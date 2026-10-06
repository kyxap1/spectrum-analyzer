import Foundation

/// The rig markdown for one request: freshly fetched, or the cached fallback
/// dated `cachedAt` when the fetch failed (KTD15).
struct RigText {
    let markdown: String
    let cachedAt: Date?
}

enum RigFetchError: Error, Equatable, LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

/// The network seam. `URLSession` implements it directly.
protocol RigFetching {
    func fetchText(from url: URL, timeoutInterval: TimeInterval) async throws -> String
}

extension URLSession: RigFetching {
    func fetchText(from url: URL, timeoutInterval: TimeInterval) async throws -> String {
        let request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { throw RigFetchError.unavailable("The rig fetch returned an unexpected response.") }
        return text
    }
}

/// The last-good-copy cache. A plain file implements it directly.
protocol RigCaching {
    /// The cached text and the date it was written, nil when nothing is cached.
    func read() -> (text: String, date: Date)?
    func write(_ text: String)
}

final class FileRigCache: RigCaching {
    private let fileManager = FileManager.default
    private let url: URL

    init(url: URL = FileRigCache.defaultURL) {
        self.url = url
    }

    private static let defaultURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spectrum Analyzer", isDirectory: true)
        return dir.appendingPathComponent("rig-cache.md")
    }()

    func read() -> (text: String, date: Date)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let date = try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        else { return nil }
        return (text, date)
    }

    func write(_ text: String) {
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// KTD15: fetches the rig markdown at request time with a 10 s timeout,
/// caches the last good copy, and falls back to it (noting its date) when the
/// fetch fails. Refuses when the fetch fails and nothing is cached.
enum RigSource {
    static let defaultURL = URL(string: "https://rig.kyxap.pro/raw")!
    static let timeout: TimeInterval = 10

    static func fetch(url: URL = defaultURL,
                      fetcher: RigFetching = URLSession.shared,
                      cache: RigCaching = FileRigCache()) async -> Result<RigText, RigFetchError> {
        do {
            let text = try await fetcher.fetchText(from: url, timeoutInterval: timeout)
            cache.write(text)
            return .success(RigText(markdown: text, cachedAt: nil))
        } catch {
            if let cached = cache.read() {
                return .success(RigText(markdown: cached.text, cachedAt: cached.date))
            }
            let reason = error.localizedDescription
            return .failure(.unavailable("The rig could not be fetched from \(url.absoluteString) (\(reason)) and no cached copy exists."))
        }
    }
}

/// The switchable pedals in the rig's `### Pedals` table and the player's
/// current rig state sent with a request. Tuner and switch rows carry no tone.
enum RigPedals {
    static func names(in markdown: String) -> [String] {
        var inSection = false
        var pastSeparator = false
        var names: [String] = []
        for line in markdown.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                inSection = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) == "Pedals"
                pastSeparator = false
                continue
            }
            guard inSection, trimmed.hasPrefix("|") else { continue }
            let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { continue }
            if cells[0].allSatisfy({ $0 == "-" || $0 == ":" }) {
                pastSeparator = true
                continue
            }
            let designation = cells[1].lowercased()
            guard pastSeparator, !designation.contains("tuner"), !designation.contains("switch") else { continue }
            names.append(cells[0])
        }
        return names
    }

    /// Nil when there is neither a pedal list nor a note to report.
    static func state(pedals: [String], engaged: Set<String>, notes: String) -> String? {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pedals.isEmpty || !notes.isEmpty else { return nil }
        var lines = ["Current rig state (overrides the rig description):"]
        if !pedals.isEmpty {
            let on = pedals.filter(engaged.contains)
            lines.append(on.isEmpty
                ? "All pedals in the Pedals table are bypassed."
                : "Pedals engaged now: \(on.joined(separator: ", ")). The other pedals in the Pedals table are bypassed.")
        }
        if !notes.isEmpty {
            lines.append("Player notes: \(notes)")
        }
        return lines.joined(separator: "\n")
    }
}
