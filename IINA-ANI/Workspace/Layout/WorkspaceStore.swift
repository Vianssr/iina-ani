import Foundation

public enum WorkspaceLoadResult: Sendable {
    case loaded(WorkspaceLayout)
    case recoveredDefault(WorkspaceLayout, reason: String)
}
public struct WorkspaceStore: Sendable {
    public let url: URL
    public let validator: WorkspaceValidator
    public init(url: URL, validator: WorkspaceValidator = WorkspaceValidator(registry: WorkspaceRegistry.builtins)) {
        self.url = url
        self.validator = validator
    }
    public func load(defaultLayout: WorkspaceLayout = WorkspaceBuiltinLayouts.makeDefault()) -> WorkspaceLoadResult {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try save(defaultLayout)
                return .loaded(defaultLayout)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= validator.maximumDocumentBytes else {
                throw WorkspaceDocumentError.tooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let layout = try WorkspaceLayoutCodec.decode(data, validator: validator)
            if let migrated = WorkspaceBuiltinLayoutMigration.migrate(layout) {
                try save(migrated)
                return .loaded(migrated)
            }
            return .loaded(layout)
        } catch { return .recoveredDefault(defaultLayout, reason: error.localizedDescription) }
    }
    public func save(_ layout: WorkspaceLayout) throws {
        let data = try WorkspaceLayoutCodec.encode(layout, validator: validator)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= validator.maximumDocumentBytes else {
                    throw WorkspaceDocumentError.tooLarge
                }
                _ = try WorkspaceLayoutCodec.decode(
                    Data(contentsOf: url, options: [.mappedIfSafe]), validator: validator)
            } catch {
                let backup = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: url, to: backup)
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }
}

private enum WorkspaceBuiltinLayoutMigration {
    // Only exact builtin page pairs in every breakpoint may be upgraded.
    static func migrate(_ layout: WorkspaceLayout) -> WorkspaceLayout? {
        let variants = [layout.pages] + Array(layout.breakpointLayouts.values)
        let legacy = variants.allSatisfy(isLegacy)
        guard legacy || variants.allSatisfy(isPreviousHome) else { return nil }
        let feed = WorkspaceNode.component(
            id: UUID(), componentID: "discovery.feed", contractVersion: 1, parameters: [:],
            size: .init(width: 760, height: 640))
        let history = WorkspaceNode.component(
            id: UUID(), componentID: "playback.continue", contractVersion: 1, parameters: [:],
            size: .init(width: 760, height: 164))
        let favoritesRootID = UUID()
        func migratePages(_ pages: [WorkspacePage]) -> [WorkspacePage] {
            let discover = pages.first { $0.id == WorkspacePageID.discover }!
            guard case .verticalStack(let rootID, let children) = discover.root else { return pages }
            return pages.map { original in
                var page = original
                switch page.id {
                case WorkspacePageID.discover:
                    page.root = .verticalStack(id: rootID, children: [
                        resized(children[legacy ? 2 : 0], height: 210), history, legacy ? feed : children[1]])
                case WorkspacePageID.favorites where legacy:
                    page.root = .verticalStack(
                        id: favoritesRootID, children: [resized(children[1], height: 240), page.root])
                default: break
                }
                return page
            }
        }
        var migrated = layout
        migrated.pages = migratePages(layout.pages)
        for key in layout.breakpointLayouts.keys {
            migrated.breakpointLayouts[key] = migratePages(layout.breakpointLayouts[key]!)
        }
        migrated.collapsedInstanceIDs.formIntersection(
            Set(WorkspaceLayoutTraversal.componentInstanceIDs(in: migrated)))
        return migrated
    }

    private static func isPreviousHome(_ pages: [WorkspacePage]) -> Bool {
        guard let discover = pages.first(where: { $0.id == WorkspacePageID.discover }),
            let favorites = pages.first(where: { $0.id == WorkspacePageID.favorites }),
            case .verticalStack(_, let children) = discover.root, children.count == 2,
            matches(children[0], "discovery.recommendations", width: 760, height: 280),
            matches(children[1], "discovery.feed", width: 760, height: 640),
            case .verticalStack(_, let favoriteChildren) = favorites.root, favoriteChildren.count == 2,
            matches(favoriteChildren[0], "discovery.updates", width: 760, height: 240),
            isLibrarySplit(favoriteChildren[1]) else { return false }
        return true
    }

    private static func isLegacy(_ pages: [WorkspacePage]) -> Bool {
        guard let discover = pages.first(where: { $0.id == WorkspacePageID.discover }),
            let favorites = pages.first(where: { $0.id == WorkspacePageID.favorites }),
            case .verticalStack(_, let children) = discover.root, children.count == 3 || children.count == 4,
            matches(children[0], "discovery.schedule", width: 760, height: 280),
            matches(children[1], "discovery.updates", width: 760, height: 280),
            matches(children[2], "discovery.recommendations", width: 760, height: 360),
            (children.count == 3 || matches(children[3], "discovery.followed", width: 760, height: 360)),
            isLibrarySplit(favorites.root) else { return false }
        return true
    }

    private static func isLibrarySplit(_ node: WorkspaceNode) -> Bool {
        guard case .split(_, let works, let links, let ratio) = node, ratio == 0.5 else { return false }
        return matches(works, "favorites.works", width: 420, height: 480)
            && matches(links, "favorites.links", width: 420, height: 480)
    }

    private static func matches(_ node: WorkspaceNode, _ expected: WorkspaceComponentID,
                                width: Double, height: Double) -> Bool {
        guard case .component(_, let type, let version, let parameters, let size) = node else { return false }
        return type == expected && version == 1 && parameters.isEmpty
            && size == WorkspaceSize(width: width, height: height)
    }

    private static func resized(_ node: WorkspaceNode, height: Double) -> WorkspaceNode {
        guard case .component(let id, let type, let version, let parameters, let size) = node else { return node }
        return .component(id: id, componentID: type, contractVersion: version, parameters: parameters,
                          size: .init(width: size.width, height: height))
    }
}
