import Foundation

/// An edit session owns only a value draft. No command or store writes occur until commit.
final class WorkspaceLayoutEditor {
    private(set) var layout: WorkspaceLayout
    private let validator: WorkspaceValidator
    private var undoLayouts: [WorkspaceLayout] = []
    private var redoLayouts: [WorkspaceLayout] = []
    var breakpoint: WorkspaceBreakpoint?
    var pages: [WorkspacePage] { breakpoint.flatMap { layout.breakpointLayouts[$0] } ?? layout.pages }
    var canUndo: Bool { !undoLayouts.isEmpty }
    var canRedo: Bool { !redoLayouts.isEmpty }

    init(layout: WorkspaceLayout, registry: any WorkspaceComponentRegistry) {
        self.layout = layout
        validator = WorkspaceValidator(registry: registry)
    }

    func transact(_ change: (inout WorkspaceLayout) throws -> Void) throws {
        var next = layout
        try change(&next)
        try validator.validate(next)
        guard next != layout else { return }
        undoLayouts.append(layout)
        redoLayouts.removeAll()
        layout = next
    }

    func editPages(_ change: (inout [WorkspacePage]) throws -> Void) throws {
        try transact { next in
            var pages = breakpoint.flatMap { next.breakpointLayouts[$0] } ?? next.pages
            try change(&pages)
            if let breakpoint { next.breakpointLayouts[breakpoint] = pages } else { next.pages = pages }
            Self.prunePresentation(&next)
        }
    }

    func undo() {
        guard let previous = undoLayouts.popLast() else { return }
        redoLayouts.append(layout)
        layout = previous
        if let breakpoint, layout.breakpointLayouts[breakpoint] == nil { self.breakpoint = nil }
    }
    func redo() {
        guard let next = redoLayouts.popLast() else { return }
        undoLayouts.append(layout)
        layout = next
        if let breakpoint, layout.breakpointLayouts[breakpoint] == nil { self.breakpoint = nil }
    }

    func addBreakpoint(width: Double) throws {
        let key = WorkspaceBreakpoint(minimumWidth: width)
        guard layout.breakpointLayouts[key] == nil else { throw WorkspaceTransactionError.invalidDestination }
        try transact { $0.breakpointLayouts[key] = pages }
        breakpoint = key
    }
    func removeBreakpoint() throws {
        guard let breakpoint else { throw WorkspaceTransactionError.invalidDestination }
        try transact { $0.breakpointLayouts.removeValue(forKey: breakpoint); Self.prunePresentation(&$0) }
        self.breakpoint = nil
    }

    func move(nodeID: UUID, to destinationID: UUID, index: Int) throws {
        try editPages { pages in
            guard let source = WorkspaceEditorTree.find(nodeID, in: pages),
                !WorkspaceEditorTree.contains(destinationID, in: source)
            else { throw WorkspaceTransactionError.invalidDestination }
            if let target = WorkspaceEditorTree.find(destinationID, in: pages) {
                if case .split(let id, let first, let second, let ratio) = target,
                   first.id == nodeID || second.id == nodeID {
                    let wanted = index <= 0 ? 0 : 1
                    let old = first.id == nodeID ? 0 : 1
                    if wanted != old {
                        for i in pages.indices {
                            pages[i].root = WorkspaceEditorTree.map(pages[i].root) {
                                $0.id == id ? .split(id: id, first: second, second: first, ratio: 1 - ratio) : $0
                            }
                        }
                    }
                    return
                }
                if case .tabs(let id, let selected, var tabs) = target,
                   let old = tabs.firstIndex(where: { $0.root.id == nodeID }) {
                    let tab = tabs.remove(at: old)
                    tabs.insert(tab, at: max(0, min(index - (old < index ? 1 : 0), tabs.count)))
                    for i in pages.indices {
                        pages[i].root = WorkspaceEditorTree.map(pages[i].root) {
                            $0.id == id ? .tabs(id: id, selectedPageID: selected, pages: tabs) : $0
                        }
                    }
                    return
                }
            }
            // Outline insertion indexes refer to the pre-removal siblings.
            let siblings = WorkspaceEditorTree.children(of: destinationID, in: pages)
            let oldIndex = siblings?.firstIndex(where: { $0.id == nodeID })
            let insertion = index - ((oldIndex.map { $0 < index } ?? false) ? 1 : 0)
            pages = pages.map { page in
                var page = page
                page.root = WorkspaceEditorTree.removing(nodeID, from: page.root) ?? .empty(id: UUID())
                return page
            }
            try WorkspaceEditorTree.insert(source, to: destinationID, index: insertion, pages: &pages)
        }
    }
    func move(nodeID: UUID, relativeTo targetID: UUID, after: Bool) throws {
        guard nodeID != targetID,
              let source = WorkspaceEditorTree.find(nodeID, in: pages),
              !WorkspaceEditorTree.contains(targetID, in: source) else {
            throw WorkspaceTransactionError.invalidDestination
        }
        func location(in node: WorkspaceNode) -> (parent: UUID, index: Int)? {
            if case .tabs(_, _, let tabs) = node {
                for tab in tabs {
                    if tab.root.id == targetID { return (tab.id, 0) }
                    if let found = location(in: tab.root) { return found }
                }
                return nil
            }
            let children = WorkspaceEditorTree.children(node)
            if let index = children.firstIndex(where: { $0.id == targetID }) {
                // A split has two fixed slots, not an insertion boundary for a third child.
                if case .split = node, !children.contains(where: { $0.id == nodeID }) { return nil }
                return (node.id, index)
            }
            for child in children {
                if let found = location(in: child) { return found }
            }
            return nil
        }
        for page in pages {
            let target = page.root.id == targetID ? (parent: page.id, index: 0) : location(in: page.root)
            if let target {
                var insertion = target.index + (after ? 1 : 0)
                if case .split(_, let first, _, _)? = WorkspaceEditorTree.find(target.parent, in: pages) {
                    let oldIndex = first.id == nodeID ? 0 : 1
                    insertion = max(0, min(1, insertion - (oldIndex < insertion ? 1 : 0)))
                }
                try move(nodeID: nodeID, to: target.parent, index: insertion)
                return
            }
        }
        throw WorkspaceTransactionError.invalidDestination
    }
    func insert(_ node: WorkspaceNode, to destinationID: UUID, index: Int = Int.max) throws {
        try editPages { try WorkspaceEditorTree.insert(node, to: destinationID, index: index, pages: &$0) }
    }
    func remove(nodeID: UUID) throws {
        try editPages { pages in
            guard WorkspaceEditorTree.find(nodeID, in: pages) != nil else {
                throw WorkspaceTransactionError.missingInstance(nodeID)
            }
            pages = pages.map { page in
                var page = page
                page.root = WorkspaceEditorTree.removing(nodeID, from: page.root) ?? .empty(id: UUID())
                return page
            }
        }
    }
    func replace(nodeID: UUID, with change: (WorkspaceNode) throws -> WorkspaceNode) throws {
        try editPages { pages in
            guard WorkspaceEditorTree.find(nodeID, in: pages) != nil else {
                throw WorkspaceTransactionError.missingInstance(nodeID)
            }
            for index in pages.indices {
                pages[index].root = try WorkspaceEditorTree.map(pages[index].root) {
                    $0.id == nodeID ? try change($0) : $0
                }
            }
        }
    }
    func setPaneCount(nodeID: UUID, count: Int) throws {
        guard count >= 1 else { throw WorkspaceTransactionError.invalidDestination }
        guard count <= validator.maximumNodes else { throw WorkspaceValidationError.tooManyNodes }
        try replace(nodeID: nodeID) { node in
            var panes: [WorkspaceNode]
            switch node {
            case .split, .horizontalStack:
                panes = WorkspaceEditorTree.panes(node)
                guard panes.count != count else { return node }
            case .verticalStack, .group, .grid:
                panes = WorkspaceEditorTree.children(node)
            case .tabs, .component, .empty:
                throw WorkspaceTransactionError.invalidDestination
            }
            // A right-associated count-column split needs at least count levels, even at the root.
            guard count <= validator.maximumDepth else { throw WorkspaceValidationError.excessiveDepth }
            if panes.count > count {
                let overflow = WorkspaceNode.verticalStack(id: UUID(), children: Array(panes[(count - 1)...]))
                panes.removeSubrange((count - 1)...)
                panes.append(overflow)
            } else {
                while panes.count < count { panes.append(.empty(id: UUID())) }
            }
            return WorkspaceEditorTree.paneContainer(id: node.id, children: panes)
        }
    }

    func reorderPage(_ id: UUID, to index: Int) throws {
        try editPages { pages in
            guard let old = pages.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceTransactionError.invalidDestination
            }
            let page = pages.remove(at: old)
            pages.insert(page, at: max(0, min(index, pages.count)))
        }
    }
    func addPage(title: String) throws {
        try editPages { $0.append(WorkspacePage(title: title, root: .empty(id: UUID()))) }
    }
    func removePage(_ id: UUID) throws {
        try editPages { $0.removeAll { $0.id == id } }
    }
    func renamePage(_ id: UUID, title: String) throws {
        try editPages { pages in
            guard let index = pages.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceTransactionError.invalidDestination
            }
            pages[index].title = title
        }
    }
    func setPageMotion(pageID: UUID, motion: WorkspacePageMotion) throws {
        try motion.validate()
        try editPages { pages in
            var found = false
            for index in pages.indices {
                if pages[index].id == pageID {
                    pages[index].motion = motion
                    found = true
                } else {
                    pages[index].root = WorkspaceEditorTree.map(pages[index].root) { node in
                        guard case .tabs(let id, let selected, var tabs) = node,
                              let tabIndex = tabs.firstIndex(where: { $0.id == pageID }) else { return node }
                        tabs[tabIndex].motion = motion
                        found = true
                        return .tabs(id: id, selectedPageID: selected, pages: tabs)
                    }
                }
            }
            guard found else { throw WorkspaceTransactionError.invalidDestination }
        }
    }
    func setHome(_ id: UUID) throws {
        try transact { $0.homePageID = id; $0.hiddenPageIDs.remove(id) }
    }
    func toggleHidden(_ id: UUID) throws {
        try transact { next in
            if next.hiddenPageIDs.remove(id) == nil { next.hiddenPageIDs.insert(id) }
            if next.homePageID == id && next.hiddenPageIDs.contains(id) { next.homePageID = nil }
        }
    }
    func toggleCollapsed(_ id: UUID) throws {
        try transact { next in
            if next.collapsedInstanceIDs.remove(id) == nil { next.collapsedInstanceIDs.insert(id) }
        }
    }
    func restore() throws {
        try transact { $0 = WorkspaceBuiltinLayouts.makeDefault() }
        if let breakpoint, layout.breakpointLayouts[breakpoint] == nil { self.breakpoint = nil }
    }

    static func prunePresentation(_ layout: inout WorkspaceLayout) {
        let pageIDs = Set(([layout.pages] + Array(layout.breakpointLayouts.values)).flatMap { $0.map(\.id) })
        layout.hiddenPageIDs.formIntersection(pageIDs)
        if let home = layout.homePageID, !pageIDs.contains(home) { layout.homePageID = nil }
        layout.collapsedInstanceIDs.formIntersection(Set(WorkspaceLayoutTraversal.componentInstanceIDs(in: layout)))
    }
}

/// Tree edits preserve IDs, including the empty slots of split containers.
enum WorkspaceEditorTree {
    static func children(_ node: WorkspaceNode) -> [WorkspaceNode] {
        switch node {
        case .grid(_, let nodes), .horizontalStack(_, let nodes), .verticalStack(_, let nodes), .group(_, let nodes):
            return nodes
        case .split(_, let first, let second, _): return [first, second]
        case .tabs(_, _, let pages): return pages.map(\.root)
        default: return []
        }
    }
    /// Split dividers describe adjacent panes; vertical content remains together in its pane.
    static func panes(_ node: WorkspaceNode) -> [WorkspaceNode] {
        var result: [WorkspaceNode] = []
        func append(_ node: WorkspaceNode) {
            switch node {
            case .split(_, let first, let second, _): append(first); append(second)
            case .horizontalStack(_, let children): result.append(contentsOf: children)
            default: result.append(node)
            }
        }
        append(node)
        return result
    }
    /// Existing binary splits encode any number of equally sized, independently resizable columns.
    static func paneContainer(id: UUID, children: [WorkspaceNode]) -> WorkspaceNode {
        guard children.count > 1 else { return .horizontalStack(id: id, children: children) }
        var remainder = children[children.count - 1]
        for index in stride(from: children.count - 2, through: 0, by: -1) {
            remainder = .split(id: index == 0 ? id : UUID(), first: children[index], second: remainder,
                               ratio: 1 / Double(children.count - index))
        }
        return remainder
    }
    static func isContainer(_ node: WorkspaceNode) -> Bool {
        switch node { case .component, .empty: return false; default: return true }
    }
    static func contains(_ id: UUID, in node: WorkspaceNode) -> Bool {
        node.id == id || children(node).contains { contains(id, in: $0) }
    }
    static func find(_ id: UUID, in pages: [WorkspacePage]) -> WorkspaceNode? {
        func find(_ node: WorkspaceNode) -> WorkspaceNode? {
            if node.id == id { return node }
            for child in children(node) { if let found = find(child) { return found } }
            return nil
        }
        for page in pages { if let node = find(page.root) { return node } }
        return nil
    }
    static func findPage(_ id: UUID, in pages: [WorkspacePage]) -> WorkspacePage? {
        func find(in node: WorkspaceNode) -> WorkspacePage? {
            if case .tabs(_, _, let tabs) = node { return findPage(id, in: tabs) }
            for child in children(node) {
                if let page = find(in: child) { return page }
            }
            return nil
        }
        for page in pages {
            if page.id == id { return page }
            if let nested = find(in: page.root) { return nested }
        }
        return nil
    }
    static func children(of id: UUID, in pages: [WorkspacePage]) -> [WorkspaceNode]? {
        if let page = findPage(id, in: pages) { return [page.root] }
        return find(id, in: pages).map(children)
    }
    static func map(_ node: WorkspaceNode, change: (WorkspaceNode) throws -> WorkspaceNode) rethrows -> WorkspaceNode {
        let next: WorkspaceNode
        switch node {
        case .grid(let id, let nodes): next = .grid(id: id, columns: try nodes.map { try map($0, change: change) })
        case .horizontalStack(let id, let nodes):
            next = .horizontalStack(id: id, children: try nodes.map { try map($0, change: change) })
        case .verticalStack(let id, let nodes):
            next = .verticalStack(id: id, children: try nodes.map { try map($0, change: change) })
        case .group(let id, let nodes): next = .group(id: id, children: try nodes.map { try map($0, change: change) })
        case .split(let id, let first, let second, let ratio):
            next = .split(id: id, first: try map(first, change: change), second: try map(second, change: change), ratio: ratio)
        case .tabs(let id, let selected, let pages):
            next = .tabs(id: id, selectedPageID: selected, pages: try pages.map { page in
                var page = page; page.root = try map(page.root, change: change); return page
            })
        default: next = node
        }
        return try change(next)
    }
    static func removing(_ id: UUID, from node: WorkspaceNode) -> WorkspaceNode? {
        if node.id == id { return nil }
        func survivors(_ nodes: [WorkspaceNode]) -> [WorkspaceNode] { nodes.compactMap { removing(id, from: $0) } }
        switch node {
        case .grid(let key, let nodes):
            let nodes = survivors(nodes); return nodes.isEmpty ? .empty(id: key) : .grid(id: key, columns: nodes)
        case .horizontalStack(let key, let nodes):
            let nodes = survivors(nodes); return nodes.isEmpty ? .empty(id: key) : .horizontalStack(id: key, children: nodes)
        case .verticalStack(let key, let nodes):
            let nodes = survivors(nodes); return nodes.isEmpty ? .empty(id: key) : .verticalStack(id: key, children: nodes)
        case .group(let key, let nodes):
            let nodes = survivors(nodes); return nodes.isEmpty ? .empty(id: key) : .group(id: key, children: nodes)
        case .split(let key, let first, let second, let ratio):
            return .split(id: key, first: removing(id, from: first) ?? .empty(id: UUID()),
                          second: removing(id, from: second) ?? .empty(id: UUID()), ratio: ratio)
        case .tabs(let key, let selected, let pages):
            let surviving = pages.compactMap { page -> WorkspacePage? in
                guard let root = removing(id, from: page.root) else { return nil }
                var page = page; page.root = root; return page
            }
            guard let first = surviving.first else { return .empty(id: key) }
            return .tabs(id: key, selectedPageID: surviving.contains { $0.id == selected } ? selected : first.id, pages: surviving)
        default: return node
        }
    }
    static func insert(_ source: WorkspaceNode, to destination: UUID, index: Int, pages: inout [WorkspacePage]) throws {
        var found = false
        func root(insertingInto root: WorkspaceNode) -> WorkspaceNode {
            if case .empty = root { return source }
            return .verticalStack(id: UUID(), children: index <= 0 ? [source, root] : [root, source])
        }
        func insertion(_ node: WorkspaceNode) throws -> WorkspaceNode {
            if case .tabs(let id, let selected, var tabs) = node,
               let pageIndex = tabs.firstIndex(where: { $0.id == destination }) {
                found = true
                tabs[pageIndex].root = root(insertingInto: tabs[pageIndex].root)
                return .tabs(id: id, selectedPageID: selected, pages: tabs)
            }
            guard node.id == destination else { return node }
            found = true
            switch node {
            case .empty: return source
            case .grid(let id, var nodes):
                nodes.insert(source, at: max(0, min(index, nodes.count))); return .grid(id: id, columns: nodes)
            case .horizontalStack(let id, var nodes):
                nodes.insert(source, at: max(0, min(index, nodes.count))); return .horizontalStack(id: id, children: nodes)
            case .verticalStack(let id, var nodes):
                nodes.insert(source, at: max(0, min(index, nodes.count))); return .verticalStack(id: id, children: nodes)
            case .group(let id, var nodes):
                nodes.insert(source, at: max(0, min(index, nodes.count))); return .group(id: id, children: nodes)
            case .tabs(let id, let selected, var pages):
                pages.insert(WorkspacePage(title: String(localized: "分頁 \(pages.count + 1)"), root: source), at: max(0, min(index, pages.count)))
                return .tabs(id: id, selectedPageID: selected, pages: pages)
            case .split(let id, let first, let second, let ratio):
                // Inserting onto the divider targets a slot; nonempty slots become a stack.
                func append(_ target: WorkspaceNode) -> WorkspaceNode {
                    if case .empty = target { return source }
                    return .verticalStack(id: UUID(), children: [target, source])
                }
                return index <= 0 ? .split(id: id, first: append(first), second: second, ratio: ratio)
                    : .split(id: id, first: first, second: append(second), ratio: ratio)
            case .component: throw WorkspaceTransactionError.invalidDestination
            }
        }
        for i in pages.indices {
            if pages[i].id == destination {
                found = true
                pages[i].root = root(insertingInto: pages[i].root)
            } else { pages[i].root = try map(pages[i].root, change: insertion) }
        }
        guard found else { throw WorkspaceTransactionError.invalidDestination }
    }
    static func container(_ kind: WorkspaceContainerKind, id: UUID = UUID(), children: [WorkspaceNode]) -> WorkspaceNode {
        let nodes = children.isEmpty ? [.empty(id: UUID())] : children
        switch kind {
        case .grid: return .grid(id: id, columns: nodes)
        case .horizontalStack: return .horizontalStack(id: id, children: nodes)
        case .verticalStack, .page: return .verticalStack(id: id, children: nodes)
        case .group: return .group(id: id, children: nodes)
        case .split:
            let second: WorkspaceNode = nodes.count > 2 ? .verticalStack(id: UUID(), children: Array(nodes.dropFirst()))
                : nodes.count == 2 ? nodes[1] : .empty(id: UUID())
            return .split(id: id, first: nodes[0], second: second, ratio: 0.5)
        case .tabs:
            let pages = nodes.enumerated().map { WorkspacePage(title: String(localized: "分頁 \($0.offset + 1)"), root: $0.element) }
            return .tabs(id: id, selectedPageID: pages[0].id, pages: pages)
        }
    }
}
