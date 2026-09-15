import Foundation

struct AdviceUsage: Equatable {
    let inputTokens: Int
    let outputTokens: Int
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
/// with `-p --model <model> --tools "" --safe-mode --output-format json`, the
/// payload on stdin. A timeout and `cancel()` both bound the call by
/// terminating the same running process.
actor AdviceRunner {
    static let timeout: TimeInterval = 180

    private var process: Process?

    func run(cliPath: String, model: String, payload: String, timeout: TimeInterval = AdviceRunner.timeout) async -> AdviceOutcome {
        let notFound = AdviceOutcome.failure("The CLI was not found at \(cliPath).")
        let expanded = (cliPath as NSString).expandingTildeInPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: expanded)
        process.arguments = ["-p", "--model", model, "--tools", "", "--safe-mode", "--output-format", "json"]
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

        async let outputData = readToEnd(stdout)
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
        let usage = AdviceUsage(inputTokens: decoded.usage?.inputTokens ?? 0,
                                outputTokens: decoded.usage?.outputTokens ?? 0)
        return .success(answer: answer, usage: usage)
    }
}

/// The `claude -p --output-format json` result message shape.
private struct CLIResult: Decodable {
    let result: String?
    let isError: Bool?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case result
        case isError = "is_error"
        case usage
    }

    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}
