import AppKit
@testable import IINA_ANI

@main
@MainActor
struct WorkspaceDetailPreferencesRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func commentsVertical(_ controller: WorkspaceDetailController) -> Bool {
        // Inspect the private presentation state without adding a production test API.
        Mirror(reflecting: controller).children.first { $0.label == "commentsVertical" }!.value as! Bool
    }

    static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let preferences = Preferences.shared
        let key = "workspace.detailCommentsVertical"
        let saved = preferences.prefs.object(forKey: key)
        defer {
            if let saved { preferences.prefs.set(saved, forKey: key) }
            else { preferences.prefs.removeObject(forKey: key) }
        }
        preferences.detailCommentsVertical = true
        let delegate = AppDelegate()
        let appearance = SkinAppearance()
        var controller: WorkspaceDetailController? = WorkspaceDetailController(
            delegate: delegate, appearance: appearance, previewOnly: true)
        weak let released = controller
        _ = controller!.view
        check(commentsVertical(controller!), "detail must start with the saved comments preference")

        let suite = "iina-detail-preferences.\(UUID().uuidString)"
        await Task.detached {
            precondition(!Thread.isMainThread, "the regression must post outside the main actor")
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            // Account metadata persistence writes an unrelated defaults key on its actor.
            defaults.set(Data("[]".utf8), forKey: "site-accounts")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }.value
        await drainMainQueue()
        check(commentsVertical(controller!), "unrelated account persistence must preserve the comments layout")

        for vertical in [false, true] {
            await Task.detached {
                Preferences.shared.detailCommentsVertical = vertical
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification,
                                                object: Preferences.shared.prefs)
            }.value
            await drainMainQueue()
            check(commentsVertical(controller!) == vertical, "background preference changes must update the detail layout")
        }
        preferences.detailCommentsVertical = false
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: preferences.prefs)
        await drainMainQueue()
        check(!commentsVertical(controller!), "main-thread preference changes must still update the detail layout")

        // Leave a UI refresh queued, then close the detail before delivery.
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
            posted.signal()
        }
        check(posted.wait(timeout: .now() + 5) == .success, "background notification must not wait for the main queue")
        controller = nil
        await drainMainQueue()
        check(released == nil, "notification delivery must not retain a closed detail controller")
        await Task.detached {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }.value
        await drainMainQueue()
        print("PASS: detail preferences accept background account writes, update both layouts and release closed controllers")
    }
}
