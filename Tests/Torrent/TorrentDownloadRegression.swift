import Cocoa
import Foundation
import CryptoKit
import Darwin
@testable import IINA_ANI

@main
@MainActor enum TorrentDownloadRegression {
    struct Failure: Error { let message: String }
    final class TempRootBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URL
        init(_ value: URL) { self.value = value }
        func get() -> URL { lock.withLock { value } }
        func set(_ value: URL) { lock.withLock { self.value = value } }
    }
    static func phase(_ label: String) {
        FileHandle.standardError.write(Data("[W11.2] phase: \(label)\n".utf8))
    }
    static func safeError(_ error: Error) -> String {
        if let failure = error as? DownloadFailure { return failure.rawValue }
        if let failure = error as? TorrentSession.Failure { return "native error code \(failure.code)" }
        if let failure = error as? Failure { return failure.message }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }
    static func inPhase<T>(_ label: String, operation: () async throws -> T) async throws -> T {
        phase(label)
        do { return try await operation() }
        catch { throw Failure(message: "phase \(label) failed: \(safeError(error))") }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func makeService(root: URL, store: URL? = nil, output: URL? = nil, temporary: URL? = nil,
                            tempRootBox: TempRootBox? = nil) throws -> DownloadService {
        let storeURL = store ?? root.appendingPathComponent("tasks-v1.json")
        let outputDirectory = output ?? root.appendingPathComponent("output", isDirectory: true)
        let temporaryDirectory = temporary ?? root.appendingPathComponent("temporary", isDirectory: true)
        return try DownloadService(storeURL: storeURL,
            policy: {
                DownloadPolicySnapshot(outputDirectory: outputDirectory, concurrencyLimit: 2,
                                       temporaryDirectory: tempRootBox?.get() ?? temporaryDirectory)
            },
            validator: { _ in throw DownloadFailure.unsupportedSource },
            resolver: { _ in throw DownloadFailure.unsupportedSource },
            torrentEnabled: { true })
    }

    static func waitFor(_ service: DownloadService, id: UUID, seconds: Int = 180,
                        _ predicate: @Sendable (DownloadRecord) -> Bool) async throws -> DownloadRecord {
        let until = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < until {
            let value = try await service.record(id)
            if predicate(value) { return value }
            if value.state == .failed { throw Failure(message: "task failed: \(value.failure?.rawValue ?? "unknown")") }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "task did not reach expected state")
    }

    static func magnetURI(for torrent: URL, port: UInt16) async throws -> String {
        let probeRoot = torrent.deletingLastPathComponent().appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeRoot) }
        let probe = try TorrentSession(configuration: .init(publicNetwork: false, uploadLimitBytesPerSecond: 64 * 1024))
        let id = try await probe.add(torrent: torrent, directory: probeRoot)
        guard let metadata = try await probe.metadata(id) else { throw Failure(message: "fixture metadata missing") }
        await probe.close()
        let xt: String
        if let v1 = metadata.infoHashes.first(where: { $0.hasPrefix("v1:") }) {
            xt = "urn:btih:" + v1.dropFirst(3)
        } else if let v2 = metadata.infoHashes.first(where: { $0.hasPrefix("v2:") }) {
            xt = "urn:btmh:1220" + v2.dropFirst(3)
        } else { throw Failure(message: "fixture had no supported infohash") }
        var components = URLComponents()
        components.scheme = "magnet"
        components.queryItems = [URLQueryItem(name: "xt", value: xt), URLQueryItem(name: "x.pe", value: "127.0.0.1:\(port)")]
        guard let value = components.string else { throw Failure(message: "could not construct loopback magnet") }
        return value
    }

    static func makeTask(_ service: DownloadService, torrent: URL, port: UInt16, title: String,
                         localFile: Bool = false) async throws -> DownloadRecord {
        phase(localFile ? "local torrent import: \(title)" : "magnet import via loopback peer: \(title)")
        let upload = try TorrentUploadPolicy(bytesPerSecond: 512 * 1024, acknowledged: true)
        let raw = localFile ? torrent.absoluteString : try await magnetURI(for: torrent, port: port)
        let imported: TorrentImport
        do { imported = try await service.importTorrent(raw: raw, uploadPolicy: upload) }
        catch { throw Failure(message: "\(title) metadata import failed: \(safeError(error))") }
        let algorithms = Set(imported.infoHashes.map { String($0.prefix(3)) })
        let expected: Set<String> = torrent.lastPathComponent.contains("hybrid")
            ? ["v1:", "v2:"] : torrent.lastPathComponent == "fixture-v2.torrent" ? ["v2:"] : ["v1:"]
        try require(algorithms == expected && imported.infoHashes.count == expected.count,
                    "metadata lost or invented an algorithm-tagged torrent identity")
        try require(imported.isPrivate == (torrent.lastPathComponent == "fixture-private-hybrid.torrent"),
                    "metadata did not preserve the torrent private flag")
        phase("\(title): metadata import returned; selecting exact playable file")
        guard let selected = imported.files.first(where: { $0.path.hasSuffix("payload.mkv") && $0.isPlayableMedia }), selected.index > 0 else {
            throw Failure(message: "fixture did not expose playable payload.mkv as a non-first file")
        }
        let task = try await service.createTorrentTask(importID: imported.id, fileIndex: selected.index,
                                                       uploadPolicy: upload, title: title)
        phase("\(title): task created; exact file index \(selected.index)")
        return task
    }

    static func connect(_ service: DownloadService, id: UUID, port: UInt16) async throws {
        for _ in 0..<300 {
            do { try await service.connectTorrentPeer(id, loopbackPort: port); return }
            catch { try await Task.sleep(for: .milliseconds(20)) }
        }
        throw Failure(message: "DownloadService never registered an active native torrent")
    }

    static func digest(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verifyPlayableMedia(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffprobe", "-v", "error", "-show_entries", "format=format_name,duration", "-show_entries", "stream=codec_name", "-of", "json", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "ffprobe rejected completed torrent output")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let format = json?["format"] as? [String: Any]
        let streams = json?["streams"] as? [[String: Any]]
        let names = format?["format_name"] as? String ?? ""
        let duration = Double(format?["duration"] as? String ?? "0") ?? 0
        try require(names.contains("matroska") && duration > 0 && streams?.contains(where: { $0["codec_name"] as? String == "ffv1" }) == true,
                    "completed non-first selection is not playable FFV1 Matroska")
    }


    static func waitSeed(_ session: TorrentSession, id: UInt32) async throws {
        let until = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < until {
            if try await session.status(id).finished { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw Failure(message: "seed failed its native file check")
    }

    static func startSeed(torrent: URL, directory: URL) async throws -> (TorrentSession, UInt16) {
        let session: TorrentSession
        do { session = try TorrentSession(configuration: .init(publicNetwork: false, uploadLimitBytesPerSecond: 512 * 1024)) }
        catch { throw Failure(message: "seed session init failed: \(error)") }
        let id: UInt32
        do { id = try await session.add(torrent: torrent, directory: directory.deletingLastPathComponent()) }
        catch { throw Failure(message: "seed add failed: \(error)") }
        let metadata: TorrentSession.Metadata
        do {
            guard let value = try await session.metadata(id) else { throw Failure(message: "seed metadata missing") }
            metadata = value
        } catch { throw Failure(message: "seed metadata failed: \(error)") }
        do { try await session.select(id, fileIndices: Set(metadata.files.filter { !$0.isPad }.map(\.index))) }
        catch { throw Failure(message: "seed select failed: \(error)") }
        do { try await session.resume(id) }
        catch { throw Failure(message: "seed resume failed: \(error)") }
        do { try await waitSeed(session, id: id) }
        catch { throw Failure(message: "seed status failed: \(error)") }
        let until = ContinuousClock.now + .seconds(10)
        do {
            while try await session.listenPort() == 0 && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(20)) }
            let port = try await session.listenPort()
            try require(port > 0, "local peer listener did not start")
            return (session, port)
        } catch { throw Failure(message: "seed listener failed: \(error)") }
    }

    static func launch(_ mode: String, root: URL, torrent: URL, port: UInt16) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [mode, root.path, torrent.path, String(port)]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.standardError
        try child.run()
        return child
    }

    static func waitForMarker(_ url: URL, child: Process, seconds: Int) async throws {
        let until = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < until {
            if FileManager.default.fileExists(atPath: url.path) { return }
            if !child.isRunning { throw Failure(message: "worker exited before checkpoint") }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "worker did not checkpoint partial torrent progress")
    }

    static func assertPartialSnapshot(root: URL, state expectedState: String = "downloading") throws {
        let data = try Data(contentsOf: root.appendingPathComponent("tasks-v1.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let records = object?["records"] as? [[String: Any]]
        guard let record = records?.first,
              let bytes = record["bytes"] as? Int, let total = record["totalBytes"] as? Int,
              let state = record["state"] as? String else {
            throw Failure(message: "persisted task lacks partial progress snapshot")
        }
        try require(state == expectedState && bytes > 0 && bytes < total,
                    "SIGKILL checkpoint was not genuinely partial: state=\(state), bytes=\(bytes)/\(total)")
    }

    static func interruptedRestart(root: URL, torrent: URL, source: URL, port: UInt16, graceful: Bool = false) async throws {
        phase(graceful ? "normal process exit with partial verified bytes" : "forced process kill with partial verified bytes")
        let child = try launch(graceful ? "--graceful" : "--checkpoint", root: root, torrent: torrent, port: port)
        let marker = root.appendingPathComponent("checkpoint")
        try await waitForMarker(marker, child: child, seconds: 90)
        if graceful {
            child.waitUntilExit()
            try require(child.terminationStatus == 0, "normal shutdown worker failed")
            try assertPartialSnapshot(root: root, state: "paused")
        } else {
            try await Task.sleep(for: .seconds(7))
            try assertPartialSnapshot(root: root)
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            try require(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,
                        "checkpoint worker was not killed as a real process")
        }
        phase("relaunch same task store and resume shared private payload")
        let reopen = try launch("--reopen", root: root, torrent: torrent, port: port)
        reopen.waitUntilExit()
        try require(reopen.terminationStatus == 0, "process restart did not finish the persisted task")
        let result = try String(contentsOf: root.appendingPathComponent("result.sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(result == digest(source), "resumed selected-file SHA-256 differs from seed")
    }


    static func localSingle(root: URL, torrent: URL, source: URL, port: UInt16) async throws {
        let service = try makeService(root: root)
        let task = try await makeTask(service, torrent: torrent, port: port, title: torrent.lastPathComponent, localFile: true)
        phase("local task created; observing downloading state")
        _ = try await waitFor(service, id: task.id) { $0.state == .downloading }
        phase("local task downloading; requesting explicit loopback peer")
        try await connect(service, id: task.id, port: port)
        let complete = try await waitFor(service, id: task.id, seconds: 180) { $0.state == .completed }
        guard let file = complete.completedFile else { throw Failure(message: "local torrent task omitted output") }
        try require(digest(file) == digest(source), "local torrent selected-file SHA-256 mismatch")
        try verifyPlayableMedia(file)
        await service.shutdown()
    }

    static func sharedPauseCancel(root: URL, torrent: URL, source: URL, port: UInt16) async throws {
        phase("v2 shared transfer and independent pause/cancel across policy-root change")
        let originalTemporary = root.appendingPathComponent("temporary", isDirectory: true)
        let changedTemporary = root.appendingPathComponent("changed-temporary", isDirectory: true)
        let tempRootBox = TempRootBox(originalTemporary)
        let service = try makeService(root: root, tempRootBox: tempRootBox)
        let first = try await makeTask(service, torrent: torrent, port: port, title: "paused then canceled")
        tempRootBox.set(changedTemporary)
        let second = try await makeTask(service, torrent: torrent, port: port, title: "shared surviving user")
        let cachedImport = try await service.importTorrent(raw: try await magnetURI(for: torrent, port: port),
            uploadPolicy: TorrentUploadPolicy(bytesPerSecond: 64 * 1024, acknowledged: true))
        await service.cancelTorrentImport(importID: cachedImport.id)
        try require(first.torrentStorageDirectory == second.torrentStorageDirectory,
                    "shared task did not retain the original transfer root after preference change")
        _ = try await waitFor(service, id: first.id) { $0.state == .downloading }
        _ = try await waitFor(service, id: second.id) { $0.state == .downloading }
        try await connect(service, id: first.id, port: port)
        _ = try await waitFor(service, id: first.id) { $0.bytes > 0 }
        try await service.pause(first.id)
        try await service.cancel(first.id)
        _ = try await waitFor(service, id: second.id) { $0.bytes > 0 }
        let complete = try await waitFor(service, id: second.id, seconds: 180) { $0.state == .completed }
        guard let file = complete.completedFile else { throw Failure(message: "shared task omitted published file") }
        try require(digest(file) == digest(source), "shared selected file SHA-256 mismatch")
        try verifyPlayableMedia(file)
        let privateRoot = root.appendingPathComponent("temporary/TorrentPrivate", isDirectory: true)
        let privateHashRoot = privateRoot.appendingPathComponent(complete.selection.torrent!.infoHashes.sorted().joined(separator: "_").replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        let privatePayload = privateHashRoot.appendingPathComponent("data/seed/payload.mkv")
        try require(FileManager.default.fileExists(atPath: privatePayload.path), "shared piece data did not remain under the private owner")
        try require(file != privatePayload && file.deletingLastPathComponent().lastPathComponent == "output",
                    "private torrent piece data was published as the user-facing file")
        await service.shutdown()
    }

    static func cancelPendingImport(root: URL, torrent: URL, port: UInt16) async throws {
        phase("cancel pending metadata import")
        let service = try makeService(root: root)
        let policy = try TorrentUploadPolicy(bytesPerSecond: 128 * 1024, acknowledged: true)
        let magnet = try await magnetURI(for: torrent, port: port)
        let imported: TorrentImport
        do { imported = try await service.importTorrent(raw: magnet, uploadPolicy: policy) }
        catch { throw Failure(message: "pending-import cancellation metadata failed: \(error)") }
        let privateRoot = root.appendingPathComponent("temporary/TorrentPrivate", isDirectory: true)
        let imports = try FileManager.default.contentsOfDirectory(at: privateRoot, includingPropertiesForKeys: nil)
        for importRoot in imports {
            for file in imported.files {
                let payload = importRoot.appendingPathComponent("data", isDirectory: true).appendingPathComponent(file.path)
                try require(!FileManager.default.fileExists(atPath: payload.path),
                            "metadata-only import wrote payload before explicit file selection")
            }
        }
        await service.cancelTorrentImport(importID: imported.id)
        var rejected = false
        do {
            _ = try await service.createTorrentTask(importID: imported.id, fileIndex: imported.files.first(where: { $0.isPlayableMedia })!.index,
                                                    uploadPolicy: policy, title: "canceled metadata import")
        } catch {
            rejected = true
        }
        try require(rejected, "canceled metadata import remained selectable")
        await service.shutdown()
    }

    static func boundedNoPeerImport(root: URL) async throws {
        phase("no-peers expected bounded metadata timeout")
        let service = try makeService(root: root)
        let policy = try TorrentUploadPolicy(bytesPerSecond: 128 * 1024, acknowledged: true)
        var components = URLComponents()
        components.scheme = "magnet"
        components.queryItems = [
            URLQueryItem(name: "xt", value: "urn:btih:\(String(repeating: "b", count: 40))"),
            URLQueryItem(name: "x.pe", value: "127.0.0.1:1")
        ]
        guard let magnet = components.string else { throw Failure(message: "could not create no-peer magnet") }
        let began = Date()
        do {
            _ = try await service.importTorrent(raw: magnet, uploadPolicy: policy, timeout: .seconds(4))
            throw Failure(message: "no-peer magnet unexpectedly acquired metadata")
        } catch let failure as DownloadFailure {
            try require(failure == .torrentNoPeers, "no-peer import mapped to \(failure.rawValue)")
        }
        try require(Date().timeIntervalSince(began) < 8, "no-peer metadata wait exceeded its explicit four-second timeout")
        await service.shutdown()
    }

    static func symlinkIsolation(root: URL, torrent: URL, port: UInt16) async throws {
        phase("symlink escape and external sentinel/delete isolation")
        let service = try makeService(root: root)
        let policy = try TorrentUploadPolicy(bytesPerSecond: 128 * 1024, acknowledged: true)
        let magnet = try await magnetURI(for: torrent, port: port)
        let imported: TorrentImport
        do { imported = try await service.importTorrent(raw: magnet, uploadPolicy: policy) }
        catch { throw Failure(message: "symlink-test metadata import failed: \(error)") }
        let hashKey = imported.infoHashes.sorted().joined(separator: "_").replacingOccurrences(of: ":", with: "-")
        let stable = root.appendingPathComponent("temporary/TorrentPrivate", isDirectory: true).appendingPathComponent(hashKey, isDirectory: true)
        let outside = root.appendingPathComponent("outside-sentinel", isDirectory: true)
        try FileManager.default.createDirectory(at: stable, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("must survive".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: stable.appendingPathComponent("data"), withDestinationURL: outside)
        guard let file = imported.files.first(where: { $0.isPlayableMedia }) else { throw Failure(message: "fixture has no playable file") }
        do {
            _ = try await service.createTorrentTask(importID: imported.id, fileIndex: file.index,
                                                    uploadPolicy: policy, title: "symlink escape")
            throw Failure(message: "pre-existing private data symlink was accepted")
        } catch let failure as DownloadFailure {
            try require(failure == .invalidSelection, "symlink path mapped to \(failure.rawValue)")
        }
        try require(try Data(contentsOf: sentinel) == Data("must survive".utf8), "symlink rejection changed external sentinel")
        try require(FileManager.default.fileExists(atPath: stable.appendingPathComponent("data").path), "symlink path was removed")
        await service.cancelTorrentImport(importID: imported.id)
        await service.shutdown()
    }

    static func downloadAndClose(root: URL, torrent: URL, source: URL, port: UInt16, title: String) async throws -> DownloadRecord {
        let service = try makeService(root: root)
        let task = try await makeTask(service, torrent: torrent, port: port, title: title)
        _ = try await waitFor(service, id: task.id) { $0.state == .downloading }
        try await connect(service, id: task.id, port: port)
        let complete = try await waitFor(service, id: task.id, seconds: 180) { $0.state == .completed }
        let file = try await service.fileForOpening(task.id)
        try require(digest(file) == digest(source), "completed selected-file SHA-256 mismatch: \(title)")
        try verifyPlayableMedia(file)
        await service.shutdown()
        return complete
    }

    static func completeSingle(root: URL, torrent: URL, source: URL, port: UInt16) async throws {
        phase("\(torrent.lastPathComponent): non-first video download and verification")
        let complete = try await downloadAndClose(root: root, torrent: torrent, source: source, port: port, title: "non-first file")
        guard let attachmentRoot = complete.torrentStorageDirectory else { throw Failure(message: "missing shared storage snapshot") }
        let privatePayload = attachmentRoot.appendingPathComponent("data").appendingPathComponent(complete.selection.torrent!.path)
        for resumeCondition in ["valid", "missing", "corrupt"] {
            phase("\(resumeCondition) resume: modified payload must be rehashed and repaired")
            var corrupted = try Data(contentsOf: privatePayload)
            corrupted[0] ^= 0xff
            try corrupted.write(to: privatePayload)
            let resumeFile = attachmentRoot.appendingPathComponent("resume.dat")
            if resumeCondition == "missing" { try FileManager.default.removeItem(at: resumeFile) }
            if resumeCondition == "corrupt" { try Data("corrupt resume".utf8).write(to: resumeFile) }
            _ = try await downloadAndClose(root: root, torrent: torrent, source: source, port: port, title: "rehash repair")
        }
        phase("record deletion preserves output; file deletion preserves other tasks and private pieces")
        let service = try makeService(root: root)
        guard let firstFile = complete.completedFile,
              let second = await service.list().first(where: { $0.id != complete.id }),
              let secondFile = second.completedFile else { throw Failure(message: "missing deletion-isolation fixtures") }
        try await service.deleteRecord(complete.id)
        try require(digest(firstFile) == digest(source), "record deletion removed or changed completed output")
        try await service.deleteFile(second.id)
        let remaining = await service.list()
        try require(remaining.contains(where: { $0.id == second.id }), "file deletion removed its task record")
        try require(!FileManager.default.fileExists(atPath: secondFile.path), "file deletion kept the selected output")
        try require(digest(firstFile) == digest(source) && digest(privatePayload) == digest(source),
                    "file deletion affected another output or shared private data")
        await service.shutdown()
    }

    static func diskFull(root: URL, torrent: URL, port: UInt16, mount: URL) async throws {
        let isolated = mount.appendingPathComponent("w112-regression-\(UUID().uuidString)", isDirectory: true)
        phase("real disk full ENOSPC")
        let temp = isolated.appendingPathComponent("private", isDirectory: true)
        let output = isolated.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: isolated) }
        let service = try makeService(root: root, store: root.appendingPathComponent("disk-full-tasks-v1.json"), output: output, temporary: temp)
        let task = try await makeTask(service, torrent: torrent, port: port, title: "real ENOSPC")
        _ = try await waitFor(service, id: task.id) { $0.state == .downloading }
        try await connect(service, id: task.id, port: port)
        let failed = try await waitFor(service, id: task.id, seconds: 60) { $0.state == .failed }
        try require(failed.failure == DownloadFailure.diskFull, "native ENOSPC mapped to \(failed.failure?.rawValue ?? "nil")")
        await service.shutdown()
    }

    static func runChild(_ mode: String, root: URL, torrent: URL, port: UInt16) async throws {
        let service = try makeService(root: root)
        if mode == "--checkpoint" || mode == "--graceful" {
            let task = try await makeTask(service, torrent: torrent, port: port, title: "process restart")
            try Data(task.id.uuidString.utf8).write(to: root.appendingPathComponent("task.id"))
            _ = try await waitFor(service, id: task.id) { $0.state == .downloading }
            try await connect(service, id: task.id, port: port)
            _ = try await waitFor(service, id: task.id) { $0.bytes >= 512 * 1024 }
            if mode == "--graceful" { await service.shutdown() }
            try Data("checkpoint".utf8).write(to: root.appendingPathComponent("checkpoint"))
            if mode == "--graceful" { return }
            while true { try await Task.sleep(for: .seconds(30)) }
        }
        let taskID = UUID(uuidString: try String(contentsOf: root.appendingPathComponent("task.id"), encoding: .utf8))!
        try await service.resume(taskID)
        try await connect(service, id: taskID, port: port)
        let completed = try await waitFor(service, id: taskID, seconds: 240) { $0.state == .completed }
        guard let file = completed.completedFile else { throw Failure(message: "resumed task omitted completed output") }
        try digest(file).write(to: root.appendingPathComponent("result.sha256"), atomically: true, encoding: .utf8)
        await service.shutdown()
    }

    static func main() async throws {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        if args.count >= 5, ["--checkpoint", "--graceful", "--reopen"].contains(args[1]) {
            let root = URL(fileURLWithPath: args[2], isDirectory: true)
            try await runChild(args[1], root: root, torrent: URL(fileURLWithPath: args[3]), port: UInt16(args[4])!)
            return
        }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let v1 = root.appendingPathComponent("fixture-v1.torrent")
        let v2 = root.appendingPathComponent("fixture-v2.torrent")
        let hybrid = root.appendingPathComponent("fixture-hybrid.torrent")
        let seedDir = root.appendingPathComponent("seed", isDirectory: true)
        let source = seedDir.appendingPathComponent("payload.mkv")
        let expected = try digest(source)
        try require(TorrentSession.coreVersion == "2.1.2", "wrong native libtorrent version")

        let selector = ProcessInfo.processInfo.environment["W112_PHASE"]
        if selector == "no-peers" || selector == nil {
            try await boundedNoPeerImport(root: root.appendingPathComponent("no-peer", isDirectory: true))
            if selector == "no-peers" { return }
        }
        if selector == "v1-local" || selector == nil {
            let (localSeed, localPort) = try await startSeed(torrent: v1, directory: seedDir)
            phase("v1 local torrent fixture")
            try await localSingle(root: root.appendingPathComponent("v1-local", isDirectory: true), torrent: v1, source: source, port: localPort)
            await localSeed.close()
            if selector == "v1-local" { return }
        }
        let (seedV1, portV1) = try await startSeed(torrent: v1, directory: seedDir)
        if selector == "cancel-import" || selector == nil {
            try await cancelPendingImport(root: root.appendingPathComponent("cancel-import", isDirectory: true), torrent: v1, port: portV1)
            if selector == "cancel-import" { await seedV1.close(); return }
        }
        if selector == "symlink" || selector == nil {
            try await symlinkIsolation(root: root.appendingPathComponent("symlink-isolation", isDirectory: true), torrent: v1, port: portV1)
            if selector == "symlink" { await seedV1.close(); return }
        }
        if selector == "restart" || selector == nil {
            try await interruptedRestart(root: root.appendingPathComponent("process-restart", isDirectory: true), torrent: v1, source: source, port: portV1)
            if selector == "restart" { await seedV1.close(); return }
        }
        if selector == "normal-restart" || selector == nil {
            try await interruptedRestart(root: root.appendingPathComponent("normal-restart", isDirectory: true), torrent: v1, source: source, port: portV1, graceful: true)
            if selector == "normal-restart" { await seedV1.close(); return }
        }
        if args.contains("--disk-full"), let mountPath = ProcessInfo.processInfo.environment["W112_DISK_FULL_DIR"], selector == "disk-full" || selector == nil {
            try await diskFull(root: root.appendingPathComponent("disk-full", isDirectory: true), torrent: v1, port: portV1, mount: URL(fileURLWithPath: mountPath, isDirectory: true))
        } else if selector == "disk-full" { throw Failure(message: "disk-full scenario requires runner --disk-full and W112_DISK_FULL_DIR") }
        await seedV1.close()
        if selector == "disk-full" { return }
        let (seedV2, portV2) = try await startSeed(torrent: v2, directory: seedDir)
        if selector == "sharing-v2" || selector == nil {
            phase("v2 shared transfer pause and independent cancel")
            try await sharedPauseCancel(root: root.appendingPathComponent("shared-v2", isDirectory: true), torrent: v2, source: source, port: portV2)
        }
        if selector == "v2-recheck" || selector == nil {
            try await completeSingle(root: root.appendingPathComponent("v2-recheck", isDirectory: true), torrent: v2, source: source, port: portV2)
        }
        await seedV2.close()
        if selector == "sharing-v2" || selector == "v2-recheck" { return }
        if selector == "private-local" || selector == nil {
            phase("private hybrid imports local metadata without public discovery")
            let privateTorrent = root.appendingPathComponent("fixture-private-hybrid.torrent")
            let (privateSeed, privatePort) = try await startSeed(torrent: privateTorrent, directory: seedDir)
            try await localSingle(root: root.appendingPathComponent("private-local", isDirectory: true), torrent: privateTorrent, source: source, port: privatePort)
            await privateSeed.close()
            if selector == "private-local" { return }
        }
        let (seedHybrid, portHybrid) = try await startSeed(torrent: hybrid, directory: seedDir)
        if selector == "hybrid" || selector == nil {
            try await completeSingle(root: root.appendingPathComponent("hybrid", isDirectory: true), torrent: hybrid, source: source, port: portHybrid)
        }
        await seedHybrid.close()
        if let selector, !["v1-local", "cancel-import", "no-peers", "symlink", "restart", "normal-restart", "disk-full", "sharing-v2", "v2-recheck", "private-local", "hybrid"].contains(selector) {
            throw Failure(message: "unknown W112_PHASE: \(selector)")
        }
        guard selector == nil else { return }
        try require(expected == digest(source), "seed fixture digest changed")
        try require(TorrentSelection(infoHashes: ["v1:" + String(repeating: "a", count: 40)], fileIndex: 0, path: "../escape", size: 1) == nil,
                    "unsafe torrent path was accepted")
        print("PASS W11.2: non-first v1/v2/hybrid selection, SHA-256 byte equality, process-kill resume, shared cancel lifetime, private data and corrupt resume")
    }
}
