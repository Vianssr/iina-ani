import Cocoa
import Darwin
import Foundation
@testable import IINA_ANI

@MainActor
private final class TestPort {
    var value: Int
    init(_ value: Int) { self.value = value }
}

@main enum HTTPServerLifecycleRegression {
    struct Failure: Error { let message: String }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let (reservedPort, reservation) = try reservePort()
        let port = TestPort(reservedPort)
        let server = HttpServer(
            decoder: VideoDecoder(),
            streaming: TorrentStreamingService(),
            port: { port.value },
            enableDanmaku: { false }
        )

        var bindFailed = false
        do {
            _ = try await server.start()
        } catch {
            bindFailed = true
        }
        try require(bindFailed, "starting on an occupied port must throw")

        Darwin.close(reservation)
        port.value = 0
        async let firstStart = server.start()
        async let concurrentStart = server.start()
        let (firstEndpoint, concurrentEndpoint) = try await (firstStart, concurrentStart)
        try require(firstEndpoint == concurrentEndpoint, "concurrent starts must share the same bound endpoint")
        try require(firstEndpoint.port > 0, "endpoint must report the actual ephemeral port")
        let repeatedEndpoint = try await server.start()
        try require(repeatedEndpoint == firstEndpoint, "repeated start must return the active endpoint")

        let connection = try connect(to: firstEndpoint)
        try await Task.sleep(nanoseconds: 50_000_000)
        async let firstStop: Void = server.stop()
        async let secondStop: Void = server.stop()
        _ = await (firstStop, secondStop)
        var receiveTimeout = timeval()
        receiveTimeout.tv_sec = 2
        let timeoutResult = withUnsafePointer(to: &receiveTimeout) { timeout in
            Darwin.setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        try require(timeoutResult == 0, "could not set bounded client receive timeout")
        var byte: UInt8 = 0
        let received = Darwin.recv(connection, &byte, 1, 0)
        Darwin.close(connection)
        try require(received == 0, "shutdown must close active client connections before returning")
        port.value = firstEndpoint.port
        let restartedEndpoint = try await server.start()
        try require(restartedEndpoint.port == firstEndpoint.port, "shutdown must release the listener before returning")
        await server.stop()
        print("HTTP server lifecycle regression passed")
    }

    private static func reservePort() throws -> (Int, Int32) {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(message: "could not create reservation socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw Failure(message: "could not reserve an ephemeral port")
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &addressLength)
            }
        }
        guard addressResult == 0 else {
            Darwin.close(descriptor)
            throw Failure(message: "could not read reserved port")
        }
        return (Int(UInt16(bigEndian: address.sin_port)), descriptor)
    }

    private static func connect(to endpoint: HTTPServerEndpoint) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(message: "could not create client socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(endpoint.port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw Failure(message: "could not connect to server endpoint")
        }
        return descriptor
    }
}
