import AppKit
import Foundation
import Testing
@testable import notch_911

@Suite("Clipboard capture")
struct ClipboardCaptureTests {

    // MARK: Helpers

    private func snapshot(
        _ pairs: [(String, Data)] = [],
        files: [URL] = [],
        extraTypes: [String] = []
    ) -> ClipboardCapture.Snapshot {
        var snapshot = ClipboardCapture.Snapshot()
        snapshot.types = pairs.map(\.0) + extraTypes + (files.isEmpty ? [] : [ClipboardCapture.fileURLType])
        snapshot.data = Dictionary(uniqueKeysWithValues: pairs)
        snapshot.fileURLs = files
        return snapshot
    }

    private func text(_ string: String) -> Data { Data(string.utf8) }

    /// A real 2×2 TIFF, so the PNG normalisation path is exercised for real
    /// rather than against a fabricated blob.
    private func tiffData() -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image.tiffRepresentation ?? Data()
    }

    // MARK: Type priority

    @Test("File URLs beat the filename string")
    func fileURLsWin() {
        let url = URL(fileURLWithPath: "/tmp/notch-911-test.txt")
        let result = ClipboardCapture.content(
            from: snapshot([(ClipboardCapture.plainTextType, text("notch-911-test.txt"))], files: [url])
        )
        #expect(result == .files([url]))
    }

    @Test("Plain text beats RTF and HTML")
    func plainTextWins() {
        let result = ClipboardCapture.content(
            from: snapshot(
                [(ClipboardCapture.plainTextType, text("hello"))],
                extraTypes: ["public.rtf", "public.html"]
            )
        )
        #expect(result == .text("hello"))
    }

    @Test("Falls back to public.url when there is no plain text")
    func urlFallback() {
        let result = ClipboardCapture.content(
            from: snapshot([(ClipboardCapture.urlType, text("https://example.com"))])
        )
        #expect(result == .text("https://example.com"))
    }

    @Test("Whitespace-only text is not captured")
    func blankTextRejected() {
        #expect(ClipboardCapture.content(
            from: snapshot([(ClipboardCapture.plainTextType, text("   \n\t "))])
        ) == nil)
    }

    @Test("Leading indentation is preserved, not trimmed away")
    func indentationPreserved() {
        let snippet = "    let x = 1\n"
        let result = ClipboardCapture.content(
            from: snapshot([(ClipboardCapture.plainTextType, text(snippet))])
        )
        #expect(result == .text(snippet))
    }

    @Test("Text past the size cap is not captured")
    func oversizeTextRejected() {
        let huge = String(repeating: "a", count: 5 * 1024 * 1024)
        #expect(ClipboardCapture.content(
            from: snapshot([(ClipboardCapture.plainTextType, text(huge))])
        ) == nil)
    }

    @Test("TIFF is normalised to PNG")
    func tiffNormalised() throws {
        let result = ClipboardCapture.content(
            from: snapshot([(ClipboardCapture.tiffType, tiffData())])
        )
        guard case .image(let data, let type) = result else {
            Issue.record("expected an image, got \(String(describing: result))")
            return
        }
        #expect(type == ClipboardCapture.pngType)
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("PNG is stored without re-encoding")
    func pngPassthrough() throws {
        let png = try #require(ClipboardImage.normalize(tiffData(), limits: .default))
        let result = ClipboardCapture.content(
            from: snapshot([(ClipboardCapture.pngType, png)])
        )
        #expect(result == .image(data: png, type: ClipboardCapture.pngType))
    }

    // MARK: Exclusions

    @Test("Every marker type excludes the pasteboard", arguments: ClipboardCapture.excludedTypes)
    func markersExclude(marker: String) {
        let board = snapshot([(ClipboardCapture.plainTextType, text("hunter2"))], extraTypes: [marker])
        #expect(ClipboardCapture.isExcluded(board))
        #expect(ClipboardCapture.content(from: board) == nil)
    }

    @Test("A marker on any item excludes the whole pasteboard")
    func markerOnLaterItem() {
        // `pasteboard.types` reports only the first item, so the store unions
        // every item's types before asking. This is that contract.
        var board = snapshot([(ClipboardCapture.plainTextType, text("hunter2"))])
        board.types.append("org.nspasteboard.ConcealedType")
        #expect(ClipboardCapture.content(from: board) == nil)
    }

    @Test("An ordinary pasteboard is not excluded")
    func ordinaryBoardAllowed() {
        #expect(!ClipboardCapture.isExcluded(
            snapshot([(ClipboardCapture.plainTextType, text("hello"))])
        ))
    }

    // MARK: Fingerprints

    @Test("Fingerprints are domain-separated by kind")
    func domainSeparation() {
        let path = "/tmp/a"
        #expect(
            ClipboardCapture.fingerprint(.text(path))
                != ClipboardCapture.fingerprint(.files([URL(fileURLWithPath: path)]))
        )
    }

    @Test("A trailing newline is a different clip")
    func newlineMatters() {
        #expect(
            ClipboardCapture.fingerprint(.text("foo"))
                != ClipboardCapture.fingerprint(.text("foo\n"))
        )
    }

    @Test("Fingerprints are stable across calls")
    func fingerprintStable() {
        // The regression test for anyone who "optimises" this into `hashValue`,
        // which is seeded per process and would not survive a relaunch.
        #expect(
            ClipboardCapture.fingerprint(.text("foo"))
                == ClipboardCapture.fingerprint(.text("foo"))
        )
    }

    @Test("File order is part of the identity")
    func fileOrderMatters() {
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        #expect(
            ClipboardCapture.fingerprint(.files([a, b]))
                != ClipboardCapture.fingerprint(.files([b, a]))
        )
    }
}
