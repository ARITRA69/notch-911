//
//  VoiceNoteStore.swift
//  notch-911
//
//  A voice note: press the hotkey, talk, press it again. What comes out is
//  text when the Mac can manage it and a recording when it can't — never
//  nothing.
//
//  Recognition is on-device only, deliberately, and there is no setting to
//  change that. The clipboard's whole pitch is "nothing leaves this Mac";
//  quietly routing someone's spoken voice notes through a server the moment
//  their locale lacks an on-device model would break that promise in the one
//  feature where it matters most. When on-device recognition isn't available —
//  wrong locale, no model downloaded, `Speech.framework` says no — the note
//  falls back to the recording itself, which is exactly the fallback that was
//  asked for, not a silent trip to Apple's servers instead.
//
//  The recording is written to disk *while* it happens, then handed to the
//  recognizer as a finished file rather than streamed live. A live
//  `SFSpeechAudioBufferRecognitionRequest` would let the notch show words
//  appearing as you speak, which is a better demo and a worse feature: it
//  couples the UI to partial results that can still change, and it means two
//  concurrent consumers of the same tap (the file writer and the recognizer)
//  instead of one. Record first, transcribe once, on a file that already
//  exists as the fallback if transcription comes back empty.
//

import AppKit
import AVFoundation
import Foundation
import Observation
import Speech
import os

// MARK: - Model

nonisolated enum VoiceNoteContent: Sendable, Equatable {
    case transcript(String)
    /// Filename within the blobs directory, never an absolute path — same
    /// reasoning as the clipboard's file clips: the directory can move between
    /// `DerivedData` and `/Applications`, and a stored absolute path would go
    /// stale on the very first update.
    case recording(file: String)
}

nonisolated struct VoiceNote: Identifiable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let content: VoiceNoteContent

    var isTranscript: Bool {
        if case .transcript = content { return true }
        return false
    }
}

/// Turns `AVAudioPlayer`'s did-finish callback into a closure. A separate
/// object rather than conforming the store itself: `VoiceNoteStore` is
/// `@MainActor` and the delegate method is not, and `AVAudioPlayer.delegate` is
/// weak — so this has to be something the store can hold on purpose.
private nonisolated final class PlaybackObserver: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}

/// Everything the input tap touches, on a type that is deliberately *not* on
/// the main actor.
///
/// This module compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a
/// closure written inline in `beginRecording()` inherits `@MainActor` —
/// `AVAudioNodeTapBlock` is a plain ObjC block with no `@Sendable` to opt it
/// out. AVFAudio then calls that main-actor closure on its own
/// `RealtimeMessenger` queue, the runtime's isolation check fails, and the app
/// traps on the very first buffer. Holding the tap's state here, behind a
/// `@Sendable` closure that captures nothing else, is what keeps the audio
/// thread off the main actor.
///
/// `@unchecked Sendable` because AVFAudio delivers buffers serially on one
/// queue: `file` is only ever touched by `receive(_:)`, and `meter` — which the
/// clock task reads from the main actor — is behind a lock.
private nonisolated final class RecordingTap: @unchecked Sendable {
    private let file: AVAudioFile
    private let meter = OSAllocatedUnfairLock(initialState: 0.0)

    init(file: AVAudioFile) {
        self.file = file
    }

    /// The most recent loudness reading, 0...1. Polled by the clock rather than
    /// pushed to the main actor per buffer: the meter only redraws at 10Hz, and
    /// hopping actors ~40 times a second to feed it would be work the audio
    /// thread does for nobody.
    var level: Double { meter.withLock { $0 } }

    /// Called on AVFAudio's tap queue, one buffer at a time.
    func receive(_ buffer: AVAudioPCMBuffer) {
        try? file.write(from: buffer)
        let level = Self.level(of: buffer)
        meter.withLock { $0 = level }
    }

    /// A 0...1 loudness reading. Root-mean-square rather than peak: a peak
    /// meter jumps around on every plosive and reads as flickery at 10Hz,
    /// where RMS tracks how loud the last buffer *sounded*.
    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)

        var sumOfSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frames { sumOfSquares += samples[frame] * samples[frame] }
        }
        let rms = sqrt(sumOfSquares / Float(frames * channelCount))
        // -50dB floor: below that is room tone, not speech, and mapping it to 0
        // is what makes the meter sit still between words instead of hovering.
        let db = 20 * log10(max(rms, 0.0000001))
        return Double(max(0, min(1, (db + 50) / 50)))
    }
}

// MARK: - Store

@MainActor
@Observable
final class VoiceNoteStore {

    enum Phase: Equatable {
        case idle
        /// `level` is 0...1, an RMS reading refreshed a few times a second —
        /// enough to drive a meter, not so often it repaints the surface at
        /// audio rate.
        case recording(elapsed: TimeInterval, level: Double)
        /// Mic held open, buffers not arriving. Carries no level because there
        /// is nothing to meter — the tap is silent until the engine restarts.
        case paused(elapsed: TimeInterval)
        case transcribing
    }

    /// Whether the two permissions this feature needs are settled. Modelled as
    /// one value rather than two Bools: the UI only ever needs to show *one*
    /// blocking reason at a time, and the microphone is checked first because
    /// nothing else works without it.
    enum Permission: Equatable {
        case unknown
        case ready
        case microphoneDenied
        /// Recording still works without this — only transcription is lost, and
        /// the note quietly becomes a recording instead. Never blocks `start()`.
        case speechDenied
    }

    /// Five minutes. A note, not a meeting recording — and a ceiling on how
    /// large the manifest's inline transcript text can get, since unlike the
    /// clipboard this store has no separate blob path for long text.
    nonisolated static let maxDuration: TimeInterval = 300
    /// The clipboard keeps thirty; notes are smaller and worth keeping longer,
    /// but the list still has to end somewhere.
    nonisolated static let maxNotes = 60
    nonisolated static let manifestVersion = 1

    private(set) var notes: [VoiceNote] = []
    private(set) var phase: Phase = .idle
    private(set) var permission: Permission = .unknown
    /// Set briefly after a note is saved, so the row can be highlighted the way
    /// a fresh clipping is.
    private(set) var justSaved: UUID?
    /// Set briefly after a note is copied to the pasteboard.
    private(set) var justCopied: UUID?
    /// The recording currently playing, if any. Held so the row that started it
    /// can offer to stop it — without this, playback is a thing you can begin
    /// and then only wait out.
    private(set) var playingID: UUID?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: .current)
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var recordingURL: URL?
    /// When the *current* run of the mic began — `nil` while paused. Not the
    /// start of the note: a paused-and-resumed note has several of these, and
    /// `accumulated` is what carries the rest.
    @ObservationIgnored private var startedAt: Date?
    /// Time captured before the current run. Pausing rolls the run into this
    /// and clears `startedAt`, so elapsed time never counts the gap.
    @ObservationIgnored private var accumulated: TimeInterval = 0
    /// Held for as long as the tap is installed — the clock reads its meter,
    /// and `teardownEngine()` drops it along with the engine.
    @ObservationIgnored private var tap: RecordingTap?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    /// `AVAudioPlayer.delegate` is weak, so whoever wants the did-finish
    /// callback has to keep the delegate alive themselves.
    @ObservationIgnored private var playbackObserver: PlaybackObserver?
    @ObservationIgnored
    private let log = Logger(subsystem: "com.aritra360.notch-911", category: "Voice")

    /// Injectable purely so tests get a temp directory — the precedent is
    /// `ClipboardStore.init(directory:)`.
    init(directory: URL = VoiceNoteStore.defaultDirectory) {
        self.directory = directory
        restore()
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("notch-911", isDirectory: true)
            .appendingPathComponent("voice", isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var blobsDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    /// The mic is live *right now*. Paused is deliberately not included: this
    /// is what the meter and the clock ask about.
    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = phase { return true }
        return false
    }

    /// There is a note in progress, running or not. This is the one every
    /// "is the user in the middle of something?" check wants — the hotkey, the
    /// escape key, and every list shortcut the HUD suppresses.
    var isCapturing: Bool { isRecording || isPaused }

    /// Capturing, or still turning what was captured into text. The notch wears
    /// its compact recording shape for the whole of this, so that finishing a
    /// note doesn't snap the panel to list width for the second transcription
    /// takes and then back again.
    var isBusy: Bool { isCapturing || phase == .transcribing }

    /// The current meter reading, 0...1 — zero whenever the mic isn't actually
    /// running, which is what makes the paused indicator sit still.
    var level: Double {
        if case .recording(_, let level) = phase { return level }
        return 0
    }

    /// Fires whenever `isCapturing` changes. The panel has to come on screen for
    /// the collapsed recording indicator and go away again afterwards, and the
    /// coordinator has to know not to open the hover peek over the top of it —
    /// the same shape as `ClipboardStore.onCapture`.
    @ObservationIgnored var onCaptureChange: (() -> Void)?

    /// Elapsed capture, excluding any time spent paused.
    private var elapsed: TimeInterval {
        accumulated + (startedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    // MARK: Recording

    /// Idempotent — the hotkey handler doesn't distinguish "nothing is
    /// recording yet" from "already recording", it just calls the one that
    /// matches `isCapturing`.
    func start() {
        guard phase == .idle else { return }
        Task { await beginRecording() }
    }

    func stop() {
        guard isCapturing else { return }
        finishRecording()
    }

    /// Holds the mic open but stops taking buffers. The engine keeps the tap
    /// and the open file, so resuming appends to the same recording rather than
    /// starting a second one — which is the only version of pause worth having
    /// here, since a note split across two files isn't a note.
    func pause() {
        guard isRecording, let engine else { return }
        engine.pause()
        clockTask?.cancel()
        clockTask = nil
        accumulated = elapsed
        startedAt = nil
        phase = .paused(elapsed: accumulated)
    }

    func resume() {
        guard isPaused, let engine else { return }
        do {
            try engine.start()
        } catch {
            // The mic went away while we were paused — a device change, or the
            // sleep the pause was for. Keep what was captured rather than
            // stranding the user on a HUD whose buttons do nothing.
            log.error("audio engine failed to resume: \(error.localizedDescription, privacy: .public)")
            finishRecording()
            return
        }
        startedAt = Date()
        phase = .recording(elapsed: accumulated, level: 0)
        startClock()
    }

    /// `esc` on the recording HUD, and nowhere else — stopping normally always
    /// keeps what was captured, because a fallback nobody asked to discard is
    /// not a fallback.
    func cancel() {
        guard isCapturing else { return }
        teardownEngine()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        startedAt = nil
        accumulated = 0
        phase = .idle
        onCaptureChange?()
    }

    private func beginRecording() async {
        guard await requestPermissions() else { return }

        try? FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        let url = blobsDirectory.appendingPathComponent("\(UUID().uuidString).caf")

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Whatever the hardware is actually giving us — writing the file in the
        // tap's own format means `AVAudioFile` never has to convert, which is
        // the difference between "just write the buffer" and carrying an
        // `AVAudioConverter` for a feature that doesn't need one.
        let format = input.outputFormat(forBus: 0)

        guard format.channelCount > 0, format.sampleRate > 0,
              let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            log.error("could not open a recording file")
            permission = .microphoneDenied
            return
        }

        // `@Sendable` is load-bearing, not decoration: without it this closure
        // inherits the enclosing `@MainActor` and traps as soon as AVFAudio
        // calls it on its own queue. See `RecordingTap`.
        let tap = RecordingTap(file: file)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            tap.receive(buffer)
        }

        do {
            try engine.start()
        } catch {
            log.error("audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            return
        }

        self.engine = engine
        self.tap = tap
        self.recordingURL = url
        self.startedAt = Date()
        self.accumulated = 0
        phase = .recording(elapsed: 0, level: 0)
        startClock()
        onCaptureChange?()
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                // `startedAt` going nil is the pause: `pause()` cancels this
                // task, but the tick already in flight has to stop too.
                guard let self, self.startedAt != nil else { return }
                let elapsed = self.elapsed
                self.phase = .recording(elapsed: elapsed, level: self.tap?.level ?? 0)
                if elapsed >= Self.maxDuration {
                    self.finishRecording()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finishRecording() {
        guard let url = recordingURL else {
            teardownEngine()
            phase = .idle
            onCaptureChange?()
            return
        }
        // Read before teardown, and from `elapsed` rather than `startedAt`,
        // which is already nil if the note was stopped from paused.
        let duration = elapsed
        teardownEngine()
        recordingURL = nil
        startedAt = nil
        accumulated = 0
        phase = .transcribing
        onCaptureChange?()

        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            let text = await self.transcribe(url: url)
            guard !Task.isCancelled else { return }
            self.save(recordingURL: url, duration: duration, transcript: text)
        }
    }

    private func teardownEngine() {
        clockTask?.cancel()
        clockTask = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        // After `removeTap` no more buffers arrive, so this is the last
        // reference — dropping it closes the recording file.
        tap = nil
    }

    // MARK: Permissions

    /// The microphone is a hard gate — without it there is nothing to record.
    /// Speech recognition is not: a denied or unavailable recognizer still
    /// leaves the recording fallback fully intact, so it is checked but never
    /// blocks `start()`.
    private func requestPermissions() async -> Bool {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micGranted: Bool
        switch micStatus {
        case .authorized:
            micGranted = true
        case .notDetermined:
            micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            micGranted = false
        }
        guard micGranted else {
            permission = .microphoneDenied
            log.notice("microphone access denied")
            return false
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // `@Sendable` for the same reason the audio tap needs it —
                // Speech documents that this handler is *not* delivered on the
                // main queue, so a closure that inherited `@MainActor` from
                // here would trap the first time anyone grants access.
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }

        permission = SFSpeechRecognizer.authorizationStatus() == .authorized ? .ready : .speechDenied
        return true
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    func openSpeechSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Transcription

    /// `nil` means "keep the recording" — covers every way this can fail to
    /// produce text: no recognizer for this locale, on-device unsupported,
    /// permission denied, nothing understood.
    private func transcribe(url: URL) async -> String? {
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { return nil }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        // `recognitionTask`'s handler is `@Sendable` and can fire more than
        // once (a final result, then an end-of-task error) — the same shape as
        // `NWListener`'s state handler in `HookServer.start()`, and the same
        // fix: a lock-guarded flag rather than trusting it only fires once.
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (String?) -> Void = { text in
                let already = resumed.withLock { flag -> Bool in
                    defer { flag = true }
                    return flag
                }
                guard !already else { return }
                continuation.resume(returning: text)
            }

            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(text.isEmpty ? nil : text)
                } else if error != nil {
                    finish(nil)
                }
            }
        }
    }

    // MARK: Notes

    private func save(recordingURL url: URL, duration: TimeInterval, transcript: String?) {
        let note: VoiceNote
        if let transcript {
            // Text is strictly more useful than the audio it came from — it's
            // searchable, pasteable, and a fraction of the size — so once it
            // exists the recording that produced it is redundant.
            try? FileManager.default.removeItem(at: url)
            note = VoiceNote(id: UUID(), createdAt: Date(), duration: duration, content: .transcript(transcript))
        } else {
            note = VoiceNote(
                id: UUID(), createdAt: Date(), duration: duration,
                content: .recording(file: url.lastPathComponent)
            )
        }

        notes.insert(note, at: 0)
        // Trimming the array is only half of it: a dropped recording note still
        // owns a `.caf` on disk, and forgetting it here is how the blobs
        // directory grows without bound behind a list that looks capped.
        while notes.count > Self.maxNotes { discardBlob(of: notes.removeLast()) }
        phase = .idle
        justSaved = note.id
        persist()
        // Transcription is what `isBusy` was still waiting on — the notch can
        // let go of its recording shape now.
        onCaptureChange?()

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard let self, self.justSaved == note.id else { return }
            self.justSaved = nil
        }
    }

    func remove(_ note: VoiceNote) {
        // Stop first: the file is about to be unlinked, and a player left
        // running on a deleted note is audio the user has no way to silence.
        if playingID == note.id { stopPlayback() }
        notes.removeAll { $0.id == note.id }
        discardBlob(of: note)
        persist()
    }

    func removeAll() {
        stopPlayback()
        for note in notes { discardBlob(of: note) }
        notes.removeAll()
        persist()
    }

    /// Unlinks off the main actor, the way `ClipboardStore.discardBlobs` does —
    /// a transcript note has nothing to unlink and returns immediately.
    private func discardBlob(of note: VoiceNote) {
        guard case .recording(let file) = note.content else { return }
        let url = blobsDirectory.appendingPathComponent(file)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Both kinds of note copy, because "copy" is the one thing every row in a
    /// list like this is expected to do. A transcript copies as text; a
    /// recording copies as the file itself, so ⌘V into Mail or Finder attaches
    /// the audio rather than pasting nothing at all.
    func copy(_ note: VoiceNote) {
        let pasteboard = NSPasteboard.general
        switch note.content {
        case .transcript(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .recording(let file):
            let url = blobsDirectory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        }

        justCopied = note.id
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, self.justCopied == note.id else { return }
            self.justCopied = nil
        }
    }

    /// Recording-only, since a transcript note has no audio left to play — the
    /// whole point of promoting text was that the recording it came from didn't
    /// need to stick around. Pressing play on whatever is already playing stops
    /// it, so one control covers both directions.
    func togglePlayback(_ note: VoiceNote) {
        guard case .recording(let file) = note.content else { return }
        guard playingID != note.id else {
            stopPlayback()
            return
        }
        stopPlayback()

        let url = blobsDirectory.appendingPathComponent(file)
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            log.error("could not open a recording for playback")
            return
        }
        let id = note.id
        let observer = PlaybackObserver { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.playingID == id else { return }
                self.stopPlayback()
            }
        }
        player.delegate = observer
        self.playbackObserver = observer
        self.player = player
        playingID = id
        player.play()
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playbackObserver = nil
        playingID = nil
    }

    // MARK: Persistence

    private struct ManifestEntry: Codable {
        let id: UUID
        let createdAt: Date
        let duration: Double
        var transcript: String?
        var recordingFile: String?
    }

    private struct Manifest: Codable {
        var version: Int
        var entries: [ManifestEntry]
    }

    private func persist() {
        let entries = notes.map { note -> ManifestEntry in
            switch note.content {
            case .transcript(let text):
                return ManifestEntry(
                    id: note.id, createdAt: note.createdAt, duration: note.duration,
                    transcript: text, recordingFile: nil
                )
            case .recording(let file):
                return ManifestEntry(
                    id: note.id, createdAt: note.createdAt, duration: note.duration,
                    transcript: nil, recordingFile: file
                )
            }
        }
        let manifest = Manifest(version: Self.manifestVersion, entries: entries)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return }

        notes = manifest.entries.compactMap { entry in
            if let transcript = entry.transcript {
                return VoiceNote(
                    id: entry.id, createdAt: entry.createdAt, duration: entry.duration,
                    content: .transcript(transcript)
                )
            }
            if let file = entry.recordingFile,
               FileManager.default.fileExists(atPath: blobsDirectory.appendingPathComponent(file).path) {
                return VoiceNote(
                    id: entry.id, createdAt: entry.createdAt, duration: entry.duration,
                    content: .recording(file: file)
                )
            }
            // Neither a transcript nor a recording still on disk — the blob was
            // cleaned up from under the manifest somehow. Drop the row rather
            // than show a note that plays nothing and copies nothing.
            return nil
        }
        sweepOrphanBlobs()
    }

    /// The other direction from the drop above: recordings on disk that no note
    /// refers to. A crash between the tap opening the file and the note being
    /// saved leaves one every time, and `cancel()` on the way out of the app is
    /// a best-effort unlink — without a sweep, a few interrupted recordings a
    /// week accumulate as megabytes nothing will ever play.
    private func sweepOrphanBlobs() {
        let referenced = Set(notes.compactMap { note -> String? in
            guard case .recording(let file) = note.content else { return nil }
            return file
        })
        let blobs = blobsDirectory
        // A recording in flight is written into this directory while the sweep
        // runs, and it is by definition unreferenced until it's saved. Same
        // guard `ClipboardStore.sweepOrphanBlobs` uses: anything newer than the
        // snapshot is left for next launch.
        let cutoff = Date()
        Task.detached(priority: .utility) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: blobs,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for url in contents where !referenced.contains(url.lastPathComponent) {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                guard let created, created < cutoff else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
