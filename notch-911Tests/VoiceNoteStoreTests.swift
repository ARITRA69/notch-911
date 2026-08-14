import AppKit
import Foundation
import Testing
@testable import notch_911

/// Nothing here touches `AVAudioEngine` or `Speech` — recording and
/// transcription need real hardware and a real microphone permission, neither
/// of which exists in a test host. What's tested is the part that doesn't need
/// either: the manifest surviving a round trip, and a recording note that has
/// lost its backing file being dropped rather than shown as something it can
/// no longer play.
@Suite("Voice notes")
@MainActor
struct VoiceNoteStoreTests {

    // MARK: Fixture

    /// A temp directory per test, in the shape `ClipboardStoreTests` already
    /// uses for the same reason: `VoiceNoteStore.init` restores but never
    /// touches the microphone, so this is safe to run on a real machine.
    private struct Fixture {
        let directory: URL

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-911-voice-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
        var manifest: URL { directory.appendingPathComponent("manifest.json") }

        func store() -> VoiceNoteStore { VoiceNoteStore(directory: directory) }

        func writeManifest(_ json: String) {
            try? json.data(using: .utf8)?.write(to: manifest)
        }

        func writeBlob(_ name: String) {
            try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
            try? Data().write(to: blobs.appendingPathComponent(name))
        }

        func blobExists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: blobs.appendingPathComponent(name).path)
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }
    }

    private func manifestJSON(entries: String) -> String {
        """
        {"version": 1, "entries": [\(entries)]}
        """
    }

    // MARK: Restore

    @Test("A transcript note round-trips through the manifest")
    func transcriptRoundTrips() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let id = UUID()

        fixture.writeManifest(manifestJSON(entries: """
        {"id": "\(id.uuidString)", "createdAt": 700000000, "duration": 12.5, "transcript": "buy oat milk"}
        """))

        let store = fixture.store()
        #expect(store.notes.count == 1)
        #expect(store.notes.first?.id == id)
        #expect(store.notes.first?.content == .transcript("buy oat milk"))
        #expect(store.notes.first?.isTranscript == true)
    }

    @Test("A recording note whose blob still exists round-trips")
    func recordingRoundTripsWhenBlobExists() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let id = UUID()
        fixture.writeBlob("note.caf")

        fixture.writeManifest(manifestJSON(entries: """
        {"id": "\(id.uuidString)", "createdAt": 700000000, "duration": 4, "recordingFile": "note.caf"}
        """))

        let store = fixture.store()
        #expect(store.notes.count == 1)
        #expect(store.notes.first?.content == .recording(file: "note.caf"))
        #expect(store.notes.first?.isTranscript == false)
    }

    @Test("A recording note whose blob is gone is dropped, not shown broken")
    func recordingDroppedWhenBlobMissing() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.writeManifest(manifestJSON(entries: """
        {"id": "\(UUID().uuidString)", "createdAt": 700000000, "duration": 4, "recordingFile": "gone.caf"}
        """))

        let store = fixture.store()
        #expect(store.notes.isEmpty)
    }

    @Test("An empty manifest is a healthy empty store, not a decode failure")
    func firstRunIsEmpty() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        let store = fixture.store()
        #expect(store.notes.isEmpty)
        #expect(store.phase == .idle)
    }

    // MARK: Removal

    @Test("Removing one note deletes its blob and persists the change")
    func removeDeletesBlobAndPersists() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let keep = UUID()
        let drop = UUID()
        fixture.writeBlob("drop.caf")

        fixture.writeManifest(manifestJSON(entries: """
        {"id": "\(keep.uuidString)", "createdAt": 700000000, "duration": 3, "transcript": "keep me"},
        {"id": "\(drop.uuidString)", "createdAt": 700000001, "duration": 3, "recordingFile": "drop.caf"}
        """))

        let store = fixture.store()
        #expect(store.notes.count == 2)
        guard let dropped = store.notes.first(where: { $0.id == drop }) else {
            Issue.record("fixture note missing")
            return
        }

        store.remove(dropped)
        #expect(store.notes.map(\.id) == [keep])
        // The unlink is detached — the list updates now, the disk catches up.
        #expect(await eventually { !fixture.blobExists("drop.caf") })

        // Persisted, not just mutated in memory — a fresh instance over the
        // same directory should agree.
        let reloaded = fixture.store()
        #expect(reloaded.notes.map(\.id) == [keep])
    }

    @Test("Clearing all notes deletes every blob and leaves the manifest empty")
    func removeAllClearsEverything() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.writeBlob("a.caf")
        fixture.writeBlob("b.caf")

        fixture.writeManifest(manifestJSON(entries: """
        {"id": "\(UUID().uuidString)", "createdAt": 700000000, "duration": 3, "recordingFile": "a.caf"},
        {"id": "\(UUID().uuidString)", "createdAt": 700000001, "duration": 3, "recordingFile": "b.caf"}
        """))

        let store = fixture.store()
        #expect(store.notes.count == 2)

        store.removeAll()
        #expect(store.notes.isEmpty)
        #expect(await eventually { !fixture.blobExists("a.caf") && !fixture.blobExists("b.caf") })

        let reloaded = fixture.store()
        #expect(reloaded.notes.isEmpty)
    }

    // MARK: Blob hygiene

    /// The sweep and the eager unlinks both run on a detached utility task, so
    /// the assertion has to give them a moment. Polling rather than one long
    /// sleep keeps the passing case fast.
    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async -> Bool {
        var waited = Duration.zero
        let step = Duration.milliseconds(25)
        while waited < timeout {
            if condition() { return true }
            try? await Task.sleep(for: step)
            waited += step
        }
        return condition()
    }

    @Test("A recording left behind by an interrupted note is swept on restore")
    func orphanBlobsAreSwept() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.writeBlob("referenced.caf")
        fixture.writeBlob("orphan.caf")

        fixture.writeManifest(manifestJSON(entries: """
        {"id": "\(UUID().uuidString)", "createdAt": 700000000, "duration": 3, "recordingFile": "referenced.caf"}
        """))

        let store = fixture.store()
        #expect(store.notes.count == 1)

        #expect(await eventually { !fixture.blobExists("orphan.caf") })
        // The one an actual note points at must survive the same pass.
        #expect(fixture.blobExists("referenced.caf"))
    }

    @Test("Removing a note unlinks its recording off the main actor")
    func removeUnlinksBlobEventually() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let id = UUID()
        fixture.writeBlob("gone-soon.caf")

        fixture.writeManifest(manifestJSON(entries: """
        {"id": "\(id.uuidString)", "createdAt": 700000000, "duration": 3, "recordingFile": "gone-soon.caf"}
        """))

        let store = fixture.store()
        guard let note = store.notes.first else {
            Issue.record("fixture note missing")
            return
        }

        store.remove(note)
        #expect(store.notes.isEmpty)
        #expect(await eventually { !fixture.blobExists("gone-soon.caf") })
    }

    // MARK: Copy

    @Test("A transcript copies as text")
    func transcriptCopiesAsText() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.writeManifest(manifestJSON(entries: """
        {"id": "\(UUID().uuidString)", "createdAt": 700000000, "duration": 3, "transcript": "ring the dentist"}
        """))

        let store = fixture.store()
        guard let note = store.notes.first else {
            Issue.record("fixture note missing")
            return
        }

        store.copy(note)
        #expect(NSPasteboard.general.string(forType: .string) == "ring the dentist")
        #expect(store.justCopied == note.id)
    }

    /// The half that didn't exist before: a note that failed to transcribe is
    /// still copyable, as the audio file itself.
    @Test("A recording copies as its file, not as nothing")
    func recordingCopiesAsFileURL() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.writeBlob("note.caf")

        fixture.writeManifest(manifestJSON(entries: """
        {"id": "\(UUID().uuidString)", "createdAt": 700000000, "duration": 3, "recordingFile": "note.caf"}
        """))

        let store = fixture.store()
        guard let note = store.notes.first else {
            Issue.record("fixture note missing")
            return
        }

        store.copy(note)
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        #expect(urls.map(\.lastPathComponent) == ["note.caf"])
        #expect(store.justCopied == note.id)
    }
}
