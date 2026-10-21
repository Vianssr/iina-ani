import CryptoKit
import Foundation

/// Streams HTTP response chunks to disk without retaining the resource in memory.
enum DirectDownloader {
    fileprivate struct ResumeMetadata: Codable {
        let resourceKey: String
        let etag: String
        let total: Int64
    }

    fileprivate enum TransferError: Error {
        case restart(String)
        case failure(DownloadFailure)
    }

    static func download(
        resource: DownloadResource,
        destination: URL,
        resume: Bool = true,
        byteRange: DownloadByteRange? = nil,
        progress: @escaping DownloadProgressHandler
    ) async throws -> DownloadTransferResult {
        let context = resource.context
        guard allowed(resource.url, context: context), resource.url.user == nil,
              resource.url.password == nil,
              !context.headers.keys.contains(where: forbiddenHeader) else {
            throw DownloadFailure.authorization
        }
        if let byteRange {
            guard byteRange.offset >= 0, byteRange.length > 0,
                  byteRange.offset <= Int64.max - byteRange.length else { throw DownloadFailure.invalidResponse }
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw DownloadFailure.directoryNotWritable
                }
            }
        } catch { throw DownloadFailure.classify(error) }

        let sidecar = destination.appendingPathExtension("download-meta")
        let resourceKey = SHA256.hash(data: Data(resource.url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var saved: ResumeMetadata?
        var offset: Int64 = 0
        if resume && byteRange == nil,
           let data = try? Data(contentsOf: sidecar),
           let metadata = try? JSONDecoder().decode(ResumeMetadata.self, from: data),
           metadata.resourceKey == resourceKey, strongETag(metadata.etag),
           let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attrs[.size] as? NSNumber,
           size.int64Value > 0, size.int64Value < metadata.total {
            saved = metadata
            offset = size.int64Value
        }
        var restartReason: String?
        if resume && byteRange == nil && offset == 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attrs[.size] as? NSNumber, size.int64Value > 0 {
            restartReason = String(localized: "No matching strong validator; restarting from the beginning")
        }

        for attempt in 0..<2 {
            do {
                let delegate = StreamDelegate(resource: resource, destination: destination, sidecar: sidecar,
                                              resourceKey: resourceKey, offset: attempt == 0 ? offset : 0,
                                              metadata: attempt == 0 ? saved : nil, byteRange: byteRange,
                                              progress: progress, restartReason: restartReason)
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let result = try await delegate.run(session: session)
                try? FileManager.default.removeItem(at: sidecar)
                return result
            } catch TransferError.restart(let reason) where byteRange == nil && attempt == 0 {
                try? FileManager.default.removeItem(at: sidecar)
                do {
                    let handle = try FileHandle(forWritingTo: destination)
                    try handle.truncate(atOffset: 0)
                    try handle.close()
                } catch { throw DownloadFailure.classify(error) }
                saved = nil
                offset = 0
                restartReason = reason
                progress(DownloadTransferProgress(bytes: 0, totalBytes: nil, restartReason: reason))
            } catch let error as TransferError {
                switch error {
                case .failure(let failure): throw failure
                case .restart: throw DownloadFailure.resourceChanged
                }
            } catch {
                if error is CancellationError { throw error }
                throw DownloadFailure.classify(error)
            }
        }
        throw DownloadFailure.resourceChanged
    }

    fileprivate static func allowed(_ url: URL, context: DownloadRequestContext) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if let hosts = context.allowedHosts, !hosts.contains(where: { $0.lowercased() == host }) { return false }
        if scheme == "https" { return true }
        let loopback = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return scheme == "http" && context.allowLoopbackHTTP &&
            (loopback == "localhost" || loopback == "::1" || loopback.hasPrefix("127."))
    }

    fileprivate static func forbiddenHeader(_ key: String) -> Bool {
        ["cookie", "authorization", "proxy-authorization"].contains(key.lowercased())
    }

    fileprivate static func strongETag(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !value.lowercased().hasPrefix("w/") && value.first == "\"" && value.last == "\""
    }

    fileprivate static func metadata(resourceKey: String, etag: String, total: Int64) throws -> Data {
        try JSONEncoder().encode(ResumeMetadata(resourceKey: resourceKey, etag: etag, total: total))
    }
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let resource: DownloadResource
    private let destination: URL
    private let sidecar: URL
    private let resourceKey: String
    private let offset: Int64
    private let metadata: DirectDownloader.ResumeMetadata?
    private let byteRange: DownloadByteRange?
    private let progress: DownloadProgressHandler
    private let restartReason: String?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadTransferResult, Error>?
    private var dataTask: URLSessionDataTask?
    private var handle: FileHandle?
    private var responseError: DirectDownloader.TransferError?
    private var expectedBodyBytes: Int64?
    private var receivedBytes: Int64 = 0
    private var responseURL: URL?
    private var finished = false
    private var cancelled = false
    private var lastProgressAt = Date.distantPast

    init(resource: DownloadResource, destination: URL, sidecar: URL, resourceKey: String,
         offset: Int64, metadata: DirectDownloader.ResumeMetadata?, byteRange: DownloadByteRange?,
         progress: @escaping DownloadProgressHandler, restartReason: String?) {
        self.resource = resource
        self.destination = destination
        self.sidecar = sidecar
        self.resourceKey = resourceKey
        self.offset = offset
        self.metadata = metadata
        self.byteRange = byteRange
        self.progress = progress
        self.restartReason = restartReason
    }

    func run(session: URLSession) async throws -> DownloadTransferResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                guard !Task.isCancelled, let request = request(for: resource.url) else {
                    finish(.failure(Task.isCancelled ? CancellationError() : DownloadFailure.authorization))
                    return
                }
                let task = session.dataTask(with: request)
                lock.lock()
                dataTask = task
                let cancelled = self.cancelled
                lock.unlock()
                if cancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.dataTask
            self.lock.unlock()
            task?.cancel()
        }
    }

    private func request(for url: URL) -> URLRequest? {
        guard DirectDownloader.allowed(url, context: resource.context), url.user == nil, url.password == nil else { return nil }
        var request = URLRequest(url: url)
        let host = url.host?.lowercased() ?? ""
        let authorizedHost = resource.context.credentialHosts.contains { $0.lowercased() == host }
        for (name, value) in resource.context.headers where !DirectDownloader.forbiddenHeader(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if authorizedHost {
            let path = url.path.isEmpty ? "/" : url.path
            let cookies = resource.context.cookies.filter { cookie in
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
                let pathOK = path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
                return (host == domain || host.hasSuffix("." + domain)) && pathOK &&
                    (!cookie.isSecure || url.scheme?.lowercased() == "https") &&
                    (cookie.expiresDate.map { $0 > Date() } ?? true)
            }
            if !cookies.isEmpty {
                request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            }
        }
        if let byteRange {
            request.setValue("bytes=\(byteRange.offset)-\(byteRange.offset + byteRange.length - 1)", forHTTPHeaderField: "Range")
        } else if offset > 0, let metadata {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(metadata.etag, forHTTPHeaderField: "If-Range")
        }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, let redirected = self.request(for: url) else { completionHandler(nil); return }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              DirectDownloader.allowed(url, context: resource.context), url.user == nil, url.password == nil else {
            responseError = .failure(DownloadFailure.authorization)
            completionHandler(.cancel)
            return
        }
        responseURL = url
        let headers = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let key = key as? String else { return nil }
            return (key.lowercased(), String(describing: value))
        })
        let etag = headers["etag"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentLength = Int64(headers["content-length"] ?? "")
        var bodyLength = contentLength
        if let range = byteRange {
            guard http.statusCode == 206,
                  Self.contentRange(headers["content-range"], start: range.offset,
                                    end: range.offset + range.length - 1, total: nil),
                  contentLength == nil || contentLength == range.length else {
                responseError = .failure(DownloadFailure.invalidResponse)
                completionHandler(.cancel)
                return
            }
            bodyLength = range.length
        } else if offset > 0, let metadata {
            guard http.statusCode == 206 else {
                responseError = .restart(String(localized: "Server ignored resume range; restarting from the beginning"))
                completionHandler(.cancel)
                return
            }
            guard etag == metadata.etag,
                  Self.contentRange(headers["content-range"], start: offset, end: nil, total: metadata.total) else {
                responseError = .restart(String(localized: "Resource validator or range changed; restarting from the beginning"))
                completionHandler(.cancel)
                return
            }
            bodyLength = metadata.total - offset
        } else if http.statusCode == 416 {
            responseError = .restart(String(localized: "Server rejected resume range; restarting from the beginning"))
            completionHandler(.cancel)
            return
        } else if http.statusCode != 200 {
            responseError = .failure(http.statusCode == 401 || http.statusCode == 403 ? .authorization : .mediaUnavailable)
            completionHandler(.cancel)
            return
        }
        do {
            let file = try FileHandle(forWritingTo: destination)
            if offset > 0 && byteRange == nil { try file.seekToEnd() }
            else { try file.truncate(atOffset: 0) }
            handle = file
            expectedBodyBytes = bodyLength
            if byteRange == nil, offset == 0, let etag, DirectDownloader.strongETag(etag),
               let contentLength, contentLength > 0 {
                let data = try DirectDownloader.metadata(resourceKey: resourceKey, etag: etag, total: contentLength)
                try data.write(to: sidecar, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            }
            completionHandler(.allow)
            progress(DownloadTransferProgress(bytes: offset, totalBytes: bodyLength.map { offset + $0 }, restartReason: restartReason))
        } catch {
            responseError = .failure(DownloadFailure.classify(error))
            completionHandler(.cancel)
        }
    }

    private static func contentRange(_ value: String?, start: Int64, end: Int64?, total: Int64?) -> Bool {
        guard let value, value.lowercased().hasPrefix("bytes ") else { return false }
        let pair = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard pair.count == 2, let receivedTotal = Int64(pair[1]), receivedTotal > 0 else { return false }
        let bounds = pair[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let receivedStart = Int64(bounds[0]), let receivedEnd = Int64(bounds[1]) else { return false }
        return receivedStart == start && (end == nil ? receivedEnd == receivedTotal - 1 : receivedEnd == end!) &&
            (total == nil || receivedTotal == total!) && receivedEnd >= receivedStart && receivedEnd < receivedTotal
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard let handle else { throw DownloadFailure.invalidResponse }
            try handle.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastProgressAt) >= 0.25 {
                lastProgressAt = now
                progress(DownloadTransferProgress(bytes: offset + receivedBytes,
                                                  totalBytes: expectedBodyBytes.map { offset + $0 }))
            }
        } catch {
            responseError = .failure(DownloadFailure.classify(error))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let handle {
            do {
                try handle.synchronize()
                try handle.close()
            } catch { responseError = .failure(DownloadFailure.classify(error)) }
            self.handle = nil
        }
        if let responseError { finish(.failure(responseError)); return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else { finish(.failure(DownloadFailure.classify(error))) }
            return
        }
        if let expectedBodyBytes, receivedBytes != expectedBodyBytes {
            finish(.failure(DownloadFailure.network))
            return
        }
        guard let responseURL else { finish(.failure(DownloadFailure.invalidResponse)); return }
        progress(DownloadTransferProgress(bytes: offset + receivedBytes, totalBytes: expectedBodyBytes.map { offset + $0 }))
        finish(.success(DownloadTransferResult(file: destination, responseURL: responseURL)))
    }

    private func finish(_ result: Result<DownloadTransferResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
