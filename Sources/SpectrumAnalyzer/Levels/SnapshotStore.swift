import Foundation

/// A reference saved under a name: band levels only, never audio (R12).
struct Snapshot: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let reference: Reference

    var name: String { reference.name ?? "" }
}

/// KTD8: every snapshot in one JSON file, written atomically on each change.
/// A file that fails to decode is kept as `snapshots.json.bad` so a bad write
/// never wipes saved parts.
final class SnapshotStore {
    private(set) var snapshots: [Snapshot] = []
    private let url: URL

    init(url: URL = SnapshotStore.defaultURL) {
        self.url = url
        load()
    }

    private static let defaultURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spectrum Analyzer", isDirectory: true)
        return dir.appendingPathComponent("snapshots.json")
    }()

    @discardableResult
    func save(_ reference: Reference, name: String) -> Snapshot {
        var named = reference
        named.name = name
        let snapshot = Snapshot(id: UUID(), date: Date(), reference: named)
        snapshots.append(snapshot)
        persist()
        return snapshot
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        var reference = snapshots[index].reference
        reference.name = name
        snapshots[index] = Snapshot(id: id, date: snapshots[index].date, reference: reference)
        persist()
    }

    func delete(_ id: UUID) {
        snapshots.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            snapshots = try Self.decoder.decode([Snapshot].self, from: data)
        } catch {
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(snapshots) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()
}
