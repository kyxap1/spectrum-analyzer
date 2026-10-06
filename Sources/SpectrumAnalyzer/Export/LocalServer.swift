import Foundation
import Network
import Synchronization

/// KTD11: HTTP/1.1 on the loopback interface, off until started. `GET /levels`
/// answers the shared JSON bytes; every connection closes after one response.
/// The listener binds to 127.0.0.1 and any connection from another address is
/// closed as a second layer. Commands for the agent loop extend `respond`.
final class LocalServer: Sendable {
    static let defaultPort: UInt16 = 47_800
    private static let maxRequestBytes = 8_192
    private static let idleTimeout: DispatchTimeInterval = .seconds(5)

    private let body = Mutex<Data>(Data())
    private let listener = Mutex<NWListener?>(nil)
    private let queue = DispatchQueue(label: "pro.kyxap.SpectrumAnalyzer.export")
    /// Called on the server queue when a running listener fails.
    let onFailure = Mutex<(@Sendable (String) -> Void)?>(nil)

    /// Replaces the bytes `GET /levels` answers with.
    func update(_ json: Data) {
        body.withLock { $0 = json }
    }

    /// Starts listening on `port` (0 picks a free one) and returns the port
    /// bound. Throws when the port is taken.
    func start(port: UInt16) async throws -> UInt16 {
        stop()
        let newListener = try NWListener(using: Self.makeParameters(port: port))
        newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let result = Mutex<CheckedContinuation<UInt16, any Error>?>(nil)
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            result.withLock { $0 = continuation }
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    result.withLock { $0?.resume(returning: newListener.port?.rawValue ?? port); $0 = nil }
                case .failed(let error):
                    let pending = result.withLock { continuation in
                        defer { continuation = nil }
                        return continuation
                    }
                    if let pending {
                        pending.resume(throwing: error)
                    } else {
                        self?.onFailure.withLock { $0 }?(error.localizedDescription)
                    }
                case .cancelled:
                    result.withLock { $0?.resume(throwing: CancellationError()); $0 = nil }
                default: break
                }
            }
            listener.withLock { $0 = newListener }
            newListener.start(queue: queue)
        }
        return bound
    }

    func stop() {
        listener.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    static func makeParameters(port: UInt16) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        return parameters
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }

    /// Refuses a Host header naming anything but loopback, so a web page
    /// reaching the port through DNS rebinding gets nothing. A request with
    /// no Host header (HTTP/1.0) passes.
    static func hostAllowed(headerLines: [String]) -> Bool {
        guard let line = headerLines.first(where: { $0.lowercased().hasPrefix("host:") }) else { return true }
        let value = line.dropFirst("host:".count).trimmingCharacters(in: .whitespaces).lowercased()
        let host = value.hasPrefix("[") ? String(value.prefix(while: { $0 != "]" }).dropFirst()) : String(value.split(separator: ":").first ?? "")
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    /// The full HTTP response for a request line such as `GET /levels HTTP/1.1`.
    static func respond(requestLine: String, body: Data) -> Data {
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            return response(status: "400 Bad Request", text: "bad request")
        }
        guard parts[0] == "GET" else {
            return response(status: "405 Method Not Allowed", text: "method not allowed", extra: ["Allow: GET"])
        }
        let path = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard path == "/levels" else { return response(status: "404 Not Found", text: "not found") }
        return response(status: "200 OK", contentType: "application/json", data: body, extra: ["Cache-Control: no-store"])
    }

    private static func response(status: String, text: String, extra: [String] = []) -> Data {
        response(status: status, contentType: "text/plain", data: Data(text.utf8), extra: extra)
    }

    private static func response(status: String, contentType: String, data: Data, extra: [String]) -> Data {
        let head = (["HTTP/1.1 \(status)", "Content-Type: \(contentType)", "Content-Length: \(data.count)", "Connection: close"] + extra)
            .joined(separator: "\r\n") + "\r\n\r\n"
        return Data(head.utf8) + data
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        // A client that connects and never finishes its request line is dropped.
        queue.asyncAfter(deadline: .now() + Self.idleTimeout) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    /// Reads until the headers are complete, then answers and closes.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            if let end = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") {
                let lines = text[..<end.lowerBound].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                let bytes = Self.hostAllowed(headerLines: Array(lines.dropFirst()))
                    ? Self.respond(requestLine: lines.first ?? "", body: self.body.withLock { $0 })
                    : Self.response(status: "403 Forbidden", text: "forbidden")
                connection.send(content: bytes, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            } else if error != nil || isComplete || buffer.count >= Self.maxRequestBytes {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }
}
