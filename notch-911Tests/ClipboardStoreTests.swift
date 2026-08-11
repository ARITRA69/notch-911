import AppKit
import Foundation
import Testing
@testable import notch_911

/// `ClipboardStore.init` restores but never polls, so nothing in this suite
/// touches `NSPasteboard.general` — it is safe to run while you are using the
/// machine, and no test can race the developer's real clipboard.
@Suite("Clipboard history")
@MainActor
struct ClipboardStoreTests {

    // MARK: Fixture

    /// A temp directory per test, in the shape `CodexPlanQuestionWatcherTests`
    /// already uses.
    private struct Fixture {
        let directory: URL

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-911-clipboard-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
        var manifest: URL { directory.appendingPathComponent("manifest.json") }

        func store() -> ClipboardStore { ClipboardStore(directory: directory) }

        func blobExists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: blobs.appendingPathComponent(name).path)
        }

        func blobNames() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: blobs.path))?.sorted() ?? []
        }

        func writeManifest(_ json: String) {
            try? json.data(using: .utf8)?.write(to: manifest)
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Whole-second dates on purpose: Foundation's `.iso8601` strategy uses
    /// `.withInternetDateTime` and drops sub-second precision, so a plain
    /// `Date()` does not survive a round trip byte-for-byte and the test would
    /// fail for a reason that has nothing to do with the code under test.
    private func date(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset.rounded())
    }

    private func textItem(_ body: String, at offset: TimeInterval = 0) -> ClipItem {
        var item = ClipItem(
            id: UUID(),
            kind: .text,
            fingerprint: ClipboardCapture.fingerprint(.text(body)),
            firstCopiedAt: date(offset),
            lastCopiedAt: date(offset),
            copyCount: 1,
            source: ClipSource(bundleID: "com.apple.Safari", name: "Safari"),
            byteCount: body.utf8.count
        )
        item.text = body
        return item
    }

    private func imageItem(in fixture: Fixture, bytes: Int = 64) -> ClipItem {
        let payload = Data(repeating: UInt8.random(in: 0...255), count: bytes)
        let id = UUID()
        let name = "\(id.uuidString).png"
        let thumb = "\(id.uuidString)-thumb.png"
        try? FileManager.default.createDirectory(at: fixture.blobs, withIntermediateDirectories: true)
        try? payload.write(to: fixture.blobs.appendingPathComponent(name))
        try? payload.write(to: fixture.blobs.appendingPathComponent(thumb))

        var item = ClipItem(
            id: id,
            kind: .image,
            fingerprint: ClipboardCapture.fingerprint(.image(data: payload, type: "public.png")),
            firstCopiedAt: date(),
            lastCopiedAt: date(),
            copyCount: 1,
            source: nil,
            byteCount: payload.count
        )
        item.imageBlob = name
        item.imageType = "public.png"
        item.thumbnailBlob = thumb
        return item
    }

    // MARK: Dedupe and eviction

    @Test("Inserting past the cap evicts the oldest")
    func evictsOldest() {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        for index in 0..<(ClipboardStore.maxItems + 1) {
            store.record(textItem("clip \(index)"))
        }

        #expect(store.items.count == ClipboardStore.maxItems)
        #expect(store.items.first?.text == "clip \(ClipboardStore.maxItems)")
        #expect(!store.items.contains { $0.text == "clip 0" })
    }

    @Test("Re-copying moves the item to the top without duplicating")
    func dedupeMovesToTop() {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        let first = textItem("A")
        store.record(first)
        store.record(textItem("B"))
        store.record(textItem("A", at: 60))

        #expect(store.items.count == 2)
        #expect(store.items.first?.text == "A")
        #expect(store.items.first?.copyCount == 2)
        // The id is reused so SwiftUI's ForEach identity — and the thumbnail
        // cache — survive the move.
        #expect(store.items.first?.id == first.id)
        #expect(store.items.first?.lastCopiedAt == date(60))
    }

    @Test("Eviction deletes the blobs")
    func evictionDeletesBlobs() async throws {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        let doomed = imageItem(in: fixture)
        store.record(doomed)
        for index in 0..<ClipboardStore.maxItems {
            store.record(textItem("filler \(index)"))
        }

        #expect(!store.items.contains { $0.id == doomed.id })
        // Blob deletion is detached so a 16MB unlink never lands on the main
        // actor; give it a moment to run.
        try await Task.sleep(for: .milliseconds(400))
        #expect(!fixture.blobExists(try #require(doomed.imageBlob)))
        #expect(!fixture.blobExists(try #require(doomed.thumbnailBlob)))
    }

    @Test("A dedupe hit discards the redundant blobs")
    func dedupeDiscardsBlobs() async throws {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        let original = imageItem(in: fixture)
        store.record(original)

        // Same fingerprint, freshly written blobs — exactly what `prepare`
        // hands over on a re-copy.
        var duplicate = imageItem(in: fixture)
        duplicate = ClipItem(
            id: duplicate.id, kind: .image, fingerprint: original.fingerprint,
            firstCopiedAt: date(60), lastCopiedAt: date(60), copyCount: 1,
            source: nil, byteCount: duplicate.byteCount
        )
        var withBlobs = duplicate
        withBlobs.imageBlob = "\(duplicate.id.uuidString).png"
        withBlobs.thumbnailBlob = "\(duplicate.id.uuidString)-thumb.png"
        store.record(withBlobs)

        #expect(store.items.count == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.blobExists(try #require(original.imageBlob)))
        #expect(!fixture.blobExists(try #require(withBlobs.imageBlob)))
    }

    @Test("The byte budget evicts before the count cap is reached")
    func byteBudgetEvicts() {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        // Three items that each claim half the total budget. The count cap is
        // nowhere near, so only the byte ceiling can be doing this.
        let half = ClipboardStore.maxTotalBytes / 2
        for index in 0..<3 {
            var item = textItem("big \(index)")
            item = ClipItem(
                id: item.id, kind: .text, fingerprint: item.fingerprint,
                firstCopiedAt: item.firstCopiedAt, lastCopiedAt: item.lastCopiedAt,
                copyCount: 1, source: nil, byteCount: half
            )
            store.record(item)
        }

        #expect(store.items.count < 3)
        #expect(store.items.reduce(0) { $0 + $1.byteCount } <= ClipboardStore.maxTotalBytes)
    }

    @Test("removeAll empties the list and the blobs directory")
    func removeAllClears() async throws {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        store.record(imageItem(in: fixture))
        store.record(textItem("keep me"))
        store.removeAll()

        #expect(store.items.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.blobNames().isEmpty)
    }

    @Test("A delete is durable immediately, not on the save debounce")
    func deleteIsDurable() {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        let doomed = textItem("delete me")
        store.record(doomed)
        store.record(textItem("keep me"))
        store.flush()
        store.remove(doomed)

        // No `flush()` and no sleep: a crash inside the 750ms debounce must not
        // resurrect it. Inline text has no blob to go missing, so the manifest
        // is the only thing standing between a deletion and its undoing.
        let restored = fixture.store()
        #expect(restored.items.map(\.text) == ["keep me"])
    }

    @Test("Clearing everything is durable immediately")
    func clearIsDurable() {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        for index in 0..<5 { store.record(textItem("clip \(index)")) }
        store.flush()
        store.removeAll()

        #expect(fixture.store().items.isEmpty)
    }

    @Test("Re-copying repairs an item whose blob went missing")
    func dedupeRepairsBrokenItem() async throws {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        let original = imageItem(in: fixture)
        store.record(original)

        // The blob disappears under us — external deletion, a lost unlink, a
        // half-swept crash. The row is still on screen and now unpasteable.
        try FileManager.default.removeItem(
            at: fixture.blobs.appendingPathComponent(try #require(original.imageBlob))
        )

        // Copying the same thing again is the natural repair attempt.
        var replacement = imageItem(in: fixture)
        replacement = ClipItem(
            id: replacement.id, kind: .image, fingerprint: original.fingerprint,
            firstCopiedAt: date(60), lastCopiedAt: date(60), copyCount: 1,
            source: nil, byteCount: replacement.byteCount
        )
        var withBlobs = replacement
        withBlobs.imageBlob = "\(replacement.id.uuidString).png"
        withBlobs.thumbnailBlob = "\(replacement.id.uuidString)-thumb.png"
        store.record(withBlobs)

        #expect(store.items.count == 1)
        // Identity is kept, but the good bytes are adopted rather than binned.
        #expect(store.items.first?.id == original.id)
        #expect(store.items.first?.imageBlob == withBlobs.imageBlob)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.blobExists(try #require(withBlobs.imageBlob)))
    }

    @Test("A capture raises the badge flag and notifies on both edges")
    func captureFlashes() async throws {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        var edges = 0
        store.onCapture = { edges += 1 }
        store.record(textItem("flash me"))

        // Raised immediately — the panel has to come on screen for the badge.
        #expect(store.justCaptured)
        #expect(edges == 1)

        try await Task.sleep(
            for: .milliseconds(ClipboardStore.captureFlashMilliseconds + 400)
        )
        // ...and lowered again, with a second notification so the panel can go.
        #expect(!store.justCaptured)
        #expect(edges == 2)
    }

    @Test("Re-copying the same thing flashes again")
    func dedupeAlsoFlashes() async throws {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        store.record(textItem("same"))
        try await Task.sleep(
            for: .milliseconds(ClipboardStore.captureFlashMilliseconds + 400)
        )
        #expect(!store.justCaptured)

        // A badge that appeared for new clips but not familiar ones would read
        // as the app having missed the copy.
        store.record(textItem("same", at: 60))
        #expect(store.justCaptured)
        #expect(store.items.count == 1)
    }

    // MARK: Persistence

    @Test("The manifest round-trips")
    func manifestRoundTrips() throws {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        let text = textItem("round trip")
        let image = imageItem(in: fixture)
        store.record(text)
        store.record(image)
        store.flush()

        let restored = fixture.store()
        #expect(restored.items.count == 2)
        #expect(restored.items.map(\.id) == [image.id, text.id])
        #expect(restored.items.last?.text == "round trip")
        #expect(restored.items.last?.lastCopiedAt == text.lastCopiedAt)
        #expect(restored.items.last?.source?.bundleID == "com.apple.Safari")
    }

    @Test("One unreadable entry doesn't lose the rest")
    func lenientDecode() {
        let fixture = Fixture(); defer { fixture.tearDown() }
        fixture.writeManifest("""
        {
          "version": 1,
          "items": [
            {"id": "\(UUID().uuidString)", "kind": "text", "fingerprint": "a",
             "firstCopiedAt": "2023-11-14T22:13:20Z", "lastCopiedAt": "2023-11-14T22:13:20Z",
             "copyCount": 1, "byteCount": 3, "text": "one"},
            {"id": "\(UUID().uuidString)", "fingerprint": "b"},
            {"id": "\(UUID().uuidString)", "kind": "text", "fingerprint": "c",
             "firstCopiedAt": "2023-11-14T22:13:20Z", "lastCopiedAt": "2023-11-14T22:13:20Z",
             "copyCount": 1, "byteCount": 5, "text": "three"}
          ]
        }
        """)

        let store = fixture.store()
        #expect(store.items.count == 2)
        #expect(store.items.map(\.text) == ["one", "three"])
    }

    @Test("A manifest entry with a missing blob drops just that item")
    func missingBlobDropsItem() {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        let image = imageItem(in: fixture)
        store.record(image)
        store.record(textItem("survivor"))
        store.flush()

        try? FileManager.default.removeItem(
            at: fixture.blobs.appendingPathComponent(image.imageBlob ?? "")
        )

        let restored = fixture.store()
        #expect(restored.items.count == 1)
        #expect(restored.items.first?.text == "survivor")
    }

    @Test("A corrupt manifest restores as empty rather than throwing")
    func corruptManifest() {
        let fixture = Fixture(); defer { fixture.tearDown() }
        fixture.writeManifest("{not json")

        let store = fixture.store()
        #expect(store.items.isEmpty)
        // Left on disk on purpose, so it's still there when someone reports it.
        #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
    }

    @Test("A future manifest version is left alone")
    func futureVersionUntouched() throws {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let json = #"{"version": 99, "items": []}"#
        fixture.writeManifest(json)

        let store = fixture.store()
        #expect(store.items.isEmpty)
        let after = try String(contentsOf: fixture.manifest, encoding: .utf8)
        #expect(after == json)
    }

    @Test("Restore preserves newest-first order")
    func orderPreserved() {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()

        for index in 0..<5 { store.record(textItem("clip \(index)")) }
        store.flush()

        let restored = fixture.store()
        #expect(restored.items.map(\.text) == ["clip 4", "clip 3", "clip 2", "clip 1", "clip 0"])
    }

    @Test("Orphaned blobs are swept after restore")
    func orphanSweep() async throws {
        let fixture = Fixture(); defer { fixture.tearDown() }
        let store = fixture.store()
        store.record(textItem("anything"))
        store.flush()

        try FileManager.default.createDirectory(at: fixture.blobs, withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: fixture.blobs.appendingPathComponent("stray.png"))

        _ = fixture.store()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!fixture.blobExists("stray.png"))
    }

    // MARK: Presentation

    @Test("Text previews collapse to a single line")
    func previewCollapsesNewlines() {
        let item = textItem("first line\nsecond line")
        #expect(ClipboardStore.preview(for: item) == "first line second line")
    }

    @Test("A file clip whose paths are all gone is stale")
    func staleFileClip() {
        var item = ClipItem(
            id: UUID(), kind: .files, fingerprint: "x",
            firstCopiedAt: date(), lastCopiedAt: date(), copyCount: 1,
            source: nil, byteCount: 0
        )
        item.filePaths = ["/tmp/definitely-not-here-\(UUID().uuidString)"]
        #expect(ClipboardStore.isStale(item))
    }
}
