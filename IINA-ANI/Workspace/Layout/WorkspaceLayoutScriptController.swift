import AppKit
import UniformTypeIdentifiers
private enum WorkspaceLayoutScriptControllerError: LocalizedError {
    case invalidConfiguration
    case sourceTooLarge
    case invalidSourceEncoding

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return String(localized: "設定必須是 JSON 物件，且不得超過輸入上限。")
        case .sourceTooLarge: return String(localized: "腳本超過允許的來源大小。")
        case .invalidSourceEncoding: return String(localized: "腳本必須使用 UTF-8 編碼。")
        }
    }
}

/// Explicitly reviews a validated candidate in native Workspace chrome before touching the saved layout.
@MainActor
final class WorkspaceLayoutScriptController: NSObject {
    private let runner: WorkspaceLayoutScriptRunner
    private let validator: WorkspaceValidator
    private let currentLayout: () throws -> WorkspaceLayout
    private let makePreview: (WorkspaceLayout) -> WorkspaceWindowController
    private let applyLayout: (WorkspaceLayout) throws -> Void
    private var generationTask: Task<Void, Never>?
    private var activeGeneration: UUID?

    init(
        runner: WorkspaceLayoutScriptRunner = WorkspaceLayoutScriptRunner(),
        registry: any WorkspaceComponentRegistry = WorkspaceRegistry.builtins,
        currentLayout: @escaping () throws -> WorkspaceLayout,
        makePreview: @escaping (WorkspaceLayout) -> WorkspaceWindowController,
        applyLayout: @escaping (WorkspaceLayout) throws -> Void
    ) {
        self.runner = runner
        validator = WorkspaceValidator(registry: registry)
        self.currentLayout = currentLayout
        self.makePreview = makePreview
        self.applyLayout = applyLayout
    }

    /// Programmatic candidates still pass validation and require explicit native preview confirmation.
    @discardableResult
    func preview(candidate: WorkspaceLayout, sourceName: String = "Generated layout") throws -> Bool {
        let baseline = try currentLayout()
        return try review(candidate: candidate, baseline: baseline, sourceName: sourceName)
    }

    private func review(
        candidate: WorkspaceLayout, baseline: WorkspaceLayout, sourceName: String
    ) throws -> Bool {
        try validator.validate(candidate)
        guard baseline != candidate else {
            showMessage(String(localized: "佈局沒有變更"), detail: String(localized: "候選佈局與目前工作區相同。"))
            return false
        }

        let difference = NSAlert()
        difference.messageText = String(localized: "檢閱工作區佈局差異")
        difference.informativeText = String(localized: "來源：\(sourceName)\n按「繼續預覽」後，候選佈局會在服務隔離的原生預覽視窗中開啟。只有在預覽視窗按下「套用此佈局」才會替換目前工作區。")
        difference.addButton(withTitle: String(localized: "繼續預覽"))
        difference.addButton(withTitle: String(localized: "取消"))
        difference.accessoryView = differenceView(before: baseline, after: candidate)
        guard difference.runModal() == .alertFirstButtonReturn else { return false }

        let preview = makePreview(candidate)
        defer { preview.close() }
        guard preview.reviewNativePreview() else { return false }
        guard try currentLayout() == baseline else {
            showMessage(String(localized: "工作區已變更"), detail: String(localized: "預覽期間目前工作區已被其他操作修改；候選佈局未套用。請重新執行並檢閱最新差異。"))
            return false
        }
        try applyLayout(candidate)
        return true
    }

    /// Opens a source chooser only when the release-security gate is explicitly enabled.
    func chooseAndRunSource() {
        guard WorkspaceLayoutScriptRunner.externalImportEnabled else {
            showMessage(String(localized: "佈局腳本尚未開放"), detail: String(localized: "外部腳本匯入仍受安全關卡保護。"))
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "js")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "執行並預覽")
        let configurationField = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 88))
        configurationField.string = "{}"
        configurationField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let configLabel = NSTextField(labelWithString: String(localized: "設定 JSON（僅傳入此腳本，不含帳號或工作區資料）"))
        let configStack = NSStackView(views: [configLabel, configurationField])
        configStack.orientation = .vertical
        configStack.alignment = .leading
        configStack.spacing = 4
        configStack.frame = NSRect(x: 0, y: 0, width: 440, height: 112)
        panel.accessoryView = configStack
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let configurationData = Data(configurationField.string.utf8)
            guard configurationData.count <= WorkspaceLayoutScriptRunner.maximumInputBytes,
                case .object(let configuration) = try JSONDecoder().decode(
                    WorkspaceJSONValue.self, from: configurationData)
            else { throw WorkspaceLayoutScriptControllerError.invalidConfiguration }
            let source = try readSource(at: url)
            let baseline = try currentLayout()
            generationTask?.cancel()
            let generation = UUID()
            activeGeneration = generation
            generationTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if activeGeneration == generation {
                        activeGeneration = nil
                        generationTask = nil
                    }
                }
                do {
                    let candidate = try await runner.generate(source: source, configuration: configuration)
                    guard activeGeneration == generation, !Task.isCancelled else { return }
                    _ = try review(candidate: candidate, baseline: baseline, sourceName: url.lastPathComponent)
                } catch {
                    guard activeGeneration == generation else { return }
                    showMessage(String(localized: "無法產生工作區佈局"), detail: "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            showMessage(String(localized: "無法讀取腳本設定"), detail: error.localizedDescription)
        }
    }

    private func readSource(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: WorkspaceLayoutScriptRunner.maximumSourceBytes + 1) ?? Data()
        guard data.count <= WorkspaceLayoutScriptRunner.maximumSourceBytes else {
            throw WorkspaceLayoutScriptControllerError.sourceTooLarge
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw WorkspaceLayoutScriptControllerError.invalidSourceEncoding
        }
        return source
    }

    private func differenceView(before: WorkspaceLayout, after: WorkspaceLayout) -> NSView {
        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 12
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.addArrangedSubview(summaryPane(title: String(localized: "目前工作區"), text: describe(before)))
        columns.addArrangedSubview(summaryPane(title: String(localized: "候選佈局"), text: describe(after)))
        columns.widthAnchor.constraint(equalToConstant: 780).isActive = true
        columns.heightAnchor.constraint(equalToConstant: 300).isActive = true
        return columns
    }

    private func summaryPane(title: String, text: String) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        let pane = NSStackView(views: [heading, scroll])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 6
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 270).isActive = true
        return pane
    }

    private func describe(_ layout: WorkspaceLayout) -> String {
        var lines: [String] = []
        func append(_ node: WorkspaceNode, depth: Int) {
            let indent = String(repeating: "  ", count: min(depth, 32))
            switch node {
            case .empty: lines.append(indent + String(localized: "空白區域"))
            case .component(_, let id, let version, _, let size):
                lines.append(indent + "\(id.rawValue) v\(version) · \(Int(size.width))×\(Int(size.height))")
            case .grid(_, let children):
                lines.append(indent + String(localized: "Grid (\(children.count))"))
                children.forEach { append($0, depth: depth + 1) }
            case .horizontalStack(_, let children):
                lines.append(indent + String(localized: "Horizontal stack"))
                children.forEach { append($0, depth: depth + 1) }
            case .verticalStack(_, let children):
                lines.append(indent + String(localized: "Vertical stack"))
                children.forEach { append($0, depth: depth + 1) }
            case .group(_, let children):
                lines.append(indent + String(localized: "Group"))
                children.forEach { append($0, depth: depth + 1) }
            case .split(_, let first, let second, let ratio):
                lines.append(indent + String(localized: "Split · \(Int((ratio * 100).rounded()))% / \(Int(((1 - ratio) * 100).rounded()))%"))
                append(first, depth: depth + 1)
                append(second, depth: depth + 1)
            case .tabs(_, let selected, let pages):
                lines.append(indent + String(localized: "Tabs"))
                for page in pages {
                    lines.append(indent + "  \(page.id == selected ? "●" : "○") \(page.displayTitle)")
                    append(page.root, depth: depth + 2)
                }
            }
        }
        func appendPages(_ pages: [WorkspacePage], label: String) {
            lines.append(label)
            for page in pages {
                lines.append("\(page.displayTitle) [\(page.id.uuidString.prefix(8))]")
                append(page.root, depth: 1)
            }
        }
        appendPages(layout.pages, label: String(localized: "主要版面"))
        for (breakpoint, pages) in layout.breakpointLayouts.sorted(by: { $0.key.minimumWidth < $1.key.minimumWidth }) {
            appendPages(pages, label: String(localized: "斷點 ≥ \(Int(breakpoint.minimumWidth)) px"))
        }
        return lines.joined(separator: "\n")
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
