import AppKit
import ObjectiveC
import SDWebImage

enum WorkspaceIcon: String {
    case discover, search, calendar, favorites, history, downloads, settings
    case openLink = "open-link"
    case play, pause, stop
    case nextEpisode = "next"
    case playlist, danmaku, subtitles, live, work, episodes, bookmark, sync, source
    case subscription, account, quality, torrent, magnet, folder
    case importFile = "import"
    case exportFile = "export"
    case appearance, layout, delete, add, close, check, back, refresh, filter, sort, info

    @MainActor
    func image(size: CGFloat = 16) -> NSImage? {
        guard let image = NSImage(named: NSImage.Name("ani-\(rawValue)"))?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

@MainActor
extension NSButton {
    /// The skin can override a command icon; removing that override restores this image.
    func setFunctionIcon(_ icon: WorkspaceIcon?, size: CGFloat = 16) {
        let image = icon?.image(size: size)
        if let button = self as? WorkspaceSkinButton {
            guard !button.usesNativeStateIndicator else { return }
            button.functionIconImage = image
            if let binding = button.workspaceSkinBinding {
                binding.refresh()
                return
            }
        }
        self.image = image
        imagePosition = image == nil ? .noImage : (self as? WorkspaceSkinButton)?.functionIconPosition ?? .imageLeading
    }
}

/// A binding only changes presentation. Targets, hit regions, accessibility and service owners stay native.
@MainActor
final class WorkspaceSkinBinding: NSObject {
    private weak var view: NSView?
    let appearance: SkinAppearance
    let slot: String
    let componentID: String?
    var state: SkinControlState = .normal { didSet { if oldValue != state { refresh() } } }
    private let backgroundLayer = CALayer()
    private let decorationLayer = CALayer()
    private var refreshing = false

    init(view: NSView, appearance: SkinAppearance, slot: String, componentID: String?) {
        self.view = view
        self.appearance = appearance
        self.slot = slot
        self.componentID = componentID
        super.init()
        view.wantsLayer = true
        backgroundLayer.contentsGravity = .resizeAspectFill
        decorationLayer.contentsGravity = .resizeAspect
        view.layer?.insertSublayer(backgroundLayer, at: 0)
        view.layer?.insertSublayer(decorationLayer, at: 1)
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: SkinAppearance.didChangeNotification,
            object: appearance)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: NSView.frameDidChangeNotification,
            object: view)
        refresh()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func refresh() {
        guard let view, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let nativeAppearance: NSAppearance.Name = appearance.effectiveColorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != nativeAppearance { view.appearance = NSAppearance(named: nativeAppearance) }
        let style = appearance.resolve(slot: slot, componentID: componentID, state: state)
        if case .number(let opacity) = style.values["opacity"] {
            view.alphaValue = opacity
        } else {
            view.alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.backgroundColor = style.background.cgColor
        view.layer?.cornerRadius = style.radius
        view.layer?.borderWidth = style.borderWidth
        view.layer?.borderColor = style.borderColor.cgColor
        for (role, layer) in [
            (SkinAssetRole.background, backgroundLayer), (.decoration, decorationLayer),
        ] {
            layer.frame = view.bounds
            layer.contents = style.assetIDs[role].flatMap {
                appearance.image(
                    assetID: $0, scale: view.window?.backingScaleFactor ?? 2,
                    targetSize: view.bounds.size)
            }?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        CATransaction.commit()
        if let control = view as? NSControl { control.font = style.font }
        if let label = view as? NSTextField {
            label.textColor = style.foreground
            if label.isEditable { label.backgroundColor = style.background }
        }
        if let button = view as? NSButton {
            button.contentTintColor = style.foreground
            button.isBordered = style.assetIDs[.background] == nil
                && ((button as? WorkspaceSkinButton)?.usesNativeBezel ?? true)
            let preservesImage = (button as? WorkspaceSkinButton).map { $0.usesNativeStateIndicator || $0.preservesNativeImage } ?? false
            if !preservesImage {
                let iconSize = max(20, (button as? WorkspaceSkinButton)?.functionIconImage?.size.width ?? 20)
                button.image = style.assetIDs[.icon].flatMap {
                    appearance.image(
                        assetID: $0, scale: view.window?.backingScaleFactor ?? 2,
                        targetSize: NSSize(width: iconSize, height: iconSize))
                } ?? (button as? WorkspaceSkinButton)?.functionIconImage
                button.imagePosition = button.image == nil ? .noImage : (button as? WorkspaceSkinButton)?.functionIconPosition ?? .imageLeading
            }
            (button as? WorkspaceSkinButton)?.applySkinStyle(style, state: state)
        }
        if let table = view as? NSTableView {
            table.backgroundColor = style.background
            let density: CGFloat =
                style.density == .compact ? 1 : style.density == .comfortable ? 1.4 : 1.15
            table.rowHeight = max(34, style.font.pointSize * 2.4 * density)
        }
        if let stack = view as? NSStackView { stack.spacing = style.spacing }
        if let grid = view as? NSGridView {
            grid.rowSpacing = style.spacing
            grid.columnSpacing = style.spacing
        }
        if let image = view as? NSImageView {
            image.image = style.assetIDs[.placeholder].flatMap {
                appearance.image(
                    assetID: $0, scale: view.window?.backingScaleFactor ?? 2,
                    targetSize: NSSize(
                        width: max(32, view.bounds.width), height: max(32, view.bounds.height))
                )
            }
            image.isHidden = style.assetIDs[.placeholder] == nil
        }
        view.needsDisplay = true
    }
}

@MainActor
private var workspaceSkinBindingKey: UInt8 = 0

@MainActor
extension NSView {
    var workspaceSkinBinding: WorkspaceSkinBinding? {
        objc_getAssociatedObject(self, &workspaceSkinBindingKey) as? WorkspaceSkinBinding
    }

    func bindSkin(_ appearance: SkinAppearance, slot: String, componentID: String? = nil) {
        if let existing = workspaceSkinBinding, existing.appearance === appearance,
            existing.slot == slot, existing.componentID == componentID
        {
            existing.refresh()
            return
        }
        let binding = WorkspaceSkinBinding(
            view: self, appearance: appearance, slot: slot, componentID: componentID)
        objc_setAssociatedObject(
            self, &workspaceSkinBindingKey, binding, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

/// Shared full-row navigation presentation for workspace pages and settings categories.
@MainActor
class WorkspaceNavigationButton: WorkspaceSkinButton {
    override var usesNativeBezel: Bool { false }

    override func applySkinStyle(_ style: SkinResolvedStyle, state: SkinControlState) {
        guard let binding = workspaceSkinBinding else { return }
        let normal = binding.appearance.resolve(slot: binding.slot, componentID: binding.componentID, state: .normal)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if style.values["radius"] == nil { layer?.cornerRadius = 10 }
        // Explicit state backgrounds and Skin artwork keep their author-defined appearance.
        if style.assetIDs[.background] == nil, style.values["background"] == normal.values["background"] {
            let emphasis: CGFloat = !isEnabled ? 0 : state == .pressed ? 0.16
                : self.state == .on ? 0.11 : (state == .hover || state == .focus) ? 0.055 : 0
            layer?.backgroundColor = style.background.blended(withFraction: emphasis, of: style.foreground)?.cgColor
        }
        CATransaction.commit()
    }
}

/// Standard NSButton tracking, action dispatch, keyboard activation and focus drawing are retained.
@MainActor
class WorkspaceSkinButton: NSButton {
    fileprivate var functionIconImage: NSImage?
    var functionIconPosition: NSControl.ImagePosition = .imageLeading
    private var hovered = false
    private var pressed = false
    private var skinTrackingArea: NSTrackingArea?
    private(set) var usesNativeStateIndicator = false
    var preservesNativeImage: Bool { false }
    var usesNativeBezel: Bool { true }
    func applySkinStyle(_ style: SkinResolvedStyle, state: SkinControlState) { }
    override func setButtonType(_ type: NSButton.ButtonType) {
        usesNativeStateIndicator = type == .radio || type == .switch
        super.setButtonType(type)
    }
    override var isEnabled: Bool { didSet { updateSkinState() } }
    override var state: NSControl.StateValue { didSet { updateSkinState() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let skinTrackingArea { removeTrackingArea(skinTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        skinTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateSkinState()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateSkinState()
    }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressed = flag
        updateSkinState()
    }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        updateSkinState()
        super.mouseDown(with: event)
        pressed = false
        updateSkinState()
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        updateSkinState()
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            workspaceSkinBinding?.state =
                !isEnabled ? .disabled : state == .on ? .selected : .normal
        }
        return result
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSkinState()
    }
    override func layout() {
        super.layout()
        workspaceSkinBinding?.refresh()
    }
    func updateSkinState() {
        workspaceSkinBinding?.state =
            !isEnabled
            ? .disabled
            : pressed
                ? .pressed
                : window?.firstResponder === self
                    ? .focus : state == .on ? .selected : hovered ? .hover : .normal
    }
}

@MainActor
final class WorkspaceSkinSearchField: NSSearchField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        workspaceSkinBinding?.state = result ? .focus : .normal
        return result
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        workspaceSkinBinding?.state = .normal
    }
}

@MainActor
final class WorkspaceSkinRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { workspaceSkinBinding?.state = isSelected ? .selected : .normal }
    }
    override func layout() {
        super.layout()
        workspaceSkinBinding?.refresh()
    }
}

/// Tracks system appearance at the view boundary, without changing app-wide appearance or preferences.
@MainActor
final class WorkspaceSkinHostView: NSView {
    var skinAppearance: SkinAppearance?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        skinAppearance?.refreshSystemAppearance()
    }
}

@MainActor
final class WorkspaceSkinStatusLabel: NSTextField {
    private let placeholderImage = NSImageView()
    private weak var statusContainer: NSStackView?
    override var isHidden: Bool {
        didSet { statusContainer?.isHidden = isHidden }
    }

    func presentation(appearance: SkinAppearance, componentID: String) -> NSView {
        placeholderImage.imageScaling = .scaleProportionallyUpOrDown
        placeholderImage.setAccessibilityElement(false)
        placeholderImage.widthAnchor.constraint(equalToConstant: 32).isActive = true
        placeholderImage.heightAnchor.constraint(equalToConstant: 32).isActive = true
        placeholderImage.bindSkin(appearance, slot: "placeholder", componentID: componentID)
        let row = NSStackView(views: [placeholderImage, self])
        row.orientation = .horizontal
        row.spacing = 8
        row.isHidden = isHidden
        statusContainer = row
        return row
    }
}

@MainActor
final class WorkspaceSkinProgressIndicator: NSProgressIndicator {
    override func draw(_ dirtyRect: NSRect) {
        guard let binding = workspaceSkinBinding else {
            super.draw(dirtyRect)
            return
        }
        let style = binding.appearance.resolve(
            slot: "progress", componentID: binding.componentID,
            state: isIndeterminate ? .loading : .normal)
        style.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: style.radius, yRadius: style.radius).fill()
        guard !isIndeterminate, maxValue > minValue else { return }
        let fraction = min(1, max(0, (doubleValue - minValue) / (maxValue - minValue)))
        let fill = NSRect(
            x: bounds.minX, y: bounds.minY, width: bounds.width * fraction, height: bounds.height)
        style.foreground.setFill()
        NSBezierPath(roundedRect: fill, xRadius: style.radius, yRadius: style.radius).fill()
    }
}

@MainActor
final class WorkspaceMediaThumbnail: NSView {
    private let imageView = WorkspaceThumbnailImageView()
    private let placeholder = NSTextField(labelWithString: String(localized: "無封面"))
    private var request: SDWebImageCombinedOperation?

    init(url: String?, poster: Bool, appearance: SkinAppearance, componentID: String, previewOnly: Bool, fixedSize: Bool = true) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.aspectFill = !fixedSize
        imageView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center
        placeholder.setAccessibilityLabel(String(localized: "未提供封面"))
        addSubview(imageView); addSubview(placeholder)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor), imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor), imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if fixedSize {
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: poster ? 56 : 96),
                heightAnchor.constraint(equalToConstant: poster ? 84 : 54),
            ])
        }
        bindSkin(appearance, slot: "placeholder", componentID: componentID)
        placeholder.bindSkin(appearance, slot: "placeholder", componentID: componentID)
        guard !previewOnly, let url, let address = URL(string: url), ["https", "http", "file"].contains(address.scheme ?? "") else { return }
        placeholder.stringValue = String(localized: "載入中")
        request = SDWebImageManager.shared.loadImage(with: address, progress: nil) { [weak self] image, _, _, _, finished, _ in
            MainActor.assumeIsolated {
                guard let self, finished else { return }
                self.imageView.image = image
                self.placeholder.isHidden = image != nil
                self.placeholder.stringValue = String(localized: "封面失效")
            }
        }
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { request?.cancel() }
}

@MainActor
private final class WorkspaceThumbnailImageView: NSImageView {
    var aspectFill = false
    override func draw(_ dirtyRect: NSRect) {
        guard aspectFill, let image, image.size.width > 0, image.size.height > 0 else {
            super.draw(dirtyRect); return
        }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        guard scale > 0 else { return }
        let sourceSize = NSSize(width: bounds.width / scale, height: bounds.height / scale)
        let source = NSRect(x: (image.size.width - sourceSize.width) / 2,
                            y: (image.size.height - sourceSize.height) / 2,
                            width: sourceSize.width, height: sourceSize.height)
        image.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

@MainActor
final class WorkspaceDragRegionView: NSView {
    weak var scrollOwner: WorkspaceScrollView?
}

/// Wheel and mouse dragging each retain one axis and one scroll owner.
@MainActor
final class WorkspaceScrollView: NSScrollView, NSGestureRecognizerDelegate {
    weak var verticalScrollTarget: WorkspaceScrollView?
    private enum Axis { case horizontal, vertical }
    private var gestureAxis: Axis?
    private weak var gestureTarget: WorkspaceScrollView?

    private lazy var mousePan = NSPanGestureRecognizer(target: self, action: #selector(dragContent(_:)))
    private var dragAxis: Axis?
    private weak var dragTarget: WorkspaceScrollView?
    private weak var dragSource: WorkspaceScrollView?
    private var dragOrigin = NSPoint.zero
    private var dragPressLocation = NSPoint.zero
    private var dragCursorActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        mousePan.delegate = self
        mousePan.allowedTouchTypes = []
        mousePan.delaysPrimaryMouseButtonEvents = true
        addGestureRecognizer(mousePan)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        mousePan.delegate = self
        mousePan.allowedTouchTypes = []
        mousePan.delaysPrimaryMouseButtonEvents = true
        addGestureRecognizer(mousePan)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard gestureRecognizer === mousePan, event.type == .leftMouseDown,
              let content = window?.contentView else { return false }
        dragSource = self
        var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let view = hit {
            if let scroll = view as? WorkspaceScrollView {
                if scroll === self { dragPressLocation = event.locationInWindow }
                return scroll === self
            }
            if let region = view as? WorkspaceDragRegionView, let owner = region.scrollOwner {
                dragSource = owner
            }
            // Keep editing, text selection, table reordering and native controls native.
            if view is NSTableView || view is NSTextView || view is NSSplitView { return false }
            if let field = view as? NSTextField {
                if field.isEditable || field.isSelectable { return false }
            } else if view is NSControl && !(view is NSImageView) { return false }
            hit = view.superview
        }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard gestureRecognizer === mousePan else { return true }
        let point = window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? dragPressLocation
        let translation = NSPoint(x: point.x - dragPressLocation.x, y: point.y - dragPressLocation.y)
        let axis: Axis = abs(translation.x) > abs(translation.y) ? .horizontal : .vertical
        let owner = (dragSource ?? self).target(for: axis)
        guard owner.canScroll(axis) else { return false }
        dragAxis = axis
        dragTarget = owner
        dragOrigin = owner.contentView.bounds.origin
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        gestureRecognizer === mousePan && otherGestureRecognizer is NSClickGestureRecognizer
    }

    @objc private func dragContent(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            NSCursor.closedHand.push()
            dragCursorActive = true
            moveDraggedContent(recognizer)
        case .changed: moveDraggedContent(recognizer)
        case .ended, .cancelled, .failed:
            if recognizer.state == .ended { moveDraggedContent(recognizer) }
            finishMouseDrag()
        default: break
        }
    }

    private func moveDraggedContent(_ recognizer: NSPanGestureRecognizer) {
        guard let axis = dragAxis, let owner = dragTarget,
              owner.window === window, !owner.isHiddenOrHasHiddenAncestor,
              let document = owner.documentView else { return }
        let point = window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? dragPressLocation
        let translation = NSPoint(x: point.x - dragPressLocation.x, y: point.y - dragPressLocation.y)
        var origin = dragOrigin
        if axis == .horizontal { origin.x -= translation.x }
        else { origin.y += document.isFlipped ? translation.y : -translation.y }
        let clip = owner.contentView
        let proposed = NSRect(origin: origin, size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        owner.reflectScrolledClipView(clip)
    }

    private func finishMouseDrag() {
        dragAxis = nil
        dragTarget = nil
        dragSource = nil
        if dragCursorActive { NSCursor.pop(); dragCursorActive = false }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishMouseDrag() }
    }

    override func scrollWheel(with event: NSEvent) {
        let discrete = event.phase.isEmpty && event.momentumPhase.isEmpty
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) || discrete {
            gestureAxis = nil
            gestureTarget = nil
        }
        if gestureAxis == nil {
            guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
            let axis: Axis = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? .horizontal : .vertical
            gestureAxis = axis
            gestureTarget = target(for: axis)
        }
        if let axis = gestureAxis {
            (gestureTarget ?? self).consume(event, axis: axis)
        }
        if discrete || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
            gestureAxis = nil
            gestureTarget = nil
        }
    }

    private func canScroll(_ axis: Axis) -> Bool {
        guard let documentView else { return false }
        switch axis {
        case .horizontal: return hasHorizontalScroller && documentView.frame.width > contentView.bounds.width + 1
        case .vertical: return hasVerticalScroller && documentView.frame.height > contentView.bounds.height + 1
        }
    }

    private func target(for axis: Axis) -> WorkspaceScrollView {
        if canScroll(axis) { return self }
        if axis == .vertical, let verticalScrollTarget, window != nil,
           verticalScrollTarget.window === window, !verticalScrollTarget.isHiddenOrHasHiddenAncestor,
           verticalScrollTarget.canScroll(axis) {
            return verticalScrollTarget
        }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? WorkspaceScrollView, scroll.canScroll(axis) { return scroll }
            ancestor = view.superview
        }
        return self
    }

    private func consume(_ event: NSEvent, axis: Axis) {
        // Preserve native scrolling physics and phases; remove only off-axis drift.
        let offAxisDelta = axis == .horizontal ? event.scrollingDeltaY : event.scrollingDeltaX
        guard offAxisDelta != 0, let projected = event.cgEvent?.copy() else {
            super.scrollWheel(with: event)
            return
        }
        switch axis {
        case .horizontal:
            projected.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            projected.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            projected.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        case .vertical:
            projected.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
            projected.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
            projected.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        }
        if let filtered = NSEvent(cgEvent: projected) { super.scrollWheel(with: filtered) }
    }
}

