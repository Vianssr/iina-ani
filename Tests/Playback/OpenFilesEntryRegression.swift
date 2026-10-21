import Cocoa
@testable import IINA_ANI

@main
struct OpenFilesEntryRegression {
    enum Failure: Error { case assertion(String), video, danmaku }

    @MainActor
    final class Controller: OpenFilesViewController {
        enum Scenario { case videoFailure, danmakuFailure, emptyMedia, cancellation }
        var scenario: Scenario = .videoFailure
        var errors: [any Error] = []
        var reachedDanmaku = false

        override func getVideo() async throws -> YouGetJSON {
            switch scenario {
            case .videoFailure: throw Failure.video
            case .cancellation: throw CancellationError()
            case .danmakuFailure, .emptyMedia:
                var media = YouGetJSON(url: "file:///isolated/example.mp4")
                media.streams = [:]
                return media
            }
        }

        override func getDanmaku(_ media: YouGetJSON) async throws -> YouGetJSON {
            reachedDanmaku = true
            if scenario == .danmakuFailure { throw Failure.danmaku }
            return media
        }

        override func presentError(_ error: any Error) -> Bool {
            errors.append(error)
            return true
        }
    }

    @MainActor
    static func main() async throws {
        for scenario in [Controller.Scenario.videoFailure, .danmakuFailure, .emptyMedia, .cancellation] {
            let controller = Controller(nibName: nil, bundle: nil)
            controller.scenario = scenario
            let original = URL(fileURLWithPath: "/isolated/example.mp4")
            controller.videoURL = original
            await controller.openFiles()
            guard controller.videoURL == original, !controller.isViewLoaded else {
                throw Failure.assertion("failed or cancelled opening must retain input and not enter window completion")
            }
            if scenario == .cancellation {
                guard controller.errors.isEmpty, !controller.reachedDanmaku else {
                    throw Failure.assertion("cancellation must not present an error or continue preparation")
                }
            } else {
                guard controller.errors.count == 1 else {
                    throw Failure.assertion("opening failure must reach the caller instead of silently returning")
                }
                switch (scenario, controller.errors[0]) {
                case (.videoFailure, Failure.video):
                    guard !controller.reachedDanmaku else { throw Failure.assertion("video failure continued into danmaku") }
                case (.danmakuFailure, Failure.danmaku), (.emptyMedia, VideoGetError.notFountData): break
                default: throw Failure.assertion("opening must retain the original failure")
                }
            }
        }
        print("PASS: open-files video/danmaku failures, empty media and cancellation retain input without false completion")
    }
}
