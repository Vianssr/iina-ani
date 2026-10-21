import Darwin
import Foundation

/// The UI gate stays closed until minimum-system and distribution-sandbox qualification.
/// Execution is deliberately separate from installation, layout loading and window resizing.
struct WorkspaceLayoutScriptRunner: Sendable {
    static let externalImportEnabled = false
    static let maximumSourceBytes = 131_072
    static let maximumInputBytes = 262_144
    static let maximumOutputBytes = 1_048_576
    private let helperURL: URL
    private let validator: WorkspaceValidator

    init(
        helperURL: URL? = nil, registry: any WorkspaceComponentRegistry = WorkspaceRegistry.builtins
    ) {
        self.helperURL =
            helperURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LayoutScriptHelper")
        validator = WorkspaceValidator(registry: registry)
    }

    func generate(source: String, configuration: [String: WorkspaceJSONValue] = [:]) async throws
        -> WorkspaceLayout
    {
        guard source.utf8.count <= Self.maximumSourceBytes else {
            throw WorkspaceLayoutScriptError.inputLimit
        }
        // No current layout, session state, account, task or preference data enters this context.
        let request = Request(
            source: source,
            context: Context(
                schemaVersion: WorkspaceLayout.currentSchemaVersion,
                components: validator.registry.descriptors.map(Component.init),
                configuration: configuration))
        let data = try JSONEncoder().encode(request)
        guard data.count <= Self.maximumInputBytes else {
            throw WorkspaceLayoutScriptError.inputLimit
        }
        let cancellation = ScriptCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            let output = try Self.execute(
                helperURL: helperURL, input: data, cancellation: cancellation)
            do { return try WorkspaceLayoutCodec.decode(output, validator: validator) } catch let
                error as DecodingError
            {
                throw WorkspaceLayoutScriptError.invalidOutput(Self.describe(error))
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    private struct Request: Encodable {
        let source: String
        let context: Context
    }
    private struct Context: Encodable {
        let schemaVersion: Int
        let componentContractVersion = 1
        let components: [Component]
        let configuration: [String: WorkspaceJSONValue]
    }
    private struct Component: Encodable {
        let id: String
        let contractVersion: Int
        let defaultSize: WorkspaceSize
        let minimumSize: WorkspaceSize
        let allowedContainers: [String]
        let allowsMultipleInstances: Bool
        let parameterKeys: [String]
        init(_ descriptor: WorkspaceComponentDescriptor) {
            id = descriptor.id.rawValue
            contractVersion = descriptor.contractVersion
            defaultSize = descriptor.defaultSize
            minimumSize = descriptor.minimumSize
            allowedContainers = descriptor.allowedContainers.map(\.rawValue).sorted()
            allowsMultipleInstances = descriptor.allowsMultipleInstances
            parameterKeys = descriptor.parameterKeys.sorted()
        }
    }

    private static func execute(helperURL: URL, input: Data, cancellation: ScriptCancellation)
        throws -> Data
    {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = helperURL
        process.arguments = []
        process.environment = [:]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let started = DispatchTime.now().uptimeNanoseconds
        try process.run()
        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        let outputFD = stdout.fileHandleForReading.fileDescriptor
        let errorFD = stderr.fileHandleForReading.fileDescriptor
        var inputClosed = false
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            if !inputClosed { try? stdin.fileHandleForWriting.close() }
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        for fd in [inputFD, outputFD, errorFD] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                throw WorkspaceLayoutScriptError.transport
            }
        }
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) != -1 else {
            throw WorkspaceLayoutScriptError.transport
        }
        var sent = 0
        var output = Data()
        var errors = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain(_ fd: Int32, into data: inout Data, limit: Int) throws {
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= limit else {
                        throw WorkspaceLayoutScriptError.outputLimit
                    }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 || errno == EAGAIN {
                    return
                } else if errno != EINTR {
                    throw WorkspaceLayoutScriptError.transport
                }
            }
        }
        repeat {
            if cancellation.isCancelled { throw CancellationError() }
            guard DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000 else {
                throw WorkspaceLayoutScriptError.timeLimit
            }
            if process.isRunning {
                var usage = rusage_info_v2()
                let status = withUnsafeMutablePointer(to: &usage) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V2, $0)
                    }
                }
                if status == 0 {
                    guard usage.ri_phys_footprint <= 134_217_728 else {
                        throw WorkspaceLayoutScriptError.resourceLimit
                    }
                } else if process.isRunning && errno != ESRCH {
                    throw WorkspaceLayoutScriptError.transport
                }
            }
            if !inputClosed {
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(inputFD, bytes.baseAddress!.advanced(by: sent), input.count - sent)
                }
                if count > 0 {
                    sent += count
                } else if count < 0 && errno != EAGAIN && errno != EINTR && errno != EPIPE {
                    throw WorkspaceLayoutScriptError.transport
                }
                if sent == input.count || (count < 0 && errno == EPIPE) {
                    try stdin.fileHandleForWriting.close()
                    inputClosed = true
                }
            }
            try drain(outputFD, into: &output, limit: maximumOutputBytes)
            try drain(errorFD, into: &errors, limit: 8192)
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.005)
        } while true
        process.waitUntilExit()
        try drain(outputFD, into: &output, limit: maximumOutputBytes)
        try drain(errorFD, into: &errors, limit: 8192)
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            if process.terminationReason == .exit {
                if process.terminationStatus == 4 { throw WorkspaceLayoutScriptError.resourceLimit }
                if process.terminationStatus == 6 { throw WorkspaceLayoutScriptError.timeLimit }
                if process.terminationStatus == 7 { throw WorkspaceLayoutScriptError.outputLimit }
            }
            let detail = errors.isEmpty
                ? "Helper terminated (\(process.terminationReason), \(process.terminationStatus))"
                : String(decoding: errors, as: UTF8.self)
            throw WorkspaceLayoutScriptError.execution(detail)
        }
        return output
    }

    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .dataCorrupted(let value), .typeMismatch(_, let value), .valueNotFound(_, let value):
            context = value
        case .keyNotFound(let key, let value):
            return
                "layout.\((value.codingPath + [key]).map(\.stringValue).joined(separator: ".")): missing field"
        @unknown default: return "Invalid layout JSON"
        }
        return
            "layout.\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
    }
}

private final class ScriptCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum WorkspaceLayoutScriptError: Error, LocalizedError {
    case inputLimit, outputLimit, timeLimit, resourceLimit, transport
    case execution(String)
    case invalidOutput(String)
    var errorDescription: String? {
        switch self {
        case .inputLimit: String(localized: "Script input exceeds the permitted size.")
        case .outputLimit: String(localized: "Script output exceeds the permitted size.")
        case .timeLimit: String(localized: "Script exceeded the two-second deadline and was terminated.")
        case .resourceLimit: String(localized: "Script exceeded its memory or execution limit and was terminated.")
        case .transport: String(localized: "Could not communicate with the restricted script helper.")
        case .execution(let message): String(localized: "Layout script: \(message)")
        case .invalidOutput(let message): message
        }
    }
}
