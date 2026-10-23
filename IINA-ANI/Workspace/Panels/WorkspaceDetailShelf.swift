import AppKit
import SDWebImage

/// A horizontal shelf that participates in the detail page's existing vertical scroll ownership.
@MainActor
final class WorkspaceDetailShelf: NSView {
    private let scroll = WorkspaceScrollView()
    private let document = WorkspaceDetailShelfDocument()
    private let items = NSStackView()

    init(height: CGFloat, spacing: CGFloat = 20) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .automatic
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        items.translatesAutoresizingMaskIntoConstraints = false
        items.orientation = .horizontal
        items.alignment = .top
        items.spacing = spacing
        scroll.documentView = document
        document.addSubview(items)
        addSubview(scroll)
        let fittedWidth = document.widthAnchor.constraint(equalTo: items.widthAnchor, constant: 8)
        fittedWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: items.widthAnchor, constant: 8),
            fittedWidth,
            items.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            items.topAnchor.constraint(equalTo: document.topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setItems(_ views: [NSView]) {
        let origin = scroll.contentView.bounds.origin
        for view in items.arrangedSubviews {
            items.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            items.addArrangedSubview(view)
        }
        layoutSubtreeIfNeeded()
        restoreScrollPosition(origin)
    }

    func resetScrollPosition() {
        restoreScrollPosition(.zero)
    }

    private func restoreScrollPosition(_ origin: NSPoint) {
        let clip = scroll.contentView
        let bounds = NSRect(origin: NSPoint(x: origin.x, y: 0), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
private final class WorkspaceDetailShelfDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class WorkspaceDetailPortraitButton: WorkspaceDetailShelfButton {
    init(title: String, subtitle: String, imageURL: URL?, appearance: SkinAppearance,
         target: AnyObject?, action: Selector?) {
        super.init(title: title, subtitle: subtitle, imageURL: imageURL, appearance: appearance,
                   target: target, action: action, portrait: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class WorkspaceDetailPosterButton: WorkspaceDetailShelfButton {
    init(title: String, subtitle: String, imageURL: URL?, appearance: SkinAppearance,
         target: AnyObject?, action: Selector?) {
        super.init(title: title, subtitle: subtitle, imageURL: imageURL, appearance: appearance,
                   target: target, action: action, portrait: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Native button tracking and keyboard activation are retained around non-interactive artwork/text.
@MainActor
class WorkspaceDetailShelfButton: NSButton {
    private let skinAppearance: SkinAppearance
    private let artworkContainer = WorkspaceDetailShelfArtworkContainer()
    private let artwork = WorkspaceDetailShelfArtwork()
    private let placeholder = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let portrait: Bool
    private var imageURL: URL?
    private var request: SDWebImageCombinedOperation?
    private var imageGeneration = UUID()
    private var completedImageGeneration: UUID?
    private var needsImage = false
    private var hovered = false
    private var pressed = false
    private var keyboardFocused = false
    private var tracking: NSTrackingArea?

    var transitionImageView: NSImageView { artwork }
    var transitionCornerRadius: CGFloat { portrait ? 56 : 10 }
    override var acceptsFirstResponder: Bool { isEnabled && action != nil }
    override var isEnabled: Bool { didSet { refreshStyle() } }
    override var action: Selector? {
        didSet {
            if action == nil { hovered = false; pressed = false; keyboardFocused = false }
            setAccessibilityRole(action == nil ? .group : .button)
            refreshStyle()
        }
    }

    fileprivate init(title: String, subtitle: String, imageURL: URL?, appearance: SkinAppearance,
                     target: AnyObject?, action: Selector?, portrait: Bool) {
        self.portrait = portrait
        skinAppearance = appearance
        super.init(frame: .zero)
        cell = WorkspaceDetailShelfButtonCell(textCell: title)
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        let cardWidth: CGFloat = portrait ? 132 : 144
        let cardHeight: CGFloat = portrait ? 190 : 248
        let artworkWidth: CGFloat = portrait ? 112 : 144
        let artworkHeight: CGFloat = portrait ? 112 : 202
        artwork.alignsImageToTop = portrait
        artworkContainer.maskRadius = transitionCornerRadius
        artworkContainer.bindSkin(appearance, slot: "row", componentID: "detail.media")
        placeholder.image = NSImage(systemSymbolName: portrait ? "person.crop.circle.fill" : "photo", accessibilityDescription: nil)
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, subtitleLabel] {
            label.alignment = portrait ? .center : .left
            label.maximumNumberOfLines = portrait ? 2 : 1
            label.lineBreakMode = portrait ? .byWordWrapping : .byTruncatingTail
            label.preferredMaxLayoutWidth = cardWidth - (portrait ? 4 : 0)
            label.isSelectable = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [artworkContainer, titleLabel, subtitleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.setAccessibilityElement(false)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.setAccessibilityElement(false)
        artworkContainer.addSubview(artwork)
        artworkContainer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: cardWidth),
            heightAnchor.constraint(equalToConstant: cardHeight),
            artworkContainer.widthAnchor.constraint(equalToConstant: artworkWidth),
            artworkContainer.heightAnchor.constraint(equalToConstant: artworkHeight),
            artworkContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            artworkContainer.topAnchor.constraint(equalTo: topAnchor),
            artwork.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artwork.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artwork.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: artwork.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: portrait ? 44 : 36),
            placeholder.heightAnchor.constraint(equalTo: placeholder.widthAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: portrait ? 2 : 0),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: portrait ? -2 : 0),
            titleLabel.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: portrait ? 10 : 8),
            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: portrait ? 34 : 18),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: portrait ? 2 : 3),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: portrait ? -1 : -2),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshStyle), name: SkinAppearance.didChangeNotification,
            object: appearance)
        refreshStyle()
        setAccessibilityElement(true)
        setAccessibilityRole(action == nil ? .group : .button)
        setAccessibilityChildren([])
        configure(title: title, subtitle: subtitle, imageURL: imageURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Clears the previous image immediately and rejects callbacks from any earlier request.
    func configure(title: String, subtitle: String, imageURL: URL?) {
        cancelImageRequest()
        self.title = title
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        let description = subtitle.isEmpty ? title : title + " · " + subtitle
        toolTip = description
        setAccessibilityLabel(description)
        self.imageURL = imageURL.flatMap { ["https", "http", "file"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        artwork.image = nil
        placeholder.isHidden = false
        needsImage = self.imageURL != nil
        if window != nil { loadImageIfNeeded() }
    }

    private func loadImageIfNeeded() {
        guard needsImage, request == nil, let imageURL else { return }
        needsImage = false
        let token = imageGeneration
        let operation = SDWebImageManager.shared.loadImage(with: imageURL, progress: nil) { [weak self] image, _, _, _, finished, _ in
            MainActor.assumeIsolated {
                guard let self, finished, self.imageGeneration == token else { return }
                self.artwork.image = image
                self.placeholder.isHidden = image != nil
                self.completedImageGeneration = token
                self.request = nil
            }
        }
        // Memory-cache hits may complete synchronously before loadImage returns its operation.
        if completedImageGeneration != token { request = operation }
    }

    private func cancelImageRequest() {
        imageGeneration = UUID()
        completedImageGeneration = nil
        request?.cancel()
        request = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hovered = false
            keyboardFocused = false
            if request != nil { needsImage = true }
            cancelImageRequest()
        } else {
            loadImageIfNeeded()
        }
        refreshStyle()
    }

    @objc private func refreshStyle() {
        let state: SkinControlState = !isEnabled ? .disabled : action == nil ? .normal : pressed ? .pressed
            : keyboardFocused ? .focus : hovered ? .hover : .normal
        let style = skinAppearance.resolve(slot: "row", componentID: "detail.media", state: state)
        appearance = NSAppearance(named: skinAppearance.effectiveColorScheme == .dark ? .darkAqua : .aqua)
        artworkContainer.workspaceSkinBinding?.state = state
        artworkContainer.layer?.cornerRadius = transitionCornerRadius
        let focused = state == .focus
        let emphasized = focused || state == .hover || state == .pressed
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = focused ? 2 : 0
        layer?.borderColor = style.foreground.withAlphaComponent(0.7).cgColor
        artworkContainer.layer?.borderWidth = emphasized ? max(2, style.borderWidth) : style.borderWidth
        artworkContainer.layer?.borderColor = (emphasized
            ? style.foreground.withAlphaComponent(focused ? 0.7 : 0.22) : style.borderColor).cgColor
        placeholder.contentTintColor = style.foreground.withAlphaComponent(0.4)
        artwork.alphaValue = state == .disabled ? 0.5 : state == .pressed ? 0.78 : 1
        // Detail's authored text colors/fonts apply without painting list backgrounds behind labels.
        let titleStyle = skinAppearance.resolve(slot: "list", componentID: "detail.media", state: state)
        let subtitleStyle = skinAppearance.resolve(slot: "subtitle", componentID: "detail.media", state: state)
        titleLabel.font = titleStyle.values["fontSize"] == nil && titleStyle.values["fontFamily"] == nil
            ? .systemFont(ofSize: 13, weight: .semibold) : titleStyle.font
        titleLabel.textColor = titleStyle.foreground
        subtitleLabel.font = subtitleStyle.font
        subtitleLabel.textColor = subtitleStyle.foreground
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero,
                                 options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) { hovered = action != nil; refreshStyle() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshStyle() }
    override func highlight(_ flag: Bool) {
        pressed = flag && action != nil
        super.highlight(pressed)
        refreshStyle()
    }
    override func mouseDown(with event: NSEvent) {
        guard action != nil else { return }
        pressed = true
        refreshStyle()
        super.mouseDown(with: event)
        pressed = false
        refreshStyle()
    }
    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder else { return false }
        let result = super.becomeFirstResponder()
        keyboardFocused = result
        if result { scrollToVisible(bounds) }
        refreshStyle()
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { keyboardFocused = false }
        refreshStyle()
        return result
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func keyDown(with event: NSEvent) {
        if isEnabled, action != nil, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    isolated deinit {
        request?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}

private final class WorkspaceDetailShelfButtonCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) { }
}

@MainActor
private final class WorkspaceDetailShelfArtworkContainer: NSView {
    var maskRadius: CGFloat = 10

    override func layout() {
        super.layout()
        workspaceSkinBinding?.refresh()
        layer?.cornerRadius = maskRadius
        layer?.masksToBounds = true
    }
}

@MainActor
private final class WorkspaceDetailShelfArtwork: NSImageView {
    var alignsImageToTop = false

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        guard scale > 0 else { return }
        let sourceSize = NSSize(width: bounds.width / scale, height: bounds.height / scale)
        // NSImage source coordinates start at the lower left, so the top crop uses the maximum Y.
        let sourceY = image.size.height - sourceSize.height
        let source = NSRect(x: (image.size.width - sourceSize.width) / 2,
                            y: alignsImageToTop ? sourceY : sourceY / 2,
                            width: sourceSize.width, height: sourceSize.height)
        image.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}
