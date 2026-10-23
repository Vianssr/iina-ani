import AppKit
import SwiftUI
import SDWebImage

private final class WorkspaceSettingsDocumentStack: NSStackView {
    override var isFlipped: Bool { true }
}

private final class WorkspaceSettingsCategoryButton: WorkspaceNavigationButton {
    override var font: NSFont? { didSet { invalidateIntrinsicContentSize() } }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if let font { size.height = max(size.height, font.ascender - font.descender + 20) }
        return size
    }
}

private final class WorkspaceSettingsSearchField: NSSearchField {
    override var font: NSFont? { didSet { invalidateIntrinsicContentSize() } }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if let font { size.height = max(size.height, font.ascender - font.descender + 8) }
        return size
    }
}

/// Commands must call the existing Workspace/Skin owners. They retain their isolated preview,
/// explicit apply/cancel and recovery confirmations; this controller never saves a Layout/Skin.
@MainActor
struct WorkspaceSettingsCommands {
    let manageSkins: () -> Void
    let importSkin: () -> Void
    let colorScheme: () -> Void
    let personalAppearance: () -> Void
    let authorPreview: () -> Void
    let reloadAuthorPreview: () -> Void
    let exportOriginalSkin: () -> Void
    let exportDerivedSkin: () -> Void
    let applyAuthorLayout: () -> Void
    let removeSkin: () -> Void
    let restoreAppearance: () -> Void
    let editLayout: () -> Void
    let generateLayout: () -> Void
    let restoreLayout: () -> Void
}

@MainActor
final class WorkspaceSettingsController: NSViewController, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, WorkspaceDetachablePanel {
    private let services: AppServices
    private var prefs: Preferences { services.preferences }
    private var accounts: SiteAccounts { services.decoder.accounts }
    private let skin: SkinAppearance
    private let commands: WorkspaceSettingsCommands
    private let previewOnly: Bool
    private let categories = NSStackView()
    private var categoryButtons: [NSButton] = []
    private let search = WorkspaceSettingsSearchField()
    private let results = NSTableView()
    private let resultScroll = WorkspaceScrollView()
    private let contentScroll = WorkspaceScrollView()
    private let content = WorkspaceSettingsDocumentStack()
    private let status = NSTextField(wrappingLabelWithString: String(localized: "全域功能偏好即改即保存；Skin／Layout 個人外觀與組件覆寫分開保存。"))
    private var group: WorkspaceSettingsGroup = .appearance
    private var sectionHeadings: [WorkspaceSettingsGroup: NSView] = [:]
    private var rebuilding = false
    private var destinations: [WorkspaceSettingDestination] = []
    private var matches: [WorkspaceSettingDestination] = []
    private var rows: [String: NSView] = [:]
    private var targets: [String: NSView] = [:]
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var displayedAccounts: [String: SiteAccount] = [:]
    private var accountsLoaded = false
    private var attached = true
    private var focusedSettingID: String?
    private var accountRefresh: Task<Void, Never>?
    private var accountAction: Task<Void, Never>?
    private var busyAccountSource: String?
    private var cacheRefresh: Task<Void, Never>?
    private var subscriptionWindow: WorkspaceSourceSubscriptionController?
    private var cacheText: NSTextField?
    private var sheetController: NSViewController?

    init(delegate: AppDelegate, appearance: SkinAppearance, commands: WorkspaceSettingsCommands,
         previewOnly: Bool = false) {
        services = delegate.services
        skin = appearance
        self.commands = commands
        self.previewOnly = previewOnly
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { accountRefresh?.cancel(); accountAction?.cancel(); cacheRefresh?.cancel() }

    override func loadView() {
        view = NSView()
        view.bindSkin(skin, slot: "background", componentID: "settings.preferences")
        categories.orientation = .vertical
        categories.alignment = .width
        categories.spacing = 6
        categories.setAccessibilityLabel(String(localized: "設定分類"))
        for (index, group) in WorkspaceSettingsGroup.allCases.enumerated() {
            let button = WorkspaceSettingsCategoryButton(title: group.displayTitle, target: self, action: #selector(changeGroup(_:)))
            button.tag = index
            let icon: WorkspaceIcon
            switch group {
            case .appearance: icon = .appearance
            case .sources: icon = .account
            case .playback: icon = .play
            case .storage: icon = .downloads
            case .about: icon = .info
            }
            button.functionIconPosition = .imageLeading
            button.setFunctionIcon(icon, size: 18)
            button.bezelStyle = .regularSquare
            button.imageScaling = .scaleNone
            button.imageHugsTitle = true
            button.alignment = .left
            button.cell?.lineBreakMode = .byTruncatingTail
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            button.setAccessibilityIdentifier("settings.category.\(index)")
            button.toolTip = String(localized: "捲動至\(group.displayTitle)")
            button.bindSkin(skin, slot: "navigation", componentID: "settings.preferences")
            categories.addArrangedSubview(button)
            categoryButtons.append(button)
        }
        search.placeholderString = String(localized: "搜尋設定／同義詞…")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel(String(localized: "搜尋設定，選結果直接聚焦設定項"))
        search.bindSkin(skin, slot: "search", componentID: "settings.preferences")
        let header = NSStackView(views: [search])
        header.orientation = .horizontal
        let column = NSTableColumn(identifier: .init("setting"))
        results.addTableColumn(column)
        results.headerView = nil
        results.dataSource = self
        results.delegate = self
        results.target = self
        results.action = #selector(chooseResult)
        results.setAccessibilityLabel(String(localized: "設定搜尋結果"))
        results.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        resultScroll.documentView = results
        resultScroll.hasVerticalScroller = true
        resultScroll.isHidden = true
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        content.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.documentView = content
        contentScroll.hasVerticalScroller = true
        contentScroll.drawsBackground = false
        contentScroll.setAccessibilityIdentifier("settings.document")
        contentScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: contentScroll.contentView)
        status.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        status.setAccessibilityIdentifier("settings.status")
        let stack = NSStackView(views: [header, resultScroll, contentScroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let body = NSView()
        categories.translatesAutoresizingMaskIntoConstraints = false
        let categoryWidth: CGFloat = 176
        let preferredCategoryWidth = categories.widthAnchor.constraint(equalToConstant: categoryWidth)
        preferredCategoryWidth.priority = .defaultHigh
        preferredCategoryWidth.isActive = true
        for button in categoryButtons {
            button.widthAnchor.constraint(equalTo: categories.widthAnchor).isActive = true
        }
        body.addSubview(categories)
        body.addSubview(stack)
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            stack.heightAnchor.constraint(equalTo: body.heightAnchor),
            categories.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            categories.topAnchor.constraint(equalTo: body.topAnchor),
            stack.topAnchor.constraint(equalTo: body.topAnchor),
            stack.leadingAnchor.constraint(equalTo: categories.trailingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            categories.widthAnchor.constraint(greaterThanOrEqualToConstant: categoryWidth),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            resultScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultScroll.heightAnchor.constraint(equalToConstant: 130),
            contentScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            content.widthAnchor.constraint(equalTo: contentScroll.contentView.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        rebuild()
        refreshAccounts()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshAccounts()
        rebuild()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        synchronizeCategory()
    }

    func focusSearch(_ query: String = "") {
        _ = view
        focusedSettingID = nil
        search.stringValue = query
        updateSearch()
        view.window?.makeFirstResponder(search)
    }

    @discardableResult
    func focusSetting(_ id: String) -> Bool {
        _ = view
        guard let destination = destinations.first(where: { $0.id == id }) else { return false }
        clearSettingFocus()
        focusedSettingID = id
        search.stringValue = ""
        updateSearch()
        let focused = restoreSettingFocus()
        if focused { status.stringValue = String(localized: "已定位：\(destination.group.displayTitle) → \(destination.title)") }
        return focused
    }

    @discardableResult
    private func restoreSettingFocus() -> Bool {
        guard attached, let id = focusedSettingID, let row = rows[id], let target = targets[id],
              let window = view.window else { return false }
        view.layoutSubtreeIfNeeded()
        scrollContent(to: NSPoint(x: 0, y: max(0, row.frame.minY - 8)))
        synchronizeCategory()
        guard window.makeFirstResponder(target) else { return false }
        row.workspaceSkinBinding?.state = .focus
        NSAccessibility.post(element: target, notification: .focusedUIElementChanged)
        return true
    }

    private func clearSettingFocus() {
        if let id = focusedSettingID { rows[id]?.workspaceSkinBinding?.state = .normal }
        focusedSettingID = nil
    }

    @objc private func changeGroup(_ sender: NSButton) {
        clearSettingFocus()
        let destination = WorkspaceSettingsGroup.allCases[sender.tag]
        search.stringValue = ""
        updateSearch()
        view.layoutSubtreeIfNeeded()
        guard let heading = sectionHeadings[destination] else { return }
        scrollContent(to: NSPoint(x: 0, y: max(0, heading.frame.minY - 16)))
        synchronizeCategory()
        status.stringValue = String(localized: "\(destination.displayTitle)；全域功能偏好即改即保存，外觀與佈局另行預覽及套用。")
    }

    private func scrollContent(to origin: NSPoint) {
        let clip = contentScroll.contentView
        var proposed = clip.bounds
        proposed.origin = origin
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        contentScroll.reflectScrolledClipView(clip)
    }

    @objc private func contentBoundsChanged() {
        synchronizeCategory()
    }

    private func synchronizeCategory() {
        guard !rebuilding, !sectionHeadings.isEmpty else { return }
        let visible = contentScroll.contentView.documentVisibleRect
        let ordered = WorkspaceSettingsGroup.allCases
        // A short final section cannot reach the top; reaching the page bottom still selects it.
        if visible.height < content.bounds.height, visible.maxY >= content.bounds.maxY - 1 {
            group = ordered.last!
        } else {
            group = ordered.last(where: { (sectionHeadings[$0]?.frame.minY ?? .greatestFiniteMagnitude) <= visible.minY + 16 }) ?? .appearance
        }
        for button in categoryButtons {
            let selected = ordered[button.tag] == group
            button.state = selected ? .on : .off
            button.setAccessibilityValue(selected ? String(localized: "已選取") : String(localized: "未選取"))
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === search { focusedSettingID = nil; updateSearch() }
        else if field.formatter == nil { invokeSettingCommand(field) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)), let first = matches.first {
            return focusSetting(first.id)
        }
        if selector == #selector(NSResponder.moveDown(_:)), !matches.isEmpty {
            results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            view.window?.makeFirstResponder(results)
            return true
        }
        return false
    }
    private func updateSearch() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasSearching = !resultScroll.isHidden
        matches = query.isEmpty ? [] : destinations.filter { $0.matches(query) }
        resultScroll.isHidden = query.isEmpty
        results.reloadData()
        if query.isEmpty && wasSearching {
            status.stringValue = String(localized: "全域功能偏好即改即保存；Skin／Layout 個人外觀與組件覆寫分開保存。")
        }
        if !query.isEmpty { status.stringValue = matches.isEmpty ? String(localized: "沒有符合的設定；可用播放器、登入、皮膚、快取等同義詞搜尋。") : String(localized: "\(matches.count) 個設定；選取結果直接聚焦，Enter 聚焦第一項。") }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let match = matches[row]
        let label = NSTextField(labelWithString: "\(match.group.displayTitle) → \(match.title)")
        label.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        return label
    }
    @objc private func chooseResult() {
        let index = results.selectedRow
        guard matches.indices.contains(index) else { return }
        focusSetting(matches[index].id)
    }
    @objc private func invokeSettingCommand(_ sender: NSControl) {
        guard !previewOnly else { return }
        actions[ObjectIdentifier(sender)]?()
    }

    private func button(_ title: String, icon: WorkspaceIcon? = nil, action: @escaping () -> Void) -> NSButton {
        let button = WorkspaceSkinButton(title: title, target: self, action: #selector(invokeSettingCommand(_:)))
        button.setFunctionIcon(icon)
        button.bezelStyle = .rounded
        button.bindSkin(skin, slot: "primaryAction", componentID: "settings.preferences")
        actions[ObjectIdentifier(button)] = action
        return button
    }
    private func toggle(_ value: Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let control = button(String(localized: "啟用")) { }
        control.setButtonType(.switch)
        control.state = value ? .on : .off
        actions[ObjectIdentifier(control)] = { [weak control] in
            guard let control else { return }
            set(control.state == .on)
        }
        return control
    }
    private func text(_ value: String, set: @escaping (String) -> Void) -> NSTextField {
        let field = NSTextField(string: value)
        field.delegate = self
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        field.target = self
        field.action = #selector(invokeSettingCommand(_:))
        field.bindSkin(skin, slot: "search", componentID: "settings.preferences")
        actions[ObjectIdentifier(field)] = { [weak field] in if let field { set(field.stringValue) } }
        return field
    }
    private func number(_ value: Double, minimum: Double, maximum: Double, integer: Bool = true,
                        set: @escaping (Double) -> Void) -> NSTextField {
        let field = text(String(value)) { _ in }
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: minimum)
        formatter.maximum = NSNumber(value: maximum)
        formatter.allowsFloats = !integer
        formatter.maximumFractionDigits = integer ? 0 : 2
        formatter.usesGroupingSeparator = false
        field.formatter = formatter
        field.doubleValue = value
        actions[ObjectIdentifier(field)] = { [weak field] in if let field { set(field.doubleValue) } }
        return field
    }
    private func popup(_ titles: [String], selected: Int, set: @escaping (Int) -> Void) -> NSPopUpButton {
        let control = NSPopUpButton()
        control.addItems(withTitles: titles)
        control.selectItem(at: selected)
        control.target = self
        control.action = #selector(invokeSettingCommand(_:))
        control.bindSkin(skin, slot: "tabs", componentID: "settings.preferences")
        actions[ObjectIdentifier(control)] = { [weak control] in if let control { set(control.indexOfSelectedItem) } }
        return control
    }
    private func add(_ id: String, _ category: WorkspaceSettingsGroup, _ title: String,
                     _ aliases: String, _ help: String, showsHeading: Bool = true,
                     accessibilityID: String? = nil,
                     control makeControl: () -> NSView) {
        destinations.append(.init(id: id, group: category, title: title, aliases: aliases))
        // Every category shares this document; category controls only move its viewport.
        let control = makeControl()
        if previewOnly, let native = control as? NSControl { native.isEnabled = false }
        control.setAccessibilityIdentifier(accessibilityID ?? "settings.\(id)")
        control.setAccessibilityLabel(title)
        control.toolTip = help
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        let row = NSStackView(views: showsHeading ? [heading, control] : [control])
        row.orientation = help.isEmpty ? .horizontal : .vertical
        row.alignment = help.isEmpty ? .centerY : .leading
        row.spacing = 12
        row.edgeInsets = showsHeading ? NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            : NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        row.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        content.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            control.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, constant: showsHeading ? -24 : 0)
        ])
        if !showsHeading { control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
        if !help.isEmpty {
            let explanation = NSTextField(wrappingLabelWithString: help)
            explanation.bindSkin(skin, slot: "list", componentID: "settings.preferences")
            row.addArrangedSubview(explanation)
            NSLayoutConstraint.activate([
                heading.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -24),
                explanation.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -24)
            ])
        }
        if let field = control as? NSTextField, field.isEditable {
            field.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -24).isActive = true
        }
        rows[id] = row
        targets[id] = (control as? NSStackView)?.arrangedSubviews.first(where: { $0 is NSButton }) ?? control
    }
    private func info(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.isSelectable = true
        label.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        return label
    }
    private func execute(_ work: @escaping () async throws -> Void) {
        guard !previewOnly, attached else { return }
        Task { [weak self] in
            do {
                try await work()
                self?.status.stringValue = String(localized: "已保存；既有資料與活動任務由原服務繼續管理。")
                self?.refreshAccounts()
            } catch {
                self?.status.stringValue = error.localizedDescription
                self?.rebuild()
            }
        }
    }
    private func confirm(_ title: String, detail: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "繼續"))
        alert.addButton(withTitle: String(localized: "取消"))
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { action() } }
        } else if alert.runModal() == .alertFirstButtonReturn { action() }
    }

    private func rebuild() {
        let scrollOrigin = contentScroll.contentView.bounds.origin
        var restoreFocus = false
        rebuilding = true
        if let responder = view.window?.firstResponder as? NSView {
            let editingField = (responder as? NSTextView)?.delegate as? NSTextField
            if let setting = targets.first(where: { $0.value === responder || $0.value === editingField }) {
                focusedSettingID = setting.key
                restoreFocus = true
            }
        }
        sectionHeadings.removeAll(keepingCapacity: true)
        for row in content.arrangedSubviews { content.removeArrangedSubview(row); row.removeFromSuperview() }
        destinations.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)
        targets.removeAll(keepingCapacity: true)
        actions.removeAll(keepingCapacity: true)
        cacheText = nil
        for category in WorkspaceSettingsGroup.allCases {
            if let previous = content.arrangedSubviews.last { content.setCustomSpacing(28, after: previous) }
            let heading = NSTextField(labelWithString: category.displayTitle)
            heading.bindSkin(skin, slot: "header", componentID: "settings.preferences")
            heading.font = NSFontManager.shared.convert(heading.font ?? .systemFont(ofSize: 15), toHaveTrait: .boldFontMask)
            heading.setAccessibilityIdentifier("settings.section.\(category)")
            content.addArrangedSubview(heading)
            heading.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
            sectionHeadings[category] = heading
            switch category {
            case .appearance: appearanceSettings()
            case .sources: sourceSettings()
            case .playback: playbackSettings()
            case .storage: storageSettings()
            case .about: aboutSettings()
            }
        }
        updateSearch()
        view.layoutSubtreeIfNeeded()
        if restoreFocus, search.stringValue.isEmpty { restoreSettingFocus() }
        scrollContent(to: scrollOrigin)
        rebuilding = false
        synchronizeCategory()
    }
    private func appearanceSettings() {
        add("language", .appearance, String(localized: "App Language"),
            "language system default english simplified traditional chinese 语言 語言 简体 繁體 简体中文 繁體中文 英语 英語 系统默认 系統預設",
            String(localized: "Language changes take effect the next time you open IINA-ANI. Playback and downloads continue uninterrupted.")) {
            popup(AppLanguage.allCases.map(\.displayTitle),
                  selected: AppLanguage.allCases.firstIndex(of: prefs.appLanguage) ?? 0) { [weak self] index in
                guard let self else { return }
                self.prefs.appLanguage = AppLanguage.allCases[index]
                self.status.stringValue = String(localized: "Language saved. The new language will be used next launch; playback and downloads are not interrupted.")
            }
        }
        detailTransitionSettings()
        add("detail.comments.presentation", .appearance, String(localized: "詳情評論顯示方式"),
            "detail comments vertical horizontal list cards automatic manual load scroll 詳情 详情 評論 评论 垂直 縱向 纵向 橫向 横向 列表 卡片 自動 自动 手動 手动 載入 加载",
            String(localized: "預設以垂直列表顯示評論，捲動到底部時自動載入更多；也可選擇橫向卡片並手動載入。"),
            accessibilityID: "detail.comments.presentation") {
            popup([String(localized: "垂直列表（自動載入）"), String(localized: "橫向卡片（手動載入）")],
                  selected: prefs.detailCommentsVertical ? 0 : 1) { [weak self] index in
                self?.prefs.detailCommentsVertical = index == 0
            }
        }
        let entries: [(String, String, String, () -> Void)] = [
            ("skin.manage", String(localized: "Skin 管理與預覽"), "skin theme 皮肤 主題 換皮", commands.manageSkins),
            ("skin.import", String(localized: "匯入 .iinaskin"), "import 安装 導入", commands.importSkin),
            ("skin.scheme", String(localized: "明暗模式"), "dark light system 深色 淺色 系统", commands.colorScheme),
            ("skin.personal", String(localized: "個人字級與密度"), "font text size density 字体 放大 緊湊", commands.personalAppearance),
            ("skin.author", String(localized: "選取作者目錄並預覽"), "author directory 作者", commands.authorPreview),
            ("skin.reload", String(localized: "重載作者目錄並預覽"), "reload refresh 重新載入", commands.reloadAuthorPreview),
            ("skin.exportOriginal", String(localized: "匯出作者原包"), "export share 分享 导出", commands.exportOriginalSkin),
            ("skin.exportDerived", String(localized: "匯出個人外觀與選定佈局"), "export share layout 分享 导出", commands.exportDerivedSkin),
            ("skin.authorLayout", String(localized: "預覽並套用作者佈局"), "layout preview apply 布局", commands.applyAuthorLayout),
            ("skin.remove", String(localized: "移除目前 Skin"), "remove delete 删除", commands.removeSkin),
            ("skin.restore", String(localized: "恢復內建外觀"), "reset restore recovery 恢复 重設", commands.restoreAppearance),
            ("layout.edit", String(localized: "編輯佈局與組件"), "layout components drag undo redo 拖曳 撤銷 重做", commands.editLayout),
            ("layout.generate", String(localized: "受限 JavaScript 佈局生成"), "script javascript generate 腳本", commands.generateLayout),
            ("layout.restore", String(localized: "恢復內建佈局"), "reset restore recovery 恢复 重設", commands.restoreLayout)
        ]
        let icons: [String: WorkspaceIcon] = [
            "skin.manage": .appearance, "skin.import": .importFile, "skin.scheme": .appearance,
            "skin.personal": .settings, "skin.author": .folder, "skin.reload": .refresh,
            "skin.exportOriginal": .exportFile, "skin.exportDerived": .exportFile,
            "skin.authorLayout": .layout, "skin.remove": .delete, "skin.restore": .refresh,
            "layout.edit": .layout, "layout.generate": .layout, "layout.restore": .refresh,
        ]
        let appearanceNote = NSTextField(wrappingLabelWithString: String(localized: "先預覽，再決定。外觀與佈局調整不會影響收藏、帳號或下載。"))
        appearanceNote.font = .systemFont(ofSize: 12)
        appearanceNote.textColor = .secondaryLabelColor
        appearanceNote.isSelectable = true
        appearanceNote.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        content.addArrangedSubview(appearanceNote)
        appearanceNote.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        for (id, title, aliases, command) in entries {
            add(id, .appearance, title, aliases, "", showsHeading: false) {
                let control = WorkspaceNavigationButton(title: "\(title)…", target: self, action: #selector(invokeSettingCommand(_:)))
                control.setFunctionIcon(icons[id], size: 18)
                control.alignment = .left
                control.bezelStyle = .regularSquare
                control.cell?.lineBreakMode = .byTruncatingTail
                control.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
                control.bindSkin(skin, slot: "navigation", componentID: "settings.preferences")
                actions[ObjectIdentifier(control)] = command
                return control
            }
        }
        for capability in WorkspaceCapability.allCases where capability.canDisable && capability != .downloads {
            add("capability.\(capability.rawValue)", .appearance, capability.title, "enable disable 功能 停用",
                String(localized: "全域功能，不是隱藏組件。依賴：\(capability.dependencies.map(\.title).sorted().joined(separator: "、"))；停用不刪資料。")) {
                toggle(services.capabilityEnabled(capability)) { [weak self] enabled in
                    guard let self else { return }
                    execute { try await self.services.setCapability(capability, enabled: enabled) }
                }
            }
        }
        let colors: [(String, String, ReferenceWritableKeyPath<Preferences, NSColor>)] = [
            ("living", String(localized: "直播中"), \.stateLiving), ("offline", String(localized: "離線"), \.stateOffline),
            ("replay", String(localized: "重播"), \.stateReplay), ("unknown", String(localized: "未知"), \.stateUnknown)
        ]
        for (id, title, keyPath) in colors {
            add("status.\(id)", .appearance, String(localized: "\(title)狀態色"), "live status color 直播 狀態 顏色", String(localized: "全域直播狀態色；狀態同時以文字呈現，不僅靠顏色識別。")) {
                let control = NSColorWell()
                control.color = prefs[keyPath: keyPath]
                control.target = self
                control.action = #selector(invokeSettingCommand(_:))
                actions[ObjectIdentifier(control)] = { [weak self, weak control] in
                    guard let self, let control else { return }
                    self.prefs[keyPath: keyPath] = control.color
                }
                return control
            }
        }
    }

    private func detailTransitionSettings() {
        let settings = prefs.detailTransition
        add("detail.transition.style", .appearance, String(localized: "詳情頁開啟動畫"),
            "detail preview transition animation cover cinema netflix iris 動畫 动画 詳情 详情 預覽 预览 封面 影院 光圈",
            String(localized: "封面從點選位置滑動放大；影院效果將封面推近並降低 gamma；光圈從封面中心展開。動畫結束時顯示詳情預覽；系統開啟減少動態效果時直接顯示。"),
            accessibilityID: "detail.transition.style") {
            popup(WorkspaceDetailTransitionStyle.allCases.map(\.displayTitle),
                  selected: WorkspaceDetailTransitionStyle.allCases.firstIndex(of: settings.style) ?? 1) { [weak self] index in
                guard WorkspaceDetailTransitionStyle.allCases.indices.contains(index) else { return }
                self?.saveDetailTransition { $0.style = WorkspaceDetailTransitionStyle.allCases[index] }
            }
        }
        add("detail.transition.curve", .appearance, String(localized: "動畫速率曲線"),
            "detail transition animation curve easing ease nonlinear 非勻速 非匀速 曲線 曲线 緩動 缓动",
            String(localized: "三種曲線都採用非勻速變化，控制動畫的起步、推進與停靠節奏。"),
            accessibilityID: "detail.transition.curve") {
            popup(WorkspaceDetailTransitionCurve.allCases.map(\.displayTitle),
                  selected: WorkspaceDetailTransitionCurve.allCases.firstIndex(of: settings.curve) ?? 0) { [weak self] index in
                guard WorkspaceDetailTransitionCurve.allCases.indices.contains(index) else { return }
                self?.saveDetailTransition { $0.curve = WorkspaceDetailTransitionCurve.allCases[index] }
            }
        }
        add("detail.transition.duration", .appearance, String(localized: "動畫時長（秒）"),
            "detail transition animation duration speed 動畫 动画 速度 時長 时长 秒",
            String(localized: "可調整為 0.2–1.8 秒；設定即改即保存，下次開啟作品時生效。"),
            accessibilityID: "detail.transition.duration") {
            number(settings.duration, minimum: 0.2, maximum: 1.8, integer: false) { [weak self] value in
                self?.saveDetailTransition { $0.duration = value }
            }
        }
        add("detail.transition.gamma", .appearance, String(localized: "影院效果 gamma"),
            "detail transition cinema netflix gamma brightness 影院 亮度 伽瑪 伽玛",
            String(localized: "僅影響影院推近效果，範圍 0.35–1；低於 1 會提亮中間調，再疊加暗色遮罩形成影院對比。"),
            accessibilityID: "detail.transition.gamma") {
            number(settings.gamma, minimum: 0.35, maximum: 1, integer: false) { [weak self] value in
                self?.saveDetailTransition { $0.gamma = value }
            }
        }
        add("detail.transition.zoom", .appearance, String(localized: "影院效果放大倍率"),
            "detail transition cinema netflix zoom scale 影院 放大 倍率 縮放 缩放",
            String(localized: "僅影響影院推近效果，範圍 1.05–1.5 倍；較大的倍率會帶來更明顯的推近。"),
            accessibilityID: "detail.transition.zoom") {
            number(settings.zoom, minimum: 1.05, maximum: 1.5, integer: false) { [weak self] value in
                self?.saveDetailTransition { $0.zoom = value }
            }
        }
    }

    private func saveDetailTransition(_ update: (inout WorkspaceDetailTransitionSettings) -> Void) {
        var settings = prefs.detailTransition
        update(&settings)
        prefs.detailTransition = settings
        status.stringValue = String(localized: "詳情頁動畫已保存，下次開啟作品時生效。")
    }

    private func sourceSettings() {
        add("subscription.manage", .sources, String(localized: "來源訂閱"), "css1 subscription anime check update preview apply 訂閱 番劇 檢查 更新 預覽 套用", String(localized: "在獨立視窗檢查、預覽與套用 css1 來源訂閱。")) {
            button(String(localized: "來源訂閱…"), icon: .subscription) { [weak self] in self?.showSubscription() }
        }
        for (source, title) in [("bilibili", "Bilibili"), ("douyu", String(localized: "鬥魚")), ("bangumi", "Bangumi")] {
            add("account.\(source)", .sources, title, "\(source) login logout account auth 登入 登录 登出 帳號 授權", "") {
                let account = displayedAccounts[source]
                let loggedIn = account?.enabled == true && account?.status == .valid
                let state: String
                if previewOnly { state = String(localized: "隔離預覽") }
                else if !accountsLoaded { state = String(localized: "讀取中…") }
                else if loggedIn { state = String(localized: "已登入") }
                else if account?.enabled == true && account?.status == .expired { state = String(localized: "登入已失效") }
                else { state = String(localized: "未登入") }
                let label = info(loggedIn ? "\(state) · \(account?.displayName ?? title)" : state)
                var controls: [NSView] = [label]
                if !loggedIn {
                    let login = button(String(localized: "登入…"), icon: .account) { [weak self] in self?.login(source: source) }
                    login.isEnabled = !previewOnly && accountsLoaded && busyAccountSource == nil
                    controls.append(login)
                }
                if let account, account.status != .needsLogin {
                    let logout = button(String(localized: "登出"), icon: .account) { [weak self] in self?.signOut(account) }
                    logout.isEnabled = !previewOnly && busyAccountSource == nil
                    controls.append(logout)
                }
                let row = NSStackView(views: controls)
                row.orientation = .horizontal
                row.spacing = 12
                return row
            }
        }
    }

    private func showSubscription() {
        guard !previewOnly, attached, let parent = view.window else { return }
        if let subscriptionWindow { subscriptionWindow.showWindow(nil); subscriptionWindow.window?.makeKeyAndOrderFront(nil); return }
        let controller = WorkspaceSourceSubscriptionController(service: services.sourceSubscription, skin: skin)
        controller.onClose = { [weak self] in self?.subscriptionWindow = nil }
        subscriptionWindow = controller
        if let window = controller.window { parent.addChildWindow(window, ordered: .above) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func login(source: String) {
        guard !previewOnly, attached, accountAction == nil, sheetController == nil else { return }
        if source == "bangumi" { showBangumi(); return }
        busyAccountSource = source
        rebuild()
        let service = accounts
        accountAction = Task { [weak self] in
            guard let self else { return }
            defer { accountAction = nil; busyAccountSource = nil; if attached { rebuild() } }
            do {
                let existing: SiteAccount?
                if let current = try await service.defaultAccount(sourceID: source) { existing = current }
                else { existing = try await service.accounts(sourceID: source).first { $0.enabled && $0.status == .needsLogin } }
                try Task.checkCancellation()
                let account: SiteAccount
                if let existing { account = existing }
                else { account = try await service.add(sourceID: source, displayName: source) }
                try Task.checkCancellation()
                guard attached else { return }
                if !account.enabled { try await service.setEnabled(accountID: account.id, enabled: true) }
                try Task.checkCancellation()
                guard attached else { return }
                displayedAccounts[source] = account
                showLogin(account)
            } catch is CancellationError {
            } catch {
                guard attached else { return }
                status.stringValue = accountError(error)
            }
        }
    }

    private func signOut(_ account: SiteAccount) {
        guard !previewOnly, attached, accountAction == nil else { return }
        busyAccountSource = account.sourceID
        rebuild()
        let service = accounts
        accountAction = Task { [weak self] in
            guard let self else { return }
            defer { accountAction = nil; busyAccountSource = nil; if attached { rebuild() } }
            do {
                try Task.checkCancellation()
                try await service.signOut(accountID: account.id)
                guard !Task.isCancelled, attached else { return }
                status.stringValue = String(localized: "已登出；收藏與活動任務未變更。")
                refreshAccounts()
            } catch is CancellationError {
            } catch {
                guard attached else { return }
                status.stringValue = accountError(error)
            }
        }
    }

    private func accountError(_ error: Error) -> String {
        if let accountError = error as? SiteAccountError, case .accountInUse = accountError {
            return String(localized: "帳號正由播放或下載使用，暫時無法登出或重新登入。")
        }
        return error.localizedDescription
    }


    private func playbackSettings() {
        add("playback.player", .playback, String(localized: "外部播放器"), "player iina mpv 播放器", String(localized: "全域預設播放器；下一次播放使用此選擇，不中斷現有視窗。")) {
            popup(LivePlayer.allCases.map(\.name), selected: prefs.livePlayer.index()) { [weak self] index in self?.prefs.livePlayer = LivePlayer(index: index) }
        }
        add("playback.mpv", .playback, String(localized: "mpv 執行檔路徑"), "mpv path executable 路径", String(localized: "沿用既有自訂 mpv 路徑；空白使用既有預設搜尋方式。")) {
            text(prefs.customMpvPath) { [weak self] in self?.prefs.customMpvPath = $0 }
        }
        add("playback.jsPlayer", .playback, String(localized: "內建 JSPlayer"), "jsplayer flvjs web 內建 網頁", String(localized: "啟用既有支援來源的 WebKit 播放路徑；不替不支援來源製造假能力。")) {
            toggle(prefs.enableFlvjs) { [weak self] in self?.prefs.enableFlvjs = $0 }
        }
        add("playback.autoOpen", .playback, String(localized: "自動開啟解析結果"), "auto open 自動", String(localized: "沿用既有解析結果自動開啟偏好。")) {
            toggle(prefs.autoOpenResult) { [weak self] in self?.prefs.autoOpenResult = $0 }
        }
        add("playback.autoPlayNext", .playback, String(localized: "同源自動連播"), "autoplay next episode 連播 连播 下一集 在線 本地", String(localized: "自然播完後接續同來源、同目錄分組的下一集；本地會載入同資料夾完整影片隊列，此開關控制是否自動換集，仍可在播放器內手動選集。停止、關閉或錯誤不續播，不跨站或切換在線／本地。")) {
            toggle(prefs.autoPlayNext) { [weak self] in self?.prefs.autoPlayNext = $0 }
        }
        add("playback.quality", .playback, String(localized: "品質／線路與編碼"), "quality resolution 清晰度 畫質 画质 codec av1 hevc avc", String(localized: "品質及線路依各影片可得選項在詳情就地選擇，與下載共用同一選擇；此處是既有 Bilibili 點播編碼偏好，不是虛構全站品質。")) {
            popup(["AV1", "HEVC", "AVC"], selected: prefs.bilibiliCodec) { [weak self] in self?.prefs.bilibiliCodec = $0 }
        }
        add("playback.biliLiveHevc", .playback, String(localized: "Bilibili 直播 HEVC"), "bilibili live hevc 编碼", String(localized: "沿用既有直播解碼偏好。")) {
            toggle(prefs.bililiveHevc) { [weak self] in self?.prefs.bililiveHevc = $0 }
        }
        add("playback.biliHTML", .playback, String(localized: "Bilibili HTML 解析"), "bilibili decoder html 解碼", String(localized: "沿用既有 Bilibili HTML decoder 偏好。")) {
            toggle(prefs.bilibiliHTMLDecoder) { [weak self] in self?.prefs.bilibiliHTMLDecoder = $0 }
        }
        add("danmaku.enabled", .playback, String(localized: "彈幕開關"), "danmaku comments 弹幕", String(localized: "既有彈幕偏好；不把隱藏組件誤當停用業務服務。外部播放器的既有活動生命週期保持不變。")) {
            toggle(prefs.enableDanmaku) { [weak self] in self?.prefs.enableDanmaku = $0 }
        }
        add("danmaku.plugin", .playback, String(localized: "IINA 彈幕外掛"), "plugin install iina 外掛 插件", String(localized: "使用既有外掛安裝／設定流程。")) {
            button(String(localized: "外掛設定…"), icon: .danmaku) { [weak self] in self?.showPlugin() }
        }
        add("danmaku.port", .playback, String(localized: "本機彈幕埠"), "port server 端口", String(localized: "1024–65535；沿用現有 HTTP 服務啟動／播放器行為，不另建伺服器。")) {
            number(Double(prefs.dmPort), minimum: 1024, maximum: 65535) { [weak self] in self?.prefs.dmPort = Int($0) }
        }
        add("danmaku.browserTest", .playback, String(localized: "瀏覽器彈幕測試"), "browser demo test 瀏覽器 測試", String(localized: "開啟既有本機彈幕測試頁；沿用目前實際綁定的服務埠。")) {
            button(String(localized: "開啟測試頁"), icon: .openLink) { [weak self] in
                guard let self else { return }
                execute {
                    let endpoint = try await self.services.httpServer.start()
                    let url = endpoint.baseURL.appendingPathComponent("danmaku/test.htm")
                    guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
                }
            }
        }
        add("danmaku.font", .playback, String(localized: "彈幕字型"), "font 字体", String(localized: "既有彈幕字型偏好；套用時機沿用播放端。")) {
            text(prefs.danmukuFontFamilyName) { [weak self] in self?.prefs.danmukuFontFamilyName = $0 }
        }
        add("danmaku.weight", .playback, String(localized: "彈幕字重"), "font weight 粗細", String(localized: "既有字重名称，例如 Regular／Bold；不改字級固定的原行為。")) {
            text(prefs.danmukuFontWeight) { [weak self] in self?.prefs.danmukuFontWeight = $0 }
        }
        add("danmaku.speed", .playback, String(localized: "彈幕速度"), "speed 弹幕 速度", String(localized: "沿用既有 dmSpeed。")) {
            number(prefs.dmSpeed, minimum: 100, maximum: 2000) { [weak self] in self?.prefs.dmSpeed = $0 }
        }
        add("danmaku.opacity", .playback, String(localized: "彈幕透明度"), "opacity alpha 透明 不透明", String(localized: "0–1；沿用既有 dmOpacity。")) {
            number(prefs.dmOpacity, minimum: 0, maximum: 1, integer: false) { [weak self] in self?.prefs.dmOpacity = $0 }
        }
    }

    private func storageSettings() {
        add("download.directory", .storage, String(localized: "下載目錄"), "directory folder path 路径 位置 資料夾", String(localized: "目前：\(prefs.downloadDirectory.path)\n改目錄只影響新任務；既有任務及完成檔保持原位置，保存 security-scoped bookmark。")) {
            button(String(localized: "選擇下載目錄…"), icon: .folder) { [weak self] in
                guard let self else { return }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.directoryURL = prefs.downloadDirectory
                let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    guard response == .OK, let url = panel.url, let self else { return }
                    self.prefs.downloadDirectory = url
                    self.rebuild()
                }
                if let window = view.window { panel.beginSheetModal(for: window, completionHandler: complete) }
                else { complete(panel.runModal()) }
            }
        }
        add("download.concurrency", .storage, String(localized: "下載併發數"), "concurrency parallel 並行 并发", String(localized: "1–8；使用同一 DownloadService 排程策略。現有工作不重新建任務。")) {
            number(Double(prefs.downloadConcurrencyLimit), minimum: 1, maximum: 8) { [weak self] in self?.prefs.downloadConcurrencyLimit = Int($0) }
        }
        add("download.enabled", .storage, String(localized: "新增／恢復下載"), "disable enable 停用 下載", String(localized: "活動下載與匯入阻擋停用並列出原因；既有任務管理不可停用。")) {
            toggle(services.capabilityEnabled(.downloads)) { [weak self] enabled in
                guard let self else { return }
                execute { try await self.services.setCapability(.downloads, enabled: enabled) }
            }
        }
        add("torrent.uploadLimit", .storage, String(localized: "Torrent 上傳限速"), "torrent bt p2p upload speed 限速 上传", String(localized: "1–10485760 bytes/s；更新實際活動傳輸上限後才保存。既有任務較低的限制仍受尊重；不在此默認同意首次 P2P 上傳。")) {
            number(Double(prefs.torrentUploadLimitBytesPerSecond), minimum: 1, maximum: 10485760) { [weak self] value in
                guard let self else { return }
                execute {
                    try await self.services.downloads().setTorrentUploadLimit(UInt32(value))
                    self.prefs.torrentUploadLimitBytesPerSecond = UInt32(value)
                }
            }
        }
        add("torrent.stop", .storage, String(localized: "停止 Torrent 傳輸"), "torrent bt p2p stop upload 停止 上传", String(localized: "停止播放 reader、撤銷串流授權、取消 metadata 匯入並暫停 Torrent 任務；保留已下載檔案，不影響非 Torrent 下載。")) {
            button(String(localized: "停止 Torrent 傳輸…"), icon: .stop) { [weak self] in
                self?.confirm(String(localized: "停止所有 Torrent 傳輸？"), detail: String(localized: "Torrent 播放會停止，任務暫停；已下載資料保留，可稍後恢復。")) { [weak self] in
                    guard let self else { return }
                    execute {
                        await self.services.player.stopTorrentPlayers()
                        try await self.services.downloads().stopTorrentTransfers()
                    }
                }
            }
        }
        add("cache.usage", .storage, String(localized: "快取用量與保護範圍"), "cache usage size space 缓存 容量 用量", String(localized: "可清理：封面／表情與 metadata。保護：活動下載暫存、Torrent 私有資料、收藏、帳號與完成檔。用量來自既有 owned-cache 服務，不含任意目錄。")) {
            let label = info(previewOnly ? String(localized: "隔離預覽不讀取私人快取用量。") : String(localized: "正在讀取本機用量…"))
            cacheText = label
            refreshCache()
            return label
        }
        add("cache.limit", .storage, String(localized: "可重建快取上限（MiB）"), "cache maximum limit 缓存 上限", String(localized: "只對封面／表情與 metadata 計量；不刪下載或私人資料。0 表示不保留可重建快取。")) {
            if previewOnly { return info(String(localized: "隔離預覽不讀取／修改快取策略。")) }
            return number(Double(ImageCacheService.shared.maximumRebuildableBytes) / 1048576, minimum: 0, maximum: 1048576) { [weak self] value in
                ImageCacheService.shared.maximumRebuildableBytes = Int64(value) * 1048576
                self?.execute {
                    _ = try await Task.detached(priority: .utility) { try ImageCacheService.shared.evictRebuildableCacheToLimit() }.value
                    self?.refreshCache()
                }
            }
        }
        add("cache.clear", .storage, String(localized: "清理可重建快取"), "clear cache cleanup delete 缓存 清除", String(localized: "只清理封面／表情与 metadata，服務拒絕與下載保護目錄交疊；不清理活動暫存、收藏、憑證或完成檔。")) {
            button(String(localized: "清理快取…"), icon: .delete) { [weak self] in
                self?.confirm(String(localized: "清理可重建快取？"), detail: String(localized: "封面／表情與 metadata 之後需重新載入。下載暫存、Torrent 資料、收藏、帳號與完成檔不會刪除。")) { [weak self] in
                    self?.execute {
                        try await Task.detached(priority: .utility) { try ImageCacheService.shared.clearRebuildableCache() }.value
                        SDImageCache.shared.clearMemory()
                        self?.refreshCache()
                    }
                }
            }
        }
        add("cache.refresh", .storage, String(localized: "重新計量快取"), "refresh cache reload 刷新 用量", String(localized: "讀取本機檔案用量，不觸發站點請求或傳輸。")) {
            button(String(localized: "重新計量"), icon: .refresh) { [weak self] in self?.refreshCache() }
        }
    }

    private func aboutSettings() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "未提供")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "未提供")
        add("about.version", .about, String(localized: "版本與專案身分"), "version build about 版本 关于", String(localized: "IINA-ANI 是 IINA+ 的非官方重構 fork，不是 IINA 或 Animeko 官方產品；尚未配置獨立發佈身分。")) {
            info(String(localized: "IINA-ANI\n版本 \(version) · build \(build)"))
        }
        add("about.license", .about, String(localized: "授權與上游"), "license copyright gpl upstream 授權 版权", String(localized: "保留原作者版權、GPL 及第三方授權。上游自動更新已停用；尚未配置獨立 fork 發佈、簽署及更新來源。")) {
            button(String(localized: "查看既有上游專案"), icon: .openLink) { NSWorkspace.shared.open(URL(string: "https://github.com/xjbeta/iina-plus")!) }
        }
    }

    func attach() {
        guard !attached else { return }
        attached = true
        if isViewLoaded { rebuild(); refreshAccounts(); refreshCache() }
    }

    func detach() {
        attached = false
        accountRefresh?.cancel()
        accountRefresh = nil
        accountAction?.cancel()
        cacheRefresh?.cancel()
        cacheRefresh = nil
        dismissSheet()
        subscriptionWindow?.close()
        subscriptionWindow = nil
    }

    private func refreshAccounts() {
        guard !previewOnly, attached else { return }
        accountRefresh?.cancel()
        let service = accounts
        accountRefresh = Task { [weak self] in
            do {
                var records: [String: SiteAccount] = [:]
                for source in ["bilibili", "douyu"] {
                    if let current = try await service.defaultAccount(sourceID: source) { records[source] = current }
                    else { records[source] = try await service.accounts(sourceID: source).first { $0.enabled && $0.status == .needsLogin } }
                }
                records["bangumi"] = await service.bangumiAccount()
                guard !Task.isCancelled, let self, attached else { return }
                displayedAccounts = records
                accountsLoaded = true
                rebuild()
            } catch {
                if !Task.isCancelled { self?.status.stringValue = error.localizedDescription }
            }
        }
    }
    private func refreshCache() {
        guard !previewOnly, attached else { return }
        cacheRefresh?.cancel()
        cacheRefresh = Task { [weak self] in
            let footprint = await Task.detached(priority: .utility) { ImageCacheService.shared.footprint() }.value
            guard !Task.isCancelled else { return }
            func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            self?.cacheText?.stringValue = String(localized: "封面／表情：\(size(footprint.coversAndEmoticons))\nMetadata：\(size(footprint.metadata))\n受保護下載暫存：\(size(footprint.downloadTemporaryFiles))\n服務持有完成檔：\(size(footprint.completedDownloads))")
        }
    }
    private func showLogin(_ account: SiteAccount) {
        guard !previewOnly, attached, sheetController == nil else { return }
        let host = NSHostingController(rootView: WorkspaceSettingsLoginSheet(account: account, accounts: accounts) { [weak self] in self?.dismissSheet() })
        sheetController = host
        presentAsSheet(host)
    }
    private func showBangumi() {
        guard !previewOnly, attached, sheetController == nil else { return }
        let host = NSHostingController(rootView: BangumiAccountSheetView(service: accounts, onClose: { [weak self] in
            self?.dismissSheet()
        }))
        sheetController = host
        presentAsSheet(host)
    }
    private func showPlugin() {
        let host = NSHostingController(rootView: WorkspaceSettingsPluginSheet { [weak self] in self?.dismissSheet() })
        sheetController = host
        presentAsSheet(host)
    }
    private func dismissSheet() {
        let controller = sheetController
        sheetController = nil
        if let controller { dismiss(controller) }
        if attached { refreshAccounts() }
    }
}

private struct WorkspaceSettingsLoginSheet: View {
    let account: SiteAccount
    let accounts: SiteAccounts
    let close: () -> Void
    @State private var presented = true
    @State private var status: SiteLoginStatus = .loggedOut
    @State private var userName = ""
    var body: some View {
        Group {
            if account.sourceID == "bilibili" {
                BiliLoginSheetView(loginSheet: $presented, status: $status, userName: $userName, accountID: account.id, accounts: accounts)
            } else {
                DouyuLoginSheetView(loginSheet: $presented, status: $status, userName: $userName, accountID: account.id, accounts: accounts)
            }
        }.onChange(of: presented) { if !$0 { close() } }
    }
}

private struct WorkspaceSettingsPluginSheet: View {
    let close: () -> Void
    @State private var presented = true
    var body: some View {
        PluginSheetView(pluginSheet: $presented).onChange(of: presented) { if !$0 { close() } }
    }
}

@MainActor
private final class WorkspaceSourceSubscriptionController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let service: SourceSubscriptionService
    private let skin: SkinAppearance
    private let content = WorkspaceSettingsDocumentStack()
    private let scroll = NSScrollView()
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var checkTask: Task<Void, Never>?
    private var plan: SourceSubscriptionPlan?
    private var checking = false
    private var active = true
    private var message = String(localized: "尚未檢查訂閱；檢查後先預覽差異，不會自動套用。")

    init(service: SourceSubscriptionService, skin: SkinAppearance) {
        self.service = service
        self.skin = skin
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "來源訂閱")
        window.minSize = NSSize(width: 640, height: 380)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let root = NSView()
        root.bindSkin(skin, slot: "background", componentID: "settings.preferences")
        window.contentView = root
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        rebuild()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { checkTask?.cancel() }

    func windowWillClose(_ notification: Notification) {
        active = false
        invalidatePreview()
        if let window { window.parent?.removeChildWindow(window) }
        onClose?()
        onClose = nil
    }
    override func close() {
        invalidatePreview()
        super.close()
    }
    override func cancelOperation(_ sender: Any?) { close() }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = true
        label.bindSkin(skin, slot: "list", componentID: "settings.preferences")
        return label
    }
    private func button(_ title: String, id: String, action: @escaping () -> Void) -> NSButton {
        let button = WorkspaceSkinButton(title: title, target: self, action: #selector(invoke(_:)))
        let icons: [String: WorkspaceIcon] = ["check": .refresh, "cancel": .close, "close": .close,
                                               "apply": .check, "discard": .close]
        button.setFunctionIcon(icons[id])
        button.bezelStyle = .rounded
        button.bindSkin(skin, slot: "primaryAction", componentID: "settings.preferences")
        button.setAccessibilityIdentifier("subscription.\(id)")
        actions[ObjectIdentifier(button)] = action
        return button
    }
    @objc private func invoke(_ sender: NSButton) { actions[ObjectIdentifier(sender)]?() }
    private func add(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
    }
    private func date(_ value: Date) -> String {
        DateFormatter.localizedString(from: value, dateStyle: .medium, timeStyle: .short)
    }
    private func rebuild() {
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        actions.removeAll(keepingCapacity: true)
        add(label(String(localized: "css1 番劇背景來源訂閱\n僅使用訪客能力；不匯入 Cookie、token、授權資料或腳本，不新增站點帳號。搜尋規則更新不代表播放或下載已驗證。")))
        let check = button(checking ? String(localized: "正在檢查…") : String(localized: "檢查訂閱更新"), id: "check") { [weak self] in self?.check() }
        check.isEnabled = !checking
        var commands: [NSView] = [check]
        if checking {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            commands.append(progress)
            commands.append(button(String(localized: "取消檢查"), id: "cancel") { [weak self] in self?.discard() })
        }
        let close = button(String(localized: "關閉"), id: "close") { [weak self] in self?.close() }
        close.keyEquivalent = "\u{1b}"
        commands.append(close)
        add(NSStackView(views: commands))
        var status = message
        if let applied = service.lastApplied {
            status += String(localized: "\n最近套用：\(date(applied.checkedAt)) 檢查的版本（\(applied.overrides.count) 個來源配置）。")
        } else { status += String(localized: "\n最近套用：尚無套用記錄。") }
        if let error = service.lastError { status += String(localized: "\n最近服務錯誤：\(error)") }
        let statusLabel = label(status)
        statusLabel.setAccessibilityIdentifier("subscription.status")
        add(statusLabel)
        guard let plan else { return }
        add(label(String(localized: "本次訂閱差異預覽\n檢查時間：\(date(plan.checkedAt))\n\(plan.entries.count) 個項目；\(plan.overrides.count) 個可套用來源配置。尚未保存，請閱讀差異後選擇套用或捨棄。")))
        for entry in plan.entries {
            let source = entry.sourceID ?? String(localized: "未對應既有來源")
            add(label(String(localized: "\(entry.name) · \(entry.status)\n來源：\(source)\n\(entry.detail)")))
        }
        let apply = button(String(localized: "套用此預覽"), id: "apply") { [weak self] in self?.apply() }
        apply.isEnabled = !checking && !plan.overrides.isEmpty
        add(NSStackView(views: [apply, button(String(localized: "捨棄預覽"), id: "discard") { [weak self] in self?.discard() }]))
        if plan.overrides.isEmpty { add(label(String(localized: "本次沒有可套用的配置；可捨棄預覽或重新檢查。"))) }
    }
    private func invalidatePreview() {
        checkTask?.cancel()
        checkTask = nil
        plan = nil
        checking = false
    }
    private func discard() {
        guard active else { return }
        invalidatePreview()
        message = String(localized: "已取消檢查並清除預覽；原來源配置未變更。")
        rebuild()
    }
    private func check() {
        guard active else { return }
        invalidatePreview()
        checking = true
        message = String(localized: "正在取得資料、轉換規則並比較來源；原配置未變更。")
        rebuild()
        let service = service
        checkTask = Task { [weak self] in
            do {
                let plan = try await service.check()
                guard !Task.isCancelled, let self, active else { return }
                checkTask = nil
                checking = false
                self.plan = plan
                message = String(localized: "檢查完成，尚未套用。請閱讀逐項差異後，選擇套用或捨棄。")
                rebuild()
            } catch {
                guard !Task.isCancelled, let self, active else { return }
                checkTask = nil
                checking = false
                message = String(localized: "訂閱檢查失敗；原來源配置未變更。\n\(error.localizedDescription)")
                rebuild()
            }
        }
    }
    private func apply() {
        guard active, !checking, let plan else { return }
        do {
            try service.apply(plan)
            invalidatePreview()
            message = String(localized: "訂閱預覽已套用；後續搜尋使用新配置，播放與下載仍需實際驗證。")
        } catch {
            message = String(localized: "訂閱套用失敗；保留先前有效來源配置。\n\(error.localizedDescription)")
        }
        rebuild()
    }
}

