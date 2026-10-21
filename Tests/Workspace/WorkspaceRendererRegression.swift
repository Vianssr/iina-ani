import AppKit
import CoreData
@testable import IINA_ANI

@main
@MainActor
struct WorkspaceRendererRegression {
    enum Failure: Error { case unexpectedService }

    final class ProductPanel: NSViewController, WorkspaceDetachablePanel {
        private(set) var attaches = 0
        private(set) var detaches = 0
        override func loadView() { view = NSView() }
        func attach() { attaches += 1 }
        func detach() { detaches += 1 }
    }

    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? [])
            + root.subviews.flatMap { descendants($0, T.self) }
    }

    static func component(_ type: WorkspaceComponentID) -> WorkspaceNode {
        let size = WorkspaceRegistry.builtins.descriptor(for: type)!.minimumSize
        return .component(id: UUID(), componentID: type, contractVersion: 1, parameters: [:], size: size)
    }

    static func tabs(in root: NSView, containing id: UUID) -> NSTabView {
        descendants(root, NSTabView.self).first {
            $0.tabViewItems.contains { $0.identifier as? String == id.uuidString }
        }!
    }

    static func item(_ tabs: NSTabView, _ page: WorkspacePage) -> NSTabViewItem {
        tabs.tabViewItems.first { $0.identifier as? String == page.id.uuidString }!
    }

    static func invoke(_ button: NSButton) {
        check(NSApp.sendAction(button.action!, to: button.target, from: button), "production button action must be connected")
    }

    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let favorites = FavoriteLibrary(container: container)
        let store = WorkspaceStore(url: root.appendingPathComponent("layout.json"))
        let state = try WorkspaceSessionState(storeURL: nil)
        var products: [UUID: ProductPanel] = [:]
        let actions = WorkspaceFixedActions(settings: {}, open: {}, openLink: { _ in }, openWork: { _ in },
            openBangumi: { _, _ in }, openSelection: { _ in }, openUpdate: { _ in }, openDownload: { _ in })
        let dependencies = WorkspaceWindowDependencies(
            favorites: favorites, actions: actions, layoutStore: store,
            loadOnlineCollections: { 0 }, retryCollectionStatus: { _ in }, sessionState: state,
            capabilityEnabled: { _ in true }, setCapabilityEnabled: { _, _ in },
            discovery: { throw Failure.unexpectedService },
            makeSearch: {
                BrowseSearchService(loadDescriptors: { [] },
                    searchBangumi: { _, _, _ in throw Failure.unexpectedService },
                    searchSource: { _, _, _ in throw Failure.unexpectedService },
                    resolveURL: { _ in throw Failure.unexpectedService })
            }, downloads: { throw Failure.unexpectedService }, playbackHistory: { throw Failure.unexpectedService },
            resumePlayback: { _ in }, enabledSourceIDs: { [] },
            makeProductPanel: { _, id, _, _ in
                let panel = ProductPanel()
                products[id] = panel
                return panel
            })
        try lifecycle(dependencies, store: store, favorites: favorites, products: { products })
        tabOrder(dependencies)
        splitDragging()
        print("PASS: production renderer nested/top-level lifecycle, retained owners, tab reorder/selection/callback suppression, native split dragging and ratio retention")
    }

    static func lifecycle(_ dependencies: WorkspaceWindowDependencies, store: WorkspaceStore,
                          favorites: FavoriteLibrary, products: () -> [UUID: ProductPanel]) throws {
        let detailNode = component("detail.media")
        let unrelatedNode = component("torrent.import")
        let settingsNode = component("settings.preferences")
        let detail = WorkspacePage(title: "Detail", root: detailNode)
        let search = WorkspacePage(title: "Search", root: component("search.results"))
        let favorite = WorkspacePage(title: "Favorites", root: component("favorites.links"))
        let settings = WorkspacePage(title: "Settings", root: settingsNode)
        let nested = WorkspacePage(title: "Nested", root: .tabs(id: UUID(), selectedPageID: detail.id,
            pages: [detail, search, favorite, settings]))
        let inactive = WorkspacePage(title: "Outer inactive", root: .empty(id: UUID()))
        let home = WorkspacePage(title: "Home", root: .horizontalStack(id: UUID(), children: [unrelatedNode,
            .tabs(id: UUID(), selectedPageID: nested.id, pages: [nested, inactive])]))
        let away = WorkspacePage(title: "Away", root: .empty(id: UUID()))
        try store.save(WorkspaceLayout(pages: [home, away]))
        let controller = WorkspaceWindowController(dependencies: dependencies)
        controller.showWindow(nil)
        defer { controller.close() }
        let content = controller.window!.contentView!
        let outer = tabs(in: content, containing: nested.id)
        let inner = tabs(in: content, containing: detail.id)
        let detailPanel = products()[detailNode.id]!
        let unrelatedPanel = products()[unrelatedNode.id]!
        let settingsPanel = products()[settingsNode.id]!
        check(detailPanel.attaches == 1 && detailPanel.detaches == 0, "only the visible detail owner starts attached")
        check(settingsPanel.attaches == 0 && settingsPanel.detaches == 1, "inactive settings must detach too")
        check(unrelatedPanel.attaches == 1 && unrelatedPanel.detaches == 0, "unrelated visible owner must attach once")
        let searchView = item(inner, search).view!
        let searchButton = descendants(searchView, NSButton.self).first { $0.title == "Search" }!
        inner.selectTabViewItem(item(inner, search))
        invoke(searchButton)
        check(descendants(searchView, NSTextField.self).contains { $0.stringValue == "輸入關鍵詞或 URL。" },
              "search first revealed from an inactive nested tab must accept its real action")
        check(detailPanel.detaches == 1, "leaving a nested detail tab detaches screen-owned work")
        let retainedSearchView = item(inner, search).view!
        inner.selectTabViewItem(item(inner, detail))
        check(detailPanel.attaches == 2, "returning to a nested detail reattaches its retained owner")
        check(item(inner, search).view === retainedSearchView, "switching tabs cannot rebuild sibling service views")
        inner.selectTabViewItem(item(inner, detail))
        check(detailPanel.attaches == 2 && detailPanel.detaches == 1, "reselecting the active tab cannot restart work")
        check(unrelatedPanel.attaches == 1 && unrelatedPanel.detaches == 0, "nested selections cannot restart unrelated owners")
        let searchStatus = descendants(searchView, NSTextField.self).first { $0.stringValue == "輸入關鍵詞或 URL。" }!
        searchStatus.stringValue = "inactive sentinel"
        invoke(searchButton)
        check(searchStatus.stringValue == "inactive sentinel", "inactive search actions cannot run while its owner is detached")
        inner.selectTabViewItem(item(inner, search))
        invoke(searchButton)
        check(searchStatus.stringValue == "輸入關鍵詞或 URL。", "a retained service must resume actions on every reveal")
        check(item(inner, search).view === retainedSearchView, "service reattachment cannot replace its existing view")

        let favoriteTable = descendants(item(inner, favorite).view!, NSTableView.self).first!
        _ = try favorites.addLink(url: "https://live.bilibili.com/10101", title: "First")
        controller.reload(nil)
        check(favoriteTable.numberOfRows == 0, "inactive favorites must not refresh while detached")
        inner.selectTabViewItem(item(inner, favorite))
        check(favoriteTable.numberOfRows == 1, "revealed favorites reattach and reread their library")
        inner.selectTabViewItem(item(inner, settings))
        check(settingsPanel.attaches == 1, "revealed settings attach their retained global owner")
        _ = try favorites.addLink(url: "https://live.bilibili.com/10102", title: "Second")
        controller.reload(nil)
        check(favoriteTable.numberOfRows == 1, "leaving favorites must detach their refresh owner")
        outer.selectTabViewItem(item(outer, inactive))
        check(settingsPanel.detaches == 2, "hiding an ancestor tab detaches the visible nested settings")
        outer.selectTabViewItem(item(outer, nested))
        check(settingsPanel.attaches == 2, "revealing an ancestor reattaches its selected descendant")
        check(inner.selectedTabViewItem === item(inner, settings), "ancestor navigation retains nested selection")
        inner.selectTabViewItem(item(inner, favorite))
        check(favoriteTable.numberOfRows == 2, "favorite owner must also reattach after repeated navigation")

        let awayButton = descendants(content, NSButton.self).first { $0.identifier?.rawValue == away.id.uuidString }!
        invoke(awayButton)
        check(unrelatedPanel.detaches == 1, "top-level navigation uses the same owner visibility lifecycle")
        let homeButton = descendants(content, NSButton.self).first { $0.identifier?.rawValue == home.id.uuidString }!
        invoke(homeButton)
        check(products()[detailNode.id] === detailPanel && products()[unrelatedNode.id] === unrelatedPanel,
              "top-level navigation retains controller identity")
        check(unrelatedPanel.attaches == 2, "top-level return reattaches its existing owner")
    }

    static func tabOrder(_ dependencies: WorkspaceWindowDependencies) {
        let a = WorkspacePage(title: "A", root: .empty(id: UUID()))
        let b = WorkspacePage(title: "B", root: .empty(id: UUID()))
        let c = WorkspacePage(title: "C", root: .empty(id: UUID()))
        let tabsID = UUID(), pageID = UUID()
        func layout(_ pages: [WorkspacePage], selected: UUID) -> WorkspaceLayout {
            WorkspaceLayout(pages: [WorkspacePage(id: pageID, title: "Tabs",
                root: .tabs(id: tabsID, selectedPageID: selected, pages: pages))])
        }
        let preview = WorkspaceWindowController(dependencies: dependencies, previewLayout: layout([a, b, c], selected: a.id))
        let hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        preview.embedLayoutEditorPreview(in: hostWindow.contentView!)
        defer { preview.close(); hostWindow.close() }
        var selections: [UUID] = []
        preview.onEditorSelection = { selections.append($0) }
        let retained = tabs(in: hostWindow.contentView!, containing: a.id)
        let retainedA = item(retained, a), retainedB = item(retained, b)
        retained.selectTabViewItem(retainedB)
        check(selections == [b.root.id], "user selection must still reach the editor")
        selections.removeAll()
        preview.updateNativePreview(layout([b, a, c], selected: a.id), pageID: pageID, breakpoint: nil)
        check(tabs(in: hostWindow.contentView!, containing: a.id) === retained, "population retains the production tab container")
        check(retained.tabViewItems.map { $0.identifier as! String } == [b, a, c].map { $0.id.uuidString },
              "retained tab items must follow reordered layout pages")
        check(item(retained, a) === retainedA && item(retained, b) === retainedB, "reorder retains tab-item identity")
        check(retained.selectedTabViewItem === retainedB, "unchanged configured selection preserves the user's selected identity")
        check(selections.isEmpty, "population must suppress editor selection callbacks")
        preview.updateNativePreview(layout([b, a, c], selected: c.id), pageID: pageID, breakpoint: nil)
        check(retained.selectedTabViewItem === item(retained, c), "an explicit model selection change overrides retained selection")
        preview.updateNativePreview(layout([b, a], selected: a.id), pageID: pageID, breakpoint: nil)
        check(retained.selectedTabViewItem === retainedA && retained.numberOfTabViewItems == 2,
              "removing the active tab selects the intended surviving model page")
        retained.selectTabViewItem(retainedB)
        preview.updateNativePreview(layout([a], selected: a.id), pageID: pageID, breakpoint: nil)
        check(retained.selectedTabViewItem === retainedA, "removed user selection falls back to the unchanged configured selection")
        check(selections == [b.root.id], "only genuine user selections emit callbacks across all populations")
    }

    static func splitDragging() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = WorkspaceRetainedSplitView(frame: window.contentView!.bounds)
        split.autoresizingMask = [.width, .height]
        let first = NSView(), second = NSView()
        split.configure(first, second, ratio: 0.5, minimumFirst: 100, minimumSecond: 100)
        window.contentView!.addSubview(split)
        window.orderFront(nil)
        defer { window.close() }
        func drag(to x: CGFloat) {
            let start = split.convert(NSPoint(x: first.frame.maxX + split.dividerThickness / 2, y: split.bounds.midY), to: nil)
            let end = split.convert(NSPoint(x: x, y: split.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseDragged, end, 2), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, end, 3), atStart: false)
            split.mouseDown(with: event(.leftMouseDown, start, 1))
        }
        let original = first.frame.width
        drag(to: 650)
        check(first.frame.width > original + 100, "normal workspace split must native-track without an editor callback")
        let retainedRatio = first.frame.width / (split.bounds.width - split.dividerThickness)
        split.setFrameSize(NSSize(width: 1200, height: 400))
        split.resizeSubviews(withOldSize: NSSize(width: 1000, height: 400))
        check(abs(first.frame.width / (split.bounds.width - split.dividerThickness) - retainedRatio) < 0.002,
              "native dragging updates the retained ratio used by subsequent resizing")
        split.configure(first, second, ratio: 0.5, minimumFirst: 100, minimumSecond: 100)
        check(abs(first.frame.width / (split.bounds.width - split.dividerThickness) - retainedRatio) < 0.002,
              "reconfiguring an unchanged model ratio cannot discard a workspace drag")
        var changes: [Double] = []
        split.onRatioChange = { changes.append($0) }
        drag(to: 450)
        check(changes.count == 1 && abs(changes[0] - Double(first.frame.width / (split.bounds.width - split.dividerThickness))) < 0.002,
              "editor drag emits one final callback with the native retained ratio")
        split.configure(first, second, ratio: 0.4, minimumFirst: 100, minimumSecond: 100)
        check(abs(first.frame.width / (split.bounds.width - split.dividerThickness) - 0.4) < 0.002,
              "an explicit model ratio change still overrides retained workspace geometry")
        check(changes.count == 1, "programmatic configuration must not emit editor drag callbacks")
    }
}
