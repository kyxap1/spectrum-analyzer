import Foundation

struct AdviceUsage: Equatable {
    let inputTokens: Int
    let outputTokens: Int
}

/// A streamed step: `status` is nil when only the token count moved.
struct AdviceProgress: Equatable {
    let status: String?
    let usage: AdviceUsage
}

enum AdviceOutcome: Equatable {
    case success(answer: String, usage: AdviceUsage)
    case failure(String)
}

/// Whether the recommendation button has anything to analyze (R16): empty
/// kept history disables it.
enum AdviceAvailability {
    static func isAvailable(historyRange: Range<Int>) -> Bool {
        !historyRange.isEmpty
    }
}

/// KTD13: runs the Claude CLI as a child process. The app starts it at a path
/// from settings (`~` expanded, since Dock-launched apps get no shell `PATH`)
/// with `-p --model <model> --safe-mode --output-format stream-json` and
/// WebFetch limited to `fetchDomains` (no tools when empty), the payload on
/// stdin. Each streamed step is reported through `onProgress`. A timeout and
/// `cancel()` both bound the call by terminating the same running process.
actor AdviceRunner {
    static let timeout: TimeInterval = 180

    private var process: Process?

    func run(cliPath: String, model: String, payload: String, fetchDomains: [String] = [],
             timeout: TimeInterval = AdviceRunner.timeout,
             onProgress: @escaping @Sendable (AdviceProgress) -> Void = { _ in }) async -> AdviceOutcome {
        // A cancel landing before launch finds no process to terminate.
        guard !Task.isCancelled else { return .failure("Cancelled.") }
        let notFound = AdviceOutcome.failure("The CLI was not found at \(cliPath).")
        let expanded = (cliPath as NSString).expandingTildeInPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: expanded)
        // User settings may allow WebFetch everywhere; loading only project settings
        // (none exist in the temp cwd) keeps the domain allowlist authoritative.
        let allowed = fetchDomains.map { "WebFetch(domain:\($0))" }.joined(separator: ",")
        let tools = allowed.isEmpty ? ["--tools", ""] : ["--tools", "WebFetch", "--allowedTools", allowed]
        process.arguments = ["-p", "--model", model] + tools
            + ["--setting-sources", "project", "--permission-mode", "dontAsk",
               "--safe-mode", "--output-format", "stream-json", "--verbose"]
        // A launched app's cwd is `/`. Run from there, the CLI raises Media Library
        // and network-volume prompts, which macOS attributes to the app.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            guard FileManager.default.fileExists(atPath: expanded) else { return notFound }
            return .failure("The CLI at \(cliPath) could not be started: \(error.localizedDescription)")
        }
        self.process = process

        if let data = payload.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

        async let outputData = readEvents(stdout, onProgress: onProgress)
        async let errorData = readToEnd(stderr)

        let timedOut = await waitWithTimeout(process, timeout: timeout)
        let out = await outputData
        let err = await errorData
        self.process = nil

        if timedOut {
            return .failure("The request timed out after \(Int(timeout)) s.")
        }
        guard process.terminationStatus == 0 else {
            let tail = String(data: err, encoding: .utf8) ?? ""
            return .failure(String(tail.suffix(500)))
        }
        return Self.parse(out)
    }

    /// Terminates the running request, if any.
    func cancel() {
        process?.terminate()
    }

    /// Races the process's own exit against `timeout`, terminating it on a
    /// timeout so a hung CLI cannot block the request indefinitely.
    private func waitWithTimeout(_ process: Process, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in continuation.resume() }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return true
            }
            let timedOut = await group.next() ?? false
            if timedOut, process.isRunning { process.terminate() }
            group.cancelAll()
            return timedOut
        }
    }

    private nonisolated func readToEnd(_ pipe: Pipe) async -> Data {
        await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
    }

    /// Reads stream-json events until EOF, reporting tool calls and tokens
    /// used so far as they come, and returns the final `result` line.
    private nonisolated func readEvents(_ pipe: Pipe, onProgress: @escaping @Sendable (AdviceProgress) -> Void) async -> Data {
        await Task.detached {
            var result = Data()
            // One API message can arrive as several events repeating its usage.
            var usageByMessage: [String: AdviceUsage] = [:]
            var lines = pipe.fileHandleForReading.bytes.lines.makeAsyncIterator()
            while let line = try? await lines.next() {
                let data = Data(line.utf8)
                guard let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else { continue }
                if event.type == "result" { result = data }
                if let id = event.message?.id, let usage = event.message?.usage {
                    usageByMessage[id] = usage.advice
                }
                let status = Self.status(of: event)
                guard status != nil || event.message?.usage != nil else { continue }
                let total = usageByMessage.values.reduce(AdviceUsage(inputTokens: 0, outputTokens: 0)) {
                    AdviceUsage(inputTokens: $0.inputTokens + $1.inputTokens, outputTokens: $0.outputTokens + $1.outputTokens)
                }
                onProgress(AdviceProgress(status: status, usage: total))
            }
            return result
        }.value
    }

    static func status(of event: StreamEvent) -> String? {
        switch event.type {
        case "assistant":
            guard let tool = event.message?.content.first(where: { $0.type == "tool_use" }) else { return nil }
            if let url = tool.input?.url {
                return "Fetching \(URL(string: url)?.host() ?? url)\u{2026}"
            }
            return "Using \(tool.name ?? "a tool")\u{2026}"
        case "user":
            return "Thinking\u{2026}"
        default:
            return nil
        }
    }

    private static func parse(_ data: Data) -> AdviceOutcome {
        guard let decoded = try? JSONDecoder().decode(CLIResult.self, from: data) else {
            return .failure("The CLI's output could not be parsed.")
        }
        if decoded.isError == true {
            return .failure(decoded.result ?? "The request failed.")
        }
        guard let answer = decoded.result else {
            return .failure("The CLI's output had no result.")
        }
        let usage = decoded.usage?.advice ?? AdviceUsage(inputTokens: 0, outputTokens: 0)
        return .success(answer: answer, usage: usage)
    }
}

/// The `claude -p --output-format json` result message shape.
private struct CLIResult: Decodable {
    let result: String?
    let isError: Bool?
    let usage: CLIUsage?

    enum CodingKeys: String, CodingKey {
        case result
        case isError = "is_error"
        case usage
    }
}

/// Uncached `input_tokens` is only a sliver of the prompt; cache reads and
/// writes count toward what the request consumed.
private struct CLIUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    var advice: AdviceUsage {
        AdviceUsage(inputTokens: inputTokens + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0),
                    outputTokens: outputTokens)
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

/// The subset of a `claude -p --output-format stream-json` event read for progress.
struct StreamEvent: Decodable {
    let type: String
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let content: [Content]
        fileprivate let usage: CLIUsage?
    }

    struct Content: Decodable {
        let type: String
        let name: String?
        let input: Input?
    }

    struct Input: Decodable {
        let url: String?
    }
}
