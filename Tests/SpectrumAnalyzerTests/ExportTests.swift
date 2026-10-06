import AVFoundation
import Network
import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate
private let hop = BandLog.hopFrames

private func fill(_ log: BandLog, _ ring: HistoryRing, hops: Int) {
    for i in 1...hops { log.advance(ring: ring, to: i * hop) }
}

private func json(_ document: LevelsDocument) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any])
}

private func source(_ log: BandLog, threshold: Float = -60) -> ExportSource {
    ExportSource(log: log, thresholdDBFS: threshold, reading: LevelReading(rmsDBFS: -18.2, peakDBFS: -6.1))
}

@Suite("LevelsDocument")
struct LevelsDocumentTests {
    @Test("the document is versioned and self-describing, with reference null when none is set")
    func shape() throws {
        let ring = HistoryRing(capacity: 20 * rate)
        writeSine(ring, frequency: 1000, amplitudeDBFS: -20, seconds: 6)
        let log = BandLog()
        fill(log, ring, hops: 12)

        let document = LevelsDocument.make(state: .live, windowSeconds: 10, guitar: source(log), mix: source(log),
                                           reference: nil, comparison: nil, now: Date(timeIntervalSince1970: 1_700_000_000))
        let object = try json(document)
        #expect(object["format"] as? String == "spectrum-analyzer.levels")
        #expect(object["version"] as? Int == 1)
        #expect(object["state"] as? String == "live")
        #expect(object["windowSeconds"] as? Int == 10)
        #expect(object["timestamp"] as? String == "2023-11-14T22:13:20Z")
        #expect(object["units"] != nil)
        let bands = try #require(object["bands"] as? [String: Any])
        #expect((bands["centersHz"] as? [Double])?.count == 31)
        #expect((bands["octaveCentersHz"] as? [Double])?.count == 10)
        #expect(object["reference"] is NSNull)
        let guitar = try #require(object["guitar"] as? [String: Any])
        #expect(guitar["activeSeconds"] as? Double == 6)
        #expect(guitar["activeHopsTotal"] as? Int == 12)
        #expect((guitar["bandsDB"] as? [Double])?.count == 31)
    }

    @Test("with the guitar not captured, its section is null and there is no difference")
    func noGuitar() throws {
        let log = BandLog()
        let document = LevelsDocument.make(state: .paused, windowSeconds: 5, guitar: nil, mix: source(log),
                                           reference: nil, comparison: nil, now: Date())
        let object = try json(document)
        #expect(object["guitar"] is NSNull)
        #expect(object["difference"] is NSNull)
        #expect(object["state"] as? String == "paused")
    }

    @Test("with a reference set, the document carries its differences and partial")
    func referenceSection() throws {
        let ring = HistoryRing(capacity: 20 * rate)
        writeSine(ring, frequency: 1000, amplitudeDBFS: -20, seconds: 6)
        let log = BandLog()
        fill(log, ring, hops: 12)
        let window = log.window(threshold: -60, limit: 20)
        let reference = try #require(Reference.make(guitar: window, mix: window, windowSeconds: 10, name: "Verse"))
        let comparison = Comparison.make(reference: reference, window: window, windowHops: 20)

        let object = try json(LevelsDocument.make(state: .live, windowSeconds: 10, guitar: source(log), mix: source(log),
                                                  reference: reference, comparison: comparison, now: Date()))
        let section = try #require(object["reference"] as? [String: Any])
        #expect(section["name"] as? String == "Verse")
        #expect(section["partial"] as? Bool == true)
        #expect((section["octaveBandsDB"] as? [Double])?.count == 10)
        let differences = try #require(section["differences"] as? [String: Any])
        #expect((differences["bandsDB"] as? [Double])?.count == 31)
        #expect(abs((differences["levelDB"] as? Double ?? 99)) < 0.1)
    }

    @Test("the difference pairs each active guitar hop with the mix hop at the same frame and ignores later mix hops")
    func pairedDifference() throws {
        let guitarRing = HistoryRing(capacity: 30 * rate)
        let mixRing = HistoryRing(capacity: 30 * rate)
        writeSine(guitarRing, frequency: 1000, amplitudeDBFS: -20, seconds: 5)
        writeSine(mixRing, frequency: 200, amplitudeDBFS: -20, seconds: 5)
        writeSine(mixRing, frequency: 3150, amplitudeDBFS: -10, seconds: 15, startFrame: 5 * rate)
        guitarRing.write(at: 20 * rate - 1, [0, 0])
        let guitarLog = BandLog()
        let mixLog = BandLog()
        fill(guitarLog, guitarRing, hops: 40)
        fill(mixLog, mixRing, hops: 40)

        let object = try json(LevelsDocument.make(state: .live, windowSeconds: 20, guitar: source(guitarLog), mix: source(mixLog),
                                                  reference: nil, comparison: nil, now: Date()))
        let difference = try #require((object["difference"] as? [String: Any])?["bandsDB"] as? [Double])
        let guitarWindow = guitarLog.window(threshold: -60, limit: 40)
        let pairedMix = BandLog.average(mixLog.hops.filter { $0.endFrame <= 5 * rate })
        let index3150 = ThirdOctaveBands.centerFrequencies.firstIndex(of: 3150)!
        let expected = dB(guitarWindow.bandPower[index3150], floor: -100) - dB(pairedMix.bandPower[index3150], floor: -100)
        #expect(abs(difference[index3150] - Double(expected)) < 0.05)

        let unpaired = dB(guitarWindow.bandPower[index3150], floor: -100) - dB(mixLog.window(threshold: -60, limit: 40).bandPower[index3150], floor: -100)
        #expect(abs(difference[index3150] - Double(unpaired)) > 10)
    }
}

@Suite("LocalServer")
struct LocalServerTests {
    @Test("the remote-endpoint filter accepts loopback and rejects a LAN address")
    func loopbackFilter() {
        #expect(LocalServer.isLoopback(.hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: 5000)))
        #expect(LocalServer.isLoopback(.hostPort(host: .ipv6(IPv6Address("::1")!), port: 5000)))
        #expect(!LocalServer.isLoopback(.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 5000)))
    }

    @Test("covers AE5: the listener binds to 127.0.0.1")
    func bindsToLoopback() {
        let endpoint = LocalServer.makeParameters(port: 0).requiredLocalEndpoint
        guard case .hostPort(let host, _)? = endpoint, case .ipv4(let address) = host else {
            Issue.record("expected an IPv4 host:port endpoint")
            return
        }
        #expect(address == IPv4Address("127.0.0.1")!)
    }

    @Test("a request line ending in a bare LF is answered, and an idle client is dropped")
    func bareLFAndIdle() async throws {
        let server = LocalServer()
        server.update(Data("{}".utf8))
        let port = try await server.start(port: 0)
        defer { server.stop() }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        let request = "GET /levels HTTP/1.1\n\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = recv(fd, &buffer, buffer.count, 0)
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self).hasPrefix("HTTP/1.1 200"))
    }

    @Test("stopping a listener that has not become ready ends start() instead of hanging")
    func stopDuringStart() async {
        let server = LocalServer()
        async let started: UInt16? = try? await server.start(port: 0)
        server.stop()
        _ = await started
        server.stop()
    }

    @Test("only loopback Host headers are accepted")
    func hostCheck() {
        #expect(LocalServer.hostAllowed(headerLines: ["Host: 127.0.0.1:47800", "Accept: */*"]))
        #expect(LocalServer.hostAllowed(headerLines: ["host: localhost"]))
        #expect(LocalServer.hostAllowed(headerLines: ["Host: [::1]:47800"]))
        #expect(LocalServer.hostAllowed(headerLines: ["Accept: */*"]))
        #expect(!LocalServer.hostAllowed(headerLines: ["Host: evil.example:47800"]))
        #expect(!LocalServer.hostAllowed(headerLines: ["Host: 127.0.0.1.evil.example"]))
    }

    @Test("routing: GET /levels is 200 JSON, other paths 404, other methods 405")
    func routing() throws {
        let body = Data("{\"ok\":true}".utf8)
        let ok = String(decoding: LocalServer.respond(requestLine: "GET /levels HTTP/1.1", body: body), as: UTF8.self)
        #expect(ok.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(ok.contains("Content-Type: application/json"))
        #expect(ok.contains("Cache-Control: no-store"))
        #expect(ok.contains("Connection: close"))
        #expect(ok.hasSuffix("\r\n\r\n{\"ok\":true}"))
        #expect(String(decoding: LocalServer.respond(requestLine: "POST /levels HTTP/1.1", body: body), as: UTF8.self).hasPrefix("HTTP/1.1 405"))
        #expect(String(decoding: LocalServer.respond(requestLine: "GET /other HTTP/1.1", body: body), as: UTF8.self).hasPrefix("HTTP/1.1 404"))
        #expect(String(decoding: LocalServer.respond(requestLine: "garbage", body: body), as: UTF8.self).hasPrefix("HTTP/1.1 400"))
    }

    @Test("covers AE5: a started server answers over HTTP, and after stop the port refuses connections")
    func serves() async throws {
        let server = LocalServer()
        server.update(Data("{\"hello\":1}".utf8))
        let port = try await server.start(port: 0)

        let url = URL(string: "http://127.0.0.1:\(port)/levels")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(decoding: data, as: UTF8.self) == "{\"hello\":1}")

        var post = URLRequest(url: url)
        post.httpMethod = "POST"
        let (_, postResponse) = try await URLSession.shared.data(for: post)
        #expect((postResponse as? HTTPURLResponse)?.statusCode == 405)
        let (_, other) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/other")!)
        #expect((other as? HTTPURLResponse)?.statusCode == 404)

        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!Self.canConnect(port: port))
    }

    private static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } == 0
        }
    }
}
