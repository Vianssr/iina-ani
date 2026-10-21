import Foundation

public enum WorkspaceTransactionError: Error, Equatable, LocalizedError {
    case missingInstance(UUID)
    case invalidDestination
    public var errorDescription: String? {
        switch self {
        case .missingInstance(let id): String(localized: "Workspace item is missing: \(id.uuidString)")
        case .invalidDestination: String(localized: "The selected layout destination is not valid.")
        }
    }
}
public enum WorkspaceTransaction {
    public static func remove(instanceID: UUID, from layout: WorkspaceLayout) throws -> WorkspaceLayout {
        guard WorkspaceLayoutTraversal.componentInstanceIDs(in: layout).contains(instanceID) else {
            throw WorkspaceTransactionError.missingInstance(instanceID)
        }
        var result = layout
        result.pages = result.pages.map { page in
            var p = page
            p.root = removing(instanceID, from: p.root) ?? .empty(id: UUID())
            return p
        }
        for key in Array(result.breakpointLayouts.keys) {
            result.breakpointLayouts[key] = result.breakpointLayouts[key]?.map { page in
                var p = page
                p.root = removing(instanceID, from: p.root) ?? .empty(id: UUID())
                return p
            }
        }
        result.collapsedInstanceIDs.remove(instanceID)
        return result
    }
    public static func move(instanceID: UUID, to destinationPageID: UUID, in layout: WorkspaceLayout) throws
        -> WorkspaceLayout
    {
        try transform(instanceID: instanceID, destination: destinationPageID, layout: layout, copying: false)
    }

    public static func copy(instanceID: UUID, to destinationPageID: UUID, in layout: WorkspaceLayout) throws
        -> WorkspaceLayout
    {
        try transform(instanceID: instanceID, destination: destinationPageID, layout: layout, copying: true)
    }

    private static func transform(instanceID: UUID, destination: UUID, layout: WorkspaceLayout, copying: Bool) throws
        -> WorkspaceLayout
    {
        var found = false
        var remapped: [UUID: UUID] = [:]
        func apply(to pages: [WorkspacePage]) throws -> [WorkspacePage] {
            guard let source = find(instanceID, in: pages) else { return pages }
            found = true
            // Never remove a component from a breakpoint where its destination is absent.
            guard pages.contains(where: { $0.id == destination }) else {
                throw WorkspaceTransactionError.invalidDestination
            }
            let inserted = copying ? reidentifying(source, ids: &remapped) : source
            return pages.map { page in
                var page = page
                if !copying { page.root = removing(instanceID, from: page.root) ?? .empty(id: UUID()) }
                if page.id == destination { page.root = appending(inserted, to: page.root) }
                return page
            }
        }
        var result = layout
        result.pages = try apply(to: layout.pages)
        for key in layout.breakpointLayouts.keys {
            result.breakpointLayouts[key] = try apply(to: layout.breakpointLayouts[key]!)
        }
        guard found else { throw WorkspaceTransactionError.missingInstance(instanceID) }
        return result
    }
    private static func find(_ id: UUID, in pages: [WorkspacePage]) -> WorkspaceNode? {
        func search(_ n: WorkspaceNode) -> WorkspaceNode? {
            if case .component(let found, _, _, _, _) = n, found == id { return n }
            switch n {
            case .empty, .component: return nil
            case .split(_, let a, let b, _): return search(a) ?? search(b)
            case .grid(_, let xs), .horizontalStack(_, let xs), .verticalStack(_, let xs), .group(_, let xs):
                return xs.lazy.compactMap(search).first
            case .tabs(_, _, let pages): return pages.lazy.compactMap { search($0.root) }.first
            }
        }
        return pages.lazy.compactMap { search($0.root) }.first
    }
    private static func removing(_ id: UUID, from node: WorkspaceNode) -> WorkspaceNode? {
        switch node {
        case .component(let found, _, _, _, _) where found == id: return nil
        case .split(let nid, let a, let b, let ratio):
            let x = removing(id, from: a)
            let y = removing(id, from: b)
            if x == nil { return y }
            if y == nil { return x }
            return .split(id: nid, first: x!, second: y!, ratio: ratio)
        case .grid(let nid, let xs): return compact(xs.map { removing(id, from: $0) }, id: nid, kind: .grid)
        case .horizontalStack(let nid, let xs):
            return compact(xs.map { removing(id, from: $0) }, id: nid, kind: .horizontalStack)
        case .verticalStack(let nid, let xs):
            return compact(xs.map { removing(id, from: $0) }, id: nid, kind: .verticalStack)
        case .group(let nid, let xs): return compact(xs.map { removing(id, from: $0) }, id: nid, kind: .group)
        case .tabs(let nid, let selected, let pages):
            let kept = pages.compactMap { page -> WorkspacePage? in
                guard let root = removing(id, from: page.root) else { return nil }
                return WorkspacePage(id: page.id, title: page.title, root: root, motion: page.motion)
            }
            guard !kept.isEmpty else { return nil }
            return .tabs(
                id: nid, selectedPageID: kept.contains(where: { $0.id == selected }) ? selected : kept[0].id,
                pages: kept)
        default: return node
        }
    }
    private static func compact(_ children: [WorkspaceNode?], id: UUID, kind: WorkspaceContainerKind) -> WorkspaceNode?
    {
        let xs = children.compactMap { $0 }
        guard !xs.isEmpty else { return nil }
        if xs.count == 1 { return xs[0] }
        switch kind {
        case .grid: return .grid(id: id, columns: xs)
        case .horizontalStack: return .horizontalStack(id: id, children: xs)
        case .verticalStack: return .verticalStack(id: id, children: xs)
        case .group: return .group(id: id, children: xs)
        default: return nil
        }
    }
    private static func appending(_ node: WorkspaceNode, to root: WorkspaceNode) -> WorkspaceNode {
        switch root {
        case .empty: return node
        case .horizontalStack(let id, let xs): return .horizontalStack(id: id, children: xs + [node])
        case .group(let id, let xs): return .group(id: id, children: xs + [node])
        default: return .horizontalStack(id: UUID(), children: [root, node])
        }
    }
    private static func reidentifying(_ node: WorkspaceNode, ids: inout [UUID: UUID]) -> WorkspaceNode {
        func id(_ original: UUID) -> UUID {
            if let found = ids[original] { return found }
            let fresh = UUID()
            ids[original] = fresh
            return fresh
        }
        switch node {
        case .empty(let old): return .empty(id: id(old))
        case .component(let old, let type, let version, let params, let size):
            return .component(id: id(old), componentID: type, contractVersion: version, parameters: params, size: size)
        case .split(let old, let a, let b, let ratio):
            return .split(
                id: id(old), first: reidentifying(a, ids: &ids), second: reidentifying(b, ids: &ids), ratio: ratio)
        case .grid(let old, let xs): return .grid(id: id(old), columns: xs.map { reidentifying($0, ids: &ids) })
        case .horizontalStack(let old, let xs):
            return .horizontalStack(id: id(old), children: xs.map { reidentifying($0, ids: &ids) })
        case .verticalStack(let old, let xs):
            return .verticalStack(id: id(old), children: xs.map { reidentifying($0, ids: &ids) })
        case .group(let old, let xs): return .group(id: id(old), children: xs.map { reidentifying($0, ids: &ids) })
        case .tabs(let old, let selected, let pages):
            let newPages = pages.map {
                WorkspacePage(id: id($0.id), title: $0.title, root: reidentifying($0.root, ids: &ids), motion: $0.motion)
            }
            return .tabs(id: id(old), selectedPageID: ids[selected] ?? id(selected), pages: newPages)
        }
    }
}
