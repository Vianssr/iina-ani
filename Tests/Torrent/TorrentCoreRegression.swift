import Foundation
import CryptoKit
@testable import IINA_ANI

@main @MainActor enum TorrentCoreRegression {
    enum Failure: Error { case assertion(String) }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    static func waitUntil(_ message: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.assertion(message) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let torrent = root.appendingPathComponent("fixture.torrent")
        let seedDirectory = root.appendingPathComponent("seed")
        let original = try Data(contentsOf: seedDirectory.appendingPathComponent("payload.bin"))
        try require(TorrentSession.coreVersion == "2.1.2", "wrong linked native core")
        print("App-linked libtorrent \(TorrentSession.coreVersion)")
        for cycle in 0..<3 {
            let configuration = TorrentSession.Configuration(publicNetwork: false, uploadLimitBytesPerSecond: 1_048_576)
            let seed = try TorrentSession(configuration: configuration)
            let receiver = try TorrentSession(configuration: configuration)
            do {
                let seedID = try await seed.add(torrent: torrent, directory: seedDirectory)
                try await seed.select(seedID, fileIndices: [0])
                try await seed.resume(seedID)
                try await waitUntil("seed check timed out") { try await seed.status(seedID).finished }
                try await waitUntil("listener did not bind") { try await seed.listenPort() != 0 }
                let port = try await seed.listenPort()
                let destination = root.appendingPathComponent("download-\(cycle)")
                let id = try await receiver.add(torrent: torrent, directory: destination)
                try await receiver.select(id, fileIndices: [0])
                try await receiver.resume(id)
                let before = try await receiver.status(id)
                try require(before.verifiedBytes == 0 && !before.finished, "empty receiver claims bytes")
                try await receiver.connect(id, loopbackPort: port)
                var sawFinished = false
                var sawPeer = false
                try await waitUntil("seed peer did not connect before reader cancellation test") {
                    for event in try await receiver.pollEvents() {
                        if event.torrentID == id && event.kind == .peerConnected { sawPeer = true }
                    }
                    return sawPeer
                }
                let pendingReader = try await receiver.openReader(id, fileIndex: 0)
                let pendingRead = Task {
                    try await receiver.readReader(pendingReader, offset: UInt64(original.count - 64), length: 64)
                }
                try await Task.sleep(for: .milliseconds(50))
                pendingRead.cancel()
                do {
                    _ = try await pendingRead.value
                    throw Failure.assertion("cancelled seeded piece read unexpectedly succeeded")
                } catch is CancellationError {}
                try await receiver.closeReader(pendingReader)
                try await waitUntil("real transfer timed out") {
                    for event in try await receiver.pollEvents() {
                        try require(event.kind != .failure, "native transfer error")
                        if event.torrentID == id {
                            sawFinished = sawFinished || event.kind == .finished
                            sawPeer = sawPeer || event.kind == .peerConnected
                        }
                    }
                    return try await receiver.status(id).finished && sawFinished && sawPeer
                }
                let final = try await receiver.status(id)
                try require(final.totalBytes == original.count && final.verifiedBytes == original.count,
                            "verified byte count includes padding or misses final piece")
                let reader = try await receiver.openReader(id, fileIndex: 0)
                let offset: UInt64 = 17_123
                let bytes = try await receiver.readReader(reader, offset: offset, length: 180_000)
                try require(bytes == original.subdata(in: Int(offset)..<Int(offset) + bytes.count),
                            "reader returned incorrect offset bytes from a completed piece")
                try require(try await receiver.readReader(reader, offset: UInt64(original.count), length: 8).isEmpty,
                            "reader did not return empty at exact EOF")
                try await receiver.closeReader(reader)
                try await receiver.remove(id, deleteFiles: false)
                try require(try await receiver.pollEvents().allSatisfy { $0.torrentID != id },
                            "cancelled transfer leaked a queued event")
                await receiver.close()
                await seed.close()
                let downloaded = try Data(contentsOf: destination.appendingPathComponent("payload.bin"))
                try require(downloaded == original, "downloaded bytes differ")
                let hash = SHA256.hash(data: downloaded).map { String(format: "%02x", $0) }.joined()
                print("cycle \(cycle + 1): \(downloaded.count) exact bytes SHA256=\(hash); copied peer/finished alerts; joined close")
                await receiver.close()
                do {
                    _ = try await receiver.status(id)
                    throw Failure.assertion("closed session accepted command")
                } catch let error as TorrentSession.Failure {
                    try require(error == .closed, "closed session returned wrong error")
                }
            } catch {
                await receiver.close()
                await seed.close()
                throw error
            }
        }
        let cancelled = try TorrentSession(configuration: .init(publicNetwork: false, uploadLimitBytesPerSecond: 1_048_576))
        do {
            let destination = root.appendingPathComponent("cancelled")
            let id = try await cancelled.add(torrent: torrent, directory: destination)
            try await cancelled.remove(id, deleteFiles: false)
            do {
                _ = try await cancelled.status(id)
                throw Failure.assertion("removed transfer is still queryable")
            } catch let error as TorrentSession.Failure {
                try require(error.code == 4, "removed transfer returned wrong error")
            }
            let replacement = try await cancelled.add(torrent: torrent, directory: destination)
            try require(replacement != id, "transfer identifier reused after cancellation")
            let cancellationReader = try await cancelled.openReader(replacement, fileIndex: 0)
            let pendingRead = Task { try await cancelled.readReader(cancellationReader, offset: 0, length: 65_536) }
            try await Task.sleep(for: .milliseconds(100))
            let cancellationStart = ContinuousClock.now
            pendingRead.cancel()
            do {
                _ = try await pendingRead.value
                throw Failure.assertion("cancelled piece read unexpectedly succeeded")
            } catch is CancellationError {
                try require(cancellationStart.duration(to: .now) < .seconds(2), "piece read cancellation was not prompt")
            }
            try await cancelled.closeReader(cancellationReader)
            try await cancelled.remove(replacement, deleteFiles: false)
            await cancelled.close()
        } catch {
            await cancelled.close()
            throw error
        }
        for _ in 0..<10 {
            let session = try TorrentSession(configuration: .init(publicNetwork: false, uploadLimitBytesPerSecond: 1_048_576))
            await session.close()
            await session.close()
        }
        print("PASS: cancel/re-add isolation, closed-session rejection, ten repeated idle starts/stops")
    }
}
