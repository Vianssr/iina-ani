import Foundation

public struct WorkspaceInstanceState: Codable, Equatable, Sendable {
    public var query: String
    public var filter: String
    public var page: Int
    public var selection: String?
    public var scrollPosition: Double
    public var density: Int
    public init(
        query: String = "", filter: String = "", page: Int = 0, selection: String? = nil, scrollPosition: Double = 0, density: Int = 0
    ) {
        self.query = query
        self.filter = filter
        self.page = page
        self.selection = selection
        self.scrollPosition = scrollPosition
        self.density = density
    }
}
public enum WorkspaceSessionStateError: Error, LocalizedError {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return String(localized: "不支援的工作區元件狀態版本：\(version)")
        }
    }
}
@MainActor
public final class WorkspaceSessionState {
    private struct Document: Codable {
        let schemaVersion: Int
        let instances: [UUID: WorkspaceInstanceState]
    }

    private let storeURL: URL?
    private var instances: [UUID: WorkspaceInstanceState] = [:]

    public init(storeURL: URL?) throws {
        self.storeURL = storeURL
        guard let storeURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == 1 else {
            throw WorkspaceSessionStateError.unsupportedSchema(document.schemaVersion)
        }
        instances = document.instances
    }

    public func state(for id: UUID) -> WorkspaceInstanceState { instances[id] ?? WorkspaceInstanceState() }
    public func update(_ state: WorkspaceInstanceState, for id: UUID) throws {
        guard instances[id] != state else { return }
        instances[id] = state
        try persist()
    }
    public func remove(_ id: UUID) throws {
        guard instances.removeValue(forKey: id) != nil else { return }
        try persist()
    }
    public func retainInstances(in layout: WorkspaceLayout) throws {
        let ids = Set(WorkspaceLayoutTraversal.componentInstanceIDs(in: layout))
        guard !instances.keys.allSatisfy({ ids.contains($0) }) else { return }
        instances = instances.filter { ids.contains($0.key) }
        try persist()
    }
    public func allInstanceIDs() -> Set<UUID> { Set(instances.keys) }

    private func persist() throws {
        guard let storeURL else { return }
        let data = try JSONEncoder().encode(Document(schemaVersion: 1, instances: instances))
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep UI intent in memory even when the caller must report a disk failure.
        try data.write(to: storeURL, options: .atomic)
    }
}
public enum WorkspaceLayoutTraversal {
    public static func componentTypes(in layout: WorkspaceLayout) -> [UUID: WorkspaceComponentID] {
        var result: [UUID: WorkspaceComponentID] = [:]
        func visit(_ node: WorkspaceNode) {
            switch node {
            case .empty: break
            case .component(let id, let type, _, _, _): result[id] = type
            case .grid(_, let children), .horizontalStack(_, let children), .verticalStack(_, let children),
                .group(_, let children):
                children.forEach(visit)
            case .split(_, let first, let second, _):
                visit(first)
                visit(second)
            case .tabs(_, _, let pages): pages.forEach { visit($0.root) }
            }
        }
        layout.pages.forEach { visit($0.root) }
        for pages in layout.breakpointLayouts.values { pages.forEach { visit($0.root) } }
        return result
    }
    public static func componentInstanceIDs(in layout: WorkspaceLayout) -> [UUID] {
        var result: [UUID] = []
        func visit(_ node: WorkspaceNode) {
            switch node {
            case .empty: break
            case .component(let id, _, _, _, _): result.append(id)
            case .grid(_, let xs), .horizontalStack(_, let xs), .verticalStack(_, let xs), .group(_, let xs):
                xs.forEach(visit)
            case .split(_, let a, let b, _):
                visit(a)
                visit(b)
            case .tabs(_, _, let pages): pages.forEach { visit($0.root) }
            }
        }
        layout.pages.forEach { visit($0.root) }
        layout.breakpointLayouts.values.flatMap { $0 }.forEach { visit($0.root) }
        return result
    }
    public static func pages(forWidth width: Double, in layout: WorkspaceLayout) -> [WorkspacePage] {
        guard let bp = layout.breakpointLayouts.keys.filter({ width >= $0.minimumWidth }).max() else {
            return layout.pages
        }
        return layout.breakpointLayouts[bp] ?? layout.pages
    }
}
