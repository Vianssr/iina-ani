import SourceCore
import AppKit
import UniformTypeIdentifiers

@MainActor
private final class WorkspaceTorrentDocumentStack: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class WorkspaceTorrentResultsTable: NSTableView {
    var importSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if isEnabled, selectedRow >= 0 { importSelection?() }
        } else { super.keyDown(with: event) }
    }
}

@MainActor
private final class WorkspaceTorrentResultsScroll: NSScrollView {
    override func layout() {
        super.layout()
        guard let table = documentView as? NSTableView, let titleColumn = table.tableColumns.first else { return }
        let fixedWidth = table.tableColumns.dropFirst().reduce(CGFloat.zero) { $0 + $1.width }
        let titleWidth = max(titleColumn.minWidth, contentSize.width - fixedWidth - table.intercellSpacing.width * CGFloat(table.numberOfColumns))
        if abs(titleColumn.width - titleWidth) > 0.5 { titleColumn.width = titleWidth }
        if abs(table.frame.width - contentSize.width) > 0.5 {
            table.setFrameSize(NSSize(width: contentSize.width, height: table.frame.height))
        }
    }
}

/// Presentation owns search and metadata cancellation. DownloadService and Processes retain transfers/playback.
@MainActor
final class WorkspaceTorrentController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    WorkspaceDetachablePanel {
    private let delegate: AppDelegate
    private let appearance: SkinAppearance
    private let previewOnly: Bool
    private let work: Work?
    private let sourceCoverURL: String?
    private let completedObservation = WorkspaceCompletedDownloads()
    private var completedRecords: [DownloadRecord] = []
    private func isDownloaded(_ file: TorrentFileCandidate) -> Bool {
        guard let metadata, let identity = TorrentSelection(infoHashes: metadata.infoHashes, fileIndex: file.index, path: file.path, size: file.size)?.identityURL else { return false }
        return completedRecords.contains { $0.selection.torrent?.identityURL == identity }
    }
    private func observeCompletedDownloads() {
        guard !previewOnly, let downloads = try? delegate.services.downloads() else { return }
        completedObservation.start(downloads) { [weak self] records in
            guard let self, self.attached else { return }
            self.completedRecords = records
            if self.isViewLoaded { self.table.reloadData(); self.updateControls() }
        }
    }
    private let keywordField = WorkspaceSkinSearchField()
    private let searchButton = WorkspaceSkinButton()
    private let cancelSearchButton = WorkspaceSkinButton()
    private let resultsTable = WorkspaceTorrentResultsTable()
    private let groupsTable = NSTableView()
    private var releaseGroups: [String] = []
    private var selectedGroup: String?
    private var resultRows: [Int] = []
    private var fileDetailViews: [NSView] = []
    private var resultIntentIsPlayback = false
    private let searchStatus = WorkspaceSkinStatusLabel(wrappingLabelWithString: String(localized: "搜尋只查詢 RSS；雙擊集數匯入，或選取後按 Return。"))
    private let searchService = TorrentSearchService()
    private var searchResults: [TorrentSearchResult] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private let address = WorkspaceSkinSearchField()
    private let uploadLimit = NSTextField(string: "")
    private let metadataLabel = NSTextField(wrappingLabelWithString: String(localized: "尚未匯入 Torrent。"))
    private let status = WorkspaceSkinStatusLabel(wrappingLabelWithString: "")
    private let playbackStatus = WorkspaceSkinStatusLabel(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let importButton = WorkspaceSkinButton()
    private let fileButton = WorkspaceSkinButton()
    private let cancelButton = WorkspaceSkinButton()
    private let downloadButton = WorkspaceSkinButton()
    private let selectAllButton = WorkspaceSkinButton()
    private let clearSelectionButton = WorkspaceSkinButton()
    private let selectionCount = NSTextField(labelWithString: "")
    private let playButton = WorkspaceSkinButton()
    private let stopButton = WorkspaceSkinButton()
    private var metadata: TorrentImport?
    private var pendingImportID: UUID?
    private var selectedStorageRoot: URL?
    private var checkedFileIndices = Set<Int>()
    private var admittedFileIndices = Set<Int>()
    private var downloadOnly = false
    private var service: DownloadService?
    private var operation: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var playback: TorrentPlayerSession?
    private var attached = true
    private var generation = UUID()

    init(delegate: AppDelegate, appearance: SkinAppearance, previewOnly: Bool = false, work: Work? = nil, sourceCoverURL: String? = nil) {
        self.delegate = delegate
        self.appearance = appearance
        self.previewOnly = previewOnly
        self.work = work
        self.sourceCoverURL = sourceCoverURL
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Torrent 匯入與詳情")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        let documentScroll = WorkspaceScrollView()
        documentScroll.hasVerticalScroller = true
        documentScroll.autohidesScrollers = true
        documentScroll.drawsBackground = false
        let panel = WorkspaceTorrentDocumentStack()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        panel.translatesAutoresizingMaskIntoConstraints = false
        documentScroll.documentView = panel
        documentScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(documentScroll)
        NSLayoutConstraint.activate([
            documentScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            documentScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            documentScroll.topAnchor.constraint(equalTo: root.topAnchor),
            documentScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.widthAnchor.constraint(equalTo: documentScroll.contentView.widthAnchor),
        ])
        let heading = NSTextField(labelWithString: title ?? "Torrent")
        heading.bindSkin(appearance, slot: "header", componentID: "torrent.import")
        panel.addArrangedSubview(heading)
        keywordField.placeholderString = String(localized: "作品名稱／BT 搜尋關鍵字")
        keywordField.target = self
        keywordField.action = #selector(searchKeywordAction)
        keywordField.sendsSearchStringImmediately = false
        keywordField.sendsWholeSearchString = true
        keywordField.setAccessibilityLabel(String(localized: "BT 搜尋關鍵字"))
        panel.addArrangedSubview(keywordField)
        configure(searchButton, title: String(localized: "搜尋 BT"), action: #selector(searchKeywordAction), icon: .search)
        configure(cancelSearchButton, title: String(localized: "取消搜尋"), action: #selector(cancelSearchAction), icon: .close)
        let searchActions = NSStackView(views: [searchButton, cancelSearchButton])
        searchActions.orientation = .horizontal
        panel.addArrangedSubview(searchActions)
        let resultColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        resultColumn.title = String(localized: "集數與版本")
        resultColumn.minWidth = 160
        resultColumn.width = 340
        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("resultActions"))
        actionColumn.title = ""
        actionColumn.width = 74
        actionColumn.minWidth = 74
        actionColumn.maxWidth = 74
        resultsTable.addTableColumn(actionColumn)
        resultsTable.addTableColumn(resultColumn)
        resultsTable.moveColumn(1, toColumn: 0)
        let detailsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("releaseDetails"))
        detailsColumn.title = String(localized: "發布日期／大小")
        detailsColumn.width = 96
        detailsColumn.minWidth = 96
        detailsColumn.maxWidth = 96
        resultsTable.addTableColumn(detailsColumn)
        resultsTable.moveColumn(2, toColumn: 1)
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.target = self
        resultsTable.doubleAction = #selector(importClickedResult)
        resultsTable.importSelection = { [weak self] in self?.readSelectedSearchResult() }
        resultsTable.rowHeight = 52
        resultsTable.gridStyleMask = .solidHorizontalGridLineMask
        resultsTable.intercellSpacing = NSSize(width: 8, height: 2)
        resultsTable.columnAutoresizingStyle = .noColumnAutoresizing
        resultsTable.setAccessibilityLabel(String(localized: "漢化組／集數 · 雙擊匯入"))
        let resultsScroll = WorkspaceTorrentResultsScroll()
        resultsScroll.documentView = resultsTable
        resultsScroll.hasVerticalScroller = true
        resultsScroll.autohidesScrollers = true
        let groupColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        groupColumn.title = String(localized: "漢化組")
        groupsTable.addTableColumn(groupColumn)
        groupsTable.dataSource = self
        groupsTable.delegate = self
        groupsTable.rowHeight = 40
        groupsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        groupsTable.setAccessibilityLabel(String(localized: "漢化組篩選"))
        let groupScroll = NSScrollView()
        groupScroll.documentView = groupsTable
        groupScroll.hasVerticalScroller = true
        groupScroll.autohidesScrollers = true
        let resultsBrowser = NSStackView(views: [groupScroll, resultsScroll])
        resultsBrowser.orientation = .horizontal
        resultsBrowser.alignment = .top
        resultsBrowser.spacing = 12
        panel.addArrangedSubview(resultsBrowser)
        groupScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resultsBrowser.heightAnchor.constraint(equalToConstant: 310),
            groupScroll.widthAnchor.constraint(equalTo: resultsBrowser.widthAnchor, multiplier: 0.24),
            groupScroll.heightAnchor.constraint(equalTo: resultsBrowser.heightAnchor),
            resultsScroll.heightAnchor.constraint(equalTo: resultsBrowser.heightAnchor),
        ])
        panel.addArrangedSubview(searchStatus)
        address.placeholderString = String(localized: "magnet: 或本機 .torrent 路徑")
        address.target = self
        address.action = #selector(importAddress)
        address.setAccessibilityLabel(String(localized: "Torrent 位址"))
        panel.addArrangedSubview(address)
        let importActions = NSStackView(views: [importButton, fileButton, cancelButton])
        importActions.orientation = .horizontal
        configure(importButton, title: String(localized: "匯入"), action: #selector(importAddress), icon: .magnet)
        configure(fileButton, title: String(localized: "選擇 .torrent…"), action: #selector(chooseFileAction), icon: .folder)
        configure(cancelButton, title: String(localized: "取消匯入"), action: #selector(cancelImportAction), icon: .close)
        panel.addArrangedSubview(importActions)
        uploadLimit.stringValue = String(delegate.services.preferences.torrentUploadLimitBytesPerSecond)
        uploadLimit.setAccessibilityLabel(String(localized: "P2P 上傳上限，每秒位元組"))
        let policyHelp = NSButton(title: "", target: self, action: #selector(showUploadHelp(_:)))
        policyHelp.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: String(localized: "P2P 上傳說明"))
        policyHelp.isBordered = false
        policyHelp.toolTip = uploadExplanation
        policyHelp.setAccessibilityLabel(String(localized: "P2P 上傳說明"))
        let policyRow = NSStackView(views: [NSTextField(labelWithString: String(localized: "上傳上限（bytes/s）")), uploadLimit, policyHelp])
        policyRow.orientation = .horizontal
        panel.addArrangedSubview(policyRow)
        panel.addArrangedSubview(metadataLabel)
        let checkColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("checked"))
        checkColumn.title = String(localized: "Download")
        checkColumn.width = 54
        checkColumn.minWidth = 54
        checkColumn.maxWidth = 54
        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = String(localized: "精確檔案路徑（不預選首檔）")
        pathColumn.width = 360
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = String(localized: "大小")
        sizeColumn.width = 120
        table.addTableColumn(checkColumn)
        table.addTableColumn(pathColumn)
        table.addTableColumn(sizeColumn)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(String(localized: "Torrent metadata 檔案清單"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        panel.addArrangedSubview(scroll)
        configure(selectAllButton, title: String(localized: "全選影片"), action: #selector(selectAllFiles), icon: .check)
        configure(clearSelectionButton, title: String(localized: "清除勾選"), action: #selector(clearCheckedFiles), icon: .close)
        let selectionActions = NSStackView(views: [selectAllButton, clearSelectionButton, selectionCount])
        selectionActions.orientation = .horizontal
        panel.addArrangedSubview(selectionActions)
        let actions = NSStackView(views: [downloadButton, playButton, stopButton])
        actions.orientation = .horizontal
        configure(downloadButton, title: String(localized: "下載勾選檔案"), action: #selector(downloadChecked), icon: .downloads)
        configure(playButton, title: String(localized: "邊下邊播"), action: #selector(playSelected), icon: .play)
        configure(stopButton, title: String(localized: "停止此播放"), action: #selector(stopPlayback), icon: .stop)
        panel.addArrangedSubview(actions)
        panel.addArrangedSubview(status)
        panel.addArrangedSubview(playbackStatus)
        for item in [heading, keywordField, searchActions, resultsBrowser, searchStatus, address, importActions, policyRow, metadataLabel, scroll, selectionActions, actions, status, playbackStatus] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -28).isActive = true
        }
        fileDetailViews = [metadataLabel, scroll, selectionActions, actions]
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        uploadLimit.widthAnchor.constraint(equalToConstant: 130).isActive = true
        root.bindSkin(appearance, slot: "panel", componentID: "torrent.import")
        panel.bindSkin(appearance, slot: "list", componentID: "torrent.import")
        table.bindSkin(appearance, slot: "list", componentID: "torrent.import")
        for label in [metadataLabel, selectionCount] { label.bindSkin(appearance, slot: "list", componentID: "torrent.import") }
        address.bindSkin(appearance, slot: "search", componentID: "torrent.import")
        keywordField.bindSkin(appearance, slot: "search", componentID: "torrent.import")
        groupsTable.bindSkin(appearance, slot: "list", componentID: "torrent.import")
        resultsTable.bindSkin(appearance, slot: "list", componentID: "torrent.import")
        searchStatus.bindSkin(appearance, slot: "emptyState", componentID: "torrent.import")
        uploadLimit.bindSkin(appearance, slot: "search", componentID: "torrent.import")
        status.bindSkin(appearance, slot: "emptyState", componentID: "torrent.import")
        playbackStatus.bindSkin(appearance, slot: "emptyState", componentID: "torrent.import")
        view = root
        if previewOnly { status.stringValue = String(localized: "外觀預覽：不讀取 metadata、不建立傳輸。") }
        updateControls()
        observeCompletedDownloads()
    }

    private func configure(_ button: WorkspaceSkinButton, title: String, action: Selector, icon: WorkspaceIcon) {
        button.title = title
        button.setFunctionIcon(icon)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.bindSkin(appearance, slot: "primaryAction", componentID: "torrent.import")
    }

    /// Dedicated download pages use this without changing the existing initializer.
    func hidePlaybackControls() {
        _ = view
        downloadOnly = true
        playButton.isHidden = true
        stopButton.isHidden = true
        playbackStatus.isHidden = true
        updateControls()
    }

    /// Prefills the work keyword and starts HTTP/RSS search only; never imports a result automatically.
    func search(keyword: String) {
        _ = view
        keywordField.stringValue = keyword
        guard !previewOnly, attached else { return }
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        resetSearchResults()
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchStatus.stringValue = String(localized: "請輸入 BT 搜尋關鍵字。")
            updateControls()
            return
        }
        guard delegate.services.preferences.isSourceEnabled("torrent") else {
            searchStatus.stringValue = String(localized: "Torrent 來源已停用；請從設定 → 來源與帳號重新啟用。")
            updateControls()
            return
        }
        let token = searchGeneration
        let service = searchService
        searchStatus.stringValue = String(localized: "正在搜尋 BT RSS；不連接 P2P…")
        searchStatus.workspaceSkinBinding?.state = .normal
        searchTask = Task { [weak self] in
            do {
                let report = try await service.search(keyword: query)
                try Task.checkCancellation()
                guard let self, attached, searchGeneration == token else { return }
                searchResults = report.results
                rebuildResultRows()
                let summary = searchResults.isEmpty ? String(localized: "沒有找到 BT 結果。") : String(localized: "找到 \(searchResults.count) 個結果；雙擊集數匯入。")
                searchStatus.stringValue = ([summary] + report.failures).joined(separator: "\n")
                searchStatus.workspaceSkinBinding?.state = report.failures.isEmpty ? .normal : .error
            } catch {
                guard let self, attached, searchGeneration == token else { return }
                searchStatus.stringValue = Task.isCancelled ? String(localized: "已取消 BT 搜尋。") : error.localizedDescription
                searchStatus.workspaceSkinBinding?.state = Task.isCancelled ? .normal : .error
            }
            guard let self, searchGeneration == token else { return }
            searchTask = nil
            updateControls()
        }
        updateControls()
    }

    private func resetSearchResults() {
        searchResults = []
        resultRows = []
        releaseGroups = []
        selectedGroup = nil
        groupsTable.reloadData()
        groupsTable.deselectAll(nil)
        resultsTable.reloadData()
        resultsTable.deselectAll(nil)
    }

    private func rebuildResultRows() {
        releaseGroups = Set(searchResults.map(\.releaseGroup)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        selectedGroup = releaseGroups.first
        groupsTable.reloadData()
        if !releaseGroups.isEmpty { groupsTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) }
        filterResultRows()
    }

    private func filterResultRows() {
        resultRows = searchResults.indices.filter { selectedGroup == nil || searchResults[$0].releaseGroup == selectedGroup }.sorted {
            let left = searchResults[$0], right = searchResults[$1]
            let order = (left.episode ?? "").localizedStandardCompare(right.episode ?? "")
            return order == .orderedSame ? left.title.localizedStandardCompare(right.title) == .orderedAscending : order == .orderedDescending
        }
        resultsTable.reloadData()
        resultsTable.deselectAll(nil)
        if !resultRows.isEmpty { resultsTable.scrollRowToVisible(0) }
    }

    private var selectedSearchResult: TorrentSearchResult? {
        let row = resultsTable.selectedRow
        guard resultRows.indices.contains(row) else { return nil }
        return searchResults[resultRows[row]]
    }

    private var uploadExplanation: String {
        String(localized: "讀取 metadata 也會連接 P2P 網路，首次須同意可能上傳。上限為 1–10485760 bytes/s；設定頁可調整活動傳輸上限或停止全部 P2P。快取清理不移除 Torrent 暫存與完成檔。")
    }

    @objc private func showUploadHelp(_ sender: NSButton) {
        let content = NSViewController()
        let label = NSTextField(wrappingLabelWithString: uploadExplanation)
        label.frame = NSRect(x: 14, y: 14, width: 320, height: 110)
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 348, height: 138))
        content.view.addSubview(label)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func searchKeywordAction() { search(keyword: keywordField.stringValue) }

    @objc private func cancelSearchAction() {
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        searchStatus.stringValue = String(localized: "已取消 BT 搜尋；metadata、下載與播放不受影響。")
        searchStatus.workspaceSkinBinding?.state = .normal
        updateControls()
    }

    @objc private func importClickedResult() {
        let row = resultsTable.clickedRow
        guard resultRows.indices.contains(row) else { return }
        readSelectedSearchResult()
    }

    @objc private func resultAction(_ sender: NSButton) {
        guard !previewOnly, attached, operation == nil, searchTask == nil,
              searchResults.indices.contains(sender.tag) else { return }
        resultIntentIsPlayback = sender.identifier?.rawValue == "playResult"
        importResult(searchResults[sender.tag])
    }

    @objc private func copyResultMagnet(_ sender: NSButton) {
        guard searchResults.indices.contains(sender.tag), let magnet = searchResults[sender.tag].magnetURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(magnet, forType: .string)
    }

    @objc private func readSelectedSearchResult() {
        guard !previewOnly, attached, operation == nil, let result = selectedSearchResult else { return }
        resultIntentIsPlayback = false
        importResult(result)
    }

    private func importResult(_ result: TorrentSearchResult) {
        if let magnet = result.magnetURL {
            openAddress(magnet)
        } else if let url = result.torrentURL {
            beginImport(url.absoluteString, remoteTorrentURL: url)
        } else {
            status.stringValue = String(localized: "所選結果沒有可匯入的 magnet 或 Torrent 連結。")
        }
    }
    func openAddress(_ value: String) {
        _ = view
        guard !previewOnly, attached else { return }
        address.stringValue = value
        beginImport(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func chooseTorrentFile() {
        _ = view
        guard !previewOnly, attached else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        address.stringValue = url.absoluteString
        beginImport(url.absoluteString, securityScopedURL: url)
    }

    @objc private func chooseFileAction() { chooseTorrentFile() }
    @objc private func importAddress() { openAddress(address.stringValue) }

    private func policy(requireConsent: Bool) throws -> TorrentUploadPolicy? {
        guard let limit = UInt32(uploadLimit.stringValue), (1...TorrentUploadPolicy.maximumBytesPerSecond).contains(limit) else {
            throw DownloadFailure.invalidSelection
        }
        let preferences = delegate.services.preferences
        if requireConsent && !preferences.torrentUploadConsentAcknowledged {
            let alert = NSAlert()
            alert.messageText = String(localized: "首次 P2P 上傳確認")
            alert.informativeText = String(localized: "Torrent metadata、下載與串流可能向其他 peer 上傳已收到的資料。此次上傳上限為 \(limit) bytes/s；共用傳輸遵守較小的有效上限。最後一個下載／播放使用者停止後傳輸會停止。取消不連接 P2P 網路。")
            alert.addButton(withTitle: String(localized: "同意並讀取"))
            alert.addButton(withTitle: String(localized: "取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        let result = try TorrentUploadPolicy(bytesPerSecond: limit, acknowledged: preferences.torrentUploadConsentAcknowledged || requireConsent)
        return result
    }

    private func beginImport(_ raw: String, securityScopedURL: URL? = nil, remoteTorrentURL: URL? = nil) {
        guard operation == nil else { status.stringValue = String(localized: "請先取消目前匯入／操作。"); return }
        do {
            let input: URL
            if let remoteTorrentURL {
                guard ["http", "https"].contains(remoteTorrentURL.scheme?.lowercased() ?? ""),
                      remoteTorrentURL.host != nil, remoteTorrentURL.user == nil, remoteTorrentURL.password == nil else {
                    throw DownloadFailure.invalidSelection
                }
                input = remoteTorrentURL
            } else {
                guard let parsed = try SourceRegistry.shared.torrentInput(for: raw) else { throw DownloadFailure.invalidSelection }
                input = parsed
            }
            guard delegate.services.preferences.isSourceEnabled("torrent") else {
                status.stringValue = String(localized: "Torrent 來源已停用；請從設定 → 來源與帳號重新啟用。")
                return
            }
            guard let uploadPolicy = try policy(requireConsent: true) else { status.stringValue = String(localized: "已取消，未連接 P2P。"); return }
            let downloads = try delegate.services.downloads()
            service = downloads
            let oldImport = pendingImportID
            releaseSelectedStorage()
            pendingImportID = nil
            metadata = nil
            selectedStorageRoot = nil
            checkedFileIndices.removeAll()
            admittedFileIndices.removeAll()
            table.reloadData()
            table.deselectAll(nil)
            let token = UUID()
            generation = token
            status.stringValue = remoteTorrentURL != nil ? String(localized: "正在下載所選 .torrent（上限 16 MiB）…") : input.isFileURL ? String(localized: "正在讀取本機 Torrent metadata…") : String(localized: "等待 peers 提供 metadata（最多 45 秒）…")
            status.workspaceSkinBinding?.state = .normal
            metadataLabel.stringValue = String(localized: "metadata 讀取中；尚未選取任何檔案。")
            operation = Task { [weak self] in
                let scoped = securityScopedURL?.startAccessingSecurityScopedResource() ?? false
                var temporaryTorrent: URL?
                defer {
                    if scoped { securityScopedURL?.stopAccessingSecurityScopedResource() }
                    if let temporaryTorrent { try? FileManager.default.removeItem(at: temporaryTorrent.deletingLastPathComponent()) }
                }
                if let oldImport { await downloads.cancelTorrentImport(importID: oldImport) }
                do {
                    try await downloads.setTorrentUploadLimit(uploadPolicy.bytesPerSecond)
                    try Task.checkCancellation()
                    self?.delegate.services.preferences.saveTorrentUploadPolicy(uploadPolicy)
                    let importRaw: String
                    if let remoteTorrentURL {
                        let file = try await Self.downloadTorrent(remoteTorrentURL)
                        temporaryTorrent = file
                        try Task.checkCancellation()
                        guard let self, attached, generation == token else { throw CancellationError() }
                        status.stringValue = String(localized: "正在讀取下載的 Torrent metadata…")
                        importRaw = file.absoluteString
                    } else {
                        importRaw = raw
                    }
                    let imported = try await downloads.importTorrent(raw: importRaw, uploadPolicy: uploadPolicy)
                    guard let self, attached, generation == token, !Task.isCancelled else {
                        await downloads.cancelTorrentImport(importID: imported.id)
                        return
                    }
                    metadata = imported
                    pendingImportID = imported.id
                    metadataLabel.stringValue = String(localized: "\(imported.isPrivate ? String(localized: "Private：不公開發現") : String(localized: "Public")) · \(imported.files.count) 個檔案 · \(Self.size(imported.totalBytes))\nInfo hash：\(imported.infoHashes.sorted().joined(separator: " / "))")
                    table.reloadData()
                    updateControls()
                    if let fileScroll = table.enclosingScrollView { fileScroll.scrollToVisible(fileScroll.bounds) }
                    if imported.files.isEmpty { status.stringValue = String(localized: "metadata 沒有可選檔案。") }
                    else if resultIntentIsPlayback { status.stringValue = String(localized: "請選取影片檔案，再按「邊下邊播」。") }
                    else if downloadOnly { status.stringValue = String(localized: "勾選影片後可一次下載多檔；非影片不支援下載，不預選任何檔案。") }
                    else { status.stringValue = String(localized: "勾選影片後可一次下載多檔；點選單一列可邊下邊播。非影片不支援下載／播放，不預選任何檔案。") }
                } catch {
                    guard let self, generation == token, attached else { return }
                    status.stringValue = Task.isCancelled ? String(localized: "已取消匯入。") : Self.message(error)
                    status.workspaceSkinBinding?.state = .error
                }
                guard let self, generation == token else { return }
                operation = nil
                updateControls()
            }
            updateControls()
        } catch { status.stringValue = Self.message(error) }
    }

    nonisolated private static func downloadTorrent(_ url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("application/x-bittorrent, application/octet-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              ["http", "https"].contains(response.url?.scheme?.lowercased() ?? "") else {
            throw WorkspaceTorrentRemoteFailure.invalidResponse
        }
        guard http.statusCode == 200 else { throw WorkspaceTorrentRemoteFailure.httpStatus(http.statusCode) }
        let limit = 16 * 1024 * 1024
        guard response.expectedContentLength <= Int64(limit) else { throw WorkspaceTorrentRemoteFailure.invalidSize }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 64_000)
        for try await byte in bytes {
            guard data.count < limit else { throw WorkspaceTorrentRemoteFailure.invalidSize }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard !data.isEmpty else { throw WorkspaceTorrentRemoteFailure.invalidSize }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BT-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let file = directory.appendingPathComponent("metadata.torrent")
            try data.write(to: file, options: .withoutOverwriting)
            try Task.checkCancellation()
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    @objc private func cancelImportAction() {
        let operationOwnsStorage = operation != nil
        generation = UUID()
        operation?.cancel()
        operation = nil
        // In-flight operations release only after selection/admission has returned.
        if !operationOwnsStorage {
            releasePendingImport()
            releaseSelectedStorage()
        }
        pendingImportID = nil
        metadata = nil
        selectedStorageRoot = nil
        checkedFileIndices.removeAll()
        admittedFileIndices.removeAll()
        table.reloadData()
        metadataLabel.stringValue = String(localized: "尚未匯入 Torrent。")
        status.stringValue = String(localized: "已取消匯入，未啟動的 metadata 資源將釋放；獨立下載與播放不受影響。")
        updateControls()
    }

    private func releasePendingImport() {
        if let id = pendingImportID, let service {
            Task { await service.cancelTorrentImport(importID: id) }
        }
        pendingImportID = nil
    }

    private func releaseSelectedStorage() {
        guard let root = selectedStorageRoot, let metadata,
              let file = metadata.files.first(where: { $0.isPlayableMedia }),
              let selection = TorrentSelection(infoHashes: metadata.infoHashes, fileIndex: file.index, path: file.path, size: file.size),
              let service else { return }
        Task { await service.releaseTorrentSelection(TorrentSelectedFile(selection: selection, storageRoot: root)) }
    }

    private var selectedFile: TorrentFileCandidate? {
        guard let files = metadata?.files, files.indices.contains(table.selectedRow) else { return nil }
        return files[table.selectedRow]
    }

    @objc private func selectAllFiles() {
        guard attached, !previewOnly, operation == nil else { return }
        checkedFileIndices = Set((metadata?.files ?? []).filter {
            $0.isPlayableMedia && !admittedFileIndices.contains($0.index)
        }.map(\.index))
        table.reloadData()
        updateControls()
    }

    @objc private func clearCheckedFiles() {
        guard attached, !previewOnly, operation == nil else { return }
        checkedFileIndices.removeAll()
        table.reloadData()
        updateControls()
    }

    @objc private func checkFile(_ sender: NSButton) {
        guard attached, !previewOnly, operation == nil,
              let file = metadata?.files.first(where: { $0.index == sender.tag }),
              file.isPlayableMedia, !admittedFileIndices.contains(file.index) else { return }
        if sender.state == .on { checkedFileIndices.insert(file.index) }
        else { checkedFileIndices.remove(file.index) }
        updateControls()
    }

    @objc private func downloadChecked() {
        guard !previewOnly, attached, operation == nil, let metadata, let downloads = service else { return }
        let files = metadata.files.filter {
            $0.isPlayableMedia && checkedFileIndices.contains($0.index) && !admittedFileIndices.contains($0.index)
        }
        guard !files.isEmpty else { return }
        do {
            guard let policy = try policy(requireConsent: false) else { return }
            let importID = pendingImportID, initialRoot = selectedStorageRoot, token = generation
            status.stringValue = String(localized: "正在建立 \(files.count) 個下載任務…")
            status.workspaceSkinBinding?.state = .normal
            operation = Task { [weak self] in
                var root = initialRoot
                var cleanupSelection: TorrentSelectedFile?
                var admitted = 0
                var failures: [String] = []
                for file in files {
                    do {
                        try Task.checkCancellation()
                        guard let self, attached, generation == token else { break }
                        let selected: TorrentSelectedFile
                        if let root {
                            guard let selection = TorrentSelection(infoHashes: metadata.infoHashes, fileIndex: file.index,
                                                                  path: file.path, size: file.size) else {
                                throw DownloadFailure.invalidSelection
                            }
                            selected = TorrentSelectedFile(selection: selection, storageRoot: root)
                        } else if let importID {
                            selected = try await downloads.selectTorrentFile(importID: importID, fileIndex: file.index, uploadPolicy: policy)
                        } else { throw DownloadFailure.invalidSelection }
                        // Only the first file consumes the import. Every later admission uses this exact root.
                        root = selected.storageRoot
                        cleanupSelection = selected
                        if self.metadata?.id == metadata.id {
                            pendingImportID = nil
                            selectedStorageRoot = selected.storageRoot
                        }
                        guard attached, generation == token, !Task.isCancelled else { break }
                        let item = SourceItemRef(sourceID: "torrent", pageURL: selected.selection.identityURL.absoluteString, kind: .video)
                        _ = try await downloads.create(selection: PlayableSelection(item: item, torrent: selected.selection, classification: work?.classification ?? .unknown), title: work?.title ?? file.path, episodeTitle: file.path, workID: work?.id,
                            torrentUploadPolicy: policy, torrentStorageDirectory: selected.storageRoot, coverURL: work?.coverURL ?? sourceCoverURL, bangumiID: work?.bangumiID, episodeKey: nil)
                        admitted += 1
                        if self.metadata?.id == metadata.id {
                            // Preserve successful admission across detach/reattach, too.
                            admittedFileIndices.insert(file.index)
                            checkedFileIndices.remove(file.index)
                            if attached {
                                table.reloadData()
                                updateControls()
                            }
                        }
                    } catch {
                        if Task.isCancelled || error is CancellationError { break }
                        failures.append("[\(file.index)] \(file.path)：\(Self.message(error))")
                    }
                }
                guard let self, attached, generation == token else {
                    // Never release the shared session between per-file admissions.
                    if let cleanupSelection { await downloads.releaseTorrentSelection(cleanupSelection) }
                    else if let root, let file = files.first,
                            let selection = TorrentSelection(infoHashes: metadata.infoHashes, fileIndex: file.index, path: file.path, size: file.size) {
                        await downloads.releaseTorrentSelection(TorrentSelectedFile(selection: selection, storageRoot: root))
                    }
                    if let importID { await downloads.cancelTorrentImport(importID: importID) }
                    return
                }
                status.stringValue = ([String(localized: "已加入 \(admitted)／\(files.count) 個下載任務。成功項目不會重複加入；失敗項目保留勾選，可重試。暫停／取消請在下載頁操作。")] + failures).joined(separator: "\n")
                status.workspaceSkinBinding?.state = failures.isEmpty ? .normal : .error
                operation = nil
                table.reloadData()
                updateControls()
            }
            updateControls()
        } catch { status.stringValue = Self.message(error) }
    }

    @objc private func playSelected() {
        guard !downloadOnly, !previewOnly, attached, operation == nil, let file = selectedFile, file.isPlayableMedia,
              let metadata, let downloads = service else { return }
        do {
            guard let policy = try policy(requireConsent: false) else { return }
            let importID = pendingImportID, root = selectedStorageRoot, token = generation
            let services = delegate.services
            status.stringValue = String(localized: "正在建立独立串流播放…")
            operation = Task { [weak self] in
                var cleanupSelection: TorrentSelectedFile?
                defer {
                    if self?.attached != true || self?.generation != token {
                        let selected = cleanupSelection
                        Task {
                            if let selected { await downloads.releaseTorrentSelection(selected) }
                            if let importID { await downloads.cancelTorrentImport(importID: importID) }
                        }
                    }
                }
                do {
                    let selected: TorrentSelectedFile
                    if let root, let selection = TorrentSelection(infoHashes: metadata.infoHashes, fileIndex: file.index, path: file.path, size: file.size) {
                        selected = TorrentSelectedFile(selection: selection, storageRoot: root)
                    } else if let importID {
                        selected = try await downloads.selectTorrentFile(importID: importID, fileIndex: file.index, uploadPolicy: policy)
                    } else { throw DownloadFailure.invalidSelection }
                    cleanupSelection = selected
                    guard let self, attached, generation == token, !Task.isCancelled else { return }
                    pendingImportID = nil
                    selectedStorageRoot = selected.storageRoot
                    let endpoint = try await services.httpServer.start()
                    try Task.checkCancellation()
                    let grant = try await downloads.torrentPlayback(selected: selected, uploadPolicy: policy, port: endpoint.port)
                    let session = try await services.player.openTorrentPlayback(grant)
                    // Once launched, Processes owns lifetime; panel removal must not stop it.
                    guard attached, generation == token else { return }
                    playback = session
                    observePlayback(session)
                    status.stringValue = String(localized: "播放與下載獨立。停止播放只撤銷此串流，不取消下載。")
                } catch {
                    guard let self, attached, generation == token else { return }
                    status.stringValue = Self.message(error)
                    status.workspaceSkinBinding?.state = .error
                }
                guard let self, generation == token else { return }
                operation = nil
                updateControls()
            }
            updateControls()
        } catch { status.stringValue = Self.message(error) }
    }

    private func observePlayback(_ session: TorrentPlayerSession) {
        observation?.cancel()
        observation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, attached else { return }
                switch session.state {
                case .connecting: playbackStatus.stringValue = String(localized: "正在連接播放器，等待串流資料…")
                case .buffering: playbackStatus.stringValue = String(localized: "緩衝中：等待所選檔案的必要分塊；可停止此播放。")
                case .playing: playbackStatus.stringValue = String(localized: "播放器已載入 Torrent 串流。")
                case .stopped: playbackStatus.stringValue = String(localized: "此播放已停止，串流授權已撤銷。"); updateControls(); return
                case .failed(let message): playbackStatus.stringValue = message; playbackStatus.workspaceSkinBinding?.state = .error; updateControls(); return
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    @objc private func stopPlayback() {
        guard let playback, !previewOnly else { return }
        Task { await playback.stop() }
    }

    private var playbackActive: Bool {
        guard let playback else { return false }
        switch playback.state {
        case .connecting, .buffering, .playing: return true
        case .stopped, .failed: return false
        }
    }
    private func updateControls() {
        let available = attached && !previewOnly
        keywordField.isEnabled = available
        searchButton.isEnabled = available
        cancelSearchButton.isEnabled = available && searchTask != nil
        resultsTable.isEnabled = available && operation == nil && searchTask == nil
        groupsTable.isEnabled = available && searchTask == nil
        for detailView in fileDetailViews { detailView.isHidden = metadata == nil }
        for row in 0..<resultsTable.numberOfRows {
            guard let actions = resultsTable.view(atColumn: 2, row: row, makeIfNecessary: false) as? NSStackView else { continue }
            for case let button as NSButton in actions.arrangedSubviews {
                button.isEnabled = available && operation == nil && searchTask == nil &&
                    (button.identifier?.rawValue != "copyMagnet" || searchResults[button.tag].magnetURL != nil)
                if button.identifier?.rawValue == "playResult" { button.isHidden = downloadOnly }
            }
        }
        importButton.isEnabled = available && operation == nil
        fileButton.isEnabled = available && operation == nil
        address.isEnabled = available && operation == nil
        uploadLimit.isEnabled = available && operation == nil
        cancelButton.isEnabled = available && (operation != nil || metadata != nil)
        let hasSelectionResources = pendingImportID != nil || selectedStorageRoot != nil
        downloadButton.isEnabled = available && hasSelectionResources && operation == nil && !checkedFileIndices.isEmpty
        playButton.isEnabled = available && hasSelectionResources && !downloadOnly && operation == nil && selectedFile?.isPlayableMedia == true && !playbackActive
        stopButton.isEnabled = available && !downloadOnly && playbackActive
        let playableCount = metadata?.files.filter { $0.isPlayableMedia }.count ?? 0
        selectAllButton.isEnabled = available && hasSelectionResources && operation == nil && playableCount > admittedFileIndices.count
        clearSelectionButton.isEnabled = available && operation == nil && !checkedFileIndices.isEmpty
        selectionCount.stringValue = String(localized: "已勾選 \(checkedFileIndices.count)／\(playableCount) 個影片 · 已加入 \(admittedFileIndices.count) 個")
        for row in 0..<table.numberOfRows {
            guard let checkbox = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSButton else { continue }
            checkbox.isEnabled = available && hasSelectionResources && operation == nil && !admittedFileIndices.contains(checkbox.tag)
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === resultsTable { return 52 }
        if tableView === groupsTable { return 40 }
        return tableView.rowHeight
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === groupsTable { return releaseGroups.isEmpty ? 0 : releaseGroups.count + 1 }
        return tableView === resultsTable ? resultRows.count : metadata?.files.count ?? 0
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === groupsTable {
            let row = groupsTable.selectedRow
            selectedGroup = row > 0 && releaseGroups.indices.contains(row - 1) ? releaseGroups[row - 1] : nil
            filterResultRows()
            return
        }
        guard notification.object as? NSTableView !== resultsTable else { return }
        if let file = selectedFile { status.stringValue = file.isPlayableMedia ? String(localized: "所選索引 \(file.index)：\(file.path)") : String(localized: "所選檔案不是支援的影片格式；請選取影片。") }
        updateControls()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === groupsTable {
            let name = row == 0 ? String(localized: "全部漢化組") : releaseGroups[row - 1]
            let count = row == 0 ? searchResults.count : searchResults.filter { $0.releaseGroup == name }.count
            let label = NSTextField(labelWithString: "\(name)  ·  \(count)")
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = name
            label.bindSkin(appearance, slot: "list", componentID: "torrent.import")
            return label
        }
        if tableView === resultsTable {
            let index = resultRows[row]
            let result = searchResults[index]
            if tableColumn?.identifier.rawValue == "releaseDetails" {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy/MM/dd"
                let date = result.publishedAt.map { formatter.string(from: $0) } ?? "—"
                let size = result.sizeBytes.map(Self.size) ?? "—"
                let label = NSTextField(wrappingLabelWithString: "\(date)\n\(size)")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                label.toolTip = String(localized: "發布日期／大小") + "：\(date) · \(size)"
                return label
            }
            if tableColumn?.identifier.rawValue == "resultActions" {
                let actions = NSStackView()
                actions.orientation = .horizontal
                actions.spacing = 6
                for (identifier, symbol, help, selector) in [
                    ("copyMagnet", "link", String(localized: "複製磁力連結"), #selector(copyResultMagnet(_:))),
                    ("playResult", "play.fill", String(localized: "選擇播放檔案"), #selector(resultAction(_:)))
                ] {
                    let button = NSButton(title: "", target: self, action: selector)
                    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
                    button.bezelStyle = .texturedRounded
                    button.identifier = NSUserInterfaceItemIdentifier(identifier)
                    button.tag = index
                    button.toolTip = help
                    button.setAccessibilityLabel(help + " · " + result.title)
                    button.isEnabled = attached && !previewOnly && operation == nil && searchTask == nil &&
                        (identifier != "copyMagnet" || result.magnetURL != nil)
                    button.isHidden = identifier == "playResult" && downloadOnly
                    actions.addArrangedSubview(button)
                    button.widthAnchor.constraint(equalToConstant: 30).isActive = true
                }
                return actions
            }
            let label = NSTextField(wrappingLabelWithString: result.title)
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.toolTip = "\(result.title)\n\(result.sourceName)"
            label.bindSkin(appearance, slot: "list", componentID: "torrent.import")
            let cell = NSTableCellView()
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: 6),
                label.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -6),
            ])
            cell.textField = label
            return cell
        }
        guard let files = metadata?.files, files.indices.contains(row) else { return nil }
        let file = files[row]
        if tableColumn?.identifier.rawValue == "checked" {
            guard file.isPlayableMedia else { return nil }
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkFile(_:)))
            checkbox.tag = file.index
            checkbox.state = checkedFileIndices.contains(file.index) ? .on : .off
            checkbox.isEnabled = attached && !previewOnly && operation == nil &&
                (pendingImportID != nil || selectedStorageRoot != nil) && !admittedFileIndices.contains(file.index)
            checkbox.setAccessibilityLabel(String(localized: "勾選下載：\(file.path)"))
            checkbox.toolTip = admittedFileIndices.contains(file.index) ? String(localized: "已加入下載任務，不會重複加入。") : String(localized: "勾選此影片下載；不影響單列播放選擇。")
            return checkbox
        }
        let value = tableColumn?.identifier.rawValue == "size" ? Self.size(file.size) : "\(isDownloaded(file) ? String(localized: "✓ 已下載 · ") : "")[\(file.index)] \(file.path)\(file.isPlayableMedia ? "" : String(localized: "（非影片）"))"
        let label = NSTextField(labelWithString: value)
        label.toolTip = value
        label.bindSkin(appearance, slot: "list", componentID: "torrent.import")
        return label
    }
    private static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
    private static func message(_ error: Error) -> String {
        if let failure = error as? DownloadFailure { return failure.localizedDescription }
        if let failure = error as? WorkspaceCapabilityFailure { return failure.localizedDescription }
        if let failure = error as? WorkspaceTorrentRemoteFailure {
            switch failure {
            case .invalidResponse: return String(localized: "Torrent 下載未收到有效的 HTTP 回應。")
            case .httpStatus(let code): return String(localized: "Torrent 下載失敗：HTTP \(code)。")
            case .invalidSize: return String(localized: "Torrent 檔案必須非空且不超過 16 MiB。")
            }
        }
        if error is CancellationError { return String(localized: "操作已取消。") }
        // Never expose raw URLs, local streaming grants or arbitrary native payloads.
        return String(localized: "Torrent 操作失敗。請檢查檔案、peers、儲存空間與播放器設定。")
    }

    func attach() {
        attached = true
        observeCompletedDownloads()
        if isViewLoaded { updateControls() }
    }

    func detach() {
        let operationOwnsStorage = operation != nil
        attached = false
        completedObservation.stop()
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        generation = UUID()
        operation?.cancel()
        operation = nil
        observation?.cancel()
        observation = nil
        if !operationOwnsStorage {
            releasePendingImport()
            releaseSelectedStorage()
        }
        pendingImportID = nil
        // Retain an acquired root as a resume identity; release closes native ownership,
        // not its on-disk metadata, and a later admission re-registers it.
    }
}
private enum WorkspaceTorrentRemoteFailure: Error {
    case invalidResponse
    case httpStatus(Int)
    case invalidSize
}
