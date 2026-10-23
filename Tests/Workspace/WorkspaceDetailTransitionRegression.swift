import AppKit
import QuartzCore
import CoreImage
@testable import IINA_ANI

@main
@MainActor
struct WorkspaceDetailTransitionRegression {
    final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) < 0.01 }

    static func sameRect(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        close(lhs.minX, rhs.minX) && close(lhs.minY, rhs.minY)
            && close(lhs.width, rhs.width) && close(lhs.height, rhs.height)
    }

    static func image() -> NSImage {
        NSImage(size: NSSize(width: 120, height: 180), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: 90, width: 120, height: 90).fill()
            return true
        }
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        imageGeometry()
        sourceCapture(host: host, window: window)
        completionLifecycle(host: host, window: window)
        print("PASS: detail transition capture/clipping, fill/fit geometry, snapshot restoration, completion/cancellation and overlay cleanup")
    }

    static func imageGeometry() {
        let bounds = NSRect(x: 10, y: 20, width: 100, height: 100)
        let landscape = NSSize(width: 400, height: 200)
        check(sameRect(WorkspaceDetailTransitionOverlay.imageRect(landscape, in: bounds, fill: false),
                       NSRect(x: 10, y: 45, width: 100, height: 50)),
              "aspect fit must preserve the complete centered landscape image")
        check(sameRect(WorkspaceDetailTransitionOverlay.imageRect(landscape, in: bounds, fill: true),
                       NSRect(x: -40, y: 20, width: 200, height: 100)),
              "aspect fill must center its horizontal crop")
        check(sameRect(WorkspaceDetailTransitionOverlay.imageRect(NSSize(width: 200, height: 400), in: bounds, fill: false),
                       NSRect(x: 35, y: 20, width: 50, height: 100)),
              "portrait fit must center its horizontal inset")
        check(sameRect(WorkspaceDetailTransitionOverlay.imageRect(.zero, in: bounds, fill: true), bounds),
              "invalid image dimensions must not produce nonfinite geometry")
    }

    static func sourceCapture(host: NSView, window: NSWindow) {
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 140, height: 160))
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 800))
        let imageView = NSImageView(frame: NSRect(x: 0, y: 100, width: 200, height: 300))
        imageView.image = image()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 7
        document.addSubview(imageView)
        scroll.documentView = document
        host.addSubview(scroll)
        host.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        guard let source = WorkspaceCoverTransitionSource.capture(from: document) else {
            preconditionFailure("a visible image inside a scrolled document must be captured")
        }
        check(source.image === imageView.image, "capture must retain the original image rather than rasterize hover text")
        check(source.visibleScreenFrame.width < source.screenFrame.width
                && source.visibleScreenFrame.height < source.screenFrame.height,
              "source capture must retain actual clipping on both axes")
        check(sameRect(source.screenFrame, window.convertToScreen(imageView.convert(imageView.bounds, to: nil))),
              "source bounds must survive flipped document and window coordinate conversion")
        check(sameRect(source.visibleScreenFrame, window.convertToScreen(imageView.convert(imageView.visibleRect, to: nil))),
              "visible bounds must use the clipped image rect in screen coordinates")
        check(!source.aspectFill && close(source.cornerRadius, 7), "plain image views preserve fit and corner metadata")

        imageView.alphaValue = 0.63
        check(WorkspaceDetailTransitionOverlay.snapshot(of: host, excluding: source) != nil,
              "a real attached AppKit view must produce a transition snapshot")
        check(close(imageView.alphaValue, 0.63), "snapshot exclusion must restore the original source alpha")
        document.isHidden = true
        check(WorkspaceCoverTransitionSource.capture(from: document) == nil, "hidden sources must not animate")
        document.isHidden = false
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 420))
        check(WorkspaceCoverTransitionSource.capture(from: imageView) == nil, "fully clipped sources must not animate")
        scroll.removeFromSuperview()

        let thumbnail = WorkspaceMediaThumbnail(url: nil, poster: true, appearance: SkinAppearance(),
                                                componentID: "discovery.feed", previewOnly: true, fixedSize: false)
        thumbnail.translatesAutoresizingMaskIntoConstraints = true
        thumbnail.frame = NSRect(x: 20, y: 20, width: 120, height: 100)
        thumbnail.transitionImageView.image = image()
        host.addSubview(thumbnail)
        host.layoutSubtreeIfNeeded()
        check(WorkspaceCoverTransitionSource.capture(from: thumbnail)?.aspectFill == true,
              "real adaptive thumbnails must retain their aspect-fill rendering mode")
        thumbnail.removeFromSuperview()
        check(WorkspaceCoverTransitionSource.capture(from: NSImageView()) == nil, "detached or empty images must fall back")
        check(WorkspaceCoverTransitionSource.capture(from: nil) == nil, "missing selection must fall back")
    }

    static func completionLifecycle(host: NSView, window: NSWindow) {
        let cover = NSImageView(frame: NSRect(x: 360, y: 160, width: 152, height: 228))
        cover.image = image()
        cover.alphaValue = 0.73
        host.addSubview(cover)
        let sourceView = NSImageView(frame: NSRect(x: 20, y: 70, width: 72, height: 108))
        sourceView.image = cover.image
        host.addSubview(sourceView)
        let source = WorkspaceCoverTransitionSource.capture(from: sourceView)!
        let snapshot = WorkspaceDetailTransitionOverlay.snapshot(of: host, excluding: source)!
        defer { cover.removeFromSuperview(); sourceView.removeFromSuperview() }

        for style in [WorkspaceDetailTransitionStyle.cover, .cinema, .iris] {
            var completions = 0
            let overlay = WorkspaceDetailTransitionOverlay(frame: host.bounds, snapshot: snapshot)
            host.addSubview(overlay)
            overlay.play(source: source, destination: cover,
                         settings: .init(style: style, duration: 0.2)) { completions += 1 }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(completions == 1 && overlay.superview == nil,
                      "Reduce Motion must navigate immediately and clean up")
            } else {
                check(completions == 0 && close(cover.alphaValue, 0), "the target cover must stay suppressed until completion")
                let backdrop = overlay.layer!.sublayers!.first!
                let container = overlay.layer!.sublayers!.last!
                let picture = container.sublayers!.first!
                check(container.mask != nil, "animated covers must retain the source clipping mask")
                if style == .cinema {
                    check((picture.filters?.first as? CIFilter)?.name == "detailGamma", "cinema mode must apply actual gamma processing")
                }
                if style == .iris {
                    check((backdrop.mask as? CAShapeLayer)?.fillRule == .evenOdd, "iris mode must cut a revealing aperture in the old page")
                }
                if style == .cover {
                    waitForCompletion { completions == 1 }
                } else if style == .iris {
                    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53)!
                    overlay.keyDown(with: escape)
                } else { overlay.finish() }
            }
            overlay.finish()
            check(completions == 1, "completion, explicit finish and Escape must not complete a transition twice")
            check(close(cover.alphaValue, 0.73), "all completion paths must restore the target's original alpha")
            check(overlay.superview == nil && (overlay.layer?.sublayers?.isEmpty ?? true),
                  "finished transitions must release the overlay and all snapshot layers")
            drain(for: 0.25)
            check(completions == 1, "a delayed Core Animation callback must not complete a cancelled transition again")
        }

        for style in [WorkspaceDetailTransitionStyle.none, .cover] {
            var completions = 0
            let overlay = WorkspaceDetailTransitionOverlay(frame: host.bounds, snapshot: snapshot)
            host.addSubview(overlay)
            overlay.play(source: nil, destination: cover, settings: .init(style: style, duration: 0.2)) { completions += 1 }
            check(close(cover.alphaValue, 0.73), "missing source must not hide the real destination cover")
            waitForCompletion { completions == 1 }
            overlay.finish()
            check(completions == 1 && overlay.superview == nil, "disabled and missing-source transitions must cleanly complete once")
        }
        let detachedCover = NSImageView(frame: cover.frame)
        let foreignWindow = NSWindow(contentRect: NSRect(x: 800, y: 100, width: 300, height: 300),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        foreignWindow.isReleasedWhenClosed = false
        let foreignCover = NSImageView(frame: NSRect(x: 20, y: 20, width: 100, height: 150))
        foreignWindow.contentView!.addSubview(foreignCover)
        let hiddenCover = NSImageView(frame: cover.frame)
        hiddenCover.isHidden = true
        host.addSubview(hiddenCover)
        defer { foreignWindow.close(); hiddenCover.removeFromSuperview() }
        for invalidDestination in [detachedCover, foreignCover, hiddenCover] {
            invalidDestination.image = cover.image
            invalidDestination.alphaValue = 0.42
            var completions = 0
            let overlay = WorkspaceDetailTransitionOverlay(frame: host.bounds, snapshot: snapshot)
            host.addSubview(overlay)
            overlay.play(source: source, destination: invalidDestination,
                         settings: .init(style: .cover, duration: 0.2)) { completions += 1 }
            check(close(invalidDestination.alphaValue, 0.42),
                  "detached, foreign-window and hidden destinations must never be suppressed")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let start = overlay.convert(window.convertFromScreen(source.screenFrame), from: nil)
                check(sameRect(overlay.layer!.sublayers!.last!.frame, start),
                      "invalid destinations must use source geometry instead of unrelated view coordinates")
            }
            overlay.finish()
            check(completions == 1 && close(invalidDestination.alphaValue, 0.42),
                  "invalid-destination fallback must finish once without changing destination alpha")
        }
        check(!host.subviews.contains { $0 is WorkspaceDetailTransitionOverlay }, "no overlay may survive any tested path")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            print("SKIP: animated layer checks because system Reduce Motion is enabled; immediate-navigation paths passed")
        }
    }

    static func waitForCompletion(_ finished: () -> Bool) {
        CATransaction.flush()
        let deadline = Date().addingTimeInterval(2)
        while !finished() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(finished(), "Core Animation must finish within the bounded transition interval")
    }

    static func drain(for seconds: TimeInterval) {
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
