import Cocoa

/// Fixed application commands are outside the saved workspace and cannot be removed by a layout.
@MainActor
final class WorkspaceApplicationController: NSObject {
    private unowned let delegate: AppDelegate
    private var workspace: WorkspaceWindowController?
    private var settingsCommands: WorkspaceSettingsCommands {
        WorkspaceSettingsCommands(
            manageSkins: { [unowned self] in self.withSkin { $0.choosePackage() } },
            importSkin: { [unowned self] in self.withSkin { $0.importPackage() } },
            colorScheme: { [unowned self] in self.withSkin { $0.chooseScheme() } },
            personalAppearance: { [unowned self] in self.withSkin { $0.editOverrides() } },
            authorPreview: { [unowned self] in self.withSkin { $0.chooseAuthorDirectory() } },
            reloadAuthorPreview: { [unowned self] in self.withSkin { $0.reloadAuthorDirectory() } },
            exportOriginalSkin: { [unowned self] in self.withSkin { $0.exportOriginal() } },
            exportDerivedSkin: { [unowned self] in self.withSkin { $0.exportDerived() } },
            applyAuthorLayout: { [unowned self] in self.withSkin { $0.useAuthorLayout() } },
            removeSkin: { [unowned self] in self.withSkin { $0.removePackage() } },
            restoreAppearance: { [unowned self] in self.withSkin { $0.restoreBuiltin() } },
            editLayout: { [unowned self] in self.perform { $0.beginLayoutEditing() } },
            generateLayout: { [unowned self] in self.runLayoutScript() },
            restoreLayout: { [unowned self] in self.restoreWorkspace() })
    }
    private func withSkin(_ action: (WorkspaceSkinController) -> Void) {
        do { action(try skinController()) } catch { NSAlert(error: error).runModal() }
    }
    private var skins: WorkspaceSkinController?
    private var layoutScripts: WorkspaceLayoutScriptController?
    init(delegate: AppDelegate) { self.delegate = delegate }

    func installMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let root = NSMenuItem(title: String(localized: "導覽"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: String(localized: "導覽"))
        root.submenu = menu
        let entries: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            (String(localized: "顯示主視窗"), #selector(showWorkspace), "1", [.command, .shift]),
            (String(localized: "搜尋"), #selector(searchWorkspace), "f", [.command]),
            (String(localized: "Bilibili 關注動態"), #selector(showFollowed), "", [.command]),
            (String(localized: "Bilibili 推薦影片"), #selector(showBilibiliRecommendations), "", [.command]),
            ("YouTube", #selector(showYouTube), "", [.command]),
            (String(localized: "開啟網址…"), #selector(openAddress), "o", [.command, .shift]),
            (String(localized: "開啟 Torrent 檔案…"), #selector(chooseTorrent), "t", [.command, .shift]),
            (String(localized: "活動任務"), #selector(showTasks), "d", [.command, .shift]),
            (String(localized: "設定…"), #selector(showSettings), ",", [.command]),
            (String(localized: "恢復內建佈局"), #selector(restoreWorkspace), "", [.command]),
        ]
        for (title, action, key, modifiers) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        if WorkspaceLayoutScriptRunner.externalImportEnabled {
            let item = NSMenuItem(title: String(localized: "執行佈局腳本…"), action: #selector(runLayoutScript), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        do { try skinController().installMenu(in: menu) } catch { NSAlert(error: error).runModal() }
        mainMenu.addItem(root)
    }

    private func skinController() throws -> WorkspaceSkinController {
        if let skins { return skins }
        let root = try AppStoragePaths.production().applicationSupport.appendingPathComponent(
            "Skins", isDirectory: true)
        let controller = try WorkspaceSkinController(
            rootURL: root, currentLayout: { [weak self] in
                if let active = self?.workspace?.shareableLayout { return active }
                let url = root.deletingLastPathComponent().appendingPathComponent("Workspace/layout-v1.json")
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                switch WorkspaceStore(url: url).load() {
                case .loaded(let layout): return layout
                case .recoveredDefault(_, let reason):
                    throw WorkspaceCapabilityFailure(reasons: [String(localized: "無法分享損壞的工作區：\(reason)")])
                }
            },
            applyLayout: { [unowned self] in try self.windowController().applyLayout($0) },
            makePreview: { [unowned self] candidate, appearance in
                if let workspace = self.workspace {
                    return workspace.presentNativePreview(candidate, appearance: appearance)
                }
                return WorkspaceWindowController(
                    dependencies: try self.workspaceDependencies(appearance: appearance),
                    previewLayout: candidate)
            })
        skins = controller
        return controller
    }
    private func layoutScriptController() throws -> WorkspaceLayoutScriptController {
        if let layoutScripts { return layoutScripts }
        let workspace = try windowController()
        let controller = WorkspaceLayoutScriptController(
            currentLayout: { workspace.shareableLayout },
            makePreview: { candidate in workspace.presentNativePreview(candidate) },
            applyLayout: { try workspace.applyLayout($0) })
        layoutScripts = controller
        return controller
    }

    private func windowController() throws -> WorkspaceWindowController {
        if let workspace { return workspace }
        let controller = WorkspaceWindowController(
            dependencies: try workspaceDependencies(appearance: skinController().appearance))
        workspace = controller
        return controller
    }

    private func workspaceDependencies(appearance: SkinAppearance) throws -> WorkspaceWindowDependencies {
        let root = try AppStoragePaths.production().applicationSupport.appendingPathComponent(
            "Workspace", isDirectory: true)
        let store = WorkspaceStore(
            url: root.appendingPathComponent("layout-v1.json"),
            validator: WorkspaceValidator(registry: WorkspaceRegistry.builtins))
        return WorkspaceWindowDependencies(
            favorites: delegate.favoriteLibrary,
            actions: WorkspaceFixedActions(
                settings: { [unowned self] in self.showSettings() },
                open: { [unowned self] in self.openAddress() },
                openLink: { [unowned self] in self.openLink($0) },
                openWork: { [unowned self] id in self.withDetail { $0.openWork(id) } },
                openBangumi: { [unowned self] id, subject in self.withDetail { $0.openBangumi(id, subject: subject) } },
                openSelection: { [unowned self] selection in self.withDetail { $0.openSelection(selection) } },
                openUpdate: { [unowned self] update in self.withDetail { $0.openUpdate(update) } },
                openDownload: { [unowned self] id in try await self.delegate.services.player.openDownloadedFile(id) }),
            layoutStore: store,
            loadOnlineCollections: { [unowned self] in
                try await BangumiWorkSync(library: self.delegate.workLibrary)
                    .loadOnlineCollections(favorites: self.delegate.favoriteLibrary)
            },
            retryCollectionStatus: { [unowned self] id in
                guard let work = try self.delegate.workLibrary.fetchWork(id: id) else {
                    throw WorkLibrary.LibraryError.workNotFound(id)
                }
                guard work.collectionStatusPending, let status = work.collectionStatus else { return }
                _ = try await BangumiWorkSync(library: self.delegate.workLibrary)
                    .setCollectionStatus(workID: id, status: status)
            },
            makeDataManager: { [unowned self] in self.delegate.makeDataManager() },
            registry: WorkspaceRegistry.builtins,
            sessionState: try WorkspaceSessionState(
                storeURL: root.appendingPathComponent("instance-state-v1.json")),
            skinAppearance: appearance,
            capabilityEnabled: { [unowned self] in self.delegate.services.capabilityEnabled($0) },
            setCapabilityEnabled: { [unowned self] capability, enabled in
                if capability == .downloads {
                    try await self.delegate.services.setCapability(capability, enabled: enabled)
                } else {
                    let discovery = try self.delegate.discovery()
                    try await self.delegate.services.setCapability(capability, enabled: enabled)
                    discovery.setRefreshPolicy(
                        self.delegate.services.preferences.discoveryRefreshPolicy)
                }
            },
            discovery: { [unowned self] in try self.delegate.discovery() },
            makeSearch: { [unowned self] in self.delegate.services.makeBrowseSearch() },
            downloads: { [unowned self] in try self.delegate.services.downloads() },
            playbackHistory: { [unowned self] in try self.delegate.services.playbackHistory() },
            resumePlayback: { [unowned self] in try await self.delegate.services.resumePlayback($0) },
            enabledSourceIDs: { [unowned self] in
                Set(
                    SourceRegistry.shared.snapshot.descriptors.filter {
                        self.delegate.services.preferences.isSourceEnabled($0.id)
                    }.map(\.id))
            }, makeProductPanel: { [unowned self] type, _, appearance, previewOnly in
                switch type.rawValue {
                case "detail.media": return WorkspaceDetailController(delegate: self.delegate, appearance: appearance, previewOnly: previewOnly)
                case "settings.preferences": return WorkspaceSettingsController(delegate: self.delegate, appearance: appearance, commands: self.settingsCommands, previewOnly: previewOnly)
                case "torrent.import": return WorkspaceTorrentController(delegate: self.delegate, appearance: appearance, previewOnly: previewOnly)
                default: preconditionFailure("Unregistered product component")
                }
            })
    }

    private func perform(_ action: (WorkspaceWindowController) -> Void) {
        do {
            let controller = try windowController()
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            action(controller)
            skins?.reportRecoveryIfNeeded()
        } catch { NSAlert(error: error).runModal() }
    }

    func openSkinPackage(at url: URL) {
        do { try skinController().openPackage(at: url) }
        catch { NSAlert(error: error).runModal() }
    }

    @objc func showWorkspace() { perform { _ in } }
    @objc private func showFollowed() { perform { $0.showFollowedVideos() } }
    @objc private func showBilibiliRecommendations() { perform { $0.showBilibiliRecommendations() } }
    @objc private func showYouTube() { perform { $0.showYouTube() } }
    @objc private func searchWorkspace() { perform { $0.focusSearch() } }
    @objc private func showTasks() { perform { $0.showTasks() } }
    @objc private func restoreWorkspace() {
        do {
            if workspace == nil {
                let file = try AppStoragePaths.production().applicationSupport
                    .appendingPathComponent("Workspace/instance-state-v1.json")
                if FileManager.default.fileExists(atPath: file.path) {
                    do { _ = try WorkspaceSessionState(storeURL: file) }
                    catch {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "無法讀取個人工作區狀態")
                        alert.informativeText = String(localized: "\(error.localizedDescription)\n備份原檔後，還原查詢、篩選、選中、捲動與密度。工作區排列、收藏、帳號及下載不受影響。")
                        alert.addButton(withTitle: String(localized: "備份並還原個人狀態"))
                        alert.addButton(withTitle: String(localized: "取消"))
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        let backup = file.appendingPathExtension("recovery-\(UUID().uuidString).bak")
                        try FileManager.default.moveItem(at: file, to: backup)
                    }
                }
            }
            perform { $0.restoreDefaults() }
        } catch { NSAlert(error: error).runModal() }
    }
    @objc func showSettings() { perform { _ = $0.showProduct("settings.preferences") } }
    func showSetting(_ id: String) {
        perform { ($0.showProduct("settings.preferences") as? WorkspaceSettingsController)?.focusSetting(id) }
    }
    @objc private func chooseTorrent() {
        withDetail { $0.openTorrent() }
    }
    private func withDetail(_ action: (WorkspaceDetailController) -> Void) {
        perform { $0.showDetail(settings: self.delegate.services.preferences.detailTransition, action) }
    }
    func openRelatedSubject(_ id: Int, from view: NSView?) {
        let source = WorkspaceCoverTransitionSource.capture(from: view)
        perform { $0.showDetail(settings: self.delegate.services.preferences.detailTransition, source: source) { $0.openBangumi(id) } }
    }
    @objc private func runLayoutScript() {
        do { try layoutScriptController().chooseAndRunSource() }
        catch { NSAlert(error: error).runModal() }
    }

    @objc private func openAddress() {
        let alert = NSAlert()
        alert.messageText = String(localized: "開啟網址")
        alert.informativeText = String(localized: "開啟影片、直播、作品或 magnet；播放與下載使用詳情中同一選擇。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = String(localized: "影片、直播或作品網址")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "開啟"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        openLink(value)
    }

    func openLink(_ address: String) {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("magnet:") || URL(string: value)?.pathExtension.lowercased() == "torrent" {
            withDetail { $0.openTorrent(value) }
        } else {
            withDetail { $0.openAddress(value) }
        }
    }
}
