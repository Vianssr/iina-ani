import AppKit

@MainActor
final class WorkspaceSkinManager: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    enum Action: Hashable { case preview, remove, exportOriginal, exportDerived, restore, importPackage, authorDirectory, reloadAuthor }
    var action: ((Action, SkinPackage?) -> Void)?
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: String(localized: "拖入 .iinaskin 可驗證並預覽；作者／授權是未驗證宣告。"))
    private var packages: [SkinPackage] = []
    private var buttons: [Action: NSButton] = [:]
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Skin 管理")
        window.minSize = NSSize(width: 760, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = SkinPackageDropView()
        content.onDrop = { [weak self] url in
            NotificationCenter.default.post(name: Self.packageDropped, object: self, userInfo: ["url": url])
        }
        window.contentView = content
        for (id, title, width) in [("name", String(localized: "名稱"), 210.0), ("version", String(localized: "版本"), 85.0),
                                   ("author", String(localized: "作者（未驗證）"), 190.0), ("license", String(localized: "授權"), 190.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(String(localized: "已安裝 Skin"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let primary = NSStackView(views: [button(String(localized: "預覽並套用…"), .preview), button(String(localized: "移除…"), .remove),
                                         button(String(localized: "匯出原包…"), .exportOriginal), button(String(localized: "匯出衍生包…"), .exportDerived),
                                         button(String(localized: "恢復內建…"), .restore)])
        let author = NSStackView(views: [button(String(localized: "匯入 .iinaskin…"), .importPackage),
                                        button(String(localized: "選取作者目錄…"), .authorDirectory), button(String(localized: "重新載入並預覽"), .reloadAuthor)])
        let stack = NSStackView(views: [scroll, primary, author, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    static let packageDropped = Notification.Name("WorkspaceSkinPackageDropped")
    private func button(_ title: String, _ operation: Action) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(operate(_:)))
        let icons: [Action: WorkspaceIcon] = [
            .preview: .appearance, .remove: .delete, .exportOriginal: .exportFile,
            .exportDerived: .exportFile, .restore: .refresh, .importPackage: .importFile,
            .authorDirectory: .folder, .reloadAuthor: .refresh,
        ]
        button.setFunctionIcon(icons[operation])
        button.identifier = NSUserInterfaceItemIdentifier(String(describing: operation))
        buttons[operation] = button
        return button
    }
    @objc private func operate(_ sender: NSButton) {
        let operations: [Action] = [.preview, .remove, .exportOriginal, .exportDerived, .restore, .importPackage, .authorDirectory, .reloadAuthor]
        guard let operation = operations.first(where: { String(describing: $0) == sender.identifier?.rawValue }) else { return }
        let index = table.selectedRow - 1
        action?(operation, packages.indices.contains(index) ? packages[index] : nil)
    }
    func reload(packages: [SkinPackage], selectedID: String?, authorDirectory: URL?) {
        self.packages = packages
        table.reloadData()
        let row = packages.firstIndex(where: { $0.manifest.id == selectedID }).map { $0 + 1 } ?? 0
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        buttons[.reloadAuthor]?.isEnabled = authorDirectory != nil
        buttons[.reloadAuthor]?.toolTip = authorDirectory == nil ? String(localized: "先選取作者目錄") : String(localized: "重新驗證作者目錄並隔離預覽")
        status.stringValue = authorDirectory.map { String(localized: "作者目錄：\($0.path)\n重新載入只建立驗證快照；取消不更動安裝、外觀或工作區。") }
            ?? String(localized: "拖入 .iinaskin 可驗證並預覽。內建外觀沒有可移除或匯出的包；請選取第三方 Skin。作者／授權是未驗證宣告。")
        updateSelectionActions()
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelectionActions() }
    private func updateSelectionActions() {
        let installed = table.selectedRow > 0
        for action in [Action.remove, .exportOriginal, .exportDerived] {
            buttons[action]?.isEnabled = installed
            buttons[action]?.toolTip = installed ? nil : String(localized: "內建外觀沒有第三方安裝包；請選取已安裝 Skin。")
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { packages.count + 1 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let key = tableColumn?.identifier.rawValue ?? "name"
        let value: String
        if row == 0 { value = key == "name" ? String(localized: "內建外觀") : "—" }
        else {
            let manifest = packages[row - 1].manifest
            switch key {
            case "version": value = manifest.version
            case "author": value = manifest.author ?? String(localized: "未聲明作者")
            case "license": value = manifest.license
            default: value = manifest.name
            }
        }
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        label.setAccessibilityLabel(value)
        return label
    }
}

@MainActor
private final class SkinPackageDropView: NSView {
    var onDrop: ((URL) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func packageURL(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let url = urls.first, url.pathExtension.lowercased() == "iinaskin" else { return nil }
        return url
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { packageURL(sender) == nil ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = packageURL(sender) else { return false }
        // Leave the drag session before entering the native review modal loop.
        Task { @MainActor [weak self] in self?.onDrop?(url) }
        return true
    }
}
