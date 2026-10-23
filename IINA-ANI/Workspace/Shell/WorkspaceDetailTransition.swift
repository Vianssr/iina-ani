import AppKit
import QuartzCore
import CoreImage

/// Captured before navigation removes the source card. Screen coordinates also work for popovers.
@MainActor
struct WorkspaceCoverTransitionSource {
    let image: NSImage
    let screenFrame: NSRect
    let visibleScreenFrame: NSRect
    let aspectFill: Bool
    let cornerRadius: CGFloat
    weak var imageView: NSImageView?

    static func capture(from root: NSView?) -> Self? {
        guard let root, !root.isHiddenOrHasHiddenAncestor else { return nil }
        if let thumbnail = root as? WorkspaceMediaThumbnail {
            return capture(imageView: thumbnail.transitionImageView,
                           aspectFill: thumbnail.transitionAspectFill, radius: 9)
        }
        if let card = root as? WorkspaceDetailShelfButton {
            // A missing cover must not fall through to the card's decorative placeholder symbol.
            return capture(imageView: card.transitionImageView,
                           aspectFill: true, radius: card.transitionCornerRadius)
        }
        if let imageView = root as? NSImageView {
            return capture(imageView: imageView, aspectFill: false, radius: imageView.layer?.cornerRadius ?? 0)
        }
        return root.subviews.lazy.compactMap { capture(from: $0) }.first
    }

    private static func capture(imageView: NSImageView, aspectFill: Bool, radius: CGFloat) -> Self? {
        guard let window = imageView.window, let image = imageView.image,
              image.size.width > 0, image.size.height > 0,
              imageView.bounds.width > 0, imageView.bounds.height > 0,
              !imageView.visibleRect.isEmpty else { return nil }
        return Self(image: image,
                    screenFrame: window.convertToScreen(imageView.convert(imageView.bounds, to: nil)),
                    visibleScreenFrame: window.convertToScreen(imageView.convert(imageView.visibleRect, to: nil)),
                    aspectFill: aspectFill, cornerRadius: radius, imageView: imageView)
    }
}

extension WorkspaceDetailTransitionCurve {
    var timingFunction: CAMediaTimingFunction {
        switch self {
        case .smooth: return CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
        case .easeOut: return CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        case .dramatic: return CAMediaTimingFunction(controlPoints: 0.76, 0, 0.24, 1)
        }
    }
}

/// A short-lived presentation layer. The actual destination stays attached and loads normally.
/// The completion and cancellation paths both restore the cover and release all snapshots once.
@MainActor
final class WorkspaceDetailTransitionOverlay: NSView {
    private let backdrop = CALayer()
    private var completion: (() -> Void)?
    private weak var destinationCover: NSImageView?
    private var previousCoverAlpha: CGFloat = 1
    private weak var previousResponder: NSResponder?
    private var running = false

    override var acceptsFirstResponder: Bool { true }

    static func snapshot(of view: NSView, excluding source: WorkspaceCoverTransitionSource?) -> NSImage? {
        view.layoutSubtreeIfNeeded()
        let oldAlpha = source?.imageView?.alphaValue
        source?.imageView?.alphaValue = 0
        defer { if let oldAlpha { source?.imageView?.alphaValue = oldAlpha } }
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let result = NSImage(size: view.bounds.size)
        result.addRepresentation(bitmap)
        return result
    }

    init(frame: NSRect, snapshot: NSImage) {
        super.init(frame: frame)
        // Layer hosting keeps all animation geometry independent of Auto Layout.
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        backdrop.contents = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        backdrop.contentsGravity = .resize
        layer?.addSublayer(backdrop)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("detail.transition.overlay")
    }
    required init?(coder: NSCoder) { nil }

    func play(source: WorkspaceCoverTransitionSource?, destination: NSImageView?,
              settings: WorkspaceDetailTransitionSettings, completion: @escaping () -> Void) {
        if running { finish() }
        self.completion = completion
        guard settings.style != .none,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window, let root = layer else { finish(); return }
        running = true
        let destination = destination.flatMap {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty ? $0 : nil
        }
        previousResponder = window.firstResponder
        window.makeFirstResponder(self)
        let duration = settings.duration
        let timing = settings.curve.timingFunction

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        // The old page holds briefly, then meets the prepared detail page at the same endpoint.
        animate(backdrop, "opacity", values: [1, 1, 0], times: [0, 0.55, 1], duration: duration, timing: timing)
        backdrop.opacity = 0

        if let source, let cgImage = source.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let start = convert(window.convertFromScreen(source.screenFrame), from: nil)
            let visibleStart = convert(window.convertFromScreen(source.visibleScreenFrame), from: nil)
            let target = destination.map { convert($0.bounds, from: $0) }
                .flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? start
            let container = CALayer()
            container.masksToBounds = true
            container.cornerRadius = 14
            root.addSublayer(container)
            let picture = CALayer()
            picture.contents = cgImage
            picture.contentsGravity = .resize
            container.addSublayer(picture)
            if let destination {
                destinationCover = destination
                previousCoverAlpha = destination.alphaValue
                destination.alphaValue = 0
            }

            let end: NSRect
            if settings.style == .cinema {
                end = bounds.insetBy(dx: -bounds.width * (settings.zoom - 1) / 2,
                                     dy: -bounds.height * (settings.zoom - 1) / 2)
            } else { end = target }
            container.frame = end
            let startImage = Self.imageRect(source.image.size, in: NSRect(origin: .zero, size: start.size), fill: source.aspectFill)
            let endImage = Self.imageRect(source.image.size, in: NSRect(origin: .zero, size: end.size), fill: settings.style == .cinema)
            picture.frame = endImage
            animateFrame(container, from: start, to: end, duration: duration, timing: timing)
            animateFrame(picture, from: startImage, to: endImage, duration: duration, timing: timing)
            animate(container, "cornerRadius", values: [source.cornerRadius, settings.style == .cinema ? 0 : 14], duration: duration, timing: timing)
            container.cornerRadius = settings.style == .cinema ? 0 : 14

            // Keep a partially scrolled card clipped at its actual visible edge at the start.
            let clip = CALayer()
            clip.backgroundColor = NSColor.black.cgColor
            let initialClip = visibleStart.offsetBy(dx: -start.minX, dy: -start.minY)
            clip.frame = container.bounds
            container.mask = clip
            animateFrame(clip, from: initialClip, to: container.bounds, duration: duration, timing: timing)

            switch settings.style {
            case .cinema:
                layerUsesCoreImageFilters = true
                if let filter = CIFilter(name: "CIGammaAdjust") {
                    filter.name = "detailGamma"
                    filter.setValue(settings.gamma, forKey: "inputPower")
                    picture.filters = [filter]
                    animate(picture, "filters.detailGamma.inputPower", values: [1, settings.gamma], duration: duration, timing: timing)
                }
                let shade = CALayer()
                shade.frame = container.bounds
                shade.backgroundColor = NSColor.black.cgColor
                shade.opacity = 0.42
                container.addSublayer(shade)
                animate(shade, "opacity", values: [0, 0.42], duration: duration, timing: timing)
                animate(container, "opacity", values: [1, 1, 0], times: [0, 0.65, 1], duration: duration, timing: timing)
                container.opacity = 0
            case .iris:
                let center = CGPoint(x: start.midX, y: start.midY)
                let radius = max(hypot(center.x, center.y), hypot(bounds.maxX - center.x, center.y),
                                 hypot(center.x, bounds.maxY - center.y), hypot(bounds.maxX - center.x, bounds.maxY - center.y)) + 2
                let mask = CAShapeLayer()
                mask.fillRule = .evenOdd
                func aperture(_ radius: CGFloat) -> CGPath {
                    let path = CGMutablePath()
                    path.addRect(bounds.insetBy(dx: -1, dy: -1))
                    path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    return path
                }
                mask.path = aperture(radius)
                backdrop.mask = mask
                animate(mask, "path", values: [aperture(0.1), aperture(radius)], duration: duration, timing: timing)
                animate(container, "transform.rotation.z", values: [0, -0.10, 0.025, 0], times: [0, 0.25, 0.6, 1], duration: duration, timing: timing)
            case .cover, .none: break
            }
        }
        CATransaction.commit()
    }

    /// AppKit's proportional image layout, also used to morph aspect-fill cards into aspect-fit covers.
    static func imageRect(_ image: CGSize, in bounds: CGRect, fill: Bool) -> CGRect {
        guard image.width > 0, image.height > 0 else { return bounds }
        let x = bounds.width / image.width, y = bounds.height / image.height
        let scale = fill ? max(x, y) : min(x, y)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func animateFrame(_ layer: CALayer, from: CGRect, to: CGRect, duration: Double, timing: CAMediaTimingFunction) {
        animate(layer, "position", values: [CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY)], duration: duration, timing: timing)
        animate(layer, "bounds", values: [CGRect(origin: .zero, size: from.size), CGRect(origin: .zero, size: to.size)], duration: duration, timing: timing)
    }

    private func animate(_ layer: CALayer, _ key: String, values: [Any], times: [NSNumber]? = nil,
                         duration: Double, timing: CAMediaTimingFunction) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = times ?? [0, 1]
        animation.timingFunctions = Array(repeating: timing, count: values.count - 1)
        animation.duration = duration
        layer.add(animation, forKey: "detail.\(key)")
    }

    func finish() {
        guard let completion else { return }
        self.completion = nil
        running = false
        destinationCover?.alphaValue = previousCoverAlpha
        destinationCover = nil
        if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
        removeFromSuperview()
        layer?.sublayers?.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        completion()
    }

    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { finish() } }
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
