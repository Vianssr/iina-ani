import AppKit
import QuartzCore

@MainActor
final class WorkspaceFixedActions {
    private(set) var transitionSource: WorkspaceCoverTransitionSource?

    func withTransitionSource(from view: NSView?, _ action: () -> Void) {
        transitionSource = WorkspaceCoverTransitionSource.capture(from: view)
        defer { transitionSource = nil }
        action()
    }

    let settings: () -> Void
    let open: () -> Void
    let imageSearch: () -> Void
    let openLink: (String) -> Void
    let openWork: (UUID) -> Void
    let openBangumi: (Int, BangumiSubject?) -> Void
    let openSelection: (PlayableSelection) -> Void
    let openUpdate: (DiscoveryFavoriteUpdate) -> Void
    let openDownload: (UUID) async throws -> Void

    init(settings: @escaping () -> Void, open: @escaping () -> Void, imageSearch: @escaping () -> Void,
         openLink: @escaping (String) -> Void, openWork: @escaping (UUID) -> Void,
         openBangumi: @escaping (Int, BangumiSubject?) -> Void, openSelection: @escaping (PlayableSelection) -> Void,
         openUpdate: @escaping (DiscoveryFavoriteUpdate) -> Void,
         openDownload: @escaping (UUID) async throws -> Void) {
        self.settings = settings
        self.open = open
        self.imageSearch = imageSearch
        self.openLink = openLink
        self.openWork = openWork
        self.openBangumi = openBangumi
        self.openSelection = openSelection
        self.openUpdate = openUpdate
        self.openDownload = openDownload
    }
}

@MainActor
struct WorkspaceWindowDependencies {
    let favorites: FavoriteLibrary
    let loadOnlineCollections: () async throws -> Int
    let retryCollectionStatus: (UUID) async throws -> Void
    let makeDataManager: (() -> DataManager)?
    let discovery: () throws -> DiscoveryService
    let makeSearch: () -> BrowseSearchService
    let downloads: () throws -> DownloadService
    let playbackHistory: () throws -> PlaybackHistoryStore
    let resumePlayback: (PlaybackHistoryEntry) async throws -> Void
    let enabledSourceIDs: () -> Set<String>
    let actions: WorkspaceFixedActions
    let layoutStore: WorkspaceStore
    let registry: WorkspaceRegistry
    let sessionState: WorkspaceSessionState
    let skinAppearance: SkinAppearance
    let capabilityEnabled: (WorkspaceCapability) -> Bool
    let setCapabilityEnabled: (WorkspaceCapability, Bool) async throws -> Void
    let makeProductPanel: (WorkspaceComponentID, UUID, SkinAppearance, Bool) -> NSViewController

    init(
        favorites: FavoriteLibrary, actions: WorkspaceFixedActions, layoutStore: WorkspaceStore,
        loadOnlineCollections: @escaping () async throws -> Int,
        retryCollectionStatus: @escaping (UUID) async throws -> Void,
        makeDataManager: (() -> DataManager)? = nil,
        registry: WorkspaceRegistry = .builtins,
        sessionState: WorkspaceSessionState,
        skinAppearance: SkinAppearance = SkinAppearance(),
        capabilityEnabled: @escaping (WorkspaceCapability) -> Bool,
        setCapabilityEnabled: @escaping (WorkspaceCapability, Bool) async throws -> Void,
        discovery: @escaping () throws -> DiscoveryService,
        makeSearch: @escaping () -> BrowseSearchService,
        downloads: @escaping () throws -> DownloadService,
        playbackHistory: @escaping () throws -> PlaybackHistoryStore,
        resumePlayback: @escaping (PlaybackHistoryEntry) async throws -> Void,
        enabledSourceIDs: @escaping () -> Set<String>,
        makeProductPanel: @escaping (WorkspaceComponentID, UUID, SkinAppearance, Bool) -> NSViewController
    ) {
        self.favorites = favorites
        self.loadOnlineCollections = loadOnlineCollections
        self.retryCollectionStatus = retryCollectionStatus
        self.makeDataManager = makeDataManager
        self.actions = actions
        self.layoutStore = layoutStore
        self.registry = registry
        self.sessionState = sessionState
        self.skinAppearance = skinAppearance
        self.capabilityEnabled = capabilityEnabled
        self.setCapabilityEnabled = setCapabilityEnabled
        self.discovery = discovery
        self.makeSearch = makeSearch
        self.downloads = downloads
        self.playbackHistory = playbackHistory
        self.resumePlayback = resumePlayback
        self.enabledSourceIDs = enabledSourceIDs
        self.makeProductPanel = makeProductPanel
    }
}

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSPopoverDelegate {
    private let dependencies: WorkspaceWindowDependencies
    private let bookmarkDataManager: DataManager?
    private var layout: WorkspaceLayout
    private let host = WorkspaceSkinHostView()
    private var sidebarWidth: CGFloat = 188
    private var activePages: [WorkspacePage] = []
    private var componentControllers: [UUID: WorkspaceFavoritePanelController] = [:]
    private var serviceControllers: [UUID: WorkspaceServicePanelController] = [:]
    private var productControllers: [UUID: NSViewController] = [:]
    // Settings are global, not a per-layout-instance owner. Keep state when the
    // trusted recovery entrance replaces a hidden or removed settings component.
    private var settingsController: NSViewController?
    private var panelVisibility: [ObjectIdentifier: Bool] = [:]
    private var navigationHistory: [UUID] = []
    private let globalSearch = WorkspaceSkinSearchField()
    private let calendarButton = WorkspaceSkinButton()
    private let calendarPopover = NSPopover()
    private var calendarController: WorkspaceServicePanelController?
    private var calendarKeyMonitor: Any?
    private var containerViews: [UUID: NSView] = [:]
    private var selectedPageID: UUID?
    private var renderedPageID: UUID?
    private weak var pageMotionView: NSView?
    private var detailTransition: WorkspaceDetailTransitionOverlay?
    private var preparingDetailTransition = false
    private var fixedPage: WorkspacePage?
    private var recoveryPages: [UUID: WorkspacePage] = [:]
    private let fixedPages = WorkspaceBuiltinLayouts.makeDefault().pages
    private var loadFailureReason: String?
    private let capabilityMenu = NSMenu(title: String(localized: "功能"))
    private let layoutUndoManager = UndoManager()
    private var layoutEditor: WorkspaceLayoutEditorController?
    private var editorPreviewPages: [WorkspacePage]?
    private var previewButtons: [NSButton] = []
    private let previewDetails = NSStackView()
    private weak var embeddedPreviewHost: NSView?
    private var embeddedPreviewContent: NSView?
    private var embeddedPreviewConstraints: [NSLayoutConstraint] = []
    private weak var previewToolbar: NSView?
    private var editorSelectionID: UUID?
    private var editorSelectionViews: [UUID: WorkspaceEditorSelectionView] = [:]
    private var activeEditorDragSource: WorkspaceEditorSelectionView?
    var onEditorSelection: ((UUID) -> Void)?
    var onEditorResize: ((UUID, WorkspaceSize) -> Void)?
    var onEditorMove: ((UUID, UUID, Bool) -> Void)?
    private var isLayoutEditorPreview: Bool { previewOnly && embeddedPreviewContent != nil }
    var onEditorSplitChange: ((UUID, Double) -> Void)? {
        didSet { previewButtons.forEach { $0.isHidden = onEditorSplitChange != nil } }
    }
    private var previewDecision: Bool?

    private let previewOnly: Bool

    init(dependencies: WorkspaceWindowDependencies, previewLayout: WorkspaceLayout? = nil) {
        self.dependencies = dependencies
        previewOnly = previewLayout != nil
        bookmarkDataManager = previewLayout == nil ? dependencies.makeDataManager?() : nil
        if let previewLayout {
            layout = previewLayout
        } else {
            switch dependencies.layoutStore.load() {
            case .loaded(let value): layout = value
            case .recoveredDefault(let value, let reason):
                layout = value
                loadFailureReason = reason
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = previewOnly ? String(localized: "IINA-ANI — 預覽") : "IINA-ANI"
        window.contentMinSize = NSSize(width: 960, height: 640)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        host.skinAppearance = dependencies.skinAppearance
        host.bindSkin(dependencies.skinAppearance, slot: "background")
        buildShell()
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        if isLayoutEditorPreview {
            embeddedPreviewHost?.layoutSubtreeIfNeeded()
            renderForCurrentWidth()
            return
        }
        super.showWindow(sender)
        window?.layoutIfNeeded()
        renderForCurrentWidth()
    }

    func showWorkspace() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func focusSearch() {
        guard !previewOnly else { return }
        showFixedPage(WorkspacePageID.search)
        guard let page = activePages.first(where: { $0.id == selectedPageID }) else { return }
        let types = WorkspaceLayoutTraversal.componentTypes(in: WorkspaceLayout(pages: [page]))
        if let id = types.first(where: { $0.value == "search.results" })?.key { serviceControllers[id]?.focusSearch() }
    }

    func showTasks() { guard !previewOnly else { return }; showFixedPage(WorkspacePageID.downloads) }
    @objc func showFollowedVideos(_ sender: Any? = nil) {
        showVideoBrowsePage(componentID: "discovery.followed",
                         pageID: UUID(uuidString: "00000000-0000-4000-8000-000000000008")!,
                         title: String(localized: "Bilibili 關注動態（固定入口）"))
    }
    @objc func showBilibiliRecommendations(_ sender: Any? = nil) {
        showVideoBrowsePage(componentID: "discovery.bilibiliRecommendations",
                         pageID: UUID(uuidString: "00000000-0000-4000-8000-000000000009")!,
                         title: String(localized: "Bilibili 推薦影片"))
    }
    @objc func showYouTube(_ sender: Any? = nil) {
        showVideoBrowsePage(componentID: "discovery.youtube",
                            pageID: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!,
                            title: "YouTube")
    }
    private func showVideoBrowsePage(componentID: WorkspaceComponentID, pageID id: UUID, title: String) {
        guard !previewOnly else { return }
        let pages = displayPages(for: host.bounds.width)
        for page in pages {
            if let id = WorkspaceLayoutTraversal.componentTypes(in: WorkspaceLayout(pages: [page]))
                .first(where: { $0.value == componentID })?.key, !layout.collapsedInstanceIDs.contains(id) {
                rememberNavigation(to: page.id); selectedPageID = page.id; renderPages(pages); return
            }
        }
        let page = recoveryPages[id] ?? WorkspacePage(id: id, title: title,
            root: .component(id: UUID(), componentID: componentID, contractVersion: 1, parameters: [:],
                size: WorkspaceSize(width: 760, height: 640)))
        rememberNavigation(to: id); fixedPage = page; recoveryPages[id] = page; selectedPageID = id
        renderPages(displayPages(for: host.bounds.width))
    }
    func showDetail(settings: WorkspaceDetailTransitionSettings, source: WorkspaceCoverTransitionSource? = nil,
                    _ action: (WorkspaceDetailController) -> Void) {
        detailTransition?.finish()
        let source = source ?? dependencies.actions.transitionSource
        let animated = settings.style != .none && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let snapshot = animated ? WorkspaceDetailTransitionOverlay.snapshot(of: host, excluding: source) : nil
        preparingDetailTransition = true
        defer { preparingDetailTransition = false }
        // A calendar source may belong to a separate popover window; its screen frame was captured above.
        calendarPopover.performClose(nil)
        guard let detail = showProduct("detail.media") as? WorkspaceDetailController else { return }
        action(detail)
        detail.prepareTransitionCover(source?.image)
        host.layoutSubtreeIfNeeded()
        detail.view.layoutSubtreeIfNeeded()
        pageMotionView?.layer?.removeAnimation(forKey: "workspace.pageMotion")
        guard let snapshot else { return }
        let overlay = WorkspaceDetailTransitionOverlay(frame: host.bounds, snapshot: snapshot)
        detailTransition = overlay
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.play(source: source, destination: detail.transitionCover, settings: settings) { [weak self, weak overlay] in
            guard self?.detailTransition === overlay else { return }
            self?.detailTransition = nil
        }
    }

    func showProduct(_ type: WorkspaceComponentID) -> NSViewController? {
        guard !previewOnly else { return nil }
        func find(_ node: WorkspaceNode) -> UUID? {
            if case .component(let id, let candidate, _, _, _) = node, candidate == type { return id }
            switch node {
            case .grid(_, let children), .horizontalStack(_, let children), .verticalStack(_, let children), .group(_, let children):
                return children.compactMap(find).first
            case .split(_, let first, let second, _): return find(first) ?? find(second)
            case .tabs(_, _, let pages): return pages.compactMap { find($0.root) }.first
            default: return nil
            }
        }
        func reveal(_ node: WorkspaceNode, instanceID: UUID) -> Bool {
            switch node {
            case .component(let id, _, _, _, _): return id == instanceID
            case .tabs(let id, _, let pages):
                for page in pages where reveal(page.root, instanceID: instanceID) {
                    if let tabs = containerViews[id] as? WorkspaceRetainedTabView,
                       let item = tabs.tabViewItems.first(where: { $0.identifier as? String == page.id.uuidString }) {
                        tabs.suppressMotion = preparingDetailTransition
                        tabs.selectTabViewItem(item)
                        tabs.suppressMotion = false
                    }
                    return true
                }
                return false
            case .grid(_, let children), .horizontalStack(_, let children), .verticalStack(_, let children), .group(_, let children):
                return children.contains { reveal($0, instanceID: instanceID) }
            case .split(_, let first, let second, _): return reveal(first, instanceID: instanceID) || reveal(second, instanceID: instanceID)
            default: return false
            }
        }
        let pages = displayPages(for: host.bounds.width)
        let preferred = pages.first { $0.id == selectedPageID }
        if let page = ([preferred].compactMap { $0 } + pages).first(where: { find($0.root) != nil }), let id = find(page.root), !layout.collapsedInstanceIDs.contains(id) {
            rememberNavigation(to: page.id)
            selectedPageID = page.id
            renderPages(pages)
            _ = reveal(page.root, instanceID: id)
            host.layoutSubtreeIfNeeded()
            synchronizePanelVisibility()
            if type.rawValue == "settings.preferences" { return settingsController }
            if let controller = productControllers[id] { return controller }
        }
        let pageID = type.rawValue == "settings.preferences" ? WorkspacePageID.settings : type.rawValue == "torrent.import" ? WorkspacePageID.torrent : WorkspacePageID.detail
        showFixedPage(pageID)
        guard let fixedPage, let id = find(fixedPage.root) else { return nil }
        if type.rawValue == "settings.preferences" { return settingsController }
        return productControllers[id]
    }
    private func rememberNavigation(to id: UUID) {
        if let selectedPageID, selectedPageID != id { navigationHistory.append(selectedPageID) }
    }
    @objc private func goBack() {
        detailTransition?.finish()
        if detailForBackNavigation()?.goBackInInformation() == true { return }
        guard let id = navigationHistory.popLast() else { return }
        selectedPageID = id
        renderPages(displayPages(for: host.bounds.width))
    }
    private func detailForBackNavigation() -> WorkspaceDetailController? {
        guard let window else { return nil }
        let visible = productControllers.values.compactMap { $0 as? WorkspaceDetailController }.filter {
            guard $0.isViewLoaded else { return false }
            return $0.view.window === window && !$0.view.isHiddenOrHasHiddenAncestor
                && !$0.view.visibleRect.isEmpty
        }
        if let responder = window.firstResponder {
            let focusedView = (responder as? NSTextView).flatMap {
                $0.isFieldEditor ? $0.delegate as? NSView : nil
            } ?? (responder as? NSView)
            if let focused = visible.first(where: { controller in
                responder === controller || focusedView.map {
                    $0 === controller.view || $0.isDescendant(of: controller.view)
                } == true
            }) { return focused }
        }
        return visible.count == 1 ? visible[0] : nil
    }
    var shareableLayout: WorkspaceLayout { layout }
    func presentNativePreview(_ candidate: WorkspaceLayout) -> WorkspaceWindowController {
        WorkspaceWindowController(dependencies: dependencies, previewLayout: candidate)
    }
    func presentNativePreview(_ candidate: WorkspaceLayout, appearance: SkinAppearance) -> WorkspaceWindowController {
        let copied = WorkspaceWindowDependencies(
            favorites: dependencies.favorites, actions: dependencies.actions, layoutStore: dependencies.layoutStore,
            loadOnlineCollections: dependencies.loadOnlineCollections,
            retryCollectionStatus: dependencies.retryCollectionStatus,
            registry: dependencies.registry, sessionState: dependencies.sessionState, skinAppearance: appearance,
            capabilityEnabled: dependencies.capabilityEnabled, setCapabilityEnabled: dependencies.setCapabilityEnabled,
            discovery: dependencies.discovery, makeSearch: dependencies.makeSearch, downloads: dependencies.downloads,
            playbackHistory: dependencies.playbackHistory, resumePlayback: dependencies.resumePlayback,
            enabledSourceIDs: dependencies.enabledSourceIDs, makeProductPanel: dependencies.makeProductPanel)
        return WorkspaceWindowController(dependencies: copied, previewLayout: candidate)
    }
    func embedLayoutEditorPreview(in host: NSView) {
        guard previewOnly, let window else { return }
        if embeddedPreviewHost === host { return }
        let content: NSView
        if let embeddedPreviewContent {
            content = embeddedPreviewContent
            NSLayoutConstraint.deactivate(embeddedPreviewConstraints)
            content.removeFromSuperview()
        } else {
            guard let windowContent = window.contentView else { return }
            content = windowContent
            window.orderOut(nil)
            window.contentView = nil
            content.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(embeddedPreviewDidResize(_:)),
                name: NSView.frameDidChangeNotification, object: content)
        }
        embeddedPreviewHost = host
        embeddedPreviewContent = content
        previewToolbar?.isHidden = true
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        embeddedPreviewConstraints = [
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ]
        NSLayoutConstraint.activate(embeddedPreviewConstraints)
        host.layoutSubtreeIfNeeded()
        activePages = []
        renderForCurrentWidth()
    }

    func highlightEditorSelection(_ id: UUID?) {
        guard previewOnly, editorSelectionID != id else { return }
        if let previous = editorSelectionID { editorSelectionViews[previous]?.isSelected = false }
        editorSelectionID = id
        if let id { editorSelectionViews[id]?.isSelected = true }
    }

    @objc private func embeddedPreviewDidResize(_ notification: Notification) {
        guard isLayoutEditorPreview else { return }
        embeddedPreviewContent?.layoutSubtreeIfNeeded()
        renderForCurrentWidth()
    }

    override func close() {
        if isLayoutEditorPreview { tearDownWorkspace() }
        super.close()
    }

    func updateNativePreview(_ candidate: WorkspaceLayout, pageID: UUID?, breakpoint: WorkspaceBreakpoint?, usesWindowBreakpoints: Bool = false) {
        guard previewOnly else { return }
        let previewPages = usesWindowBreakpoints ? nil : (breakpoint.flatMap { candidate.breakpointLayouts[$0] } ?? candidate.pages)
        if !isLayoutEditorPreview || layout != candidate || editorPreviewPages != previewPages {
            activePages = []
        }
        layout = candidate
        editorPreviewPages = previewPages
        if let pageID { selectedPageID = pageID }
        renderForCurrentWidth()
    }
    func previewPageMotion(_ motion: WorkspacePageMotion, pageID: UUID? = nil) {
        guard previewOnly else { return }
        if let pageID, pageID != selectedPageID {
            for tabs in containerViews.values.compactMap({ $0 as? WorkspaceRetainedTabView }) {
                if tabs.previewMotion(motion, pageID: pageID) { return }
            }
        }
        guard let pageMotionView else { return }
        host.layoutSubtreeIfNeeded()
        WorkspacePageAnimator.play(dependencies.skinAppearance.resolvedPageMotion(motion), on: pageMotionView)
    }

    func setNativePreviewApplyTitle(_ title: String) {
        guard previewOnly, let button = previewButtons.first(where: { $0.action == #selector(acceptPreview) }) else { return }
        button.title = title
        button.setAccessibilityLabel(title)
    }
    func setNativePreviewDetails(_ view: NSView) {
        guard previewOnly else { return }
        previewDetails.arrangedSubviews.forEach { $0.removeFromSuperview() }
        previewDetails.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: previewDetails.widthAnchor).isActive = true
        previewDetails.isHidden = false
    }
    @discardableResult
    func beginLayoutEditing() -> WorkspaceLayoutEditorController? {
        guard !previewOnly else { return nil }
        if let layoutEditor, layoutEditor.window?.isVisible == true {
            layoutEditor.showEditor()
            return layoutEditor
        }
        let baseline = layout
        let editor = WorkspaceLayoutEditorController(layout: layout, registry: dependencies.registry,
            initialWidth: Double(host.bounds.width), initialPageID: selectedPageID,
            makePreview: { [unowned self] in self.presentNativePreview($0) },
            commit: { [unowned self] next in
                guard self.layout == baseline else {
                    throw NSError(domain: "WorkspaceLayoutEditor", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        String(localized: "已保存的工作區在編輯期間已變更；草稿未覆寫新版本。請取消後重新進入編輯。")] )
                }
                try self.applyLayout(next)
            })
        layoutEditor?.close()
        layoutEditor = editor
        editor.showEditor()
        return editor
    }
    func reviewNativePreview() -> Bool {
        guard previewOnly, let window else { return false }
        previewDecision = nil
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: window)
        let accepted = response == .OK && previewDecision == true
        previewDecision = nil
        return accepted
    }
    @objc private func acceptPreview() {
        guard previewOnly else { return }
        previewDecision = true
        NSApp.stopModal(withCode: .OK)
    }
    @objc private func cancelPreview() {
        guard previewOnly else { return }
        previewDecision = false
        NSApp.stopModal(withCode: .cancel)
    }
    func restoreDefaults() { guard !previewOnly else { return }; restoreBuiltinLayout() }

    private func showFixedPage(_ id: UUID) {
        if let page = displayPages(for: host.bounds.width).first(where: { $0.id == id }),
           !WorkspaceLayoutTraversal.componentInstanceIDs(in: WorkspaceLayout(pages: [page])).contains(where: { layout.collapsedInstanceIDs.contains($0) }) {
            rememberNavigation(to: id)
            selectedPageID = id
            renderPages(displayPages(for: host.bounds.width))
            return
        }
        // Fixed command targets exist even after a custom layout removes every corresponding panel.
        guard var page = fixedPages.first(where: { $0.id == id }) else { return }
        page.title = String(localized: "\(page.displayTitle)（固定入口）")
        rememberNavigation(to: page.id)
        fixedPage = page
        recoveryPages[page.id] = page
        selectedPageID = page.id
        renderPages(displayPages(for: host.bounds.width))
    }

    func moveComponent(_ instanceID: UUID, to pageID: UUID) throws {
        try applyLayout(WorkspaceTransaction.move(instanceID: instanceID, to: pageID, in: layout))
    }
    func copyComponent(_ instanceID: UUID, to pageID: UUID) throws {
        try applyLayout(WorkspaceTransaction.copy(instanceID: instanceID, to: pageID, in: layout))
    }
    func removeComponent(_ instanceID: UUID) throws {
        try applyLayout(WorkspaceTransaction.remove(instanceID: instanceID, from: layout))
    }

    func applyLayout(_ next: WorkspaceLayout) throws {
        guard !previewOnly else { return }
        let previous = layout
        let previousTypes = WorkspaceLayoutTraversal.componentTypes(in: layout)
        for (id, type) in WorkspaceLayoutTraversal.componentTypes(in: next) {
            if let previous = previousTypes[id], previous != type {
                throw WorkspaceValidationError.inconsistentInstance(id)
            }
        }
        try dependencies.layoutStore.save(next)
        // The store validates and atomically replaces the committed document before rendering.
        layout = next
        fixedPage = nil
        recoveryPages.removeAll()
        detachRemovedComponents()
        containerViews.removeAll()
        activePages = []
        renderForCurrentWidth()
        let undoManager = layoutUndoManager
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            do { try target.applyLayout(previous) } catch { target.presentPersistenceError(error) }
        }
        undoManager.setActionName(String(localized: "套用工作區佈局"))
        undoManager.endUndoGrouping()
        try dependencies.sessionState.retainInstances(in: next)
    }

    func restoreBuiltinLayout() {
        do { try applyLayout(WorkspaceBuiltinLayouts.makeDefault()) } catch {
            presentPersistenceError(error)
        }
    }

    func windowWillClose(_ notification: Notification) {
        detailTransition?.finish()
        if previewOnly, NSApp.modalWindow === window { NSApp.stopModal(withCode: .cancel) }
        tearDownWorkspace()
    }

    private func tearDownWorkspace() {
        if let content = embeddedPreviewContent {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: content)
            NSLayoutConstraint.deactivate(embeddedPreviewConstraints)
            embeddedPreviewConstraints = []
            content.removeFromSuperview()
            embeddedPreviewContent = nil
            embeddedPreviewHost = nil
        }
        editorSelectionViews.removeAll()
        editorSelectionID = nil
        layoutEditor?.close()
        calendarPopover.performClose(nil)
        calendarController?.detach()
        // Closing a window releases only its query/subscription owners, never the underlying tasks.
        componentControllers.values.forEach { $0.detach() }
        serviceControllers.values.forEach { $0.detach() }
        (productControllers.values.compactMap { $0 as? WorkspaceDetachablePanel }).forEach { $0.detach() }
        (settingsController as? WorkspaceDetachablePanel)?.detach()
        panelVisibility.removeAll()
        // Settled state survives closing; detach cancels screen-owned work.
        for id in Array(productControllers.keys) where productControllers[id] is WorkspaceTorrentController {
            productControllers.removeValue(forKey: id)
        }
        containerViews.removeAll()
        host.subviews.forEach { $0.removeFromSuperview() }
        activePages = []
        renderedPageID = nil
    }

    func windowDidResize(_ notification: Notification) {
        detailTransition?.finish()
        renderForCurrentWidth()
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let page = activePages.first(where: { $0.id == selectedPageID }) else { return layoutUndoManager }
        let ids = WorkspaceLayoutTraversal.componentInstanceIDs(in: WorkspaceLayout(pages: [page]))
        return ids.compactMap { componentControllers[$0]?.favoriteUndoManager }.first ?? layoutUndoManager
    }
    @objc func reload(_ sender: Any?) {
        guard !previewOnly, let page = activePages.first(where: { $0.id == selectedPageID }) else { return }
        let ids = WorkspaceLayoutTraversal.componentInstanceIDs(in: WorkspaceLayout(pages: [page]))
        for id in ids {
            componentControllers[id]?.reload(sender)
            serviceControllers[id]?.reload(sender)
        }
    }

    private func buildShell() {
        guard let content = window?.contentView else { return }
        let shell = NSStackView()
        shell.orientation = .vertical
        shell.distribution = .gravityAreas
        shell.spacing = 0
        shell.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(shell)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            shell.topAnchor.constraint(equalTo: content.topAnchor),
            shell.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let toolbar = NSStackView()
        if previewOnly { previewToolbar = toolbar }
        toolbar.orientation = .horizontal
        toolbar.distribution = .fill
        toolbar.bindSkin(dependencies.skinAppearance, slot: "toolbar")
        toolbar.spacing = 12
        toolbar.alignment = .centerY
        toolbar.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        func actionGroup() -> NSStackView {
            let group = NSStackView()
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 6
            group.setHuggingPriority(.required, for: .horizontal)
            return group
        }
        func actionButton(_ title: String, action: Selector, icon: WorkspaceIcon, iconOnly: Bool = false) -> WorkspaceSkinButton {
            let button = WorkspaceSkinButton(title: iconOnly ? "" : title, target: self, action: action)
            button.functionIconPosition = iconOnly ? .imageOnly : .imageLeading
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.setFunctionIcon(icon)
            button.bezelStyle = .rounded
            button.bindSkin(dependencies.skinAppearance, slot: "navigation")
            button.updateSkinState()
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            if iconOnly { button.widthAnchor.constraint(equalToConstant: 36).isActive = true }
            return button
        }
        if !previewOnly {
            let brand = NSStackView()
            brand.alignment = .centerY
            brand.spacing = 9
            let mark = NSImageView(image: WorkspaceIcon.play.image(size: 22) ?? NSImage())
            mark.contentTintColor = .labelColor
            mark.setAccessibilityElement(false)
            let name = NSTextField(labelWithString: "IINA-ANI")
            name.bindSkin(dependencies.skinAppearance, slot: "brand")
            brand.addArrangedSubview(mark)
            brand.addArrangedSubview(name)
            brand.addArrangedSubview(NSView())
            brand.widthAnchor.constraint(equalToConstant: 156).isActive = true
            toolbar.addArrangedSubview(brand)
        }
        if previewOnly {
            let previewActions = actionGroup()
            let accept = actionButton(String(localized: "套用此佈局"), action: #selector(acceptPreview), icon: .check)
            let cancel = actionButton(String(localized: "取消"), action: #selector(cancelPreview), icon: .close)
            cancel.keyEquivalent = "\u{1b}"
            previewButtons = [accept, cancel]
            previewActions.addArrangedSubview(accept)
            previewActions.addArrangedSubview(cancel)
            toolbar.addArrangedSubview(previewActions)
            toolbar.addArrangedSubview(NSView())
        } else {
            let searchActions = actionGroup()
            searchActions.spacing = 8
            searchActions.setHuggingPriority(.defaultLow, for: .horizontal)
            searchActions.addArrangedSubview(actionButton(String(localized: "返回"), action: #selector(goBack), icon: .back, iconOnly: true))
            globalSearch.placeholderString = String(localized: "搜尋作品、影片、網址或 magnet")
            globalSearch.target = self
            globalSearch.action = #selector(submitGlobalSearch)
            globalSearch.setAccessibilityLabel(String(localized: "全域搜尋或開啟網址"))
            globalSearch.bindSkin(dependencies.skinAppearance, slot: "search")
            globalSearch.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            globalSearch.heightAnchor.constraint(equalToConstant: 36).isActive = true
            globalSearch.setContentHuggingPriority(.defaultLow, for: .horizontal)
            searchActions.addArrangedSubview(globalSearch)
            searchActions.addArrangedSubview(actionButton(String(localized: "開啟"), action: #selector(openAction), icon: .openLink, iconOnly: true))
            toolbar.addArrangedSubview(searchActions)
        }
        let capabilities = NSPopUpButton(frame: .zero, pullsDown: true)
        capabilityMenu.autoenablesItems = false
        capabilityMenu.addItem(withTitle: String(localized: "功能"), action: nil, keyEquivalent: "")
        for capability in WorkspaceCapability.allCases {
            let item = NSMenuItem(
                title: capability.title, action: #selector(toggleCapability(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = capability.rawValue
            item.toolTip = capability.disableUnavailableReason
            item.isEnabled = capability.canDisable
            capabilityMenu.addItem(item)
        }
        let followed = NSMenuItem(title: String(localized: "Bilibili 關注動態"), action: #selector(showFollowedVideos(_:)), keyEquivalent: "")
        followed.target = self; capabilityMenu.addItem(followed)
        let recommended = NSMenuItem(title: String(localized: "Bilibili 推薦影片"), action: #selector(showBilibiliRecommendations(_:)), keyEquivalent: "")
        recommended.target = self; capabilityMenu.addItem(recommended)
        let youtube = NSMenuItem(title: "YouTube", action: #selector(showYouTube(_:)), keyEquivalent: "")
        youtube.target = self; capabilityMenu.addItem(youtube)
        capabilities.isEnabled = !previewOnly
        if previewOnly {
            let notice = NSTextField(labelWithString: String(localized: "安全預覽 — 服務已隔離，業務控制項不可操作"))
            notice.textColor = .secondaryLabelColor
            notice.alignment = .center
            shell.addArrangedSubview(notice)
            previewDetails.orientation = .vertical
            previewDetails.isHidden = true
            shell.addArrangedSubview(previewDetails)
            previewDetails.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
        }
        capabilities.menu = capabilityMenu
        capabilities.bindSkin(dependencies.skinAppearance, slot: "navigation")
        capabilities.heightAnchor.constraint(equalToConstant: 36).isActive = true
        calendarButton.title = String(localized: "日曆")
        calendarButton.setFunctionIcon(.calendar)
        calendarButton.bezelStyle = .rounded
        calendarButton.target = self
        calendarButton.action = #selector(toggleCalendar(_:))
        calendarButton.setAccessibilityLabel(String(localized: "開啟 Bangumi 日曆"))
        calendarButton.isEnabled = !previewOnly
        calendarButton.bindSkin(dependencies.skinAppearance, slot: "navigation")
        calendarButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let activityActions = actionGroup()
        activityActions.addArrangedSubview(calendarButton)
        if !previewOnly {
            activityActions.addArrangedSubview(actionButton(String(localized: "活動任務"), action: #selector(tasksAction), icon: .downloads, iconOnly: true))
        }
        toolbar.addArrangedSubview(activityActions)
        let groupDivider = NSBox()
        groupDivider.boxType = .separator
        groupDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        groupDivider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        toolbar.addArrangedSubview(groupDivider)
        let configurationActions = actionGroup()
        if !previewOnly {
            let layoutButton = actionButton(String(localized: "編輯佈局"), action: #selector(editLayoutAction), icon: .layout)
            layoutButton.title = String(localized: "佈局")
            configurationActions.addArrangedSubview(layoutButton)
        }
        configurationActions.addArrangedSubview(capabilities)
        toolbar.addArrangedSubview(configurationActions)
        if !previewOnly { updateCapabilityMenu() }
        toolbar.setHuggingPriority(.required, for: .vertical)
        shell.addArrangedSubview(toolbar)
        toolbar.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
        if let loadFailureReason {
            let recovery = NSTextField(
                wrappingLabelWithString: String(localized: "工作區無法讀取，已使用內建佈局；原檔保留供修復。\n\(loadFailureReason)"))
            recovery.textColor = .systemOrange
            shell.addArrangedSubview(recovery)
        }
        let divider = NSBox()
        divider.boxType = .separator
        shell.addArrangedSubview(divider)
        host.translatesAutoresizingMaskIntoConstraints = false
        shell.addArrangedSubview(host)
        host.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
        host.bottomAnchor.constraint(equalTo: shell.bottomAnchor).isActive = true
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func searchAnimeTitle(_ title: String) {
        guard !previewOnly else { return }
        globalSearch.stringValue = title
        focusSearch()
        guard let page = activePages.first(where: { $0.id == selectedPageID }) else { return }
        let types = WorkspaceLayoutTraversal.componentTypes(in: WorkspaceLayout(pages: [page]))
        if let id = types.first(where: { $0.value == "search.results" })?.key {
            serviceControllers[id]?.submitAnimeTitle(title)
        }
    }

    @objc private func submitGlobalSearch() {
        guard !previewOnly else { return }
        focusSearch()
        guard let page = activePages.first(where: { $0.id == selectedPageID }) else { return }
        let types = WorkspaceLayoutTraversal.componentTypes(in: WorkspaceLayout(pages: [page]))
        if let id = types.first(where: { $0.value == "search.results" })?.key { serviceControllers[id]?.submitSearch(globalSearch.stringValue) }
    }

    @objc private func openAction() { guard !previewOnly else { return }; dependencies.actions.open() }
    @objc private func tasksAction() { showTasks() }

    @objc private func editLayoutAction() { beginLayoutEditing() }

    @objc private func toggleCalendar(_ sender: NSButton) {
        guard !previewOnly, dependencies.capabilityEnabled(.schedule) else { return }
        if calendarPopover.isShown { calendarPopover.performClose(nil); return }
        let controller = calendarController ?? WorkspaceServicePanelController(
            instanceID: UUID(), componentID: "discovery.schedule", dependencies: dependencies)
        calendarController = controller
        controller.attach()
        controller.view.setFrameSize(NSSize(width: 1100, height: 620))
        calendarPopover.contentViewController = controller
        calendarPopover.contentSize = NSSize(width: 1100, height: 620)
        calendarPopover.behavior = .transient
        calendarPopover.delegate = self
        calendarPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        calendarKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.calendarPopover.isShown else { return event }
            self.calendarPopover.performClose(nil)
            return nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        calendarController?.detach()
        if let calendarKeyMonitor { NSEvent.removeMonitor(calendarKeyMonitor) }
        calendarKeyMonitor = nil
    }

    private func updateCapabilityMenu() {
        calendarButton.isEnabled = !previewOnly && dependencies.capabilityEnabled(.schedule)
        if !calendarButton.isEnabled { calendarPopover.performClose(nil) }
        for item in capabilityMenu.items {
            guard let raw = item.representedObject as? String,
                let capability = WorkspaceCapability(rawValue: raw)
            else { continue }
            item.state = dependencies.capabilityEnabled(capability) ? .on : .off
        }
    }

    @objc private func toggleCapability(_ sender: NSMenuItem) {
        guard !previewOnly else { return }
        guard let raw = sender.representedObject as? String,
            let capability = WorkspaceCapability(rawValue: raw)
        else {
            return
        }
        sender.isEnabled = false
        let enabled = !dependencies.capabilityEnabled(capability)
        Task { [weak self] in
            guard let self else { return }
            defer {
                sender.isEnabled = capability.canDisable
                self.updateCapabilityMenu()
            }
            do {
                try await self.dependencies.setCapabilityEnabled(capability, enabled)
                self.serviceControllers.values.forEach { $0.capabilitiesDidChange() }
                self.calendarController?.capabilitiesDidChange()
                self.renderedPageID = nil
                self.renderPages(self.displayPages(for: self.host.bounds.width))
            } catch { self.presentPersistenceError(error) }
        }
    }

    private func displayPages(for width: CGFloat) -> [WorkspacePage] {
        let pages = (editorPreviewPages ?? WorkspaceLayoutTraversal.pages(forWidth: width, in: layout))
            .filter { !layout.hiddenPageIDs.contains($0.id) }
        return pages.filter { recoveryPages[$0.id] == nil } + recoveryPages.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func renderForCurrentWidth() {
        guard host.bounds.width > 0 else { return }
        let pages = displayPages(for: host.bounds.width)
        guard activePages != pages || renderedPageID != selectedPageID || host.subviews.isEmpty else { return }
        renderPages(pages)
    }

    private func renderPages(_ pages: [WorkspacePage]) {
        guard activePages != pages || renderedPageID != selectedPageID || host.subviews.isEmpty else { return }
        detailTransition?.finish()
        let previousMotion = activePages.first(where: { $0.id == renderedPageID })?.motion
        activePages = pages
        if !pages.contains(where: { $0.id == selectedPageID }) {
            selectedPageID = pages.first(where: { $0.id == layout.homePageID })?.id ?? pages.first?.id
        }
        host.subviews.forEach { $0.removeFromSuperview() }
        editorSelectionViews.removeAll()
        let shell = NSStackView()
        shell.orientation = .horizontal
        shell.distribution = .fill
        shell.spacing = 0
        shell.translatesAutoresizingMaskIntoConstraints = false
        var navigationView: NSView?
        var updateNavigation: ((CGFloat) -> Void)?
        if pages.count > 1 {
            let nav = NSStackView()
            nav.orientation = .vertical
            nav.alignment = .leading
            nav.bindSkin(dependencies.skinAppearance, slot: "sidebar")
            nav.spacing = 6
            var navigationButtons: [(WorkspaceNavigationButton, WorkspaceIcon, NSLayoutConstraint)] = []
            nav.edgeInsets = NSEdgeInsets(top: 24, left: 12, bottom: 18, right: 12)
            let navigationLabel = NSTextField(labelWithString: String(localized: "導覽"))
            navigationLabel.bindSkin(dependencies.skinAppearance, slot: "sectionLabel")
            nav.addArrangedSubview(navigationLabel)
            navigationLabel.widthAnchor.constraint(equalTo: nav.widthAnchor, constant: -24).isActive = true
            nav.setCustomSpacing(14, after: navigationLabel)
            for page in pages where !layout.hiddenPageIDs.contains(page.id) {
                if page.id == WorkspacePageID.settings && page.id == pages.last?.id {
                    let spacer = NSView()
                    spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
                    nav.addArrangedSubview(spacer)
                }
                let button = WorkspaceNavigationButton(
                    title: page.displayTitle, target: self, action: #selector(selectPage(_:)))
                let icons: [UUID: WorkspaceIcon] = [
                    WorkspacePageID.discover: .discover, WorkspacePageID.search: .search,
                    WorkspacePageID.favorites: .favorites, WorkspacePageID.downloads: .downloads,
                    WorkspacePageID.detail: .work, WorkspacePageID.settings: .settings,
                    WorkspacePageID.torrent: .torrent,
                ]
                button.functionIconPosition = .imageLeading
                button.setFunctionIcon(icons[page.id] ?? .layout, size: 18)
                button.identifier = NSUserInterfaceItemIdentifier(page.id.uuidString)
                button.bezelStyle = .regularSquare
                button.imageScaling = .scaleNone
                button.imageHugsTitle = true
                button.alignment = .left
                button.lineBreakMode = .byTruncatingTail
                button.toolTip = page.displayTitle
                let rowHeight = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
                rowHeight.isActive = true
                navigationButtons.append((button, icons[page.id] ?? .layout, rowHeight))
                button.state = page.id == selectedPageID ? .on : .off
                button.setAccessibilityValue(page.id == selectedPageID ? String(localized: "已選取") : String(localized: "未選取"))
                button.bindSkin(dependencies.skinAppearance, slot: "navigation")
                button.updateSkinState()
                nav.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: nav.widthAnchor, constant: -24).isActive = true
            }
            if pages.last?.id != WorkspacePageID.settings {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
                nav.addArrangedSubview(spacer)
            }
            let libraryNote = NSTextField(wrappingLabelWithString: String(localized: "每一部，都值得期待。"))
            libraryNote.bindSkin(dependencies.skinAppearance, slot: "subtitle")
            libraryNote.maximumNumberOfLines = 2
            nav.addArrangedSubview(libraryNote)
            libraryNote.widthAnchor.constraint(equalTo: nav.widthAnchor, constant: -24).isActive = true
            var compact: Bool?
            updateNavigation = { width in
                let next = width < 140
                guard compact != next else { return }
                compact = next
                navigationLabel.isHidden = next
                libraryNote.isHidden = next
                nav.edgeInsets = NSEdgeInsets(top: next ? 12 : 24, left: 12, bottom: 18, right: 12)
                for (button, icon, height) in navigationButtons {
                    button.functionIconPosition = next ? .imageAbove : .imageLeading
                    button.alignment = next ? .center : .left
                    button.setFunctionIcon(icon, size: next ? 32 : 18)
                    height.constant = next ? 68 : 44
                    button.updateSkinState()
                }
            }
            updateNavigation?(sidebarWidth)
            let navigationScroll = WorkspaceScrollView()
            navigationScroll.hasVerticalScroller = true
            navigationScroll.autohidesScrollers = true
            navigationScroll.scrollerStyle = .overlay
            navigationScroll.drawsBackground = false
            nav.translatesAutoresizingMaskIntoConstraints = false
            navigationScroll.documentView = nav
            let fitHeight = nav.heightAnchor.constraint(equalTo: navigationScroll.contentView.heightAnchor)
            fitHeight.priority = .defaultLow
            NSLayoutConstraint.activate([
                nav.widthAnchor.constraint(equalTo: navigationScroll.contentView.widthAnchor),
                nav.heightAnchor.constraint(greaterThanOrEqualTo: navigationScroll.contentView.heightAnchor),
                fitHeight,
            ])
            navigationView = navigationScroll
        }
        if let selected = pages.first(where: { $0.id == selectedPageID }) {
            let scroll = WorkspaceScrollView()
            pageMotionView = scroll
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let document = WorkspaceDocumentView()
            document.translatesAutoresizingMaskIntoConstraints = false
            for controller in serviceControllers.values { controller.setPageScrollOwner(nil) }
            let root = renderNode(selected.root)
            root.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(root)
            let discoveryIntro = selected.id == WorkspacePageID.discover && isDiscoveryFeedPage(selected.root)
                && !isLayoutEditorPreview
            let pageInset: CGFloat = discoveryIntro ? 18 : 0
            let introHeight: CGFloat = discoveryIntro ? 92 : 0
            if discoveryIntro {
                let intro = makeDiscoveryHeading(for: selected)
                intro.translatesAutoresizingMaskIntoConstraints = false
                document.addSubview(intro)
                NSLayoutConstraint.activate([
                    intro.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
                    intro.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
                    intro.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
                    intro.heightAnchor.constraint(equalToConstant: 56),
                ])
            }
            scroll.documentView = document
            if selected.id == WorkspacePageID.discover, isDiscoveryFeedPage(selected.root),
               case .verticalStack(_, let children) = selected.root {
                scroll.setAccessibilityLabel(String(localized: "主頁 · Trends、繼續觀看與推薦 · 共同捲動"))
                for child in children {
                    if case .component(let id, let type, _, _, let size) = child,
                       type != "discovery.feed" || size.height == dependencies.registry.descriptor(for: type)?.defaultSize.height {
                        serviceControllers[id]?.setPageScrollOwner(scroll)
                    }
                }
            }
            let minimum = extent(selected.root, requested: false)
            let requested = extent(selected.root, requested: true)
            let fitWidth = document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            fitWidth.priority = .defaultHigh
            let preferredWidth = document.widthAnchor.constraint(
                greaterThanOrEqualToConstant: requested.width + pageInset * 2)
            preferredWidth.priority = .defaultLow
            let preferredHeight = document.heightAnchor.constraint(
                greaterThanOrEqualToConstant: requested.height + introHeight)
            preferredHeight.priority = .defaultLow
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: pageInset),
                root.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -pageInset),
                root.topAnchor.constraint(equalTo: document.topAnchor, constant: introHeight),
                root.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                document.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum.width + pageInset * 2),
                document.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum.height + introHeight),
                document.heightAnchor.constraint(
                    greaterThanOrEqualTo: scroll.contentView.heightAnchor),
                fitWidth, preferredWidth, preferredHeight,
            ])
            let usesInternalScroll: Bool
            if case .component(_, let type, _, _, _) = selected.root {
                usesInternalScroll = type.rawValue == "settings.preferences"
            } else if case .verticalStack(_, let nodes) = selected.root {
                usesInternalScroll = hasColumnBody(nodes)
            } else {
                usesInternalScroll = isColumnComposition(selected.root)
            }
            if usesInternalScroll {
                // Column bodies and settings own their internal vertical scrolling.
                let fitHeight = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
                fitHeight.priority = .defaultHigh
                fitHeight.isActive = true
            }
            if let navigationView {
                let split = WorkspaceSidebarSplitView(
                    sidebar: navigationView, content: scroll, width: sidebarWidth)
                split.onWidthChange = { [weak self] width in
                    self?.sidebarWidth = width
                    updateNavigation?(width)
                }
                split.translatesAutoresizingMaskIntoConstraints = false
                shell.addArrangedSubview(split)
                split.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
                split.heightAnchor.constraint(equalTo: shell.heightAnchor).isActive = true
            } else {
                shell.addArrangedSubview(scroll)
                scroll.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
                scroll.heightAnchor.constraint(equalTo: shell.heightAnchor).isActive = true
            }
        } else {
            shell.addArrangedSubview(
                WorkspaceStatusView(title: String(localized: "沒有可見頁面"), detail: String(localized: "仍可使用固定搜尋、開啟、活動任務與恢復入口。")))
        }
        host.subviews.forEach { $0.removeFromSuperview() }
        host.addSubview(shell)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            shell.topAnchor.constraint(equalTo: host.topAnchor),
            shell.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        if !preparingDetailTransition, let selected = pages.first(where: { $0.id == selectedPageID }),
           let pageMotionView,
           renderedPageID != selectedPageID || previousMotion != selected.motion {
            WorkspacePageAnimator.play(dependencies.skinAppearance.pageMotion(for: selected), on: pageMotionView)
        }
        synchronizePanelVisibility()
        renderedPageID = selectedPageID
    }

    private func makeDiscoveryHeading(for page: WorkspacePage) -> NSView {
        let title = NSTextField(labelWithString: page.displayTitle)
        title.bindSkin(dependencies.skinAppearance, slot: "pageTitle")
        let subtitle = NSTextField(labelWithString: String(localized: "接著上次的故事，發現下一部喜歡的作品。"))
        subtitle.bindSkin(dependencies.skinAppearance, slot: "subtitle")
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 5
        let date = WorkspaceDateLabel()
        date.bindSkin(dependencies.skinAppearance, slot: "subtitle")
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [titles, NSView(), date])
        row.alignment = .centerY
        row.spacing = 16
        return row
    }

    // NSTabView removes inactive page views from the window. Reconcile after
    // insertion/selection, not while building every page (including inactive ones).
    private func synchronizePanelVisibility() {
        func synchronize(_ controller: NSViewController, panel: WorkspaceDetachablePanel) {
            let visible = controller.isViewLoaded && host.window != nil
                && controller.view.window === host.window
                && !controller.view.isHiddenOrHasHiddenAncestor
            let key = ObjectIdentifier(controller)
            guard panelVisibility[key] != visible else { return }
            panelVisibility[key] = visible
            if visible { panel.attach() } else { panel.detach() }
        }
        for controller in componentControllers.values { synchronize(controller, panel: controller) }
        for controller in serviceControllers.values { synchronize(controller, panel: controller) }
        for controller in productControllers.values {
            if let panel = controller as? WorkspaceDetachablePanel { synchronize(controller, panel: panel) }
        }
        if let controller = settingsController, let panel = controller as? WorkspaceDetachablePanel {
            synchronize(controller, panel: panel)
        }
    }

    private func isDiscoveryFeedPage(_ root: WorkspaceNode) -> Bool {
        guard case .verticalStack(_, let children) = root else { return false }
        return isDiscoveryFeedNodes(children)
    }

    private func isDiscoveryFeedNodes(_ nodes: [WorkspaceNode]) -> Bool {
        guard nodes.count == 2 || nodes.count == 3,
              case .component(_, let first, _, _, _) = nodes[0], first == "discovery.recommendations",
              case .component(_, let last, _, _, _) = nodes[nodes.count - 1], last == "discovery.feed" else { return false }
        if nodes.count == 2 { return true }
        guard case .component(_, let middle, _, _, _) = nodes[1] else { return false }
        return middle == "playback.continue"
    }

    private func isColumnComposition(_ node: WorkspaceNode) -> Bool {
        switch node {
        case .split: return true
        case .horizontalStack(_, let children): return children.count > 1
        default: return false
        }
    }

    private func hasColumnBody(_ nodes: [WorkspaceNode]) -> Bool {
        guard let body = nodes.last, isColumnComposition(body) else { return false }
        return nodes.dropLast().allSatisfy {
            if case .component = $0 { return true }
            return false
        }
    }

    @objc private func selectPage(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if id != fixedPage?.id { fixedPage = nil }
        rememberNavigation(to: id)
        selectedPageID = id
        renderPages(displayPages(for: host.bounds.width))
        if isLayoutEditorPreview {
            highlightEditorSelection(id)
            onEditorSelection?(id)
        }
    }

    private func renderNode(_ node: WorkspaceNode) -> NSView {
        let content = renderSizedNode(node)
        guard isLayoutEditorPreview else { return placeComponent(content, node: node) }
        let id = node.id
        let chrome = WorkspaceEditorSelectionView(id: id, title: editorTitle(for: node), content: content) { [weak self] in
            self?.highlightEditorSelection(id)
            self?.onEditorSelection?(id)
        }
        chrome.selectionButton.identifier = NSUserInterfaceItemIdentifier("workspace.editor.node.\(id.uuidString)")
        if case .component(_, _, _, _, let size) = node,
           !layout.collapsedInstanceIDs.contains(id) {
            chrome.requestedSize = size
            chrome.onResize = { [weak self] size in self?.onEditorResize?(id, size) }
        }
        chrome.onMove = { [weak self] source, after in self?.onEditorMove?(source, id, after) }
        chrome.onDragStateChange = { [weak self, weak chrome] active in
            guard let self else { return }
            if active { self.activeEditorDragSource = chrome }
            else if self.activeEditorDragSource === chrome { self.activeEditorDragSource = nil }
        }
        chrome.isSelected = editorSelectionID == id
        editorSelectionViews[id] = chrome
        return placeComponent(chrome, node: node)
    }

    // Default axes remain responsive; authored axes size the visible panel, not its
    // parent slot. A slot may fill a page/grid/split without stretching that panel.
    private func placeComponent(_ content: NSView, node: WorkspaceNode) -> NSView {
        guard case .component(let id, let type, _, _, let size) = node,
              !layout.collapsedInstanceIDs.contains(id),
              let descriptor = dependencies.registry.descriptor(for: type) else { return content }
        let customWidth = size.width != descriptor.defaultSize.width
        let customHeight = size.height != descriptor.defaultSize.height
        guard customWidth || customHeight else { return content }
        let slot = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(content)
        let chromeWidth = isLayoutEditorPreview ? WorkspaceEditorSelectionView.horizontalInset : 0
        let chromeHeight = isLayoutEditorPreview ? WorkspaceEditorSelectionView.verticalInset : 0
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            content.topAnchor.constraint(equalTo: slot.topAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: slot.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: slot.bottomAnchor),
            customWidth
                ? content.widthAnchor.constraint(equalToConstant: size.width + chromeWidth)
                : content.widthAnchor.constraint(equalTo: slot.widthAnchor),
            customHeight
                ? content.heightAnchor.constraint(equalToConstant: size.height + chromeHeight)
                : content.heightAnchor.constraint(equalTo: slot.heightAnchor),
        ])
        return slot
    }

    private func editorTitle(for node: WorkspaceNode) -> String {
        switch node {
        case .component(_, let type, _, _, _):
            return WorkspaceLayoutEditorController.componentTitle(type)
                + (layout.collapsedInstanceIDs.contains(node.id) ? String(localized: "（已折疊）") : "")
        case .empty: return String(localized: "空白放置區")
        case .grid: return String(localized: "網格容器")
        case .horizontalStack: return String(localized: "水平排列")
        case .verticalStack: return String(localized: "垂直排列")
        case .group: return String(localized: "群組容器")
        case .split: return String(localized: "分割容器")
        case .tabs: return String(localized: "分頁容器")
        }
    }

    private func renderSizedNode(_ node: WorkspaceNode) -> NSView {
        if case .component(let id, let type, _, _, let size) = node {
            if layout.collapsedInstanceIDs.contains(id) {
                let label = NSTextField(labelWithString: String(localized: "\(WorkspaceLayoutEditorController.componentTitle(type))（已折疊；可於編輯模式展開）"))
                return label
            }
            let panel = renderNodeContent(node)
            let wrapper = NSView()
            panel.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(panel)
            let minimum = dependencies.registry.descriptor(for: type)?.minimumSize ?? size
            let requestedWidth = wrapper.widthAnchor.constraint(equalToConstant: size.width)
            let requestedHeight = wrapper.heightAnchor.constraint(equalToConstant: size.height)
            requestedWidth.priority = .defaultLow; requestedHeight.priority = .defaultLow
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor), panel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                panel.topAnchor.constraint(equalTo: wrapper.topAnchor), panel.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                wrapper.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum.width),
                wrapper.heightAnchor.constraint(greaterThanOrEqualToConstant: type == "discovery.updates" ? 84 : minimum.height), requestedWidth, requestedHeight,
            ])
            return wrapper
        }
        return renderNodeContent(node)
    }


    private func renderNodeContent(_ node: WorkspaceNode) -> NSView {
        switch node {
        case .component(let id, let componentID, let version, _, _):
            guard let descriptor = dependencies.registry.descriptor(for: componentID),
                descriptor.contractVersion == version
            else {
                return WorkspaceStatusView(title: String(localized: "組件版本不相容"), detail: componentID.rawValue)
            }
            guard previewOnly || descriptor.dependencies.allSatisfy(dependencies.capabilityEnabled) else {
                return WorkspaceStatusView(title: String(localized: "功能已停用"), detail: String(localized: "可從固定「功能」選單重新啟用；既有資料並未刪除。"))
            }
            if componentID.rawValue.hasPrefix("favorites.") {
                let controller =
                    componentControllers[id]
                    ?? WorkspaceFavoritePanelController(
                        instanceID: id,
                        componentID: componentID, favorites: dependencies.favorites,
                        loadOnlineCollections: dependencies.loadOnlineCollections,
                        retryCollectionStatus: dependencies.retryCollectionStatus,
                        sessionState: dependencies.sessionState, actions: dependencies.actions,
                        skinAppearance: dependencies.skinAppearance, previewOnly: previewOnly,
                        dataManager: bookmarkDataManager)
                componentControllers[id] = controller
                return controller.view
            }
            if componentID.rawValue == "settings.preferences" {
                let controller = settingsController ?? dependencies.makeProductPanel(componentID, id, dependencies.skinAppearance, previewOnly)
                settingsController = controller
                return controller.view
            }
            if ["detail.media", "torrent.import"].contains(componentID.rawValue) {
                let controller = productControllers[id] ?? dependencies.makeProductPanel(componentID, id, dependencies.skinAppearance, previewOnly)
                productControllers[id] = controller
                return controller.view
            }
            let controller =
                serviceControllers[id]
                ?? WorkspaceServicePanelController(
                    instanceID: id, componentID: componentID, dependencies: dependencies,
                    previewOnly: previewOnly)
            serviceControllers[id] = controller
            return controller.view
        case .empty:
            return WorkspaceStatusView(title: String(localized: "空白頁面"), detail: String(localized: "固定搜尋、開啟、活動任務與恢復入口仍可使用。"))
        case .grid(_, let children):
            let columns = max(1, Int(ceil(sqrt(Double(children.count)))))
            let rows = stride(from: 0, to: children.count, by: columns).map { start in
                Array(children[start..<min(start + columns, children.count)]).map(renderNode)
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 8
            grid.columnSpacing = 8
            grid.xPlacement = .fill
            grid.yPlacement = .fill
            grid.bindSkin(dependencies.skinAppearance, slot: "list")
            return grid
        case .horizontalStack(_, let children): return stack(children, orientation: .horizontal)
        case .verticalStack(_, let children): return stack(children, orientation: .vertical)
        case .group(_, let children):
            let group = NSBox()
            group.titlePosition = .noTitle
            group.contentViewMargins = NSSize(width: 8, height: 8)
            let content = stack(children, orientation: .vertical)
            content.translatesAutoresizingMaskIntoConstraints = false
            let container = group.contentView!
            container.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.topAnchor.constraint(equalTo: container.topAnchor),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            return group
        case .split(let id, let first, let second, let ratio):
            let split =
                containerViews[id] as? WorkspaceRetainedSplitView ?? WorkspaceRetainedSplitView()
            let firstView = renderNode(first), secondView = renderNode(second)
            (firstView as? WorkspaceEditorSelectionView)?.dropsHorizontally = true
            (secondView as? WorkspaceEditorSelectionView)?.dropsHorizontally = true
            split.configure(
                firstView, secondView, ratio: ratio,
                minimumFirst: extent(first, requested: false).width,
                minimumSecond: extent(second, requested: false).width)
            split.onRatioChange = onEditorSplitChange.map { callback in { callback(id, $0) } }
            containerViews[id] = split
            return split
        case .tabs(let id, let selected, let pages):
            let tabs = containerViews[id] as? WorkspaceRetainedTabView ?? WorkspaceRetainedTabView()
            tabs.motionAppearance = dependencies.skinAppearance
            tabs.onSelectionChange = { [weak self] in self?.synchronizePanelVisibility() }
            tabs.onEditorPageSelection = isLayoutEditorPreview ? { [weak self] pageID in
                guard let rootID = pages.first(where: { $0.id == pageID })?.root.id else { return }
                self?.highlightEditorSelection(rootID)
                self?.onEditorSelection?(rootID)
            } : nil
            tabs.populate(pages, selectedPageID: selected, render: renderNode)
            tabs.bindSkin(dependencies.skinAppearance, slot: "tabs")
            containerViews[id] = tabs
            return tabs
        }
    }

    private func extent(_ node: WorkspaceNode, requested: Bool) -> NSSize {
        let size = contentExtent(node, requested: requested)
        guard isLayoutEditorPreview else { return size }
        return NSSize(width: size.width + WorkspaceEditorSelectionView.horizontalInset,
            height: size.height + WorkspaceEditorSelectionView.verticalInset)
    }

    private func contentExtent(_ node: WorkspaceNode, requested: Bool) -> NSSize {
        func combined(_ nodes: [WorkspaceNode], horizontal: Bool) -> NSSize {
            let sizes = nodes.map { extent($0, requested: requested) }
            return NSSize(
                width: horizontal
                    ? sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * 8
                    : sizes.map(\.width).max() ?? 0,
                height: horizontal
                    ? sizes.map(\.height).max() ?? 0
                    : sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * 8)
        }
        switch node {
        case .component(let id, let type, _, _, let size):
            if layout.collapsedInstanceIDs.contains(id) { return NSSize(width: 280, height: 32) }
            let descriptor = dependencies.registry.descriptor(for: type)!
            let value = requested ? size : descriptor.minimumSize
            return NSSize(
                width: size.width != descriptor.defaultSize.width ? max(value.width, size.width) : value.width,
                height: size.height != descriptor.defaultSize.height ? max(value.height, size.height) : value.height)
        case .empty: return NSSize(width: 280, height: 180)
        case .split(_, let first, let second, _):
            let a = extent(first, requested: requested)
            let b = extent(second, requested: requested)
            return NSSize(width: a.width + b.width + 1, height: max(a.height, b.height))
        case .horizontalStack(_, let children): return combined(children, horizontal: true)
        case .verticalStack(_, let children): return combined(children, horizontal: false)
        case .group(_, let children):
            let content = combined(children, horizontal: false)
            return NSSize(width: content.width + 16, height: content.height + 16)
        case .grid(_, let children):
            let columns = max(1, Int(ceil(sqrt(Double(children.count)))))
            let sizes = children.map { extent($0, requested: requested) }
            return NSSize(
                width: (sizes.map(\.width).max() ?? 0) * CGFloat(columns) + CGFloat(columns - 1)
                    * 8,
                height: (sizes.map(\.height).max() ?? 0)
                    * CGFloat((children.count + columns - 1) / columns)
            )
        case .tabs(_, _, let pages):
            let sizes = pages.map { extent($0.root, requested: requested) }
            return NSSize(
                width: sizes.map(\.width).max() ?? 0, height: (sizes.map(\.height).max() ?? 0) + 32)
        }
    }

    private func stack(_ nodes: [WorkspaceNode], orientation: NSUserInterfaceLayoutOrientation)
        -> NSView
    {
        let view = NSStackView(views: nodes.map(renderNode))
        view.orientation = orientation
        if orientation == .horizontal {
            nodes.forEach { editorSelectionViews[$0.id]?.dropsHorizontally = true }
        }
        view.alignment = orientation == .horizontal ? .height : .width
        var pinned: [(Int, UUID, Double)] = []
        if orientation == .vertical, isDiscoveryFeedNodes(nodes) {
            for (index, node) in nodes.dropLast().enumerated() {
                guard case .component(let id, let type, _, _, let size) = node else { continue }
                let automatic = size.height == dependencies.registry.descriptor(for: type)?.defaultSize.height
                let height = type == "playback.continue" && automatic
                    ? min(size.height, serviceControllers[id]?.continueHeight ?? size.height) : size.height
                pinned.append((index, id, layout.collapsedInstanceIDs.contains(id) ? 32 : height))
            }
        } else if orientation == .vertical, hasColumnBody(nodes) {
            for (index, node) in nodes.dropLast().enumerated() {
                guard case .component(let id, let type, _, _, let size) = node else { continue }
                let automatic = size.height == dependencies.registry.descriptor(for: type)?.defaultSize.height
                let contentHeight: Double?
                switch type {
                case "discovery.updates": contentHeight = serviceControllers[id]?.favoriteUpdatesHeight
                case "playback.continue": contentHeight = serviceControllers[id]?.continueHeight
                default: contentHeight = nil
                }
                let height = automatic ? min(size.height, contentHeight ?? size.height) : size.height
                pinned.append((index, id, layout.collapsedInstanceIDs.contains(id) ? 32 : height))
            }
        }
        if orientation == .vertical {
            for (node, child) in zip(nodes, view.arrangedSubviews) where isColumnComposition(node) {
                child.heightAnchor.constraint(
                    greaterThanOrEqualToConstant: extent(node, requested: false).height).isActive = true
            }
        }
        view.distribution = .fill
        for (index, id, value) in pinned {
            let chromeHeight = isLayoutEditorPreview ? WorkspaceEditorSelectionView.verticalInset : 0
            let height = view.arrangedSubviews[index].heightAnchor.constraint(equalToConstant: value + chromeHeight)
            height.priority = .defaultHigh; height.isActive = true
            if case .component(_, let type, _, _, let size) = nodes[index],
               (type == "playback.continue" || type == "discovery.updates"),
               size.height == dependencies.registry.descriptor(for: type)?.defaultSize.height,
               !layout.collapsedInstanceIDs.contains(id) {
                serviceControllers[id]?.contentHeightDidChange = { [weak height, weak view] value in
                    height?.constant = min(size.height, value) + chromeHeight
                    view?.needsLayout = true
                }
            }
        }
        view.spacing = 8
        view.bindSkin(dependencies.skinAppearance, slot: "list")
        for child in view.arrangedSubviews {
            if orientation == .horizontal {
                child.heightAnchor.constraint(equalTo: view.heightAnchor).isActive = true
            } else {
                child.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
            }
        }
        return view
    }


    private func detachRemovedComponents() {
        let live = Set(WorkspaceLayoutTraversal.componentInstanceIDs(in: layout))
        for id in Array(componentControllers.keys) where !live.contains(id) {
            if let controller = componentControllers[id] { panelVisibility.removeValue(forKey: ObjectIdentifier(controller)) }
            componentControllers.removeValue(forKey: id)?.detach()
        }
        for id in Array(serviceControllers.keys) where !live.contains(id) {
            if let controller = serviceControllers[id] { panelVisibility.removeValue(forKey: ObjectIdentifier(controller)) }
            serviceControllers.removeValue(forKey: id)?.detach()
        }
        for id in Array(productControllers.keys) where !live.contains(id) {
            if let controller = productControllers[id] { panelVisibility.removeValue(forKey: ObjectIdentifier(controller)) }
            (productControllers.removeValue(forKey: id) as? WorkspaceDetachablePanel)?.detach()
        }
    }

    private func presentPersistenceError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

@MainActor
private final class WorkspaceDateLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        refreshDate()
        for name in [Notification.Name.NSCalendarDayChanged, NSApplication.didBecomeActiveNotification,
                     NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(dateChanged), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc nonisolated private func dateChanged() {
        Task { @MainActor [weak self] in self?.refreshDate() }
    }

    private func refreshDate() {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d EEEE")
        stringValue = formatter.string(from: Date())
    }
}

@MainActor
private final class WorkspaceEditorSelectionView: NSView, NSDraggingSource {
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 32
    private static let moveType = NSPasteboard.PasteboardType("com.iina-ani.workspace.editor-node")
    let selectionButton: NSButton
    let nodeID: UUID
    var requestedSize: WorkspaceSize? { didSet { updateHandles() } }
    var onResize: ((WorkspaceSize) -> Void)?
    var onMove: ((UUID, Bool) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    var dropsHorizontally = false
    private let select: () -> Void
    private var resizeHandles: [WorkspaceEditorResizeHandle] = []
    private var dropAfter: Bool? { didSet { needsDisplay = true } }
    var isSelected = false {
        didSet {
            selectionButton.state = isSelected ? .on : .off
            selectionButton.setAccessibilityValue(isSelected ? String(localized: "已選取") : String(localized: "未選取"))
            updateHandles()
            needsDisplay = true
        }
    }

    init(id: UUID, title: String, content: NSView, select: @escaping () -> Void) {
        let titleButton = WorkspaceEditorDragTitle(title: title, target: nil, action: nil)
        selectionButton = titleButton
        nodeID = id
        self.select = select
        super.init(frame: .zero)
        registerForDraggedTypes([Self.moveType])
        titleButton.onMouseDown = { [weak self] event in self?.trackTitle(with: event) }
        selectionButton.target = self
        selectionButton.action = #selector(selectNode)
        selectionButton.isBordered = false
        selectionButton.alignment = .left
        selectionButton.font = .systemFont(ofSize: 12, weight: .medium)
        selectionButton.lineBreakMode = .byTruncatingTail
        selectionButton.setAccessibilityLabel(String(localized: "選取\(title)"))
        selectionButton.toolTip = String(localized: "點選以選取；拖動標題可移到其他區域之前或之後，Escape 取消")
        selectionButton.setAccessibilityHelp(selectionButton.toolTip)
        selectionButton.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(selectionButton)
        NSLayoutConstraint.activate([
            selectionButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            selectionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            selectionButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            selectionButton.heightAnchor.constraint(equalToConstant: 26),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            content.topAnchor.constraint(equalTo: selectionButton.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        updateHandles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func selectNode() { select() }

    override func mouseDown(with event: NSEvent) { select() }

    private func updateHandles() {
        if requestedSize != nil, resizeHandles.isEmpty {
            for edge in WorkspaceEditorResizeHandle.Edge.allCases {
                let handle = WorkspaceEditorResizeHandle(edge: edge)
                handle.onMouseDown = { [weak self] event in self?.trackResize(edge: edge, with: event) }
                handle.identifier = NSUserInterfaceItemIdentifier("workspace.editor.resize.\(edge.rawValue).\(nodeID.uuidString)")
                addSubview(handle)
                resizeHandles.append(handle)
            }
            needsLayout = true
        }
        resizeHandles.forEach { $0.isHidden = !isSelected || requestedSize == nil }
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        for handle in resizeHandles {
            switch handle.edge {
            case .right: handle.frame = NSRect(x: bounds.maxX - 7, y: bounds.midY - 15, width: 7, height: 30)
            case .bottom: handle.frame = NSRect(x: bounds.midX - 15, y: bounds.minY, width: 30, height: 7)
            case .corner: handle.frame = NSRect(x: bounds.maxX - 13, y: bounds.minY, width: 13, height: 13)
            }
        }
    }

    // Keep the initiating view alive on the mouseDown stack. Never rebuild the draft while tracking.
    // A short timeout lets window closure, deactivation, and external rerenders cancel safely.
    private func trackPointer(from event: NSEvent, drag: (NSEvent) -> Bool) -> NSEvent? {
        guard let originalWindow = window else { return nil }
        while window === originalWindow, superview != nil, originalWindow.isVisible,
              originalWindow.isKeyWindow, NSApp.isActive {
            guard let next = originalWindow.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true)
            else { continue }
            guard window === originalWindow, superview != nil, originalWindow.isVisible,
                  originalWindow.isKeyWindow, NSApp.isActive else { return nil }
            switch next.type {
            case .leftMouseUp: return next
            case .leftMouseDragged: if !drag(next) { return nil }
            case .keyDown:
                if next.keyCode == 53 { return nil }
                NSApp.sendEvent(next)
            default: break
            }
        }
        return nil
    }

    private func trackTitle(with event: NSEvent) {
        select()
        let origin = event.locationInWindow
        _ = trackPointer(from: event) { next in
            let point = next.locationInWindow
            guard hypot(point.x - origin.x, point.y - origin.y) >= 5 else { return true }
            let item = NSPasteboardItem()
            item.setString(nodeID.uuidString, forType: Self.moveType)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let title = selectionButton.title
            let size = selectionButton.bounds.size
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                (title as NSString).draw(in: rect.insetBy(dx: 6, dy: 5), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
                ])
                return true
            }
            draggingItem.setDraggingFrame(convert(selectionButton.bounds, from: selectionButton), contents: image)
            onDragStateChange?(true)
            let session = beginDraggingSession(with: [draggingItem], event: next, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            return false
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragStateChange?(false)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard NSApp.isActive, let source = sender.draggingSource as? WorkspaceEditorSelectionView,
              source.window === window, source.superview != nil,
              sender.draggingPasteboard.string(forType: Self.moveType) == source.nodeID.uuidString,
              !isDescendant(of: source), onMove != nil else {
            dropAfter = nil
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        dropAfter = dropsHorizontally ? point.x >= bounds.midX : point.y < bounds.midY
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropAfter = nil }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingUpdated(sender) == .move }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingUpdated(sender) == .move, let after = dropAfter,
              let source = sender.draggingSource as? WorkspaceEditorSelectionView else { return false }
        dropAfter = nil
        onMove?(source.nodeID, after)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropAfter = nil }

    private func trackResize(edge: WorkspaceEditorResizeHandle.Edge, with event: NSEvent) {
        guard isSelected, let original = requestedSize, let overlayHost = window?.contentView else { return }
        let origin = event.locationInWindow
        let originalFrame = overlayHost.convert(bounds, from: self)
        let initial = WorkspaceSize(
            width: edge == .bottom ? original.width : bounds.width - Self.horizontalInset,
            height: edge == .right ? original.height : bounds.height - Self.verticalInset)
        let feedback = WorkspaceEditorResizeFeedback(frame: originalFrame)
        feedback.caption = String(localized: "要求尺寸：\(Int(original.width.rounded())) × \(Int(original.height.rounded())) pt")
        overlayHost.addSubview(feedback)
        var requested = original
        var moved = false
        func update(_ next: NSEvent) {
            let dx = next.locationInWindow.x - origin.x
            let dy = origin.y - next.locationInWindow.y
            guard hypot(dx, dy) >= 2 || moved else { return }
            moved = true
            requested = WorkspaceSize(
                width: edge == .bottom ? original.width : max(1, initial.width + dx),
                height: edge == .right ? original.height : max(1, initial.height + dy))
            var frame = originalFrame
            frame.size.width = max(20, originalFrame.width + requested.width - initial.width)
            frame.size.height = max(20, originalFrame.height + requested.height - initial.height)
            if !overlayHost.isFlipped { frame.origin.y = originalFrame.maxY - frame.height }
            feedback.frame = frame
            feedback.caption = String(localized: "要求尺寸：\(Int(requested.width.rounded())) × \(Int(requested.height.rounded())) pt")
        }
        let mouseUp = trackPointer(from: event) { next in
            update(next)
            return true
        }
        if let mouseUp { update(mouseUp) }
        feedback.removeFromSuperview()
        if mouseUp != nil, moved { onResize?(requested) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        border.lineWidth = isSelected ? 2 : 1
        border.stroke()
        if let after = dropAfter {
            let cue: NSRect
            if dropsHorizontally {
                cue = NSRect(x: after ? bounds.maxX - 4 : bounds.minX, y: bounds.minY, width: 4, height: bounds.height)
            } else {
                cue = NSRect(x: bounds.minX, y: after ? bounds.minY : bounds.maxY - 4, width: bounds.width, height: 4)
            }
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: cue, xRadius: 2, yRadius: 2).fill()
        }
    }
}

@MainActor
private final class WorkspaceEditorDragTitle: NSButton {
    var onMouseDown: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

@MainActor
private final class WorkspaceEditorResizeHandle: NSControl {
    enum Edge: String, CaseIterable { case right, bottom, corner }
    let edge: Edge
    var onMouseDown: ((NSEvent) -> Void)?
    private static let diagonalCursor: NSCursor = {
        let image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)!
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }()

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        let label: String
        switch edge {
        case .right: label = String(localized: "拖動調整寬度")
        case .bottom: label = String(localized: "拖動調整高度")
        case .corner: label = String(localized: "拖動調整寬度與高度")
        }
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(label)
        setAccessibilityHelp(String(localized: "拖動以調整要求尺寸；放開套用至草稿，Escape 取消"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        let cursor: NSCursor
        switch edge {
        case .right: cursor = .resizeLeftRight
        case .bottom: cursor = .resizeUpDown
        case .corner: cursor = Self.diagonalCursor
        }
        cursor.push()
        defer { NSCursor.pop() }
        onMouseDown?(event)
    }

    override func resetCursorRects() {
        switch edge {
        case .right: addCursorRect(bounds, cursor: .resizeLeftRight)
        case .bottom: addCursorRect(bounds, cursor: .resizeUpDown)
        case .corner: addCursorRect(bounds, cursor: Self.diagonalCursor)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        let grip = edge == .corner ? bounds.insetBy(dx: 3, dy: 3)
            : bounds.insetBy(dx: edge == .right ? 1 : 6, dy: edge == .right ? 6 : 1)
        NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3).fill()
    }
}

@MainActor
private final class WorkspaceEditorResizeFeedback: NSView {
    var caption = "" { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.setLineDash([5, 3], count: 2, phase: 0)
        border.stroke()
        let label = NSRect(x: 8, y: bounds.maxY - 28, width: max(0, bounds.width - 16), height: 22)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
        (caption as NSString).draw(in: label.insetBy(dx: 4, dy: 3), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
    }
}

@MainActor
final class WorkspaceDensityButton: WorkspaceSkinButton {
    override var preservesNativeImage: Bool { true }
    private let instanceID: UUID
    private let sessionState: WorkspaceSessionState
    private let didChange: () -> Void

    init(instanceID: UUID, sessionState: WorkspaceSessionState, appearance: SkinAppearance,
         componentID: String, previewOnly: Bool, didChange: @escaping () -> Void) {
        self.instanceID = instanceID
        self.sessionState = sessionState
        self.didChange = didChange
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = ""
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: String(localized: "組件緊湊度"))
        toolTip = String(localized: "本組件緊湊度")
        setAccessibilityLabel(String(localized: "本組件緊湊度"))
        target = self
        action = #selector(showDensityMenu)
        isEnabled = !previewOnly
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        bindSkin(appearance, slot: "primaryAction", componentID: componentID)
        updateSkinState()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func showDensityMenu() {
        let menu = NSMenu()
        for (density, title) in [String(localized: "緊湊"), String(localized: "標準"), String(localized: "寬鬆")].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(changeDensity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = density
            item.state = sessionState.state(for: instanceID).density == density ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 3), in: self)
    }

    @objc private func changeDensity(_ sender: NSMenuItem) {
        var state = sessionState.state(for: instanceID)
        state.density = sender.tag
        do {
            try sessionState.update(state, for: instanceID)
            didChange()
        } catch {
            if let window { window.presentError(error) } else { NSApp.presentError(error) }
        }
    }
}

@MainActor
private final class WorkspaceDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Keeps navigation width in points while the document receives window resizing.
@MainActor
private final class WorkspaceSidebarSplitView: NSSplitView, NSSplitViewDelegate {
    var onWidthChange: ((CGFloat) -> Void)?
    private var sidebarWidth: CGFloat
    private var updating = false

    init(sidebar: NSView, content: NSView, width: CGFloat) {
        sidebarWidth = width
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        setAccessibilityIdentifier("workspace.sidebar.split")
        for view in [sidebar, content] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addArrangedSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var maximumWidth: CGFloat { min(320, max(96, bounds.width - dividerThickness - 320)) }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard arrangedSubviews.count == 2 else { return }
        updating = true
        let available = max(0, bounds.width - dividerThickness)
        let width = min(available, min(max(96, sidebarWidth), maximumWidth))
        arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        arrangedSubviews[1].frame = NSRect(
            x: width + dividerThickness, y: 0, width: max(0, available - width), height: bounds.height)
        updating = false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !updating, arrangedSubviews.count == 2, bounds.width > 0 else { return }
        let width = arrangedSubviews[0].frame.width
        guard width >= 96, width <= maximumWidth, abs(width - sidebarWidth) > 0.5 else { return }
        sidebarWidth = width
        onWidthChange?(width)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(96, proposed)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(maximumWidth, proposed)
    }
}

@MainActor
final class WorkspaceRetainedSplitView: NSSplitView, NSSplitViewDelegate {
    var onRatioChange: ((Double) -> Void)?
    private var ratio: CGFloat = 0.5
    private var configuredRatio: Double?
    private var minimumFirst: CGFloat = 280
    private var minimumSecond: CGFloat = 280
    private var updating = false
    private var trackingGesture = false
    override func mouseDown(with event: NSEvent) {
        let previous = ratio
        trackingGesture = true
        super.mouseDown(with: event)
        splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification, object: self))
        trackingGesture = false
        if abs(previous - ratio) > 0.0001 { onRatioChange?(Double(ratio)) }
    }

    func configure(
        _ first: NSView, _ second: NSView, ratio: Double, minimumFirst: CGFloat,
        minimumSecond: CGFloat
    ) {
        updating = true
        if configuredRatio != ratio {
            self.ratio = CGFloat(ratio)
            configuredRatio = ratio
        }
        self.minimumFirst = minimumFirst
        self.minimumSecond = minimumSecond
        isVertical = true
        dividerStyle = .thin
        delegate = self
        // NSSplitView owns child frames; Auto Layout remains inside each panel.
        first.translatesAutoresizingMaskIntoConstraints = true
        second.translatesAutoresizingMaskIntoConstraints = true
        if arrangedSubviews.count != 2 || arrangedSubviews[0] !== first
            || arrangedSubviews[1] !== second
        {
            arrangedSubviews.forEach {
                removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            addArrangedSubview(first)
            addArrangedSubview(second)
        }
        updating = false
        resizeSubviews(withOldSize: bounds.size)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard arrangedSubviews.count == 2 else { return }
        updating = true
        defer { updating = false }
        let available = max(0, bounds.width - dividerThickness)
        let first = min(
            max(available * ratio, minimumFirst), max(minimumFirst, available - minimumSecond))
        arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: first, height: bounds.height)
        arrangedSubviews[1].frame = NSRect(
            x: first + dividerThickness, y: 0, width: max(0, available - first),
            height: bounds.height)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard trackingGesture, !updating, arrangedSubviews.count == 2, bounds.width > dividerThickness else {
            return
        }
        let next = arrangedSubviews[0].frame.width / (bounds.width - dividerThickness)
        guard next > 0, next < 1, abs(next - ratio) > 0.0001 else { return }
        ratio = next
    }
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int
    )
        -> CGFloat
    { max(minimumFirst, proposed) }
    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int
    )
        -> CGFloat
    { min(bounds.width - dividerThickness - minimumSecond, proposed) }
}

@MainActor
private final class WorkspaceRetainedTabView: NSTabView, NSTabViewDelegate {
    var suppressMotion = false
    private var configuredSelection: UUID?
    var onEditorPageSelection: ((UUID) -> Void)?
    var onSelectionChange: (() -> Void)?
    private var populating = false
    private var motions: [UUID: WorkspacePageMotion] = [:]
    var motionAppearance: SkinAppearance?
    func previewMotion(_ motion: WorkspacePageMotion, pageID: UUID) -> Bool {
        guard let item = tabViewItems.first(where: { $0.identifier as? String == pageID.uuidString }),
              let view = item.view else { return false }
        populating = true
        selectTabViewItem(item)
        populating = false
        layoutSubtreeIfNeeded()
        onSelectionChange?()
        WorkspacePageAnimator.play(motionAppearance?.resolvedPageMotion(motion) ?? motion, on: view)
        return true
    }
    func populate(_ pages: [WorkspacePage], selectedPageID: UUID, render: (WorkspaceNode) -> NSView)
    {
        populating = true
        defer { populating = false }
        delegate = self
        motions = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.motion) })
        let retained = selectedTabViewItem?.identifier as? String
        let ids = Set(pages.map { $0.id.uuidString })
        for item in tabViewItems where !ids.contains(item.identifier as? String ?? "") {
            removeTabViewItem(item)
        }
        for (index, page) in pages.enumerated() {
            let id = page.id.uuidString
            let item =
                tabViewItems.first { $0.identifier as? String == id }
                ?? NSTabViewItem(identifier: id)
            item.label = page.displayTitle
            let content = render(page.root)
            content.translatesAutoresizingMaskIntoConstraints = true
            content.autoresizingMask = [.width, .height]
            item.view = content
            if index >= tabViewItems.count || tabViewItems[index] !== item {
                if tabViewItems.contains(item) { removeTabViewItem(item) }
                insertTabViewItem(item, at: index)
            }
        }
        let selection =
            configuredSelection == selectedPageID
            ? retained.flatMap { ids.contains($0) ? $0 : nil } ?? selectedPageID.uuidString
            : selectedPageID.uuidString
        configuredSelection = selectedPageID
        if let selected = tabViewItems.first(where: { $0.identifier as? String == selection }) {
            selectTabViewItem(selected)
        } else if let first = tabViewItems.first {
            selectTabViewItem(first)
        }
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard !populating, let raw = tabViewItem?.identifier as? String,
              let id = UUID(uuidString: raw) else { return }
        layoutSubtreeIfNeeded()
        onSelectionChange?()
        if !suppressMotion, let view = tabViewItem?.view, let motion = motions[id] {
            layoutSubtreeIfNeeded()
            WorkspacePageAnimator.play(motionAppearance?.resolvedPageMotion(motion) ?? motion, on: view)
        }
        onEditorPageSelection?(id)
    }
}

@MainActor
private final class WorkspaceStatusView: NSView {
    init(title: String, detail: String) {
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 14)
        let body = NSTextField(wrappingLabelWithString: detail)
        body.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Presentation-only animations leave layout, hit testing and final model values unchanged.
@MainActor
private enum WorkspacePageAnimator {
    static func play(_ motion: WorkspacePageMotion, on view: NSView) {
        view.layer?.removeAnimation(forKey: "workspace.pageMotion")
        guard motion.duration > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              (try? motion.validate()) != nil else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = motion.opacity
        opacity.toValue = 1
        let transform = CABasicAnimation(keyPath: "transform")
        // Scale around the page centre without changing AppKit's layer anchor point.
        let x = motion.offsetX + Double(layer.bounds.width) * (1 - motion.scale) / 2
        let y = motion.offsetY + Double(layer.bounds.height) * (1 - motion.scale) / 2
        transform.fromValue = CATransform3DScale(
            CATransform3DMakeTranslation(x, y, 0), motion.scale, motion.scale, 1)
        transform.toValue = CATransform3DIdentity
        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = motion.duration
        let timing: CAMediaTimingFunctionName
        switch motion.curve {
        case .linear: timing = .linear
        case .easeIn: timing = .easeIn
        case .easeOut: timing = .easeOut
        case .easeInOut: timing = .easeInEaseOut
        }
        group.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(group, forKey: "workspace.pageMotion")
    }
}
