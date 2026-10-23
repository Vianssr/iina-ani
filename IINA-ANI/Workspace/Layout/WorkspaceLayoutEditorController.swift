import AppKit
import UniformTypeIdentifiers

@MainActor
final class WorkspaceLayoutEditorController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Item {
        let id: UUID
        let title: String
        let node: WorkspaceNode?
        var children: [Item]
        init(id: UUID, title: String, node: WorkspaceNode?, children: [Item]) {
            self.id = id; self.title = title; self.node = node; self.children = children
        }
    }
    private final class InspectorDocument: NSView {
        override var isFlipped: Bool { true }
    }
    private let draft: WorkspaceLayoutEditor
    private let registry: WorkspaceRegistry
    private let commit: (WorkspaceLayout) throws -> Void
    private let preview: WorkspaceWindowController
    private let previewHost = NSView()
    private let inspector = NSStackView()
    private let inspectorTabs = NSSegmentedControl(labels: [String(localized: "編輯"), String(localized: "新增"), String(localized: "編排"), String(localized: "進階")], trackingMode: .selectOne, target: nil, action: nil)
    private enum SectionScope { case any, selection, page, component, split, arrangement }
    private var inspectorSections: [(view: NSView, tab: Int, scope: SectionScope)] = []
    private let widthStepper = NSStepper()
    private let heightStepper = NSStepper()
    private let paneCountStepper = NSStepper()
    private let paneScope = NSTextField(wrappingLabelWithString: "")
    private let ratioSlider = NSSlider(value: 0.5, minValue: 0.05, maxValue: 0.95, target: nil, action: nil)
    private let sizePresets = NSSegmentedControl(labels: [String(localized: "最小尺寸"), String(localized: "預設尺寸"), String(localized: "寬大尺寸")], trackingMode: .momentary, target: nil, action: nil)
    private let orientation = NSSegmentedControl(labels: [String(localized: "水平排列"), String(localized: "垂直排列")], trackingMode: .selectOne, target: nil, action: nil)
    private let selectedHeading = NSTextField(wrappingLabelWithString: String(localized: "尚未選取項目"))
    private let selectedDetail = NSTextField(wrappingLabelWithString: String(localized: "在畫布或編排樹中選取項目。"))
    private let canvasCaption = NSTextField(labelWithString: String(localized: "原生畫布"))
    private let componentDescriptors: [WorkspaceComponentDescriptor]
    private let containerKinds = WorkspaceContainerKind.allCases.filter { $0 != .page }
    private var toolbarButtons: [NSToolbarItem.Identifier: NSButton] = [:]
    private var previewPageID: UUID?
    private var isReloading = false
    private let outline = NSOutlineView()
    private let variants = NSPopUpButton()
    private let containers = NSPopUpButton()
    private let destinations = NSPopUpButton()
    private let name = NSTextField(string: String(localized: "新頁面"))
    private let width = NSTextField(string: "760")
    private let height = NSTextField(string: "480")
    private let ratio = NSTextField(string: "0.5")
    private let paneCount = NSTextField(string: "1")
    private let breakpointWidth = NSTextField(string: "1280")
    private let motionPresets = NSPopUpButton()
    private let motionDuration = NSTextField(string: "0")
    private let motionOpacity = NSTextField(string: "1")
    private let motionOffsetX = NSTextField(string: "0")
    private let motionOffsetY = NSTextField(string: "0")
    private let motionScale = NSTextField(string: "1")
    private let motionCurve = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var roots: [Item] = []
    private var destinationIDs: [UUID] = []
    private var variantKeys: [WorkspaceBreakpoint?] = []
    private let pasteboardType = NSPasteboard.PasteboardType("org.iina.workspace.layout-item")
    private var undoButton: NSButton!
    private var redoButton: NSButton!

    init(layout: WorkspaceLayout, registry: WorkspaceRegistry, initialWidth: Double = 1280, initialPageID: UUID? = nil,
         makePreview: (WorkspaceLayout) -> WorkspaceWindowController,
         commit: @escaping (WorkspaceLayout) throws -> Void) {
        self.draft = WorkspaceLayoutEditor(layout: layout, registry: registry)
        self.draft.breakpoint = layout.breakpointLayouts.keys.filter { $0.minimumWidth <= initialWidth }.max()
        self.registry = registry
        self.componentDescriptors = registry.descriptors
        self.commit = commit
        preview = makePreview(layout)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "編輯佈局 — 草稿（結束編輯才保存）")
        window.contentMinSize = NSSize(width: 1100, height: 700)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildControls()
        preview.onEditorSplitChange = { [weak self] id, value in
            guard let self else { return }
            self.perform {
                try self.draft.replace(nodeID: id) { node in
                    guard case .split(let id, let first, let second, _) = node else {
                        throw WorkspaceTransactionError.invalidDestination
                    }
                    return .split(id: id, first: first, second: second, ratio: value)
                }
            }
        }
        preview.onEditorResize = { [weak self] id, size in
            self?.resize(nodeID: id, requested: size)
        }
        preview.onEditorMove = { [weak self] source, target, after in
            guard let self else { return }
            self.perform(selecting: source) {
                try self.draft.move(nodeID: source, relativeTo: target, after: after)
            }
        }
        preview.onEditorSelection = { [weak self] id in
            guard let self else { return }
            self.previewPageID = self.pageID(containing: id)
            self.selectItem(id)
            self.updateSelection()
        }
        preview.embedLayoutEditorPreview(in: previewHost)
        previewHost.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(canvasResized),
                                               name: NSView.frameDidChangeNotification, object: previewHost)
        window.contentView?.layoutSubtreeIfNeeded()
        reload(selecting: initialPageID)
        window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func showEditor() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: previewHost)
        preview.onEditorSelection = nil
        preview.onEditorSplitChange = nil
        preview.onEditorResize = nil
        preview.onEditorMove = nil
        preview.close()
    }

    private func button(_ title: String, _ action: Selector, key: String = "", icon: WorkspaceIcon? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.setFunctionIcon(icon)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = [.command, .option]
        return button
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal; row.spacing = 6
        row.alignment = .centerY
        return row
    }
    private func label(_ title: String) -> NSTextField { NSTextField(labelWithString: title) }
    private func guidance(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func section(_ title: String, tab: Int = 0, scope: SectionScope = .any, views: [NSView]) {
        let heading = label(title)
        heading.font = .boldSystemFont(ofSize: 13)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        inspector.addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        inspectorSections.append((stack, tab, scope))
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let separator = NSBox()
        separator.boxType = .separator
        inspector.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        inspectorSections.append((separator, tab, scope))
    }
    @objc private func inspectorTabAction() {
        for section in inspectorSections {
            let matches: Bool
            switch section.scope {
            case .any: matches = true
            case .selection: matches = selection != nil
            case .page: matches = selectedPage != nil
            case .component:
                if case .component? = selection?.node { matches = true } else { matches = false }
            case .split:
                if case .split? = selection?.node { matches = true } else { matches = false }
            case .arrangement:
                if let node = selection?.node, WorkspaceEditorTree.isContainer(node) {
                    if case .tabs = node { matches = false } else { matches = true }
                } else { matches = false }
            }
            section.view.isHidden = section.tab != inspectorTabs.selectedSegment || !matches
        }
    }
    private func buildControls() {
        guard let content = window?.contentView else { return }
        undoButton = button(String(localized: "撤銷"), #selector(undoAction), key: "z")
        redoButton = button(String(localized: "重做"), #selector(redoAction), key: "Z")
        let save = button(String(localized: "保存並結束"), #selector(saveAction), key: "s", icon: .check)
        let cancel = button(String(localized: "取消編輯"), #selector(cancelAction), icon: .close)
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        for (id, control) in [
            ("save", save), ("cancel", cancel), ("undo", undoButton!), ("redo", redoButton!),
            ("reset", button(String(localized: "恢復內建草稿"), #selector(restoreAction), icon: .refresh))
        ] {
            toolbarButtons[NSToolbarItem.Identifier(id)] = control
            control.setAccessibilityLabel(control.title)
        }
        let toolbar = NSToolbar(identifier: "WorkspaceLayoutEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)

        let canvas = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvasCaption.font = .boldSystemFont(ofSize: 14)
        let canvasHeader = NSStackView(views: [
            canvasCaption, guidance(String(localized: "選取後拖曳標題移動，拖曳右側、底部或角落調整尺寸；分隔線可調比例。預覽不執行業務命令。"))
        ])
        canvasHeader.orientation = .vertical
        canvasHeader.alignment = .leading
        canvasHeader.spacing = 4
        canvas.addSubview(canvasHeader)
        canvas.addSubview(previewHost)
        canvasHeader.translatesAutoresizingMaskIntoConstraints = false
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewHost.setAccessibilityLabel(String(localized: "工作區原生編排畫布"))
        NSLayoutConstraint.activate([
            canvasHeader.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 16),
            canvasHeader.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -16),
            canvasHeader.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 12),
            previewHost.topAnchor.constraint(equalTo: canvasHeader.bottomAnchor, constant: 12),
            previewHost.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            previewHost.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            previewHost.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
        ])

        let inspectorPane = NSView()
        inspectorPane.translatesAutoresizingMaskIntoConstraints = false
        inspectorTabs.selectedSegment = 0
        inspectorTabs.target = self
        inspectorTabs.action = #selector(inspectorTabAction)
        inspectorTabs.setAccessibilityLabel(String(localized: "編輯工具分類"))
        let selectionHeader = NSStackView(views: [inspectorTabs, selectedHeading, selectedDetail])
        selectionHeader.orientation = .vertical
        selectionHeader.alignment = .leading
        selectionHeader.spacing = 6
        selectionHeader.translatesAutoresizingMaskIntoConstraints = false
        inspectorPane.addSubview(selectionHeader)
        let inspectorScroll = NSScrollView()
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.autohidesScrollers = true
        inspectorScroll.drawsBackground = true
        inspectorScroll.backgroundColor = .windowBackgroundColor
        inspectorScroll.translatesAutoresizingMaskIntoConstraints = false
        inspectorPane.addSubview(inspectorScroll)
        NSLayoutConstraint.activate([
            selectionHeader.topAnchor.constraint(equalTo: inspectorPane.topAnchor, constant: 16),
            selectionHeader.leadingAnchor.constraint(equalTo: inspectorPane.leadingAnchor, constant: 16),
            selectionHeader.trailingAnchor.constraint(equalTo: inspectorPane.trailingAnchor, constant: -16),
            selectedHeading.widthAnchor.constraint(equalTo: selectionHeader.widthAnchor),
            selectedDetail.widthAnchor.constraint(equalTo: selectionHeader.widthAnchor),
            inspectorScroll.topAnchor.constraint(equalTo: selectionHeader.bottomAnchor, constant: 12),
            inspectorScroll.leadingAnchor.constraint(equalTo: inspectorPane.leadingAnchor),
            inspectorScroll.trailingAnchor.constraint(equalTo: inspectorPane.trailingAnchor),
            inspectorScroll.bottomAnchor.constraint(equalTo: inspectorPane.bottomAnchor),
        ])
        let document = InspectorDocument()
        inspectorScroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 16
        inspector.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(inspector)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: inspectorScroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: inspectorScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: inspectorScroll.contentView.widthAnchor),
            inspector.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            inspector.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            inspector.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            inspector.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
        ])
        split.addArrangedSubview(canvas)
        split.addArrangedSubview(inspectorPane)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        let preferredInspectorWidth = inspectorPane.widthAnchor.constraint(equalToConstant: 350)
        preferredInspectorWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 700),
            inspectorPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 330),
            inspectorPane.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            preferredInspectorWidth,
        ])

        let treeScroll = NSScrollView()
        treeScroll.hasVerticalScroller = true
        treeScroll.hasHorizontalScroller = true
        treeScroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layout"))
        column.title = String(localized: "頁面與編排")
        column.width = 450
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 30
        outline.indentationPerLevel = 12
        outline.dataSource = self; outline.delegate = self
        outline.allowsMultipleSelection = false
        outline.registerForDraggedTypes([pasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel(String(localized: "工作區頁面與編排樹"))
        treeScroll.documentView = outline
        treeScroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        name.setAccessibilityLabel(String(localized: "頁面名稱"))
        name.placeholderString = String(localized: "頁面名稱")
        section(String(localized: "頁面與編排"), tab: 2, views: [
            guidance(String(localized: "拖曳項目至頁面、容器內或兩列之間；每次放下是一筆撤銷。")),
            treeScroll, name,
            row([button(String(localized: "新增頁"), #selector(addPageAction), icon: .add), button(String(localized: "更名"), #selector(renamePageAction))]),
            row([button(String(localized: "設為首頁"), #selector(homeAction)), button(String(localized: "顯示／隱藏導覽"), #selector(hiddenAction))]),
        ])

        motionPresets.addItem(withTitle: String(localized: "自訂參數"))
        WorkspacePageMotion.presets.forEach { motionPresets.addItem(withTitle: $0.title) }
        motionPresets.target = self; motionPresets.action = #selector(motionPresetAction)
        motionPresets.setAccessibilityLabel(String(localized: "頁面進場動效預設"))
        for curve in WorkspacePageMotion.Curve.allCases { motionCurve.addItem(withTitle: motionCurveTitle(curve)) }
        motionCurve.target = self; motionCurve.action = #selector(motionParameterAction)
        motionCurve.setAccessibilityLabel(String(localized: "頁面動效時間曲線"))
        for (field, title) in [
            (motionDuration, String(localized: "頁面動效時間，0 到 5 秒")),
            (motionOpacity, String(localized: "頁面動效起始不透明度，0 到 1")),
            (motionOffsetX, String(localized: "頁面動效起始水平位移，負 2048 到 2048 點")),
            (motionOffsetY, String(localized: "頁面動效起始垂直位移，負 2048 到 2048 點")),
            (motionScale, String(localized: "頁面動效起始縮放，0.1 到 4 倍"))
        ] {
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            field.setAccessibilityLabel(title)
            field.target = self; field.action = #selector(motionParameterAction)
        }
        let motionGuidance = guidance(String(localized: "選擇預設即更新草稿；精確參數與 XML 匯入位於「進階」。"))
        let importMotion = button(String(localized: "從 XML 載入…"), #selector(importMotionAction))
        let replayMotion = button(String(localized: "重播已套用動效"), #selector(replayMotionAction))
        importMotion.setAccessibilityLabel(String(localized: "從 XML 載入選取頁面的進場動效"))
        replayMotion.setAccessibilityLabel(String(localized: "在畫布重播選取頁面已套用的進場動效"))
        section(String(localized: "頁面進場動效"), scope: .page, views: [
            motionGuidance, motionPresets, replayMotion,
        ])
        section(String(localized: "進階頁面動效"), tab: 3, scope: .page, views: [
            guidance(String(localized: "輸入數值後按 Return，或選擇時間曲線，即更新此頁面的草稿。")),
            row([label(String(localized: "時間")), motionDuration, label(String(localized: "秒"))]),
            row([label(String(localized: "起始不透明度")), motionOpacity]),
            row([label(String(localized: "水平位移")), motionOffsetX, label("pt")]),
            row([label(String(localized: "垂直位移")), motionOffsetY, label("pt")]),
            row([label(String(localized: "起始縮放")), motionScale, label(String(localized: "倍"))]),
            motionCurve, importMotion,
            guidance(String(localized: "「無」沿用 Skin 動效；Skin 未配置則不播放。其他自訂動效優先於 Skin。不透明度 0–1、位移 ±2048 pt、縮放 0.1–4 倍；播放後恢復正常位置與大小。")),
        ])

        var componentButtons: [NSView] = []
        for (index, descriptor) in componentDescriptors.enumerated() {
            let control = button(Self.componentTitle(descriptor.id), #selector(addComponentAction(_:)), icon: .add)
            control.tag = index
            control.toolTip = String(localized: "加入 \(Self.componentTitle(descriptor.id))")
            componentButtons.append(control)
        }
        for kind in containerKinds { containers.addItem(withTitle: containerName(kind)) }
        containers.setAccessibilityLabel(String(localized: "容器類型"))
        section(String(localized: "多欄佈局"), scope: .page, views: [
            button(String(localized: "加入分欄容器"), #selector(addPageColumnsAction), icon: .add),
        ])
        let addPageColumns = button(String(localized: "加入分欄容器"), #selector(addPageColumnsAction), icon: .add)
        addPageColumns.setAccessibilityIdentifier("workspace.layout.addPageColumns")
        section(String(localized: "多欄佈局"), tab: 1, views: [
            addPageColumns,
            guidance(String(localized: "在目前頁面加入分欄容器，保留既有內容；加入後可調整欄數，再選取空白欄位加入組件。")),
        ])
        section(String(localized: "加入組件"), tab: 1, views: [
            guidance(String(localized: "先在畫布選取放置位置，再點選組件直接加入；新組件會自動選取。"))
        ] + componentButtons)
        section(String(localized: "容器與包裝"), tab: 3, views: [
            guidance(String(localized: "新增容器至選取位置，或將選取項目改為指定容器；組件會被包入新容器，子項目保留。")),
            containers,
            row([button(String(localized: "新增容器"), #selector(addContainerAction), icon: .add),
                 button(String(localized: "改容器類型"), #selector(convertContainerAction))]),
        ])
        selectedHeading.font = .boldSystemFont(ofSize: 14)
        selectedHeading.setAccessibilityLabel(String(localized: "目前選取項目"))
        selectedDetail.font = .systemFont(ofSize: 11)
        selectedDetail.textColor = .secondaryLabelColor
        section(String(localized: "選取項目"), scope: .selection, views: [
            button(String(localized: "刪除"), #selector(deleteAction), icon: .delete),
            guidance(String(localized: "刪除只移除佈局項目，不刪除收藏或停止已提交任務；取消編輯會捨棄草稿。")),
        ])
        section(String(localized: "組件顯示"), scope: .component, views: [
            button(String(localized: "折疊／展開"), #selector(collapseAction)),
        ])

        destinations.setAccessibilityLabel(String(localized: "鍵盤移動目的頁面或容器"))
        destinations.target = self; destinations.action = #selector(destinationAction)
        destinations.lineBreakMode = .byTruncatingMiddle
        width.setAccessibilityLabel(String(localized: "組件寬度，單位點，32 點吸附網格"))
        height.setAccessibilityLabel(String(localized: "組件高度，單位點，32 點吸附網格"))
        ratio.setAccessibilityLabel(String(localized: "分隔容器比例，0 到 1 之間"))
        for field in [width, height, ratio, breakpointWidth] {
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        for (stepper, title) in [(widthStepper, String(localized: "調整組件寬度")), (heightStepper, String(localized: "調整組件高度"))] {
            stepper.minValue = 0
            stepper.maxValue = Double.greatestFiniteMagnitude
            stepper.increment = 32
            stepper.valueWraps = false
            stepper.target = self
            stepper.action = #selector(sizeStepAction(_:))
            stepper.setAccessibilityLabel(title)
        }
        for field in [width, height] {
            field.target = self
            field.action = #selector(resizeAction)
        }
        ratio.target = self
        ratio.action = #selector(ratioAction)
        ratioSlider.target = self
        ratioSlider.action = #selector(ratioSliderAction)
        ratioSlider.isContinuous = false
        ratioSlider.setAccessibilityLabel(String(localized: "第一欄空間比例"))
        section(String(localized: "移動"), scope: .selection, views: [
            row([button(String(localized: "上移"), #selector(upAction), key: "\u{F700}"),
                 button(String(localized: "下移"), #selector(downAction), key: "\u{F701}")]),
            guidance(String(localized: "上移／下移調整同層順序；跨容器移動可拖曳標題，或使用「進階」的目的位置。")),
        ])
        section(String(localized: "跨容器移動"), tab: 3, scope: .selection, views: [
            guidance(String(localized: "明確選擇目的頁面或容器，再按「移至」。")),
            destinations, button(String(localized: "移至"), #selector(moveAction)),
        ])
        sizePresets.target = self
        sizePresets.action = #selector(sizePresetAction)
        sizePresets.setAccessibilityLabel(String(localized: "組件尺寸預設"))
        section(String(localized: "組件尺寸"), scope: .component, views: [
            sizePresets,
            row([label(String(localized: "寬")), width, widthStepper, label("pt")]),
            row([label(String(localized: "高")), height, heightStepper, label("pt")]),
            guidance(String(localized: "按步進器立即調整；輸入精確尺寸後按 Return。尺寸吸附至 32 pt 網格，不小於組件最小尺寸。")),
        ])
        section(String(localized: "分隔比例"), scope: .split, views: [
            row([label(String(localized: "分隔比例")), ratio]),
            ratioSlider,
            guidance(String(localized: "拖動滑桿後放開即更新，或直接拖曳畫布分隔線；精確比例輸入後按 Return。")),
        ])
        paneCount.widthAnchor.constraint(equalToConstant: 70).isActive = true
        paneCount.setAccessibilityLabel(String(localized: "同時顯示的面板欄數，至少 1 欄"))
        paneCount.setAccessibilityIdentifier("workspace.layout.paneCount")
        paneCount.target = self; paneCount.action = #selector(paneCountAction)
        paneCountStepper.minValue = 1
        paneCountStepper.maxValue = Double(WorkspaceValidator(registry: registry).maximumDepth)
        paneCountStepper.increment = 1
        paneCountStepper.valueWraps = false
        paneCountStepper.target = self; paneCountStepper.action = #selector(paneCountStepAction)
        paneCountStepper.setAccessibilityLabel(String(localized: "調整同時顯示的面板欄數"))
        paneCountStepper.setAccessibilityIdentifier("workspace.layout.paneCountStepper")
        paneScope.font = .systemFont(ofSize: 11)
        paneScope.textColor = .secondaryLabelColor
        let applyPaneCount = button(String(localized: "套用多欄佈局"), #selector(paneCountAction))
        applyPaneCount.setAccessibilityIdentifier("workspace.layout.applyPaneCount")
        section(String(localized: "多欄佈局"), scope: .arrangement, views: [
            row([label(String(localized: "欄數")), paneCount, paneCountStepper]),
            applyPaneCount,
            guidance(String(localized: "按步進器立即調整，或輸入欄數後按 Return／套用。新增欄位為空白放置區；減少欄數時，多出的內容會保留並垂直排列於最後一欄，不會刪除。")),
            paneScope,
        ])
        orientation.target = self
        orientation.action = #selector(orientationAction)
        orientation.setAccessibilityLabel(String(localized: "容器排列方向"))
        section(String(localized: "排列方向"), scope: .arrangement, views: [
            orientation,
            guidance(String(localized: "立即改為水平或垂直排列，保留容器與所有子項目的識別及順序。其他容器類型位於「進階」。")),
        ])
        variants.target = self; variants.action = #selector(variantAction)
        variants.setAccessibilityLabel(String(localized: "編輯視窗寬度斷點"))
        breakpointWidth.setAccessibilityLabel(String(localized: "新增斷點最小寬度，單位點"))
        section(String(localized: "寬度斷點"), tab: 3, views: [
            variants,
            guidance(String(localized: "編輯所選寬度版本。調整編輯視窗大小只改變畫布尺寸，不會自動切換此版本。")),
            row([label(String(localized: "最小寬度")), breakpointWidth, label("pt")]),
            row([button(String(localized: "新增斷點"), #selector(addBreakpointAction), icon: .add),
                 button(String(localized: "刪除斷點"), #selector(removeBreakpointAction), icon: .delete)]),
        ])

        status.stringValue = String(localized: "草稿模式：變更只在按下「保存並結束」後套用。")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.setAccessibilityLabel(String(localized: "編排操作結果"))
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(status)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["save", "cancel", "undo", "redo", "reset"].map { NSToolbarItem.Identifier($0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let control = toolbarButtons[itemIdentifier] else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = control.title
        item.view = control
        return item
    }
    static func componentTitle(_ id: WorkspaceComponentID) -> String {
        switch id.rawValue {
        case "detail.media": return String(localized: "作品詳情")
        case "settings.preferences": return String(localized: "偏好設定")
        case "torrent.import": return String(localized: "種子匯入")
        case "discovery.schedule": return String(localized: "播出時間表")
        case "discovery.followed": return String(localized: "關注動態")
        case "discovery.bilibiliRecommendations": return String(localized: "Bilibili 推薦影片")
        case "discovery.youtube": return "YouTube"
        case "discovery.updates": return String(localized: "收藏更新")
        case "discovery.recommendations": return String(localized: "熱門趨勢")
        case "discovery.feed": return String(localized: "推薦")
        case "playback.continue": return String(localized: "繼續觀看")
        case "search.results": return String(localized: "搜尋結果")
        case "downloads.tasks": return String(localized: "下載任務")
        case "favorites.works": return String(localized: "收藏作品")
        case "favorites.links": return String(localized: "收藏連結")
        default: return String(localized: "自訂組件（\(id.rawValue)）")
        }
    }
    private func containerName(_ kind: WorkspaceContainerKind) -> String {
        switch kind {
        case .page: return String(localized: "頁面")
        case .grid: return String(localized: "網格容器")
        case .horizontalStack: return String(localized: "水平排列")
        case .verticalStack: return String(localized: "垂直排列")
        case .split: return String(localized: "分割容器")
        case .group: return String(localized: "群組容器")
        case .tabs: return String(localized: "分頁容器")
        }
    }
    private func motionCurveTitle(_ curve: WorkspacePageMotion.Curve) -> String {
        switch curve {
        case .linear: return String(localized: "線性（linear）")
        case .easeIn: return String(localized: "慢入（easeIn）")
        case .easeOut: return String(localized: "慢出（easeOut）")
        case .easeInOut: return String(localized: "慢入慢出（easeInOut）")
        }
    }
    private var selection: Item? { outline.item(atRow: outline.selectedRow) as? Item }
    private func perform(selecting selectedID: UUID? = nil, _ action: () throws -> Void) {
        let selected = selectedID ?? selection?.id
        do { try action(); setStatus(String(localized: "草稿已更新；尚未保存。")); reload(selecting: selected) }
        catch { setStatus(error.localizedDescription, isError: true); NSSound.beep() }
    }
    private func reload(selecting id: UUID? = nil) {
        let selectedID = id ?? selection?.id
        let destinationID = destination
        isReloading = true
        func item(_ node: WorkspaceNode) -> Item {
            let title: String
            switch node {
            case .component(_, let type, _, _, let size):
                title = "\(Self.componentTitle(type)) — \(Int(size.width)) × \(Int(size.height)) pt\(draft.layout.collapsedInstanceIDs.contains(node.id) ? String(localized: "（折疊）") : "")"
            case .empty: title = String(localized: "空白放置區")
            case .grid: title = containerName(.grid)
            case .horizontalStack: title = containerName(.horizontalStack)
            case .verticalStack: title = containerName(.verticalStack)
            case .group: title = containerName(.group)
            case .split(_, _, _, let value): title = "\(containerName(.split)) — \(String(format: "%.2f", value))"
            case .tabs: title = containerName(.tabs)
            }
            let children: [Item]
            if case .tabs(_, _, let pages) = node {
                children = pages.map {
                    Item(id: $0.id, title: String(localized: "\($0.displayTitle)（巢狀頁面）"), node: nil, children: [item($0.root)])
                }
            } else {
                children = WorkspaceEditorTree.children(node).map(item)
            }
            return Item(id: node.id, title: title, node: node, children: children)
        }
        roots = draft.pages.map { page in
            Item(id: page.id, title: "\(page.displayTitle)\(draft.layout.homePageID == page.id ? String(localized: "（首頁）") : "")\(draft.layout.hiddenPageIDs.contains(page.id) ? String(localized: "（隱藏）") : "")",
                 node: nil, children: [item(page.root)])
        }
        outline.reloadData(); outline.expandItem(nil, expandChildren: true)
        if selectedID.map({ selectItem($0) }) != true {
            let fallback = roots.first { $0.id == previewPageID } ?? roots.first { $0.id == draft.layout.homePageID } ?? roots.first
            if let fallback { selectItem(fallback.id) }
        }
        variants.removeAllItems(); variantKeys = [nil] + draft.layout.breakpointLayouts.keys.sorted().map { Optional($0) }
        for key in variantKeys { variants.addItem(withTitle: key.map { "≥ \(Int($0.minimumWidth)) pt" } ?? String(localized: "基礎排列")) }
        variants.selectItem(at: variantKeys.firstIndex(where: { $0 == draft.breakpoint }) ?? 0)
        destinations.removeAllItems(); destinationIDs = []
        func destinationsFor(_ item: Item, path: String) {
            let path = path.isEmpty ? item.title : "\(path) / \(item.title)"
            if item.node == nil || item.node.map(WorkspaceEditorTree.isContainer) == true || { if case .empty? = item.node { return true }; return false }() {
                destinations.addItem(withTitle: path); destinationIDs.append(item.id)
                destinations.lastItem?.toolTip = path
            }
            item.children.forEach { destinationsFor($0, path: path) }
        }
        roots.forEach { destinationsFor($0, path: "") }
        if let destinationID, let index = destinationIDs.firstIndex(of: destinationID) { destinations.selectItem(at: index) }
        isReloading = false
        undoButton.isEnabled = draft.canUndo; redoButton.isEnabled = draft.canRedo
        updatePreview()
        updateSelection()
    }
    private func pageID(containing id: UUID) -> UUID? {
        func contains(_ node: WorkspaceNode) -> Bool {
            if node.id == id { return true }
            if case .tabs(_, _, let pages) = node, pages.contains(where: { $0.id == id }) { return true }
            return WorkspaceEditorTree.children(node).contains(where: contains)
        }
        return draft.pages.first { $0.id == id || contains($0.root) }?.id
    }
    @discardableResult
    private func selectItem(_ id: UUID) -> Bool {
        func path(to id: UUID, in items: [Item]) -> [Item]? {
            for item in items {
                if item.id == id { return [item] }
                if let descendants = path(to: id, in: item.children) { return [item] + descendants }
            }
            return nil
        }
        guard let ancestors = path(to: id, in: roots) else { return false }
        let wasReloading = isReloading
        isReloading = true
        defer { isReloading = wasReloading }
        ancestors.dropLast().forEach { outline.expandItem($0) }
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? Item)?.id == id {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            return true
        }
        return false
    }
    private func updatePreview() {
        previewPageID = selection.flatMap { pageID(containing: $0.id) }
            ?? draft.pages.first(where: { $0.id == previewPageID })?.id
            ?? draft.pages.first?.id
        preview.updateNativePreview(draft.layout, pageID: previewPageID, breakpoint: draft.breakpoint)
        preview.highlightEditorSelection(selection?.id)
        updateCanvasCaption()
    }
    private func updateCanvasCaption() {
        let page = draft.pages.first { $0.id == previewPageID }?.displayTitle ?? String(localized: "未選取頁面")
        let version = draft.breakpoint.map { "≥ \(Int($0.minimumWidth)) pt" } ?? String(localized: "基礎排列")
        canvasCaption.stringValue = String(localized: "\(page) · \(version) · 畫布 \(Int(previewHost.bounds.width)) pt")
    }
    @objc private func canvasResized(_ notification: Notification) {
        updateCanvasCaption()
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let selectedPageID = selection.flatMap { pageID(containing: $0.id) }
        if let selectedPageID, selectedPageID != previewPageID { updatePreview() }
        updateSelection()
    }
    private func updateSelection() {
        switch selection?.node {
        case .horizontalStack?: orientation.selectedSegment = 0
        case .verticalStack?: orientation.selectedSegment = 1
        default: orientation.selectedSegment = -1
        }
        if let node = selection?.node {
            let count: Int
            switch node {
            case .split, .horizontalStack: count = WorkspaceEditorTree.panes(node).count
            default: count = 1
            }
            paneCount.integerValue = count
            paneCountStepper.integerValue = count
        }
        let version = draft.breakpoint.map { "≥ \(Int($0.minimumWidth)) pt" } ?? String(localized: "基礎排列")
        paneScope.stringValue = String(localized: "目前編輯：\(version)。只變更此寬度版本，不影響其他斷點。")
        if let item = selection {
            selectedHeading.stringValue = item.title
            selectedHeading.toolTip = item.id.uuidString
            if item.node == nil {
                name.stringValue = selectedPage?.displayTitle ?? ""
                selectedDetail.stringValue = isTopLevelPage(item.id)
                    ? String(localized: "頁面：可更名、設為首頁、切換導覽列顯示，或設定進場動效。")
                    : String(localized: "巢狀頁面：可設定此分頁的進場動效；展開後可編輯其容器與組件。")
            } else {
                selectedDetail.stringValue = String(localized: "容器：可移動、刪除，或變更排列類型。")
            }
            if case .component(_, let type, _, _, let size)? = item.node {
                width.doubleValue = size.width; height.doubleValue = size.height
                if let minimum = registry.descriptor(for: type)?.minimumSize {
                    widthStepper.minValue = minimum.width
                    heightStepper.minValue = minimum.height
                }
                widthStepper.doubleValue = size.width
                heightStepper.doubleValue = size.height
                let minimum = registry.descriptor(for: type)?.minimumSize
                selectedDetail.stringValue = minimum.map {
                    String(localized: "組件：最小 \(Int($0.width)) × \(Int($0.height)) pt；尺寸欄位以點（pt）為單位。")
                } ?? String(localized: "組件：可調整尺寸、折疊或移動。")
            }
            if case .split(_, _, _, let value)? = item.node {
                ratio.doubleValue = value
                ratioSlider.doubleValue = value
                selectedDetail.stringValue = String(localized: "分隔容器：比例控制第一欄所占空間，亦可拖曳畫布分隔線。")
            }
            if case .empty? = item.node {
                selectedDetail.stringValue = String(localized: "空白放置區：可在此插入組件或容器。")
            }
        } else {
            selectedHeading.stringValue = String(localized: "尚未選取項目")
            selectedHeading.toolTip = nil
            selectedDetail.stringValue = String(localized: "在畫布或編排樹中選取頁面、容器或組件。")
        }
        updateMotionControls()
        preview.highlightEditorSelection(selection?.id)
        updateCanvasCaption()
        updateControls()
        inspectorTabAction()
    }
    private func setStatus(_ text: String, isError: Bool = false) {
        status.stringValue = isError ? String(localized: "操作未完成：\(text)") : text
        status.textColor = isError ? .systemRed : .secondaryLabelColor
        status.font = isError ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
    }
    private func isTopLevelPage(_ id: UUID) -> Bool { draft.pages.contains { $0.id == id } }
    private var selectedPage: WorkspacePage? {
        guard let item = selection, item.node == nil else { return nil }
        return WorkspaceEditorTree.findPage(item.id, in: draft.pages)
    }
    private var selectedNodeSiblings: (parentID: UUID, items: [Item])? {
        guard let item = selection, item.node != nil,
              let parent = outline.parent(forItem: item) as? Item else { return nil }
        if parent.node == nil, !isTopLevelPage(parent.id),
           let tabs = outline.parent(forItem: parent) as? Item {
            return (tabs.id, tabs.children.compactMap { $0.children.first })
        }
        return (parent.id, parent.children)
    }
    private func updateMotionControls() {
        let page = selectedPage
        let motion = page?.motion ?? .none
        motionDuration.doubleValue = motion.duration
        motionOpacity.doubleValue = motion.opacity
        motionOffsetX.doubleValue = motion.offsetX
        motionOffsetY.doubleValue = motion.offsetY
        motionScale.doubleValue = motion.scale
        motionCurve.selectItem(at: WorkspacePageMotion.Curve.allCases.firstIndex(of: motion.curve) ?? 0)
        let preset = WorkspacePageMotion.presets.firstIndex { $0.motion == motion }
        motionPresets.selectItem(at: preset.map { $0 + 1 } ?? 0)
        for control in [motionPresets, motionDuration, motionOpacity, motionOffsetX, motionOffsetY, motionScale, motionCurve] as [NSControl] {
            control.isEnabled = page != nil
        }
    }
    @objc private func destinationAction() { updateControls() }
    private func updateControls() {
        let item = selection
        let isPage = item != nil && item?.node == nil
        let isTopLevelPage = item.map { self.isTopLevelPage($0.id) } ?? false
        let isComponent: Bool = { if case .component? = item?.node { return true }; return false }()
        let isSplit: Bool = { if case .split? = item?.node { return true }; return false }()
        func update(_ view: NSView) {
            if let button = view as? NSButton, let action = button.action {
                switch action {
                case #selector(renamePageAction), #selector(homeAction), #selector(hiddenAction):
                    button.isEnabled = isTopLevelPage
                case #selector(importMotionAction), #selector(replayMotionAction):
                    button.isEnabled = selectedPage != nil
                case #selector(collapseAction), #selector(resizeAction):
                    button.isEnabled = isComponent
                case #selector(ratioAction):
                    button.isEnabled = isSplit
                case #selector(convertContainerAction):
                    button.isEnabled = item?.node != nil
                case #selector(deleteAction):
                    button.isEnabled = item?.node != nil || isTopLevelPage
                case #selector(moveAction):
                    button.isEnabled = item?.node != nil && destination != nil
                case #selector(addComponentAction(_:)), #selector(addContainerAction):
                    button.isEnabled = insertionDestination != nil
                case #selector(removeBreakpointAction):
                    button.isEnabled = draft.breakpoint != nil
                case #selector(upAction), #selector(downAction):
                    let siblings = isPage ? (isTopLevelPage ? roots : []) : (selectedNodeSiblings?.items ?? [])
                    let index = siblings.firstIndex { $0.id == item?.id }
                    button.isEnabled = index.map { action == #selector(upAction) ? $0 > 0 : $0 + 1 < siblings.count } ?? false
                default: break
                }
            }
            view.subviews.forEach(update)
        }
        update(inspector)
        width.isEnabled = isComponent; height.isEnabled = isComponent; ratio.isEnabled = isSplit
        widthStepper.isEnabled = isComponent
        heightStepper.isEnabled = isComponent
        ratioSlider.isEnabled = isSplit
        sizePresets.isEnabled = isComponent
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Item)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Item).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let view = NSTextField(labelWithString: (item as! Item).title)
        view.setAccessibilityLabel((item as! Item).title)
        view.toolTip = "\((item as! Item).title)\n\((item as! Item).id.uuidString)"
        view.lineBreakMode = .byTruncatingTail
        return view
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        let item = item as! Item
        guard item.node != nil || isTopLevelPage(item.id) else { return nil }
        let writer = NSPasteboardItem()
        writer.setString("\(item.node == nil ? "page" : "node"):\(item.id.uuidString)", forType: pasteboardType)
        return writer
    }
    private func dragged(_ info: NSDraggingInfo) -> (Bool, UUID)? {
        guard let raw = info.draggingPasteboard.string(forType: pasteboardType) else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        return (parts[0] == "page", id)
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let (page, id) = dragged(info) else { return [] }
        let trial = WorkspaceLayoutEditor(layout: draft.layout, registry: registry); trial.breakpoint = draft.breakpoint
        do {
            if page {
                guard item == nil else { return [] }
                let old = draft.pages.firstIndex { $0.id == id } ?? 0
                try trial.reorderPage(id, to: max(0, index - (old < index ? 1 : 0)))
            } else {
                guard let target = item as? Item else { return [] }
                try trial.move(nodeID: id, to: target.id, index: index < 0 ? Int.max : index)
            }
            return .move
        } catch { return [] }
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let (page, id) = dragged(info) else { return false }
        do {
            if page {
                let old = draft.pages.firstIndex { $0.id == id } ?? 0
                try draft.reorderPage(id, to: max(0, index - (old < index ? 1 : 0)))
            } else {
                guard let target = item as? Item else { return false }
                try draft.move(nodeID: id, to: target.id, index: index < 0 ? Int.max : index)
            }
            setStatus(String(localized: "拖曳已完成（一筆撤銷）；尚未保存。"))
            reload(selecting: id); return true
        } catch { setStatus(error.localizedDescription, isError: true); return false }
    }
    @objc private func variantAction() {
        draft.breakpoint = variantKeys[variants.indexOfSelectedItem]; reload()
    }
    @objc private func addBreakpointAction() { perform { try draft.addBreakpoint(width: breakpointWidth.doubleValue) } }
    @objc private func removeBreakpointAction() { perform { try draft.removeBreakpoint() } }
    @objc private func addPageAction() { perform { try draft.addPage(title: name.stringValue) } }
    @objc private func renamePageAction() {
        guard let item = selection, isTopLevelPage(item.id),
              name.stringValue != selectedPage?.displayTitle else { return }
        perform { try draft.renamePage(item.id, title: name.stringValue) }
    }
    @objc private func homeAction() { guard let item = selection, isTopLevelPage(item.id) else { return }; perform { try draft.setHome(item.id) } }
    @objc private func hiddenAction() { guard let item = selection, isTopLevelPage(item.id) else { return }; perform { try draft.toggleHidden(item.id) } }
    private func performMotionChange(pageID: UUID, _ makeMotion: () throws -> WorkspacePageMotion) {
        var applied: WorkspacePageMotion?
        perform {
            let motion = try makeMotion()
            try draft.setPageMotion(pageID: pageID, motion: motion)
            applied = motion
        }
        if let applied { preview.previewPageMotion(applied, pageID: pageID) }
    }
    @objc private func motionParameterAction() { applyMotionAction() }
    @objc private func motionPresetAction() {
        guard let page = selectedPage else { return }
        let index = motionPresets.indexOfSelectedItem - 1
        guard WorkspacePageMotion.presets.indices.contains(index) else { return }
        let motion = WorkspacePageMotion.presets[index].motion
        performMotionChange(pageID: page.id) { motion }
    }
    @objc private func applyMotionAction() {
        guard let page = selectedPage else { return }
        performMotionChange(pageID: page.id) {
            func number(_ field: NSTextField, title: String) throws -> Double {
                guard let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
                    throw NSError(domain: "WorkspacePageMotionEditor", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: String(localized: "\(title)必須是有限的數字。")])
                }
                return value
            }
            let curves = WorkspacePageMotion.Curve.allCases
            guard curves.indices.contains(motionCurve.indexOfSelectedItem) else {
                throw WorkspaceTransactionError.invalidDestination
            }
            let motion = try WorkspacePageMotion(
                duration: number(motionDuration, title: String(localized: "時間")),
                opacity: number(motionOpacity, title: String(localized: "起始不透明度")),
                offsetX: number(motionOffsetX, title: String(localized: "水平位移")),
                offsetY: number(motionOffsetY, title: String(localized: "垂直位移")),
                scale: number(motionScale, title: String(localized: "起始縮放")),
                curve: curves[motionCurve.indexOfSelectedItem])
            return motion
        }
    }
    @objc private func importMotionAction() {
        guard let page = selectedPage else { return }
        let breakpoint = draft.breakpoint
        let panel = NSOpenPanel()
        panel.title = String(localized: "載入頁面進場動效")
        panel.message = String(localized: "將 XML 動效套用至「\(page.displayTitle)」的目前寬度版本；取消或載入失敗不會更改草稿。")
        panel.prompt = String(localized: "載入動效")
        panel.allowedContentTypes = [.xml]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard selectedPage?.id == page.id, draft.breakpoint == breakpoint else {
            setStatus(String(localized: "選取頁面或寬度版本已變更，未載入 XML；草稿保留。"), isError: true)
            return
        }
        performMotionChange(pageID: page.id) { try WorkspacePageMotion.loadXML(from: url) }
    }
    @objc private func replayMotionAction() {
        guard let page = selectedPage else { return }
        preview.previewPageMotion(page.motion, pageID: page.id)
        setStatus(String(localized: "已重播「\(page.displayTitle)」的已套用動效；草稿未改變。"))
    }
    private var destination: UUID? {
        guard destinations.indexOfSelectedItem >= 0, destinations.indexOfSelectedItem < destinationIDs.count else { return nil }
        return destinationIDs[destinations.indexOfSelectedItem]
    }
    private var insertionDestination: UUID? {
        if let item = selection, item.node == nil || item.node.map(WorkspaceEditorTree.isContainer) == true { return item.id }
        if let item = selection, case .empty? = item.node { return item.id }
        if let item = selection, let parent = outline.parent(forItem: item) as? Item { return parent.id }
        return destination
    }
    private var selectedContainerKind: WorkspaceContainerKind? {
        let index = containers.indexOfSelectedItem
        return containerKinds.indices.contains(index) ? containerKinds[index] : nil
    }
    @objc private func addComponentAction(_ sender: NSButton) {
        guard componentDescriptors.indices.contains(sender.tag), let target = insertionDestination else { return }
        let descriptor = componentDescriptors[sender.tag]
        let id = UUID()
        do {
            try draft.insert(.component(id: id, componentID: descriptor.id, contractVersion: descriptor.contractVersion,
                parameters: [:], size: descriptor.defaultSize), to: target)
            inspectorTabs.selectedSegment = 0
            setStatus(String(localized: "已加入「\(Self.componentTitle(descriptor.id))」；可直接調整，尚未保存。"))
            reload(selecting: id)
        } catch { setStatus(error.localizedDescription, isError: true); NSSound.beep() }
    }
    @objc private func addContainerAction() {
        guard let target = insertionDestination, let kind = selectedContainerKind else { return }
        let node = WorkspaceEditorTree.container(kind, children: [])
        perform(selecting: node.id) { try draft.insert(node, to: target) }
    }
    @objc private func addPageColumnsAction() {
        guard let pageID = selectedPage?.id ?? previewPageID else { return }
        let node = WorkspaceEditorTree.paneContainer(id: UUID(), children: [
            .empty(id: UUID()), .empty(id: UUID()),
        ])
        do {
            try draft.insert(node, to: pageID)
            inspectorTabs.selectedSegment = 0
            setStatus(String(localized: "草稿已更新；尚未保存。"))
            reload(selecting: node.id)
        } catch { setStatus(error.localizedDescription, isError: true); NSSound.beep() }
    }
    private func containerKind(of node: WorkspaceNode) -> WorkspaceContainerKind? {
        switch node {
        case .grid: return .grid
        case .horizontalStack: return .horizontalStack
        case .verticalStack: return .verticalStack
        case .split: return .split
        case .group: return .group
        case .tabs: return .tabs
        case .component, .empty: return nil
        }
    }
    private func convertSelection(to kind: WorkspaceContainerKind) {
        guard let item = selection, let node = item.node, containerKind(of: node) != kind else { return }
        let id = WorkspaceEditorTree.isContainer(node) ? node.id : UUID()
        perform(selecting: id) {
            try draft.replace(nodeID: item.id) { _ in
                WorkspaceEditorTree.container(kind, id: id,
                    children: WorkspaceEditorTree.isContainer(node) ? WorkspaceEditorTree.children(node) : [node])
            }
        }
    }
    @objc private func convertContainerAction() {
        guard let kind = selectedContainerKind else { return }
        convertSelection(to: kind)
    }
    @objc private func orientationAction() {
        guard let node = selection?.node, WorkspaceEditorTree.isContainer(node) else { return }
        if case .tabs = node { return }
        guard orientation.selectedSegment == 0 || orientation.selectedSegment == 1 else { return }
        convertSelection(to: orientation.selectedSegment == 0 ? .horizontalStack : .verticalStack)
    }
    @objc private func paneCountStepAction() {
        paneCount.integerValue = paneCountStepper.integerValue
        paneCountAction()
    }
    @objc private func paneCountAction() {
        guard let item = selection, let node = item.node, WorkspaceEditorTree.isContainer(node) else { return }
        if case .tabs = node { return }
        guard let count = Int(paneCount.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              count >= 1 else {
            setStatus(String(localized: "欄數必須是至少 1 的整數。"), isError: true)
            NSSound.beep()
            return
        }
        perform(selecting: item.id) { try draft.setPaneCount(nodeID: item.id, count: count) }
    }
    private func reorder(_ delta: Int) {
        guard let item = selection else { return }
        guard item.node != nil || isTopLevelPage(item.id) else { return }
        perform {
            if item.node == nil, let index = draft.pages.firstIndex(where: { $0.id == item.id }) {
                try draft.reorderPage(item.id, to: index + delta)
            } else if let siblings = selectedNodeSiblings,
                      let index = siblings.items.firstIndex(where: { $0.id == item.id }) {
                guard index + delta >= 0, index + delta < siblings.items.count else { return }
                try draft.move(nodeID: item.id, to: siblings.parentID, index: index + delta + (delta > 0 ? 1 : 0))
            }
        }
    }
    @objc private func upAction() { reorder(-1) }
    @objc private func downAction() { reorder(1) }
    @objc private func moveAction() { guard let item = selection, item.node != nil, let destination else { return }; perform { try draft.move(nodeID: item.id, to: destination, index: Int.max) } }
    @objc private func collapseAction() { guard let item = selection, case .component? = item.node else { return }; perform { try draft.toggleCollapsed(item.id) } }
    @objc private func deleteAction() {
        guard let item = selection else { return }
        guard item.node != nil || isTopLevelPage(item.id) else { return }
        perform { if item.node == nil { try draft.removePage(item.id) } else { try draft.remove(nodeID: item.id) } }
    }
    @objc private func sizeStepAction(_ sender: NSStepper) {
        if sender === widthStepper { width.doubleValue = sender.doubleValue }
        else { height.doubleValue = sender.doubleValue }
        resizeAction()
    }
    @objc private func ratioSliderAction() {
        ratio.doubleValue = ratioSlider.doubleValue
        ratioAction()
    }
    @objc private func sizePresetAction() {
        guard let item = selection, case .component(_, let type, _, _, _)? = item.node,
              let descriptor = registry.descriptor(for: type) else { return }
        let requested: WorkspaceSize
        switch sizePresets.selectedSegment {
        case 0: requested = descriptor.minimumSize
        case 1: requested = descriptor.defaultSize
        case 2:
            requested = WorkspaceSize(width: descriptor.defaultSize.width * 1.25,
                                      height: descriptor.defaultSize.height * 1.25)
        default: return
        }
        resize(nodeID: item.id, requested: requested, snapToGrid: sizePresets.selectedSegment == 2)
    }
    @objc private func resizeAction() {
        guard let item = selection else { return }
        guard let requestedWidth = Double(width.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let requestedHeight = Double(height.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            setStatus(String(localized: "尺寸必須是有限的數字。"), isError: true)
            NSSound.beep()
            return
        }
        resize(nodeID: item.id, requested: WorkspaceSize(width: requestedWidth, height: requestedHeight))
    }
    private func resize(nodeID: UUID, requested: WorkspaceSize, snapToGrid: Bool = true) {
        perform(selecting: nodeID) {
            guard requested.width.isFinite, requested.height.isFinite else {
                throw NSError(domain: "WorkspaceLayoutEditor", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "尺寸必須是有限的數字。")])
            }
            try draft.replace(nodeID: nodeID) { node in
                guard case .component(let id, let type, let version, let parameters, let original) = node,
                      let descriptor = registry.descriptor(for: type) else {
                    throw WorkspaceTransactionError.invalidDestination
                }
                func dimension(_ value: Double, original: Double, minimum: Double) -> Double {
                    guard value != original else { return original }
                    return max(minimum, snapToGrid ? (value / 32).rounded() * 32 : value)
                }
                let size = WorkspaceSize(
                    width: dimension(requested.width, original: original.width, minimum: descriptor.minimumSize.width),
                    height: dimension(requested.height, original: original.height, minimum: descriptor.minimumSize.height))
                return .component(id: id, componentID: type, contractVersion: version, parameters: parameters, size: size)
            }
        }
    }
    @objc private func ratioAction() {
        guard let item = selection else { return }
        perform { try draft.replace(nodeID: item.id) { node in
            guard case .split(let id, let first, let second, _) = node else { throw WorkspaceTransactionError.invalidDestination }
            return .split(id: id, first: first, second: second, ratio: ratio.doubleValue)
        } }
    }
    @objc private func undoAction() { draft.undo(); setStatus(String(localized: "已撤銷；尚未保存。")); reload() }
    @objc private func redoAction() { draft.redo(); setStatus(String(localized: "已重做；尚未保存。")); reload() }
    @objc private func restoreAction() { perform { try draft.restore() } }
    @objc private func saveAction() {
        do { try commit(draft.layout); close() }
        catch { setStatus(String(localized: "保存失敗，草稿保留：\(error.localizedDescription)"), isError: true) }
    }
    @objc private func cancelAction() { close() }
}
