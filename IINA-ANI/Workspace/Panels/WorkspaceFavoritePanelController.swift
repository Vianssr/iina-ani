import AppKit
import CoreData

@MainActor
private final class FavoriteTableView: NSTableView {
    var activate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { activate?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
final class WorkspaceFavoritePanelController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate, WorkspaceDetachablePanel
{
    private enum Kind { case works, links }
    private enum Row: Hashable {
        case work(Work)
        case link(LinkFavorite)
    }

    private let instanceID: UUID
    private let kind: Kind
    private let favorites: FavoriteLibrary
    private let loadOnlineCollections: () async throws -> Int
    private let retryCollectionStatus: (UUID) async throws -> Void
    private let sessionState: WorkspaceSessionState
    private let actions: WorkspaceFixedActions
    private let skinAppearance: SkinAppearance
    private let componentID: String
    private let previewOnly: Bool
    private var query = ""
    private var sort: FavoriteSort = .manual
    private var rows: [Row] = []
    private var selectedIdentity: String?
    private var savedScrollPosition: Double = 0
    private var requestTask: Task<Void, Never>?
    private var attached = true
    private var savedStateLoaded = false
    private var suppressSelectionChanges = false
    private let countLabel = NSTextField(labelWithString: "0")
    private let statusLabel = WorkspaceSkinStatusLabel(wrappingLabelWithString: "")
    private var errorMessage: String?
    private let searchField = WorkspaceSkinSearchField()
    private let tableView = FavoriteTableView()
    private let scrollView = WorkspaceScrollView()
    private let emptyState = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let sortPopup = NSPopUpButton()
    private let actionButton = WorkspaceSkinButton()
    private let urlField = NSTextField()
    private let titleField = NSTextField()
    private let openButton = WorkspaceSkinButton()
    private let editButton = WorkspaceSkinButton()
    private var sourceDescriptions: [UUID: String] = [:]
    private let dataManager: DataManager?
    private var bookmarks: [UUID: Bookmark] = [:]
    private let liveFilter = NSPopUpButton()
    private let siteFilter = NSPopUpButton()
    private let refreshButton = WorkspaceSkinButton()
    private let collectionFilter = NSPopUpButton()
    private var collectionFilterIndex = 0
    private let onlineButton = WorkspaceSkinButton()
    private let onlineStatus = WorkspaceSkinStatusLabel(wrappingLabelWithString: "")
    private var onlineTask: Task<Void, Never>?
    private var onlineGeneration = UUID()
    private let retryButton = WorkspaceSkinButton()
    private var retryTask: Task<Void, Never>?
    private var retryGeneration = UUID()
    private var selectedSite = ""
    private var liveFilterIndex = 0
    private var statusRefreshTask: Task<Void, Never>?
    private var liveRequest: Task<Void, Never>?
    private static let dragType = NSPasteboard.PasteboardType("org.iina-ani.workspace.favorite")
    init(
        instanceID: UUID, componentID: WorkspaceComponentID, favorites: FavoriteLibrary,
        loadOnlineCollections: @escaping () async throws -> Int,
        retryCollectionStatus: @escaping (UUID) async throws -> Void,
        sessionState: WorkspaceSessionState, actions: WorkspaceFixedActions,
        skinAppearance: SkinAppearance, previewOnly: Bool = false, dataManager: DataManager? = nil
    ) {
        self.instanceID = instanceID
        kind = componentID.rawValue == "favorites.works" ? .works : .links
        self.favorites = favorites
        self.loadOnlineCollections = loadOnlineCollections
        self.retryCollectionStatus = retryCollectionStatus
        self.sessionState = sessionState
        self.actions = actions
        self.skinAppearance = skinAppearance
        self.componentID = componentID.rawValue
        self.previewOnly = previewOnly
        self.dataManager = dataManager
        if !previewOnly, dataManager?.context.undoManager == nil { dataManager?.context.undoManager = UndoManager() }
        super.init(nibName: nil, bundle: nil)
        title = kind == .works ? String(localized: "作品收藏") : String(localized: "連結收藏")
        if !previewOnly { loadSavedState() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSStackView(views: [])
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 8
        panel.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 14, right: 16)
        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.topAnchor.constraint(equalTo: root.topAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let header = NSStackView(views: [])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let heading = NSTextField(labelWithString: title ?? String(localized: "收藏"))
        heading.font = .boldSystemFont(ofSize: 17)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.addArrangedSubview(heading)
        header.addArrangedSubview(countLabel)
        let spacer = NSView()
        header.addArrangedSubview(spacer)
        sortPopup.addItems(withTitles: [String(localized: "手動排序"), String(localized: "依標題"), String(localized: "最近加入")])
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)
        sortPopup.selectItem(at: sortIndex)
        sortPopup.controlSize = .small
        if kind == .works {
            header.addArrangedSubview(WorkspaceDensityButton(
                instanceID: instanceID, sessionState: sessionState, appearance: skinAppearance,
                componentID: componentID, previewOnly: previewOnly
            ) { [weak self] in self?.presentationSettingsDidChange() })
            refreshButton.title = String(localized: "刷新")
            refreshButton.target = self; refreshButton.action = #selector(reload(_:))
            refreshButton.bezelStyle = .rounded
            refreshButton.bindSkin(skinAppearance, slot: "primaryAction", componentID: componentID)
            refreshButton.isEnabled = !previewOnly
            header.addArrangedSubview(refreshButton)
        }
        actionButton.setFunctionIcon(.delete)
        refreshButton.setFunctionIcon(.refresh)
        retryButton.setFunctionIcon(.sync)
        onlineButton.setFunctionIcon(.importFile)
        actionButton.target = self
        actionButton.action = #selector(primaryAction)
        actionButton.bezelStyle = .rounded
        actionButton.title = String(localized: "移除收藏")
        panel.addArrangedSubview(header)
        let commands = NSStackView(views: [])
        commands.orientation = .horizontal
        commands.spacing = 6
        openButton.title = kind == .works ? String(localized: "開啟詳情") : String(localized: "開啟連結")
        openButton.setFunctionIcon(kind == .works ? .work : .openLink)
        openButton.target = self
        openButton.action = #selector(activateSelectedRow)
        editButton.title = String(localized: "編輯")
        editButton.setFunctionIcon(.settings)
        editButton.target = self
        editButton.action = #selector(editSelectedRow)
        for button in [openButton, editButton] {
            button.bezelStyle = .rounded
            button.isEnabled = false
            button.bindSkin(skinAppearance, slot: "primaryAction", componentID: componentID)
            commands.addArrangedSubview(button)
        }
        if kind == .works {
            retryButton.title = String(localized: "重試同步")
            retryButton.target = self
            retryButton.action = #selector(retrySelectedCollection)
            retryButton.bezelStyle = .rounded
            retryButton.isEnabled = false
            retryButton.bindSkin(skinAppearance, slot: "primaryAction", componentID: componentID)
            commands.addArrangedSubview(retryButton)
        }
        commands.addArrangedSubview(NSView())
        commands.addArrangedSubview(actionButton)
        sortPopup.setAccessibilityLabel(String(localized: "收藏排序"))
        header.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true

        searchField.placeholderString =
            kind == .works ? String(localized: "搜尋作品名稱或別名") : String(localized: "搜尋標題、網址或來源")
        searchField.delegate = self
        searchField.stringValue = query
        searchField.sendsSearchStringImmediately = true
        let searchRow = NSStackView(views: [searchField, sortPopup])
        searchRow.spacing = 8
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        panel.addArrangedSubview(searchRow)
        searchRow.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        searchField.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        if kind == .works {
            collectionFilter.addItems(withTitles: [String(localized: "全部分類")]
                + BangumiCollectionStatus.displayOrder.map(\.title) + [String(localized: "待同步")])
            collectionFilter.selectItem(at: collectionFilterIndex)
            collectionFilter.target = self
            collectionFilter.action = #selector(collectionFilterChanged)
            collectionFilter.setAccessibilityLabel(String(localized: "作品收藏分類"))
            collectionFilter.isEnabled = !previewOnly
            collectionFilter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            onlineButton.title = String(localized: "載入在線收藏")
            onlineButton.target = self
            onlineButton.action = #selector(loadOnlineFavorites)
            onlineButton.bezelStyle = .rounded
            onlineButton.isEnabled = !previewOnly
            onlineButton.toolTip = String(localized: "載入目前 Bangumi 帳號的番劇收藏；不刪除本機收藏或覆蓋待同步修改。")
            onlineButton.bindSkin(skinAppearance, slot: "primaryAction", componentID: componentID)
            let filters = NSStackView(views: [collectionFilter, onlineButton])
            filters.spacing = 6
            panel.addArrangedSubview(filters)
            filters.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
            onlineStatus.maximumNumberOfLines = 2
            onlineStatus.textColor = .secondaryLabelColor
            onlineStatus.isHidden = true
            let presentation = onlineStatus.presentation(appearance: skinAppearance, componentID: componentID)
            panel.addArrangedSubview(presentation)
            presentation.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        }
        if kind == .links {
            liveFilter.addItems(withTitles: [String(localized: "全部狀態"), String(localized: "直播中"), String(localized: "未開播"), String(localized: "影片／未知")])
            liveFilter.selectItem(at: liveFilterIndex)
            liveFilter.target = self; liveFilter.action = #selector(linkFilterChanged)
            liveFilter.setAccessibilityLabel(String(localized: "Bookmark live state"))
            siteFilter.addItem(withTitle: String(localized: "全部來源"))
            siteFilter.target = self; siteFilter.action = #selector(linkFilterChanged)
            siteFilter.setAccessibilityLabel(String(localized: "Bookmark site"))
            refreshButton.title = String(localized: "刷新")
            refreshButton.toolTip = String(localized: "更新連結的直播狀態")
            refreshButton.target = self; refreshButton.action = #selector(refreshLiveStatus)
            refreshButton.bezelStyle = .rounded
            refreshButton.bindSkin(skinAppearance, slot: "primaryAction", componentID: componentID)
            refreshButton.isEnabled = !previewOnly && dataManager != nil
            liveFilter.isEnabled = !previewOnly; siteFilter.isEnabled = !previewOnly
            for popup in [liveFilter, siteFilter] {
                popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            let densityButton = WorkspaceDensityButton(
                instanceID: instanceID, sessionState: sessionState, appearance: skinAppearance,
                componentID: componentID, previewOnly: previewOnly
            ) { [weak self] in self?.presentationSettingsDidChange() }
            let filters = NSStackView(views: [liveFilter, siteFilter, densityButton, refreshButton])
            filters.spacing = 6
            panel.addArrangedSubview(filters)
            filters.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.isHidden = true
        let statusPresentation = statusLabel.presentation(
            appearance: skinAppearance, componentID: componentID)
        panel.addArrangedSubview(statusPresentation)
        statusPresentation.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32)
            .isActive =
            true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
        column.title = kind == .works ? String(localized: "Work") : String(localized: "Link")
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.activate = { [weak self] in self?.activateSelectedRow() }
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(activateSelectedRow)
        tableView.target = self
        tableView.setAccessibilityLabel(kind == .works ? String(localized: "Favorite works") : String(localized: "Favorite links"))
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        if !previewOnly {
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(favoriteDataChanged(_:)),
                name: .NSManagedObjectContextObjectsDidChange, object: nil)
        }
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let listContent = NSView()
        listContent.translatesAutoresizingMaskIntoConstraints = false
        listContent.addSubview(scrollView)
        panel.addArrangedSubview(listContent)
        NSLayoutConstraint.activate([
            listContent.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32),
            listContent.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            scrollView.leadingAnchor.constraint(equalTo: listContent.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContent.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContent.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContent.bottomAnchor),
        ])
        configureEmptyState(in: listContent)
        let commandDivider = NSBox()
        commandDivider.boxType = .separator
        panel.addArrangedSubview(commandDivider)
        commandDivider.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        panel.addArrangedSubview(commands)
        commands.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        let note = NSTextField(wrappingLabelWithString: kind == .works
            ? String(localized: "在詳情修改收藏分類；選取待同步作品後可重試同步。移除收藏不刪除下載。")
            : String(localized: "雙擊或按 Return 開啟；手動排序且無篩選時可拖曳。移除不刪除下載。"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        panel.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        if kind == .links { addLinkEditor(to: panel) }
        view = root
        root.bindSkin(skinAppearance, slot: "panel", componentID: componentID)
        panel.bindSkin(skinAppearance, slot: "list", componentID: componentID)
        heading.bindSkin(skinAppearance, slot: "header", componentID: componentID)
        countLabel.bindSkin(skinAppearance, slot: "emptyState", componentID: componentID)
        tableView.bindSkin(skinAppearance, slot: "list", componentID: componentID)
        searchField.bindSkin(skinAppearance, slot: "search", componentID: componentID)
        actionButton.bindSkin(skinAppearance, slot: "primaryAction", componentID: componentID)
        actionButton.updateSkinState()
        if previewOnly {
            statusLabel.stringValue = String(localized: "安全預覽：不讀取收藏資料或修改收藏")
            statusLabel.isHidden = false
            searchField.isEnabled = false
            sortPopup.isEnabled = false
            actionButton.isEnabled = false
            tableView.isEnabled = false
            urlField.isEnabled = false
            titleField.isEnabled = false
            updateEmptyState()
        } else if savedStateLoaded {
            refresh()
            startStatusRefresh()
        }
    }

    private func configureEmptyState(in container: NSView) {
        let icon = NSImageView(image: (kind == .works ? WorkspaceIcon.favorites : .bookmark).image(size: 24) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        emptyTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        emptyTitle.lineBreakMode = .byTruncatingTail
        let titleRow = NSStackView(views: [icon, emptyTitle])
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        emptyDetail.maximumNumberOfLines = 3
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 10
        emptyState.addArrangedSubview(titleRow)
        emptyState.addArrangedSubview(emptyDetail)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        container.addSubview(emptyState)
        let preferredWidth = emptyState.widthAnchor.constraint(equalToConstant: 280)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
            emptyState.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 8),
            emptyState.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
            emptyDetail.widthAnchor.constraint(equalTo: emptyState.widthAnchor),
            preferredWidth,
        ])
        emptyTitle.bindSkin(skinAppearance, slot: "emptyState", componentID: componentID)
        emptyDetail.bindSkin(skinAppearance, slot: "emptyState", componentID: componentID)
    }

    private func updateEmptyState() {
        emptyState.isHidden = !rows.isEmpty || errorMessage != nil
        guard !emptyState.isHidden else { return }
        let filtered = !query.isEmpty || (kind == .works ? collectionFilterIndex != 0
            : !selectedSite.isEmpty || liveFilterIndex != 0)
        emptyTitle.stringValue = filtered ? String(localized: "沒有符合條件的收藏")
            : (kind == .works ? String(localized: "收藏你的下一部作品") : String(localized: "把常看的連結留在這裡"))
        emptyDetail.stringValue = filtered ? String(localized: "試試其他關鍵詞，或調整上方的篩選條件。")
            : (kind == .works ? String(localized: "從搜尋或推薦開啟作品詳情，即可加入收藏。")
                : String(localized: "在下方貼上網址，收藏影片、直播或常用頁面。"))
    }

    private var sortIndex: Int {
        switch sort {
        case .manual: 0
        case .title: 1
        case .createdNewest: 2
        }
    }

    private func addLinkEditor(to panel: NSStackView) {
        let editor = NSStackView(views: [])
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 6
        urlField.placeholderString = String(localized: "影片或頁面網址")
        titleField.placeholderString = String(localized: "標題（選填）")
        urlField.setAccessibilityLabel(String(localized: "Favorite link URL"))
        titleField.setAccessibilityLabel(String(localized: "Favorite link title"))
        let add = WorkspaceSkinButton(title: String(localized: "新增連結"), target: self, action: #selector(addLink))
        add.setFunctionIcon(.add)
        add.isEnabled = !previewOnly
        add.bindSkin(skinAppearance, slot: "primaryAction", componentID: componentID)
        add.bezelStyle = .rounded
        editor.addArrangedSubview(urlField)
        let titleRow = NSStackView(views: [titleField, add])
        titleRow.spacing = 6
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editor.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        panel.addArrangedSubview(editor)
        editor.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        urlField.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
    }

    private func loadSavedState() {
        let saved = sessionState.state(for: instanceID)
        query = saved.query
        selectedIdentity = saved.selection
        sort =
            switch saved.filter.components(separatedBy: "|").first ?? "manual" {
            case "title": .title
            case "createdNewest": .createdNewest
            default: .manual
            }
        let filters = saved.filter.components(separatedBy: "|")
        if filters.count == 3 { liveFilterIndex = Int(filters[1]) ?? 0; selectedSite = filters[2] }
        if kind == .works, filters.count == 2 {
            let key = filters[1]
            if key == "pending" {
                collectionFilterIndex = BangumiCollectionStatus.displayOrder.count + 1
            } else if key.hasPrefix("status:"), let raw = Int(key.dropFirst(7)),
                      let status = BangumiCollectionStatus(rawValue: raw),
                      let index = BangumiCollectionStatus.displayOrder.firstIndex(of: status) {
                collectionFilterIndex = index + 1
            } else if let legacy = Int(key), legacy > 0 {
                // Old indices: all, unclassified, five categories, pending.
                collectionFilterIndex = legacy == 1 ? 1
                    : min(legacy - 1, BangumiCollectionStatus.displayOrder.count + 1)
            }
        }
        searchField.stringValue = saved.query
        sortPopup.selectItem(at: sortIndex)
        savedScrollPosition = saved.scrollPosition
        savedStateLoaded = true
    }

    func attach() {
        guard !previewOnly, !attached, isViewLoaded else { return }
        attached = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(favoriteDataChanged(_:)), name: .NSManagedObjectContextObjectsDidChange, object: nil)
        refresh()
        startStatusRefresh()
    }

    func detach() {
        storeState()
        attached = false
        NotificationCenter.default.removeObserver(
            self, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.removeObserver(
            self, name: .NSManagedObjectContextObjectsDidChange, object: nil)
        requestTask?.cancel()
        requestTask = nil
        statusRefreshTask?.cancel(); statusRefreshTask = nil
        liveRequest?.cancel(); liveRequest = nil
        onlineTask?.cancel(); onlineTask = nil
        onlineGeneration = UUID()
        retryTask?.cancel(); retryTask = nil
        retryGeneration = UUID()
        retryButton.title = String(localized: "重試同步")
        onlineButton.title = String(localized: "載入在線收藏")
        onlineButton.setFunctionIcon(.importFile)
        onlineStatus.isHidden = true
    }

    @objc private func loadOnlineFavorites() {
        guard kind == .works, !previewOnly, attached else { return }
        if let onlineTask {
            onlineTask.cancel()
            self.onlineTask = nil
            onlineGeneration = UUID()
            onlineButton.title = String(localized: "載入在線收藏")
            onlineButton.setFunctionIcon(.importFile)
            onlineStatus.stringValue = String(localized: "已取消載入；本機收藏保留。")
            return
        }
        let generation = UUID()
        onlineGeneration = generation
        onlineButton.title = String(localized: "取消載入")
        onlineButton.setFunctionIcon(.close)
        onlineStatus.workspaceSkinBinding?.state = .normal
        onlineStatus.stringValue = String(localized: "正在載入目前 Bangumi 帳號的番劇收藏…")
        onlineStatus.isHidden = false
        onlineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await self.loadOnlineCollections()
                guard self.attached, self.onlineGeneration == generation, !Task.isCancelled else { return }
                self.refresh()
                self.onlineStatus.stringValue = count == 0 ? String(localized: "此 Bangumi 帳號沒有番劇收藏；本機收藏保留。")
                    : String(localized: "已載入 \(count) 部在線收藏；保留本機待同步修改。")
            } catch {
                guard self.attached, self.onlineGeneration == generation, !Task.isCancelled else { return }
                self.onlineStatus.workspaceSkinBinding?.state = .error
                self.onlineStatus.stringValue = String(localized: "載入在線收藏失敗：\(error.localizedDescription)")
            }
            guard self.onlineGeneration == generation else { return }
            self.onlineTask = nil
            self.onlineButton.title = String(localized: "載入在線收藏")
            self.onlineButton.setFunctionIcon(.importFile)
        }
    }
    private func updateRetryButton() {
        guard !previewOnly, attached, retryTask == nil, rows.indices.contains(tableView.selectedRow),
              case .work(let work) = rows[tableView.selectedRow] else {
            retryButton.isEnabled = false
            return
        }
        retryButton.isEnabled = work.collectionStatusPending && work.collectionStatus != nil
    }

    @objc private func retrySelectedCollection() {
        guard kind == .works, !previewOnly, attached, retryTask == nil,
              rows.indices.contains(tableView.selectedRow),
              case .work(let work) = rows[tableView.selectedRow],
              work.collectionStatusPending, work.collectionStatus != nil else { return }
        let generation = UUID()
        retryGeneration = generation
        retryButton.title = String(localized: "同步中…")
        retryButton.isEnabled = false
        retryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.retryCollectionStatus(work.id)
                guard self.attached, self.retryGeneration == generation, !Task.isCancelled else { return }
                self.refresh()
                self.onlineStatus.workspaceSkinBinding?.state = .normal
                self.onlineStatus.stringValue = String(localized: "已同步收藏分類。")
            } catch {
                guard self.attached, self.retryGeneration == generation, !Task.isCancelled else { return }
                self.onlineStatus.workspaceSkinBinding?.state = .error
                self.onlineStatus.stringValue = String(localized: "同步失敗：\(error.localizedDescription)")
            }
            guard self.retryGeneration == generation else { return }
            self.onlineStatus.isHidden = false
            self.retryTask = nil
            self.retryButton.title = String(localized: "重試同步")
            self.updateRetryButton()
        }
    }


    @objc private func scrollBoundsChanged(_ notification: Notification) { storeState() }

    @objc private func favoriteDataChanged(_ notification: Notification) { guard !previewOnly else { return }; scheduleRefresh() }
    func controlTextDidChange(_ notification: Notification) {
        guard !previewOnly else { return }
        guard let field = notification.object as? NSSearchField else { return }
        query = field.stringValue
        scheduleRefresh()
        storeState()
    }

    @objc private func sortChanged() {
        guard !previewOnly else { return }
        switch sortPopup.indexOfSelectedItem {
        case 1: sort = .title
        case 2: sort = .createdNewest
        default: sort = .manual
        }
        scheduleRefresh()
        storeState()
    }

    var favoriteUndoManager: UndoManager? { dataManager?.context.undoManager }
    @objc func reload(_ sender: Any?) { refreshLiveStatus(); refresh() }
    @objc private func linkFilterChanged() {
        guard !previewOnly else { return }
        liveFilterIndex = liveFilter.indexOfSelectedItem
        selectedSite = siteFilter.selectedItem?.representedObject as? String ?? ""
        refresh(); storeState()
    }
    @objc private func collectionFilterChanged() {
        guard !previewOnly else { return }
        collectionFilterIndex = collectionFilter.indexOfSelectedItem
        refresh()
        storeState()
    }
    @objc private func refreshLiveStatus() {
        guard !previewOnly, attached, let dataManager, liveRequest == nil else { return }
        liveRequest = Task { [weak self] in
            await dataManager.reloadAllBookmark()
            self?.liveRequest = nil
        }
    }
    private func startStatusRefresh() {
        guard kind == .links, dataManager != nil, !previewOnly else { return }
        refreshLiveStatus()
        statusRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.attached else { return }
                self.refreshLiveStatus()
            }
        }
    }

    @objc private func primaryAction() {
        guard !previewOnly else { return }
        guard let selectedIdentity, let id = UUID(uuidString: selectedIdentity), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "移除收藏？")
        alert.informativeText = String(localized: "僅移除收藏；下載任務、已下載檔案與作品資料都會保留。")
        alert.addButton(withTitle: String(localized: "移除收藏"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.attached else { return }
            self.removeFavorite(id: id)
        }
    }

    private func removeFavorite(id: UUID) {
        do {
            switch kind {
            case .works: try favorites.removeWork(workID: id)
            case .links: try favorites.deleteLink(id: id)
            }
            self.selectedIdentity = nil
            refresh()
        } catch { showError(error) }
    }

    @objc private func addLink() {
        guard !previewOnly else { return }
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        do {
            let link = try favorites.addLink(
                url: url, title: titleField.stringValue.isEmpty ? nil : titleField.stringValue)
            urlField.stringValue = ""
            titleField.stringValue = ""
            selectedIdentity = link.id.uuidString
            refresh()
            refreshLiveStatus()
        } catch { showError(error) }
    }

    @objc private func activateSelectedRow() {
        guard !previewOnly else { return }
        let index = tableView.selectedRow
        guard rows.indices.contains(index) else { return }
        let sourceView = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
        actions.withTransitionSource(from: sourceView) {
            switch rows[index] {
            case .work(let work): actions.openWork(work.id)
            case .link(let link): actions.openLink(link.originalURL)
            }
        }
    }
    @objc private func editSelectedRow() {
        guard !previewOnly, rows.indices.contains(tableView.selectedRow), let window = view.window else { return }
        let row = rows[tableView.selectedRow]
        let alert = NSAlert()
        alert.messageText = String(localized: "編輯收藏")
        alert.informativeText = String(localized: "修改不影響下載；暫時無法使用的連結可保留原網址。")
        alert.addButton(withTitle: String(localized: "儲存"))
        alert.addButton(withTitle: String(localized: "取消"))
        let editor = NSStackView()
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 8
        let name = NSTextField()
        let value = NSTextField()
        name.setAccessibilityLabel(String(localized: "Favorite title"))
        switch row {
        case .work(let work):
            name.stringValue = work.title
            value.stringValue = work.aliases.joined(separator: "\n")
            value.usesSingleLineMode = false
            value.maximumNumberOfLines = 4
            value.setAccessibilityLabel(String(localized: "Work aliases, one per line"))
        case .link(let link):
            name.stringValue = link.title
            value.stringValue = link.originalURL
            value.setAccessibilityLabel(String(localized: "Favorite link URL"))
        }
        for (label, field) in [(String(localized: "標題"), name), (kind == .works ? String(localized: "別名（每行一項）") : String(localized: "網址"), value)] {
            editor.addArrangedSubview(NSTextField(labelWithString: label))
            editor.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        alert.accessoryView = editor
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.attached else { return }
            do {
                switch row {
                case .work(let work):
                    try self.favorites.updateWork(workID: work.id, title: name.stringValue,
                        aliases: value.stringValue.components(separatedBy: .newlines).filter { !$0.isEmpty })
                case .link(let link):
                    try self.favorites.updateLink(id: link.id, url: value.stringValue, title: name.stringValue)
                }
                self.refresh()
            } catch { self.showError(error) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = WorkspaceSkinRowView()
        view.bindSkin(
            skinAppearance, slot: kind == .works ? "workRow" : "linkRow", componentID: componentID)
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        (kind == .works ? 96 : 72) + CGFloat(sessionState.state(for: instanceID).density * 16)
    }
    func presentationSettingsDidChange() { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard rows.indices.contains(row) else { return nil }
        let text: String
        let subtitle: String
        switch rows[row] {
        case .work(let work):
            text = work.title
            subtitle = [work.collectionStatus?.title,
                work.collectionStatusPending ? String(localized: "待同步") : nil,
                work.classification.kind.title, work.year.map(String.init), sourceDescriptions[work.id]]
                .compactMap { $0 }.joined(separator: " · ")
        case .link(let link):
            let bookmark = bookmarks[link.id]
            text = link.title
            let state: String = switch Int(bookmark?.state ?? -1) {
            case 1: String(localized: "直播中")
            case 0: String(localized: "未開播")
            case -99: String(localized: "影片")
            default: String(localized: "狀態未知")
            }
            subtitle = [state, link.sourceID, bookmark?.liveName, bookmark?.liveTitle, link.originalURL]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let cell = NSTableCellView()
        let coverURL: String?
        if case .work(let work) = rows[row] { coverURL = work.coverURL }
        else if case .link(let link) = rows[row] { coverURL = bookmarks[link.id]?.cover }
        else { coverURL = nil }
        let poster: Bool
        if case .work(let work) = rows[row] { poster = work.classification.kind == .anime }
        else { poster = false }
        let thumbnail = WorkspaceMediaThumbnail(url: coverURL, poster: poster,
            appearance: skinAppearance, componentID: componentID, previewOnly: previewOnly)
        thumbnail.layer?.masksToBounds = true
        cell.addSubview(thumbnail)
        thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8).isActive = true
        thumbnail.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.toolTip = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        cell.textField = label
        let detail = NSTextField(labelWithString: subtitle)
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = subtitle
        detail.textColor = .secondaryLabelColor
        if case .link(let link) = rows[row] {
            switch Int(bookmarks[link.id]?.state ?? -1) {
            case 1: detail.textColor = Preferences.shared.stateLiving
            case 0: detail.textColor = Preferences.shared.stateOffline
            case -99: detail.textColor = Preferences.shared.stateReplay
            default: detail.textColor = Preferences.shared.stateUnknown
            }
        }
        detail.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [label, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -6),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        label.bindSkin(
            skinAppearance, slot: kind == .works ? "workCard" : "linkRow", componentID: componentID)
        cell.setAccessibilityLabel([text, subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !previewOnly else { return }
        guard !suppressSelectionChanges else { return }
        let selected = tableView.selectedRow
        if rows.indices.contains(selected) {
            switch rows[selected] {
            case .work(let work): selectedIdentity = work.id.uuidString
            case .link(let link): selectedIdentity = link.id.uuidString
            }
        } else {
            selectedIdentity = nil
        }
        actionButton.isEnabled = selectedIdentity != nil
        openButton.isEnabled = selectedIdentity != nil
        editButton.isEnabled = selectedIdentity != nil
        updateRetryButton()
        storeState()
    }

    private func scheduleRefresh() {
        guard !previewOnly else { return }
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, self.attached, !Task.isCancelled else { return }
            self.refresh()
        }
    }

    private func refresh() {
        guard !previewOnly else { return }
        guard isViewLoaded, attached else { return }
        do {
            statusLabel.workspaceSkinBinding?.state = .normal
            errorMessage = nil
            switch kind {
            case .works:
                let works = try favorites.works(query: query, sort: sort).filter { work in
                    switch collectionFilterIndex {
                    case 0: return true
                    case 1...BangumiCollectionStatus.displayOrder.count:
                        return work.collectionStatus == BangumiCollectionStatus.displayOrder[collectionFilterIndex - 1]
                    default: return work.collectionStatusPending
                    }
                }
                sourceDescriptions = try Dictionary(uniqueKeysWithValues: works.map { work in
                    let sources = try favorites.sources(workID: work.id)
                    let names = Set(sources.map { $0.sourceWork.sourceID }).sorted()
                    return (work.id, names.isEmpty ? String(localized: "尚未關聯來源") : names.joined(separator: ", "))
                })
                rows = works.map(Row.work)
            case .links:
                let objects = dataManager?.requestData() ?? []
                bookmarks = Dictionary(objects.compactMap { bookmark in
                    (bookmark.value(forKey: "favoriteID") as? UUID).map { ($0, bookmark) }
                }, uniquingKeysWith: { first, _ in first })
                let links = try favorites.links(query: query, sort: sort)
                let allLinks = try (query.isEmpty && sort == .manual ? links : favorites.links())
                let sites = Set(allLinks.map(siteIdentity)).sorted()
                siteFilter.removeAllItems(); siteFilter.addItem(withTitle: String(localized: "全部來源"))
                for siteID in sites {
                    let site = allLinks.first { siteIdentity($0) == siteID }.map { SupportSites(url: $0.canonicalURL ?? $0.originalURL) }
                    siteFilter.addItem(withTitle: site?.siteName ?? String(localized: "未知來源"))
                    siteFilter.lastItem?.representedObject = siteID
                }
                siteFilter.selectItem(at: sites.firstIndex(of: selectedSite).map { $0 + 1 } ?? 0)
                rows = links.filter { link in
                    if !selectedSite.isEmpty && siteIdentity(link) != selectedSite { return false }
                    if selectedSite == "bilibili" || selectedSite == "bilibili-bangumi" { return true }
                    let state = Int(bookmarks[link.id]?.state ?? -1)
                    switch liveFilterIndex {
                    case 1: return state == 1
                    case 2: return state == 0
                    case 3: return state == -1 || state == -99
                    default: return true
                    }
                }.map(Row.link)
            }
            statusLabel.isHidden = true
        } catch {
            rows = []
            statusLabel.workspaceSkinBinding?.state = .error
            errorMessage = error.localizedDescription
            statusLabel.stringValue = String(localized: "無法載入收藏：\(error.localizedDescription)")
            statusLabel.isHidden = false
        }
        countLabel.stringValue = String(localized: "\(rows.count) 項")
        let scrollOffset = savedScrollPosition
        suppressSelectionChanges = true
        tableView.reloadData()
        if let selectedIdentity,
            let index = rows.firstIndex(where: { identity(of: $0) == selectedIdentity })
        {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateEmptyState()
        suppressSelectionChanges = false
        restoreScrollPosition(scrollOffset)
        actionButton.isEnabled =
            selectedIdentity != nil
            && rows.contains(where: { identity(of: $0) == selectedIdentity })
        openButton.isEnabled = actionButton.isEnabled
        editButton.isEnabled = actionButton.isEnabled
        updateRetryButton()
    }

    private func identity(of row: Row) -> String {
        switch row {
        case .work(let value): value.id.uuidString
        case .link(let value): value.id.uuidString
        }
    }


    private func siteIdentity(_ link: LinkFavorite) -> String {
        if SupportSites(url: link.canonicalURL ?? link.originalURL) == .bangumi { return "bilibili-bangumi" }
        return link.sourceID ?? "unsupported"
    }
    private var permitsReordering: Bool {
        !previewOnly && sort == .manual && query.isEmpty && selectedSite.isEmpty
            && liveFilterIndex == 0 && collectionFilterIndex == 0
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard permitsReordering, rows.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(identity(of: rows[row]), forType: Self.dragType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard permitsReordering, info.draggingSource as? NSTableView === tableView,
              info.draggingPasteboard.string(forType: Self.dragType) != nil else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard permitsReordering, info.draggingSource as? NSTableView === tableView,
              let value = info.draggingPasteboard.string(forType: Self.dragType),
              let id = UUID(uuidString: value), let old = rows.firstIndex(where: { identity(of: $0) == value }),
              row >= 0, row <= rows.count else { return false }
        do {
            let destination = row > old ? row - 1 : row
            switch kind {
            case .works: try favorites.moveWork(workID: id, toIndex: destination)
            case .links: try favorites.moveLink(id: id, toIndex: destination)
            }
            refresh(); storeState(); return true
        } catch { showError(error); return false }
    }
    private func showError(_ error: Error) {
        statusLabel.workspaceSkinBinding?.state = .error
        errorMessage = error.localizedDescription
        statusLabel.stringValue = error.localizedDescription
        statusLabel.isHidden = false
    }

    private var collectionFilterKey: String {
        if collectionFilterIndex == 0 { return "all" }
        let index = collectionFilterIndex - 1
        guard BangumiCollectionStatus.displayOrder.indices.contains(index) else { return "pending" }
        return "status:\(BangumiCollectionStatus.displayOrder[index].rawValue)"
    }

    private func storeState() {
        guard attached else { return }
        guard !previewOnly else { return }
        savedScrollPosition = Double(scrollView.contentView.bounds.origin.y)
        let state = WorkspaceInstanceState(
            query: query, filter: kind == .links ? "\(sortKey)|\(liveFilterIndex)|\(selectedSite)" : "\(sortKey)|\(collectionFilterKey)", selection: selectedIdentity,
            scrollPosition: savedScrollPosition, density: sessionState.state(for: instanceID).density)
        do { try sessionState.update(state, for: instanceID) }
        catch {
            if let window = view.window { window.presentError(error) }
            else { showError(error) }
        }
    }

    private var sortKey: String {
        switch sort {
        case .manual: "manual"
        case .title: "title"
        case .createdNewest: "createdNewest"
        }
    }

    private func restoreScrollPosition(_ offset: Double) {
        guard isViewLoaded else { return }
        let maxY = max(
            0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
        let point = NSPoint(x: 0, y: min(max(0, offset), maxY))
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
