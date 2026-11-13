import Foundation
import Network

// All listener and connection state is confined to one serial queue. The proxy
// owns this server, and the server retains connections until their response ends.
final class DidahdLoopbackServer: @unchecked Sendable {
    typealias Handler = @Sendable (String) async throws -> (data: Data, contentType: String)?

    private let queue = DispatchQueue(label: "SourceRuntime.Didahd.loopback")
    private var listener: NWListener?
    private var port: UInt16?
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private var connections: [UUID: DidahdLoopbackConnection] = [:]

    deinit {
        let listener = self.listener
        let clients = Array(connections.values)
        queue.async {
            listener?.cancel()
            for client in clients { client.close() }
        }
    }

    func start(handler: @escaping Handler) async throws -> UInt16 {
        try Task.checkCancellation()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            queue.async { self.start(handler: handler, continuation: continuation) }
        }
        try Task.checkCancellation()
        return port
    }

    private func start(handler: @escaping Handler, continuation: CheckedContinuation<UInt16, Error>) {
        if let port {
            continuation.resume(returning: port)
            return
        }
        waiters.append(continuation)
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            // Binding to the IPv4 loopback address, not just checking the peer,
            // prevents this unauthenticated media endpoint being exposed on LAN.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        self.stop(error: VideoGetError.notFountData)
                        return
                    }
                    self.port = port
                    let waiters = self.waiters
                    self.waiters.removeAll()
                    for waiter in waiters { waiter.resume(returning: port) }
                case .failed(let error):
                    self.stop(error: error)
                case .cancelled:
                    self.stop(error: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                let id = UUID()
                let client = DidahdLoopbackConnection(connection: connection, queue: self.queue,
                                                       handler: handler) { [weak self] in
                    self?.connections.removeValue(forKey: id)
                }
                self.connections[id] = client
                client.start()
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 20) { [weak self, weak listener] in
                guard let self, let listener, self.listener === listener, self.port == nil else { return }
                self.stop(error: VideoGetError.notFountData)
            }
        } catch {
            stop(error: error)
        }
    }

    private func stop(error: Error) {
        let listener = self.listener
        self.listener = nil
        port = nil
        listener?.cancel()
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
        let clients = Array(connections.values)
        connections.removeAll()
        for client in clients { client.close() }
    }
}

private final class DidahdLoopbackConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: DidahdLoopbackServer.Handler
    private let onClose: @Sendable () -> Void
    private var request = Data()
    private var task: Task<Void, Never>?
    private var headerTimeout: DispatchWorkItem?
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue,
         handler: @escaping DidahdLoopbackServer.Handler, onClose: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        headerTimeout = timeout
        queue.asyncAfter(deadline: .now() + 20, execute: timeout)
        connection.start(queue: queue)
        receiveHeader()
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.close(); return }
            if let data { self.request.append(data) }
            guard self.request.count <= 16_384 else { self.sendBadRequest(); return }
            if let end = self.request.range(of: Data([13, 10, 13, 10])) {
                self.headerTimeout?.cancel()
                self.headerTimeout = nil
                guard let header = String(data: self.request[..<end.lowerBound], encoding: .ascii),
                      let path = Self.path(from: header) else { self.sendBadRequest(); return }
                self.request.removeAll(keepingCapacity: false)
                self.respond(to: path)
            } else if complete {
                self.close()
            } else {
                self.receiveHeader()
            }
        }
    }

    private static func path(from header: String) -> String? {
        guard let line = header.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/didahd/"), !parts[1].contains("#") else { return nil }
        // The desktop HTTP handler strips the query before routing, too.
        return String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    private func respond(to path: String) {
        let handler = self.handler
        task = Task { [weak self] in
            do {
                let response = try await handler(path)
                try Task.checkCancellation()
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.task = nil
                    if let response {
                        self.send(data: response.data, contentType: response.contentType)
                    } else {
                        self.sendBadRequest()
                    }
                }
            } catch {
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.task = nil
                    if error is CancellationError { self.close() } else { self.sendBadRequest() }
                }
            }
        }
        monitorDisconnect()
    }

    private func monitorDisconnect() {
        // While fetching media, keep a receive pending so a closed player cancels
        // its upstream request instead of downloading an unwanted segment.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if complete || error != nil || data?.isEmpty == false {
                self.close()
            } else {
                self.monitorDisconnect()
            }
        }
    }

    private func send(data: Data, contentType: String) {
        let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\nContent-Type: \(contentType)\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.close(); return }
            self.connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { [weak self] _ in self?.close() })
        })
    }

    private func sendBadRequest() {
        guard !closed else { return }
        headerTimeout?.cancel()
        headerTimeout = nil
        let header = Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func close() {
        guard !closed else { return }
        closed = true
        headerTimeout?.cancel()
        headerTimeout = nil
        task?.cancel()
        task = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }
}
