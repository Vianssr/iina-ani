import AppKit

/// A small glass band for popup navigation or actions. Reading surfaces remain ordinary Skin panels.
@MainActor
final class WorkspaceGlassSurface: NSView {
    let contentView = NSView()
    private let skinAppearance: SkinAppearance
    private let componentID: String
    private let preferredCornerRadius: CGFloat
    private let opaqueSurface = NSView()
    private let effectSurface: NSView
    private var contentConstraints: [NSLayoutConstraint] = []
    private var usesOpaqueSurface: Bool?

    init(appearance: SkinAppearance, cornerRadius: CGFloat = 20, componentID: String = "detail.media") {
        skinAppearance = appearance
        self.componentID = componentID
        preferredCornerRadius = cornerRadius
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            effectSurface = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effectSurface = effect
        }
        super.init(frame: .zero)
        wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        opaqueSurface.bindSkin(appearance, slot: "panel", componentID: componentID)
        for surface in [opaqueSurface, effectSurface] {
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.wantsLayer = true
            addSubview(surface)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: trailingAnchor),
                surface.topAnchor.constraint(equalTo: topAnchor),
                surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshSurface), name: SkinAppearance.didChangeNotification,
            object: appearance)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshSurface),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshSurface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func refreshSurface() {
        let style = skinAppearance.resolve(slot: "panel", componentID: componentID)
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let needsOpaque = increasedContrast || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let authoredSurface = style.values["background"] != nil || style.assetIDs[.background] != nil
            || style.assetIDs[.decoration] != nil || style.values["opacity"] != nil
        let opaque = needsOpaque || authoredSurface
        let radius = style.values["radius"] == nil ? preferredCornerRadius : style.radius
        appearance = NSAppearance(named: skinAppearance.effectiveColorScheme == .dark ? .darkAqua : .aqua)
        opaqueSurface.workspaceSkinBinding?.refresh()
        opaqueSurface.layer?.cornerRadius = radius
        opaqueSurface.layer?.masksToBounds = true
        if needsOpaque {
            opaqueSurface.alphaValue = 1
            opaqueSurface.layer?.backgroundColor = style.background.withAlphaComponent(1).cgColor
        }
        if increasedContrast {
            opaqueSurface.layer?.borderWidth = max(1, style.borderWidth)
            opaqueSurface.layer?.borderColor = style.foreground.withAlphaComponent(0.6).cgColor
        }
        effectSurface.layer?.cornerRadius = radius
        if #available(macOS 26.0, *), let glass = effectSurface as? NSGlassEffectView {
            glass.cornerRadius = radius
            glass.tintColor = style.background.withAlphaComponent(0.08)
        } else {
            effectSurface.layer?.masksToBounds = true
            effectSurface.layer?.borderWidth = 1
            effectSurface.layer?.borderColor = style.foreground.withAlphaComponent(0.08).cgColor
        }
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = opaque ? 0 : 0.04
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        if usesOpaqueSurface != opaque {
            NSLayoutConstraint.deactivate(contentConstraints)
            contentView.removeFromSuperview()
            if #available(macOS 26.0, *), let glass = effectSurface as? NSGlassEffectView {
                glass.contentView = opaque ? nil : contentView
            }
            let container = opaque ? opaqueSurface : effectSurface
            if contentView.superview == nil { container.addSubview(contentView) }
            contentConstraints = [
                contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: container.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ]
            NSLayoutConstraint.activate(contentConstraints)
            usesOpaqueSurface = opaque
        }
        opaqueSurface.isHidden = !opaque
        effectSurface.isHidden = opaque
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshSurface()
    }
}
