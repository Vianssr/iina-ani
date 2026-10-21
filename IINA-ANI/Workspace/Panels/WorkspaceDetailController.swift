import AppKit
import SDWebImage
import HuyaKit
import SwiftSoup

@MainActor
private enum WorkspaceDetailRichText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        func safeURL(_ value: String) -> URL? {
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            return url
        }
        func newline() {
            if result.length > 0, !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n")) }
        }
        func append(_ node: SwiftSoup.Node) {
            if let text = node as? TextNode {
                result.append(NSAttributedString(string: text.getWholeText()))
                return
            }
            guard let element = node as? Element else { return }
            let tag = element.tagName().lowercased()
            guard !["script", "style", "iframe", "object"].contains(tag) else { return }
            if tag == "br" { result.append(NSAttributedString(string: "\n")); return }
            let block = ["p", "div", "li", "blockquote", "h1", "h2", "h3"].contains(tag)
            if block { newline() }
            let start = result.length
            for child in element.getChildNodes() { append(child) }
            if tag == "a", let href = try? element.attr("href"), let url = safeURL(href), result.length > start {
                result.addAttribute(.link, value: url, range: NSRange(location: start, length: result.length - start))
            }
            if block { newline() }
        }
        if let body = try? SwiftSoup.parseBodyFragment(text).body() {
            append(body)
        } else { result.append(NSAttributedString(string: text)) }
        let range = NSRange(location: 0, length: result.length)
        detector?.enumerateMatches(in: result.string, range: range) { match, _, _ in
            guard let match, let url = match.url, safeURL(url.absoluteString) != nil,
                  result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { return }
            result.addAttribute(.link, value: url, range: match.range)
        }
        return result
    }

    static func configure(_ field: NSTextField, text: NSAttributedString) {
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        let styled = NSMutableAttributedString(attributedString: text)
        styled.addAttributes([.font: field.font ?? NSFont.systemFont(ofSize: 13),
                              .foregroundColor: field.textColor ?? NSColor.labelColor],
                             range: NSRange(location: 0, length: styled.length))
        field.attributedStringValue = styled
    }
}

@MainActor
private final class WorkspaceDetailDescription: NSStackView {
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSButton(title: String(localized: "展開全文"), target: nil, action: nil)
    private var fullText = NSAttributedString(string: "")
    private var preview = NSAttributedString(string: "")
    private var expanded = false
    var stringValue = "" {
        didSet {
            guard oldValue != stringValue else { return }
            fullText = WorkspaceDetailRichText.render(stringValue)
            let text = fullText.string
            var end = text.startIndex
            var lines = 1
            for character in text.prefix(280) {
                if character == "\n" { lines += 1 }
                if lines > 6 { break }
                end = text.index(after: end)
            }
            let range = NSRange(text.startIndex..<end, in: text)
            let shortened = NSMutableAttributedString(attributedString: fullText.attributedSubstring(from: range))
            if end != text.endIndex { shortened.append(NSAttributedString(string: "…")) }
            preview = shortened
            toggle.isHidden = end == text.endIndex
            expanded = false
            updateText()
        }
    }
    init(appearance: SkinAppearance) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        textField.bindSkin(appearance, slot: "list", componentID: "detail.media")
        toggle.bindSkin(appearance, slot: "primaryAction", componentID: "detail.media")
        toggle.bezelStyle = .rounded
        toggle.target = self; toggle.action = #selector(toggleExpanded)
        addArrangedSubview(textField); addArrangedSubview(toggle)
        textField.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        textField.maximumNumberOfLines = 0
        toggle.isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    @objc private func toggleExpanded() { expanded.toggle(); updateText() }
    private func updateText() {
        WorkspaceDetailRichText.configure(textField, text: expanded ? fullText : preview)
        toggle.title = expanded ? String(localized: "收合") : String(localized: "展開全文")
        toggle.setAccessibilityValue(expanded ? String(localized: "已展開") : String(localized: "已收合"))
        textField.invalidateIntrinsicContentSize()
    }
}

@MainActor
final class WorkspaceCompletedDownloads {
    private struct Identity: Hashable {
        let id: UUID
        let workID: UUID?
        let bangumiID: Int?
        let episodeKey: String?
        let sourceID: String
        let pageURL: String
        let torrentURL: URL?
        let completedFile: URL?
        init(_ record: DownloadRecord) {
            id = record.id; workID = record.workID; bangumiID = record.bangumiID
            episodeKey = record.episodeKey
            let ref = record.selection.episode ?? record.selection.item
            sourceID = ref.sourceID; pageURL = ref.pageURL
            torrentURL = record.selection.torrent?.identityURL
            completedFile = record.completedFile
        }
    }
    private var eventsTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var snapshot: Set<Identity>?
    deinit { eventsTask?.cancel(); activationTask?.cancel() }
    func stop() {
        eventsTask?.cancel(); eventsTask = nil
        activationTask?.cancel(); activationTask = nil
    }
    private func refresh(_ service: DownloadService, update: @MainActor ([DownloadRecord]) -> Void) async {
        let records = await service.completedDownloads()
        guard !Task.isCancelled else { return }
        let next = Set(records.map(Identity.init))
        guard snapshot != next else { return }
        snapshot = next
        update(records)
    }
    func start(_ service: DownloadService, update: @escaping @MainActor ([DownloadRecord]) -> Void) {
        stop()
        eventsTask = Task { [weak self] in
            let events = await service.events()
            await self?.refresh(service, update: update)
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .changed(let record):
                    guard record.state == .completed || self?.snapshot?.contains(where: { $0.id == record.id }) == true else { continue }
                case .removed(let id):
                    guard self?.snapshot?.contains(where: { $0.id == id }) == true else { continue }
                case .snapshot: break
                }
                await self?.refresh(service, update: update)
            }
        }
        activationTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
            for await _ in notifications {
                guard !Task.isCancelled else { return }
                await self?.refresh(service, update: update)
            }
        }
    }
    static func same(_ a: PlayableSelection, _ b: PlayableSelection) -> Bool {
        if a.torrent != nil || b.torrent != nil { return a.torrent?.identityURL == b.torrent?.identityURL }
        let lhs = a.episode ?? a.item, rhs = b.episode ?? b.item
        return lhs.sourceID == rhs.sourceID && lhs.pageURL == rhs.pageURL
    }
    static func key(for selection: PlayableSelection, links: [WorkSourceLink], episodes: [Episode]) -> String? {
        let ids = Set(links.flatMap(\.episodeMappings).filter { same($0.selection, selection) }.map(\.episodeID))
        guard ids.count == 1, let id = ids.first else { return nil }
        return episodes.first(where: { $0.id == id })?.externalID.flatMap { $0.hasPrefix("bangumi:") ? $0 : nil } ?? id.uuidString
    }
}

enum WorkspaceDetailEpisodeAvailability {
    static func isUpdatedTitle(_ title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch title {
        case "", "未知", "標題未知", "标题未知": return false
        default: return title.caseInsensitiveCompare("unknown") != .orderedSame
        }
    }

    // Rows refer to the full metadata/local arrays, never the filtered button positions.
    static func index(for key: String, bangumi: [BangumiEpisode], local: [Episode]) -> Int? {
        if let index = bangumi.firstIndex(where: { "bangumi:\($0.id)" == key }) {
            return isUpdatedTitle(bangumi[index].title) ? index : nil
        }
        guard let index = local.firstIndex(where: { $0.id.uuidString == key }),
              isUpdatedTitle(local[index].label) else { return nil }
        return bangumi.count + index
    }
}

@MainActor
private final class WorkspaceDetailDocumentStack: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class WorkspaceDetailButtonGrid: NSView {
    override var isFlipped: Bool { true }
    private var measuredHeight: CGFloat = 40
    private var rowHeight: CGFloat = 40
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight) }
    func replace(_ items: [NSView], rowHeight: CGFloat = 40) {
        self.rowHeight = rowHeight
        subviews.forEach { $0.removeFromSuperview() }
        items.forEach { addSubview($0) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let columns = max(1, Int((bounds.width + 8) / 148))
        let width = max(1, (bounds.width - CGFloat(columns - 1) * 8) / CGFloat(columns))
        for (index, button) in subviews.enumerated() {
            button.frame = NSRect(x: CGFloat(index % columns) * (width + 8), y: CGFloat(index / columns) * rowHeight, width: width, height: rowHeight - 8)
        }
        let height = CGFloat(max(1, (subviews.count + columns - 1) / columns)) * rowHeight
        if measuredHeight != height { measuredHeight = height; invalidateIntrinsicContentSize() }
    }
}
@MainActor
private final class WorkspaceDetailAdaptiveColumns: NSStackView {
    private let breakpoint: CGFloat
    private var stackedWidths: [NSLayoutConstraint] = []
    init(views: [NSView], breakpoint: CGFloat) {
        self.breakpoint = breakpoint
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 16
        for item in views {
            addArrangedSubview(item)
            stackedWidths.append(item.widthAnchor.constraint(equalTo: widthAnchor))
        }
        NSLayoutConstraint.activate(stackedWidths)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        let target: NSUserInterfaceLayoutOrientation = bounds.width >= breakpoint ? .horizontal : .vertical
        if orientation != target {
            NSLayoutConstraint.deactivate(stackedWidths)
            orientation = target
            alignment = target == .horizontal ? .top : .leading
            distribution = target == .horizontal ? .fillEqually : .fill
            if target == .vertical { NSLayoutConstraint.activate(stackedWidths) }
        }
        super.layout()
    }
}

@MainActor
private final class WorkspaceDetailTagFlow: NSView {
    override var isFlipped: Bool { true }
    private var measuredHeight: CGFloat = 28
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight) }
    init(labels: [NSTextField]) {
        super.init(frame: .zero)
        for label in labels { addSubview(label) }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        var y: CGFloat = 0
        for label in subviews {
            let width = min(max(1, bounds.width), label.intrinsicContentSize.width)
            if x > 0 && x + width > bounds.width { x = 0; y += 32 }
            label.frame = NSRect(x: x, y: y, width: width, height: 28)
            x += width + 8
        }
        let height = subviews.isEmpty ? 0 : y + 28
        if measuredHeight != height { measuredHeight = height; invalidateIntrinsicContentSize() }
    }
}

/// Screen-local selection and cancellation; app owners retain persistent data and submitted operations.
@MainActor
final class WorkspaceDetailController: NSViewController, NSWindowDelegate, NSPopoverDelegate, WorkspaceDetachablePanel {
    private let delegate: AppDelegate
    private let appearance: SkinAppearance
    private let previewOnly: Bool
    private var services: AppServices { delegate.services }
    private lazy var sync = BangumiWorkSync(library: delegate.workLibrary)
    private lazy var animeSources = AnimeSourceService(decoder: services.decoder)
    private var animeReport: AnimeSourceReport?
    private var sourcePanel: NSPanel?
    private var quickDownloadPanel: NSPanel?
    private var quickDownloadController: WorkspaceQuickDownloadController?
    private var quickDownloadButton: WorkspaceSkinButton!
    private var playbackSourceTabs: NSSegmentedControl!
    private var webSourceView: NSView!
    private var webSourceFooter: NSView!
    private var torrentSourceHost: NSView!
    private var torrentSourceController: WorkspaceTorrentController?
    private let candidatePopup = NSPopUpButton()
    private let candidateEvidence = NSTextField(wrappingLabelWithString: String(localized: "開啟來源窗口後自動尋找已選集數。"))
    private var candidateControls: NSStackView!
    private var sourcePanelButton: WorkspaceSkinButton!
    private var exactPlayButton: WorkspaceSkinButton!
    private var catalogSection: NSView!
    private var sourceSelectionSection: NSView!
    private var findSourceButton: WorkspaceSkinButton!
    private let sourceDiagnostics = NSTextField(wrappingLabelWithString: "")
    private var sourceManagement: NSView!
    private var sourceManagementButton: WorkspaceSkinButton!
    private let panelStatus = NSTextField(wrappingLabelWithString: "")
    private let panelSelection = NSTextField(wrappingLabelWithString: "")
    private var extrasOperation: Task<Void, Never>?
    private var commentsOperation: Task<Void, Never>?
    private var extrasGeneration = UUID()
    private var commentsGeneration = UUID()
    private var extras: BangumiSubjectExtras?
    private var comments: [BangumiComment] = []
    private var nextCommentsPage: Int?
    private var commentsLoading = false
    private var extrasSubjectID: Int?
    private var overviewContent: WorkspaceDetailAdaptiveColumns!
    private var informationTabs: NSSegmentedControl!
    private let subjectInformation = NSStackView()
    private let tagsContent = NSStackView()
    private let commentsPage = NSStackView()
    private let heroRating = NSTextField(wrappingLabelWithString: "")
    private let charactersContent = NSStackView()
    private let relationsContent = NSStackView()
    private let commentsContent = NSStackView()
    private let commentsStatus = NSTextField(wrappingLabelWithString: "")
    private var moreCommentsButton: WorkspaceSkinButton!
    private var playbackCommand = false
    private var playbackSubmitted = false
    private var selectedEpisodeKey: String?
    private let completedObservation = WorkspaceCompletedDownloads()
    private var completedRecords: [DownloadRecord] = []
    private func observeCompletedDownloads() {
        guard !previewOnly, let downloads = try? services.downloads() else { return }
        completedObservation.start(downloads) { [weak self] records in
            guard let self, self.attached, self.isViewLoaded else { return }
            self.completedRecords = records
            self.rebuildEpisodeButtons(); self.rebuildCatalogButtons()
        }
    }
    private func episodeDownloaded(_ key: String) -> Bool {
        completedRecords.contains { record in
            if WorkspaceCompletedDownloads.key(for: record.selection, links: links, episodes: localEpisodes) == key { return true }
            guard let work, record.workID == work.id || (work.bangumiID != nil && record.bangumiID == work.bangumiID) else { return false }
            return record.episodeKey == key
        }
    }
    private var work: Work?
    private var links: [WorkSourceLink] = []
    private var localEpisodes: [Episode] = []
    private var selection: PlayableSelection?
    private var media: YouGetJSON?
    private var sourceCoverURL: String?
    private var leaves: [VideoTreeNode] = []
    private var leafTitles: [String] = []
    private var accounts: [SiteAccount] = []
    private var qualityKeys: [String] = []
    private var operation: Task<Void, Never>?
    private var metadataOperation: Task<Void, Never>?
    private var command: Task<Void, Never>?
    private var generation = UUID()
    private var metadataGeneration = UUID()
    private var updating = false
    private var loading = false
    private var commanding = false
    private var attached = true
    private var coverRequest: SDWebImageCombinedOperation?
    private var coverGeneration = UUID()
    private let cover = NSImageView()
    private let coverStatus = NSTextField(wrappingLabelWithString: String(localized: "來源未提供封面"))
    private let documentScroll = WorkspaceScrollView()
    private let heading = NSTextField(wrappingLabelWithString: String(localized: "作品／影片詳情"))
    private let metadata = NSTextField(wrappingLabelWithString: String(localized: "開啟作品、影片連結或搜尋結果。"))
    private let identity = NSTextField(wrappingLabelWithString: "")
    private lazy var summary = WorkspaceDetailDescription(appearance: appearance)
    private let episodeEmpty = NSTextField(wrappingLabelWithString: String(localized: "尚無集數資料"))
    private let catalogEmpty = NSTextField(wrappingLabelWithString: String(localized: "尚未載入來源"))
    private var catalogCaption: NSTextField!
    private let catalogGrid = WorkspaceDetailButtonGrid()
    private var accountRow: NSStackView!
    private var sourceRow: NSStackView!
    private var qualityRow: NSStackView!
    private var maintenance: NSStackView!
    private var moreButton: WorkspaceSkinButton!
    private var coverWidth: NSLayoutConstraint!
    private var coverHeight: NSLayoutConstraint!
    private let episodeGroups = NSStackView()
    private var sourceName: String?
    private var sourceTitle: String?
    private var sourceAuthor: String?
    private var sourceOnline: Bool?
    private let status = NSTextField(wrappingLabelWithString: String(localized: "尚未選擇來源。"))
    private let reasons = NSTextField(wrappingLabelWithString: "")
    private let address = NSTextField()
    private let sourceAddress = NSTextField()
    private let bangumiID = NSTextField()
    private let classificationPopup = NSPopUpButton()
    private let classificationStatus = NSTextField(wrappingLabelWithString: String(localized: "未知待確認"))
    private var classificationButton: WorkspaceSkinButton!
    private var associateButton: WorkspaceSkinButton!
    private var bangumiControls: NSStackView!
    private var episodeCaption: NSTextField!

    private let sources = NSPopUpButton()
    private let accountStatus = NSTextField(labelWithString: String(localized: "未登入"))
    private let qualities = NSPopUpButton()
    private let lines = NSPopUpButton()
    private let playerChoice = NSPopUpButton()
    private var autoOpenAfterSelection = false

    private var downloadButton: WorkspaceSkinButton!
    private var removeSourceButton: WorkspaceSkinButton!
    private var mapButton: WorkspaceSkinButton!
    private var favoriteWorkButton: WorkspaceSkinButton!
    private var collectionButtons: [WorkspaceSkinButton] = []
    private let collectionPopover = NSPopover()
    private var collectionKeyMonitor: Any?
    private var collectionOperation: Task<Void, Never>?
    private var collectionGeneration = UUID()
    private var collectionIdentity: String?
    private var collectionSaving = false
    private var workIsFavorite = false
    private var favoriteLinkButton: WorkspaceSkinButton!
    private var refreshButton: WorkspaceSkinButton!
    private var originalButton: WorkspaceSkinButton!
    private var unlinkButton: WorkspaceSkinButton!
    private var cancelButton: WorkspaceSkinButton!

    init(delegate: AppDelegate, appearance: SkinAppearance, previewOnly: Bool = false) {
        self.delegate = delegate
        self.appearance = appearance
        self.previewOnly = previewOnly
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { operation?.cancel(); metadataOperation?.cancel(); extrasOperation?.cancel(); commentsOperation?.cancel(); collectionOperation?.cancel(); if playbackCommand { command?.cancel() } }

    override func viewWillAppear() {
        super.viewWillAppear()
        attached = true
        observeCompletedDownloads()
        updateCommands()
        refreshCollectionStatus()
    }

    override func loadView() {
        let root = NSView()
        let scroll = documentScroll
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let content = WorkspaceDetailDocumentStack()
        content.orientation = .vertical
        content.alignment = .leading
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.spacing = 20
        scroll.documentView = content
        root.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        func append(_ item: NSView) {
            content.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        sources.target = self; sources.action = #selector(sourceChanged)
        sources.setAccessibilityLabel(String(localized: "作品來源"))
        sourceRow = row([label(String(localized: "來源")), sources])
        sourcePanelButton = button(String(localized: "播放所選集數…"), #selector(showSourcePanel), icon: .play)
        qualities.target = self; qualities.action = #selector(qualityChanged)
        lines.target = self; lines.action = #selector(lineChanged)
        accountStatus.setAccessibilityLabel(String(localized: "登入狀態"))
        qualities.setAccessibilityLabel(String(localized: "播放與下載共用的品質"))
        lines.setAccessibilityLabel(String(localized: "播放與下載共用的線路"))
        accountRow = row([label(String(localized: "帳號")), accountStatus])
        qualityRow = row([label(String(localized: "品質")), qualities, label(String(localized: "線路")), lines])
        playerChoice.addItems(withTitles: [String(localized: "偏好設定播放器"), String(localized: "外部 IINA／mpv"), String(localized: "內建 JSPlayer")])
        playerChoice.target = self; playerChoice.action = #selector(playerChanged)
        playerChoice.setAccessibilityLabel(String(localized: "播放器選擇"))
        downloadButton = button(String(localized: "Download"), #selector(download), icon: .downloads)
        quickDownloadButton = button(String(localized: "快速下載…"), #selector(showQuickDownload), icon: .downloads)
        cancelButton = button(String(localized: "取消来源操作"), #selector(cancelLoading), icon: .close)
        favoriteWorkButton = button(String(localized: "收藏作品…"), #selector(showCollectionPopover), icon: .favorites)
        favoriteWorkButton.toolTip = String(localized: "點選收藏方式即可確認。")
        collectionButtons = BangumiCollectionStatus.displayOrder.map { status in
            let control = button(status.title, #selector(favoriteWork(_:)))
            control.tag = status.rawValue
            return control
        }
        favoriteLinkButton = button(String(localized: "Favorite Link"), #selector(favoriteLink), icon: .bookmark)
        refreshButton = button(String(localized: "刷新"), #selector(refreshMetadata), icon: .refresh)
        originalButton = button(String(localized: "原始頁面"), #selector(openOriginal), icon: .openLink)
        moreButton = button(String(localized: "管理 ▸"), #selector(toggleMaintenance), icon: .settings)
        moreButton.setAccessibilityLabel(String(localized: "作品管理與資料狀態"))
        moreButton.setAccessibilityValue(String(localized: "已收合"))

        heading.setAccessibilityLabel(String(localized: "作品／影片名稱"))
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.setAccessibilityLabel(String(localized: "作品封面"))
        coverHeight = cover.heightAnchor.constraint(equalToConstant: 174)
        coverHeight.isActive = true
        coverWidth = cover.widthAnchor.constraint(equalToConstant: 116)
        coverWidth.isActive = true
        cover.isHidden = true
        let headerText = NSStackView(views: [heading, identity, heroRating, coverStatus])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 10
        for field in [heading, identity, heroRating, coverStatus] {
            field.widthAnchor.constraint(equalTo: headerText.widthAnchor).isActive = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        headerText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = row([cover, headerText])
        header.alignment = .top
        append(header)
        let libraryActions = row([favoriteWorkButton, favoriteLinkButton, quickDownloadButton])
        let utilityActions = row([refreshButton, originalButton, moreButton])
        let actions = WorkspaceDetailAdaptiveColumns(views: [libraryActions, utilityActions], breakpoint: 560)
        append(actions)
        let collectionControls = NSStackView(views: collectionButtons)
        collectionControls.orientation = .horizontal
        collectionControls.alignment = .centerY
        collectionControls.spacing = 8
        collectionControls.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionControls.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let collectionController = NSViewController()
        collectionController.view = collectionControls
        collectionPopover.contentViewController = collectionController
        collectionPopover.contentSize = NSSize(width: 340, height: 56)
        collectionPopover.behavior = .transient
        collectionPopover.delegate = self
        status.isSelectable = true
        append(status)

        episodeCaption = label(String(localized: "選集"))
        episodeCaption.bindSkin(appearance, slot: "header", componentID: "detail.media")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let episodeToolbar = row([episodeCaption, spacer, sourcePanelButton])
        episodeToolbar.distribution = .fill
        episodeGroups.orientation = .vertical
        episodeGroups.alignment = .leading
        episodeGroups.spacing = 14
        append(card(title: nil, items: [episodeToolbar, episodeGroups, episodeEmpty]))

        informationTabs = NSSegmentedControl(labels: [String(localized: "簡介"), String(localized: "人物"), String(localized: "關聯"), String(localized: "評論")], trackingMode: .selectOne, target: self, action: #selector(informationTabChanged))
        informationTabs.segmentStyle = .rounded
        informationTabs.selectedSegment = 0
        informationTabs.setAccessibilityLabel(String(localized: "作品資訊分頁"))
        for index in 0..<informationTabs.segmentCount { informationTabs.setWidth(72, forSegment: index) }
        append(informationTabs)
        metadata.isSelectable = true
        identity.isSelectable = true
        for section in [subjectInformation, charactersContent, relationsContent, commentsContent, commentsPage, tagsContent] {
            section.orientation = .vertical; section.alignment = .leading; section.spacing = 12
        }
        let synopsis = card(title: String(localized: "故事簡介"), items: [summary, tagsContent])
        let facts = card(title: String(localized: "作品資訊"), items: [subjectInformation])
        overviewContent = WorkspaceDetailAdaptiveColumns(views: [synopsis, facts], breakpoint: 760)
        moreCommentsButton = button(String(localized: "載入更多評論"), #selector(loadMoreComments), icon: .add)
        for item in [commentsContent, commentsStatus, moreCommentsButton] as [NSView] { appendInfo(item, to: commentsPage) }
        for page in [overviewContent!, charactersContent, relationsContent, commentsPage] {
            append(page)
        }
        updateInformationTab()

        address.placeholderString = String(localized: "影片／作品原始連結")
        address.setAccessibilityLabel(String(localized: "開啟影片連結"))
        classificationPopup.addItems(withTitles: MediaContentKind.allCases.map(\.title))
        classificationPopup.setAccessibilityLabel(String(localized: "手動確認內容類型"))
        classificationButton = button(String(localized: "確認／修正分類"), #selector(confirmClassification), icon: .check)
        bangumiID.placeholderString = String(localized: "Bangumi subject ID（手動確認）")
        bangumiID.setAccessibilityLabel(String(localized: "手動 Bangumi 作品 ID"))
        unlinkButton = button(String(localized: "解除"), #selector(unlinkBangumi), icon: .close)
        associateButton = button(String(localized: "Associate"), #selector(associateBangumi), icon: .sync)
        bangumiControls = row([bangumiID, associateButton, unlinkButton])
        sourceAddress.placeholderString = String(localized: "新增此作品的來源連結（不自動按名稱關聯）")
        sourceAddress.setAccessibilityLabel(String(localized: "新增來源連結"))
        removeSourceButton = button(String(localized: "移除來源關聯"), #selector(removeSource), icon: .delete)
        mapButton = button(String(localized: "將所選作品集數關聯到目前來源集數"), #selector(mapEpisode), icon: .sync)
        maintenance = NSStackView()
        maintenance.orientation = .vertical
        maintenance.alignment = .leading
        maintenance.spacing = 12
        for item in [card(title: String(localized: "作品管理"), items: [row([address, button(String(localized: "開啟"), #selector(openTypedAddress), icon: .openLink)]), classificationStatus, row([classificationPopup, classificationButton]), bangumiControls]), card(title: String(localized: "資料狀態"), items: [metadata])] {
            appendInfo(item, to: maintenance)
        }
        maintenance.isHidden = true
        append(maintenance)
        buildSourcePanel()
        view = root
        root.bindSkin(appearance, slot: "panel", componentID: "detail.media")
        heading.bindSkin(appearance, slot: "header", componentID: "detail.media")
        for field in [heading, identity, heroRating, metadata, status] {
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            if field !== heading { field.bindSkin(appearance, slot: "list", componentID: "detail.media") }
        }
        for field in [coverStatus, episodeEmpty, catalogEmpty, classificationStatus] {
            field.bindSkin(appearance, slot: "emptyState", componentID: "detail.media")
        }
        updateCommands()
    }

    @objc private func toggleMaintenance() {
        maintenance.isHidden.toggle()
        moreButton.title = maintenance.isHidden ? String(localized: "管理 ▸") : String(localized: "管理 ▾")
        moreButton.setAccessibilityValue(maintenance.isHidden ? String(localized: "已收合") : String(localized: "已展開"))
    }
    private func card(title: String?, items: [NSView]) -> NSView {
        let container = NSView()
        container.bindSkin(appearance, slot: "panel", componentID: "detail.media")
        let border = NSBox()
        border.boxType = .custom
        border.titlePosition = .noTitle
        border.fillColor = .clear
        border.borderColor = .separatorColor
        border.borderWidth = 1
        border.cornerRadius = 10
        container.addSubview(border)
        border.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            border.topAnchor.constraint(equalTo: container.topAnchor),
            border.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        if let title {
            let caption = label(title)
            caption.font = NSFontManager.shared.convert(caption.font ?? NSFont.systemFont(ofSize: 13), toHaveTrait: .boldFontMask)
            appendInfo(caption, to: stack)
        }
        for item in items { appendInfo(item, to: stack) }
        return container
    }
    private func factsGrid(_ entries: [(String, String)]) -> NSView {
        guard !entries.isEmpty else { return infoText(String(localized: "資訊來源尚未提供詳細資料。")) }
        let rows = entries.map { key, value -> [NSView] in
            let name = infoText(key)
            let detail = infoText(value.isEmpty ? String(localized: "未提供") : value)
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [name, detail]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10; grid.columnSpacing = 12
        grid.xPlacement = .fill; grid.yPlacement = .top
        grid.column(at: 0).width = 84
        return grid
    }
    @objc private func informationTabChanged() {
        updateInformationTab()
        view.layoutSubtreeIfNeeded()
        if let document = documentScroll.documentView {
            let origin = informationTabs.convert(informationTabs.bounds, to: document).origin
            documentScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, origin.y - 8)))
            documentScroll.reflectScrolledClipView(documentScroll.contentView)
        }
    }
    private func updateInformationTab() {
        let extended = classification.kind == .anime && (work?.bangumiID != nil || extrasSubjectID != nil)
        informationTabs.isHidden = !extended
        if !extended { informationTabs.selectedSegment = 0 }
        for (index, page) in [overviewContent!, charactersContent, relationsContent, commentsPage].enumerated() {
            page.isHidden = index != informationTabs.selectedSegment
        }
    }

    private func label(_ value: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.bindSkin(appearance, slot: "list", componentID: "detail.media")
        return field
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        for view in views where view is NSTextField && (view as? NSTextField)?.isEditable == true {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        }
        for view in views where view is NSPopUpButton {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return stack
    }
    private func button(_ title: String, _ action: Selector, icon: WorkspaceIcon? = nil) -> WorkspaceSkinButton {
        let button = WorkspaceSkinButton(title: title, target: self, action: action)
        button.setFunctionIcon(icon)
        button.bezelStyle = .rounded
        button.bindSkin(appearance, slot: "primaryAction", componentID: "detail.media")
        button.isEnabled = !previewOnly
        button.updateSkinState()
        return button
    }
    private func selectionButton(_ title: String, identity: String, action: Selector, selected: Bool) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded
        value.setButtonType(.pushOnPushOff)
        value.state = selected ? .on : .off
        value.identifier = NSUserInterfaceItemIdentifier(identity)
        value.lineBreakMode = .byTruncatingTail
        value.toolTip = title
        value.setAccessibilityLabel(title)
        value.setAccessibilityValue(selected ? String(localized: "已選取") : String(localized: "未選取"))
        value.isEnabled = !previewOnly
        return value
    }

    func openTorrent(_ address: String? = nil) {
        guard !previewOnly else { return }
        reset()
        playbackSourceTabs.selectedSegment = 1
        playbackSourceChanged()
        showSourcePanel()
        if let address { torrentSourceController?.openAddress(address) }
        else { torrentSourceController?.chooseTorrentFile() }
    }

    func openAddress(_ address: String, directly: Bool = false, with option: Bool = false) {
        guard !previewOnly else { return }
        if let subjectID = BrowseSearchService.bangumiSubjectID(URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines))) {
            openBangumi(subjectID); return
        }
        reset()
        self.address.stringValue = address
        autoOpenAfterSelection = services.preferences.autoOpenResult && !option && !(NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
        loadAddress(address, directly: directly, autoOpen: autoOpenAfterSelection, honorJSPlayer: true)
    }
    func openSelection(_ selection: PlayableSelection) {
        guard !previewOnly else { return }
        reset()
        address.stringValue = (selection.episode ?? selection.item).pageURL
        loadSelection(selection, autoOpen: isDirectBilibiliVideo(selection))
    }
    func openWork(_ id: UUID) {
        guard !previewOnly else { return }
        reset()
        do {
            guard let value = try delegate.workLibrary.fetchWork(id: id) else {
                throw WorkLibrary.LibraryError.workNotFound(id)
            }
            work = value
            showWork()
            refreshWorkMetadata(force: false)
        } catch { showError(error) }
    }
    func openBangumi(_ subjectID: Int, subject: BangumiSubject? = nil) {
        guard !previewOnly else { return }
        reset()
        loadExtraInformation(subjectID: subjectID, force: false)
        do {
            if let existing = try delegate.workLibrary.worksAssociated(withBangumiID: subjectID).first {
                work = existing; showWork(); refreshWorkMetadata(force: false)
                return
            }
        } catch { showError(error); return }
        if let subject {
            work = Work(bangumiID: subjectID, title: subject.title, aliases: subject.aliases,
                coverURL: subject.coverURL, summary: subject.summary, classification: subject.classification)
            showWork()
        }
        let token = metadataGeneration
        status.stringValue = String(localized: "載入 Bangumi 資料…")
        metadataOperation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await BangumiService.shared.metadata(subjectID: subjectID)
                guard self.acceptsMetadata(token) else { return }
                let subject = result.value.subject
                var value = self.work ?? Work(bangumiID: subjectID, title: subject.title)
                value.title = subject.title; value.aliases = subject.aliases
                value.coverURL = subject.coverURL; value.summary = subject.summary
                value.bangumiMetadata = result.value
                if !value.classificationIsManual { value.classification = subject.classification }
                if try self.delegate.workLibrary.fetchWork(id: value.id) != nil { try self.delegate.workLibrary.upsert(value) }
                self.work = value
                self.showWork()
                self.showMetadataOrigin(result.origin, failure: result.failure)
                self.status.stringValue = result.failure == nil ? String(localized: "作品資訊已載入；選集與播放來源獨立。") : String(localized: "已保留作品資料；部分資訊暫時無法更新。")
            } catch { if self.acceptsMetadata(token) { self.showError(error) } }
        }
    }
    func openUpdate(_ update: DiscoveryFavoriteUpdate) {
        guard !previewOnly else { return }
        openWork(update.workID)
        loadUpdate(update)
    }
    func attach() {
        guard !attached else { return }
        attached = true
        observeCompletedDownloads()
        if isViewLoaded { updateCommands(); refreshCollectionStatus() }
    }

    func detach() {
        attached = false
        closeCollectionPopover()
        completedObservation.stop()
        closeQuickDownload()
        hideSourcePanel(); invalidateExtraInformation()
        generation = UUID(); metadataGeneration = UUID()
        operation?.cancel(); metadataOperation?.cancel(); invalidatePlayback()
        invalidateCollectionOperation()
        coverRequest?.cancel(); coverGeneration = UUID()
        loading = false; commanding = false
    }
    func capabilitiesDidChange() {
        guard isViewLoaded else { return }
        updateCommands()
        quickDownloadController?.capabilitiesDidChange()
        guard !previewOnly, classification.kind != .anime, let choice = selection else { return }
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let values = try await self.services.decoder.accounts.accounts(sourceID: choice.item.sourceID)
                guard self.accepts(token) else { return }
                self.accounts = values; self.updateAccounts(); self.updateCommands()
            } catch { if self.accepts(token) { self.showError(error) } }
        }
    }
    private func reset() {
        _ = view
        attached = true
        closeCollectionPopover()
        closeQuickDownload()
        hideSourcePanel(); invalidateExtraInformation()
        extras = nil; extrasSubjectID = nil; comments = []; nextCommentsPage = nil
        generation = UUID(); metadataGeneration = UUID()
        operation?.cancel(); metadataOperation?.cancel(); invalidatePlayback()
        invalidateCollectionOperation()
        collectionIdentity = nil
        workIsFavorite = false
        coverRequest?.cancel(); coverGeneration = UUID(); cover.image = nil; cover.isHidden = true
        work = nil; links = []; localEpisodes = []; selection = nil; media = nil; sourceCoverURL = nil
        sourceName = nil; sourceTitle = nil; sourceAuthor = nil; sourceOnline = nil
        animeReport = nil
        sourceManagement.isHidden = true; sourceManagementButton.title = String(localized: "來源診斷與管理 ▸")
        sourceManagementButton.setAccessibilityValue(String(localized: "已收合"))
        renderCandidates()
        selectedEpisodeKey = nil
        summary.stringValue = String(localized: "簡介未知")
        commentsStatus.stringValue = ""
        renderOverview(); renderExtraInformation(); renderComments()
        maintenance.isHidden = true; moreButton.title = String(localized: "管理 ▸")
        informationTabs.selectedSegment = 0
        moreButton.setAccessibilityValue(String(localized: "已收合"))
        leaves = []; leafTitles = []; qualityKeys = []; accounts = []
        loading = false; commanding = false
        autoOpenAfterSelection = false
        updating = true
        rebuildEpisodeButtons(); rebuildCatalogButtons()
        for popup in [sources, qualities, lines] { popup.removeAllItems() }
        accountStatus.stringValue = String(localized: "未登入")
        heading.stringValue = String(localized: "作品／影片詳情")
        metadata.stringValue = String(localized: "影片不需要 Bangumi 關聯即可播放、收藏或下載。")
        bangumiID.stringValue = ""; sourceAddress.stringValue = ""; address.stringValue = ""
        coverStatus.stringValue = String(localized: "來源未提供封面"); coverStatus.isHidden = false
        documentScroll.contentView.scroll(to: .zero)
        documentScroll.reflectScrolledClipView(documentScroll.contentView)
        updating = false
        updateCommands()
    }
    private func accepts(_ token: UUID) -> Bool { attached && generation == token && !Task.isCancelled }
    private func acceptsMetadata(_ token: UUID) -> Bool { attached && metadataGeneration == token && !Task.isCancelled }
    private func beginLoading() -> UUID {
        operation?.cancel(); invalidatePlayback(); generation = UUID()
        loading = true; media = nil
        status.stringValue = String(localized: "載入所選來源…")
        status.workspaceSkinBinding?.state = .loading
        updateCommands()
        return generation
    }
    private func isDirectBilibiliVideo(_ choice: PlayableSelection) -> Bool {
        choice.item.sourceID == "bilibili" &&
            BilibiliUrl(url: (choice.episode ?? choice.item).pageURL)?.urlType == .video
    }

    private func loadAddress(_ value: String, directly: Bool = false, autoOpen: Bool = false, honorJSPlayer: Bool = false) {
        selection = nil; leaves = []; leafTitles = []
        updating = true; rebuildCatalogButtons(); updating = false
        let token = beginLoading()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                var choice = try await self.services.decoder.guestSelection(for: value)
                guard self.accepts(token) else { return }
                choice = try self.classifiedSelection(choice)
                if choice.classification.kind != .anime {
                    choice = try self.classifiedSelection(await self.services.decoder.selection(for: value))
                    self.accounts = try await self.services.decoder.accounts.accounts(sourceID: choice.item.sourceID)
                } else { self.accounts = [] }
                guard self.accepts(token) else { return }
                self.selection = choice; self.updateAccounts()
                if self.isDirectBilibiliVideo(choice) {
                    try await self.inspect(choice, token: token)
                    guard self.accepts(token) else { return }
                    self.autoOpenAfterSelection = true
                    self.showSourcePanel()
                    self.playSelectedMedia()
                    return
                }
                if honorJSPlayer, choice.classification.kind != .anime, self.usesJSPlayer(choice) {
                    try self.services.openJSPlayer(selection: choice, title: self.work?.title, coverURL: self.work?.coverURL ?? self.sourceCoverURL, episodeTitle: self.media?.title)
                    self.loading = false; self.autoOpenAfterSelection = false
                    self.status.stringValue = String(localized: "已將來源與帳號交給內建 JSPlayer。")
                    self.updateCommands(); return
                }
                await self.loadSourceMetadata(choice, token: token)
                guard self.accepts(token) else { return }
                switch try await self.services.decoder.inspect(choice, directly: directly) {
                case .selection(let catalog):
                    guard self.accepts(token) else { return }
                    var catalogChoice = catalog.selection
                    if catalogChoice.classification.kind == .unknown { catalogChoice.classification = choice.classification }
                    self.selection = try self.classifiedSelection(catalogChoice)
                    self.appendCatalog(catalog.nodes, prefix: "")
                    self.updating = true
                    self.rebuildCatalogButtons()

                    self.updating = false; self.loading = false
                    self.status.stringValue = String(localized: "選擇來源集數／分 P；未自動播放。")
                    self.updateCommands(); self.showSourcePanel()
                case .playable(let resolved):
                    try await self.adoptResolved(resolved, choice: choice, token: token)
                    if self.accepts(token), autoOpen, self.classification.kind != .anime { self.autoOpenAfterSelection = false; self.playSelectedMedia() }
                }
            } catch {
                // Keep a failed default account pinned; never switch silently to guest.
                if error is SiteAccountError, self.classification.kind != .anime, self.accepts(token),
                   let item = try? self.services.decoder.registry.item(for: value) {
                    self.selection = PlayableSelection(item: item, accountID: self.services.preferences.defaultAccountID(for: item.sourceID))
                    self.accounts = (try? await self.services.decoder.accounts.accounts(sourceID: item.sourceID)) ?? []
                    guard self.accepts(token) else { return }
                    self.updateAccounts()
                }
                await self.failLoad(error, token: token)
            }
        }
    }
    private func loadSelection(_ incoming: PlayableSelection, loadCatalog: Bool = true, autoOpen: Bool = false) {
        let choice: PlayableSelection
        do { choice = try classifiedSelection(incoming) }
        catch { showError(error); return }
        selection = choice
        let token = beginLoading()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.inspect(choice, token: token, loadCatalog: loadCatalog)
                if self.accepts(token), autoOpen, self.classification.kind != .anime {
                    if self.isDirectBilibiliVideo(choice) {
                        self.autoOpenAfterSelection = true
                        self.showSourcePanel()
                    }
                    self.playSelectedMedia()
                }
            }
            catch { await self.failLoad(error, token: token) }
        }
    }
    private func loadSourceMetadata(_ choice: PlayableSelection, token: UUID) async {
        let decoder = services.decoder
        guard work == nil, choice.item.kind != .local,
              decoder.registry.descriptor(for: choice.item.sourceID)?.capabilities.contains(.information) == true else { return }
        do {
            let page = (choice.episode ?? choice.item).pageURL
            let info = try await decoder.accounts.withSource(sourceID: choice.item.sourceID,
                accountID: choice.accountID, useDefaultAccount: false) {
                    try await decoder.liveInfo(page, false)
                }
            guard accepts(token) else { return }
            sourceName = decoder.registry.descriptor(for: choice.item.sourceID)?.name ?? choice.item.sourceID
            sourceTitle = info.title
            sourceAuthor = info.name.isEmpty ? nil : info.name
            sourceOnline = info.isLiving
            if !info.title.isEmpty { heading.stringValue = info.title }
            metadata.stringValue = String(localized: "資訊來源：\(sourceName ?? choice.item.sourceID)\n取得時間：\(Date().formatted())\n來源更新日期：未知")
            sourceCoverURL = info.cover.isEmpty ? nil : info.cover
            showCover(sourceCoverURL)
            renderOverview()
            updatePresentation()
        } catch {
            guard accepts(token) else { return }
            metadata.stringValue = String(localized: "來源基本資料暫時無法取得；解析與播放能力獨立。\n\(error.localizedDescription)")
        }
    }
    private func inspect(_ choice: PlayableSelection, token: UUID, loadCatalog: Bool = true) async throws {
        let decoder = services.decoder
        let available = choice.classification.kind == .anime ? [] : try await decoder.accounts.accounts(sourceID: choice.item.sourceID)
        guard accepts(token) else { return }
        accounts = available
        selection = choice
        updateAccounts()
        if loadCatalog { await loadSourceMetadata(choice, token: token) }
        if loadCatalog {
            var catalogRequest = choice
            if isDirectBilibiliVideo(choice), let episode = choice.episode { catalogRequest.item = episode }
            let catalog = try await decoder.catalog(for: catalogRequest)
            guard accepts(token) else { return }
            leaves = []; leafTitles = []
            if let catalog {
                if catalog.selection.classification.kind != .unknown {
                    var classified = choice
                    classified.classification = catalog.selection.classification
                    selection = try classifiedSelection(classified)
                }
                appendCatalog(catalog.nodes, prefix: "")
                if isDirectBilibiliVideo(choice) {
                    guard leaves.indices.contains(catalog.current) else { throw VideoGetError.notFountData }
                    selection?.episode = try decoder.registry.item(for: leaves[catalog.current].selectionURL)
                }
                // Keep the caller's pinned account/quality/line; catalog never chooses a different account.
                if choice.episode == nil, choice.item.kind == .work, !leaves.isEmpty {
                    loading = false
                    rebuildCatalogButtons()
                    status.stringValue = String(localized: "選擇來源集數／分 P；尚未猜測播放集數。")
                    updateCommands(); showSourcePanel()
                    return
                }
            }
            rebuildCatalogButtons()
        }
        let exact = selection ?? choice
        if exact.classification.kind == .anime { accounts = [] }
        let resolved = try await decoder.resolve(exact)
        try await adoptResolved(resolved, choice: exact, token: token)
    }
    private func adoptResolved(_ resolved: YouGetJSON, choice: PlayableSelection, token: UUID) async throws {
        let decoder = services.decoder
        guard accepts(token) else { return }
        var prepared = resolved
        var exact = resolved.selection ?? choice
        if exact.classification.kind == .unknown { exact.classification = choice.classification }
        exact = try classifiedSelection(exact)
        if exact.classification.kind == .anime { exact.accountID = nil }
        prepared.selection = exact
        if exact.qualityID == nil {
            guard let first = resolved.videos.first else { throw VideoGetError.notFountData }
            exact.qualityID = first.key
            prepared.selection = exact
            prepared = try await decoder.prepareVideoUrl(prepared, first.key)
        }
        guard accepts(token) else { return }
        selection = prepared.selection ?? exact
        selection?.classification = exact.classification
        prepared.selection = selection
        media = prepared
        loading = false
        if work == nil { heading.stringValue = prepared.title.isEmpty ? String(localized: "影片／直播") : prepared.title }
        renderOverview()
        address.stringValue = (selection?.episode ?? selection?.item)?.pageURL ?? choice.item.pageURL
        rebuildCatalogButtons()
        updateMediaMenus()
        status.stringValue = String(localized: "所選來源已就緒；播放與下載共用此選擇。")
        status.workspaceSkinBinding?.state = .normal
        updateCommands()
    }
    private func appendCatalog(_ nodes: [VideoTreeNode], prefix: String) {
        for node in nodes {
            if node.isLeaf {
                leaves.append(node); leafTitles.append(prefix + node.displayTitle)
            } else {
                appendCatalog(node.children, prefix: node.title.isEmpty ? prefix : prefix + node.title + " › ")
            }
        }
    }
    private func failLoad(_ error: Error, token: UUID) async {
        guard accepts(token) else { return }
        if let choice = selection, choice.classification.kind != .anime {
            let values = (try? await services.decoder.accounts.accounts(sourceID: choice.item.sourceID)) ?? []
            guard accepts(token) else { return }
            accounts = values
        }
        loading = false; media = nil
        showError(error); updateCommands()
    }
    private func showCover(_ raw: String?) {
        coverRequest?.cancel(); coverGeneration = UUID()
        cover.image = nil; cover.isHidden = true
        coverStatus.isHidden = false; coverStatus.stringValue = String(localized: "來源未提供封面")
        guard !previewOnly, let raw, let url = URL(string: raw) else { return }
        coverStatus.stringValue = String(localized: "封面載入中…")
        let token = coverGeneration
        coverRequest = SDWebImageManager.shared.loadImage(with: url, progress: nil) { [weak self] image, _, error, _, finished, _ in
            MainActor.assumeIsolated {
                guard let self, self.attached, self.coverGeneration == token, finished else { return }
                self.cover.image = image
                self.cover.isHidden = image == nil
                self.coverStatus.isHidden = image != nil
                self.coverStatus.stringValue = String(localized: "封面無法載入；其他作品資料仍可使用。")
                if error != nil { self.metadata.stringValue += String(localized: "\n封面暫時無法載入；其他作品資料仍可使用。") }
            }
        }
    }
    private func showWork() {
        guard let work else { return }
        heading.stringValue = work.title
        if let subjectID = work.bangumiID, extrasSubjectID != subjectID { loadExtraInformation(subjectID: subjectID, force: false) }
        let subject = extras?.subject.value ?? work.bangumiMetadata?.subject
        summary.stringValue = subject?.summary.flatMap { $0.isEmpty ? nil : $0 } ?? work.summary.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "簡介未知")
        let detail = [subject?.date.map { String(localized: "放送日期：\($0)") },
            (work.aliases + (subject?.aliases ?? [])).isEmpty ? nil : String(localized: "別名：\((work.aliases + (subject?.aliases ?? [])).joined(separator: "、"))"),
            work.classification.kind == .anime ? subject.map { String(localized: "已公開集數：\($0.episodeCount.map(String.init) ?? String(localized: "未知"))／總集數：\($0.totalEpisodes.map(String.init) ?? String(localized: "未知"))") } : nil,
            String(localized: "資訊來源：\(subject == nil ? String(localized: "本機作品資料") : "Bangumi")"),
            String(localized: "本機資料更新：\(work.updatedAt.formatted())")].compactMap { $0 }
        metadata.stringValue = detail.joined(separator: "\n")
        renderOverview()
        showCover(subject?.coverURL ?? work.coverURL)
        bangumiID.stringValue = work.bangumiID.map(String.init) ?? ""
        do {
            links = try delegate.workLibrary.sourceLinks(forWorkID: work.id)
            localEpisodes = try delegate.workLibrary.episodes(forWorkID: work.id)
            sourceName = links.isEmpty ? nil : Array(Set(links.map { services.decoder.registry.descriptor(for: $0.sourceWork.sourceID)?.name ?? $0.sourceWork.sourceID })).sorted().joined(separator: "、")
            updating = true
            sources.removeAllItems()
            sources.addItem(withTitle: String(localized: "選擇來源（不自動猜測）"))
            for link in links {
                let name = services.decoder.registry.descriptor(for: link.sourceWork.sourceID)?.name ?? link.sourceWork.sourceID
                sources.addItem(withTitle: "\(name) — \(link.sourceWork.pageURL)")
            }
            if let selection, let index = links.firstIndex(where: { $0.sourceWork.sourceID == selection.item.sourceID && $0.sourceWork.pageURL == selection.item.pageURL }) {
                sources.selectItem(at: index + 1)
            }
            rebuildEpisodeButtons()

            updating = false
            workIsFavorite = try delegate.favoriteLibrary.favoriteWorkIDs().contains(work.id)
            favoriteWorkButton.title = workIsFavorite ? String(localized: "已收藏作品…") : String(localized: "收藏作品…")
            updateCollectionSelection()
            updateCommands()
        } catch { updating = false; showError(error) }
    }
    private func refreshWorkMetadata(force: Bool) {
        guard let work, work.classification.kind == .anime else { return }
        metadataOperation?.cancel(); metadataGeneration = UUID()
        let token = metadataGeneration
        metadataOperation = Task { [weak self] in
            guard let self else { return }
            do {
                guard try self.delegate.workLibrary.fetchWork(id: work.id) != nil else {
                    guard let subjectID = work.bangumiID else { return }
                    let result = try await BangumiService.shared.metadata(subjectID: subjectID, forceRefresh: force)
                    guard self.acceptsMetadata(token) else { return }
                    var updated = work
                    updated.bangumiMetadata = result.value
                    self.work = updated; self.showWork()
                    self.showMetadataOrigin(result.origin, failure: result.failure)
                    return
                }
                let result = try await self.sync.refresh(workID: work.id, forceRefresh: force)
                guard self.acceptsMetadata(token) else { return }
                self.work = result.work; self.showWork()
                if let origin = result.origin { self.showMetadataOrigin(origin, failure: result.failure) }
            } catch { if self.acceptsMetadata(token) { self.showError(error) } }
        }
    }
    private func invalidateExtraInformation() {
        extrasOperation?.cancel(); commentsOperation?.cancel()
        extrasGeneration = UUID(); commentsGeneration = UUID()
        commentsLoading = false
    }
    private func loadExtraInformation(subjectID: Int, force: Bool) {
        invalidateExtraInformation()
        extrasSubjectID = subjectID
        if force || extras?.subject.value?.id != subjectID { extras = nil }
        comments = []; nextCommentsPage = 1
        commentsStatus.stringValue = String(localized: "評論載入中…")
        renderOverview(); renderExtraInformation(); renderComments()
        loadCommentsPage(subjectID: subjectID, page: 1, force: force)
        let token = extrasGeneration
        extrasOperation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await BangumiService.shared.subjectExtras(subjectID: subjectID, forceRefresh: force)
                guard attached, extrasGeneration == token, extrasSubjectID == subjectID, !Task.isCancelled else { return }
                extras = result
                if let subject = result.subject.value {
                    var value = work ?? Work(bangumiID: subjectID, title: subject.title, classification: subject.classification)
                    value.title = subject.title; value.aliases = subject.aliases
                    value.summary = subject.summary; value.coverURL = subject.coverURL
                    if !value.classificationIsManual { value.classification = subject.classification }
                    work = value
                    showWork()
                } else { renderOverview() }
                renderExtraInformation()
                updateCommands()
            } catch {
                guard attached, extrasGeneration == token, !Task.isCancelled else { return }
                clear(subjectInformation); appendInfo(infoText(error.localizedDescription), to: subjectInformation)
            }
        }
    }
    private func sectionOrigin<T: Sendable>(_ section: BangumiDetailSection<T>) -> String {
        let origin: String
        switch section.origin { case .network: origin = String(localized: "網路"); case .cache: origin = String(localized: "快取"); case .staleCache: origin = String(localized: "過期快取"); case nil: origin = String(localized: "未取得") }
        return "Bangumi · \(origin) · \(section.fetchedAt?.formatted() ?? String(localized: "時間未知"))" + (section.failure.map { "\n" + $0.localizedDescription } ?? "")
    }
    private func infoText(_ text: String) -> NSTextField {
        let field = label(text)
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        WorkspaceDetailRichText.configure(field, text: WorkspaceDetailRichText.render(text))
        return field
    }
    private func clear(_ stack: NSStackView) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }
    private func appendInfo(_ item: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(item)
        item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func renderOverview() {
        clear(subjectInformation); clear(tagsContent)
        let subject = extras?.subject.value ?? work?.bangumiMetadata?.subject
        var entries: [(String, String)] = []
        if let subject {
            entries = subject.infobox.map { ($0.key, $0.value.displayText) }
            if let date = subject.date, !entries.contains(where: { $0.1 == date }) { entries.insert((String(localized: "放送日期"), date), at: 0) }
            if classification.kind == .anime {
                entries.insert((String(localized: "集數"), String(localized: "已公開 \(subject.episodeCount.map(String.init) ?? String(localized: "未知"))／共 \(subject.totalEpisodes.map(String.init) ?? String(localized: "未知"))")), at: 0)
            }
            if let rating = subject.rating {
                let counts = rating.count.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
                entries.append((String(localized: "評分分佈"), counts.map { String(localized: "\($0)分 · \(rating.count[$0] ?? 0)人") }.joined(separator: "  ")))
            }
            if let collection = subject.collection {
                entries.append((String(localized: "收藏統計"), String(localized: "想看 \(collection.wish.map(String.init) ?? String(localized: "未知")) · 看過 \(collection.collect.map(String.init) ?? String(localized: "未知"))\n在看 \(collection.doing.map(String.init) ?? String(localized: "未知")) · 擱置 \(collection.onHold.map(String.init) ?? String(localized: "未知")) · 拋棄 \(collection.dropped.map(String.init) ?? String(localized: "未知"))")))
            }
            let tags = subject.tags.map { "#\($0.name) · \($0.count)" } + subject.metaTags.filter { tag in !subject.tags.contains(where: { $0.name == tag }) }.map { "#" + $0 }
            if !tags.isEmpty {
                appendInfo(WorkspaceDetailTagFlow(labels: tags.map { value in
                    let field = label("  " + value + "  ")
                    field.maximumNumberOfLines = 1
                    field.lineBreakMode = .byTruncatingTail
                    field.toolTip = value
                    return field
                }), to: tagsContent)
            }
        } else if let work {
            if !work.aliases.isEmpty { entries.append((String(localized: "別名"), work.aliases.joined(separator: "、"))) }
            entries.append((String(localized: "內容類型"), work.classification.kind.title))
            if let year = work.year { entries.append((String(localized: "年份"), String(year))) }
        } else {
            if let sourceName { entries.append((String(localized: "來源"), sourceName)) }
            if let sourceAuthor { entries.append((classification.kind == .live ? String(localized: "主播") : String(localized: "作者"), sourceAuthor)) }
        }
        appendInfo(factsGrid(entries), to: subjectInformation)
        if let section = extras?.subject { appendInfo(infoText(sectionOrigin(section)), to: subjectInformation) }
        else if extrasSubjectID != nil { appendInfo(infoText(String(localized: "Bangumi 資訊載入中…")), to: subjectInformation) }
        tagsContent.isHidden = tagsContent.arrangedSubviews.isEmpty
    }
    private func renderExtraInformation() {
        clear(charactersContent); clear(relationsContent)
        if let section = extras?.characters {
            appendInfo(infoText(sectionOrigin(section)), to: charactersContent)
            for character in section.value ?? [] {
                let actors = character.actors.map(\.name).joined(separator: "、")
                let identity = [character.name == character.title ? nil : character.name, character.relation.isEmpty ? nil : character.relation,
                    actors.isEmpty ? nil : String(localized: "配音：\(actors)")].compactMap { $0 }.joined(separator: " · ")
                let introduction = WorkspaceDetailDescription(appearance: appearance)
                introduction.stringValue = character.summary.isEmpty ? String(localized: "人物簡介未提供") : character.summary
                var items: [NSView] = [infoText(identity), introduction]
                if !character.infobox.isEmpty { items.append(factsGrid(character.infobox.map { ($0.key, $0.value.displayText) })) }
                if let failure = character.introductionFailure { items.append(infoText(String(localized: "人物介紹載入失敗：\(failure)"))) }
                let portrait = WorkspaceMediaThumbnail(url: character.coverURL, poster: true,
                    appearance: appearance, componentID: "detail.media", previewOnly: previewOnly)
                portrait.setAccessibilityLabel(String(localized: "\(character.title) 人物圖片"))
                let content = card(title: character.title, items: items)
                let characterRow = row([portrait, content])
                characterRow.alignment = .top
                content.widthAnchor.constraint(equalTo: characterRow.widthAnchor, constant: -64).isActive = true
                appendInfo(characterRow, to: charactersContent)
            }
            if section.value?.isEmpty == true { appendInfo(infoText(String(localized: "沒有公開人物資料。")), to: charactersContent) }
        } else { appendInfo(infoText(extrasSubjectID == nil ? String(localized: "尚無人物資料。") : String(localized: "人物介紹載入中…")), to: charactersContent) }
        if let section = extras?.relations {
            appendInfo(infoText(sectionOrigin(section)), to: relationsContent)
            var groups: [(String, [BangumiSubjectRelation])] = []
            for relation in section.value ?? [] {
                if let index = groups.firstIndex(where: { $0.0 == relation.relation }) { groups[index].1.append(relation) }
                else { groups.append((relation.relation, [relation])) }
            }
            for (relation, subjects) in groups {
                let grid = WorkspaceDetailButtonGrid()
                grid.replace(subjects.map { subject in
                    let value = button(subject.title, #selector(openRelatedSubject(_:)))
                    value.tag = subject.id
                    value.toolTip = subject.title
                    value.setAccessibilityLabel(String(localized: "應用內開啟 \(relation) · \(subject.title)"))
                    value.lineBreakMode = .byTruncatingTail
                    value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    let cover = WorkspaceMediaThumbnail(url: subject.coverURL, poster: true,
                        appearance: appearance, componentID: "detail.media", previewOnly: previewOnly)
                    cover.setAccessibilityLabel(String(localized: "\(subject.title) 封面"))
                    let item = NSStackView(views: [cover, value])
                    item.translatesAutoresizingMaskIntoConstraints = true
                    item.orientation = .vertical
                    item.alignment = .centerX
                    item.spacing = 8
                    value.widthAnchor.constraint(equalTo: item.widthAnchor).isActive = true
                    return item
                }, rowHeight: 132)
                appendInfo(card(title: relation, items: [grid]), to: relationsContent)
            }
            if section.value?.isEmpty == true { appendInfo(infoText(String(localized: "沒有公開關聯條目。")), to: relationsContent) }
        } else { appendInfo(infoText(extrasSubjectID == nil ? String(localized: "尚無關聯條目。") : String(localized: "關聯條目載入中…")), to: relationsContent) }
    }
    @objc private func openRelatedSubject(_ sender: NSButton) {
        guard !previewOnly, sender.tag > 0 else { return }
        openBangumi(sender.tag)
    }
    private func renderComments() {
        clear(commentsContent)
        for comment in comments {
            let rating = comment.rating.map { String(localized: " · \($0) 分") } ?? ""
            appendInfo(card(title: comment.author, items: [infoText(comment.dateText + rating), infoText(comment.text)]), to: commentsContent)
        }
        updateCommentsControls()
    }
    private func updateCommentsControls() {
        moreCommentsButton.isHidden = nextCommentsPage == nil
        moreCommentsButton.isEnabled = !previewOnly && !commentsLoading && nextCommentsPage != nil
        moreCommentsButton.title = commentsLoading ? String(localized: "評論載入中…") : String(localized: "載入更多評論")
    }
    @objc private func loadMoreComments() {
        guard !commentsLoading, let id = extrasSubjectID, let page = nextCommentsPage else { return }
        loadCommentsPage(subjectID: id, page: page, force: false)
    }
    private func loadCommentsPage(subjectID: Int, page: Int, force: Bool) {
        guard !previewOnly, !commentsLoading else { return }
        commentsLoading = true; updateCommentsControls()
        let token = commentsGeneration
        commentsOperation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await BangumiService.shared.comments(subjectID: subjectID, page: page, forceRefresh: force)
                guard attached, commentsGeneration == token, extrasSubjectID == subjectID, !Task.isCancelled else { return }
                let ids = Set(comments.map(\.id))
                comments.append(contentsOf: result.value.data.filter { !ids.contains($0.id) })
                nextCommentsPage = result.value.nextPage
                let origin: String
                switch result.origin { case .network: origin = String(localized: "網路"); case .cache: origin = String(localized: "快取"); case .staleCache: origin = String(localized: "過期快取") }
                commentsStatus.stringValue = String(localized: "Bangumi 公開短評 · \(origin) · 第 \(result.value.page) 頁 · \(result.fetchedAt?.formatted() ?? String(localized: "時間未知"))") + (comments.isEmpty ? String(localized: "\n尚無公開評論。") : "") + (result.failure.map { "\n" + $0.localizedDescription } ?? "")
                renderComments()
            } catch {
                guard attached, commentsGeneration == token, !Task.isCancelled else { return }
                commentsStatus.stringValue = String(localized: "評論載入失敗：\(error.localizedDescription)；已載入評論保留，可再試。")
            }
            commentsLoading = false; updateCommentsControls()
        }
    }

    private func showMetadataOrigin(_ origin: BangumiOrigin, failure: BangumiError?) {
        let originText: String
        switch origin { case .network: originText = String(localized: "網路"); case .cache: originText = String(localized: "快取"); case .staleCache: originText = String(localized: "過期快取") }
        let date = work?.bangumiMetadata?.fetchedAt.formatted() ?? String(localized: "未知")
        metadata.stringValue += "\nBangumi · \(originText) · \(date)"
        if let failure { metadata.stringValue += "\n\(failure.localizedDescription)" }
    }
    private func updateAccounts() {
        let account = selection?.accountID.flatMap { id in accounts.first { $0.id == id } }
        accountStatus.stringValue = account?.enabled == true && account?.status == .valid ? String(localized: "已登入") : String(localized: "未登入")
        let source = selection.map { SiteAccounts.canonicalSource($0.item.sourceID) }
        accountRow.isHidden = classification.kind == .anime || (source != "bilibili" && source != "douyu")
    }
    private func updateMediaMenus() {
        updating = true
        qualities.removeAllItems(); lines.removeAllItems()
        qualityKeys = media?.videos.map(\.key) ?? []
        for key in qualityKeys { qualities.addItem(withTitle: key) }
        if let key = selection?.qualityID, let index = qualityKeys.firstIndex(of: key) { qualities.selectItem(at: index) }
        lines.addItem(withTitle: String(localized: "預設線路"))
        if let key = selection?.qualityID, let stream = media?.streams[key] {
            for index in stream.src.indices { lines.addItem(withTitle: String(localized: "線路 \(index + 1)")) }
        }
        if let raw = selection?.lineID, let index = Int(raw), index < lines.numberOfItems { lines.selectItem(at: index) }
        updating = false
    }
    private func accountUnavailableReason(_ choice: PlayableSelection) -> String? {
        guard let id = choice.accountID else { return nil }
        guard let account = accounts.first(where: { $0.id == id }) else { return String(localized: "所選帳號已移除；請至設定管理帳號後重新開啟網址。") }
        if !account.enabled { return String(localized: "所選帳號已停用。") }
        if account.status != .valid { return String(localized: "所選帳號需要重新登入；不會改用另一個帳號。") }
        return nil
    }
    private func usesJSPlayer(_ choice: PlayableSelection) -> Bool {
        if playerChoice.indexOfSelectedItem == 2 { return true }
        return playerChoice.indexOfSelectedItem == 0 && services.preferences.enableFlvjs &&
            services.decoder.registry.descriptor(for: choice.item.sourceID)?.capabilities.contains(.jsPlayer) == true
    }
    @objc private func playerChanged() { updateCommands() }
    private func pluginPlaybackReason(_ choice: PlayableSelection) -> String? {
        guard !usesJSPlayer(choice), services.preferences.livePlayer == .iina,
              services.preferences.enableDanmaku,
              services.decoder.registry.descriptor(for: choice.item.sourceID)?.capabilities.contains(.danmaku) == true,
              IINAApp.getArchiveType() == .plugin else { return nil }
        switch IINAApp.pluginState() {
        case .ok, .isDev, .newer: return nil
        case .needsInstall: return String(localized: "此 IINA 外掛播放路徑需要彈幕外掛；請至設定 → 彈幕 → IINA 外掛安裝，或明確停用彈幕。")
        case .needsUpdate: return String(localized: "此 IINA 彈幕外掛需更新；請至設定 → 彈幕 → IINA 外掛更新。")
        case .multiple: return String(localized: "IINA 偵測到多個彈幕外掛；請在 IINA 外掛管理移除重複項目。")
        case .error: return String(localized: "無法讀取 IINA 彈幕外掛；請至設定 → 彈幕 → IINA 外掛檢查。")
        }
    }
    private func updateCommands() {
        guard isViewLoaded else { return }
        updateAccounts()
        if previewOnly {
            quickDownloadButton.isEnabled = false
            updatePresentation()
            collectionButtons.forEach { $0.isEnabled = false }
            for control in [exactPlayButton, downloadButton, removeSourceButton, mapButton, favoriteWorkButton, favoriteLinkButton] { control?.isEnabled = false }
            for control in [sources, qualities, lines, playerChoice] { control.isEnabled = false }
            for field in [address, sourceAddress, bangumiID] { field.isEnabled = false }
            classificationPopup.isEnabled = false; classificationButton.isEnabled = false; associateButton.isEnabled = false
            bangumiControls.isHidden = true; episodeCaption.isHidden = true; episodeGroups.isHidden = true; mapButton.isHidden = true
            status.stringValue = String(localized: "外觀預覽：只呈現控制項，不讀寫收藏、帳號或啟動網路操作。")
            return
        }
        var playReason: String?
        var downloadReason: String?
        if let choice = selection {
            let descriptor = services.decoder.registry.descriptor(for: choice.item.sourceID)
            if !services.decoder.isSourceEnabled(choice.item.sourceID) { playReason = String(localized: "來源已停用；請至來源設定重新啟用。") }
            else if let reason = accountUnavailableReason(choice) { playReason = reason }
            else if loading { playReason = String(localized: "正在載入所選來源。") }
            else if media == nil || choice.qualityID == nil {
                playReason = classification.kind == .live ? String(localized: "尚無可用直播串流或品質；可刷新房間狀態。") : String(localized: "請選擇有效來源集數／分 P 與品質。")
            }
            downloadReason = playReason
            if playReason == nil {
                let capability: SourceCapability = usesJSPlayer(choice) ? .jsPlayer : services.preferences.livePlayer == .mpv ? .mpv : .iina
                playReason = descriptor?.unavailableReason(for: capability) ?? (descriptor == nil ? String(localized: "來源能力未知。") : nil)
            }
            if playReason == nil { playReason = pluginPlaybackReason(choice) }

            if classification.kind == .live { downloadReason = String(localized: "直播不提供下載錄影；播放仍可獨立使用。") }
            else if !services.capabilityEnabled(.downloads) { downloadReason = String(localized: "新增下載已停用；至設定啟用。") }
            else if let reason = descriptor?.unavailableReason(for: .download) { downloadReason = reason }
            else if downloadReason == nil {
                do { try DownloadSourceResolver(decoder: services.decoder).validate(choice) }
                catch { downloadReason = error.localizedDescription }
            }
        } else { playReason = String(localized: "尚未選擇影片來源。"); downloadReason = playReason }
        downloadButton.isEnabled = downloadReason == nil && !commanding
        downloadButton.toolTip = downloadReason
        quickDownloadButton.isHidden = classification.kind == .live
        quickDownloadButton.isEnabled = attached && !commanding && services.capabilityEnabled(.downloads) && (work != nil || selection != nil) && classification.kind != .live
        quickDownloadButton.toolTip = services.capabilityEnabled(.downloads) ? String(localized: "選擇 BT 或在線來源，勾選多集下載。") : String(localized: "新增下載已停用；至設定啟用。")
        reasons.stringValue = [playReason.map { String(localized: "播放：\($0)") }, classification.kind == .live ? nil : downloadReason.map { String(localized: "下載：\($0)") }].compactMap { $0 }.joined(separator: "\n")
        removeSourceButton.isEnabled = sources.indexOfSelectedItem > 0 && !commanding
        mapButton.isEnabled = classification.kind == .anime && selection?.classification.kind == .anime && work != nil && currentLink != nil && (selectedEpisodeIndex ?? -1) >= 0 && media != nil && !loading && !commanding
        favoriteWorkButton.isEnabled = attached && (work != nil || media != nil) && !commanding
        for control in collectionButtons {
            control.isEnabled = favoriteWorkButton.isEnabled && !collectionSaving
                && (!workIsFavorite || control.tag != work?.collectionStatus?.rawValue)
        }
        favoriteLinkButton.isEnabled = selection != nil && !commanding
        let descriptor = selection.flatMap { services.decoder.registry.descriptor(for: $0.item.sourceID) }
        qualities.isEnabled = media != nil && descriptor?.capabilities.contains(.quality) == true && !loading && !commanding
        qualities.toolTip = descriptor?.unavailableReason(for: .quality)
        lines.isEnabled = media != nil && descriptor?.capabilities.contains(.lines) == true && !loading && !commanding
        lines.toolTip = descriptor?.unavailableReason(for: .lines)
        refreshButton.isEnabled = (work != nil || selection != nil) && !commanding
        originalButton.isEnabled = originalAddress != nil
        originalButton.toolTip = originalAddress == nil ? String(localized: "尚無原始作品或影片頁面。") : nil
        unlinkButton.isEnabled = work?.bangumiID != nil && !commanding && !collectionSaving
        let anime = classification.kind == .anime
        bangumiControls.isHidden = !anime
        mapButton.isHidden = !anime
        associateButton.isEnabled = anime && !loading && !commanding && !collectionSaving
        bangumiID.isEnabled = anime && !loading && !commanding && !collectionSaving
        classificationPopup.isEnabled = (work != nil || selection != nil) && !loading && !commanding && !collectionSaving
        classificationButton.isEnabled = classificationPopup.isEnabled
        classificationStatus.stringValue = String(localized: "類型：\(classification.kind.title)\n分類出處：\(classification.provenance)") + (classification.kind == .unknown ? String(localized: "\n尚未確認；播放不需要 Bangumi，番劇關聯與映射在確認為番劇前不可用。") : "")
        classificationPopup.selectItem(at: MediaContentKind.allCases.firstIndex(of: classification.kind) ?? 0)
        cancelButton.isEnabled = loading || playbackCommand
        cancelButton.isHidden = !loading && !playbackCommand
        downloadButton.isHidden = classification.kind == .live
        favoriteWorkButton.isHidden = !anime
        if !anime { closeCollectionPopover() }
        sourceRow.isHidden = work == nil || hasPinnedAnimeEpisode
        qualityRow.isHidden = media == nil
        removeSourceButton.isHidden = work == nil
        if let selection {
            let station = services.decoder.registry.descriptor(for: selection.item.sourceID)?.name ?? selection.item.sourceID
            panelSelection.stringValue = String(localized: "\(station) · \((selection.episode ?? selection.item).pageURL)\n品質：\(selection.qualityID ?? String(localized: "尚未解析")) · 線路：\(selection.lineID ?? String(localized: "預設"))")
        } else { panelSelection.stringValue = loading ? String(localized: "正在尋找或載入所選集數的來源。") : String(localized: "尚未選擇可播放的匹配來源。") }
        if let index = selectedEpisodeIndex {
            let title: String
            if bangumiEpisodes.indices.contains(index) {
                let episode = bangumiEpisodes[index]
                title = "\(episode.sort.formatted(.number.grouping(.never))) · \(episode.title)"
            } else {
                let episode = localOnlyEpisodes[index - bangumiEpisodes.count]
                title = "\(episode.sort.formatted(.number.grouping(.never))) · \(episode.label)"
            }
            panelSelection.stringValue = title + "\n" + panelSelection.stringValue
        }
        exactPlayButton.isEnabled = playReason == nil && !commanding && !playbackSubmitted && (!anime || !hasWorkEpisodes || selectedEpisodeIndex != nil)
        findSourceButton.isEnabled = animeCommandReason == nil
        findSourceButton.title = String(localized: "重新尋源")
        candidateControls.isHidden = !anime || !hasWorkEpisodes
        sourcePanelButton.isEnabled = !previewOnly && attached && (work != nil || selection != nil) && (!anime || !hasWorkEpisodes || selectedEpisodeIndex != nil)
        exactPlayButton.toolTip = playReason ?? (playbackSubmitted ? String(localized: "此選擇已提交播放；重選來源或集數後可再次播放。") : nil)
        exactPlayButton.isHidden = hasPinnedAnimeEpisode && media == nil
        mapButton.isHidden = !anime || hasPinnedAnimeEpisode
        panelStatus.stringValue = status.stringValue + (reasons.stringValue.isEmpty ? "" : "\n" + reasons.stringValue)
        candidateChanged()
        updatePresentation()
    }
    private func updatePresentation() {
        let scrollOrigin = documentScroll.contentView.bounds.origin
        let kind = classification.kind
        let anime = kind == .anime
        let live = kind == .live
        let subject = extras?.subject.value ?? work?.bangumiMetadata?.subject
        let year = work?.year.map(String.init) ?? subject?.date.map { String($0.prefix(4)) }
        var facts = [anime ? subject?.platform ?? kind.title : kind.title]
        if let year { facts.append(year) }
        if anime, let count = subject?.totalEpisodes { facts.append(String(localized: "全 \(count) 集")) }
        let originalTitle = subject?.name ?? sourceTitle
        var lines = originalTitle.flatMap { $0 == heading.stringValue || $0.isEmpty ? nil : $0 }.map { [$0] } ?? []
        lines.append(facts.joined(separator: " · "))
        if !anime, let author = sourceAuthor { lines.append(live ? String(localized: "主播：\(author)") : String(localized: "作者：\(author)")) }
        if live { lines.append(sourceOnline.map { $0 ? String(localized: "直播中") : String(localized: "未開播") } ?? String(localized: "直播狀態未知")) }
        identity.stringValue = lines.joined(separator: "\n")
        if let rating = subject?.rating {
            heroRating.stringValue = String(localized: "\(rating.score.formatted(.number.precision(.fractionLength(1)))) 分 · \(rating.total) 人評分") + (rating.rank.flatMap { $0 > 0 ? String(localized: " · 排名 #\($0)") : nil } ?? "")
        } else { heroRating.stringValue = "" }
        heroRating.isHidden = heroRating.stringValue.isEmpty
        coverWidth.constant = anime ? 116 : 180
        coverHeight.constant = anime ? 174 : 102
        cover.setAccessibilityLabel(anime ? String(localized: "作品海報") : String(localized: "影片縮圖"))
        episodeCaption.stringValue = anime ? String(localized: "選集") : live ? String(localized: "直播") : String(localized: "影片")
        let episodeCount = bangumiEpisodes.count + localOnlyEpisodes.count
        updateInformationTab()
        episodeGroups.isHidden = !anime || episodeCount == 0
        episodeEmpty.isHidden = !anime || episodeCount > 0
        episodeEmpty.stringValue = work?.bangumiMetadata == nil ? String(localized: "集數資料尚未載入；可刷新資訊，或選擇來源後查看來源選集。") : String(localized: "資訊來源未提供集數；請從來源窗口選擇精確集數。")
        sourcePanelButton.title = anime ? String(localized: "播放所選集數…") : live ? String(localized: "直播來源…") : String(localized: "選集與來源…")
        catalogCaption.stringValue = anime ? String(localized: "來源集數") : String(localized: "分 P／影片選擇")
        catalogSection.isHidden = live || hasPinnedAnimeEpisode
        sourceSelectionSection.isHidden = sourceRow.isHidden && candidateControls.isHidden
        catalogGrid.isHidden = leaves.isEmpty
        catalogEmpty.isHidden = !leaves.isEmpty
        catalogEmpty.stringValue = loading ? String(localized: "來源目錄載入中…") : selection == nil ? String(localized: "尚未選擇播放來源。") : media != nil ? String(localized: "單一影片；無額外分 P。") : String(localized: "尚無可用來源目錄；請查看載入結果。")
        view.layoutSubtreeIfNeeded()
        documentScroll.contentView.scroll(to: scrollOrigin)
        documentScroll.reflectScrolledClipView(documentScroll.contentView)
    }

    private func showError(_ error: Error) {
        guard !(error is CancellationError) else { return }
        if let failure = error as? WorkLibrary.LibraryError, failure == .animeRequired {
            status.stringValue = String(localized: "此操作只接受已確認的動畫作品；真人、直播或未知類型不可關聯為番劇。原關聯與資料保留。")
        } else if let failure = error as? VideoGetError, case .isNotLiving = failure {
            status.stringValue = String(localized: "此直播目前未開播；直播類型與房間連結保留，不提供下載錄影。")
        } else {
            status.stringValue = error.localizedDescription
        }
        status.workspaceSkinBinding?.state = .error
    }
    private var hasWorkEpisodes: Bool { work != nil && (!bangumiEpisodes.isEmpty || !localOnlyEpisodes.isEmpty) }
    private var hasPinnedAnimeEpisode: Bool { classification.kind == .anime && hasWorkEpisodes && selectedEpisodeIndex != nil }
    private var animeCommandReason: String? {
        guard attached, !previewOnly, classification.kind == .anime else { return String(localized: "請先開啟番劇詳情；一般影片與直播不使用番劇尋源。") }
        if loading || commanding { return String(localized: "番劇來源操作進行中；可取消後重選。") }
        if hasWorkEpisodes, (selectedEpisodeIndex ?? -1) < 0 { return String(localized: "請先選擇作品集數，再執行番劇尋源。") }
        if !hasWorkEpisodes, selection == nil { return String(localized: "請先選擇精確來源集數。") }
        return nil
    }
    private func invalidatePlayback() {
        command?.cancel(); playbackCommand = false; commanding = false
        playbackSubmitted = false

    }
    private func selectedAnimeEpisode() throws -> Episode {
        let value = try ensureWork()
        if let episode = localEpisode(at: (selectedEpisodeIndex ?? -1)) { return episode }
        let row = (selectedEpisodeIndex ?? -1)
        guard bangumiEpisodes.indices.contains(row) else { throw VideoGetError.notFountData }
        let remote = bangumiEpisodes[row]
        let kind: Episode.Kind = remote.type == 0 ? .main : remote.type == 1 ? .special : remote.type == 2 ? .opening : remote.type == 3 ? .ending : .other
        let episode = Episode(workID: value.id, externalID: "bangumi:\(remote.id)", kind: kind, label: remote.title, sort: remote.sort)
        try delegate.workLibrary.upsert(episode)
        localEpisodes.append(episode)
        return episode
    }
    private func discoverAnimeSources(force: Bool, playWhenMatched: Bool) {
        do {
            let episode = try selectedAnimeEpisode()
            guard let work else { return }
            operation?.cancel(); generation = UUID(); playbackSubmitted = false
            let token = generation
            loading = true
            status.stringValue = String(localized: "尋找已選作品與集數的公開來源…")
            runCommand(playback: true) { [self] in
                defer { if accepts(token) { loading = false } }
                let report = try await animeSources.discover(work: work, episode: episode, links: links, forceSearch: force)
                guard accepts(token) else { return }
                presentAnimeCandidates(report)
                let automatic = report.automaticCandidates
                if playWhenMatched, automatic.count == 1, let candidate = automatic.first {
                    status.stringValue = String(localized: "已匹配所選集數；正在解析並播放…")
                    try await resolveAndPlayAnimeCandidate(candidate, work: work, episode: episode, token: token)
                } else {
                    status.stringValue = report.matchedCandidates.isEmpty ? String(localized: "沒有能對應所選集數的來源；可重新尋源，原因見來源診斷。") : String(localized: "已找到所選集數；請選擇播放來源，不需重新選集。")
                }
            }
        } catch { showError(error) }
    }
    private func resolveAnimeCandidate(_ candidate: AnimeSourceCandidate, work: Work, episode: Episode, token: UUID) async throws {
        guard var choice = candidate.selection else { throw VideoGetError.notFountData }
        if let current = selection, current.item == choice.item, current.episode == choice.episode {
            choice.qualityID = current.qualityID; choice.lineID = current.lineID
        }
        choice.accountID = nil
        selection = choice; accounts = []; media = nil
        let pinned = AnimeSourceCandidate(id: candidate.id, sourceName: candidate.sourceName, title: candidate.title, selection: choice, evidence: candidate.evidence, failure: candidate.failure, trusted: candidate.trusted)
        let resolved = try await animeSources.resolve(pinned)
        guard accepts(token) else { throw CancellationError() }
        try await adoptResolved(resolved, choice: choice, token: token)
        guard accepts(token) else { throw CancellationError() }
        try animeSources.confirm(pinned, work: work, episode: episode, library: delegate.workLibrary)
        showWork()
    }
    private func submitAnimePlayback(token: UUID) async throws {
        guard accepts(token), let choice = selection, let prepared = media, let key = choice.qualityID else { throw CancellationError() }
        let descriptor = services.decoder.registry.descriptor(for: choice.item.sourceID)
        let capability: SourceCapability = usesJSPlayer(choice) ? .jsPlayer : services.preferences.livePlayer == .mpv ? .mpv : .iina
        if let reason = descriptor?.unavailableReason(for: capability) ?? pluginPlaybackReason(choice) {
            throw WorkspaceCapabilityFailure(reasons: [reason])
        }
        if usesJSPlayer(choice) {
            try Task.checkCancellation()
            guard accepts(token), !playbackSubmitted else { throw CancellationError() }
            playbackSubmitted = true
            try services.openJSPlayer(selection: choice, title: work?.title, coverURL: work?.coverURL ?? sourceCoverURL, episodeTitle: prepared.title)
        } else {
            try await services.player.prepareDanmakuFile(yougetJSON: prepared, id: prepared.uuid)
            try Task.checkCancellation()
            guard accepts(token), !playbackSubmitted else { throw CancellationError() }
            playbackSubmitted = true
            try await services.player.openWithPlayer(prepared, key, title: work?.title, coverURL: work?.coverURL ?? sourceCoverURL, episodeTitle: prepared.title)
        }
        if accepts(token) { status.stringValue = String(localized: "已提交所選番劇集數、品質與線路（訪客）；不會自動改播其他來源。") }
    }
    private func playExactAnime() {
        guard let choice = selection, media != nil, choice.qualityID != nil else {
            status.stringValue = String(localized: "所選集數的來源尚未就緒；請等待尋源或選擇匹配來源。"); return
        }
        let token = generation
        runCommand(playback: true) { [self] in
            let resolved = try await services.decoder.resolve(choice)
            try await adoptResolved(resolved, choice: choice, token: token)
            try await submitAnimePlayback(token: token)
        }
    }
    private func presentAnimeCandidates(_ report: AnimeSourceReport) {
        guard attached else { return }
        animeReport = report
        renderCandidates()
        showSourcePanel()
    }
    private func renderCandidates() {
        candidatePopup.removeAllItems()
        candidatePopup.addItem(withTitle: String(localized: "選擇匹配來源即播放"))
        let candidates = animeReport?.matchedCandidates ?? []
        for candidate in candidates {
            let item = NSMenuItem(title: "\(candidate.sourceName) — \(candidate.title)", action: nil, keyEquivalent: "")
            item.representedObject = candidate.id
            candidatePopup.menu?.addItem(item)
        }
        candidatePopup.autoenablesItems = false
        candidatePopup.isHidden = candidates.isEmpty
        if let selected = selection, let index = candidates.firstIndex(where: { $0.selection?.item == selected.item && $0.selection?.episode == selected.episode }) { candidatePopup.selectItem(at: index + 1) }
        let diagnostics = (animeReport?.candidates ?? []).filter { $0.failure != nil || $0.selection == nil }
        sourceDiagnostics.stringValue = diagnostics.isEmpty ? String(localized: "沒有未匹配來源或尋源失敗記錄。") : diagnostics.map { "\($0.sourceName) — \($0.title)：\($0.failure ?? String(localized: "未提供所選集數的精確身份"))" }.joined(separator: "\n")
        candidateChanged()
    }
    private func candidateChanged() {
        candidatePopup.isEnabled = !previewOnly && !loading && !commanding && hasPinnedAnimeEpisode && candidatePopup.numberOfItems > 1
        guard let id = candidatePopup.selectedItem?.representedObject as? String,
              let candidate = animeReport?.candidates.first(where: { $0.id == id && $0.selection != nil && $0.failure == nil }) else {
            if animeReport == nil { candidateEvidence.stringValue = String(localized: "自動尋找已選作品與集數；保存映射優先。") }
            else if candidatePopup.numberOfItems > 1 { candidateEvidence.stringValue = String(localized: "已找到所選集數；核對候選名稱後選擇來源，即解析並播放。") }
            else { candidateEvidence.stringValue = String(localized: "沒有可播放的匹配來源；請重新尋源或展開來源診斷。") }
            return
        }
        candidateEvidence.stringValue = String(localized: "匹配證據：\(candidate.evidence)\n來源已對應一級頁面所選集數；\(candidate.trusted ? String(localized: "已有明確映射或唯一作品／集數證據") : String(localized: "有多個候選或作品證據不足，請核對名稱及年份後選擇來源"))。")
    }
    @objc private func confirmCandidate() {
        guard !previewOnly, !loading, !commanding,
              let id = candidatePopup.selectedItem?.representedObject as? String,
              let candidate = animeReport?.candidates.first(where: { $0.id == id }), candidate.selection != nil, candidate.failure == nil else { return }
        if playbackSubmitted, let current = selection, current.item == candidate.selection?.item, current.episode == candidate.selection?.episode { return }
        candidateChanged()
        do {
            let episode = try selectedAnimeEpisode()
            guard let work else { return }
            playbackSubmitted = false
            let token = generation
            loading = true
            runCommand(playback: true) { [self] in
                try await resolveAndPlayAnimeCandidate(candidate, work: work, episode: episode, token: token)
            }
        } catch { showError(error) }
    }
    private func resolveAndPlayAnimeCandidate(_ candidate: AnimeSourceCandidate, work: Work, episode: Episode, token: UUID) async throws {
        do {
            try await resolveAnimeCandidate(candidate, work: work, episode: episode, token: token)
        } catch {
            guard accepts(token) else { throw CancellationError() }
            selection = nil; media = nil; loading = false
            qualityKeys = []; qualities.removeAllItems(); lines.removeAllItems()
            if let report = animeReport {
                animeReport = AnimeSourceReport(candidates: report.candidates.map {
                    $0.id == candidate.id ? AnimeSourceCandidate(id: $0.id, sourceName: $0.sourceName, title: $0.title, selection: $0.selection, evidence: $0.evidence, failure: error.localizedDescription, trusted: $0.trusted) : $0
                })
            }
            status.stringValue = String(localized: "來源解析失敗，詳情已移至來源診斷；可另選匹配來源，未改播其他站。")
            renderCandidates()
            return
        }
        guard accepts(token) else { throw CancellationError() }
        renderCandidates()
        try await submitAnimePlayback(token: token)
    }
    private func buildSourcePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = String(localized: "來源與播放選擇")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 460, height: 360)
        panel.delegate = self
        for field in [panelSelection, panelStatus, candidateEvidence, sourceDiagnostics] { field.isSelectable = true }
        let root = NSView()
        root.bindSkin(appearance, slot: "panel", componentID: "detail.media")
        panel.contentView = root
        playbackSourceTabs = NSSegmentedControl(labels: [String(localized: "線上來源"), String(localized: "BT 搜尋與播放")], trackingMode: .selectOne, target: self, action: #selector(playbackSourceChanged))
        playbackSourceTabs.selectedSegment = 0
        playbackSourceTabs.setAccessibilityLabel(String(localized: "播放來源類型"))
        root.addSubview(playbackSourceTabs)
        playbackSourceTabs.translatesAutoresizingMaskIntoConstraints = false
        torrentSourceHost = NSView()
        torrentSourceHost.isHidden = true
        root.addSubview(torrentSourceHost)
        torrentSourceHost.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        webSourceView = scroll
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        root.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = WorkspaceDetailDocumentStack()
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        candidatePopup.target = self; candidatePopup.action = #selector(confirmCandidate)
        candidatePopup.setAccessibilityLabel(String(localized: "選擇匹配來源即播放已選集數"))
        findSourceButton = button(String(localized: "重新尋源"), #selector(findPanelSources), icon: .search)
        candidateControls = NSStackView()
        candidateControls.orientation = .vertical; candidateControls.alignment = .leading; candidateControls.spacing = 10
        for item in [row([findSourceButton, candidatePopup]), candidateEvidence] as [NSView] { appendInfo(item, to: candidateControls) }
        sourceSelectionSection = card(title: String(localized: "匹配來源"), items: [sourceRow, candidateControls])
        catalogCaption = label(String(localized: "來源集數／分 P"))
        catalogSection = card(title: nil, items: [catalogCaption, catalogGrid, catalogEmpty])
        let configuration = card(title: String(localized: "播放設定"), items: [accountRow, qualityRow, row([label(String(localized: "播放器")), playerChoice])])
        sourceManagement = card(title: nil, items: [sourceDiagnostics, row([sourceAddress, button(String(localized: "新增來源"), #selector(addSource), icon: .add)]), removeSourceButton, mapButton])
        sourceManagement.isHidden = true
        sourceManagementButton = button(String(localized: "來源診斷與管理 ▸"), #selector(toggleSourceManagement), icon: .source)
        sourceManagementButton.setAccessibilityValue(String(localized: "已收合"))
        for item in [panelSelection, sourceSelectionSection!, catalogSection!, configuration, panelStatus, sourceManagementButton!, sourceManagement!] {
            content.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        }
        exactPlayButton = button(String(localized: "播放所選集數"), #selector(playPanelSelection), icon: .play)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = WorkspaceDetailAdaptiveColumns(views: [
            row([exactPlayButton, downloadButton]),
            row([spacer, cancelButton, button(String(localized: "關閉"), #selector(closeSourcePanel), icon: .close)]),
        ], breakpoint: 520)
        webSourceFooter = footer
        root.addSubview(footer)
        footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playbackSourceTabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            playbackSourceTabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            torrentSourceHost.topAnchor.constraint(equalTo: playbackSourceTabs.bottomAnchor, constant: 12),
            torrentSourceHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            torrentSourceHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            torrentSourceHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: playbackSourceTabs.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        sourcePanel = panel
    }
    @objc private func playbackSourceChanged() {
        let torrent = playbackSourceTabs.selectedSegment == 1
        webSourceView.isHidden = torrent
        webSourceFooter.isHidden = torrent
        torrentSourceHost.isHidden = !torrent
        if torrent {
            // Cancel automatic online playback before searching another source type.
            cancelLoading()
            guard torrentSourceController == nil else { return }
            let controller = WorkspaceTorrentController(delegate: delegate, appearance: appearance, previewOnly: previewOnly, work: work, sourceCoverURL: sourceCoverURL)
            addChild(controller)
            torrentSourceHost.addSubview(controller.view)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: torrentSourceHost.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: torrentSourceHost.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: torrentSourceHost.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: torrentSourceHost.bottomAnchor),
            ])
            torrentSourceController = controller
            if let keyword = work?.title ?? sourceTitle { controller.search(keyword: keyword) }
        } else {
            releaseTorrentSource()
        }
    }
    private func releaseTorrentSource() {
        torrentSourceController?.detach()
        torrentSourceController?.view.removeFromSuperview()
        torrentSourceController?.removeFromParent()
        torrentSourceController = nil
    }
    private func resetPlaybackSource() {
        releaseTorrentSource()
        playbackSourceTabs?.selectedSegment = 0
        webSourceView?.isHidden = false
        webSourceFooter?.isHidden = false
        torrentSourceHost?.isHidden = true
    }
    @objc private func showSourcePanel() {
        guard !previewOnly, attached, let parent = view.window, let panel = sourcePanel else { return }
        let opening = !panel.isVisible
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
            panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2, y: parent.frame.midY - panel.frame.height / 2))
        }
        panel.title = String(localized: "\(work?.title ?? heading.stringValue) · 來源與播放選擇")
        updateCommands()
        panel.makeKeyAndOrderFront(nil)
        if playbackSourceTabs.selectedSegment == 0, hasPinnedAnimeEpisode, animeCommandReason == nil, opening || animeReport == nil {
            discoverAnimeSources(force: false, playWhenMatched: true)
        }
    }
    @objc private func findPanelSources() {
        guard animeCommandReason == nil else { return }
        if hasWorkEpisodes { discoverAnimeSources(force: animeReport != nil, playWhenMatched: false) }
        else if let selection { loadSelection(selection) }
    }
    @objc private func toggleSourceManagement() {
        sourceManagement.isHidden.toggle()
        sourceManagementButton.title = sourceManagement.isHidden ? String(localized: "來源診斷與管理 ▸") : String(localized: "來源診斷與管理 ▾")
        sourceManagementButton.setAccessibilityValue(sourceManagement.isHidden ? String(localized: "已收合") : String(localized: "已展開"))
    }
    @objc private func closeSourcePanel() { sourcePanel?.close() }
    func windowWillClose(_ notification: Notification) {
        if let panel = quickDownloadPanel, (notification.object as? NSWindow) === panel {
            closeQuickDownload()
            return
        }
        guard let panel = sourcePanel, (notification.object as? NSWindow) === panel else { return }
        panel.parent?.removeChildWindow(panel)
        cancelLoading()
        resetPlaybackSource()
    }
    private func hideSourcePanel() {
        resetPlaybackSource()
        guard let panel = sourcePanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
    @objc private func playPanelSelection() {
        guard exactPlayButton.isEnabled else { return }
        if classification.kind == .anime { playExactAnime() }
        else { playSelectedMedia() }
    }

    private func runCommand(playback: Bool = false, _ body: @escaping @MainActor () async throws -> Void) {
        guard !previewOnly, !commanding else { return }
        commanding = true; playbackCommand = playback; updateCommands()
        let token = generation
        command = Task { [weak self] in
            guard let self else { return }
            do { try await body() }
            catch { if self.accepts(token) { self.showError(error) } }
            guard self.accepts(token) else { return }
            self.commanding = false; self.playbackCommand = false; self.updateCommands()
        }
    }
    private func ensureWork() throws -> Work {
        if let work {
            if try delegate.workLibrary.fetchWork(id: work.id) == nil { try delegate.workLibrary.upsert(work) }
            return work
        }
        let title = media.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "影片")
        let value = Work(title: title, coverURL: sourceCoverURL, classification: classification)
        try delegate.workLibrary.upsert(value)
        work = value
        if let item = selection?.item {
            let source = item
            _ = try delegate.favoriteLibrary.addSource(workID: value.id, source: source)
        }
        return value
    }
    private var classification: MediaClassification { work?.classification ?? selection?.classification ?? .unknown }
    private func classifiedSelection(_ choice: PlayableSelection) throws -> PlayableSelection {
        if work == nil {
            let linked = try delegate.workLibrary.worksLinked(to: choice.episode ?? choice.item)
            if linked.count == 1 { work = linked[0]; showWork() }
        }
        var result = choice
        if var existing = work {
            if !existing.classificationIsManual, choice.classification.kind != .unknown,
               existing.classification.kind == .unknown || MediaClassification.requiresBangumiLookup(for: choice.item) { 
                existing.classification = choice.classification
                try delegate.workLibrary.upsert(existing)
                work = existing; showWork()
            }
            result.classification = existing.classification
        }
        if result.classification.kind == .anime { result.accountID = nil }
        return result
    }
    @objc private func confirmClassification() {
        guard !previewOnly, !loading, !commanding, MediaContentKind.allCases.indices.contains(classificationPopup.indexOfSelectedItem) else { return }
        let kind = MediaContentKind.allCases[classificationPopup.indexOfSelectedItem]
        do {
            let value = try ensureWork()
            metadataOperation?.cancel(); metadataGeneration = UUID()
            work = try delegate.workLibrary.setClassification(workID: value.id, kind: kind)
            if let work { selection?.classification = work.classification }
            if kind == .anime {
                selection?.accountID = nil
                accounts = []
                media = nil
            }
            media?.selection = selection
            showWork()
            status.stringValue = String(localized: "已保存手動分類；作品、集數、收藏與下載身份保持不變。")
        } catch { showError(error) }
    }

    @objc private func openTypedAddress() { openAddress(address.stringValue) }
    @objc private func refreshMetadata() {
        guard !previewOnly else { return }
        if work?.classification.kind == .anime {
            if let id = work?.bangumiID { loadExtraInformation(subjectID: id, force: true) }
            refreshWorkMetadata(force: true)
            refreshCollectionStatus()
        }
        else if let selection { loadSelection(selection) }
    }
    private var originalAddress: String? {
        selection.map { ($0.episode ?? $0.item).pageURL } ?? work?.bangumiID.map { "https://bgm.tv/subject/\($0)" } ?? links.first?.sourceWork.pageURL
    }
    @objc private func openOriginal() {
        guard let raw = originalAddress, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func showCollectionPopover() {
        guard !previewOnly, attached, favoriteWorkButton.isEnabled else { return }
        if collectionPopover.isShown { closeCollectionPopover(); return }
        collectionPopover.show(relativeTo: favoriteWorkButton.bounds, of: favoriteWorkButton, preferredEdge: .minY)
        if let first = collectionButtons.first(where: \.isEnabled) {
            collectionPopover.contentViewController?.view.window?.makeFirstResponder(first)
        }
        collectionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.collectionPopover.isShown else { return event }
            self.closeCollectionPopover()
            return nil
        }
    }
    @objc private func closeCollectionPopover() {
        collectionPopover.performClose(nil)
    }
    func popoverDidClose(_ notification: Notification) {
        if let collectionKeyMonitor { NSEvent.removeMonitor(collectionKeyMonitor) }
        collectionKeyMonitor = nil
    }
    private func collectionKey(_ value: Work) -> String {
        "\(value.id.uuidString):\(value.bangumiID.map(String.init) ?? "local")"
    }
    private func invalidateCollectionOperation() {
        collectionOperation?.cancel()
        collectionGeneration = UUID()
        collectionSaving = false
    }
    private func acceptsCollection(_ token: UUID, workID: UUID) -> Bool {
        attached && collectionGeneration == token && work?.id == workID && !Task.isCancelled
    }
    private func updateCollectionSelection() {
        guard let value = work, value.classification.kind == .anime, !previewOnly else { return }
        // Metadata requests can finish after a collection edit; use the library's current collection fields.
        if let saved = try? delegate.workLibrary.fetchWork(id: value.id) {
            work?.collectionStatus = saved.collectionStatus
            work?.collectionStatusPending = saved.collectionStatusPending
        }
        let current = work ?? value
        let key = collectionKey(current)
        if collectionIdentity != key {
            collectionIdentity = key
            refreshCollectionStatus()
        }
    }
    private func refreshCollectionStatus() {
        guard !previewOnly, attached, !collectionSaving, let value = work, value.classification.kind == .anime else { return }
        invalidateCollectionOperation()
        let token = collectionGeneration
        do {
            // Opening one detail may persist its metadata, but does not add it to favorites.
            _ = try ensureWork()
        } catch {
            status.stringValue = String(localized: "無法讀取收藏分類：\(error.localizedDescription)")
            return
        }
        collectionOperation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.sync.refreshCollectionStatus(workID: value.id)
                guard self.acceptsCollection(token, workID: value.id) else { return }
                // Do not replace unrelated metadata.
                self.work?.collectionStatus = result.work.collectionStatus
                self.work?.collectionStatusPending = result.work.collectionStatusPending
            } catch {
                guard self.acceptsCollection(token, workID: value.id) else { return }
                self.status.stringValue = String(localized: "無法讀取 Bangumi 收藏分類：\(error.localizedDescription)")
            }
            guard self.acceptsCollection(token, workID: value.id) else { return }
            self.updateCollectionSelection()
            self.updateCommands()
        }
    }
    @objc private func favoriteWork(_ sender: NSButton) {
        guard !previewOnly, attached, collectionPopover.isShown, sender.isEnabled, !collectionSaving,
              let selected = BangumiCollectionStatus(rawValue: sender.tag),
              !workIsFavorite || selected != work?.collectionStatus else { return }
        do {
            let value = try ensureWork()
            try delegate.favoriteLibrary.addWork(workID: value.id)
            collectionOperation?.cancel(); collectionGeneration = UUID()
            let token = collectionGeneration
            collectionIdentity = collectionKey(value)
            showWork()
            collectionSaving = true
            status.stringValue = String(localized: "正在保存收藏…")
            updateCommands()
            closeCollectionPopover()
            collectionOperation = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.sync.setCollectionStatus(workID: value.id, status: selected)
                    guard self.acceptsCollection(token, workID: value.id) else { return }
                    self.work = result.work
                    self.status.stringValue = String(localized: "已收藏至「\(selected.title)」。")
                } catch {
                    guard self.acceptsCollection(token, workID: value.id) else { return }
                    if let saved = try? self.delegate.workLibrary.fetchWork(id: value.id) {
                        self.work = saved
                        if saved.collectionStatus == selected {
                            self.status.stringValue = String(localized: "收藏與分類已保存本機；Bangumi 尚未同步：\(error.localizedDescription)")
                        } else {
                            self.status.stringValue = String(localized: "收藏已保存本機，但分類保存失敗：\(error.localizedDescription)")
                        }
                    } else {
                        self.status.stringValue = String(localized: "收藏已加入；無法確認分類是否保存：\(error.localizedDescription)")
                    }
                }
                guard self.acceptsCollection(token, workID: value.id) else { return }
                self.collectionSaving = false
                self.showWork()
            }
        } catch {
            status.stringValue = String(localized: "無法保存本機收藏：\(error.localizedDescription)")
        }
    }
    @objc private func favoriteLink() {
        guard let choice = selection else { return }
        do {
            _ = try delegate.favoriteLibrary.addLink(url: (choice.episode ?? choice.item).pageURL, title: media?.title)
            status.stringValue = String(localized: "已收藏原始連結。")
        } catch { showError(error) }
    }
    @objc private func associateBangumi() {
        guard classification.kind == .anime else { return }
        guard let subject = Int(bangumiID.stringValue), subject > 0 else { status.stringValue = String(localized: "請輸入正整數 Bangumi subject ID。"); return }
        do {
            let value = try ensureWork()
            metadataOperation?.cancel(); metadataGeneration = UUID()
            let token = generation
            runCommand { [self] in
                let result = try await sync.associate(workID: value.id, subjectID: subject)
                guard accepts(token) else { return }
                work = result.work; selection?.classification = result.work.classification
                extras = nil; extrasSubjectID = nil
                media?.selection = selection
                showWork()
                if let origin = result.origin { showMetadataOrigin(origin, failure: result.failure) }
            }
        } catch { showError(error) }
    }
    @objc private func unlinkBangumi() {
        guard let work else { return }
        metadataOperation?.cancel(); metadataGeneration = UUID()
        do {
            _ = try ensureWork()
            self.work = try delegate.workLibrary.setBangumiAssociation(workID: work.id, subjectID: nil)
            invalidateExtraInformation(); extras = nil; extrasSubjectID = nil; comments = []; nextCommentsPage = nil
            renderExtraInformation(); renderComments()
            showWork(); status.stringValue = String(localized: "已解除 Bangumi 關聯；本機作品、来源及下載保留。")
        } catch { showError(error) }
    }
    @objc private func addSource() {
        do {
            let item = try services.decoder.registry.item(for: sourceAddress.stringValue)
            let value = try ensureWork()
            _ = try delegate.favoriteLibrary.addSource(workID: value.id,
                source: SourceItemRef(sourceID: item.sourceID, pageURL: item.pageURL, kind: .work))
            sourceAddress.stringValue = ""; showWork()
            status.stringValue = String(localized: "已新增手動來源關聯。")
        } catch { showError(error) }
    }
    @objc private func removeSource() {
        let index = sources.indexOfSelectedItem - 1
        guard links.indices.contains(index), let work else { return }
        let link = links[index]
        do {
            try delegate.workLibrary.removeSourceLink(id: link.id, workID: work.id)
            operation?.cancel(); invalidatePlayback(); generation = UUID(); selection = nil; media = nil; leaves = []; leafTitles = []
            loading = false; rebuildCatalogButtons(); showWork()
            status.stringValue = String(localized: "已移除來源關聯；收藏、集數與下載保留。")
        } catch { showError(error) }
    }
    @objc private func sourceChanged() {
        guard !updating, !hasPinnedAnimeEpisode else { return }
        let index = sources.indexOfSelectedItem - 1
        guard links.indices.contains(index) else { return }

        let link = links[index]
        if classification.kind == .anime, selectedEpisodeIndex != nil {
            do {
                let episode = try selectedAnimeEpisode()
                if let mapping = link.episodeMappings.first(where: { $0.episodeID == episode.id }) {
                    loadSelection(mapping.selection)
                    return
                }
            } catch { showError(error); return }
        }
        loadAddress(link.sourceWork.pageURL)
    }
    @objc private func qualityChanged() {
        guard !updating, var choice = selection, qualityKeys.indices.contains(qualities.indexOfSelectedItem) else { return }
        choice.qualityID = qualityKeys[qualities.indexOfSelectedItem]; choice.lineID = nil
        loadSelection(choice, loadCatalog: false)
    }
    @objc private func lineChanged() {
        guard !updating, var choice = selection else { return }
        choice.lineID = String(lines.indexOfSelectedItem)
        loadSelection(choice, loadCatalog: false)
    }
    @objc private func cancelLoading() {
        operation?.cancel(); invalidatePlayback(); generation = UUID(); loading = false; media = nil
        status.stringValue = String(localized: "已取消待完成來源操作；已提交的播放或下載不會撤回。"); updateCommands()
    }
    private func playSelectedMedia() {
        guard exactPlayButton.isEnabled, let choice = selection, media != nil, let key = choice.qualityID else { return }
        let token = generation
        runCommand(playback: true) { [self] in
            try Task.checkCancellation()
            if usesJSPlayer(choice) {
                guard accepts(token) else { return }
                playbackSubmitted = true
                try services.openJSPlayer(selection: choice, title: work?.title, coverURL: work?.coverURL ?? sourceCoverURL, episodeTitle: media?.title)
            } else {
                let prepared = try await services.decoder.resolve(choice)
                try Task.checkCancellation()
                if prepared.site == .huya, prepared.id != -1 {
                    let quality = prepared.streams[key]?.quality ?? 9999999
                    await HuyaProxyServer.shared.startPrewarm(uuid: prepared.uuid, roomId: "\(prepared.id)",
                        rate: quality < 1_000_000 ? quality : nil)
                    try Task.checkCancellation()
                }
                try await services.player.prepareDanmakuFile(yougetJSON: prepared, id: prepared.uuid)
                try Task.checkCancellation()
                guard accepts(token) else { return }
                playbackSubmitted = true
                try await services.player.openWithPlayer(prepared, key, title: work?.title, coverURL: work?.coverURL ?? sourceCoverURL, episodeTitle: prepared.title)
            }
            if attached && generation == token { status.stringValue = String(localized: "已將所選集數、品質、線路與帳號交給播放器。") }
        }
    }
    @objc private func showQuickDownload() {
        guard !previewOnly, attached, quickDownloadButton.isEnabled, let parent = view.window else { return }
        if let panel = quickDownloadPanel { panel.makeKeyAndOrderFront(nil); return }
        do {
            if work != nil, classification.kind == .anime { _ = try ensureWork() }
            let title = work?.title ?? sourceTitle ?? media?.title ?? heading.stringValue
            let controller = WorkspaceQuickDownloadController(delegate: delegate, appearance: appearance, work: work, links: links, selection: selection, title: title, sourceCoverURL: sourceCoverURL, episodes: localEpisodes)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = String(localized: "\(title) · 快速下載")
            panel.minSize = NSSize(width: 520, height: 400)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            addChild(controller)
            panel.contentViewController = controller
            panel.setContentSize(NSSize(width: 760, height: 680))
            quickDownloadController = controller
            quickDownloadPanel = panel
            parent.addChildWindow(panel, ordered: .above)
            panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2, y: parent.frame.midY - panel.frame.height / 2))
            panel.makeKeyAndOrderFront(nil)
        } catch { showError(error) }
    }
    private func closeQuickDownload() {
        quickDownloadController?.detach()
        if let panel = quickDownloadPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentViewController = nil
        }
        quickDownloadController?.removeFromParent()
        quickDownloadController = nil
        quickDownloadPanel = nil
    }
    @objc private func download() {
        guard downloadButton.isEnabled, let choice = selection else { return }
        let title = work?.title ?? media?.title ?? String(localized: "影片")
        let episodeTitle = leaves.firstIndex(where: { $0.selectionURL == choice.episode?.pageURL }).map { leafTitles[$0] }
        let workID = work?.id
        let token = generation
        runCommand { [self] in
            try Task.checkCancellation()
            guard accepts(token) else { throw CancellationError() }
            _ = try await services.downloads().create(selection: choice, title: title, episodeTitle: episodeTitle, workID: workID, coverURL: work?.coverURL ?? sourceCoverURL, bangumiID: work?.bangumiID, episodeKey: selectedEpisodeKey ?? WorkspaceCompletedDownloads.key(for: choice, links: links, episodes: localEpisodes))
            try Task.checkCancellation()
            if attached && generation == token { status.stringValue = String(localized: "已建立下載；使用與播放完全相同的來源選擇。") }
        }
    }
    private var bangumiEpisodes: [BangumiEpisode] { classification.kind == .anime ? work?.bangumiMetadata?.episodes ?? [] : [] }
    private var localOnlyEpisodes: [Episode] {
        guard classification.kind == .anime else { return [] }
        let externalIDs = Set(bangumiEpisodes.map { "bangumi:\($0.id)" })
        return localEpisodes.filter { $0.externalID.map { !externalIDs.contains($0) } ?? true }
    }
    private var selectedEpisodeIndex: Int? {
        guard let key = selectedEpisodeKey else { return nil }
        return WorkspaceDetailEpisodeAvailability.index(for: key, bangumi: bangumiEpisodes, local: localOnlyEpisodes)
    }
    private func rebuildEpisodeButtons() {
        episodeGroups.arrangedSubviews.forEach { episodeGroups.removeArrangedSubview($0); $0.removeFromSuperview() }
        var groups: [(String, [(String, String, String?)])] = []
        var updatingKinds = Set<String>()
        func add(_ kind: String, _ key: String, _ title: String, _ detail: String? = nil) {
            if let index = groups.firstIndex(where: { $0.0 == kind }) { groups[index].1.append((key, title, detail)) }
            else { groups.append((kind, [(key, title, detail)])) }
        }
        for episode in bangumiEpisodes {
            let kinds = [String(localized: "正篇"), String(localized: "SP"), String(localized: "OP"), String(localized: "ED"), String(localized: "預告"), String(localized: "MAD"), String(localized: "其他")]
            let kind = kinds.indices.contains(episode.type) ? kinds[episode.type] : String(localized: "類型未知")
            guard WorkspaceDetailEpisodeAvailability.isUpdatedTitle(episode.title) else {
                updatingKinds.insert(kind)
                if !groups.contains(where: { $0.0 == kind }) { groups.append((kind, [])) }
                continue
            }
            let title = "\(episode.sort) · \(episode.title)"
            let detail = [title, episode.airdate, episode.duration, episode.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            add(kind, "bangumi:\(episode.id)", title, detail)
        }
        for episode in localOnlyEpisodes {
            let kind: String
            switch episode.kind { case .main: kind = String(localized: "正篇"); case .special: kind = String(localized: "SP"); case .opening: kind = String(localized: "OP"); case .ending: kind = String(localized: "ED"); case .other: kind = String(localized: "其他") }
            guard WorkspaceDetailEpisodeAvailability.isUpdatedTitle(episode.label) else {
                updatingKinds.insert(kind)
                if !groups.contains(where: { $0.0 == kind }) { groups.append((kind, [])) }
                continue
            }
            add(kind, episode.id.uuidString, "\(episode.sort) · \(episode.label)")
        }
        if selectedEpisodeKey != nil, selectedEpisodeIndex == nil {
            clearEpisodePlaybackSelection()
            rebuildCatalogButtons(); renderCandidates()
            status.stringValue = String(localized: "原選集數尚未更新或已移除；請重新選擇已更新集數。")
        }
        for (kind, entries) in groups {
            episodeGroups.addArrangedSubview(label(kind))
            let grid = WorkspaceDetailButtonGrid()
            var buttons = entries.map { key, title, detail in
                let value = selectionButton(episodeDownloaded(key) ? String(localized: "✓ 已下載 · \(title)") : title, identity: key, action: #selector(episodeClicked(_:)), selected: selectedEpisodeKey == key)
                if let detail {
                    value.toolTip = detail
                    value.setAccessibilityHelp(detail)
                }
                return value
            }
            if updatingKinds.contains(kind) {
                let placeholder = NSButton(title: String(localized: "更新中"), target: nil, action: nil)
                placeholder.bezelStyle = .rounded
                placeholder.isEnabled = false
                placeholder.setAccessibilityLabel(String(localized: "更新中"))
                placeholder.setAccessibilityHelp(String(localized: "未提供集名的集數尚未更新，不能選擇或播放。"))
                buttons.append(placeholder)
            }
            grid.replace(buttons)
            episodeGroups.addArrangedSubview(grid)
            grid.widthAnchor.constraint(equalTo: episodeGroups.widthAnchor).isActive = true
        }
    }
    private func rebuildCatalogButtons() {
        let playingPart = selection.flatMap { isDirectBilibiliVideo($0) ? BilibiliUrl(url: ($0.episode ?? $0.item).pageURL) : nil }
        catalogGrid.replace(leaves.enumerated().map { index, leaf in
            let selected: Bool
            if let playingPart, let part = BilibiliUrl(url: leaf.selectionURL) {
                selected = playingPart.id == part.id && playingPart.p == part.p
            } else {
                selected = selection?.episode?.pageURL == leaf.selectionURL
            }
            return selectionButton(completedRecords.contains { ($0.selection.episode ?? $0.selection.item).pageURL == leaf.selectionURL && ($0.selection.episode ?? $0.selection.item).sourceID == selection?.item.sourceID } ? String(localized: "✓ 已下載 · \(leafTitles[index])") : leafTitles[index], identity: leaf.selectionURL, action: #selector(catalogClicked(_:)), selected: selected)
        })
    }
    private func clearEpisodePlaybackSelection() {
        resetPlaybackSource()
        selectedEpisodeKey = nil
        operation?.cancel(); invalidatePlayback(); generation = UUID()
        loading = false; selection = nil; media = nil; animeReport = nil
        autoOpenAfterSelection = false
        leaves = []; leafTitles = []; qualityKeys = []; qualities.removeAllItems(); lines.removeAllItems()
        sources.selectItem(at: 0)
        sourceManagement.isHidden = true; sourceManagementButton.title = String(localized: "來源診斷與管理 ▸")
        sourceManagementButton.setAccessibilityValue(String(localized: "已收合"))
    }
    @objc private func episodeClicked(_ sender: NSButton) {
        guard !previewOnly, sender.isEnabled, let key = sender.identifier?.rawValue,
              WorkspaceDetailEpisodeAvailability.index(for: key, bangumi: bangumiEpisodes, local: localOnlyEpisodes) != nil else { return }
        if key != selectedEpisodeKey {
            clearEpisodePlaybackSelection()
            selectedEpisodeKey = key
            status.stringValue = String(localized: "已選作品集數；開啟來源窗口自動尋源並播放，不按目錄下標猜測。")
            rebuildEpisodeButtons(); rebuildCatalogButtons(); renderCandidates(); updateCommands()
        } else { sender.state = .on }
        showSourcePanel()
    }
    @objc private func catalogClicked(_ sender: NSButton) {
        guard !previewOnly, !hasPinnedAnimeEpisode, let url = sender.identifier?.rawValue, leaves.contains(where: { $0.selectionURL == url }), let base = selection else { return }
        do {
            var choice = base
            choice.episode = try services.decoder.registry.item(for: url)
            choice.qualityID = nil; choice.lineID = nil
            let autoOpen = autoOpenAfterSelection && !(NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
            loadSelection(choice, loadCatalog: false, autoOpen: autoOpen)
            rebuildCatalogButtons()
        } catch { showError(error) }
    }
    private var currentLink: WorkSourceLink? {
        let index = sources.indexOfSelectedItem - 1
        return links.indices.contains(index) ? links[index] : nil
    }
    private func localEpisode(at row: Int) -> Episode? {
        if bangumiEpisodes.indices.contains(row) {
            return localEpisodes.first { $0.externalID == "bangumi:\(bangumiEpisodes[row].id)" }
        }
        let local = localOnlyEpisodes
        let index = row - bangumiEpisodes.count
        return local.indices.contains(index) ? local[index] : nil
    }
    @objc private func mapEpisode() {
        guard classification.kind == .anime, let work, let choice = selection, choice.classification.kind == .anime, var link = currentLink, (selectedEpisodeIndex ?? -1) >= 0 else { return }
        let row = (selectedEpisodeIndex ?? -1)
        do {
            let episode: Episode
            if let existing = localEpisode(at: row) { episode = existing }
            else if bangumiEpisodes.indices.contains(row) {
                let remote = bangumiEpisodes[row]
                let kind: Episode.Kind = remote.type == 0 ? .main : remote.type == 1 ? .special : remote.type == 2 ? .opening : remote.type == 3 ? .ending : .other
                episode = Episode(workID: work.id, externalID: "bangumi:\(remote.id)", kind: kind, label: remote.title, sort: remote.sort)
                try delegate.workLibrary.upsert(episode)
            } else { return }
            link.episodeMappings.removeAll { $0.episodeID == episode.id }
            link.episodeMappings.append(EpisodeSourceMapping(episodeID: episode.id, selection: choice))
            try delegate.workLibrary.upsert(link)
            showWork(); status.stringValue = String(localized: "已保存明確集數映射；來源選擇與帳號保持不變。")
        } catch { showError(error) }
    }
    private func loadUpdate(_ update: DiscoveryFavoriteUpdate) {
        let token = beginLoading()
        let candidates = links.filter { $0.sourceWork.sourceID == update.sourceID }
        operation = Task { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for link in candidates {
                do {
                    let base = try self.classifiedSelection(await self.services.decoder.guestSelection(for: link.sourceWork.pageURL))
                    let catalog = try await self.services.decoder.catalog(for: base)
                    guard self.accepts(token) else { return }
                    self.leaves = []; self.leafTitles = []
                    if let catalog { self.appendCatalog(catalog.nodes, prefix: "") }
                    if let leaf = try self.leaves.first(where: { try update.newIdentities.contains(self.services.decoder.episodeIdentity($0)) }) {
                        var exact = base
                        exact.episode = try self.services.decoder.registry.item(for: leaf.selectionURL)
                        self.updating = true
                        if let index = self.links.firstIndex(where: { $0.id == link.id }) { self.sources.selectItem(at: index + 1) }
                        self.rebuildCatalogButtons()
                        self.updating = false
                        try await self.inspect(exact, token: token, loadCatalog: false)
                        return
                    }
                } catch {
                    guard self.accepts(token) else { return }
                    failures.append(error.localizedDescription)
                }
            }
            guard self.accepts(token) else { return }
            self.loading = false; self.selection = nil; self.media = nil
            self.status.stringValue = failures.isEmpty ? String(localized: "更新中的精確集數已不在來源清單；請明確選擇，不自動改播其他集數。") : failures.joined(separator: "\n")
            self.updateCommands()
        }
    }
}
