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
        let actions = WorkspaceFixedActions(settings: {}, open: {}, imageSearch: {}, openLink: { _ in }, openWork: { _ in },
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
        componentSizing(dependencies)
        multiColumnSizing(dependencies)
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

        let originalLayout = controller.shareableLayout
        outer.selectTabViewItem(item(outer, inactive))
        let detailAttaches = detailPanel.attaches
        let unrelatedAttaches = unrelatedPanel.attaches
        check(controller.showProduct("detail.media") === detailPanel,
              "fixed detail commands must find the retained product inside nested tabs")
        check(outer.selectedTabViewItem === item(outer, nested)
                && inner.selectedTabViewItem === item(inner, detail),
              "opening a nested product must reveal every selected tab ancestor")
        check(detailPanel.view.window === controller.window && !detailPanel.view.isHiddenOrHasHiddenAncestor,
              "revealed detail geometry must belong to the actual destination window")
        check(detailPanel.attaches == detailAttaches + 1,
              "revealing the complete nested path must attach the detail owner exactly once")
        check(unrelatedPanel.attaches == unrelatedAttaches,
              "revealing nested detail cannot restart a visible sibling owner")
        _ = controller.showProduct("detail.media")
        check(detailPanel.attaches == detailAttaches + 1,
              "repeating the product command must not restart an already visible detail")
        check(controller.shareableLayout == originalLayout,
              "product navigation must not overwrite the user's authored tab selection")

        let currentAwayButton = descendants(content, NSButton.self).first { $0.identifier?.rawValue == away.id.uuidString }!
        invoke(currentAwayButton)
        check(controller.showProduct("detail.media") === detailPanel
                && detailPanel.view.window === controller.window,
              "opening nested detail from another top-level page must reveal the retained destination")
        check(detailPanel.attaches == detailAttaches + 2,
              "cross-page product navigation must attach the retained detail once")
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

    static func componentSizing(_ dependencies: WorkspaceWindowDependencies) {
        func node(_ type: WorkspaceComponentID, id: UUID = UUID(), width: Double, height: Double) -> WorkspaceNode {
            .component(id: id, componentID: type, contractVersion: 1, parameters: [:],
                       size: WorkspaceSize(width: width, height: height))
        }
        func verify(_ nodes: [WorkspaceNode], root: WorkspaceNode, pageID: UUID = UUID()) {
            let page = WorkspacePage(id: pageID, title: "Sizing", root: root)
            let preview = WorkspaceWindowController(dependencies: dependencies,
                previewLayout: WorkspaceLayout(pages: [page]))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            preview.embedLayoutEditorPreview(in: window.contentView!)
            window.contentView!.layoutSubtreeIfNeeded()
            defer { preview.close(); window.close() }
            for node in nodes {
                guard case .component(_, let type, _, _, let size) = node else { fatalError("expected component") }
                let title = descendants(window.contentView!, NSButton.self).first {
                    $0.identifier?.rawValue == "workspace.editor.node.\(node.id.uuidString)"
                }!
                let frame = title.superview!.bounds
                check(abs(frame.width - size.width - 6) < 1,
                      "\(type): authored width must size the visible selection, not just an invisible request")
                check(abs(frame.height - size.height - 32) < 1,
                      "\(type): authored height must override fill and empty-content height")
            }
        }
        for descriptor in WorkspaceRegistry.builtins.descriptors {
            let component = node(descriptor.id, width: descriptor.minimumSize.width + 64,
                                 height: descriptor.minimumSize.height + 96)
            verify([component], root: component)
        }
        let a = node("playback.continue", width: 544, height: 256)
        let b = node("discovery.recommendations", width: 608, height: 288)
        let feed = node("discovery.feed", width: 672, height: 352)
        verify([b, a, feed], root: .verticalStack(id: UUID(), children: [b, a, feed]),
               pageID: WorkspacePageID.discover)
        verify([a, b], root: .horizontalStack(id: UUID(), children: [a, b]))
        verify([a, b], root: .grid(id: UUID(), columns: [a, b]))
        let works = node("favorites.works", width: 352, height: 320)
        let links = node("favorites.links", width: 384, height: 352)
        let updates = node("discovery.updates", width: 608, height: 288)
        verify([updates, works, links], root: .verticalStack(id: UUID(), children: [
            updates, .split(id: UUID(), first: works, second: links, ratio: 0.5)
        ]))
        print("PASS: custom dimensions for every component, discovery empty states, horizontal/grid/split placement")
    }

    static func multiColumnSizing(_ dependencies: WorkspaceWindowDependencies) {
        func automatic(_ type: WorkspaceComponentID) -> WorkspaceNode {
            .component(id: UUID(), componentID: type, contractVersion: 1, parameters: [:],
                       size: WorkspaceRegistry.builtins.descriptor(for: type)!.defaultSize)
        }
        func header(_ type: WorkspaceComponentID, height: Double) -> WorkspaceNode {
            let size = WorkspaceRegistry.builtins.descriptor(for: type)!.defaultSize
            return .component(id: UUID(), componentID: type, contractVersion: 1, parameters: [:],
                              size: .init(width: size.width, height: height))
        }
        func columns() -> [WorkspaceNode] {
            [automatic("downloads.tasks"), automatic("search.results"), automatic("favorites.links")]
        }
        func split(_ nodes: [WorkspaceNode]) -> WorkspaceNode {
            .split(id: UUID(), first: nodes[0], second:
                .split(id: UUID(), first: nodes[1], second: nodes[2], ratio: 0.5), ratio: 1.0 / 3.0)
        }
        func verify(_ root: WorkspaceNode, pageID: UUID = UUID(), internalScroll: Bool = true,
                    headerHeights: [CGFloat] = [], columnWidths: [CGFloat] = []) {
            let page = WorkspacePage(id: pageID, title: "Columns", root: root)
            let preview = WorkspaceWindowController(dependencies: dependencies,
                previewLayout: WorkspaceLayout(pages: [page]))
            preview.showWindow(nil)
            let content = preview.window!.contentView!
            content.layoutSubtreeIfNeeded()
            defer { preview.close() }
            let scroll = descendants(content, NSScrollView.self).first!
            let document = scroll.documentView!
            if internalScroll {
                check(abs(document.bounds.height - scroll.contentView.bounds.height) < 1,
                      "column pages must give their panels the viewport instead of the requested document height")
            } else {
                check(document.bounds.height > scroll.contentView.bounds.height + 1,
                      "ordinary vertical and discovery feed pages must retain page scrolling")
            }
            var body = document.subviews[0]
            if !headerHeights.isEmpty {
                let stack = body as! NSStackView
                for (index, height) in headerHeights.enumerated() {
                    check(abs(stack.arrangedSubviews[index].bounds.height - height) < 1,
                          "each header above columns must retain its authored height")
                }
                body = stack.arrangedSubviews.last!
            }
            if !columnWidths.isEmpty {
                let panes: [NSView]
                if let outer = body as? WorkspaceRetainedSplitView {
                    let inner = outer.arrangedSubviews[1] as! WorkspaceRetainedSplitView
                    panes = [outer.arrangedSubviews[0]] + inner.arrangedSubviews
                } else {
                    panes = (body as! NSStackView).arrangedSubviews
                }
                check(panes.count == columnWidths.count, "all authored columns must be simultaneously visible")
                for (pane, minimum) in zip(panes, columnWidths) {
                    check(pane.bounds.width >= minimum - 1, "nested and horizontal columns must retain pane minima")
                }
            }
        }
        let minimumWidths: [CGFloat] = [480, 480, 280]
        verify(split(columns()), columnWidths: minimumWidths)
        verify(.horizontalStack(id: UUID(), children: columns()), pageID: WorkspacePageID.discover,
               columnWidths: minimumWidths)
        verify(.verticalStack(id: UUID(), children: [
            header("playback.continue", height: 192), header("playback.continue", height: 224), split(columns())
        ]), headerHeights: [192, 224], columnWidths: minimumWidths)
        verify(.verticalStack(id: UUID(), children: [
            header("discovery.updates", height: 256), .horizontalStack(id: UUID(), children: columns())
        ]), headerHeights: [256], columnWidths: minimumWidths)
        verify(.verticalStack(id: UUID(), children: [
            automatic("playback.continue"), automatic("playback.continue"), automatic("downloads.tasks")
        ]), internalScroll: false)
        verify(.verticalStack(id: UUID(), children: [
            automatic("discovery.recommendations"), automatic("playback.continue"), automatic("discovery.feed")
        ]), pageID: WorkspacePageID.discover, internalScroll: false)
        let insertionPage = WorkspacePage(title: "Search with added columns", root:
            .verticalStack(id: UUID(), children: [
                automatic("search.results"),
                .split(id: UUID(), first: .empty(id: UUID()), second: .empty(id: UUID()), ratio: 0.5),
            ]))
        let inserted = WorkspaceWindowController(dependencies: dependencies,
            previewLayout: WorkspaceLayout(pages: [insertionPage]))
        inserted.showWindow(nil)
        inserted.window!.contentView!.layoutSubtreeIfNeeded()
        let emptyColumns = descendants(inserted.window!.contentView!, WorkspaceRetainedSplitView.self).first!
        check(emptyColumns.arrangedSubviews.allSatisfy { $0.bounds.height >= 180 },
              "new empty columns below existing page content must remain visible and usable")
        inserted.close()
        print("PASS: structural nested/horizontal columns, authored header heights, pane minima and normal/discovery page scrolling")
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
