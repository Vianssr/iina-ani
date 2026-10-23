import AppKit

/// A compact summary only. The detail controller remains the owner of the complete information.
@MainActor
final class WorkspaceDetailInfoPreview: NSView {
    let openButton: NSButton
    private let skinAppearance: SkinAppearance
    private let heading = NSTextField(labelWithString: String(localized: "作品資訊"))
    private let summary = WorkspaceDetailInfoSummary()
    private let header = NSStackView()
    private var headerHeight: CGFloat = 24
    private let contentSpacing: CGFloat = 10

    /// Reading this property returns only the retained, Unicode-safe preview (at most 180 Characters).
    var text: String {
        get { summary.previewText }
        set { summary.setText(newValue) }
    }

    init(appearance: SkinAppearance, target: AnyObject?, action: Selector?) {
        skinAppearance = appearance
        openButton = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage(),
                              target: target, action: action)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        openButton.bezelStyle = .inline
        openButton.isBordered = false
        openButton.imagePosition = .imageOnly
        openButton.image?.isTemplate = true
        openButton.setAccessibilityLabel(String(localized: "開啟完整資訊"))
        openButton.toolTip = String(localized: "開啟完整資訊")
        openButton.translatesAutoresizingMaskIntoConstraints = false
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.addArrangedSubview(heading)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(openButton)
        for child in [header, summary] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            openButton.widthAnchor.constraint(equalToConstant: 24),
            openButton.heightAnchor.constraint(equalToConstant: 24),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.topAnchor.constraint(equalTo: header.bottomAnchor, constant: contentSpacing),
            summary.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        summary.heightDidChange = { [weak self] in self?.invalidateIntrinsicContentSize() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshStyle), name: SkinAppearance.didChangeNotification,
            object: appearance)
        refreshStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: headerHeight + contentSpacing + summary.intrinsicContentSize.height)
    }

    @objc private func refreshStyle() {
        let titleStyle = skinAppearance.resolve(slot: "list", componentID: "detail.media")
        let textStyle = skinAppearance.resolve(slot: "subtitle", componentID: "detail.media")
        appearance = NSAppearance(named: skinAppearance.effectiveColorScheme == .dark ? .darkAqua : .aqua)
        heading.font = titleStyle.values["fontSize"] == nil && titleStyle.values["fontFamily"] == nil
            ? .systemFont(ofSize: 14, weight: .semibold) : titleStyle.font
        heading.textColor = titleStyle.foreground
        openButton.contentTintColor = titleStyle.foreground
        headerHeight = max(24, heading.intrinsicContentSize.height)
        summary.setStyle(font: textStyle.font, color: textStyle.foreground,
                         maximumHeight: max(0, 228 - headerHeight - contentSpacing))
        invalidateIntrinsicContentSize()
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }
}

/// TextKit measures complete lines; the last visible line is composited with an alpha-only fade.
@MainActor
private final class WorkspaceDetailInfoSummary: NSView {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()
    private var font = NSFont.systemFont(ofSize: 12.5)
    private var color = NSColor.secondaryLabelColor
    private var maximumHeight: CGFloat = 194
    private var exceedsCharacterLimit = false
    private var visibleGlyphs = NSRange(location: 0, length: 0)
    private var fadeRect: NSRect?
    private var measuredHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0
    private(set) var previewText = ""
    var heightDidChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setText(_ value: String) {
        let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        exceedsCharacterLimit = !normalized.dropFirst(180).isEmpty
        previewText = String(normalized.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        rebuildText()
    }

    func setStyle(font: NSFont, color: NSColor, maximumHeight: CGFloat) {
        self.font = font
        self.color = color
        self.maximumHeight = maximumHeight
        rebuildText()
    }

    private func rebuildText() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4
        storage.setAttributedString(NSAttributedString(string: previewText, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]))
        measure(width: bounds.width > 0 ? bounds.width : 280)
    }

    override func layout() {
        super.layout()
        if bounds.width > 0, abs(bounds.width - measuredWidth) > 0.5 { measure(width: bounds.width) }
    }

    private func measure(width: CGFloat) {
        measuredWidth = width
        container.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let allGlyphs = manager.glyphRange(for: container)
        var lineCount = 0
        var end = 0
        var bottom: CGFloat = 0
        var lastInk = NSRect.zero
        manager.enumerateLineFragments(forGlyphRange: allGlyphs) { _, used, _, range, stop in
            guard lineCount < 7, used.maxY <= self.maximumHeight else { stop.pointee = true; return }
            lineCount += 1
            end = NSMaxRange(range)
            bottom = max(bottom, used.maxY)
            if used.width > 0 { lastInk = used }
        }
        visibleGlyphs = NSRange(location: 0, length: end)
        let clipped = exceedsCharacterLimit || end < NSMaxRange(allGlyphs)
        if clipped, !lastInk.isEmpty {
            let fadeWidth = min(lastInk.width, max(24, min(64, lastInk.width * 0.4)))
            fadeRect = NSRect(x: lastInk.maxX - fadeWidth, y: lastInk.minY,
                              width: fadeWidth, height: lastInk.height)
        } else { fadeRect = nil }
        let range = manager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let visibleText = (previewText as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        setAccessibilityLabel(visibleText)
        setAccessibilityValue(visibleText)
        let nextHeight = ceil(bottom)
        if measuredHeight != nextHeight {
            measuredHeight = nextHeight
            invalidateIntrinsicContentSize()
            heightDidChange?()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard visibleGlyphs.length > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        manager.drawGlyphs(forGlyphRange: visibleGlyphs, at: .zero)
        if let fadeRect, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                                   colors: [NSColor.black.cgColor, NSColor.clear.cgColor] as CFArray,
                                                   locations: [0, 1]) {
            context.saveGState()
            context.clip(to: fadeRect)
            context.setBlendMode(.destinationIn)
            context.drawLinearGradient(gradient,
                                       start: NSPoint(x: fadeRect.minX, y: fadeRect.midY),
                                       end: NSPoint(x: fadeRect.maxX, y: fadeRect.midY), options: [])
            context.restoreGState()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
