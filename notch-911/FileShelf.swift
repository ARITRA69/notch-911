//
//  FileShelf.swift
//  notch-911
//
//  A temporary parking space for files: drag in from anywhere, drag back out
//  later. Nine slots, which is what fits a 3-column grid without the peek
//  growing taller than the surface it lives in.
//
//  Dropped files are *copied* into Application Support rather than referenced.
//  A shelf that holds references breaks the moment the original is moved,
//  renamed, or cleaned up — and drags out of browsers and Mail hand over temp
//  files that vanish almost immediately.
//

import AppKit
import Foundation
import Observation
import QuickLookThumbnailing
import os

struct ShelfItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL

    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}

@MainActor
@Observable
final class ShelfStore {

    /// 3 columns × 3 rows. Past this the grid stops being glanceable.
    static let maxItems = 9

    private(set) var items: [ShelfItem] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    /// Set briefly when a drop is refused so the UI can flash a reason.
    private(set) var isFull = false

    @ObservationIgnored
    private let log = Logger(subsystem: "com.aritra360.notch-911", category: "Shelf")

    @ObservationIgnored
    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("notch-911", isDirectory: true)
            .appendingPathComponent("shelf", isDirectory: true)
    }

    init() {
        restore()
    }

    // MARK: Mutation

    /// Copies dropped files in. Returns false when nothing was taken, which is
    /// what `dropDestination` wants in order to show a rejection.
    @discardableResult
    func accept(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let room = Self.maxItems - items.count
        guard room > 0 else {
            flashFull()
            return false
        }
        if urls.count > room { flashFull() }

        var accepted = false
        for url in urls.prefix(room) {
            guard let copied = copyIn(url) else { continue }
            let item = ShelfItem(url: copied)
            items.append(item)
            accepted = true
            loadThumbnail(for: item)
        }
        return accepted
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.url] = nil
        try? FileManager.default.removeItem(at: item.url)
    }

    func removeAll() {
        for item in items { try? FileManager.default.removeItem(at: item.url) }
        items.removeAll()
        thumbnails.removeAll()
    }

    // MARK: Storage

    private func copyIn(_ source: URL) -> URL? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let destination = uniqueDestination(for: source.lastPathComponent)
            try manager.copyItem(at: source, to: destination)
            return destination
        } catch {
            log.error("could not shelve \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Two files called `screenshot.png` are a completely ordinary thing to want
    /// on a shelf, so collisions get suffixed rather than overwritten.
    private func uniqueDestination(for filename: String) -> URL {
        let manager = FileManager.default
        var candidate = storageDirectory.appendingPathComponent(filename)
        guard manager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        repeat {
            let suffixed = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = storageDirectory.appendingPathComponent(suffixed)
            index += 1
        } while manager.fileExists(atPath: candidate.path) && index < 100
        return candidate
    }

    /// Survives relaunch — a shelf that empties itself when the app restarts is
    /// a shelf you can't trust anything to.
    private func restore() {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = contents.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        items = sorted.prefix(Self.maxItems).map(ShelfItem.init)
        for item in items { loadThumbnail(for: item) }
    }

    // MARK: Thumbnails

    private func loadThumbnail(for item: ShelfItem) {
        // Workspace icon first so a tile never renders empty, then upgrade to a
        // real preview if QuickLook can make one.
        thumbnails[item.url] = NSWorkspace.shared.icon(forFile: item.url.path)

        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 128, height: 128),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let representation else { return }
            let image = NSImage(cgImage: representation.cgImage, size: representation.contentRect.size)
            Task { @MainActor [weak self] in
                self?.thumbnails[item.url] = image
            }
        }
    }

    private func flashFull() {
        isFull = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            self?.isFull = false
        }
    }
}

// MARK: - View

import SwiftUI

/// Collapsed it's a small well (empty) or a fanned stack (holding files).
/// Hovering fans it out into a 3-column grid — bare thumbnails, no borders or
/// backgrounds, per the brief.
struct ShelfView: View {
    let store: ShelfStore
    /// Drop targeting, reported up so the peek stays open mid-drag. Hover events
    /// stop firing once a drag session starts, so the container's own `onHover`
    /// can't see the pointer arrive.
    var onDragTargeting: (Bool) -> Void = { _ in }

    @State private var isOpen = false
    @State private var isTargeted = false
    @State private var hovered: UUID?

    private static let tile: CGFloat = 40
    private static let gap: CGFloat = 8
    /// Three columns exactly, so the column never reflows as files come and go.
    static let width: CGFloat = tile * 3 + gap * 2

    private static let reveal = Animation.spring(response: 0.34, dampingFraction: 0.84)

    private var showsGrid: Bool { (isOpen || isTargeted) && !store.items.isEmpty }

    /// Rows of three. Built eagerly on purpose — see `grid`.
    private var rows: [[ShelfItem]] {
        stride(from: 0, to: store.items.count, by: 3).map {
            Array(store.items[$0 ..< min($0 + 3, store.items.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            heading
            if showsGrid {
                grid
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            } else if store.items.isEmpty {
                well
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            } else {
                fan
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .animation(Self.reveal, value: store.items.count)
        .contentShape(Rectangle())
        // Driven explicitly rather than by `.animation(value:)` so opening and
        // closing share one transaction and stay symmetric.
        .onHover { hovering in
            withAnimation(Self.reveal) { isOpen = hovering }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.accept(urls)
        } isTargeted: { targeted in
            withAnimation(Self.reveal) { isTargeted = targeted }
            onDragTargeting(targeted)
        }
    }

    // MARK: Pieces

    private var heading: some View {
        HStack(spacing: 4) {
            Image(systemName: store.items.isEmpty ? "tray" : "tray.full")
            Text(headingText)
            Spacer(minLength: 0)
            if showsGrid {
                Button { store.removeAll() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the shelf")
            }
        }
        .font(.caption2)
        .foregroundStyle(store.isFull ? Color.orange.opacity(0.85) : .white.opacity(0.35))
        .animation(.easeOut(duration: 0.18), value: store.isFull)
    }

    private var headingText: String {
        if store.isFull { return "Shelf full" }
        return store.items.isEmpty ? "Shelf" : "\(store.items.count)/\(ShelfStore.maxItems)"
    }

    /// Empty state: a target that visibly wants a file.
    private var well: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(
                .white.opacity(isTargeted ? 0.45 : 0.14),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
            .frame(height: Self.tile)
            .overlay(
                Image(systemName: "arrow.down.to.line")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(isTargeted ? 0.65 : 0.28))
            )
            .scaleEffect(isTargeted ? 1.04 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTargeted)
    }

    /// Holding files, at rest: the newest three, fanned.
    private var fan: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(store.items.suffix(3).enumerated()), id: \.element.id) { index, item in
                thumbnail(item)
                    .frame(width: Self.tile, height: Self.tile)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .rotationEffect(.degrees(Double(index) * 4 - 4))
                    .offset(x: CGFloat(index) * 11)
                    .zIndex(Double(index))
            }
        }
        .frame(height: Self.tile, alignment: .leading)
        .scaleEffect(isTargeted ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTargeted)
    }

    /// Deliberately eager rather than a `LazyVGrid`. A lazy container lays its
    /// cells out immediately when inserted, so the grid appeared with no
    /// animation while removal still faded — expansion and collapse looked like
    /// two different interactions. At nine items max, laziness buys nothing.
    private var grid: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.gap) {
                    ForEach(row) { tile($0) }
                    if row.count < 3 { Spacer(minLength: 0) }
                }
            }
        }
    }

    private func tile(_ item: ShelfItem) -> some View {
        thumbnail(item)
            .frame(width: Self.tile, height: Self.tile)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if hovered == item.id {
                    Button { store.remove(item) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .onHover { inside in
                if inside { hovered = item.id }
                else if hovered == item.id { hovered = nil }
            }
            .animation(.easeOut(duration: 0.14), value: hovered)
            // Drag straight back out to Finder or any app that takes files.
            .draggable(item.url)
            .help(item.name)
    }

    @ViewBuilder
    private func thumbnail(_ item: ShelfItem) -> some View {
        if let image = store.thumbnails[item.url] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Color.white.opacity(0.06)
        }
    }
}
