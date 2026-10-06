import AVFoundation
import Testing
@testable import SpectrumAnalyzer

private func makeReference(name: String? = nil) -> Reference {
    Reference(name: name, windowSeconds: 10, activeSeconds: 10, guitarLevelDBFS: -18.5, guitarPeakDBFS: -6,
              guitarBands: (0..<31).map { Float($0) / 100 }, guitarDisplay: [Float](repeating: 0.25, count: 240),
              mixLevelDBFS: -20, mixBands: [Float](repeating: 0.5, count: 31))
}

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("snapshots.json")
}

@Suite("SnapshotStore")
struct SnapshotStoreTests {
    @Test("covers AE7: a saved snapshot survives a new store, and its file holds band levels and no samples")
    func persistsBandsOnly() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SnapshotStore(url: url)
        store.save(makeReference(), name: "Song \u{2014} chorus")

        let reopened = SnapshotStore(url: url)
        #expect(reopened.snapshots.map(\.name) == ["Song \u{2014} chorus"])
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("guitarBands"))
        #expect(!json.lowercased().contains("samples"))
        #expect(!json.contains("Int16"))
    }

    @Test("rename and delete persist across a new store")
    func renameAndDelete() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SnapshotStore(url: url)
        let first = store.save(makeReference(), name: "A")
        let second = store.save(makeReference(), name: "B")
        store.rename(first.id, to: "A2")
        store.delete(second.id)

        #expect(SnapshotStore(url: url).snapshots.map(\.name) == ["A2"])
    }

    @Test("an undecodable file is renamed to snapshots.json.bad and the store starts empty")
    func badFileIsKept() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)

        let store = SnapshotStore(url: url)
        #expect(store.snapshots.isEmpty)
        let bad = url.deletingLastPathComponent().appendingPathComponent("snapshots.json.bad")
        #expect(try String(contentsOf: bad, encoding: .utf8) == "not json")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a failed write is reported instead of swallowed")
    func writeFailureIsReported() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-blocker-\(UUID().uuidString)")
        try "file".write(to: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = SnapshotStore(url: blocker.appendingPathComponent("snapshots.json"))
        store.save(makeReference(), name: "A")
        #expect(store.lastError != nil)
    }

    @Test("a missing file starts an empty store without error")
    func missingFile() {
        #expect(SnapshotStore(url: temporaryURL()).snapshots.isEmpty)
    }

    @Test("loading a snapshot yields a reference equal to the saved one, carrying the name")
    func loadEqualsSaved() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SnapshotStore(url: url)
        let saved = store.save(makeReference(), name: "Verse")

        var expected = makeReference()
        expected.name = "Verse"
        #expect(SnapshotStore(url: url).snapshots.first { $0.id == saved.id }?.reference == expected)
    }
}
