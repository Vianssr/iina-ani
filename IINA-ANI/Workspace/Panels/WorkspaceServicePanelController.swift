import AppKit

@MainActor
protocol WorkspaceDetachablePanel: AnyObject {
    func attach()
    func detach()
}

@MainActor
final class WorkspaceServicePanelController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSSearchFieldDelegate, WorkspaceDetachablePanel
{
    private enum PanelKind: Equatable { case schedule, updates, recommendations, continuing, feed, followed, bilibiliRecommendations, youtube, search, downloads }
    private enum YouTubeCookieImportError: Error { case invalidFileSize }
    let componentID: String
    private let instanceID: UUID
    private let kind: PanelKind
    private let dependencies: WorkspaceWindowDependencies
    private let previewOnly: Bool
    private let heading = NSTextField(labelWithString: "")
    private let count = WorkspacePanelCountBadge(labelWithString: "0")
    private let status = WorkspaceSkinStatusLabel(wrappingLabelWithString: "")
    private let queryField = WorkspaceSkinSearchField()
    private let table = NSTableView()
    private lazy var cards = WorkspaceDiscoveryCollectionView()
    private var isBilibiliVideoGrid: Bool { kind == .followed || kind == .bilibiliRecommendations }
    private var isVideoGrid: Bool { isBilibiliVideoGrid || kind == .youtube }
    private var isDiscovery: Bool { kind == .schedule || kind == .updates || kind == .recommendations || kind == .continuing || kind == .feed || isVideoGrid }
    private var isHorizontalDiscovery: Bool { isDiscovery && kind != .feed && kind != .schedule && !isVideoGrid }
    private var selectedIndex: Int { isDiscovery ? cards.selectionIndexPaths.first?.item ?? -1 : table.selectedRow }
    private let scroll = WorkspaceScrollView()
    private weak var pageScrollOwner: WorkspaceScrollView?
    private var expandedFeedHeight: NSLayoutConstraint?
    private var expandedFeedWidth: NSLayoutConstraint?
    private weak var panelStack: NSStackView?
    private var feedHeightUpdateScheduled = false
    private var pendingPageScrollPosition: Double?
    private let primary = WorkspaceSkinButton()
    private let secondary = WorkspaceSkinButton()
    private let cancelButton = WorkspaceSkinButton()
    private var rows: [String] = []
    private enum Destination {
        case bangumi(Int, BangumiSubject?), work(UUID), update(DiscoveryFavoriteUpdate), selection(PlayableSelection), address(String)
        case resume(PlaybackHistoryEntry)
    }
    private var destinations: [Destination?] = []
    private var coverURLs: [String?] = []
    private var posters: [Bool] = []
    private let category = NSPopUpButton()
    private let sourceFilter = NSPopUpButton()
    private var sourceIDs: [String] = [""]
    private var searchSnapshot: BrowseSearchSnapshot?
    private var searchTitles: [String] = []
    private var searchGeneration: UInt64 = 0
    private var filter = ""
    private let revealButton = WorkspaceSkinButton()
    private let openFileButton = WorkspaceSkinButton()
    private let deleteRecordButton = WorkspaceSkinButton()
    private let deleteFileButton = WorkspaceSkinButton()
    private let downloadSelection = NSTextField(labelWithString: String(localized: "請先選取下載任務，再使用下方操作。"))
    private var selectedRowID: String?
    private var query = ""
    private var attached = true
    private var savedScrollPosition: Double = 0
    private var suppressSelectionChanges = false
    private var operation: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var sourceMenuTask: Task<Void, Never>?
    private var searching = false
    private var browseSearch: BrowseSearchService?
    private var downloadService: DownloadService?
    private var downloads: [DownloadRecord] = []
    private var completedDownloadIDs = Set<UUID>()
    var contentHeightDidChange: ((Double) -> Void)?
    private var historyEntries: [PlaybackHistoryEntry] = []
    private var historyReloadTask: Task<Void, Never>?
    var continueHeight: Double { historyEntries.isEmpty ? 76 : 164 }
    var favoriteUpdatesHeight: Double { rows.isEmpty ? 84 : 240 }
    private var followedCards: [BilibiliCard] = []
    private var followedManager: BilibiliDynamicManger?
    private var followedLoading = false
    private var followedFailure: String?
    private var recommendationTask: Task<Void, Never>?
    private var recommendationGeneration: UInt64 = 0
    private var recommendationNextPage = 1
    private var recommendationLoading = false
    private var recommendationFailure: String?
    private var recommendationAllowsAutoLoad = false
    private var recommendationSeen = Set<String>()
    private var youtubeVideos: [YouTubeVideo] = []
    private var youtubeContinuation: YouTubeContinuation?
    private var youtubeQuery = ""
    private var youtubeLoading = false
    private var youtubeFailure: String?
    private var youtubeMessage: String?
    private var youtubeGeneration: UInt64 = 0
    private var youtubeTask: Task<Void, Never>?
    private var youtubeSeen = Set<String>()
    private var youtubeAllowsAutoLoad = false
    private var youtubeNeedsFirstPage = true
    private var youtubeAccount: SiteAccount?
    private var youtubeAccountBusy = false
    private let youtubeAccountLabel = NSTextField(labelWithString: "")
    private let youtubeImportButton = WorkspaceSkinButton()
    private let youtubeSignOutButton = WorkspaceSkinButton()
    private var youtubeBrowseControls: [NSControl] = []
    private weak var youtubeOpenPanel: NSOpenPanel?
    private var youtubeImportAlert: NSAlert?
    private var feedPage = 2
    private var feedHasMore = true
    private var feedLoading = false
    private var feedFailure: String?
    private var feedSeen = Set<Int>()
    private var feedGeneration: UInt64 = 0
    private let weekdayNames = [String(localized: "周日"), String(localized: "周一"), String(localized: "周二"), String(localized: "周三"), String(localized: "周四"), String(localized: "周五"), String(localized: "周六")]
    private let weekdayOrder = [7, 1, 2, 3, 4, 5, 6]

    init(
        instanceID: UUID, componentID: WorkspaceComponentID,
        dependencies: WorkspaceWindowDependencies, previewOnly: Bool = false
    ) {
        self.instanceID = instanceID
        self.componentID = componentID.rawValue
        self.dependencies = dependencies
        self.previewOnly = previewOnly
        switch componentID.rawValue {
        case "discovery.schedule": kind = .schedule
        case "discovery.updates": kind = .updates
        case "discovery.recommendations": kind = .recommendations
        case "playback.continue": kind = .continuing
        case "discovery.feed": kind = .feed
        case "discovery.followed": kind = .followed
        case "discovery.bilibiliRecommendations": kind = .bilibiliRecommendations
        case "discovery.youtube": kind = .youtube
        case "search.results": kind = .search
        default: kind = .downloads
        }
        super.init(nibName: nil, bundle: nil)
        switch kind {
        case .schedule: title = String(localized: "全週放送 · Bangumi 日曆")
        case .updates: title = String(localized: "收藏更新")
        case .recommendations: title = String(localized: "熱度趨勢")
        case .continuing: title = String(localized: "繼續觀看")
        case .feed: title = String(localized: "推薦")
        case .followed: title = String(localized: "Bilibili 關注動態")
        case .bilibiliRecommendations: title = String(localized: "Bilibili 推薦影片")
        case .youtube: title = "YouTube"
        case .search: title = String(localized: "Search")
        case .downloads: title = String(localized: "Downloads")
        }
        if case .search = kind, !previewOnly { browseSearch = dependencies.makeSearch() }
        if !previewOnly {
            let saved = dependencies.sessionState.state(for: instanceID)
            query = saved.query
            queryField.stringValue = saved.query
            filter = saved.filter
            selectedRowID = saved.selection
            savedScrollPosition = saved.scrollPosition
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = WorkspaceDragRegionView()
        root.scrollOwner = scroll
        let panel = NSStackView(views: [])
        panelStack = panel
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 10
        panel.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
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
        header.spacing = 10
        heading.stringValue = title ?? "IINA-ANI"
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.lineBreakMode = .byTruncatingTail
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        count.alignment = .center
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setAccessibilityLabel(String(localized: "已載入項目數"))
        header.addArrangedSubview(heading)
        header.addArrangedSubview(count)
        if kind == .recommendations || kind == .schedule {
            let source = NSTextField(labelWithString: "BANGUMI")
            source.font = .systemFont(ofSize: 9, weight: .semibold)
            source.textColor = .tertiaryLabelColor
            source.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            header.addArrangedSubview(source)
        }
        header.addArrangedSubview(NSView())
        primary.bezelStyle = .rounded
        primary.target = self
        primary.action = #selector(primaryAction)
        secondary.bezelStyle = .rounded
        secondary.target = self
        secondary.action = #selector(secondaryAction)
        cancelButton.title = String(localized: "Cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelectedDownload)
        configureActions()
        if kind == .updates { primary.title = String(localized: "刷新") }
        header.addArrangedSubview(WorkspaceDensityButton(
            instanceID: instanceID, sessionState: dependencies.sessionState,
            appearance: dependencies.skinAppearance, componentID: componentID, previewOnly: previewOnly
        ) { [weak self] in self?.presentationSettingsDidChange() })
        if kind != .downloads {
            header.addArrangedSubview(primary)
            if !secondary.isHidden { header.addArrangedSubview(secondary) }
            if kind == .search { header.addArrangedSubview(cancelButton) }
        }
        panel.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        if kind == .schedule {
            let weekdays = NSStackView(views: weekdayNames.map { name in
                let label = NSTextField(labelWithString: name)
                label.alignment = .center
                label.font = .boldSystemFont(ofSize: 14)
                return label
            })
            weekdays.orientation = .horizontal
            weekdays.distribution = .fillEqually
            weekdays.spacing = 0
            panel.addArrangedSubview(weekdays)
            weekdays.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        }

        if kind == .search {
            queryField.placeholderString = String(localized: "Keyword or media URL")
            queryField.delegate = self
            queryField.sendsSearchStringImmediately = false
            queryField.target = self
            queryField.action = #selector(primaryAction)
            queryField.controlSize = .large
            queryField.font = .systemFont(ofSize: 15)
            let imageSearch = WorkspaceSkinButton(
                title: String(localized: "截圖識圖…"), target: self, action: #selector(openImageSearch))
            imageSearch.bezelStyle = .rounded
            imageSearch.isEnabled = !previewOnly
            imageSearch.setAccessibilityIdentifier("search.imageSearch")
            imageSearch.setContentCompressionResistancePriority(.required, for: .horizontal)
            imageSearch.bindSkin(dependencies.skinAppearance, slot: "primaryAction", componentID: componentID)
            let searchRow = NSStackView(views: [queryField, imageSearch])
            searchRow.spacing = 8
            panel.addArrangedSubview(searchRow)
            searchRow.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
            queryField.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
            category.addItems(withTitles: BrowseContentFilter.allCases.map(\.title))
            category.target = self
            category.action = #selector(filterChanged)
            category.setAccessibilityLabel(String(localized: "搜尋分類"))
            sourceFilter.addItem(withTitle: String(localized: "全部啟用來源"))
            sourceFilter.target = self
            sourceFilter.action = #selector(sourceChanged)
            sourceFilter.setAccessibilityLabel(String(localized: "搜尋來源"))
            let savedFilter = filter.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let savedCategory = BrowseContentFilter(rawValue: savedFilter.first ?? "") ?? .anime
            category.selectItem(at: BrowseContentFilter.allCases.firstIndex(of: savedCategory) ?? 0)
            if savedCategory != .anime, savedFilter.count == 2, !savedFilter[1].isEmpty {
                sourceIDs.append(savedFilter[1])
                sourceFilter.addItem(withTitle: savedFilter[1])
                sourceFilter.selectItem(at: 1)
            }
            filter = "\(savedCategory.rawValue)|\(sourceIDs[sourceFilter.indexOfSelectedItem])"
            if savedCategory == .anime {
                sourceFilter.removeAllItems()
                sourceFilter.addItem(withTitle: "Bangumi")
                sourceFilter.isEnabled = false
            }
            panel.addArrangedSubview(NSStackView(views: [category, sourceFilter]))
        }
        if kind == .youtube { configureYouTubeControls(in: panel) }
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = kind == .search ? 0 : 3
        status.isHidden = true
        let statusPresentation = status.presentation(
            appearance: dependencies.skinAppearance, componentID: componentID)
        if kind != .feed {
            panel.addArrangedSubview(statusPresentation)
            statusPresentation.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        }
        if isBilibiliVideoGrid {
            let buttons: [(String, Selector, WorkspaceIcon?)] = [(String(localized: "開啟影片"), #selector(activateSelection), .play),
                (String(localized: "複製網址"), #selector(copyFollowedURL), nil), (String(localized: "原始頁面"), #selector(openFollowedPage), .openLink)]
            let commands = NSStackView()
            for (title, action, icon) in buttons {
                let button = WorkspaceSkinButton(title: title, target: self, action: action)
                button.setFunctionIcon(icon)
                button.bezelStyle = .rounded; button.isEnabled = !previewOnly
                button.bindSkin(dependencies.skinAppearance, slot: "primaryAction", componentID: componentID)
                commands.addArrangedSubview(button)
            }
            panel.addArrangedSubview(commands)
        }
        if kind == .downloads {
            downloadSelection.lineBreakMode = .byTruncatingTail
            downloadSelection.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            downloadSelection.bindSkin(dependencies.skinAppearance, slot: "header", componentID: componentID)
            panel.addArrangedSubview(downloadSelection)
            downloadSelection.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
            let taskActions = NSStackView(views: [primary, secondary, cancelButton])
            taskActions.orientation = .horizontal
            taskActions.spacing = 8
            panel.addArrangedSubview(taskActions)
            let buttons: [(WorkspaceSkinButton, String, Selector, WorkspaceIcon)] = [
                (openFileButton, String(localized: "播放器開啟"), #selector(openCompletedFile), .play),
                (revealButton, String(localized: "顯示於 Finder"), #selector(revealCompletedFile), .folder),
                (deleteRecordButton, String(localized: "刪除記錄"), #selector(deleteSelectedRecord), .delete),
                (deleteFileButton, String(localized: "刪除完成檔"), #selector(deleteSelectedFile), .delete)]
            for (button, title, action, icon) in buttons {
                button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded
                button.setFunctionIcon(icon)
                button.setAccessibilityLabel(title)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                button.bindSkin(dependencies.skinAppearance, slot: "primaryAction", componentID: componentID)
                button.updateSkinState()
            }
            panel.addArrangedSubview(NSStackView(views: buttons.map { $0.0 }))
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("results"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(activateSelection)
        table.setAccessibilityLabel(heading.stringValue)
        if isDiscovery {
            cards.collectionViewLayout = discoveryLayout()
            cards.dataSource = self
            cards.delegate = self
            cards.isSelectable = !previewOnly
            cards.allowsMultipleSelection = false
            cards.backgroundColors = [.clear]
            cards.autoresizingMask = isHorizontalDiscovery ? [.height] : [.width]
            cards.register(WorkspaceDiscoveryCard.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("discovery.card"))
            cards.register(WorkspaceResumeCard.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("playback.resume"))
            cards.register(WorkspaceFollowedCard.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("followed.video"))
            cards.activate = { [weak self] in self?.activateSelection() }
            if kind == .continuing {
                cards.contextMenu = { [weak self] indexPath in self?.historyMenu(at: indexPath) }
            }
            let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(activateDiscoveryCard(_:)))
            doubleClick.numberOfClicksRequired = kind == .continuing ? 1 : 2
            cards.addGestureRecognizer(doubleClick)
            cards.setAccessibilityLabel(heading.stringValue + (isHorizontalDiscovery ? String(localized: " · 水平內容") : String(localized: " · 垂直內容")))
            scroll.setAccessibilityLabel(heading.stringValue + (kind == .feed || isVideoGrid ? String(localized: " · 向下捲動載入更多") : isHorizontalDiscovery ? String(localized: " · 水平捲動") : String(localized: " · 全週垂直捲動")))
            scroll.documentView = cards
            scroll.hasHorizontalScroller = isHorizontalDiscovery
            scroll.hasVerticalScroller = !isHorizontalDiscovery
            scroll.autohidesScrollers = true
        } else {
            scroll.documentView = table
            scroll.hasVerticalScroller = true
        }
        if !previewOnly {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: kind == .continuing || kind == .updates ? 0 : 120).isActive = true
        if kind == .feed {
            // Loading must not insert/remove space above the cards. Keep a footer
            // even while its status row is hidden, including in standalone panels.
            let footer = NSView()
            footer.translatesAutoresizingMaskIntoConstraints = false
            statusPresentation.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(statusPresentation)
            panel.addArrangedSubview(footer)
            NSLayoutConstraint.activate([
                footer.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32),
                footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
                statusPresentation.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
                statusPresentation.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
                statusPresentation.topAnchor.constraint(equalTo: footer.topAnchor),
                statusPresentation.bottomAnchor.constraint(lessThanOrEqualTo: footer.bottomAnchor),
            ])
            let preferredHeight = footer.heightAnchor.constraint(equalToConstant: 32)
            preferredHeight.priority = .defaultHigh
            preferredHeight.isActive = true
        }
        view = root
        root.bindSkin(dependencies.skinAppearance, slot: "panel", componentID: componentID)
        panel.bindSkin(dependencies.skinAppearance, slot: "list", componentID: componentID)
        heading.bindSkin(dependencies.skinAppearance, slot: "header", componentID: componentID)
        queryField.bindSkin(dependencies.skinAppearance, slot: "search", componentID: componentID)
        table.bindSkin(dependencies.skinAppearance, slot: "list", componentID: componentID)
        status.bindSkin(dependencies.skinAppearance, slot: "emptyState", componentID: componentID)
        for button in [primary, secondary, cancelButton] {
            button.bindSkin(
                dependencies.skinAppearance, slot: "primaryAction", componentID: componentID)
            button.updateSkinState()
        }
        if previewOnly {
            status.stringValue = String(localized: "安全預覽：不連接搜尋、收藏或任務服務")
            status.isHidden = false
            for control in [primary, secondary, cancelButton, queryField, table, category, sourceFilter, openFileButton, revealButton, deleteRecordButton, deleteFileButton] { control.isEnabled = false }
        } else {
            switch kind {
            case .schedule, .updates, .recommendations:
                NotificationCenter.default.addObserver(self, selector: #selector(refreshForDayChange), name: .NSCalendarDayChanged, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(refreshForDayChange), name: NSApplication.didBecomeActiveNotification, object: nil)
                refreshDiscovery(force: false)
            case .continuing: attachHistory()
            case .feed: loadFeed()
            case .downloads: attachDownloads()
            case .followed: loadFollowed(.init😅)
            case .bilibiliRecommendations: loadBilibiliRecommendations(replacing: true)
            case .youtube: loadYouTube(replacing: true, requestedQuery: "")
            case .search:
                showEmpty(String(localized: "Enter a keyword or URL, then choose Search."))
                refreshSearchSources()
            }
        }
        restoreScroll(savedScrollPosition)
    }

    private func configureActions() {
        primary.setFunctionIcon(.refresh)
        secondary.setFunctionIcon(.add)
        cancelButton.setFunctionIcon(.close)
        cancelButton.isHidden = kind != .downloads && kind != .search
        if kind == .search {
            cancelButton.action = #selector(cancelSearch)
            cancelButton.isEnabled = false
            secondary.isEnabled = false
        }
        switch kind {
        case .schedule, .updates, .recommendations:
            primary.title = String(localized: "Refresh")
            secondary.isHidden = true
        case .continuing:
            primary.isHidden = true
            secondary.isHidden = true
        case .feed:
            primary.title = String(localized: "刷新")
            secondary.title = String(localized: "載入更多")
            secondary.isHidden = false
        case .bilibiliRecommendations:
            primary.title = String(localized: "刷新")
            secondary.title = String(localized: "載入更多")
            secondary.isHidden = false
        case .youtube:
            primary.title = String(localized: "Refresh")
            secondary.title = String(localized: "Load More")
            secondary.isHidden = false
            secondary.isEnabled = false
        case .followed:
            primary.title = String(localized: "刷新")
            secondary.title = String(localized: "較舊影片")
            secondary.isHidden = false
        case .search:
            primary.title = String(localized: "Search")
            primary.setFunctionIcon(.search)
            secondary.title = String(localized: "More Results")
            secondary.isHidden = false
        case .downloads:
            primary.title = String(localized: "暫停")
            primary.setFunctionIcon(.pause)
            secondary.title = String(localized: "Resume")
            secondary.setFunctionIcon(.play)
            cancelButton.title = String(localized: "取消下載")
            secondary.isHidden = false
            for button in [primary, secondary, cancelButton] {
                button.setAccessibilityLabel(button.title)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                button.isEnabled = false
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !previewOnly, kind == .schedule || kind == .updates || kind == .recommendations {
            refreshDiscovery(force: false)
        }
        if !previewOnly, kind == .feed, rows.isEmpty { loadFeed() }
        if !previewOnly, kind == .continuing { reloadHistory() }
        restoreScroll(savedScrollPosition)
        if !previewOnly, kind == .followed { loadFollowed(followedCards.isEmpty ? .init😅 : .new) }
        if !previewOnly, kind == .bilibiliRecommendations, recommendationNextPage == 1 {
            loadBilibiliRecommendations(replacing: true)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // History can arrive while the section still has its compact empty-state
        // height. Re-measure after its parent applies the populated section height.
        if isHorizontalDiscovery { updateDiscoveryGeometry() }
    }

    func attach() {
        guard !previewOnly, !attached, isViewLoaded else { return }
        attached = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        switch kind {
        case .schedule, .updates, .recommendations:
            NotificationCenter.default.addObserver(self, selector: #selector(refreshForDayChange), name: .NSCalendarDayChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(refreshForDayChange), name: NSApplication.didBecomeActiveNotification, object: nil)
            refreshDiscovery(force: false)
        case .continuing: attachHistory()
        case .feed: if rows.isEmpty { loadFeed() }
        case .downloads: attachDownloads()
        case .followed: loadFollowed(followedCards.isEmpty ? .init😅 : .new)
        case .bilibiliRecommendations:
            updateBilibiliRecommendationStatus()
            if recommendationNextPage == 1 { loadBilibiliRecommendations(replacing: true) }
        case .youtube:
            if youtubeNeedsFirstPage { loadYouTube(replacing: true, requestedQuery: youtubeQuery) }
            else { updateYouTubeStatus() }
        case .search: refreshSearchSources()
        }
        restoreScroll(savedScrollPosition)
    }

    func detach() {
        guard attached else { return }
        if kind == .search, searching { cancelSearch() }
        storeState()
        attached = false
        NotificationCenter.default.removeObserver(self)
        operation?.cancel()
        operation = nil
        historyReloadTask?.cancel()
        historyReloadTask = nil
        feedGeneration &+= 1
        feedLoading = false
        recommendationTask?.cancel()
        recommendationTask = nil
        recommendationGeneration &+= 1
        recommendationLoading = false
        cancelYouTubeRequest()
        streamTask?.cancel()
        streamTask = nil
        sourceMenuTask?.cancel()
        sourceMenuTask = nil
        if let followedManager { Task { await followedManager.cancel() } }
        followedManager = nil
    }

    @objc nonisolated private func refreshForDayChange() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if attached { refreshDiscovery(force: false) }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attached else { return }
                self.refreshDiscovery(force: false)
            }
        }
    }
    @objc private func scrollBoundsChanged(_ notification: Notification) {
        guard !suppressSelectionChanges else { return }
        if pendingPageScrollPosition == nil { storeState() }
        updateDiscoveryGeometry()
        if kind == .feed, feedFailure == nil, isNearFeedEnd {
            loadFeed()
        }
        if kind == .followed, !followedCards.isEmpty, !followedLoading, followedFailure == nil,
           (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY < 240 {
            loadFollowed(.history)
        }
        if kind == .bilibiliRecommendations, recommendationAllowsAutoLoad,
           recommendationFailure == nil, isNearBilibiliVideoEnd {
            loadBilibiliRecommendations()
        }
        if kind == .youtube, youtubeAllowsAutoLoad, youtubeFailure == nil, isNearBilibiliVideoEnd {
            loadYouTube()
        }
    }

    @objc private func openImageSearch() {
        guard !previewOnly, attached else { return }
        dependencies.actions.imageSearch()
    }

    func submitSearch(_ input: String) {
        guard !previewOnly else { return }
        _ = view
        queryField.stringValue = input
        if kind == .youtube { searchYouTube() } else { search() }
    }
    func submitAnimeTitle(_ title: String) {
        guard !previewOnly, kind == .search else { return }
        _ = view
        queryField.stringValue = title
        category.selectItem(at: BrowseContentFilter.allCases.firstIndex(of: .anime) ?? 0)
        filterChanged()
    }

    func focusSearch() {
        guard !previewOnly else { return }
        guard kind == .search || kind == .youtube, isViewLoaded else { return }
        view.window?.makeFirstResponder(queryField)
    }

    func capabilitiesDidChange() {
        guard !previewOnly else { return }
        switch kind {
        case .schedule, .updates, .recommendations: refreshDiscovery(force: false)
        case .continuing: reloadHistory()
        case .feed: loadFeed(reset: true)
        case .downloads: attachDownloads()
        case .search: refreshSearchSources()
        case .youtube:
            cancelYouTubeRequest()
            clearYouTubePage()
            loadYouTube(replacing: true, requestedQuery: "")
        case .bilibiliRecommendations:
            recommendationTask?.cancel()
            recommendationTask = nil
            recommendationGeneration &+= 1
            recommendationLoading = false
            recommendationNextPage = 1
            recommendationAllowsAutoLoad = false
            recommendationSeen.removeAll()
            followedCards.removeAll()
            selectedRowID = nil
            savedScrollPosition = 0
            showFollowedCards()
            loadBilibiliRecommendations(replacing: true)
        case .followed:
            if let followedManager { Task { await followedManager.cancel() } }
            followedManager = nil; followedCards = []; followedLoading = false
            loadFollowed(.init😅)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !previewOnly else { return }
        if kind == .youtube {
            cancelYouTubeRequest()
            youtubeNeedsFirstPage = true
            youtubeFailure = nil
            youtubeMessage = String(localized: "Press Return or Search to search YouTube.")
            updateYouTubeStatus()
            return
        }
        query = queryField.stringValue
        searchGeneration &+= 1
        operation?.cancel()
        operation = nil
        searching = false
        cancelButton.isEnabled = false
        searchSnapshot = nil
        showEmpty(query.isEmpty ? String(localized: "輸入關鍵詞、影片網址或 magnet。") : String(localized: "按 Return 搜尋。"))
        secondary.isEnabled = false
        storeState()
    }

    @objc private func primaryAction() {
        guard !previewOnly else { return }
        switch kind {
        case .schedule, .updates, .recommendations: refreshDiscovery(force: true)
        case .continuing: reloadHistory()
        case .feed: loadFeed(reset: true, force: true)
        case .followed: loadFollowed(followedCards.isEmpty ? .init😅 : .new)
        case .bilibiliRecommendations: loadBilibiliRecommendations(replacing: true)
        case .youtube:
            loadYouTube(replacing: true, requestedQuery: youtubeQuery)
        case .search: search()
        case .downloads: performSelectedDownloadOperation(.pause)
        }
    }

    @objc private func secondaryAction() {
        guard !previewOnly else { return }
        switch kind {
        case .search: loadMore()
        case .feed: loadFeed()
        case .followed: loadFollowed(.history)
        case .bilibiliRecommendations: loadBilibiliRecommendations()
        case .youtube: loadYouTube()
        case .downloads: performSelectedDownloadOperation(.resume)
        default: break
        }
    }
    @objc func reload(_ sender: Any?) { primaryAction() }

    private func configureYouTubeControls(in panel: NSStackView) {
        queryField.stringValue = ""
        queryField.placeholderString = String(localized: "Search YouTube")
        queryField.delegate = self
        queryField.sendsSearchStringImmediately = false
        queryField.target = self
        queryField.action = #selector(searchYouTube)
        queryField.controlSize = .large
        let home = WorkspaceSkinButton(title: String(localized: "Home"), target: self, action: #selector(showYouTubeHome))
        let search = WorkspaceSkinButton(title: String(localized: "Search"), target: self, action: #selector(searchYouTube))
        youtubeBrowseControls = [home, search, queryField]
        let searchRow = NSStackView(views: [home, queryField, search])
        searchRow.spacing = 8
        panel.addArrangedSubview(searchRow)
        searchRow.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        queryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        youtubeImportButton.title = String(localized: "Import Browser Cookies…")
        youtubeImportButton.target = self
        youtubeImportButton.action = #selector(importYouTubeCookies)
        youtubeSignOutButton.title = String(localized: "Sign Out")
        youtubeSignOutButton.target = self
        youtubeSignOutButton.action = #selector(signOutYouTube)
        let login = WorkspaceSkinButton(title: String(localized: "Sign in on YouTube"), target: self, action: #selector(openYouTubeHome))
        let accountRow = NSStackView(views: [youtubeImportButton, youtubeSignOutButton, login])
        accountRow.spacing = 8
        panel.addArrangedSubview(accountRow)
        youtubeAccountLabel.font = .systemFont(ofSize: 12)
        youtubeAccountLabel.textColor = .secondaryLabelColor
        youtubeAccountLabel.stringValue = String(localized: "YouTube · Guest")
        panel.addArrangedSubview(youtubeAccountLabel)
        let help = NSTextField(wrappingLabelWithString: String(localized: "Sign in on youtube.com in Chrome or Safari, then select Import Browser Cookies… and explicitly allow a one-time import from your chosen browser/profile. macOS may request Keychain access or Full Disk Access separately. You can also import an exported Netscape cookies.txt file; keep that sensitive file private and delete it after import. No embedded Google login is used."))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        panel.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        let open = WorkspaceSkinButton(title: String(localized: "Open in Browser"), target: self, action: #selector(openYouTubeVideo))
        let copy = WorkspaceSkinButton(title: String(localized: "Copy URL"), target: self, action: #selector(copyYouTubeURL))
        panel.addArrangedSubview(NSStackView(views: [open, copy]))
        for button in [home, search, youtubeImportButton, youtubeSignOutButton, login, open, copy] {
            button.bezelStyle = .rounded
            button.isEnabled = !previewOnly
            button.bindSkin(dependencies.skinAppearance, slot: "primaryAction", componentID: componentID)
            button.updateSkinState()
        }
        youtubeSignOutButton.isEnabled = false
    }

    private func clearYouTubePage() {
        youtubeVideos.removeAll()
        youtubeSeen.removeAll()
        youtubeContinuation = nil
        youtubeNeedsFirstPage = true
        youtubeMessage = nil
        rows.removeAll()
        destinations.removeAll()
        coverURLs.removeAll()
        posters.removeAll()
        selectedRowID = nil
        savedScrollPosition = 0
        count.stringValue = "0"
        reloadRowsPreservingSelection()
    }

    private func cancelYouTubeRequest() {
        youtubeTask?.cancel()
        youtubeTask = nil
        youtubeGeneration &+= 1
        youtubeOpenPanel?.cancel(nil)
        youtubeOpenPanel = nil
        if let sheet = youtubeImportAlert?.window, let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: .cancel)
        }
        youtubeImportAlert = nil
        youtubeLoading = false
        youtubeAccountBusy = false
        youtubeAllowsAutoLoad = false
    }

    private func updateYouTubeStatus() {
        guard kind == .youtube else { return }
        primary.isEnabled = !previewOnly && !youtubeAccountBusy
        secondary.isEnabled = !previewOnly && !youtubeLoading && !youtubeAccountBusy
            && !youtubeNeedsFirstPage && youtubeContinuation != nil
        youtubeImportButton.isEnabled = !previewOnly && !youtubeAccountBusy
        youtubeSignOutButton.isEnabled = !previewOnly && !youtubeAccountBusy && youtubeAccount != nil
        for control in youtubeBrowseControls { control.isEnabled = !previewOnly && !youtubeAccountBusy }
        if let account = youtubeAccount {
            if account.status == .expired {
                youtubeAccountLabel.stringValue = String(localized: "YouTube · Login expired — import fresh cookies")
            } else if !account.enabled || account.status == .needsLogin {
                youtubeAccountLabel.stringValue = String(localized: "YouTube · Account unavailable — import fresh cookies or sign out")
            } else {
                youtubeAccountLabel.stringValue = String(localized: "YouTube · Signed in")
            }
        } else {
            youtubeAccountLabel.stringValue = String(localized: "YouTube · Guest")
        }
        status.stringValue = youtubeFailure ?? (youtubeAccountBusy
            ? String(localized: "Updating YouTube account…")
            : youtubeLoading ? String(localized: "Loading YouTube…")
            : youtubeMessage ?? (youtubeVideos.isEmpty
                ? String(localized: "No YouTube videos to show. Try Search, or sign in in your browser and import cookies for your home feed.")
                : ""))
        status.isHidden = status.stringValue.isEmpty
        status.workspaceSkinBinding?.state = youtubeFailure != nil ? .error : youtubeLoading || youtubeAccountBusy ? .loading : .normal
    }

    private func loadYouTube(replacing: Bool = false, requestedQuery: String? = nil) {
        guard kind == .youtube, !previewOnly, attached, !youtubeAccountBusy else { return }
        if replacing {
            cancelYouTubeRequest()
            youtubeQuery = (requestedQuery ?? youtubeQuery).trimmingCharacters(in: .whitespacesAndNewlines)
            query = youtubeQuery
            queryField.stringValue = youtubeQuery
            youtubeNeedsFirstPage = true
        } else {
            guard !youtubeLoading, !youtubeNeedsFirstPage, youtubeContinuation != nil else { return }
        }
        youtubeLoading = true
        youtubeFailure = nil
        youtubeMessage = nil
        updateYouTubeStatus()
        let generation = youtubeGeneration
        let input = youtubeQuery
        let continuation = youtubeContinuation
        youtubeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.attached, generation == self.youtubeGeneration {
                    self.youtubeLoading = false
                    self.youtubeTask = nil
                    self.updateYouTubeStatus()
                    if self.youtubeAllowsAutoLoad {
                        Task { @MainActor [weak self] in
                            await Task.yield()
                            guard let self, self.attached, generation == self.youtubeGeneration,
                                  self.isNearBilibiliVideoEnd else { return }
                            self.loadYouTube()
                        }
                    }
                }
            }
            do {
                let account = try await SiteAccounts.shared.defaultAccount(sourceID: "youtube")
                guard self.attached, !Task.isCancelled, generation == self.youtubeGeneration else { return }
                self.youtubeAccount = account
                self.updateYouTubeStatus()
                let page = try await SiteAccounts.shared.withSource(sourceID: "youtube") {
                    if !replacing, let continuation {
                        return try await YouTubeBrowseService.shared.more(continuation)
                    }
                    if input.isEmpty { return try await YouTubeBrowseService.shared.home() }
                    return try await YouTubeBrowseService.shared.search(input)
                }
                guard self.attached, !Task.isCancelled, generation == self.youtubeGeneration else { return }
                if replacing {
                    self.youtubeVideos.removeAll()
                    self.youtubeSeen.removeAll()
                    self.selectedRowID = nil
                    self.savedScrollPosition = 0
                }
                var added = 0
                for video in page.videos where self.youtubeSeen.insert(video.id).inserted {
                    self.youtubeVideos.append(video)
                    added += 1
                }
                self.youtubeContinuation = page.continuation
                self.youtubeNeedsFirstPage = false
                self.youtubeMessage = page.message
                self.youtubeAllowsAutoLoad = added > 0 && page.continuation != nil
                self.rows = self.youtubeVideos.map { "\($0.title) — \($0.channel) · \($0.viewCountText)" }
                self.destinations = self.youtubeVideos.map { .address($0.watchURL.absoluteString) }
                self.coverURLs = self.youtubeVideos.map(\.thumbnailURL)
                self.posters = self.youtubeVideos.map { _ in false }
                self.count.stringValue = "\(self.youtubeVideos.count)"
                self.reloadRowsPreservingSelection()
            } catch is CancellationError {
            } catch {
                guard self.attached, !Task.isCancelled, generation == self.youtubeGeneration else { return }
                self.youtubeAllowsAutoLoad = false
                self.youtubeFailure = self.youTubeFailureMessage(error)
                let account = try? await SiteAccounts.shared.defaultAccount(sourceID: "youtube")
                guard self.attached, !Task.isCancelled, generation == self.youtubeGeneration else { return }
                self.youtubeAccount = account
                if case SiteAccountError.expired = error { self.youtubeAccount?.status = .expired }
            }
        }
    }

    private func youTubeFailureMessage(_ error: Error) -> String {
        // Never surface provider bodies, cookie values, file paths, or request headers.
        if let failure = error as? YouTubeBrowseError { return failure.localizedDescription }
        if let failure = error as? YouTubeBrowserCookiesError { return failure.localizedDescription }
        switch error {
        case YouTubeCookieImportError.invalidFileSize:
            return String(localized: "Choose a nonempty Netscape cookies.txt file no larger than 1 MiB.")
        case SiteAccountError.expired, SiteAccountError.needsLogin:
            return String(localized: "YouTube login expired. Sign in in your browser and import fresh cookies, or Sign Out to browse as a guest.")
        case SiteAccountError.invalidCookies, SiteAccountError.validationFailed:
            return String(localized: "YouTube could not validate these cookies. Export fresh Netscape cookies.txt for youtube.com after signing in.")
        case SiteAccountError.accountInUse:
            return String(localized: "The YouTube account is still in use. Wait for the current request to stop and try again.")
        case SiteAccountError.disabled:
            return String(localized: "The YouTube source or account is disabled.")
        case SiteAccountError.secureStorage:
            return String(localized: "Secure credential storage is unavailable.")
        default:
            return String(localized: "YouTube could not complete this request. Check your connection and try again; existing videos have been kept.")
        }
    }

    @objc private func showYouTubeHome() {
        loadYouTube(replacing: true, requestedQuery: "")
    }

    @objc private func searchYouTube() {
        loadYouTube(replacing: true, requestedQuery: queryField.stringValue)
    }

    @objc private func openYouTubeHome() {
        guard !previewOnly, let url = URL(string: "https://www.youtube.com/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openYouTubeVideo() {
        guard !previewOnly, youtubeVideos.indices.contains(selectedIndex) else { return }
        NSWorkspace.shared.open(youtubeVideos[selectedIndex].watchURL)
    }

    @objc private func copyYouTubeURL() {
        guard !previewOnly, youtubeVideos.indices.contains(selectedIndex) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(youtubeVideos[selectedIndex].watchURL.absoluteString, forType: .string)
    }

    @objc private func importYouTubeCookies() {
        guard !previewOnly, attached, !youtubeAccountBusy, let window = view.window else { return }
        let previousRequest = youtubeTask
        cancelYouTubeRequest()
        youtubeAccountBusy = true
        youtubeFailure = nil
        updateYouTubeStatus()
        let generation = youtubeGeneration
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow YouTube cookie import?")
        alert.informativeText = String(localized: "Choose Chrome or Safari. After you allow, select a profile if the browser has more than one. IINA-ANI will read only YouTube cookies from that browser/profile once, validate them with YouTube, and save them in Keychain. Passwords, browsing history, and other sites’ cookies are not imported. macOS may separately ask for Keychain access or require Full Disk Access in System Settings > Privacy & Security. This in-app consent does not grant macOS permissions.")
        alert.addButton(withTitle: String(localized: "Allow Import"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Import cookies.txt…"))
        let browserChoice = NSPopUpButton()
        let browsers = YouTubeCookieBrowser.allCases
        browserChoice.addItems(withTitles: browsers.map { browser in
            switch browser {
            case .chrome: return "Chrome"
            case .safari: return "Safari"
            }
        })
        alert.accessoryView = youTubeImportChoiceView(label: String(localized: "Browser"), choice: browserChoice)
        youtubeImportAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self, let window, self.attached, self.view.window === window,
                  generation == self.youtubeGeneration else { return }
            self.youtubeImportAlert = nil
            switch response {
            case .alertFirstButtonReturn:
                guard browsers.indices.contains(browserChoice.indexOfSelectedItem) else {
                    self.finishYouTubeCookieImport(generation: generation)
                    return
                }
                // Neither profile metadata nor cookie stores are accessed until this explicit consent.
                self.loadYouTubeBrowserProfiles(
                    browser: browsers[browserChoice.indexOfSelectedItem],
                    generation: generation, previousRequest: previousRequest)
            case .alertThirdButtonReturn:
                self.chooseYouTubeCookieFile(generation: generation, previousRequest: previousRequest)
            default:
                self.finishYouTubeCookieImport(generation: generation)
            }
        }
    }

    private func youTubeImportChoiceView(label: String, choice: NSPopUpButton) -> NSView {
        choice.setAccessibilityLabel(label)
        let stack = NSStackView(views: [NSTextField(labelWithString: label), choice])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 56)
        choice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func loadYouTubeBrowserProfiles(
        browser: YouTubeCookieBrowser, generation: UInt64, previousRequest: Task<Void, Never>?
    ) {
        guard !previewOnly, attached, generation == youtubeGeneration else { return }
        youtubeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let profiles = try await YouTubeBrowserCookies.profiles(for: browser)
                guard self.attached, !Task.isCancelled, generation == self.youtubeGeneration else { return }
                self.youtubeTask = nil
                guard !profiles.isEmpty else {
                    self.finishYouTubeCookieImport(
                        generation: generation,
                        message: String(localized: "No browser profiles were found. Open the selected browser and sign in to YouTube, then try again, or use Import cookies.txt…. Safari may require Full Disk Access in System Settings > Privacy & Security."))
                    return
                }
                if profiles.count == 1, let profile = profiles.first {
                    self.performYouTubeCookieImport(generation: generation, previousRequest: previousRequest) {
                        try await YouTubeBrowserCookies.read(profile: profile)
                    }
                    return
                }
                self.chooseYouTubeBrowserProfile(
                    profiles, generation: generation, previousRequest: previousRequest)
            } catch {
                guard !Task.isCancelled else { return }
                self.finishYouTubeCookieImport(
                    generation: generation,
                    message: error is CancellationError ? nil : self.youTubeFailureMessage(error))
            }
        }
    }

    private func chooseYouTubeBrowserProfile(
        _ profiles: [YouTubeBrowserProfile], generation: UInt64, previousRequest: Task<Void, Never>?
    ) {
        guard !previewOnly, attached, generation == youtubeGeneration, let window = view.window else {
            finishYouTubeCookieImport(generation: generation)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Choose a browser profile")
        alert.informativeText = String(localized: "Only YouTube cookies from the selected profile will be imported.")
        alert.addButton(withTitle: String(localized: "Import"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let profileChoice = NSPopUpButton()
        profileChoice.addItems(withTitles: profiles.map(\.name))
        alert.accessoryView = youTubeImportChoiceView(label: String(localized: "Profile"), choice: profileChoice)
        youtubeImportAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self, let window, self.attached, self.view.window === window,
                  generation == self.youtubeGeneration else { return }
            self.youtubeImportAlert = nil
            guard response == .alertFirstButtonReturn,
                  profiles.indices.contains(profileChoice.indexOfSelectedItem) else {
                self.finishYouTubeCookieImport(generation: generation)
                return
            }
            let profile = profiles[profileChoice.indexOfSelectedItem]
            self.performYouTubeCookieImport(generation: generation, previousRequest: previousRequest) {
                try await YouTubeBrowserCookies.read(profile: profile)
            }
        }
    }

    private func chooseYouTubeCookieFile(generation: UInt64, previousRequest: Task<Void, Never>?) {
        guard !previewOnly, attached, generation == youtubeGeneration, let window = view.window else {
            finishYouTubeCookieImport(generation: generation)
            return
        }
        let panel = NSOpenPanel()
        youtubeOpenPanel = panel
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Import cookies.txt…")
        panel.message = String(localized: "Choose Netscape cookies.txt exported for youtube.com. Keep this sensitive file private and delete it after importing.")
        panel.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self, let window, self.attached, self.view.window === window,
                  generation == self.youtubeGeneration else { return }
            self.youtubeOpenPanel = nil
            guard response == .OK, let url = panel.url else {
                self.finishYouTubeCookieImport(generation: generation)
                return
            }
            self.performYouTubeCookieImport(generation: generation, previousRequest: previousRequest) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileReadUnknown)
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let maximumBytes = 1_048_576
                let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                guard !data.isEmpty, data.count <= maximumBytes else {
                    throw YouTubeCookieImportError.invalidFileSize
                }
                return data
            }
        }
    }

    private func performYouTubeCookieImport(
        generation: UInt64, previousRequest: Task<Void, Never>?,
        readData: @escaping @MainActor () async throws -> Data
    ) {
        guard !previewOnly, attached, generation == youtubeGeneration else { return }
        youtubeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let data = try await readData()
                await previousRequest?.value
                try Task.checkCancellation()
                guard self.attached, generation == self.youtubeGeneration else { return }
                let account = try await SiteAccounts.shared.importYouTubeCookies(data)
                guard self.attached, !Task.isCancelled, generation == self.youtubeGeneration else { return }
                self.clearYouTubePage()
                self.youtubeAccount = account
                self.youtubeAccountBusy = false
                self.youtubeTask = nil
                self.loadYouTube(replacing: true, requestedQuery: "")
            } catch {
                guard !Task.isCancelled else { return }
                self.finishYouTubeCookieImport(
                    generation: generation,
                    message: error is CancellationError ? nil : self.youTubeFailureMessage(error))
            }
        }
    }

    private func finishYouTubeCookieImport(generation: UInt64, message: String? = nil) {
        guard attached, generation == youtubeGeneration else { return }
        youtubeAccountBusy = false
        youtubeTask = nil
        if let message { youtubeFailure = message }
        updateYouTubeStatus()
    }

    @objc private func signOutYouTube() {
        guard !previewOnly, attached, !youtubeAccountBusy else { return }
        let previousRequest = youtubeTask
        cancelYouTubeRequest()
        youtubeAccountBusy = true
        youtubeFailure = nil
        updateYouTubeStatus()
        let generation = youtubeGeneration
        youtubeTask = Task { [weak self] in
            guard let self else { return }
            do {
                await previousRequest?.value
                try Task.checkCancellation()
                if let account = try await SiteAccounts.shared.defaultAccount(sourceID: "youtube") {
                    try Task.checkCancellation()
                    try await SiteAccounts.shared.signOut(accountID: account.id)
                }
                guard self.attached, !Task.isCancelled, generation == self.youtubeGeneration else { return }
                self.clearYouTubePage()
                self.youtubeAccount = nil
                self.youtubeAccountBusy = false
                self.youtubeTask = nil
                self.loadYouTube(replacing: true, requestedQuery: "")
            } catch {
                guard self.attached, !Task.isCancelled, generation == self.youtubeGeneration else { return }
                self.youtubeAccountBusy = false
                self.youtubeTask = nil
                self.youtubeFailure = self.youTubeFailureMessage(error)
                self.updateYouTubeStatus()
            }
        }
    }

    private func loadFollowed(_ action: BilibiliDynamicAction) {
        guard !previewOnly, attached, !followedLoading else { return }
        if followedManager == nil { followedManager = BilibiliDynamicManger() }
        guard let manager = followedManager else { return }
        followedLoading = true; followedFailure = nil
        bilibiliDynamicStatusChanged(true)
        Task { [weak self] in
            guard let self, self.attached else { return }
            await manager.setDelegate(self)
            await manager.loadBilibiliCards(action)
        }
    }

    private var isNearBilibiliVideoEnd: Bool {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY < 240
    }

    private func updateBilibiliRecommendationStatus() {
        primary.isEnabled = !recommendationLoading
        // Empty or filtered pages are not an end-of-feed signal.
        secondary.isEnabled = !recommendationLoading
        secondary.title = recommendationFailure == nil ? String(localized: "載入更多") : String(localized: "重試載入")
        secondary.setFunctionIcon(recommendationFailure == nil ? .add : .refresh)
        status.stringValue = recommendationFailure ?? (recommendationLoading
            ? String(localized: "正在載入 Bilibili 推薦影片…")
            : followedCards.isEmpty ? String(localized: "暫無可播放的 Bilibili 推薦影片；可刷新或載入更多。") : "")
        status.isHidden = status.stringValue.isEmpty
        status.workspaceSkinBinding?.state = recommendationFailure != nil ? .error : recommendationLoading ? .loading : .normal
    }

    private func loadBilibiliRecommendations(replacing: Bool = false) {
        guard kind == .bilibiliRecommendations, !previewOnly, attached, !recommendationLoading else { return }
        recommendationLoading = true
        recommendationFailure = nil
        updateBilibiliRecommendationStatus()
        let generation = recommendationGeneration
        // Refresh requests a fresh batch rather than replaying the initial page.
        let page = recommendationNextPage
        recommendationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.attached, generation == self.recommendationGeneration {
                    self.recommendationLoading = false
                    self.recommendationTask = nil
                    self.updateBilibiliRecommendationStatus()
                }
            }
            do {
                let cards = try await SiteAccounts.shared.withSource(sourceID: "bilibili") {
                    try await Bilibili.shared.recommendationList(page: page)
                }
                guard self.attached, !Task.isCancelled, generation == self.recommendationGeneration else { return }
                if replacing {
                    self.recommendationSeen.removeAll()
                    self.followedCards.removeAll()
                    self.selectedRowID = nil
                    self.savedScrollPosition = 0
                }
                var addedCount = 0
                for card in cards where self.recommendationSeen.insert(card.bvid).inserted {
                    self.followedCards.append(card)
                    addedCount += 1
                }
                self.recommendationNextPage = page + 1
                self.recommendationAllowsAutoLoad = addedCount > 0
                self.showFollowedCards()
                // Stop automatic paging on empty/duplicate-only batches, while
                // leaving explicit Load More available for subsequent raw pages.
                if self.recommendationAllowsAutoLoad {
                    Task { @MainActor [weak self] in
                        guard let self, self.attached, generation == self.recommendationGeneration,
                              self.isNearBilibiliVideoEnd else { return }
                        self.loadBilibiliRecommendations()
                    }
                }
            } catch is CancellationError {
            } catch {
                guard self.attached, !Task.isCancelled, generation == self.recommendationGeneration else { return }
                self.recommendationFailure = error.localizedDescription
                self.recommendationAllowsAutoLoad = false
            }
        }
    }

    private var selectedFollowedURL: String? {
        guard followedCards.indices.contains(selectedIndex) else { return nil }
        return "https://www.bilibili.com/video/\(followedCards[selectedIndex].bvid)"
    }
    @objc private func copyFollowedURL() {
        guard !previewOnly, let url = selectedFollowedURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
    }
    @objc private func openFollowedPage() {
        guard !previewOnly, let value = selectedFollowedURL, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
    private func showFollowedCards() {
        guard attached else { return }
        rows = followedCards.map { String(localized: "\($0.title) — \($0.name) · \($0.views) views · \(Int($0.duration))s") }
        destinations = followedCards.map { .address("https://www.bilibili.com/video/\($0.bvid)") }
        coverURLs = followedCards.map(\.picUrl); posters = followedCards.map { _ in false }
        count.stringValue = "\(rows.count)"; reloadRowsPreservingSelection()
    }
    @objc private func cancelSelectedDownload() { guard !previewOnly else { return }; performSelectedDownloadOperation(.cancel) }
    private func loadFeed(reset: Bool = false, force: Bool = false) {
        guard kind == .feed, !previewOnly, attached,
              dependencies.capabilityEnabled(.recommendations) else { return }
        if reset {
            operation?.cancel()
            feedGeneration &+= 1
            feedLoading = false
            feedPage = 2; feedHasMore = true; feedSeen.removeAll()
            feedFailure = nil; selectedRowID = nil; savedScrollPosition = 0
            rows.removeAll(); destinations.removeAll(); coverURLs.removeAll(); posters.removeAll()
            count.stringValue = "0"
            reloadRowsPreservingSelection()
        }
        guard !feedLoading, feedHasMore else { return }
        feedLoading = true; feedFailure = nil
        secondary.isEnabled = false; secondary.title = String(localized: "載入更多")
        secondary.setFunctionIcon(.add)
        status.stringValue = String(localized: "載入推薦…"); status.isHidden = false
        status.workspaceSkinBinding?.state = .loading
        let generation = feedGeneration
        let page = feedPage
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.feedGeneration {
                    self.feedLoading = false
                    self.operation = nil
                    self.secondary.isEnabled = self.feedHasMore
                }
            }
            do {
                if page == 2, self.feedSeen.isEmpty {
                    let trends = try await BangumiService.shared.trendingSubjects(forceRefresh: force)
                    guard self.attached, !Task.isCancelled, generation == self.feedGeneration else { return }
                    self.feedSeen.formUnion(trends.value.lazy.map(\.id))
                }
                let result = try await BangumiService.shared.trendingPage(page: page, forceRefresh: force)
                guard self.attached, !Task.isCancelled, generation == self.feedGeneration else { return }
                for subject in result.value.subjects where subject.type == 2 && self.feedSeen.insert(subject.id).inserted {
                    self.rows.append(String(localized: "\(subject.title) · Bangumi 熱度推薦"))
                    self.destinations.append(.bangumi(subject.id, subject))
                    self.coverURLs.append(subject.coverURL); self.posters.append(true)
                }
                self.count.stringValue = "\(self.rows.count)"
                self.reloadRowsPreservingSelection()
                if let failure = result.failure {
                    self.feedFailure = String(localized: "已保留快取推薦；\(failure.localizedDescription)")
                } else {
                    self.feedPage += 1
                    self.feedHasMore = result.value.hasMore
                }
                self.status.stringValue = self.feedFailure ?? (self.feedHasMore ? "" : String(localized: "已瀏覽全部推薦。"))
                self.status.isHidden = self.status.stringValue.isEmpty
                self.status.workspaceSkinBinding?.state = self.feedFailure == nil ? .normal : .error
                if self.feedFailure == nil, self.feedHasMore {
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.feedGeneration,
                              self.isNearFeedEnd else { return }
                        self.loadFeed()
                    }
                }
            } catch is CancellationError {
            } catch {
                guard self.attached, !Task.isCancelled, generation == self.feedGeneration else { return }
                self.feedFailure = error.localizedDescription
                self.showError(error)
                self.secondary.title = String(localized: "重試載入")
                self.secondary.setFunctionIcon(.refresh)
            }
        }
    }


    private func refreshDiscovery(force: Bool) {
        guard !previewOnly else { return }
        guard isViewLoaded, attached else { return }
        operation?.cancel()
        status.stringValue = String(localized: "Refreshing…")
        status.isHidden = false
        status.workspaceSkinBinding?.state = .loading
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try self.dependencies.discovery()
                let snapshot = try await service.presentationSnapshot(force: force)
                guard self.attached, !Task.isCancelled else { return }
                self.showDiscovery(snapshot)
            } catch is CancellationError {
            } catch { self.showError(error) }
        }
    }

    private func showDiscovery(_ snapshot: DiscoverySnapshot) {
        rows = []; destinations = []; coverURLs = []; posters = []
        var failure: String?
        switch kind {
        case .schedule:
            let grouped = Dictionary(grouping: snapshot.weeklyBroadcasts.items, by: \.weekday)
            let days = weekdayOrder.map { grouped[$0] ?? [] }
            let height = days.map(\.count).max() ?? 0
            for index in 0..<height {
                for day in days {
                    if index < day.count {
                        let item = day[index]
                        rows.append(item.subject.title)
                        destinations.append(.bangumi(item.subject.id, item.subject))
                        coverURLs.append(item.coverURL); posters.append(true)
                    } else {
                        rows.append(""); destinations.append(nil)
                        coverURLs.append(nil); posters.append(true)
                    }
                }
            }
            failure = snapshot.weeklyBroadcasts.failure
        case .updates:
            for item in snapshot.favoriteUpdates.items {
                rows.append(String(localized: "\(item.workTitle) · \(item.sourceID) · 新集數 \(item.newIdentities.joined(separator: "、"))"))
                destinations.append(.update(item))
                coverURLs.append(nil); posters.append(true)
            }
            failure = snapshot.favoriteUpdates.failure
        case .recommendations:
            for item in snapshot.recommendations.items {
                rows.append("\(item.subject.nameCN.isEmpty ? item.subject.name : item.subject.nameCN) · Bangumi — \(item.reasons.joined(separator: "、"))")
                destinations.append(.bangumi(item.subject.id, item.subject))
                coverURLs.append(item.subject.coverURL); posters.append(true)
            }
            failure = snapshot.recommendations.failure
        case .continuing, .feed, .followed, .bilibiliRecommendations, .youtube, .search, .downloads: return
        }
        count.stringValue = "\(kind == .schedule ? snapshot.weeklyBroadcasts.items.count : rows.count)"
        reloadRowsPreservingSelection()
        status.stringValue = failure ?? (rows.isEmpty ? String(localized: "此分區目前沒有項目。") : "")
        status.workspaceSkinBinding?.state = failure == nil ? .normal : .error
        status.isHidden = failure == nil && !rows.isEmpty
        if kind == .updates {
            scroll.isHidden = rows.isEmpty
            contentHeightDidChange?(favoriteUpdatesHeight)
        }
    }

    private var selectedContentFilter: BrowseContentFilter {
        guard BrowseContentFilter.allCases.indices.contains(category.indexOfSelectedItem) else { return .anime }
        return BrowseContentFilter.allCases[category.indexOfSelectedItem]
    }

    private var selectedSearchSource: String {
        guard selectedContentFilter != .anime else { return "" }
        let saved = filter.split(separator: "|", omittingEmptySubsequences: false)
        return saved.count == 2 ? String(saved[1]) : ""
    }

    @objc private func filterChanged() {
        guard BrowseContentFilter.allCases.indices.contains(category.indexOfSelectedItem) else { return }
        filter = "\(BrowseContentFilter.allCases[category.indexOfSelectedItem].rawValue)|\(selectedSearchSource)"
        refreshSearchSources()
        storeState(); search()
    }

    @objc private func sourceChanged() {
        guard sourceIDs.indices.contains(sourceFilter.indexOfSelectedItem),
              BrowseContentFilter.allCases.indices.contains(category.indexOfSelectedItem) else { return }
        filter = "\(BrowseContentFilter.allCases[category.indexOfSelectedItem].rawValue)|\(sourceIDs[sourceFilter.indexOfSelectedItem])"
        storeState(); search()
    }

    private func refreshSearchSources() {
        guard !previewOnly, attached, let service = browseSearch else { return }
        sourceMenuTask?.cancel()
        let contentFilter = selectedContentFilter
        sourceFilter.isEnabled = contentFilter != .anime
        if contentFilter == .anime {
            sourceIDs = [""]
            sourceFilter.removeAllItems()
            sourceFilter.addItem(withTitle: "Bangumi")
            return
        }
        let enabled = dependencies.enabledSourceIDs()
        sourceMenuTask = Task { [weak self] in
            let ids = await service.searchableSourceIDs(enabledSourceIDs: enabled)
            guard let self, self.attached, !Task.isCancelled, self.selectedContentFilter == contentFilter else { return }
            let selected = self.selectedSearchSource
            self.sourceIDs = [""] + ids
            self.sourceFilter.removeAllItems()
            self.sourceFilter.addItems(withTitles: [String(localized: "全部啟用來源")] + ids)
            if !selected.isEmpty, !ids.contains(selected) {
                self.sourceIDs.append(selected)
                self.sourceFilter.addItem(withTitle: String(localized: "\(selected)（目前不可用）"))
                self.sourceFilter.menu?.items.last?.isEnabled = false
            }
            self.sourceFilter.selectItem(at: self.sourceIDs.firstIndex(of: selected) ?? 0)
        }
    }

    @objc private func cancelSearch() {
        guard !previewOnly, searching else { return }
        searchGeneration &+= 1
        operation?.cancel()
        operation = nil
        searching = false
        cancelButton.isEnabled = false
        if let searchSnapshot { showSearch(searchSnapshot) }
        else { showEmpty(String(localized: "搜尋已取消；可重新搜尋。")); secondary.isEnabled = false }
    }

    private func search() {
        guard !previewOnly, attached else { return }
        let value = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration &+= 1
        let generation = searchGeneration
        operation?.cancel()
        operation = nil
        searchSnapshot = nil
        searching = false
        cancelButton.isEnabled = false
        secondary.isEnabled = false
        query = value
        selectedRowID = nil
        savedScrollPosition = 0
        storeState()
        guard !value.isEmpty else { showEmpty(String(localized: "輸入關鍵詞或 URL。")); return }
        if value.lowercased().hasPrefix("magnet:") || URL(string: value)?.pathExtension.lowercased() == "torrent" {
            showEmpty(String(localized: "已開啟 BT 播放來源窗口。"))
            dependencies.actions.openLink(value); return
        }
        let source = selectedSearchSource
        let enabled = dependencies.enabledSourceIDs()
        let isURL = URLComponents(string: value)?.scheme?.isEmpty == false
        guard isURL || source.isEmpty || (enabled.contains(source) && sourceFilter.selectedItem?.isEnabled != false) else {
            showEmpty(String(localized: "所選來源目前不可用；請重新啟用來源或明確選擇其他來源。"))
            return
        }
        let ids: Set<String> = source.isEmpty ? enabled : [source]
        let contentFilter = selectedContentFilter
        searching = true
        cancelButton.isEnabled = true
        showEmpty(String(localized: "搜尋中…"))
        restoreScroll(0)
        status.workspaceSkinBinding?.state = .loading
        operation = Task { [weak self] in
            guard let self, let service = self.browseSearch else { return }
            defer {
                if generation == self.searchGeneration {
                    self.searching = false
                    self.cancelButton.isEnabled = false
                    self.operation = nil
                }
            }
            do {
                let result = try await service.search(value, enabledSourceIDs: ids, contentFilter: contentFilter)
                guard self.attached, !Task.isCancelled, generation == self.searchGeneration else { return }
                self.searchSnapshot = result
                self.searching = false
                self.showSearch(result)
                self.scroll.layoutSubtreeIfNeeded()
                self.restoreScroll(0)
            } catch is CancellationError {
            } catch {
                if self.attached, generation == self.searchGeneration, !Task.isCancelled { self.showError(error) }
            }
        }
    }

    private func loadMore() {
        guard !previewOnly, attached, !searching, searchSnapshot != nil, secondary.isEnabled else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        secondary.isEnabled = false
        searching = true
        cancelButton.isEnabled = true
        status.stringValue = String(localized: "載入更多結果…")
        status.isHidden = false
        status.workspaceSkinBinding?.state = .loading
        operation = Task { [weak self] in
            guard let self, let service = self.browseSearch else { return }
            defer {
                if generation == self.searchGeneration {
                    self.searching = false
                    self.cancelButton.isEnabled = false
                    self.operation = nil
                }
            }
            do {
                let result = try await service.loadMore()
                guard self.attached, !Task.isCancelled, generation == self.searchGeneration else { return }
                let position = self.savedScrollPosition
                self.searchSnapshot = result
                self.searching = false
                self.showSearch(result)
                self.restoreScroll(position)
            } catch is CancellationError {
            } catch {
                if self.attached, generation == self.searchGeneration, !Task.isCancelled {
                    self.searching = false
                    if let snapshot = self.searchSnapshot { self.showSearch(snapshot) }
                    self.showError(error)
                }
            }
        }
    }

    private func showSearch(_ result: BrowseSearchSnapshot) {
        rows = []; destinations = []; coverURLs = []; posters = []
        searchTitles = []
        var failures: [String] = []
        var hasMore = false
        func subjects(_ values: [BangumiSubject]) {
            for subject in values {
                searchTitles.append(subject.title)
                rows.append("\(subject.title) · \(subject.classification.kind.title) · Bangumi · \(subject.classification.provenance)")
                destinations.append(.bangumi(subject.id, subject))
                coverURLs.append(subject.coverURL); posters.append(subject.classification.kind == .anime)
            }
        }
        func sources(_ values: [SourceSearchResult], _ source: String) {
            for item in values {
                searchTitles.append(item.title)
                rows.append("\(item.title) · \(item.classification.kind.title) · \(source) · \(item.classification.provenance)")
                destinations.append(.selection(PlayableSelection(item: item.item, classification: item.classification)))
                coverURLs.append(item.cover); posters.append(item.classification.kind == .anime)
            }
        }
        switch result.route {
        case .bangumi(let id):
            searchTitles.append("Bangumi · \(id)")
            rows.append(String(localized: "Bangumi subject · \(id) · 載入 subject 類型後分類"))
            destinations.append(.bangumi(id, nil))
            coverURLs.append(nil); posters.append(false)
        case .url(let selection):
            searchTitles.append(selection.item.pageURL)
            rows.append("\(selection.item.pageURL) · \(selection.classification.kind.title) · \(selection.classification.provenance)")
            destinations.append(.selection(selection))
            coverURLs.append(nil); posters.append(selection.classification.kind == .anime)
        case .keyword(let bangumi):
            switch bangumi {
            case .results(let values, let next): subjects(values); hasMore = next != nil
            case .empty(let next): hasMore = next != nil
            case .failure(let error, let previous): subjects(previous); failures.append("Bangumi：\(error)")
            }
            for source in result.sources.keys.sorted() {
                switch result.sources[source]! {
                case .results(let values, let next): sources(values, source); hasMore = hasMore || next != nil
                case .empty(let next): hasMore = hasMore || next != nil
                case .failure(let error, let previous): sources(previous, source); failures.append("\(source)：\(error)")
                }
            }
        }
        count.stringValue = "\(rows.count)"
        reloadRowsPreservingSelection()
        status.stringValue = failures.isEmpty ? (rows.isEmpty ? String(localized: "\(result.contentFilter.title)沒有結果。") : "") : failures.joined(separator: "\n")
        status.workspaceSkinBinding?.state = failures.isEmpty ? .normal : .error
        status.isHidden = failures.isEmpty && !rows.isEmpty
        secondary.isEnabled = hasMore && !searching
        storeState()
        if searching {
            status.stringValue = String(localized: "載入更多結果…")
            status.isHidden = false
            status.workspaceSkinBinding?.state = .loading
        }
    }

    private func attachDownloads() {
        guard !previewOnly else { return }
        guard isViewLoaded, attached else { return }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDownloadsForActivation),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        operation?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try self.dependencies.downloads()
                self.downloadService = service
                await self.reloadDownloads(checkFiles: true)
                let events = await service.events()
                self.streamTask?.cancel()
                self.streamTask = Task { [weak self] in
                    for await event in events {
                        guard let self, self.attached, !Task.isCancelled else { return }
                        let checkFiles: Bool
                        switch event {
                        case .snapshot, .removed: checkFiles = true
                        case .changed(let record): checkFiles = record.state == .completed
                        }
                        await self.reloadDownloads(checkFiles: checkFiles)
                    }
                }
            } catch { self.showError(error) }
        }
    }

    @objc private func refreshDownloadsForActivation() {
        guard attached, kind == .downloads else { return }
        Task { [weak self] in await self?.reloadDownloads(checkFiles: true) }
    }

    private func reloadDownloads(checkFiles: Bool = false) async {
        guard !previewOnly else { return }
        guard let downloadService else { return }
        let values = await downloadService.list()
        if checkFiles {
            let completed = await downloadService.completedDownloads()
            guard attached, !Task.isCancelled else { return }
            completedDownloadIDs = Set(completed.map(\.id))
        }
        guard attached, !Task.isCancelled else { return }
        let sameTasks = downloads.count == values.count && zip(downloads, values).allSatisfy { pair in
            pair.0.id == pair.1.id
        }
        downloads = values
        rows = values.map { record in
            let progress = record.fractionCompleted.map { "\(Int($0 * 100))%" } ?? String(localized: "總量未知")
            let speed = ByteCountFormatter.string(fromByteCount: Int64(max(0, record.bytesPerSecond)), countStyle: .file) + "/s"
            let remaining = record.remainingSeconds.map { String(localized: " · 約 \(Int($0)) 秒") } ?? ""
            let segments = record.totalSegments.map { String(localized: " · 分段 \(record.completedSegments ?? 0)/\($0)") } ?? ""
            let failure = record.failure.map { " · \($0.localizedDescription)" } ?? ""
            let episode = record.episodeTitle.map { " · " + $0 } ?? ""
            let state = record.state == .completed ? (completedDownloadIDs.contains(record.id) ? String(localized: "已下載") : String(localized: "完成檔已移除")) : record.state.displayTitle
            return "\(record.title)\(episode) — \(state) · \(progress) · \(speed)\(remaining)\(segments)\(failure)"
        }
        destinations = values.map { _ in nil }
        count.stringValue = "\(values.count)"
        // Progress events must not reset native row selection while the user clicks.
        if sameTasks {
            table.reloadData(forRowIndexes: IndexSet(rows.indices), columnIndexes: IndexSet(integer: 0))
        } else {
            reloadRowsPreservingSelection()
        }
        if values.isEmpty { showEmpty(String(localized: "No download tasks.")) } else { status.isHidden = true }
        updateDownloadControls()
    }

    private func performSelectedDownloadOperation(_ operation: DownloadOperation) {
        guard !previewOnly else { return }
        let index = table.selectedRow
        guard downloads.indices.contains(index), let service = downloadService else { return }
        let record = downloads[index]
        guard record.allowedOperations.contains(operation) else { return }
        Task { [weak self] in
            do {
                switch operation {
                case .pause: try await service.pause(record.id)
                case .resume: try await service.resume(record.id)
                case .cancel: try await service.cancel(record.id)
                case .deleteRecord: try await service.deleteRecord(record.id)
                case .deleteFile: try await service.deleteFile(record.id)
                case .openFile: try await self?.dependencies.actions.openDownload(record.id)
                }
                await self?.reloadDownloads()
            } catch { self?.showError(error) }
        }
    }

    @objc private func openCompletedFile() { performSelectedDownloadOperation(.openFile) }
    @objc private func revealCompletedFile() {
        guard !previewOnly, downloads.indices.contains(table.selectedRow), let service = downloadService else { return }
        let id = downloads[table.selectedRow].id
        Task { [weak self] in
            do { NSWorkspace.shared.activateFileViewerSelecting([try await service.fileForOpening(id)]) }
            catch { self?.showError(error) }
        }
    }
    private func confirmDeletion(_ message: String) -> Bool {
        let alert = NSAlert(); alert.messageText = message
        alert.informativeText = String(localized: "刪除記錄不刪完成檔；刪除完成檔不刪收藏。此操作無法撤銷。")
        alert.addButton(withTitle: String(localized: "取消")); alert.addButton(withTitle: String(localized: "刪除"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func deleteSelectedRecord() {
        guard !previewOnly, confirmDeletion(String(localized: "刪除所選下載記錄？")) else { return }
        performSelectedDownloadOperation(.deleteRecord)
    }
    @objc private func deleteSelectedFile() {
        guard !previewOnly, confirmDeletion(String(localized: "刪除所選完成檔？")) else { return }
        performSelectedDownloadOperation(.deleteFile)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, view.window?.firstResponder === table { activateSelection() }
        else { super.keyDown(with: event) }
    }
    @objc private func activateDiscoveryCard(_ gesture: NSClickGestureRecognizer) {
        guard !previewOnly, let index = cards.indexPathForItem(at: gesture.location(in: cards)) else { return }
        cards.selectionIndexPaths = [index]
        selectedRowID = identity(forRow: index.item)
        storeState()
        activateSelection()
    }

    @objc private func activateSelection() {
        guard !previewOnly else { return }
        if kind == .downloads { openCompletedFile(); return }
        if kind == .youtube { openYouTubeVideo(); return }
        guard destinations.indices.contains(selectedIndex), let destination = destinations[selectedIndex] else { return }
        if case .resume(let entry) = destination {
            guard operation == nil else { return }
            operation = Task { [weak self] in
                guard let self else { return }
                defer { self.operation = nil }
                do { try await self.dependencies.resumePlayback(entry) }
                catch { if self.attached { self.showError(error) } }
            }
            return
        }
        let sourceView: NSView? = isDiscovery
            ? cards.item(at: IndexPath(item: selectedIndex, section: 0))?.view
            : table.view(atColumn: 0, row: selectedIndex, makeIfNecessary: false)
        dependencies.actions.withTransitionSource(from: sourceView) {
            switch destination {
            case .bangumi(let id, let subject): dependencies.actions.openBangumi(id, subject)
            case .work(let id): dependencies.actions.openWork(id)
            case .update(let update): dependencies.actions.openUpdate(update)
            case .selection(let value): dependencies.actions.openSelection(value)
            case .address(let value): dependencies.actions.openLink(value)
            case .resume: break
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = WorkspaceSkinRowView()
        view.bindSkin(dependencies.skinAppearance, slot: rowSlot, componentID: componentID)
        return view
    }

    private var rowSlot: String { kind == .downloads ? "task" : kind == .search ? "result" : "row" }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        96 + CGFloat(dependencies.sessionState.state(for: instanceID).density * 16)
    }
    func presentationSettingsDidChange() {
        if isDiscovery {
            suppressSelectionChanges = true
            cards.collectionViewLayout = discoveryLayout()
            view.layoutSubtreeIfNeeded()
            restoreScroll(savedScrollPosition)
            suppressSelectionChanges = false
        } else { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
        updateDiscoveryGeometry()
    }

    private func discoveryLayout() -> NSCollectionViewLayout {
        if isVideoGrid {
            let density = dependencies.sessionState.state(for: instanceID).density
            return NSCollectionViewCompositionalLayout { _, environment in
                let width = environment.container.effectiveContentSize.width
                let spacing: CGFloat = 16
                let columns = max(1, Int((width + spacing) / CGFloat(280 + density * 32)))
                let cardWidth = max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
                let height = cardWidth * 9 / 16 + 94
                let item = NSCollectionLayoutItem(layoutSize: .init(
                    widthDimension: .absolute(cardWidth), heightDimension: .absolute(height)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(
                    widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                    subitems: [item])
                group.interItemSpacing = .fixed(spacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 20
                section.contentInsets = .init(top: 12, leading: 0, bottom: 24, trailing: 0)
                return section
            }
        }
        if kind == .schedule {
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / 7), heightDimension: .fractionalHeight(1)))
            item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(200)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 8
            return NSCollectionViewCompositionalLayout(section: section)
        }
        if kind == .feed {
            return WorkspaceFeedGridLayout(density: dependencies.sessionState.state(for: instanceID).density)
        }
        if kind == .recommendations || kind == .continuing {
            let density = dependencies.sessionState.state(for: instanceID).density
            let layout = NSCollectionViewFlowLayout()
            layout.scrollDirection = .horizontal
            layout.minimumInteritemSpacing = 10
            layout.minimumLineSpacing = 10
            layout.itemSize = NSSize(width: CGFloat((kind == .continuing ? 316 : 122) + density * 20),
                height: 120)
            return layout
        }
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let width = CGFloat(180 + dependencies.sessionState.state(for: instanceID).density * 20)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(
            widthDimension: .absolute(width), heightDimension: .fractionalHeight(1)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 10
        let configuration = NSCollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        return NSCollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        if kind == .youtube, youtubeVideos.indices.contains(indexPath.item) {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("followed.video"), for: indexPath)
            (item as? WorkspaceFollowedCard)?.configure(youtubeVideos[indexPath.item],
                appearance: dependencies.skinAppearance, componentID: componentID, previewOnly: previewOnly)
            return item
        }
        if isBilibiliVideoGrid, followedCards.indices.contains(indexPath.item) {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("followed.video"), for: indexPath)
            (item as? WorkspaceFollowedCard)?.configure(followedCards[indexPath.item],
                appearance: dependencies.skinAppearance, componentID: componentID, previewOnly: previewOnly)
            return item
        }
        if case .resume(let entry) = destinations[indexPath.item] {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("playback.resume"), for: indexPath)
            (item as? WorkspaceResumeCard)?.configure(entry: entry, appearance: dependencies.skinAppearance,
                componentID: componentID, previewOnly: previewOnly)
            return item
        }
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("discovery.card"), for: indexPath)
        guard let card = item as? WorkspaceDiscoveryCard else { return item }
        guard destinations[indexPath.item] != nil else {
            card.clear()
            return card
        }
        let row = indexPath.item
        let poster = posters.indices.contains(row) ? posters[row] : true
        let thumbnail = WorkspaceMediaThumbnail(
            url: coverURLs.indices.contains(row) ? coverURLs[row] : nil, poster: poster,
            appearance: dependencies.skinAppearance, componentID: componentID,
            previewOnly: previewOnly, fixedSize: false)
        let caption: String?
        if case .update(let update) = destinations[row] {
            caption = String(localized: "新集數 \(update.newIdentities.joined(separator: "、"))")
        } else { caption = nil }
        let title: String
        if case .update(let update) = destinations[row] { title = update.workTitle }
        else { title = visibleRowTitle(row) }
        card.configure(thumbnail: thumbnail, poster: poster, title: title, detail: rows[row],
                       caption: caption, appearance: dependencies.skinAppearance, componentID: componentID)
        return card
    }

    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        kind == .schedule ? Set(indexPaths.filter { destinations.indices.contains($0.item) && destinations[$0.item] != nil }) : indexPaths
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !previewOnly, !suppressSelectionChanges else { return }
        selectedRowID = identity(forRow: selectedIndex)
        storeState()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !previewOnly, !suppressSelectionChanges else { return }
        selectedRowID = identity(forRow: selectedIndex)
        storeState()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if kind == .downloads, downloads.indices.contains(row) {
            let identifier = NSUserInterfaceItemIdentifier("download.task")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? WorkspaceDownloadCell
                ?? WorkspaceDownloadCell(appearance: dependencies.skinAppearance, componentID: componentID, previewOnly: previewOnly)
            cell.identifier = identifier
            cell.configure(record: downloads[row], text: rows[row])
            return cell
        }
        let cell = NSTableCellView()
        let rowTitle = searchTitles.indices.contains(row) ? searchTitles[row] : visibleRowTitle(row)
        let label = NSTextField(wrappingLabelWithString: rowTitle)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        let prefix = rowTitle + " · "
        let detail = NSTextField(wrappingLabelWithString: rows[row].hasPrefix(prefix) ? String(rows[row].dropFirst(prefix.count)) : rows[row])
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        let isPoster = posters.indices.contains(row) ? posters[row] : true
        let thumbnail = WorkspaceMediaThumbnail(url: coverURLs.indices.contains(row) ? coverURLs[row] : nil,
            poster: isPoster, appearance: dependencies.skinAppearance, componentID: componentID,
            previewOnly: previewOnly, fixedSize: false)
        cell.addSubview(thumbnail)
        thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12).isActive = true
        thumbnail.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        thumbnail.widthAnchor.constraint(equalToConstant: isPoster ? 50 : 112).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: isPoster ? 76 : 64).isActive = true
        label.toolTip = rows[row]
        label.setAccessibilityHelp(rows[row])
        let labels = NSStackView(views: [label, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        labels.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(labels)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 14),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.widthAnchor.constraint(equalTo: labels.widthAnchor),
            detail.widthAnchor.constraint(equalTo: labels.widthAnchor),
        ])
        label.bindSkin(dependencies.skinAppearance, slot: rowSlot, componentID: componentID)
        detail.bindSkin(dependencies.skinAppearance, slot: rowSlot, componentID: componentID)
        cell.setAccessibilityLabel(rows[row])
        return cell
    }
    private func visibleRowTitle(_ row: Int) -> String {
        guard destinations.indices.contains(row) else { return rows[row] }
        switch destinations[row] {
        case .bangumi(_, let subject?): return subject.title
        case .update(let update):
            return String(localized: "\(update.workTitle) · 新集數 \(update.newIdentities.joined(separator: "、"))")
        case .address where followedCards.indices.contains(row): return followedCards[row].title
        default: return rows[row]
        }
    }

    private func attachHistory() {
        NotificationCenter.default.addObserver(self, selector: #selector(historyDidChange),
            name: PlaybackHistoryStore.didChangeNotification, object: nil)
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let service = try? self?.dependencies.downloads() else { return }
            for await _ in await service.events() {
                guard !Task.isCancelled, let self, self.attached else { return }
                self.reloadHistory()
            }
        }
        reloadHistory()
    }

    @objc private func historyDidChange() { if attached { reloadHistory() } }

    private func historyMenu(at indexPath: IndexPath) -> NSMenu? {
        guard !previewOnly, attached, historyEntries.indices.contains(indexPath.item) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: String(localized: "刪除記錄"), action: #selector(deleteHistoryEntry(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = historyEntries[indexPath.item].id
        menu.addItem(item)
        return menu
    }

    @objc private func deleteHistoryEntry(_ sender: NSMenuItem) {
        guard !previewOnly, attached, let id = sender.representedObject as? String else { return }
        do { try dependencies.playbackHistory().remove(id: id) }
        catch { showError(error) }
    }

    private func reloadHistory() {
        guard !previewOnly, attached else { return }
        historyReloadTask?.cancel()
        historyReloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let records = try await dependencies.downloads().list()
                guard attached, !Task.isCancelled else { return }
                historyEntries = try dependencies.playbackHistory().continuing(downloads: records)
                rows = historyEntries.map { entry in
                    "\(entry.title) · \(entry.episodeTitle ?? String(localized: "影片")) · \(entry.awaitingUpdates == true ? String(localized: "此集已看完 · 保留追更") : WorkspaceResumeCardView.timestamp(entry.position))"
                }
                destinations = historyEntries.map { .resume($0) }
                coverURLs = historyEntries.map(\.coverURL)
                posters = historyEntries.map { _ in true }
                count.stringValue = "\(historyEntries.count)"
                reloadRowsPreservingSelection()
                scroll.isHidden = historyEntries.isEmpty
                status.stringValue = String(localized: "尚無可繼續觀看的番劇；播放番劇後會自動保存實際位置。")
                status.isHidden = !historyEntries.isEmpty
                contentHeightDidChange?(continueHeight)
            } catch {
                guard attached, !Task.isCancelled else { return }
                historyEntries = []; rows = []; destinations = []
                count.stringValue = "0"
                reloadRowsPreservingSelection()
                scroll.isHidden = true
                showError(error)
                contentHeightDidChange?(continueHeight)
            }
        }
    }

    func setPageScrollOwner(_ page: WorkspaceScrollView?) {
        if kind == .feed, pageScrollOwner != nil { storeState() }
        let wasSuppressing = suppressSelectionChanges
        suppressSelectionChanges = true
        defer { suppressSelectionChanges = wasSuppressing }
        if let previous = pageScrollOwner {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: previous.contentView)
        }
        pageScrollOwner = page
        scroll.verticalScrollTarget = page
        guard kind == .feed, let panel = panelStack else { return }
        guard page != nil || expandedFeedHeight != nil else { return }
        expandedFeedHeight?.isActive = false
        expandedFeedWidth?.isActive = false
        expandedFeedHeight = nil
        expandedFeedWidth = nil
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: cards)
        (view as? WorkspaceDragRegionView)?.scrollOwner = page ?? scroll
        pendingPageScrollPosition = pendingPageScrollPosition ?? savedScrollPosition
        if let page {
            scroll.documentView = nil
            let contentIndex = panel.arrangedSubviews.firstIndex(of: scroll) ?? panel.arrangedSubviews.count
            panel.removeArrangedSubview(scroll)
            scroll.removeFromSuperview()
            cards.translatesAutoresizingMaskIntoConstraints = false
            panel.insertArrangedSubview(cards, at: contentIndex)
            expandedFeedHeight = cards.heightAnchor.constraint(equalToConstant: 120)
            expandedFeedWidth = cards.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32)
            expandedFeedHeight?.isActive = true
            expandedFeedWidth?.isActive = true
            page.contentView.postsBoundsChangedNotifications = true
            cards.postsFrameChangedNotifications = true
            if !previewOnly {
                NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                    name: NSView.boundsDidChangeNotification, object: page.contentView)
                NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                    name: NSView.frameDidChangeNotification, object: cards)
            }
            updateDiscoveryGeometry()
        } else {
            let contentIndex = panel.arrangedSubviews.firstIndex(of: cards) ?? panel.arrangedSubviews.count
            panel.removeArrangedSubview(cards)
            cards.removeFromSuperview()
            cards.translatesAutoresizingMaskIntoConstraints = true
            scroll.documentView = cards
            if !panel.arrangedSubviews.contains(scroll) { panel.insertArrangedSubview(scroll, at: contentIndex) }
        }
    }

    private var isNearFeedEnd: Bool {
        let owner = pageScrollOwner ?? scroll
        return (owner.documentView?.frame.height ?? 0) - owner.contentView.bounds.maxY < 240
    }


    private func updateDiscoveryGeometry() {
        guard kind == .feed || cards.collectionViewLayout is NSCollectionViewFlowLayout,
              !feedHeightUpdateScheduled else { return }
        feedHeightUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.feedHeightUpdateScheduled = false
            if self.isHorizontalDiscovery, let layout = self.cards.collectionViewLayout as? NSCollectionViewFlowLayout {
                let viewportHeight = self.scroll.contentView.bounds.height
                guard !self.scroll.isHidden, viewportHeight > 0 else { return }
                let density = self.dependencies.sessionState.state(for: self.instanceID).density
                let size = NSSize(width: CGFloat((self.kind == .continuing ? 316 : 122) + density * 20),
                    height: viewportHeight)
                if layout.itemSize != size { layout.itemSize = size; layout.invalidateLayout() }
                return
            }
            guard let layout = self.cards.collectionViewLayout as? WorkspaceFeedGridLayout,
                  self.cards.bounds.width > 0 else { return }
            layout.prepare()
            let value = layout.collectionViewContentSize.height
            if let height = self.expandedFeedHeight, abs(height.constant - value) > 0.5 { height.constant = value }
            if let position = self.pendingPageScrollPosition, let page = self.pageScrollOwner {
                page.documentView?.layoutSubtreeIfNeeded()
                self.restoreScroll(position)
                self.pendingPageScrollPosition = nil
            } else if let position = self.pendingPageScrollPosition, self.view.window != nil {
                self.restoreScroll(position)
                self.pendingPageScrollPosition = nil
            }
        }
    }


    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !previewOnly else { return }
        guard !suppressSelectionChanges else { return }
        selectedRowID = identity(forRow: table.selectedRow)
        storeState()
        updateDownloadControls()
    }

    private func identity(forRow index: Int) -> String? {
        guard rows.indices.contains(index) else { return nil }
        if kind == .downloads, downloads.indices.contains(index) {
            return downloads[index].id.uuidString
        }
        if destinations.indices.contains(index), let destination = destinations[index] {
            switch destination {
            case .bangumi(let id, _): return "bangumi:\(id)"
            case .work(let id): return "work:\(id)"
            case .update(let value): return "update:\(value.workID):\(value.sourceID)"
            case .selection(let value): return "selection:\(value.item.sourceID):\(value.item.pageURL)"
            case .address(let value): return "url:\(value)"
            case .resume(let entry): return "history:\(entry.id)"
            }
        }
        return "row:\(rows[index])"
    }

    private func reloadRowsPreservingSelection() {
        suppressSelectionChanges = true
        if isDiscovery { cards.reloadData() } else { table.reloadData() }
        if let selectedRowID, let index = rows.indices.first(where: { identity(forRow: $0) == selectedRowID }) {
            if isDiscovery { cards.selectionIndexPaths = [IndexPath(item: index, section: 0)] }
            else { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        } else if isDiscovery { cards.selectionIndexPaths = [] }
        else if kind == .downloads {
            table.deselectAll(nil)
            selectedRowID = nil
        }
        if isDiscovery {
            view.layoutSubtreeIfNeeded()
            restoreScroll(savedScrollPosition)
        }
        suppressSelectionChanges = false
        updateDiscoveryGeometry()
    }

    private func updateDownloadControls() {
        guard kind == .downloads else { return }
        guard downloads.indices.contains(table.selectedRow) else {
            downloadSelection.stringValue = String(localized: "請先選取下載任務，再使用下方操作。")
            downloadSelection.toolTip = nil
            primary.isEnabled = false
            secondary.isEnabled = false
            cancelButton.isEnabled = false
            [openFileButton, revealButton, deleteRecordButton, deleteFileButton].forEach { $0.isEnabled = false }
            return
        }
        let record = downloads[table.selectedRow]
        let allowed = record.allowedOperations
        downloadSelection.stringValue = String(localized: "所選任務：\(record.title)")
        downloadSelection.toolTip = record.title
        primary.isEnabled = allowed.contains(.pause)
        secondary.isEnabled = allowed.contains(.resume)
        cancelButton.isEnabled = allowed.contains(.cancel)
        openFileButton.isEnabled = allowed.contains(.openFile)
        revealButton.isEnabled = allowed.contains(.openFile)
        deleteRecordButton.isEnabled = allowed.contains(.deleteRecord)
        deleteFileButton.isEnabled = allowed.contains(.deleteFile)
    }

    private func showEmpty(_ message: String) {
        status.workspaceSkinBinding?.state = .normal
        rows = []
        destinations = []
        count.stringValue = "0"
        reloadRowsPreservingSelection()
        status.stringValue = message
        status.isHidden = false
    }

    private func showError(_ error: Error) {
        status.workspaceSkinBinding?.state = .error
        if kind == .search, let failure = error as? VideoGetError {
            switch failure {
            case .invalidLink: status.stringValue = String(localized: "網址格式無效；請輸入完整影片或 Bangumi 作品網址。")
            case .notSupported: status.stringValue = String(localized: "此網址不在既有來源的解析範圍；請改用支援的影片網址。")
            case .needLogin: status.stringValue = String(localized: "此來源需要登入；請至設定檢查帳號。")
            case .needVip, .cantWatch: status.stringValue = String(localized: "此影片不可觀看或需要來源會員權限。")
            case .isNotLiving: status.stringValue = String(localized: "此直播目前未開播。")
            default: status.stringValue = String(localized: "來源無法取得影片資訊：\(error.localizedDescription)")
            }
        } else { status.stringValue = error.localizedDescription }
        status.isHidden = false
    }

    private func storeState() {
        guard attached else { return }
        guard !previewOnly else { return }
        guard pendingPageScrollPosition == nil else { return }
        savedScrollPosition = Double(isHorizontalDiscovery ? scroll.contentView.bounds.origin.x : (pageScrollOwner ?? scroll).contentView.bounds.origin.y)
        let state = WorkspaceInstanceState(
            query: query, filter: filter, page: searchSnapshot?.page ?? 0, selection: selectedRowID,
            scrollPosition: savedScrollPosition, density: dependencies.sessionState.state(for: instanceID).density)
        do { try dependencies.sessionState.update(state, for: instanceID) }
        catch {
            if let window = view.window { window.presentError(error) }
            else { showError(error) }
        }
    }

    private func restoreScroll(_ position: Double) {
        guard isViewLoaded else { return }
        let scroll = isHorizontalDiscovery ? self.scroll : (pageScrollOwner ?? self.scroll)
        let maximum = isHorizontalDiscovery
            ? max(0, (scroll.documentView?.frame.width ?? 0) - scroll.contentView.bounds.width)
            : max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        let offset = min(max(0, position), Double(maximum))
        scroll.contentView.scroll(to: isHorizontalDiscovery ? NSPoint(x: offset, y: 0) : NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
private final class WorkspacePanelCountBadge: NSTextField {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(26, size.width + 14), height: max(20, size.height + 3))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        // The badge is taller than the native text cell; center the cell rather
        // than letting NSTextField draw at the top of the padded bounds.
        let textHeight = min(bounds.height, super.intrinsicContentSize.height)
        let textRect = NSRect(x: bounds.minX, y: bounds.midY - textHeight / 2,
                              width: bounds.width, height: textHeight)
        let alignedRect = backingAlignedRect(textRect, options: [
            .alignMinXNearest, .alignMinYNearest, .alignMaxXNearest, .alignMaxYNearest,
        ])
        cell?.drawInterior(withFrame: alignedRect, in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class WorkspaceDiscoveryCollectionView: NSCollectionView {
    private(set) var keyboardNavigation = false
    var contextMenu: ((IndexPath) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let contextMenu else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return contextMenu(indexPath)
    }

    private func updateKeyboardCards() {
        for case let card as WorkspaceDiscoveryCard in visibleItems() { card.updateKeyboardReveal() }
    }

    func beginHover(on card: WorkspaceDiscoveryCardView) {
        keyboardNavigation = false
        updateKeyboardCards()
        for item in visibleItems() where item.view !== card {
            (item.view as? WorkspaceDiscoveryCardView)?.endHover()
        }
    }
    override func mouseDown(with event: NSEvent) {
        keyboardNavigation = false
        updateKeyboardCards()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { keyboardNavigation = false; updateKeyboardCards() }
        return result
    }
    var activate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        keyboardNavigation = true
        if event.keyCode == 36 || event.keyCode == 76 { activate?() }
        else { super.keyDown(with: event) }
        updateKeyboardCards()
    }
}

@MainActor
private final class WorkspaceFollowedCard: NSCollectionViewItem {
    private let cover = NSView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let author = NSTextField(labelWithString: "")
    private let metadata = NSTextField(labelWithString: "")
    private let duration = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 10
        cover.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        for label in [author, metadata] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        duration.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        duration.textColor = .white
        duration.drawsBackground = true
        duration.backgroundColor = .black.withAlphaComponent(0.8)
        duration.wantsLayer = true
        duration.layer?.cornerRadius = 3
        duration.layer?.masksToBounds = true
        for child in [cover, titleLabel, author, metadata, duration] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cover.topAnchor.constraint(equalTo: view.topAnchor),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor, multiplier: 9.0 / 16),
            duration.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -8),
            duration.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            titleLabel.heightAnchor.constraint(equalToConstant: 36),
            author.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            author.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            author.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: author.bottomAnchor, constant: 3),
            metadata.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityChildren([])
    }

    override var isSelected: Bool {
        didSet { view.workspaceSkinBinding?.state = isSelected ? .selected : .normal }
    }

    func configure(_ card: BilibiliCard, appearance: SkinAppearance, componentID: String, previewOnly: Bool) {
        configure(title: card.title, thumbnailURL: card.picUrl, channel: card.name,
            viewCount: String(localized: "\(card.views) 次觀看"),
            durationText: card.duration > 0 ? WorkspaceResumeCardView.timestamp(card.duration) : "",
            appearance: appearance, componentID: componentID, previewOnly: previewOnly)
    }

    func configure(_ video: YouTubeVideo, appearance: SkinAppearance, componentID: String, previewOnly: Bool) {
        configure(title: video.title, thumbnailURL: video.thumbnailURL, channel: video.channel,
            viewCount: video.viewCountText, durationText: video.durationText,
            appearance: appearance, componentID: componentID, previewOnly: previewOnly)
    }

    private func configure(title: String, thumbnailURL: String, channel: String, viewCount: String,
                           durationText: String, appearance: SkinAppearance, componentID: String, previewOnly: Bool) {
        _ = view
        cover.subviews.forEach { $0.removeFromSuperview() }
        let image = WorkspaceMediaThumbnail(url: thumbnailURL, poster: false, appearance: appearance,
            componentID: componentID, previewOnly: previewOnly, fixedSize: false)
        cover.addSubview(image)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: cover.trailingAnchor),
            image.topAnchor.constraint(equalTo: cover.topAnchor),
            image.bottomAnchor.constraint(equalTo: cover.bottomAnchor),
        ])
        titleLabel.stringValue = title
        author.stringValue = channel
        metadata.stringValue = viewCount
        duration.stringValue = " \(durationText) "
        duration.isHidden = durationText.isEmpty
        view.bindSkin(appearance, slot: "row", componentID: componentID)
        view.workspaceSkinBinding?.state = isSelected ? .selected : .normal
        view.setAccessibilityLabel(title)
        view.setAccessibilityHelp("\(channel) · \(metadata.stringValue) · \(duration.stringValue)")
    }
}

@MainActor
private final class WorkspaceDiscoveryCard: NSCollectionViewItem {
    override func loadView() { view = WorkspaceDiscoveryCardView() }

    override var isSelected: Bool {
        didSet {
            view.workspaceSkinBinding?.state = isSelected ? .selected : .normal
            updateKeyboardReveal()
        }
    }

    func updateKeyboardReveal() {
        (view as? WorkspaceDiscoveryCardView)?.keyboardFocused =
            isSelected && (collectionView as? WorkspaceDiscoveryCollectionView)?.keyboardNavigation == true
    }

    func clear() {
        (view as? WorkspaceDiscoveryCardView)?.clear()
    }

    func configure(thumbnail: NSView, poster: Bool, title: String, detail: String, caption: String?,
                   appearance: SkinAppearance, componentID: String) {
        guard let card = view as? WorkspaceDiscoveryCardView else { return }
        card.configure(thumbnail: thumbnail, poster: poster, title: title, detail: detail, caption: caption)
        card.bindSkin(appearance, slot: "row", componentID: componentID)
        card.workspaceSkinBinding?.state = isSelected ? .selected : .normal
        updateKeyboardReveal()
    }
}

@MainActor
private final class WorkspaceDiscoveryCardView: NSView {
    private let coverContainer = NSView()
    private let overlay = NSView()
    private let filter = NSVisualEffectView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailHint = NSTextField(labelWithString: String(localized: "連按兩下查看詳情"))
    private let captionLabel = NSTextField(labelWithString: "")
    private var captionHeight: NSLayoutConstraint!
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var populated = false
    var keyboardFocused = false { didSet { updateReveal(animated: true) } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for child in [coverContainer, overlay, captionLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        coverContainer.wantsLayer = true
        coverContainer.layer?.cornerRadius = 9
        coverContainer.layer?.masksToBounds = true
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 9
        overlay.layer?.masksToBounds = true
        filter.material = .hudWindow
        filter.blendingMode = .withinWindow
        filter.state = .active
        filter.appearance = NSAppearance(named: .vibrantDark)
        filter.wantsLayer = true
        filter.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        filter.alphaValue = 0.68
        filter.translatesAutoresizingMaskIntoConstraints = false
        filter.setAccessibilityElement(false)
        overlay.addSubview(filter)
        overlay.alphaValue = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .left
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byWordWrapping
        overlay.addSubview(titleLabel)
        detailHint.translatesAutoresizingMaskIntoConstraints = false
        detailHint.font = .systemFont(ofSize: 9, weight: .medium)
        detailHint.textColor = NSColor.white.withAlphaComponent(0.68)
        detailHint.lineBreakMode = .byTruncatingTail
        overlay.addSubview(detailHint)
        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textColor = .labelColor
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byTruncatingTail
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        for child in [coverContainer, overlay, titleLabel, detailHint, captionLabel] { child.setAccessibilityElement(false) }
        setAccessibilityChildren([])
        captionHeight = captionLabel.heightAnchor.constraint(equalToConstant: 0)
        captionHeight.isActive = true
        NSLayoutConstraint.activate([
            coverContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            coverContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            coverContainer.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            coverContainer.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -1),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            overlay.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: coverContainer.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor),
            filter.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            filter.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            filter.topAnchor.constraint(equalTo: overlay.topAnchor),
            filter.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: overlay.topAnchor, constant: 10),
            titleLabel.bottomAnchor.constraint(equalTo: detailHint.topAnchor, constant: -7),
            detailHint.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailHint.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailHint.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(thumbnail: NSView, poster: Bool, title: String, detail: String, caption: String?) {
        coverContainer.subviews.forEach { $0.removeFromSuperview() }
        coverContainer.addSubview(thumbnail)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor),
            thumbnail.topAnchor.constraint(equalTo: coverContainer.topAnchor),
            thumbnail.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor),
        ])
        titleLabel.stringValue = title
        captionLabel.stringValue = caption ?? ""
        captionHeight.constant = caption == nil ? 0 : 18
        setAccessibilityElement(true)
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail)
        populated = true
        keyboardFocused = false
        updateTrackingAreas()
        updateReveal(animated: false)
    }

    func clear() {
        populated = false
        hovered = false
        keyboardFocused = false
        coverContainer.subviews.forEach { $0.removeFromSuperview() }
        titleLabel.stringValue = ""
        captionLabel.stringValue = ""
        captionHeight.constant = 0
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
        setAccessibilityHelp(nil)
        updateReveal(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        if let window, window.isKeyWindow {
            hovered = hovered && visibleRect.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        } else { hovered = false }
        var options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect]
        if hovered { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        tracking = area
        updateReveal(animated: false)
    }
    override func mouseEntered(with event: NSEvent) {
        var ancestor = superview
        while let current = ancestor {
            if let collection = current as? WorkspaceDiscoveryCollectionView {
                collection.beginHover(on: self)
                break
            }
            ancestor = current.superview
        }
        hovered = true
        updateReveal(animated: true)
    }

    func endHover() { hovered = false; updateReveal(animated: true) }
    override func mouseExited(with event: NSEvent) { endHover() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false; keyboardFocused = false }
        updateReveal(animated: false)
    }

    override func layout() {
        let width = max(1, bounds.width - 22)
        if titleLabel.preferredMaxLayoutWidth != width { titleLabel.preferredMaxLayoutWidth = width }
        super.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    private func updateReveal(animated: Bool) {
        let alpha: CGFloat = populated && (hovered || keyboardFocused) ? 1 : 0
        guard overlay.alphaValue != alpha else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                overlay.animator().alphaValue = alpha
            }
        } else { overlay.alphaValue = alpha }
    }
}

extension WorkspaceServicePanelController: BilibiliDynamicMangerDelegate {
    func bilibiliDynamicStatusChanged(_ isLoading: Bool) {
        guard attached else { return }
        followedLoading = isLoading
        primary.isEnabled = !isLoading; secondary.isEnabled = !isLoading && !followedCards.isEmpty
        status.stringValue = followedFailure ?? (isLoading ? String(localized: "載入 Bilibili 關注動態…") : followedCards.isEmpty ? String(localized: "尚無動態；需登入 Bilibili 帳號，可至設定登入後刷新。") : "")
        status.isHidden = status.stringValue.isEmpty
        status.workspaceSkinBinding?.state = followedFailure != nil ? .error : isLoading ? .loading : .normal
    }
    func bilibiliDynamicFailed(_ message: String) {
        guard attached else { return }
        followedFailure = message
        status.stringValue = message; status.isHidden = false; status.workspaceSkinBinding?.state = .error
    }
    func bilibiliDynamicCards() -> [BilibiliCard] { followedCards }
    func bilibiliDynamicInitCards(_ cards: [BilibiliCard]) {
        guard attached else { return }
        followedCards = cards; showFollowedCards()
    }
    func bilibiliDynamicAppendCards(_ cards: [BilibiliCard]) {
        guard attached else { return }
        followedCards.append(contentsOf: cards); showFollowedCards()
    }
    func bilibiliDynamicInsertCards(_ cards: [BilibiliCard]) {
        guard attached else { return }
        followedCards.insert(contentsOf: cards, at: 0); showFollowedCards()
    }
}

@MainActor
private final class WorkspaceDownloadCell: NSTableCellView {
    private let artwork = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let progress = WorkspaceSkinProgressIndicator()
    private let skinAppearance: SkinAppearance
    private let componentID: String
    private let previewOnly: Bool
    private var thumbnail: WorkspaceMediaThumbnail?
    private var coverURL: String?

    init(appearance: SkinAppearance, componentID: String, previewOnly: Bool) {
        self.skinAppearance = appearance
        self.componentID = componentID
        self.previewOnly = previewOnly
        super.init(frame: .zero)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        progress.minValue = 0; progress.maxValue = 1
        for child in [artwork, label, progress] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            artwork.centerYAnchor.constraint(equalTo: centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 48),
            artwork.heightAnchor.constraint(equalToConstant: 72),
            label.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -5),
            progress.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            progress.heightAnchor.constraint(equalToConstant: 4),
        ])
        label.bindSkin(appearance, slot: "task", componentID: componentID)
        progress.bindSkin(appearance, slot: "progress", componentID: componentID)
    }
    required init?(coder: NSCoder) { nil }

    func configure(record: DownloadRecord, text: String) {
        if thumbnail == nil || coverURL != record.coverURL {
            thumbnail?.removeFromSuperview()
            coverURL = record.coverURL
            let image = WorkspaceMediaThumbnail(url: coverURL, poster: true, appearance: skinAppearance,
                componentID: componentID, previewOnly: previewOnly, fixedSize: false)
            thumbnail = image
            artwork.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: artwork.leadingAnchor),
                image.trailingAnchor.constraint(equalTo: artwork.trailingAnchor),
                image.topAnchor.constraint(equalTo: artwork.topAnchor),
                image.bottomAnchor.constraint(equalTo: artwork.bottomAnchor),
            ])
        }
        label.stringValue = text
        label.toolTip = text
        label.setAccessibilityHelp(text)
        progress.isIndeterminate = record.fractionCompleted == nil
        progress.doubleValue = record.fractionCompleted ?? 0
        progress.setAccessibilityLabel(record.title + (record.episodeTitle.map { " · " + $0 } ?? ""))
    }
}

@MainActor
private final class WorkspaceResumeCard: NSCollectionViewItem {
    override func loadView() { view = WorkspaceResumeCardView() }
    override var isSelected: Bool {
        didSet { view.workspaceSkinBinding?.state = isSelected ? .selected : .normal }
    }
    func configure(entry: PlaybackHistoryEntry, appearance: SkinAppearance, componentID: String, previewOnly: Bool) {
        (view as? WorkspaceResumeCardView)?.configure(entry: entry, appearance: appearance,
            componentID: componentID, previewOnly: previewOnly)
        view.bindSkin(appearance, slot: "row", componentID: componentID)
        view.workspaceSkinBinding?.state = isSelected ? .selected : .normal
    }
}

@MainActor
private final class WorkspaceResumeCardView: NSView {
    private let cover = NSView()
    private var thumbnail: WorkspaceMediaThumbnail?
    private var thumbnailURL: String?
    private var thumbnailPreviewOnly = false
    private weak var thumbnailAppearance: SkinAppearance?
    private var thumbnailComponentID: String?
    private let title = NSTextField(wrappingLabelWithString: "")
    private let episode = NSTextField(labelWithString: "")
    private let position = NSTextField(labelWithString: "")
    private let progress = WorkspaceSkinProgressIndicator()
    private let playIndicator = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 7
        cover.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        episode.font = .systemFont(ofSize: 12)
        episode.textColor = .secondaryLabelColor
        episode.lineBreakMode = .byTruncatingTail
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        position.textColor = .secondaryLabelColor
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        playIndicator.image = WorkspaceIcon.play.image(size: 14)
        playIndicator.imageScaling = .scaleNone
        playIndicator.contentTintColor = .white
        playIndicator.wantsLayer = true
        playIndicator.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        playIndicator.layer?.cornerRadius = 15
        playIndicator.setAccessibilityElement(false)
        let labels = NSStackView(views: [title, episode, position, progress])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
        for child in [cover, labels, playIndicator] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cover.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            cover.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            cover.widthAnchor.constraint(equalTo: cover.heightAnchor, multiplier: 2.0 / 3),
            labels.leadingAnchor.constraint(equalTo: cover.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            title.widthAnchor.constraint(equalTo: labels.widthAnchor),
            episode.widthAnchor.constraint(equalTo: labels.widthAnchor),
            position.widthAnchor.constraint(equalTo: labels.widthAnchor),
            progress.widthAnchor.constraint(equalTo: labels.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 4),
            playIndicator.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            playIndicator.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            playIndicator.widthAnchor.constraint(equalToConstant: 30),
            playIndicator.heightAnchor.constraint(equalToConstant: 30),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityChildren([])
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    static func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds).rounded(.down))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }

    func configure(entry: PlaybackHistoryEntry, appearance: SkinAppearance, componentID: String, previewOnly: Bool) {
        if thumbnail == nil || thumbnailURL != entry.coverURL || thumbnailPreviewOnly != previewOnly
            || thumbnailAppearance !== appearance || thumbnailComponentID != componentID {
            thumbnail?.removeFromSuperview()
            let image = WorkspaceMediaThumbnail(url: entry.coverURL, poster: true, appearance: appearance,
                componentID: componentID, previewOnly: previewOnly, fixedSize: false)
            thumbnail = image
            thumbnailURL = entry.coverURL
            thumbnailPreviewOnly = previewOnly
            thumbnailAppearance = appearance
            thumbnailComponentID = componentID
            cover.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
                image.trailingAnchor.constraint(equalTo: cover.trailingAnchor),
                image.topAnchor.constraint(equalTo: cover.topAnchor),
                image.bottomAnchor.constraint(equalTo: cover.bottomAnchor),
            ])
        }
        title.stringValue = entry.title
        episode.stringValue = entry.episodeTitle ?? String(localized: "影片")
        let knownDuration = entry.duration.flatMap { $0 > 0 ? $0 : nil }
        position.stringValue = entry.awaitingUpdates == true ? String(localized: "此集已看完 · 保留追更") :
            String(localized: "已看 \(Self.timestamp(entry.position))") + (knownDuration.map { " / \(Self.timestamp($0))" } ?? String(localized: " · 時長未知"))
        progress.doubleValue = knownDuration.map { min(1, entry.position / $0) } ?? 0
        progress.setAccessibilityLabel(knownDuration == nil ? String(localized: "播放時長未知") : String(localized: "觀看進度"))
        for label in [title, episode, position] { label.bindSkin(appearance, slot: "row", componentID: componentID) }
        progress.bindSkin(appearance, slot: "progress", componentID: componentID)
        let description = "\(entry.title) · \(episode.stringValue) · \(position.stringValue)"
        setAccessibilityLabel(description)
        setAccessibilityHelp(entry.awaitingUpdates == true ? String(localized: "尚未確認全季更新完畢。點選重播此集；新集可從詳情選播。") : String(localized: "點選從實際保存的位置繼續播放"))
        toolTip = description
    }
}

