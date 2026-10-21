import AppKit
import UniformTypeIdentifiers

/// Trusted commands are outside the author-editable workspace and Skin package.
@MainActor
final class WorkspaceSkinController: NSObject {
    let appearance = SkinAppearance()
    private let store: SkinStore
    private let currentLayout: () throws -> WorkspaceLayout?
    private let applyLayout: (WorkspaceLayout) throws -> Void
    private let makePreview: (WorkspaceLayout, SkinAppearance) throws -> WorkspaceWindowController
    private var manager: WorkspaceSkinManager?
    private var authorDirectory: URL?
    private var recoveryError: Error?
    private var reportedAppearanceError: SkinAppearanceError?
    private var reportedStoreRecovery = false

    init(rootURL: URL, currentLayout: @escaping () throws -> WorkspaceLayout?,
         applyLayout: @escaping (WorkspaceLayout) throws -> Void,
         makePreview: @escaping (WorkspaceLayout, SkinAppearance) throws -> WorkspaceWindowController) throws {
        store = SkinStore(rootURL: rootURL)
        self.currentLayout = currentLayout
        self.applyLayout = applyLayout
        self.makePreview = makePreview
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
            name: SkinAppearance.didChangeNotification, object: appearance)
        do {
            let package = try store.selectedPackage()
            let overrides = try package.map { try store.loadOverrides(for: $0.manifest.id) }
            try appearance.apply(package: package, overrides: overrides, scheme: store.colorScheme)
        } catch { recoveryError = error }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func appearanceChanged() {
        guard let error = appearance.selectionError ?? appearance.assetError else {
            reportedAppearanceError = nil
            return
        }
        guard reportedAppearanceError != error else { return }
        reportedAppearanceError = error
        Task { [weak self] in
            self?.showMessage(String(localized: "Skin 外觀無法更新"), detail: String(localized: "目前有效樣式保持不變；可從固定選單恢復內建外觀。\n\(error.localizedDescription)"))
        }
    }
    func installMenu(in parent: NSMenu) {
        let root = NSMenuItem(title: String(localized: "外觀"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: String(localized: "外觀"))
        root.submenu = menu
        let entries: [(String, Selector)] = [
            (String(localized: "Skin 管理…"), #selector(choosePackage)),
            (String(localized: "匯入 .iinaskin…"), #selector(importPackage)),
            (String(localized: "明暗模式…"), #selector(chooseScheme)),
            (String(localized: "此 Skin 的文字與密度…"), #selector(editOverrides)),
            (String(localized: "選取作者目錄並預覽…"), #selector(chooseAuthorDirectory)),
            (String(localized: "重新載入作者目錄並預覽"), #selector(reloadAuthorDirectory)),
            (String(localized: "匯出作者原包…"), #selector(exportOriginal)),
            (String(localized: "匯出個人外觀與選定佈局…"), #selector(exportDerived)),
            (String(localized: "預覽並套用作者佈局…"), #selector(useAuthorLayout)),
            (String(localized: "移除目前 Skin…"), #selector(removePackage)),
            (String(localized: "恢復內建外觀…"), #selector(restoreBuiltin))
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        parent.addItem(root)
    }
    func reportRecoveryIfNeeded() {
        if let error = recoveryError {
            recoveryError = nil
            showMessage(String(localized: "Skin 未能載入，已保留原檔並使用內建外觀"), detail: error.localizedDescription)
        }
        if !reportedStoreRecovery, let notice = store.recoveryNotice {
            reportedStoreRecovery = true
            showMessage(String(localized: "Skin 安裝記錄已恢復"), detail: notice)
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); try refreshManager() } catch { NSAlert(error: error).runModal() }
        reportRecoveryIfNeeded()
    }
    private func prepare(_ package: SkinPackage?, scheme: SkinColorScheme? = nil,
                         overrides: SkinPersonalOverrides? = nil) throws -> SkinAppearance {
        let personal = try overrides ?? package.map { try store.loadOverrides(for: $0.manifest.id) }
        let prepared = SkinAppearance()
        try prepared.apply(package: package, overrides: personal, scheme: scheme ?? store.colorScheme)
        return prepared
    }
    private struct ReviewBaseline: Equatable {
        let layout: WorkspaceLayout?
        let selectedDigest: String?
        let appearanceRevision: UInt64
        let scheme: SkinColorScheme
    }
    private func baseline() throws -> ReviewBaseline {
        let selected = try store.selectedPackage()
        return try ReviewBaseline(layout: currentLayout(), selectedDigest: selected.map { try SkinPackageCodec.contentDigest(for: $0) },
                                  appearanceRevision: appearance.revision, scheme: store.colorScheme)
    }
    private func requireUnchanged(_ before: ReviewBaseline) throws {
        guard try baseline() == before else { throw SkinReviewError.changedDuringReview }
    }
    private func preview(_ prepared: SkinAppearance, layout: WorkspaceLayout, package: SkinPackage? = nil,
                         allowAuthorLayout: Bool = false, initiallyAuthorLayout: Bool = false) throws -> (accepted: Bool, authorLayout: Bool) {
        let author = allowAuthorLayout ? package?.manifest.layout : nil
        let initial = initiallyAuthorLayout ? author ?? layout : layout
        let controller = try makePreview(initial, prepared)
        defer { controller.close() }
        let options = SkinPreviewOptions()
        options.checkbox.state = initiallyAuthorLayout && author != nil ? .on : .off
        options.checkbox.isEnabled = author != nil
        let metadata = NSTextField(wrappingLabelWithString: package.map {
            String(localized: "\($0.manifest.name) · \($0.manifest.version) · 作者：\($0.manifest.author ?? String(localized: "未聲明")) · 授權：\($0.manifest.license)（未驗證宣告）")
        } ?? String(localized: "內建外觀"))
        metadata.lineBreakMode = .byTruncatingTail
        metadata.toolTip = metadata.stringValue
        metadata.maximumNumberOfLines = 2
        metadata.preferredMaxLayoutWidth = 800
        metadata.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let note = NSTextField(labelWithString: String(localized: "只改外觀；明確選取作者佈局才改排列。取消不保存；預覽不執行業務命令。"))
        let stack = NSStackView(views: [metadata, options.checkbox, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        NSLayoutConstraint.activate([
            stack.heightAnchor.constraint(equalToConstant: 90),
            metadata.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        note.lineBreakMode = .byTruncatingTail
        note.toolTip = note.stringValue
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controller.setNativePreviewDetails(stack)
        options.onChange = { [weak controller] enabled in
            guard let controller else { return }
            controller.updateNativePreview(enabled ? author ?? layout : layout, pageID: nil, breakpoint: nil, usesWindowBreakpoints: true)
            controller.setNativePreviewApplyTitle(enabled ? String(localized: "套用外觀與作者佈局") : String(localized: "套用此外觀"))
        }
        controller.setNativePreviewApplyTitle(options.checkbox.state == .on ? String(localized: "套用外觀與作者佈局") : String(localized: "套用此外觀"))
        return (controller.reviewNativePreview(), options.checkbox.state == .on)
    }
    private func confirmReplacement(_ review: SkinReviewPackage) throws -> SkinReplacementConfirmation? {
        try store.replacementRequired(for: review)
    }
    private func approveReplacement(_ change: SkinReplacementConfirmation) -> Bool {
        confirm(String(localized: "相同 ID 的 Skin 差異確認"), detail:
            String(localized: "ID：\(change.skinID)\n版本：\(change.currentVersion) → \(change.newVersion)\n變更檔案：\(change.changedFiles.joined(separator: ", "))\n作者身分未驗證；只有預覽後明確套用才替換。失敗或取消保留舊安裝。"), button: String(localized: "繼續預覽"))
    }
    /// File-open and manager drag/drop use exactly the same review transaction.
    func openPackage(at url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let review = try store.prepareReview(archiveURL: url)
        try reviewAndInstall(review)
        try refreshManager()
    }
    private func reviewAndInstall(_ review: SkinReviewPackage) throws {
        let before = try baseline()
        let change = try confirmReplacement(review)
        if let change, !approveReplacement(change) { return }
        let previousLayout = before.layout ?? WorkspaceBuiltinLayouts.makeDefault()
        let personal = try store.loadOverrides(for: review.package.manifest.id)
        let prepared = try prepare(review.package, overrides: personal)
        let decision = try preview(prepared, layout: previousLayout, package: review.package, allowAuthorLayout: true)
        guard decision.accepted else { return }
        try requireUnchanged(before)
        guard try store.loadOverrides(for: review.package.manifest.id) == personal else { throw SkinReviewError.changedDuringReview }
        let layout = decision.authorLayout ? review.package.manifest.layout! : previousLayout
        var installedAppearance: SkinAppearance?
        _ = try store.installReviewed(review, replacing: change, select: true, activate: {
            if decision.authorLayout { try self.applyLayout(layout) }
        }, validateForActivation: { installed in
            installedAppearance = try self.prepare(installed, overrides: personal)
        })
        if let installedAppearance { appearance.adopt(installedAppearance) }
        showWarnings()
    }
    private func select(_ package: SkinPackage?, authorLayout: Bool = false) throws {
        let before = try baseline()
        let personal = try package.map { try store.loadOverrides(for: $0.manifest.id) }
        let prepared = try prepare(package, overrides: personal)
        let original = before.layout ?? WorkspaceBuiltinLayouts.makeDefault()
        let digest = try package.map { try SkinPackageCodec.contentDigest(for: $0) }
        let decision = try preview(prepared, layout: original, package: package,
                                   allowAuthorLayout: package != nil, initiallyAuthorLayout: authorLayout)
        guard decision.accepted else { return }
        try requireUnchanged(before)
        if let package, try store.loadOverrides(for: package.manifest.id) != personal { throw SkinReviewError.changedDuringReview }
        let candidate = decision.authorLayout ? package!.manifest.layout! : original
        try store.selectSkin(id: package?.manifest.id, activate: {
            if decision.authorLayout { try self.applyLayout(candidate) }
        }, validate: { installed in
            guard try installed.map({ try SkinPackageCodec.contentDigest(for: $0) }) == digest else { throw SkinReviewError.changedDuringReview }
        })
        appearance.adopt(prepared)
        showWarnings()
    }
    @objc func choosePackage() {
        perform {
            if manager == nil {
                let controller = WorkspaceSkinManager()
                controller.action = { [weak self] action, package in
                    guard let self else { return }
                    self.perform {
                        switch action {
                        case .preview:
                            try self.select(package)
                        case .remove: if let package { try self.remove(package) }
                        case .exportOriginal: if let package { try self.export(package, derived: false) }
                        case .exportDerived: if let package { try self.export(package, derived: true) }
                        case .restore: try self.select(nil)
                        case .importPackage: self.importPackage()
                        case .authorDirectory: self.chooseAuthorDirectory()
                        case .reloadAuthor: try self.reloadAuthor()
                        }
                    }
                }
                manager = controller
                NotificationCenter.default.addObserver(self, selector: #selector(packageDropped(_:)),
                    name: WorkspaceSkinManager.packageDropped, object: controller)
            }
            try refreshManager()
            manager?.showWindow(nil)
            manager?.window?.makeKeyAndOrderFront(nil)
        }
    }
    private func refreshManager() throws {
        guard let manager else { return }
        manager.reload(packages: try store.installedSkins(), selectedID: try store.selectedPackage()?.manifest.id,
                       authorDirectory: authorDirectory)
    }
    @objc private func packageDropped(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        perform { try openPackage(at: url) }
    }
    @objc func importPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iinaskin") ?? .zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try openPackage(at: url) }
    }
    @objc func chooseAuthorDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        authorDirectory = url
        perform { try reloadAuthor() }
    }
    @objc func reloadAuthorDirectory() { perform { try reloadAuthor() } }
    private func reloadAuthor() throws {
        guard let url = authorDirectory else {
            showMessage(String(localized: "尚未選取作者目錄"), detail: String(localized: "請先選取含 manifest.json 的本機 Skin 目錄。"))
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // A fresh validated snapshot each time; never render the mutable author directory in-place.
        let review = try store.prepareReview(directoryURL: url)
        try reviewAndInstall(review)
    }
    @objc func chooseScheme() {
        perform {
            let choices: [SkinColorScheme] = [.system, .light, .dark]
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
            popup.addItems(withTitles: [String(localized: "跟隨系統"), String(localized: "淺色"), String(localized: "深色")])
            popup.selectItem(at: choices.firstIndex(of: store.colorScheme) ?? 0)
            guard confirm(String(localized: "明暗模式"), detail: String(localized: "先隔離預覽；缺少變體時拒絕切換，不自動反色。"), accessory: popup, button: String(localized: "預覽")) else { return }
            let scheme = choices[popup.indexOfSelectedItem]
            let before = try baseline()
            let package = try store.selectedPackage()
            let personal = try package.map { try store.loadOverrides(for: $0.manifest.id) }
            let prepared = try prepare(package, scheme: scheme, overrides: personal)
            guard try preview(prepared, layout: before.layout ?? WorkspaceBuiltinLayouts.makeDefault(), package: package).accepted else { return }
            try requireUnchanged(before)
            if let package, try store.loadOverrides(for: package.manifest.id) != personal { throw SkinReviewError.changedDuringReview }
            try store.setColorScheme(scheme)
            appearance.adopt(prepared)
            showWarnings()
        }
    }
    @objc func editOverrides() {
        perform {
            guard let package = try store.selectedPackage() else {
                showMessage(String(localized: "請先選擇第三方 Skin"), detail: String(localized: "個人覆寫依 Skin ID 獨立保存。"))
                return
            }
            let before = try baseline()
            let originalOverrides = try store.loadOverrides(for: package.manifest.id)
            var overrides = originalOverrides
            let size = NSTextField(string: String(Int(appearance.resolve(slot: "list").font.pointSize)))
            let density = NSPopUpButton()
            let densityOptions: [SkinDensity] = [.compact, .regular, .comfortable]
            density.addItems(withTitles: densityOptions.map(\.displayTitle))
            density.selectItem(at: densityOptions.firstIndex(of: appearance.resolve(slot: "list").density) ?? 1)
            let fields = NSStackView(views: [NSTextField(labelWithString: String(localized: "字級（10–32 pt）")), size,
                                           NSTextField(labelWithString: String(localized: "密度")), density])
            fields.orientation = .vertical
            fields.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
            guard confirm(String(localized: "此 Skin 的個人覆寫"), detail: String(localized: "先預覽；取消不保存字級、密度或偏好。"), accessory: fields, button: String(localized: "預覽")) else { return }
            guard let value = Double(size.stringValue), value.isFinite, (10...32).contains(value) else { throw SkinAppearanceError.invalidValue("fontSize") }
            overrides.theme["fontSize"] = .number(value)
            overrides.theme["density"] = .string(densityOptions[density.indexOfSelectedItem].rawValue)
            let prepared = try prepare(package, overrides: overrides)
            guard try preview(prepared, layout: before.layout ?? WorkspaceBuiltinLayouts.makeDefault(), package: package).accepted else { return }
            try requireUnchanged(before)
            guard try store.loadOverrides(for: package.manifest.id) == originalOverrides else { throw SkinReviewError.changedDuringReview }
            try store.saveOverrides(overrides, for: package.manifest.id)
            appearance.adopt(prepared)
        }
    }
    @objc func exportOriginal() { perform { if let package = try store.selectedPackage() { try export(package, derived: false) } } }
    @objc func exportDerived() { perform { if let package = try store.selectedPackage() { try export(package, derived: true) } } }
    private func export(_ package: SkinPackage, derived: Bool) throws {
        let layoutChoice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        layoutChoice.addItems(withTitles: [String(localized: "不包含 Layout"), String(localized: "目前工作區 Layout")])
        if package.manifest.layout != nil { layoutChoice.addItem(withTitle: String(localized: "作者 Layout")) }
        guard confirm(String(localized: "確認素材再散布授權"), detail:
            String(localized: "\(package.manifest.license)\n作者與授權宣告不是權利驗證；請確認可分享素材與字體。衍生包生成新 ID。分享只含展示结构，不含帳號、收藏、私人搜尋或任務。"),
            accessory: derived ? layoutChoice : nil, button: String(localized: "匯出…")) else { return }
        let layout: WorkspaceLayout?
        switch layoutChoice.indexOfSelectedItem {
        case 1: layout = try currentLayout()
        case 2: layout = package.manifest.layout
        default: layout = nil
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = derived ? "personal.iinaskin" : "skin.iinaskin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try store.exportSkin(id: package.manifest.id, to: url, mode: derived ? .derived : .original,
            layout: derived ? layout : nil, overrides: derived ? store.loadOverrides(for: package.manifest.id) : nil)
    }
    @objc func useAuthorLayout() {
        perform {
            guard let package = try store.selectedPackage(), package.manifest.layout != nil else {
                showMessage(String(localized: "此 Skin 沒有作者佈局"), detail: String(localized: "目前工作區不變。"))
                return
            }
            try select(package, authorLayout: true)
        }
    }
    @objc func removePackage() { perform { if let package = try store.selectedPackage() { try remove(package) } } }
    private func remove(_ package: SkinPackage) throws {
        guard confirm(String(localized: "移除 \(package.manifest.name)？"), detail: String(localized: "目前使用此包時恢復內建外觀；不移除工作區、收藏、偏好或任務。")) else { return }
        let active = try store.selectedPackage()?.manifest.id == package.manifest.id
        let prepared = try active ? prepare(nil) : nil
        try store.removeSkin(id: package.manifest.id)
        if let prepared { appearance.adopt(prepared) }
    }
    @objc func restoreBuiltin() { perform { try select(nil) } }
    private func showWarnings() {
        for slot in SkinSlot.allCases { _ = appearance.resolve(slot: slot) }
        if !appearance.contrastWarnings.isEmpty {
            showMessage(String(localized: "Skin 對比度警示"), detail: String(localized: "部分第三方樣式未達正文 4.5:1。未替作者改色；固定外觀選單可恢復內建外觀。"))
        }
    }
    private func confirm(_ title: String, detail: String, accessory: NSView? = nil, button: String = String(localized: "確認")) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.accessoryView = accessory
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

private enum SkinReviewError: Error, LocalizedError {
    case changedDuringReview
    var errorDescription: String? { String(localized: "預覽期間目前工作區、Skin 或個人外觀已變更；未套用過期候選。請重新預覽。") }
}

@MainActor
private final class SkinPreviewOptions: NSObject {
    let checkbox = NSButton(checkboxWithTitle: String(localized: "外觀＋作者 Layout（取代目前排列）"), target: nil, action: nil)
    var onChange: ((Bool) -> Void)?
    override init() {
        super.init()
        checkbox.target = self
        checkbox.action = #selector(changed)
    }
    @objc private func changed() { onChange?(checkbox.state == .on) }
}
