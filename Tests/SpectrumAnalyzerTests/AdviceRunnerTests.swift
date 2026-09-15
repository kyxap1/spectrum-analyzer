import AVFoundation
import Testing
@testable import SpectrumAnalyzer

/// Writes an executable shell script at a fresh temporary path and returns
/// its URL; the caller removes the containing directory when done.
private func makeStub(_ script: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("cli")
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private let okJSON = #"{"type":"result","is_error":false,"result":"ok","usage":{"input_tokens":1,"output_tokens":1}}"#

@Suite("AdviceRunner")
struct AdviceRunnerTests {
    @Test("a stub printing valid JSON yields the answer text and parsed usage")
    func stubReturnsAnswerAndUsage() async throws {
        let cli = try makeStub("""
        #!/bin/sh
        cat > /dev/null
        echo '{"type":"result","is_error":false,"result":"Try boosting 2 kHz.","usage":{"input_tokens":1234,"output_tokens":56}}'
        """)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }

        let outcome = await AdviceRunner().run(cliPath: cli.path, model: "sonnet", payload: "payload text")

        guard case .success(let answer, let usage) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(answer == "Try boosting 2 kHz.")
        #expect(usage.inputTokens == 1234)
        #expect(usage.outputTokens == 56)
    }

    @Test("picking Opus passes --model opus along with -p, --tools \"\" and --safe-mode")
    func opusPassesExpectedFlags() async throws {
        let recordURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cli = try makeStub("""
        #!/bin/sh
        cat > /dev/null
        printf '%s\\n' "$@" > "\(recordURL.path)"
        echo '\(okJSON)'
        """)
        defer {
            try? FileManager.default.removeItem(at: cli.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: recordURL)
        }

        _ = await AdviceRunner().run(cliPath: cli.path, model: "opus", payload: "x")

        let args = try String(contentsOf: recordURL, encoding: .utf8)
        #expect(args.contains("-p"))
        #expect(args.contains("--model"))
        #expect(args.contains("opus"))
        #expect(args.contains("--tools"))
        #expect(args.contains("--safe-mode"))
    }

    @Test("a CLI path set to ~/... is expanded to the home directory")
    func tildeIsExpanded() async throws {
        let subdir = "spectrum-analyzer-test-\(UUID().uuidString)"
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(subdir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("cli")
        try "#!/bin/sh\ncat > /dev/null\necho '\(okJSON)'\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let outcome = await AdviceRunner().run(cliPath: "~/\(subdir)/cli", model: "sonnet", payload: "x")

        guard case .success = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
    }

    @Test("the stub receives on stdin exactly the payload built")
    func stdinCarriesExactPayload() async throws {
        let recordURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cli = try makeStub("""
        #!/bin/sh
        cat > "\(recordURL.path)"
        echo '\(okJSON)'
        """)
        defer {
            try? FileManager.default.removeItem(at: cli.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: recordURL)
        }

        let payload = "line one\nline two with \"quotes\" and a\ttab"
        _ = await AdviceRunner().run(cliPath: cli.path, model: "sonnet", payload: payload)

        let received = try String(contentsOf: recordURL, encoding: .utf8)
        #expect(received == payload)
    }

    @Test("a stub exiting with status 1 shows the tail of its stderr")
    func nonZeroExitShowsStderrTail() async throws {
        let cli = try makeStub("""
        #!/bin/sh
        cat > /dev/null
        echo 'boom: something broke' 1>&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }

        let outcome = await AdviceRunner().run(cliPath: cli.path, model: "sonnet", payload: "x")

        guard case .failure(let message) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(message.contains("boom: something broke"))
    }

    @Test("covers AE7: a missing CLI path shows that the CLI was not found at that path")
    func missingCLIPath() async {
        let path = "/nonexistent/path/to/cli-\(UUID().uuidString)"
        let outcome = await AdviceRunner().run(cliPath: path, model: "sonnet", payload: "x")

        guard case .failure(let message) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(message.contains("not found"))
        #expect(message.contains(path))
    }

    @Test("a stub sleeping past the timeout is terminated, and a timeout error is shown")
    func timeoutTerminatesTheProcess() async throws {
        let cli = try makeStub("""
        #!/bin/sh
        cat > /dev/null
        sleep 30
        echo '\(okJSON)'
        """)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }

        let outcome = await AdviceRunner().run(cliPath: cli.path, model: "sonnet", payload: "x", timeout: 0.2)

        guard case .failure(let message) = outcome else {
            Issue.record("expected a timeout failure, got \(outcome)")
            return
        }
        #expect(message.contains("timed out"))
    }

    @Test("the advice button is disabled with empty history and enabled after one write")
    func availabilityFollowsHistory() {
        let ring = HistoryRing(capacity: 10)
        #expect(AdviceAvailability.isAvailable(historyRange: ring.range) == false)

        ring.write(at: 0, [0, 0])

        #expect(AdviceAvailability.isAvailable(historyRange: ring.range) == true)
    }
}
