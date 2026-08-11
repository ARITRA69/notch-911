//
//  ClipboardHistory.swift
//  notch-911
//
//  The last thirty things you copied, kept where the notch can hand them back.
//  Text, images and files; newest first; survives a relaunch.
//
//  Two things here are load-bearing and easy to undo by accident:
//
//  1. Marker types are checked *before* any byte is read. Password managers
//     stamp `org.nspasteboard.ConcealedType` on their writes, and reading a
//     concealed payload and then discarding it still means it was in our heap,
//     in a crash log, and possibly in a swap file. Types first, always.
//  2. Files are stored as *paths*, unlike the shelf next door, which copies.
//     The shelf copies because drags out of browsers and Mail hand over temp
//     files that vanish. A Finder ⌘C hands over a real, stable URL, and quietly
//     duplicating a 4 GB video into Application Support on every copy would be
//     indefensible. The cost is that a file clip can go stale — handled at
//     restore, dimmed in the view.
//

import AppKit
import CryptoKit
import Foundation
import Observation
import os

// MARK: - Model

nonisolated enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case files

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc"
        }
    }

    var label: String {
        switch self {
        case .text: "Text"
        case .image: "Image"
        case .files: "File"
        }
    }
}

/// Provenance, stored as identifiers rather than as anything renderable. An
/// `NSImage` on this struct would break `Sendable` *and* balloon the manifest;
/// the icon is resolved once per bundle id into a main-actor cache instead.
nonisolated struct ClipSource: Codable, Sendable, Hashable {
    let bundleID: String
    let name: String
}

nonisolated struct ClipItem: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let kind: ClipKind

    /// SHA-256 over a kind-tagged canonicalisation of the content. Deliberately
    /// *not* `hashValue`: Swift seeds `Hasher` per process, so a digest written
    /// on Monday matches nothing on Tuesday and every restored item would look
    /// new on the next launch.
    let fingerprint: String

    let firstCopiedAt: Date
    var lastCopiedAt: Date
    var copyCount: Int
    var source: ClipSource?
    /// Drives the byte budget. Text: UTF-8 count. Image: blob size. Files: 0 —
    /// file clips store paths, not bytes.
    let byteCount: Int

    // Payload. Exactly one group is populated per `kind`. Flat optionals rather
    // than an enum with associated values on purpose: synthesised `Codable` for
    // such an enum produces a nested keyed shape that breaks the moment a case
    // is added, and this file has to survive being read by an older build.
    //
    // Blob fields hold *filenames*, never absolute paths — a manifest full of
    // `/Users/…` is worthless the moment the directory moves or a test points
    // the store at a temp dir.
    var text: String?
    var textBlob: String?
    var imageBlob: String?
    var imageType: String?
    var thumbnailBlob: String?
    var filePaths: [String]?

    var urls: [URL] { (filePaths ?? []).map { URL(fileURLWithPath: $0) } }
}

// MARK: - Capture

/// The pure seam. Everything AppKit-shaped is flattened into `Sendable` values
/// on the main actor first; every decision after that is a plain function, which
/// is what lets the whole capture path be tested without a live pasteboard.
nonisolated enum ClipboardCapture {

    /// One `NSPasteboard` read, flattened. `NSPasteboardItem` is a class and is
    /// not `Sendable`, so it never leaves the main actor — this does.
    struct Snapshot: Sendable {
        /// The union of the board's own types and every item's types.
        var types: [String] = []
        /// Type string → bytes, unioned across items. Only the types the
        /// priority list below actually wants are ever pulled; there is no
        /// reason to copy an app's private 40 MB internal type into a `Data`.
        var data: [String: Data] = [:]
        /// Resolved with `readObjects(forClasses:options:)`, which walks every
        /// item — per-item `data(forType:)` would only ever see the first file.
        var fileURLs: [URL] = []
        /// `org.nspasteboard.source`, when the copying app bothered to set it.
        var declaredSource: String?

        init() {}
    }

    enum Content: Sendable, Equatable {
        case text(String)
        case image(data: Data, type: String)
        case files([URL])
    }

    struct Limits: Sendable {
        var maxTextBytes = 4 * 1024 * 1024
        var maxImageBytes = 16 * 1024 * 1024
        /// Checked *before* decoding. A 6K screenshot arrives as ~100 MB of
        /// uncompressed TIFF; handing that to `NSBitmapImageRep` first would
        /// spike a hundred megabytes of RSS just to find out it's too big.
        var maxSourceImageBytes = 64 * 1024 * 1024

        init() {}
        static let `default` = Limits()
    }

    // MARK: Exclusions

    /// The nspasteboard.org convention: an app that puts a secret on the
    /// pasteboard adds a marker type asking clipboard managers not to record it.
    /// It is a convention, not an API — there is no enforcement — so this is
    /// data, and adding to it is a one-line change.
    static let excludedTypes: Set<String> = [
        // Current convention (nspasteboard.org).
        "org.nspasteboard.ConcealedType",        // passwords and other secrets
        "org.nspasteboard.TransientType",        // not meant to be recorded
        "org.nspasteboard.AutoGeneratedType",    // written by another clipboard tool

        // Legacy markers still emitted by older apps.
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",

        // Vendor markers that predate the convention.
        "com.agilebits.onepassword",
        "net.antelle.keeweb",
    ]

    static func isExcluded(types: [String]) -> Bool {
        types.contains { excludedTypes.contains($0) }
    }

    static func isExcluded(_ snapshot: Snapshot) -> Bool {
        isExcluded(types: snapshot.types)
    }

    // MARK: Type priority

    /// Types we are willing to pull bytes for, in the order they win.
    ///
    /// Finder puts a file URL *and* a plain-text filename on the board — the
    /// file is the intent, the string is a convenience. TIFF is what screenshots
    /// and most AppKit apps write and is uncompressed, so it is normalised to
    /// PNG rather than stored as-is; thirty unconverted screenshots would be
    /// gigabytes.
    ///
    /// Deliberately absent: `public.rtf`, `public.rtfd`, `public.html`.
    /// Capturing those would mean a fourth kind and a rich-text renderer inside
    /// a notch panel, and every one of those copies also carries plain text — so
    /// nothing is lost but formatting, which is what "paste as plain text"
    /// wanted anyway.
    static let fileURLType = "public.file-url"
    static let pngType = "public.png"
    static let tiffType = "public.tiff"
    static let plainTextType = "public.utf8-plain-text"
    static let urlType = "public.url"

    /// Types worth reading bytes for. `fileURLType` is absent because file URLs
    /// come from `readObjects`, not from `data(forType:)`.
    static let interestingTypes = [pngType, tiffType, plainTextType, urlType]

    static func content(from snapshot: Snapshot, limits: Limits = .default) -> Content? {
        guard !isExcluded(snapshot) else { return nil }

        if !snapshot.fileURLs.isEmpty {
            return .files(snapshot.fileURLs)
        }

        if let png = snapshot.data[pngType] {
            guard png.count <= limits.maxImageBytes else { return nil }
            return .image(data: png, type: pngType)
        }

        if let tiff = snapshot.data[tiffType] {
            guard let normalized = ClipboardImage.normalize(tiff, limits: limits) else { return nil }
            return .image(data: normalized, type: pngType)
        }

        if let string = text(from: snapshot, key: plainTextType, limits: limits) {
            return .text(string)
        }

        // Some apps write only a URL. Treat it as text — it's what you'd paste.
        if let string = text(from: snapshot, key: urlType, limits: limits) {
            return .text(string)
        }

        return nil
    }

    private static func text(from snapshot: Snapshot, key: String, limits: Limits) -> String? {
        guard let data = snapshot.data[key], data.count <= limits.maxTextBytes else { return nil }
        let string = String(decoding: data, as: UTF8.self)
        // Plenty of apps write an empty string as a side effect of a selection
        // change. Test the trimmed value, keep the untrimmed one — leading
        // indentation in a copied code block is content, not noise.
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    // MARK: Fingerprint

    /// Domain-separated, so a text clip whose content happens to be a path can
    /// never collide with a file clip pointing at that path.
    ///
    /// Text is hashed exactly as copied: `"foo"` and `"foo\n"` are genuinely
    /// different pastes, and merging them would surprise anyone pasting into a
    /// shell. File order is preserved rather than sorted — paste order matters.
    static func fingerprint(_ content: Content) -> String {
        var preimage: Data
        switch content {
        case .text(let string):
            preimage = Data("text:".utf8) + Data(string.utf8)
        case .image(let data, let type):
            preimage = Data("image:\(type):".utf8) + data
        case .files(let urls):
            preimage = Data("files:".utf8)
                + Data(urls.map(\.path).joined(separator: "\n").utf8)
        }
        return SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Images

nonisolated enum ClipboardImage {

    /// Everything becomes PNG. TIFF off the pasteboard is uncompressed and
    /// enormous, and the history would be measured in gigabytes otherwise.
    static func normalize(_ data: Data, limits: ClipboardCapture.Limits) -> Data? {
        // Size-check before decoding, then again after re-encoding.
        guard data.count <= limits.maxSourceImageBytes,
              let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]),
              png.count <= limits.maxImageBytes
        else { return nil }
        return png
    }

    /// Longest-edge downscale for the row preview, so a restore decodes thirty
    /// 128px PNGs instead of thirty full screenshots — and so the eager row list
    /// isn't drawing full-resolution images thirty times a frame.
    static func thumbnail(_ data: Data, maxEdge: CGFloat = 128) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let width = CGFloat(rep.pixelsWide)
        let height = CGFloat(rep.pixelsHigh)
        guard width > 0, height > 0 else { return nil }

        let scale = min(1, maxEdge / max(width, height))
        // Already small enough — re-encoding would only lose quality.
        guard scale < 1 else { return rep.representation(using: .png, properties: [:]) }

        let target = NSSize(width: max(1, (width * scale).rounded()),
                            height: max(1, (height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: Int(target.width),
            height: Int(target.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let source = rep.cgImage else { return nil }

        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(origin: .zero, size: target))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}

// MARK: - Manifest

nonisolated struct ClipboardManifest: Codable, Sendable {
    var version: Int
    var items: [ClipItem]

    init(version: Int, items: [ClipItem]) {
        self.version = version
        self.items = items
    }

    enum CodingKeys: String, CodingKey { case version, items }

    /// Decodes each entry independently. A plain `[ClipItem]` decode is
    /// all-or-nothing, so one record written by a newer build — or truncated
    /// mid-write — would cost the user the other twenty-nine.
    ///
    /// The wrapper *cannot* throw, and that matters: a bare `try?` around an
    /// element decode inside an `UnkeyedDecodingContainer` leaves `currentIndex`
    /// in an implementation-defined state, whereas an initialiser that always
    /// succeeds keeps the container advancing correctly.
    private struct Lenient: Decodable {
        let item: ClipItem?
        init(from decoder: any Decoder) throws {
            item = try? ClipItem(from: decoder)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        items = try container.decode([Lenient].self, forKey: .items).compactMap(\.item)
    }
}

// MARK: - Store

@MainActor
@Observable
final class ClipboardStore {

    // `nonisolated` because `prepare` runs off the main actor and needs the
    // limits, and because the views and tests read them freely.

    /// Thirty. Past that a history stops being something you scan and becomes
    /// something you search, which is a different feature.
    nonisolated static let maxItems = 30
    /// 256 MB across the whole history. The count cap alone would allow thirty
    /// 16 MB screenshots — a quarter of a gigabyte the user never agreed to.
    nonisolated static let maxTotalBytes = 256 * 1024 * 1024
    /// Short text lives in the manifest. A dedicated file per "ok" is silly.
    nonisolated static let inlineTextLimit = 16 * 1024
    nonisolated static let manifestVersion = 1
    nonisolated static let captureDefaultsKey = "notchd.clipboardHistory"

    /// NSPasteboard has no change notification of any kind — no KVO, no
    /// NSNotification. Polling `changeCount` is the only route, and every
    /// clipboard manager on the platform does the same.
    ///
    /// 500ms. Steady state is one `changeCount` read per tick, a single cheap
    /// round-trip to the pasteboard server and nothing else, because the
    /// expensive path only runs when the count actually moves. The interval
    /// doesn't decide what gets *missed* — only the newest contents exist to be
    /// read — it decides how many intermediate copies get collapsed. At 1s,
    /// copying three things quickly records one. Below ~250ms there is nothing
    /// left to win.
    static let pollInterval: Duration = .milliseconds(500)

    private(set) var items: [ClipItem] = []
    private(set) var thumbnails: [UUID: NSImage] = [:]
    private(set) var sourceIcons: [String: NSImage] = [:]

    // Everything a row needs to draw itself, computed once per item instead of
    // once per render. A row's body runs on every hover, and these are all
    // things that must never be on that path: `icon(forFile:)` is a Launch
    // Services round trip, `fileExists` is a disk stat, and `preview` walks and
    // rewrites the string. Thirty rows re-rendering per pointer move made the
    // list visibly stick.
    private(set) var fileIcons: [UUID: NSImage] = [:]
    private(set) var previews: [UUID: String] = [:]
    private(set) var staleIDs: Set<UUID> = []
    private(set) var isCapturing = false
    /// Set briefly after a write-back so the row can acknowledge the click.
    private(set) var justCopied: UUID?
    /// Set briefly after a *capture*, so the collapsed notch can flash an
    /// acknowledgement that the copy landed. Distinct from `justCopied`, which
    /// acknowledges a click inside the open card — this one fires when you press
    /// ⌘C anywhere on the Mac and the notch is closed.
    private(set) var justCaptured = false

    /// Fires on both edges of `justCaptured`, so the panel can come on screen
    /// for the flash and go away after it. The badge is the only thing that
    /// would be showing, so without this the panel is ordered out and there is
    /// nothing to see.
    @ObservationIgnored var onCapture: (() -> Void)?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var captureFlashTask: Task<Void, Never>?
    @ObservationIgnored
    private let log = Logger(subsystem: "com.aritra360.notch-911", category: "Clipboard")

    /// The directory is injectable purely so the tests get a temp dir —
    /// `ShelfStore` hardcodes its path, which is exactly why it has none. The
    /// precedent is `CodexPlanQuestionWatcher(homeDirectory:)`.
    init(directory: URL = ClipboardStore.defaultDirectory) {
        self.directory = directory
        restore()
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("notch-911", isDirectory: true)
            .appendingPathComponent("clipboard", isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var blobsDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    // MARK: Lifecycle

    /// `init` restores but never polls, so every unit test — and the XCTest host
    /// itself — is inert without any special-casing.
    func setCapturing(_ enabled: Bool) {
        guard enabled != isCapturing else { return }
        isCapturing = enabled
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        guard isCapturing else { return }
        // Re-seed rather than carrying the count across a disabled stretch, so
        // switching capture back on doesn't retroactively hoover up whatever was
        // copied while it was off. Same reasoning at launch: quietly recording a
        // possibly-sensitive pasteboard nobody offered us is the wrong default.
        lastChangeCount = NSPasteboard.general.changeCount
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    // MARK: Capture

    private func tick() async {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        // Claimed before the await below. The loop is serial so re-entrancy
        // can't happen today, but leaving a window here is how it would.
        lastChangeCount = count

        guard let snapshot = readSnapshot(pasteboard) else { return }
        let source = resolveSource(declared: snapshot.declaredSource)
        let directory = self.directory

        // Normalising a 6K screenshot to PNG and hashing 16 MB is 100–300ms of
        // work. On the main actor that is a visible hitch in the notch's springs,
        // so it goes off-actor — only `Sendable` values cross.
        let prepared = await Task.detached(priority: .utility) {
            guard let content = ClipboardCapture.content(from: snapshot) else { return nil as ClipItem? }
            return ClipboardStore.prepare(content, source: source, in: directory)
        }.value

        guard let prepared else { return }
        record(prepared)
    }

    /// Flattens the pasteboard into a `Sendable` snapshot.
    ///
    /// The exclusion check runs against the type list alone, before a single
    /// `data(forType:)`. And the type list is the *union* of the board's types
    /// and every item's: `pasteboard.types` reports only the first item, so a
    /// marker sitting on a later item of a multi-item copy would sail straight
    /// past a check that trusted it.
    private func readSnapshot(_ pasteboard: NSPasteboard) -> ClipboardCapture.Snapshot? {
        let items = pasteboard.pasteboardItems ?? []
        let types = (pasteboard.types ?? []).map(\.rawValue)
            + items.flatMap { $0.types.map(\.rawValue) }
        guard !ClipboardCapture.isExcluded(types: types) else { return nil }

        var snapshot = ClipboardCapture.Snapshot()
        snapshot.types = types
        snapshot.declaredSource = pasteboard.string(
            forType: NSPasteboard.PasteboardType("org.nspasteboard.source")
        )

        // The only call that correctly picks up every URL from a multi-file copy.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            snapshot.fileURLs = urls
        }

        if snapshot.fileURLs.isEmpty {
            for type in ClipboardCapture.interestingTypes where types.contains(type) {
                if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) {
                    snapshot.data[type] = data
                }
            }
        }
        return snapshot
    }

    /// `frontmostApplication` is a heuristic, and it's worth being honest about
    /// where it's wrong: up to 500ms elapses between ⌘C and this read, so a fast
    /// ⌘-Tab misattributes; and a copy from a background script (`pbcopy`, an
    /// Automator action) is credited to whatever the user happened to be looking
    /// at. `org.nspasteboard.source` wins when present because it's the copying
    /// app saying so directly, but almost nothing sets it.
    private func resolveSource(declared: String?) -> ClipSource? {
        if let declared, !declared.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: declared).first,
           let bundleID = app.bundleIdentifier {
            return ClipSource(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              // Our own write-backs are already suppressed by `lastChangeCount`,
              // but "copied from notch-911" would be a confusing thing to see.
              bundleID != Bundle.main.bundleIdentifier
        else { return nil }
        return ClipSource(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }

    /// Blobs are written here, off the main actor, before the item exists. On a
    /// dedupe hit the caller deletes them again — one wasted write on the rare
    /// path, in exchange for a single hop instead of hash-then-write-then-insert.
    nonisolated static func prepare(
        _ content: ClipboardCapture.Content,
        source: ClipSource?,
        in directory: URL
    ) -> ClipItem? {
        let id = UUID()
        let now = Date()
        let fingerprint = ClipboardCapture.fingerprint(content)
        let blobs = directory.appendingPathComponent("blobs", isDirectory: true)

        switch content {
        case .text(let string):
            let bytes = string.utf8.count
            var item = ClipItem(
                id: id, kind: .text, fingerprint: fingerprint,
                firstCopiedAt: now, lastCopiedAt: now, copyCount: 1,
                source: source, byteCount: bytes
            )
            if bytes <= inlineTextLimit {
                item.text = string
            } else {
                let name = "\(id.uuidString).txt"
                guard write(Data(string.utf8), named: name, in: blobs) else { return nil }
                item.textBlob = name
                // Keep a truncated copy inline so the row renders without
                // touching disk. The blob is the source of truth for pasting.
                item.text = String(string.prefix(512))
            }
            return item

        case .image(let data, let type):
            let name = "\(id.uuidString).png"
            guard write(data, named: name, in: blobs) else { return nil }
            var item = ClipItem(
                id: id, kind: .image, fingerprint: fingerprint,
                firstCopiedAt: now, lastCopiedAt: now, copyCount: 1,
                source: source, byteCount: data.count
            )
            item.imageBlob = name
            item.imageType = type
            if let thumb = ClipboardImage.thumbnail(data) {
                let thumbName = "\(id.uuidString)-thumb.png"
                if write(thumb, named: thumbName, in: blobs) { item.thumbnailBlob = thumbName }
            }
            return item

        case .files(let urls):
            guard !urls.isEmpty else { return nil }
            var item = ClipItem(
                id: id, kind: .files, fingerprint: fingerprint,
                firstCopiedAt: now, lastCopiedAt: now, copyCount: 1,
                source: source, byteCount: 0
            )
            item.filePaths = urls.map(\.path)
            return item
        }
    }

    @discardableResult
    private nonisolated static func write(_ data: Data, named name: String, in blobs: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
            try data.write(to: blobs.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Bookkeeping

    /// The collapsed notch flashes for ~1.2s after a capture. Long enough to
    /// register out of the corner of your eye on the way back to the keyboard,
    /// short enough that copying repeatedly doesn't leave a badge parked in the
    /// menu bar. A fresh copy restarts the timer rather than queueing.
    static let captureFlashMilliseconds = 1200

    private func flashCaptured() {
        captureFlashTask?.cancel()
        justCaptured = true
        onCapture?()
        captureFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.captureFlashMilliseconds))
            guard !Task.isCancelled else { return }
            self?.justCaptured = false
            self?.onCapture?()
        }
    }

    /// Pure main-actor bookkeeping, which is what makes it testable without a
    /// pasteboard anywhere in sight.
    func record(_ item: ClipItem) {
        // Fires for a dedupe hit too: re-copying something is still a copy, and
        // a badge that appeared for new clips but not familiar ones would read
        // as the app having missed it. Our own write-backs never reach here —
        // `copy()` claims the change count — so clicking a row can't flash.
        defer { flashCaptured() }

        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            // Move to top, keeping the *existing* id. That keeps the thumbnail
            // cache warm and — more importantly — keeps SwiftUI's ForEach
            // identity stable, so the row slides up from where it was instead of
            // the whole list cross-fading. The blobs `prepare` just wrote are
            // byte-identical to the ones already on disk by definition of the
            // fingerprint, so they go — *unless* the existing item's blob has
            // gone missing since, in which case re-copying the same content is
            // the user's natural attempt to repair it and throwing away the good
            // bytes would keep the broken row instead.
            var existing = items.remove(at: index)
            if hasIntactPayload(existing) {
                discardBlobs(of: item)
            } else {
                discardBlobs(of: existing)
                existing.textBlob = item.textBlob
                existing.imageBlob = item.imageBlob
                existing.imageType = item.imageType
                existing.thumbnailBlob = item.thumbnailBlob
                existing.text = item.text
                loadThumbnail(for: existing)
            }
            existing.lastCopiedAt = item.lastCopiedAt
            existing.copyCount += 1
            existing.source = item.source
            items.insert(existing, at: 0)
            scheduleSave()
            return
        }

        items.insert(item, at: 0)
        evict()
        index(item)
        loadThumbnail(for: item)
        loadSourceIcon(for: item)
        refreshFileStates()
        scheduleSave()
    }

    /// Two ceilings, one loop: thirty is the number the *list* wants, 256 MB is
    /// the number the *disk* wants, and thirty screenshots blow through the
    /// second long before they reach the first.
    private func evict() {
        var total = items.reduce(0) { $0 + $1.byteCount }
        while items.count > Self.maxItems || (total > Self.maxTotalBytes && items.count > 1) {
            let dropped = items.removeLast()
            total -= dropped.byteCount
            forget(dropped)
        }
    }

    // Deletions save *now*, not on the 750ms debounce. Losing a capture to a
    // hard kill inside that window is a fair trade for coalescing bursts;
    // losing a deletion is the opposite trade. The blobs are unlinked
    // immediately, but an inline-text item has no blob to go missing — so a
    // crash before the debounced write would bring cleared history back on the
    // next launch, which is exactly the thing a Clear button must never do.

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        forget(item)
        flush()
    }

    func removeAll() {
        for item in items { forget(item) }
        items.removeAll()
        thumbnails.removeAll()
        fileIcons.removeAll()
        previews.removeAll()
        staleIDs.removeAll()
        flush()
    }

    private func forget(_ item: ClipItem) {
        thumbnails[item.id] = nil
        fileIcons[item.id] = nil
        previews[item.id] = nil
        staleIDs.remove(item.id)
        discardBlobs(of: item)
    }

    /// A 16 MB unlink has no business on the main actor.
    private func discardBlobs(of item: ClipItem) {
        let urls = [item.textBlob, item.imageBlob, item.thumbnailBlob]
            .compactMap { $0 }
            .map { blobsDirectory.appendingPathComponent($0) }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Write-back

    /// Returns false when the payload could not be resolved and the pasteboard
    /// was left untouched.
    @discardableResult
    func copy(_ item: ClipItem) -> Bool {
        // Resolve *before* clearing. `clearContents()` destroys whatever the
        // user already had, so discovering a missing blob afterwards would
        // replace their pasteboard with nothing and still flash "Copied" — the
        // worst of both. A row that can't be restored should leave the
        // pasteboard exactly as it was.
        var payload: (data: Data, type: NSPasteboard.PasteboardType)?
        switch item.kind {
        case .text:
            guard let text = fullText(of: item) else { return false }
            payload = (Data(text.utf8), .string)
        case .image:
            guard let data = blobData(item.imageBlob) else { return false }
            payload = (
                data,
                NSPasteboard.PasteboardType(item.imageType ?? ClipboardCapture.pngType)
            )
        case .files:
            guard !item.urls.isEmpty else { return false }
            payload = nil   // written through `writeObjects` below
        }

        let pasteboard = NSPasteboard.general
        // `clearContents()` returns the new change count and is the *only* call
        // in this write that bumps it — the `setData` calls below do not.
        // Claiming it here is the whole mechanism for not re-capturing our own
        // write. Leaning on dedupe instead would technically work, but it would
        // refresh the timestamp and re-attribute the source app on every paste,
        // which is worse than one assignment.
        lastChangeCount = pasteboard.clearContents()

        if let payload {
            pasteboard.setData(payload.data, forType: payload.type)
        } else {
            pasteboard.writeObjects(item.urls as [NSURL])
        }

        // Good citizenship, and a second line of defence: the convention says a
        // clipboard manager replaying content should mark it auto-generated so
        // *other* managers don't record the replay as a fresh copy. Written last
        // because `writeObjects` appends items — `setData(forType:)` then adds
        // the type to the existing item rather than resetting the board.
        pasteboard.setData(
            Data(),
            forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        )
        lastChangeCount = pasteboard.changeCount

        flashCopied(item.id)
        return true
    }

    private func flashCopied(_ id: UUID) {
        flashTask?.cancel()
        justCopied = id
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.justCopied = nil
        }
    }

    /// The blob is the source of truth for long text; `item.text` is only a
    /// 512-character preview in that case and pasting it would be a silent lie —
    /// a truncated document that looks like it worked. So an item that *has* a
    /// blob resolves from the blob or not at all; only a blob-less item falls
    /// back to the inline string, where the inline string is the whole thing.
    private func fullText(of item: ClipItem) -> String? {
        guard let blob = item.textBlob else { return item.text }
        guard let data = blobData(blob) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func blobData(_ name: String?) -> Data? {
        guard let name else { return nil }
        return try? Data(contentsOf: blobsDirectory.appendingPathComponent(name))
    }

    // MARK: Presentation helpers

    func sourceIcon(for item: ClipItem) -> NSImage? {
        guard let bundleID = item.source?.bundleID else { return nil }
        return sourceIcons[bundleID]
    }

    /// The cached row previews. All three of these are dictionary lookups on
    /// purpose — see `previews` for why nothing here may touch disk.
    func preview(for item: ClipItem) -> String {
        previews[item.id] ?? Self.preview(for: item)
    }

    /// Image thumbnail for image clips, Finder icon for file clips, nil for text.
    func rowImage(for item: ClipItem) -> NSImage? {
        thumbnails[item.id] ?? fileIcons[item.id]
    }

    func isStale(_ item: ClipItem) -> Bool { staleIDs.contains(item.id) }

    /// Fills the per-item caches. Called when an item arrives and on restore,
    /// never from a view body.
    private func index(_ item: ClipItem) {
        previews[item.id] = Self.preview(for: item)
        if item.kind == .files, let url = item.urls.first {
            fileIcons[item.id] = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    /// Re-checks which file clips have gone missing. Cheap enough to run
    /// whenever a clipboard surface opens, and deliberately *not* per render:
    /// staleness is disk state, so it costs a stat() per path.
    func refreshFileStates() {
        let probe = items.filter { $0.kind == .files }.map { ($0.id, $0.urls) }
        guard !probe.isEmpty else {
            if !staleIDs.isEmpty { staleIDs = [] }
            return
        }
        Task { [weak self] in
            let stale = await Task.detached(priority: .utility) {
                Set(
                    probe
                        .filter { _, urls in
                            urls.contains { !FileManager.default.fileExists(atPath: $0.path) }
                        }
                        .map(\.0)
                )
            }.value
            guard let self, stale != staleIDs else { return }
            staleIDs = stale
        }
    }

    /// The first line, trimmed, for the row. Files show names; images show a
    /// dimension-free label because the thumbnail already says what it is.
    nonisolated static func preview(for item: ClipItem) -> String {
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            let condensed = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            return condensed.isEmpty ? "(blank)" : String(condensed.prefix(300))
        case .image:
            return "Image"
        case .files:
            let names = item.urls.map(\.lastPathComponent)
            if names.count == 1 { return names[0] }
            return "\(names.count) files — \(names.prefix(2).joined(separator: ", "))"
        }
    }

    /// Computed at render time, never stored: a `isStale` field on the model
    /// would be wrong the instant it was written.
    nonisolated static func isStale(_ item: ClipItem) -> Bool {
        guard item.kind == .files else { return false }
        return item.urls.contains { !FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Thumbnails and icons

    private func loadThumbnail(for item: ClipItem) {
        guard item.kind == .image, let name = item.thumbnailBlob ?? item.imageBlob else { return }
        let url = blobsDirectory.appendingPathComponent(name)
        Task { [weak self] in
            // `NSImage` isn't Sendable, so the decode has to land back here —
            // only the bytes cross.
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url)
            }.value
            guard let data, let image = NSImage(data: data) else { return }
            self?.thumbnails[item.id] = image
        }
    }

    /// Memoized per bundle id, not per item: the lookup hits Launch Services and
    /// there is no reason to do it thirty times for thirty clips out of Safari.
    private func loadSourceIcon(for item: ClipItem) {
        guard let bundleID = item.source?.bundleID, sourceIcons[bundleID] == nil else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        sourceIcons[bundleID] = NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: Persistence

    /// Coalesced. The manifest is cheap enough to write eagerly — this exists
    /// for bursts: holding ⌘C, or an app that rewrites the pasteboard several
    /// times a second. The cost is a 750ms window where a hard kill loses the
    /// last copy, which for a clipboard history is fine; `shutDown()` closes the
    /// ordinary case.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard let data = try? Self.encoder().encode(
            ClipboardManifest(version: Self.manifestVersion, items: items)
        ) else { return }
        let url = manifestURL
        let directory = self.directory
        // Encode on the main actor (it needs `items`), write off it — `Data` is
        // Sendable, so the hop is free.
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Cancels the debounce and writes synchronously. Called from
    /// `AppModel.shutDown()`, which `applicationWillTerminate` already invokes.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? Self.encoder().encode(
            ClipboardManifest(version: Self.manifestVersion, items: items)
        ) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Pretty and sorted so the file is readable when something goes wrong.
        // Thirty records with inline text is single-digit kilobytes; legibility
        // is free at that size.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Must match the encoder or every restore fails at the first date.
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func restore() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }   // first run
        guard let manifest = try? Self.decoder().decode(ClipboardManifest.self, from: data) else {
            // Don't try to salvage and don't delete: the next save replaces it,
            // and leaving the bad file on disk means it's still there to look at
            // when someone reports the bug.
            log.error("clipboard manifest unreadable — starting empty")
            return
        }
        guard manifest.version <= Self.manifestVersion else {
            // A newer build wrote this. Restoring partially and then saving would
            // silently downgrade it and destroy whatever the new fields held.
            log.error("clipboard manifest is version \(manifest.version, privacy: .public) — leaving it alone")
            return
        }

        items = Array(manifest.items.filter(hasIntactPayload).prefix(Self.maxItems))
        sweepOrphanBlobs()
        for item in items {
            index(item)
            loadThumbnail(for: item)
            loadSourceIcon(for: item)
        }
        refreshFileStates()
    }

    private func hasIntactPayload(_ item: ClipItem) -> Bool {
        let exists: (String?) -> Bool = { name in
            guard let name else { return false }
            return FileManager.default.fileExists(
                atPath: self.blobsDirectory.appendingPathComponent(name).path
            )
        }
        switch item.kind {
        case .text:
            // Inline text is always intact; a promised blob has to be there.
            if item.textBlob != nil { return exists(item.textBlob) }
            return item.text != nil
        case .image:
            // A missing thumbnail is survivable — it regenerates. A missing
            // image blob leaves a row with no content at all.
            return exists(item.imageBlob)
        case .files:
            // A row that puts dead URLs on the pasteboard is worse than no row,
            // but a partially-moved multi-file copy is still worth keeping.
            return item.urls.contains { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// Covers a crash between the blob write and the debounced manifest write, an
    /// eviction whose delete was lost, and manual meddling. Blobs are also
    /// deleted eagerly everywhere else — this is belt and braces, not the
    /// primary mechanism.
    private func sweepOrphanBlobs() {
        let referenced = Set(items.flatMap { [$0.textBlob, $0.imageBlob, $0.thumbnailBlob] }.compactMap { $0 })
        let blobs = blobsDirectory
        // `referenced` is a snapshot, and after a crash this sweep can be a
        // directory listing plus a pile of 16 MB unlinks — slow enough to still
        // be running when the first capture lands. A blob written after the
        // sweep started isn't in the snapshot and would be deleted out from
        // under the item that is about to reference it, so anything newer than
        // this cutoff is left alone; it will be collected next launch if it
        // really is an orphan.
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
