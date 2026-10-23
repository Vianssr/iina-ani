//
//  MainMenu.swift
//  iina+
//
//  Created by xjbeta on 2018/7/27.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa

@MainActor
final class MainMenu: NSObject {
    private unowned let delegate: AppDelegate
    private var openFilesWindow: NSWindowController?

    init(delegate: AppDelegate) { self.delegate = delegate }

    func install() {
        let menu = NSMenu()
        NSApp.mainMenu = menu
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            item.submenu = child
            menu.addItem(item)
            return child
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                 _ key: String = "", target: AnyObject? = nil,
                 modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let app = submenu("IINA-ANI")
        add(app, String(localized: "關於 IINA-ANI"), #selector(about), target: self)
        // No updater is started while this fork has no independent feed/signing identity.
        app.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "服務"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: String(localized: "服務"))
        app.addItem(services)
        NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        add(app, String(localized: "隱藏 IINA-ANI"), #selector(NSApplication.hide(_:)), "h")
        add(app, String(localized: "隱藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        add(app, String(localized: "顯示全部"), #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, String(localized: "結束 IINA-ANI"), #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(String(localized: "檔案"))
        add(file, String(localized: "開啟影片與彈幕…"), #selector(openFiles), "o", target: self)
        file.addItem(.separator())
        add(file, String(localized: "關閉視窗"), #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu(String(localized: "編輯"))
        // The focused editor/window owns undo, not a global Core Data context.
        add(edit, String(localized: "復原"), Selector(("undo:")), "z")
        add(edit, String(localized: "重做"), Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, String(localized: "剪下"), #selector(NSText.cut(_:)), "x")
        add(edit, String(localized: "複製"), #selector(NSText.copy(_:)), "c")
        add(edit, String(localized: "貼上"), #selector(NSText.paste(_:)), "v")
        add(edit, String(localized: "貼上並符合樣式"), #selector(NSTextView.pasteAsPlainText(_:)), "v", modifiers: [.command, .option, .shift])
        add(edit, String(localized: "刪除"), #selector(NSText.delete(_:)))
        add(edit, String(localized: "全選"), #selector(NSText.selectAll(_:)), "a")

        delegate.workspaceApplication.installMenu()
        let window = submenu(String(localized: "視窗"))
        NSApp.windowsMenu = window
        add(window, String(localized: "顯示主視窗"), #selector(WorkspaceApplicationController.showWorkspace), target: delegate.workspaceApplication)
        add(window, String(localized: "重新整理目前清單"), Selector(("reload:")), "r")
        add(window, String(localized: "縮小"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, String(localized: "縮放"), #selector(NSWindow.performZoom(_:)))
        add(window, String(localized: "切換全螢幕"), #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        window.addItem(.separator())
        add(window, String(localized: "全部移至最前"), #selector(NSApplication.arrangeInFront(_:)))
        let help = submenu(String(localized: "輔助說明"))
        NSApp.helpMenu = help
        add(help, String(localized: "上游 IINA+ 專案"), #selector(upstream), target: self)
        add(help, String(localized: "開啟日誌"), #selector(openLog), target: self)
    }

    @objc private func openFiles() {
        if openFilesWindow == nil {
            openFilesWindow = NSStoryboard(name: "OpenFilesWindow", bundle: nil)
                .instantiateInitialController() as? NSWindowController
        }
        openFilesWindow?.showWindow(nil)
        openFilesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func about() { delegate.workspaceApplication.showSetting("about.version") }
    @objc private func upstream() { NSWorkspace.shared.open(URL(string: "https://github.com/xjbeta/iina-plus")!) }
    @objc private func openLog() {
        if let url = delegate.logUrl { NSWorkspace.shared.open(url) }
    }
}
