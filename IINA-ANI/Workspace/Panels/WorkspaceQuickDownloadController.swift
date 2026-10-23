import AppKit

@MainActor
private final class WorkspaceQuickDownloadDocument: NSStackView {
    override var isFlipped: Bool { true }
}

/// Keep complete action labels available when a narrow window or localization needs more space.
@MainActor
private final class WorkspaceQuickDownloadActions: NSStackView {
    init(buttons: [NSButton]) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        for button in buttons {
            addArrangedSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let requiredWidth = arrangedSubviews.reduce(CGFloat.zero) {
            $0 + max(0, $1.intrinsicContentSize.width)
        } + spacing * CGFloat(max(0, arrangedSubviews.count - 1))
        let desired: NSUserInterfaceLayoutOrientation = requiredWidth > bounds.width ? .vertical : .horizontal
        guard orientation != desired else { return }
        orientation = desired
        alignment = desired == .vertical ? .leading : .centerY
    }
}

/// Owns only catalogue/discovery and admission UI. Admitted transfers belong to DownloadService.
@MainActor
final class WorkspaceQuickDownloadController: NSViewController, WorkspaceDetachablePanel {
    private struct SourceChoice {
        let title: String
        let selection: PlayableSelection
        let evidence: String
    }

    // Quality and line changes must not admit the same exact episode twice in this window.
    private struct AdmissionIdentity: Hashable {
        let item: SourceItemRef
        let accountID: UUID?
        init(_ selection: PlayableSelection) {
            item = selection.episode ?? selection.item
            accountID = selection.accountID
        }
    }

    @MainActor
    private final class Row {
        let selection: PlayableSelection
        let label: String
        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let status = NSTextField(wrappingLabelWithString: String(localized: "尚未勾選；勾選後解析此來源的精確集數。"))
        var displayedAsDownloaded = false
        var ready: PlayableSelection?
        var submittedID: UUID?
        var resolving: Task<Void, Never>?
        var generation = UUID()

        init(selection: PlayableSelection, label: String) {
            self.selection = selection
            self.label = label
        }
    }

    private let delegate: AppDelegate
    private let appearance: SkinAppearance
    private let work: Work?
    private let links: [WorkSourceLink]
    private let initialSelection: PlayableSelection?
    private let downloadTitle: String
    private var sourceCoverURL: String?
    private let episodes: [Episode]
    private let completedObservation = WorkspaceCompletedDownloads()
    private var completedRecords: [DownloadRecord] = []
    private func isDownloaded(_ row: Row) -> Bool {
        let key = WorkspaceCompletedDownloads.key(for: row.selection, links: links, episodes: episodes)
        return completedRecords.contains { record in
            WorkspaceCompletedDownloads.same(record.selection, row.selection) || (key != nil && record.episodeKey == key && work != nil && (record.workID == work?.id || (work?.bangumiID != nil && record.bangumiID == work?.bangumiID)))
        }
    }
    private func observeCompletedDownloads() {
        guard let downloads = try? services.downloads() else { return }
        completedObservation.start(downloads) { [weak self] records in
            guard let self, self.attached else { return }
            self.completedRecords = records
            if self.isViewLoaded { self.renderRows() }
        }
    }
    private var services: AppServices { delegate.services }
    private let tabs = NSSegmentedControl(labels: [String(localized: "在線源下載"), String(localized: "BT下載")], trackingMode: .selectOne, target: nil, action: nil)
    private let host = NSView()
    private let online = NSView()
    private let sources = NSPopUpButton()
    private let sourceStatus = WorkspaceSkinStatusLabel(wrappingLabelWithString: String(localized: "先尋找並明確選擇作品來源，再勾選該來源的集數；不會預選或自動綁定。"))
    private let rowsStack = WorkspaceQuickDownloadDocument()
    private let status = WorkspaceSkinStatusLabel(wrappingLabelWithString: String(localized: "尚未選擇作品來源。"))
    private let selectionSummary = NSTextField(wrappingLabelWithString: "")
    private let selectAllButton = WorkspaceSkinButton()
    private let clearButton = WorkspaceSkinButton()
    private let findButton = WorkspaceSkinButton()
    private let retryCatalogButton = WorkspaceSkinButton()
    private let submitButton = WorkspaceSkinButton()
    private let cancelButton = WorkspaceSkinButton()
    private var choices: [SourceChoice] = []
    private var selectedSource: SourceChoice?
    private var rows: [Row] = []
    private var submitted: [AdmissionIdentity: UUID] = [:]
    private var torrent: WorkspaceTorrentController?
    private var searchedTorrent = false
    private var attached = true
    private var catalogTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var submissionTask: Task<Void, Never>?
    private var stopSubmission = false
    private var generation = UUID()

    init(delegate: AppDelegate, appearance: SkinAppearance, work: Work?,
         links: [WorkSourceLink], selection: PlayableSelection?, title: String, sourceCoverURL: String? = nil, episodes: [Episode] = []) {
        self.delegate = delegate
        self.appearance = appearance
        self.work = work
        self.links = links
        self.initialSelection = selection
        self.downloadTitle = title
        self.sourceCoverURL = sourceCoverURL
        self.episodes = episodes
        super.init(nibName: nil, bundle: nil)
        self.title = String(localized: "快速下載 · \(title)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = WorkspaceSkinHostView()
        root.skinAppearance = appearance
        root.bindSkin(appearance, slot: "panel", componentID: "detail.media")
        view = root
        let header = WorkspaceGlassSurface(appearance: appearance)
        let eyebrow = NSTextField(labelWithString: String(localized: "快速下載"))
        eyebrow.bindSkin(appearance, slot: "sectionLabel", componentID: "detail.media")
        let heading = NSTextField(wrappingLabelWithString: downloadTitle)
        heading.bindSkin(appearance, slot: "header", componentID: "detail.media")
        heading.maximumNumberOfLines = 2
        heading.toolTip = downloadTitle
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.segmentStyle = .rounded
        tabs.controlSize = .large
        tabs.setAccessibilityLabel(String(localized: "快速下載方式"))
        let headerContent = NSStackView(views: [eyebrow, heading, tabs])
        headerContent.orientation = .vertical
        headerContent.alignment = .leading
        headerContent.spacing = 8
        headerContent.setCustomSpacing(12, after: heading)
        headerContent.translatesAutoresizingMaskIntoConstraints = false
        header.contentView.addSubview(headerContent)
        for item in [header, host] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headerContent.leadingAnchor.constraint(equalTo: header.contentView.leadingAnchor, constant: 18),
            headerContent.trailingAnchor.constraint(equalTo: header.contentView.trailingAnchor, constant: -18),
            headerContent.topAnchor.constraint(equalTo: header.contentView.topAnchor, constant: 12),
            headerContent.bottomAnchor.constraint(equalTo: header.contentView.bottomAnchor, constant: -12),
            heading.widthAnchor.constraint(equalTo: headerContent.widthAnchor),
            tabs.widthAnchor.constraint(equalTo: headerContent.widthAnchor),
            host.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        buildOnlinePage()
        embed(online)
        loadKnownSources()
        observeCompletedDownloads()
    }

    private func buildOnlinePage() {
        let document = WorkspaceQuickDownloadDocument()
        document.orientation = .vertical
        document.alignment = .leading
        document.spacing = 14
        document.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 18, right: 18)
        let scroll = WorkspaceScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        online.addSubview(scroll)
        let footer = WorkspaceGlassSurface(appearance: appearance, cornerRadius: 16)
        footer.translatesAutoresizingMaskIntoConstraints = false
        online.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: online.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: online.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: online.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: online.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: online.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: online.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        configure(selectAllButton, title: String(localized: "全選"), action: #selector(selectAllEpisodes), icon: .check)
        configure(clearButton, title: String(localized: "清除勾選"), action: #selector(clearChecks), icon: .close)
        configure(findButton, title: String(localized: "尋找作品來源"), action: #selector(findSources), icon: .search)
        configure(retryCatalogButton, title: String(localized: "重新讀取所選來源集數"), action: #selector(retryCatalog), icon: .refresh)
        configure(submitButton, title: String(localized: "下載勾選且就緒的集數"), action: #selector(submit), icon: .downloads, slot: "primaryAction")
        configure(cancelButton, title: String(localized: "取消未提交操作"), action: #selector(cancelPending), icon: .close)
        sources.target = self
        sources.action = #selector(sourceChanged)
        sources.setAccessibilityLabel(String(localized: "作品下載來源，不預選"))
        sources.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let selectionActions = WorkspaceQuickDownloadActions(buttons: [selectAllButton, clearButton])
        let downloadActions = WorkspaceQuickDownloadActions(buttons: [submitButton, cancelButton])
        let sourceActions = WorkspaceQuickDownloadActions(buttons: [findButton, retryCatalogButton])
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        let sourceSection = section(
            title: String(localized: "作品來源"), items: [sources, sourceStatus, sourceActions])
        let episodeSection = section(
            title: String(localized: "選擇下載集數"), items: [status, selectionActions, rowsStack])
        for item in [sourceSection, episodeSection] {
            document.addArrangedSubview(item)
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -36).isActive = true
        }
        sourceStatus.bindSkin(appearance, slot: "status", componentID: "detail.media")
        status.bindSkin(appearance, slot: "status", componentID: "detail.media")
        selectionSummary.bindSkin(appearance, slot: "subtitle", componentID: "detail.media")
        let footerContent = NSStackView(views: [selectionSummary, downloadActions])
        footerContent.orientation = .vertical
        footerContent.alignment = .leading
        footerContent.spacing = 9
        footerContent.translatesAutoresizingMaskIntoConstraints = false
        footer.contentView.addSubview(footerContent)
        NSLayoutConstraint.activate([
            footerContent.leadingAnchor.constraint(equalTo: footer.contentView.leadingAnchor, constant: 16),
            footerContent.trailingAnchor.constraint(equalTo: footer.contentView.trailingAnchor, constant: -16),
            footerContent.topAnchor.constraint(equalTo: footer.contentView.topAnchor, constant: 12),
            footerContent.bottomAnchor.constraint(equalTo: footer.contentView.bottomAnchor, constant: -12),
            selectionSummary.widthAnchor.constraint(equalTo: footerContent.widthAnchor),
            downloadActions.widthAnchor.constraint(equalTo: footerContent.widthAnchor),
        ])
    }

    private func section(title: String, items: [NSView]) -> NSView {
        let card = NSView()
        card.bindSkin(appearance, slot: "workCard", componentID: "detail.media")
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.bindSkin(appearance, slot: "text", componentID: "detail.media")
        let content = NSStackView(views: [heading] + items)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        for item in items {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        return card
    }

    private func configure(_ button: WorkspaceSkinButton, title: String, action: Selector, icon: WorkspaceIcon, slot: String = "button") {
        button.title = title
        button.setFunctionIcon(icon)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.bindSkin(appearance, slot: slot, componentID: "detail.media")
    }

    private func embed(_ page: NSView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    @objc private func tabChanged() {
        guard attached else { return }
        if tabs.selectedSegment == 0 {
            torrent?.detach()
            embed(online)
            return
        }
        if torrent == nil {
            let controller = WorkspaceTorrentController(delegate: delegate, appearance: appearance, previewOnly: false, work: work, sourceCoverURL: sourceCoverURL)
            controller.hidePlaybackControls()
            addChild(controller)
            torrent = controller
        }
        guard let torrent else { return }
        torrent.attach()
        embed(torrent.view)
        if !searchedTorrent {
            searchedTorrent = true
            torrent.search(keyword: downloadTitle)
        }
    }

    private func sourceChoice(_ selection: PlayableSelection, title: String, evidence: String) -> SourceChoice {
        var exact = selection
        if exact.classification.kind == .anime { exact.accountID = nil }
        let name = services.decoder.registry.descriptor(for: exact.item.sourceID)?.name ?? exact.item.sourceID
        return SourceChoice(title: name + " · " + title, selection: exact, evidence: evidence)
    }

    private func loadKnownSources() {
        var known: [SourceChoice] = []
        if let initialSelection, initialSelection.torrent == nil,
           [.work, .episode, .video].contains(initialSelection.item.kind) {
            known.append(sourceChoice(initialSelection, title: downloadTitle + String(localized: "（目前來源）"), evidence: String(localized: "保留目前來源身份；仍需明確選取。")))
        }
        if let work {
            for link in links where link.workID == work.id {
                let selection = PlayableSelection(item: link.sourceWork, classification: work.classification)
                if !known.contains(where: { $0.selection.item == selection.item }) {
                    known.append(sourceChoice(selection, title: work.title + String(localized: "（已關聯）"), evidence: String(localized: "已保存的作品來源；目錄以原站目前結果為準。")))
                }
            }
        }
        choices = known
        resetSources()
        updateControls()
    }

    private func resetSources() {
        sources.removeAllItems()
        sources.addItem(withTitle: String(localized: "請明確選擇作品來源…"))
        for choice in choices {
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            item.toolTip = choice.evidence
            sources.menu?.addItem(item)
        }
        sources.selectItem(at: 0)
    }

    @objc private func findSources() {
        guard attached, discoveryTask == nil, submissionTask == nil, let work,
              work.classification.kind == .anime else { return }
        clearPendingCatalog()
        resetSources()
        let token = generation
        sourceStatus.stringValue = String(localized: "正在尋找作品來源；不會先選集數或自動選取來源。")
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token { self.discoveryTask = nil; self.updateControls() }
            }
            let allDescriptors = await self.services.decoder.sourceDescriptors()
            let descriptors = allDescriptors.filter {
                self.services.decoder.isSourceEnabled($0.id) && $0.capabilities.contains(.search) &&
                    $0.capabilities.contains(.resolve) && ($0.capabilities.contains(.iina) || $0.capabilities.contains(.mpv))
            }.sorted { $0.id < $1.id }
            let subject = work.bangumiMetadata?.subject
            var aliases: [String] = []
            for title in [work.title, subject?.nameCN ?? "", subject?.name ?? ""] + work.aliases + (subject?.aliases ?? []) {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !aliases.contains(trimmed) { aliases.append(trimmed) }
                if aliases.count == 4 { break }
            }
            var found = self.choices
            var seen = Set(found.map { $0.selection.item })
            var failures: [String] = []
            for source in descriptors {
                var count = 0
                for alias in aliases {
                    if Task.isCancelled || !self.attached || self.generation != token { return }
                    do {
                        let page = try await self.services.decoder.searchSource(sourceID: source.id, query: alias, page: 1, classifyWithBangumi: true)
                        try Task.checkCancellation()
                        guard self.attached, self.generation == token else { return }
                        for result in page.results where result.item.sourceID == source.id && [.work, .episode].contains(result.item.kind) {
                            guard count < 8, seen.insert(result.item).inserted else { continue }
                            // Search titles are candidates, not proof of a work or episode match.
                            let selection = PlayableSelection(item: result.item, classification: work.classification)
                            found.append(self.sourceChoice(selection, title: result.title + String(localized: "（請核對作品）"), evidence: String(localized: "作品名稱搜尋候選；請核對作品、季度及原站集數，不會自動綁定。")))
                            count += 1
                        }
                    } catch {
                        if Task.isCancelled || error is CancellationError { return }
                        failures.append(source.name)
                    }
                }
            }
            guard self.attached, self.generation == token else { return }
            self.choices = found
            self.resetSources()
            self.sourceStatus.stringValue = found.isEmpty ? String(localized: "沒有找到作品來源；可重新尋找或切換 BT下載。") : String(localized: "找到 \(found.count) 個作品來源；請核對作品並明確選擇，再勾選集數。")
            if !failures.isEmpty {
                self.sourceStatus.stringValue += String(localized: "\n部分搜尋失敗：") + Array(Set(failures)).sorted().joined(separator: "、") + String(localized: "；已找到的來源仍可選取。")
            }
        }
        updateControls()
    }

    /// Invalidates only UI-owned operations. Never cancel an in-flight persistent admission.
    private func clearPendingCatalog() {
        generation = UUID()
        stopSubmission = true
        catalogTask?.cancel()
        catalogTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        for row in rows {
            row.generation = UUID()
            row.resolving?.cancel()
            row.resolving = nil
            row.ready = nil
            row.check.state = .off
        }
        rows = []
        selectedSource = nil
        renderRows()
    }

    @objc private func sourceChanged() {
        guard attached, discoveryTask == nil else { return }
        let index = sources.indexOfSelectedItem - 1
        clearPendingCatalog()
        guard choices.indices.contains(index) else {
            sourceStatus.stringValue = String(localized: "先尋找並明確選擇作品來源，再勾選該來源的集數；不會預選或自動綁定。")
            status.stringValue = String(localized: "尚未選擇作品來源。")
            updateControls()
            return
        }
        selectedSource = choices[index]
        loadCatalog()
    }

    @objc private func retryCatalog() {
        guard attached, submissionTask == nil, let choice = selectedSource else { return }
        clearPendingCatalog()
        selectedSource = choice
        loadCatalog()
    }

    private func loadCatalog() {
        guard attached, let choice = selectedSource else { return }
        let token = generation
        status.stringValue = String(localized: "正在讀取所選作品來源的精確集數／分 P 目錄；不會預選。")
        catalogTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token { self.catalogTask = nil; self.updateControls() }
            }
            do {
                var selection = choice.selection
                if selection.classification.kind == .anime {
                    selection.accountID = nil
                    let normalized = try await self.services.decoder.guestSelection(for: selection.item.pageURL)
                    try Task.checkCancellation()
                    guard normalized.item.sourceID == selection.item.sourceID, normalized.torrent == nil else {
                        throw DownloadFailure.invalidSelection
                    }
                    selection.item = normalized.item
                }
                let catalog = try await self.services.decoder.catalog(for: selection)
                if self.work?.coverURL == nil, self.sourceCoverURL == nil,
                   let info = try? await self.services.decoder.liveInfo(selection.item.pageURL), !info.cover.isEmpty {
                    self.sourceCoverURL = info.cover
                }
                try Task.checkCancellation()
                guard self.attached, self.generation == token else { return }
                var loaded: [Row] = []
                var seen: Set<AdmissionIdentity> = []
                var rejected = 0
                if let catalog {
                    var base = catalog.selection
                    guard base.item.sourceID == selection.item.sourceID, base.torrent == nil else { throw DownloadFailure.invalidSelection }
                    base.accountID = selection.accountID
                    base.qualityID = selection.qualityID
                    base.lineID = selection.lineID
                    if selection.classification.kind != .unknown { base.classification = selection.classification }
                    for (leaf, label) in Self.leaves(catalog.nodes) {
                        do {
                            let ref = try self.services.decoder.registry.item(for: leaf.selectionURL)
                            guard ref.sourceID == base.item.sourceID, [.episode, .video].contains(ref.kind) else { throw DownloadFailure.invalidSelection }
                            var exact = base
                            exact.episode = ref
                            let identity = AdmissionIdentity(exact)
                            guard seen.insert(identity).inserted else { continue }
                            let row = Row(selection: exact, label: label)
                            row.submittedID = self.submitted[identity]
                            loaded.append(row)
                        } catch { rejected += 1 }
                    }
                    // An empty/broken supplied catalogue must not silently become the current episode.
                    guard !loaded.isEmpty else { throw DownloadFailure.invalidSelection }
                } else {
                    let ref = selection.episode ?? selection.item
                    guard [.episode, .video].contains(ref.kind), selection.torrent == nil else { throw DownloadFailure.invalidSelection }
                    let row = Row(selection: selection, label: self.downloadTitle)
                    row.submittedID = self.submitted[AdmissionIdentity(selection)]
                    loaded = [row]
                }
                self.rows = loaded
                self.sourceStatus.stringValue = String(localized: "所選作品來源：\(choice.title)\n\(choice.evidence)")
                self.status.stringValue = String(localized: "請勾選此來源的精確集數；勾選後解析品質／線路，其他來源不會混入。")
                if rejected > 0 { self.status.stringValue += String(localized: "\n\(rejected) 個目錄項目缺少有效同來源身份，未列入下載。") }
                self.renderRows()
            } catch {
                guard self.attached, self.generation == token else { return }
                self.status.stringValue = String(localized: "所選來源目錄載入失敗：\(Self.message(error)) 可重新讀取或換來源。")
            }
        }
        updateControls()
    }

    private static func leaves(_ nodes: [VideoTreeNode], prefix: String = "") -> [(VideoTreeNode, String)] {
        nodes.flatMap { node in
            let label = prefix.isEmpty ? node.displayTitle : prefix + " · " + node.displayTitle
            return node.isLeaf ? [(node, label)] : leaves(node.children, prefix: label)
        }
    }

    private func renderRows() {
        rowsStack.arrangedSubviews.forEach { rowsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            row.check.title = (isDownloaded(row) ? String(localized: "✓ 已下載 · ") : "") + row.label
            row.check.font = .systemFont(ofSize: 13, weight: .medium)
            row.check.lineBreakMode = .byTruncatingTail
            row.check.toolTip = row.label
            row.check.tag = index
            row.check.target = self
            row.check.action = #selector(checkChanged(_:))
            row.check.setAccessibilityLabel(String(localized: "下載集數 \(row.label)"))
            row.status.bindSkin(appearance, slot: "status", componentID: "detail.media")
            if isDownloaded(row) { row.status.stringValue = String(localized: "已下載；完成檔存在。") }
            else if row.submittedID != nil { row.status.stringValue = String(localized: "已提交下載；不會重複提交，進度請至下載頁查看。") }
            else if row.displayedAsDownloaded { row.status.stringValue = String(localized: "完成檔已移除；可重新下載。") }
            row.displayedAsDownloaded = isDownloaded(row)
            for item in [row.check, row.status] {
                stack.addArrangedSubview(item)
                item.translatesAutoresizingMaskIntoConstraints = false
                item.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            rowsStack.addArrangedSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        updateControls()
    }

    @objc private func checkChanged(_ sender: NSButton) {
        guard attached, submissionTask == nil, rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]
        if sender.state == .on { resolve(row) }
        else { cancelResolution(row) }
        updateControls()
    }

    @objc private func selectAllEpisodes() {
        guard attached, submissionTask == nil, catalogTask == nil else { return }
        for row in rows where row.submittedID == nil && !isDownloaded(row) {
            row.check.state = .on
            resolve(row)
        }
        updateControls()
    }

    @objc private func clearChecks() {
        guard attached, submissionTask == nil else { return }
        for row in rows where row.submittedID == nil {
            row.check.state = .off
            cancelResolution(row)
        }
        updateControls()
    }

    private func cancelResolution(_ row: Row) {
        row.generation = UUID()
        row.resolving?.cancel()
        row.resolving = nil
        row.ready = nil
        row.status.stringValue = String(localized: "尚未勾選；勾選後解析此來源的精確集數。")
    }

    private func resolve(_ row: Row) {
        guard !isDownloaded(row), row.submittedID == nil, row.ready == nil, row.resolving == nil else { return }
        let token = row.generation
        let catalogToken = generation
        row.status.stringValue = String(localized: "解析所選作品來源的精確集數／品質／線路…")
        row.resolving = Task { [weak self] in
            guard let self else { return }
            defer {
                if row.generation == token { row.resolving = nil; self.updateControls() }
            }
            do {
                var exact = row.selection
                if exact.classification.kind == .anime { exact.accountID = nil }
                guard self.services.capabilityEnabled(.downloads) else {
                    throw WorkspaceCapabilityFailure(reasons: [String(localized: "新增下載已停用；請至設定啟用。")])
                }
                let decoded = try await self.services.decoder.resolve(exact)
                try Task.checkCancellation()
                guard decoded.audio.isEmpty else { throw DownloadFailure.unsupportedMedia }
                guard let quality = exact.qualityID ?? decoded.videos.first?.key else { throw DownloadFailure.mediaUnavailable }
                exact.qualityID = quality
                try self.validate(exact)
                _ = try await DownloadSourceResolver(decoder: self.services.decoder).resolve(exact)
                try Task.checkCancellation()
                try self.validate(exact)
                guard self.attached, self.generation == catalogToken, row.generation == token, row.check.state == .on else { return }
                row.ready = exact
                row.status.stringValue = String(localized: "就緒 · 品質：\(exact.qualityID ?? "") · 線路：\(exact.lineID ?? "0")\n保留所選作品來源與集數的精確身份。")
            } catch {
                guard self.attached, self.generation == catalogToken, row.generation == token else { return }
                row.status.stringValue = String(localized: "此集無法下載：\(Self.message(error))；可取消勾選後重選以重試。")
            }
        }
    }

    private func validate(_ selection: PlayableSelection) throws {
        guard services.capabilityEnabled(.downloads) else {
            throw WorkspaceCapabilityFailure(reasons: [String(localized: "新增下載已停用；請至設定啟用。")])
        }
        guard services.decoder.isSourceEnabled(selection.item.sourceID) else { throw SiteAccountError.disabled }
        try DownloadSourceResolver(decoder: services.decoder).validate(selection)
    }

    @objc private func submit() {
        guard attached, submissionTask == nil, discoveryTask == nil, catalogTask == nil else { return }
        let selected = rows.filter { $0.check.state == .on && $0.submittedID == nil && !isDownloaded($0) }
        let ready = selected.compactMap { row in row.ready.map { (row, $0) } }
        guard !ready.isEmpty else { return }
        let token = generation
        stopSubmission = false
        submissionTask = Task { [weak self] in
            guard let self else { return }
            var succeeded = 0, failed = 0
            for (row, selection) in ready {
                // Once create starts it may persist a record. Never cancel it or discard its returned identity.
                if self.stopSubmission || !self.attached || self.generation != token { break }
                let identity = AdmissionIdentity(selection)
                if let id = self.submitted[identity] { row.submittedID = id; row.check.state = .off; continue }
                do {
                    try self.validate(selection)
                    let record = try await self.services.downloads().create(selection: selection,
                        title: self.downloadTitle, episodeTitle: row.label, workID: self.work?.id, coverURL: self.work?.coverURL ?? self.sourceCoverURL, bangumiID: self.work?.bangumiID, episodeKey: WorkspaceCompletedDownloads.key(for: selection, links: self.links, episodes: self.episodes))
                    self.submitted[identity] = record.id
                    row.submittedID = record.id
                    row.check.state = .off
                    row.status.stringValue = String(localized: "已提交下載；後續進度請至下載頁查看。")
                    // A source change may already have rendered this identity in a new catalogue.
                    for current in self.rows where AdmissionIdentity(current.selection) == identity {
                        current.submittedID = record.id
                        current.check.state = .off
                        current.generation = UUID()
                        current.resolving?.cancel()
                        current.resolving = nil
                        current.ready = nil
                        current.status.stringValue = String(localized: "已提交下載；不會重複提交，進度請至下載頁查看。")
                    }
                    succeeded += 1
                } catch {
                    failed += 1
                    if self.generation == token { row.status.stringValue = String(localized: "提交失敗：\(Self.message(error))；可重試，不會重複已提交集數。") }
                }
            }
            self.submissionTask = nil
            if self.attached {
                if self.generation == token {
                    let pending = selected.filter { $0.submittedID == nil }.count
                    self.status.stringValue = String(localized: "已提交 \(succeeded) 集；失敗 \(failed) 集；未提交 \(pending) 集。") +
                        (self.stopSubmission ? String(localized: "已停止後續提交，既有下載繼續。") : String(localized: "未就緒集數保留勾選。"))
                }
                self.updateControls()
            }
        }
        updateControls()
    }

    @objc private func cancelPending() {
        guard attached else { return }
        clearPendingCatalog()
        resetSources()
        sourceStatus.stringValue = String(localized: "已取消未提交操作；請重新明選作品來源。")
        status.stringValue = String(localized: "已建立的下載不會停止或刪除。")
        updateControls()
    }

    private func updateControls() {
        guard isViewLoaded else { return }
        let submitting = submissionTask != nil
        let discovering = discoveryTask != nil
        let loading = catalogTask != nil
        let checked = rows.filter { $0.check.state == .on && $0.submittedID == nil }
        let readyCount = checked.filter { $0.ready != nil }.count
        selectionSummary.stringValue = checked.isEmpty
            ? String(localized: "勾選集數後即可加入下載佇列。")
            : String(localized: "已選 \(checked.count) 集 · \(readyCount) 集就緒")
        sources.isEnabled = attached && !discovering && !choices.isEmpty
        findButton.isEnabled = attached && !submitting && !discovering && work?.classification.kind == .anime
        retryCatalogButton.isEnabled = attached && !submitting && !discovering && !loading && selectedSource != nil
        selectAllButton.isEnabled = attached && !submitting && !discovering && !loading && rows.contains { $0.submittedID == nil }
        clearButton.isEnabled = selectAllButton.isEnabled
        submitButton.isEnabled = attached && !submitting && !discovering && !loading && services.capabilityEnabled(.downloads) && checked.contains { $0.ready != nil }
        cancelButton.isEnabled = attached && (submitting || discovering || loading || selectedSource != nil)
        for row in rows {
            row.check.isEnabled = attached && !submitting && !discovering && !loading && row.submittedID == nil && !isDownloaded(row)
        }
    }

    private static func message(_ error: Error) -> String {
        if let value = error as? DownloadFailure { return value.localizedDescription }
        if let value = error as? WorkspaceCapabilityFailure { return value.localizedDescription }
        if error is CancellationError { return String(localized: "操作已取消。") }
        if error is SiteAccountError { return String(localized: "來源已停用、帳號不可用或需要授權；不會切換其他帳號。") }
        return String(localized: "來源或下載操作失敗；請檢查來源、網路與下載設定。")
    }

    func capabilitiesDidChange() {
        guard isViewLoaded else { return }
        for row in rows where row.submittedID == nil {
            if let selection = row.ready {
                do { try validate(selection) }
                catch {
                    row.ready = nil
                    row.status.stringValue = String(localized: "下載能力已變更：\(Self.message(error))；請取消勾選後重新勾選。")
                }
            }
        }
        if attached, tabs.selectedSegment == 1 { torrent?.attach() }
        updateControls()
    }

    func attach() {
        attached = true
        observeCompletedDownloads()
        if isViewLoaded {
            if tabs.selectedSegment == 1 { torrent?.attach() }
            updateControls()
        }
    }

    func detach() {
        attached = false
        completedObservation.stop()
        clearPendingCatalog()
        if isViewLoaded { resetSources(); updateControls() }
        torrent?.detach()
    }
}
