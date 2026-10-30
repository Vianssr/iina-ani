import Observation
import OSLog
import SwiftUI
import UIKit

/// Rotates the scene that contains this player, without locking future device rotation.
@MainActor @Observable
final class PlayerOrientationController {
    private(set) var isLandscape = false
    private(set) var isAttached = false
    var errorMessage: String?

    @ObservationIgnored private weak var host: PlayerOrientationViewController?
    @ObservationIgnored private var requestNumber = 0
    private static let logger = Logger(subsystem: "com.LlS.iina-ani.ios", category: "PlayerOrientation")

    func toggleOrientation() {
        guard let scene = host?.viewIfLoaded?.window?.windowScene else {
            errorMessage = String(localized: "The player is not ready to rotate yet.")
            return
        }
        request(Self.orientation(of: scene).isLandscape ? .portrait : .landscape)
    }

    func requestLandscape() { request(.landscape) }
    func requestPortrait() { request(.portrait) }

    private func request(_ orientations: UIInterfaceOrientationMask) {
        guard let host, let window = host.viewIfLoaded?.window, let scene = window.windowScene else {
            errorMessage = String(localized: "The player is not ready to rotate yet.")
            return
        }
        errorMessage = nil
        requestNumber += 1
        let request = requestNumber

        // Refresh the actual presentation hierarchy, not another window's controller.
        // Supported masks stay unrestricted; this is a one-off geometry preference.
        var parent: UIViewController? = host
        while let controller = parent {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            parent = controller.parent
        }
        var presented = window.rootViewController
        while let controller = presented {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            presented = controller.presentedViewController
        }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { [weak self, weak host] error in
            #if DEBUG
            let failure = error as NSError
            Self.logger.error("Geometry denied: domain=\(failure.domain, privacy: .public), code=\(failure.code), reason=\(failure.localizedDescription, privacy: .public)")
            #endif
            // UIKit can deliver a denial asynchronously (e.g. an iPad windowing restriction).
            Task { @MainActor [weak self, weak host] in
                guard let self, let host, self.host === host, self.requestNumber == request else { return }
                self.errorMessage = String(localized: "The system could not rotate this window. Try rotating your device or opening the app full screen.")
            }
        }
    }

    fileprivate func attach(_ host: PlayerOrientationViewController) {
        self.host = host
        refresh(from: host)
    }

    fileprivate func detach(_ host: PlayerOrientationViewController) {
        guard self.host === host else { return }
        self.host = nil
        requestNumber += 1
        Task { @MainActor [weak self] in
            guard let self, self.host == nil else { return }
            self.isAttached = false
        }
    }

    fileprivate func refresh(from host: PlayerOrientationViewController) {
        // Defer Observation changes outside SwiftUI's representable/layout update.
        Task { @MainActor [weak self, weak host] in
            guard let self, let host, self.host === host else { return }
            let scene = host.viewIfLoaded?.window?.windowScene
            let attached = scene != nil
            if self.isAttached != attached { self.isAttached = attached }
            guard let scene else { return }
            let orientation = Self.orientation(of: scene)
            guard orientation != .unknown else { return }
            if self.isLandscape != orientation.isLandscape { self.isLandscape = orientation.isLandscape }
        }
    }

    private static func orientation(of scene: UIWindowScene) -> UIInterfaceOrientation {
        if #available(iOS 26.0, *) { return scene.effectiveGeometry.interfaceOrientation }
        return scene.interfaceOrientation
    }
}

/// Attach once to the outer player container so its identity survives layout changes.
struct PlayerOrientationObserver: UIViewControllerRepresentable {
    let controller: PlayerOrientationController

    func makeUIViewController(context: Context) -> PlayerOrientationViewController {
        let viewController = PlayerOrientationViewController()
        viewController.orientationController = controller
        controller.attach(viewController)
        return viewController
    }

    func updateUIViewController(_ viewController: PlayerOrientationViewController, context: Context) {
        if viewController.orientationController !== controller {
            viewController.orientationController?.detach(viewController)
            viewController.orientationController = controller
            controller.attach(viewController)
        }
        controller.refresh(from: viewController)
    }

    static func dismantleUIViewController(_ viewController: PlayerOrientationViewController, coordinator: ()) {
        viewController.orientationController?.detach(viewController)
        viewController.orientationController = nil
    }
}

final class PlayerOrientationViewController: UIViewController {
    weak var orientationController: PlayerOrientationController?

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        traitCollection.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        orientationController?.refresh(from: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        orientationController?.refresh(from: self)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.orientationController?.refresh(from: self)
        }
    }
}
