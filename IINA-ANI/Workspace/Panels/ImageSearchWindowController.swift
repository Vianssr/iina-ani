import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ImageSearchWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum ImageInput: Sendable {
        case file(URL)
        case pasteboard(Data)
    }

    private enum ImageError: LocalizedError {
        case tooLarge, unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge: String(localized: "圖片不可超過 25 MB，請先縮小圖片。")
            case .unreadable: String(localized: "無法讀取此圖片，請選擇其他圖片或重新貼上。")
            }
        }
    }

    private let service = TraceMoeSearchService()
    private let onSearchTitle: (String) -> Void
    private let preview = NSImageView()
    private let imageStatus = NSTextField(wrappingLabelWithString: String(localized: "尚未選擇圖片"))
    private let status = NSTextField(wrappingLabelWithString: String(localized: "選擇或貼上動畫截圖，再按上傳；選圖不會自動上傳。"))
    private let selectionStatus = NSTextField(wrappingLabelWithString: String(localized: "選取結果以查看詳情與操作。"))
    private let table = NSTableView()
    private let progress = NSProgressIndicator()
    private var uploadButton: NSButton!
    private var cancelButton: NSButton!
    private var anilistButton: NSButton!
    private var videoButton: NSButton!
    private var searchButton: NSButton!
    private var jpeg: Data?
    private var matches: [TraceMoeMatch] = []
    private var operationTask: Task<Void, Never>?
    private var preparationTask: Task<Data, Error>?
    private var revision = UUID()
    private weak var openPanel: NSOpenPanel?

    init(onSearchTitle: @escaping (String) -> Void) {
        self.onSearchTitle = onSearchTitle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "截圖識圖")
        window.contentMinSize = NSSize(width: 620, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        updateActions()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        operationTask?.cancel()
        preparationTask?.cancel()
    }

    private func button(_ title: String, action: Selector, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("imageSearch.\(identifier)")
        return button
    }

    private func buildContent(in window: NSWindow) {
        let root = NSView()
        window.contentView = root
        let choose = button(String(localized: "選擇圖片…"), action: #selector(chooseImage), identifier: "choose")
        let paste = button(String(localized: "貼上圖片"), action: #selector(pasteImage), identifier: "paste")
        let inputActions = NSStackView(views: [choose, paste])
        inputActions.spacing = 8

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        preview.setAccessibilityLabel(String(localized: "待上傳的本機圖片預覽"))
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.layer?.cornerRadius = 6
        imageStatus.textColor = .secondaryLabelColor
        imageStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        imageStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let imageInfo = NSStackView(views: [inputActions, imageStatus])
        imageInfo.orientation = .vertical
        imageInfo.alignment = .leading
        imageInfo.spacing = 10
        let input = NSStackView(views: [preview, imageInfo])
        input.alignment = .centerY
        input.spacing = 16
        preview.widthAnchor.constraint(equalToConstant: 200).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let disclosure = NSTextField(wrappingLabelWithString: String(localized: "按下上傳後，截圖會傳送至第三方 trace.moe，服務會記錄 IP 位址，僅限非商業使用（另獲授權者除外）。僅供動畫畫面辨識，結果可能有誤，不保證提供可播放來源。選圖與貼上僅在本機處理；上傳前會縮圖並移除原始中繼資料。"))
        disclosure.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        disclosure.textColor = .secondaryLabelColor
        disclosure.setAccessibilityIdentifier("imageSearch.privacy")

        uploadButton = button(String(localized: "上傳至 trace.moe 並識圖"), action: #selector(uploadImage), identifier: "upload")
        cancelButton = button(String(localized: "取消"), action: #selector(cancelSearch), identifier: "cancel")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let terms = button(String(localized: "服務條款"), action: #selector(openTerms), identifier: "terms")
        let uploadActions = NSStackView(views: [uploadButton, cancelButton, progress, terms])
        uploadActions.spacing = 8
        status.setAccessibilityIdentifier("imageSearch.status")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.isSelectable = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 68
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .inset
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "trace.moe 識圖結果"))
        table.setAccessibilityIdentifier("imageSearch.results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        selectionStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        selectionStatus.maximumNumberOfLines = 3
        selectionStatus.lineBreakMode = .byTruncatingTail
        selectionStatus.isSelectable = true
        selectionStatus.setAccessibilityIdentifier("imageSearch.selection")
        anilistButton = button(String(localized: "開啟 AniList"), action: #selector(openAniList), identifier: "anilist")
        videoButton = button(String(localized: "在瀏覽器預覽片段"), action: #selector(openVideo), identifier: "video")
        searchButton = button(String(localized: "搜尋此作品"), action: #selector(searchSelectedTitle), identifier: "searchTitle")
        let resultActions = NSStackView(views: [anilistButton, videoButton, searchButton])
        resultActions.spacing = 8

        let stack = NSStackView(views: [input, disclosure, uploadActions, status, scroll, selectionStatus, resultActions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor),
            disclosure.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            selectionStatus.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func chooseImage() {
        guard let window, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "選擇動畫截圖")
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        openPanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            self.openPanel = nil
            guard response == .OK, let url = panel?.url else { return }
            self.prepare(.file(url))
        }
    }

    @objc private func pasteImage() {
        invalidateOperation()
        let pasteboard = NSPasteboard.general
        guard let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type) else {
            status.stringValue = String(localized: "剪貼簿沒有可讀取的圖片，請複製圖片後再試。")
            updateActions()
            return
        }
        prepare(.pasteboard(data))
    }

    private func prepare(_ input: ImageInput) {
        invalidateOperation()
        let currentRevision = revision
        jpeg = nil
        preview.image = nil
        matches = []
        table.reloadData()
        table.deselectAll(nil)
        imageStatus.stringValue = String(localized: "正在本機處理圖片…")
        status.stringValue = String(localized: "正在縮圖並移除原始中繼資料，尚未上傳。")
        let work = Task.detached(priority: .userInitiated) {
            try Self.prepareJPEG(input)
        }
        preparationTask = work
        operationTask = Task { [weak self] in
            do {
                let data = try await work.value
                guard !Task.isCancelled, let self, self.revision == currentRevision else { return }
                self.preparationTask = nil
                self.operationTask = nil
                self.jpeg = data
                self.preview.image = NSImage(data: data)
                let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                self.imageStatus.stringValue = String(localized: "本機 JPEG 預覽 · \(size)\n最長邊不超過 1280 像素")
                self.status.stringValue = String(localized: "圖片已就緒，尚未上傳。請確認圖片內容與隱私說明後再按上傳。")
                self.updateActions()
            } catch {
                guard !Task.isCancelled, let self, self.revision == currentRevision else { return }
                self.preparationTask = nil
                self.operationTask = nil
                self.imageStatus.stringValue = String(localized: "圖片處理失敗")
                self.status.stringValue = (error as? ImageError)?.errorDescription
                    ?? String(localized: "無法讀取此圖片，請選擇其他圖片或重新貼上。")
                self.updateActions()
            }
        }
        updateActions()
    }

    nonisolated private static func prepareJPEG(_ input: ImageInput) throws -> Data {
        let maximumBytes = 25 * 1024 * 1024
        try Task.checkCancellation()
        let data: Data
        switch input {
        case .file(let url):
            guard url.isFileURL else { throw ImageError.unreadable }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        case .pasteboard(let contents):
            data = contents
        }
        guard data.count <= maximumBytes else { throw ImageError.tooLarge }
        try Task.checkCancellation()
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageError.unreadable
        }
        // Render only decoded pixels into a fresh destination; never copy source properties.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let flattened = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageError.unreadable
        }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else {
            throw ImageError.unreadable
        }
        try Task.checkCancellation()
        return output as Data
    }

    @objc private func uploadImage() {
        guard let jpeg, operationTask == nil else { return }
        invalidateOperation()
        let currentRevision = revision
        let service = service
        matches = []
        table.reloadData()
        table.deselectAll(nil)
        status.stringValue = String(localized: "正在上傳至 trace.moe 並辨識…")
        operationTask = Task { [weak self] in
            do {
                let results = try await service.search(jpeg: jpeg)
                guard !Task.isCancelled, let self, self.revision == currentRevision else { return }
                self.operationTask = nil
                self.matches = results
                self.table.reloadData()
                self.status.stringValue = results.isEmpty
                    ? String(localized: "找不到相符動畫，請換用清晰、未裁切的動畫截圖再試。")
                    : String(localized: "找到 \(results.count) 個候選結果。相似度低於 90% 的結果可能不正確，請自行核對。")
                self.updateActions()
            } catch {
                guard !Task.isCancelled, let self, self.revision == currentRevision else { return }
                self.operationTask = nil
                // Only the service's sanitized errors are safe to present.
                self.status.stringValue = (error as? TraceMoeSearchError)?.errorDescription
                    ?? String(localized: "trace.moe 辨識失敗，可能是連線、服務限額或圖片格式問題。請稍後重試。")
                self.updateActions()
            }
        }
        updateActions()
    }

    private func invalidateOperation() {
        revision = UUID()
        operationTask?.cancel()
        operationTask = nil
        preparationTask?.cancel()
        preparationTask = nil
    }

    @objc private func cancelSearch() {
        let wasPreparing = preparationTask != nil
        invalidateOperation()
        if wasPreparing { imageStatus.stringValue = String(localized: "已取消圖片處理") }
        status.stringValue = String(localized: "已取消。若圖片已傳送，取消無法撤回 trace.moe 已收到的內容。")
        updateActions()
    }

    func windowWillClose(_ notification: Notification) {
        openPanel?.cancel(nil)
        if operationTask != nil { cancelSearch() }
        else { invalidateOperation() }
    }

    override func cancelOperation(_ sender: Any?) {
        if operationTask != nil { cancelSearch() }
        else { close() }
    }

    private var selectedMatch: TraceMoeMatch? {
        matches.indices.contains(table.selectedRow) ? matches[table.selectedRow] : nil
    }

    private func meaningfulTitle(_ match: TraceMoeMatch) -> String? {
        let title = match.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title != match.filename.trimmingCharacters(in: .whitespacesAndNewlines),
              title.rangeOfCharacter(from: .letters) != nil,
              !title.contains("://") else { return nil }
        return title
    }

    private func previewURL(_ match: TraceMoeMatch) -> URL? {
        guard let url = match.videoURL, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), ["trace.moe", "api.trace.moe"].contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }

    private func updateActions() {
        let working = operationTask != nil
        uploadButton.isEnabled = jpeg != nil && !working
        cancelButton.isEnabled = working
        if working { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        let match = selectedMatch
        anilistButton.isEnabled = match.flatMap(\.anilistID).map { $0 > 0 } ?? false
        videoButton.isEnabled = match.flatMap { previewURL($0) } != nil
        searchButton.isEnabled = match.flatMap { meaningfulTitle($0) } != nil
        selectionStatus.stringValue = match.map { match in
            let title = meaningfulTitle(match) ?? String(localized: "未提供作品名稱；無法直接搜尋此作品。")
            let warning = match.similarity < 0.9 ? String(localized: "低信心：請核對作品與畫面。") : String(localized: "辨識結果僅供參考。")
            return String(localized: "\(title)\n\(metadata(match)) · \(warning)")
        } ?? String(localized: "選取結果以查看詳情與操作。")
        selectionStatus.toolTip = selectionStatus.stringValue
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let match = matches[row]
        let title = NSTextField(labelWithString: match.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = match.title
        let detail = NSTextField(labelWithString: metadata(match))
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let warning = NSTextField(labelWithString: match.similarity < 0.9
                                  ? String(localized: "低信心：相似度低於 90%，可能辨識錯誤。")
                                  : String(localized: "請核對作品與畫面。"))
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warning.textColor = match.similarity < 0.9 ? .systemOrange : .secondaryLabelColor
        let stack = NSStackView(views: [title, detail, warning])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        for label in [title, detail, warning] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.setAccessibilityLabel(String(localized: "\(match.title) · \(metadata(match)) · \(warning.stringValue)"))
        return stack
    }

    private func metadata(_ match: TraceMoeMatch) -> String {
        let episode = match.episode.map { String(localized: "集數：\($0)") } ?? String(localized: "集數未知")
        let similarity = min(1, max(0, match.similarity)).formatted(.percent.precision(.fractionLength(1)))
        return String(localized: "\(episode) · \(timestamp(match.from))–\(timestamp(match.to)) · 相似度 \(similarity)")
    }

    private func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let value = Int(seconds)
        return String(format: "%02lld:%02lld:%02lld", Int64(value / 3600), Int64(value / 60 % 60), Int64(value % 60))
    }

    @objc private func openAniList() {
        guard let id = selectedMatch?.anilistID, id > 0,
              let url = URL(string: "https://anilist.co/anime/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openVideo() {
        guard let match = selectedMatch, let url = previewURL(match) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openTerms() {
        guard let url = URL(string: "https://soruly.github.io/trace.moe-api/#/terms") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func searchSelectedTitle() {
        guard let match = selectedMatch, let title = meaningfulTitle(match) else { return }
        onSearchTitle(title)
    }
}
