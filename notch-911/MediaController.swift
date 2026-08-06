//
//  MediaController.swift
//  notch-911
//
//  Now-playing for Music.app, Spotify and YouTube Music.
//
//  This is deliberately *not* a general "whatever is playing" reader. Since
//  macOS 15.4 `mediaremoted` gates now-playing behind `com.apple.mediaremote.allow`,
//  which third-party apps cannot obtain, and the /usr/bin/perl adapter that used
//  to work is unentitled on 26.5. Per-app scripting is the only route left.
//
//  Spotify and Music.app expose scripting dictionaries and are read directly.
//  YouTube Music has no dictionary — it is a web app — so it is read through
//  whichever browser is showing it: Safari's `do JavaScript` and Chromium's
//  `execute javascript` both reach `navigator.mediaSession`, which YouTube Music
//  keeps populated, and the player bar's own buttons drive transport. The
//  Electron "YouTube Music Desktop" build is not scriptable at all and is not
//  covered.
//
//  Cost of this file: an Automation (Apple Events) prompt on first use, which
//  §9 previously listed as "No". That was an explicit, informed trade. The
//  browser route costs more than that — controlling a browser reads every tab's
//  URL, and it additionally needs "Allow JavaScript from Apple Events" turned on
//  in the browser's Develop menu — so it is behind a default-off setting rather
//  than something the app helps itself to.
//
//  Scripts run out of process through `osascript` rather than NSAppleScript.
//  NSAppleScript is main-thread-only, and a 10–20ms Apple Event round trip on
//  the main thread would blow §7.2's 4ms frame budget mid-animation.
//

import AppKit
import Foundation
import os

nonisolated final class MediaController: @unchecked Sendable {

    enum Source: String, Sendable, CaseIterable {
        case spotify
        case appleMusic
        case youtubeMusic

        var displayName: String {
            switch self {
            case .spotify: return "Spotify"
            case .appleMusic: return "Music"
            case .youtubeMusic: return "YouTube Music"
            }
        }

        /// The player's own mark, in `Assets.xcassets/Logos`. Nil where we don't
        /// have one — the caller falls back to a generic note rather than
        /// showing a wrong or invented mark.
        var logoAsset: String? {
            switch self {
            case .spotify: return "logo.spotify"
            case .appleMusic: return "logo.apple-music"
            case .youtubeMusic: return nil
            }
        }
    }

    /// The two players that answer for themselves. YouTube Music is absent on
    /// purpose: it is reached through a browser, not through a bundle ID.
    private enum NativePlayer: String, CaseIterable {
        case spotify
        case appleMusic

        var source: Source { self == .spotify ? .spotify : .appleMusic }

        var bundleID: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .appleMusic: return "com.apple.Music"
            }
        }
    }

    /// Chromium forks share Chrome's scripting dictionary verbatim, so one
    /// script covers all of them. Arc and Dia ship their own dictionaries and
    /// are deliberately not listed — a wrong guess there is an error every poll.
    private enum Browser: String, CaseIterable {
        case safari
        case safariPreview
        case chrome
        case brave
        case edge
        case vivaldi
        case opera
        case chromium

        var bundleID: String {
            switch self {
            case .safari: return "com.apple.Safari"
            case .safariPreview: return "com.apple.SafariTechnologyPreview"
            case .chrome: return "com.google.Chrome"
            case .brave: return "com.brave.Browser"
            case .edge: return "com.microsoft.edgemac"
            case .vivaldi: return "com.vivaldi.Vivaldi"
            case .opera: return "com.operasoftware.Opera"
            case .chromium: return "org.chromium.Chromium"
            }
        }

        var isSafari: Bool { self == .safari || self == .safariPreview }
    }

    struct NowPlaying: Sendable, Equatable {
        var source: Source
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        /// Seconds.
        var position: Double
        var duration: Double
        /// Spotify and YouTube Music hand out an https URL. Music.app has no URL
        /// at all — its art comes out as raw bytes, so this stays empty there.
        var artworkURL: String = ""
        /// Which app transport commands go back to. For YouTube Music this is
        /// the browser holding the tab, not the player itself.
        var hostBundleID: String = ""

        /// Changes exactly when the artwork needs re-fetching.
        var artworkKey: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }
    }

    struct Snapshot: Sendable {
        var track: NowPlaying?
        /// The user declined an Automation prompt, or hasn't answered it.
        var isPermissionDenied = false
        /// A YouTube Music tab is open, but the browser refuses to run scripts
        /// from Apple Events — a separate switch from Automation, in the
        /// browser's own Develop menu.
        var needsBrowserJavaScript = false
    }

    /// Reading a browser means reading every tab's URL, so it stays off until
    /// asked for. Read per poll rather than cached: the setting can flip from
    /// the status window while the poll loop is mid-flight.
    static let youTubeMusicDefaultsKey = "notchd.youtubeMusic"
    private var isYouTubeMusicEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.youTubeMusicDefaultsKey)
    }

    private let queue = DispatchQueue(label: "com.aritra69.notch-911.media")
    private let log = Logger(subsystem: "com.aritra69.notch-911", category: "Media")

    /// Field separator — ASCII unit separator, which cannot appear in a track name.
    private static let separator = "\u{1F}"

    // MARK: Query

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.snapshotSync()) }
        }
    }

    private func snapshotSync() -> Snapshot {
        var result = Snapshot()
        // A playing source wins outright; a paused one is only a fallback, so a
        // paused Spotify can't mask a playing Music.app or YouTube Music tab.
        var paused: NowPlaying?

        func consider(_ track: NowPlaying) -> Bool {
            if track.isPlaying { return true }
            if paused == nil { paused = track }
            return false
        }

        for player in NativePlayer.allCases {
            guard Self.isRunning(player.bundleID) else { continue }
            switch run(Self.readScript(for: player)) {
            case .failure(.notPermitted):
                result.isPermissionDenied = true
            case .failure(.failed):
                continue
            case .success(let raw):
                guard let track = Self.parse(
                    raw,
                    source: player.source,
                    host: player.bundleID
                ) else { continue }
                if consider(track) {
                    result.track = track
                    return result
                }
            }
        }

        if isYouTubeMusicEnabled {
            for browser in Browser.allCases {
                guard Self.isRunning(browser.bundleID) else { continue }
                switch run(Self.youTubeMusicReadScript(for: browser)) {
                case .failure(.notPermitted):
                    result.isPermissionDenied = true
                case .failure(.failed):
                    continue
                case .success(let raw):
                    // The tab is there but the browser wouldn't run the script.
                    if raw == Self.blockedMarker {
                        result.needsBrowserJavaScript = true
                        continue
                    }
                    guard let track = Self.parse(
                        raw,
                        source: .youtubeMusic,
                        host: browser.bundleID
                    ) else { continue }
                    if consider(track) {
                        result.track = track
                        return result
                    }
                }
            }
        }

        result.track = paused
        return result
    }

    // MARK: Transport

    func playPause(_ track: NowPlaying) { command(.playPause, on: track) }
    func nextTrack(_ track: NowPlaying) { command(.next, on: track) }
    func previousTrack(_ track: NowPlaying) { command(.previous, on: track) }

    enum Command {
        case playPause, next, previous

        var appleScriptVerb: String {
            switch self {
            case .playPause: return "playpause"
            case .next: return "next track"
            case .previous: return "previous track"
            }
        }

        /// YouTube Music's player bar keeps its own UI in sync when its buttons
        /// are clicked, which driving the `<video>` element directly does not.
        var javaScript: String {
            switch self {
            case .playPause:
                return "(function(){var b=document.querySelector('#play-pause-button');"
                    + "if(b){b.click();return 'ok';}"
                    + "var v=document.querySelector('video');"
                    + "if(v){if(v.paused){v.play();}else{v.pause();}}return 'ok';})()"
            case .next:
                return "(function(){var b=document.querySelector('.next-button');"
                    + "if(b){b.click();}return 'ok';})()"
            case .previous:
                return "(function(){var b=document.querySelector('.previous-button');"
                    + "if(b){b.click();}return 'ok';})()"
            }
        }
    }

    private func command(_ command: Command, on track: NowPlaying) {
        let host = track.hostBundleID
        guard !host.isEmpty else { return }
        queue.async {
            guard Self.isRunning(host) else { return }
            if track.source == .youtubeMusic {
                guard let browser = Browser.allCases.first(where: { $0.bundleID == host })
                else { return }
                _ = self.run(Self.youTubeMusicScript(command.javaScript, in: browser))
            } else {
                _ = self.run("tell application id \"\(host)\" to \(command.appleScriptVerb)")
            }
        }
    }

    // MARK: Scripts

    /// Only ever talks to an app that is *already* running — scripting a quit
    /// app would launch it, which is a hostile thing for a hover panel to do.
    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func readScript(for player: NativePlayer) -> String {
        // Spotify reports track length in milliseconds, Music in seconds.
        let duration = player == .spotify
            ? "((duration of theTrack) / 1000)"
            : "(duration of theTrack)"
        // Spotify's `artwork` property is documented as deprecated and never
        // set; `artwork url` is the only working route.
        let artwork = player == .spotify ? "(artwork url of theTrack) as text" : "\"\""
        // Deliberately plain: `character id` rather than the legacy `ASCII
        // character`, no `¬` continuations, one return path, and variable names
        // long enough not to collide with anything in either app's dictionary.
        return """
        set AppleScript's text item delimiters to (character id 31)
        set nowPlayingInfo to ""
        tell application id "\(player.bundleID)"
            try
                set playerStateText to (player state as text)
                if playerStateText is not "stopped" then
                    set theTrack to current track
                    set nowPlayingInfo to {(name of theTrack) as text, (artist of theTrack) as text, (album of theTrack) as text, playerStateText, (player position as text), (\(duration) as text), \(artwork)} as text
                end if
            end try
        end tell
        return nowPlayingInfo
        """
    }

    /// Returned when a YouTube Music tab exists but the browser wouldn't run the
    /// script. Carries no separator, so even if it somehow reached `parse` it
    /// would be rejected rather than shown as a track.
    private static let blockedMarker = "__notch911_script_blocked__"

    /// Reads `navigator.mediaSession`, which YouTube Music populates for the OS
    /// media keys, and falls back to the player bar's title element. The
    /// `<video>` element is the authority on play state and position — the
    /// media session's own position state is not readable from script.
    private static let youTubeMusicReadJavaScript =
        "(function(){var v=document.querySelector('video');if(!v)return '';"
        + "var m=(navigator.mediaSession&&navigator.mediaSession.metadata)||{};"
        + "var t=m.title||'';"
        + "if(!t){var e=document.querySelector('.title.ytmusic-player-bar');"
        + "t=e?e.textContent.trim():'';}"
        + "if(!t)return '';"
        + "var a='';if(m.artwork&&m.artwork.length){a=m.artwork[m.artwork.length-1].src;}"
        + "var d=isFinite(v.duration)?v.duration:0;"
        + "return [t,m.artist||'',m.album||'',v.paused?'paused':'playing',v.currentTime,d,a]"
        + ".join(String.fromCharCode(31));})()"

    private static func youTubeMusicReadScript(for browser: Browser) -> String {
        youTubeMusicScript(youTubeMusicReadJavaScript, in: browser)
    }

    /// Finds the first YouTube Music tab in any window and runs `javaScript` in
    /// it. The inner `try` separates "no such tab" from "the browser refuses to
    /// run scripts from Apple Events", which is a different switch from
    /// Automation and needs a different thing said to the user.
    private static func youTubeMusicScript(_ javaScript: String, in browser: Browser) -> String {
        let escaped = javaScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let evaluate = browser.isSafari
            ? "do JavaScript \"\(escaped)\" in theTab"
            : "execute theTab javascript \"\(escaped)\""
        // Safari calls them `current tab`/`tabs`, Chromium `active tab`/`tabs`;
        // `tabs of theWindow` is spelled the same in both dictionaries.
        return """
        set scriptResult to ""
        tell application id "\(browser.bundleID)"
            repeat with theWindow in windows
                -- Not every window in either dictionary carries tabs (Safari's
                -- downloads window, Chromium's app windows); an unguarded
                -- access there would abort the whole read.
                set theTabs to {}
                try
                    set theTabs to (tabs of theWindow)
                end try
                repeat with theTab in theTabs
                    set tabURL to ""
                    try
                        set tabURL to (URL of theTab) as text
                    end try
                    if tabURL contains "music.youtube.com" then
                        set scriptResult to "\(blockedMarker)"
                        try
                            set scriptResult to (\(evaluate)) as text
                        end try
                        exit repeat
                    end if
                end repeat
                if scriptResult is not "" then exit repeat
            end repeat
        end tell
        return scriptResult
        """
    }

    private static func parse(_ raw: String, source: Source, host: String) -> NowPlaying? {
        let fields = raw.components(separatedBy: separator)
        guard fields.count >= 6, !fields[0].isEmpty else { return nil }
        return NowPlaying(
            source: source,
            title: fields[0],
            artist: fields[1],
            album: fields[2],
            isPlaying: fields[3] == "playing",
            position: Double(fields[4]) ?? 0,
            duration: Double(fields[5]) ?? 0,
            artworkURL: fields.count > 6 ? fields[6] : "",
            hostBundleID: host
        )
    }

    // MARK: Artwork

    /// Spotify and YouTube Music: fetch the URL they hand out. Music.app: ask it
    /// to write the raw picture bytes to disk, since it exposes no URL.
    func artwork(for track: NowPlaying) async -> NSImage? {
        switch track.source {
        case .spotify, .youtubeMusic:
            guard let url = URL(string: track.artworkURL), url.scheme?.hasPrefix("http") == true
            else { return nil }
            // The one network call in the app. It goes to the player's own
            // image CDN, carries no identifiers, and only fires when the track
            // changes while the peek is open.
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)

        case .appleMusic:
            return await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.exportedMusicArtwork()) }
            }
        }
    }

    private func exportedMusicArtwork() -> NSImage? {
        guard Self.isRunning(NativePlayer.appleMusic.bundleID) else { return nil }
        let destination = Self.artworkCacheURL
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        let script = """
        set outputPath to "\(destination.path)"
        set artworkBytes to missing value
        tell application id "\(NativePlayer.appleMusic.bundleID)"
            try
                set theArtworks to artworks of current track
                if (count of theArtworks) is greater than 0 then
                    set artworkBytes to data of item 1 of theArtworks
                end if
            end try
        end tell
        if artworkBytes is missing value then return ""
        try
            set outputFile to open for access (POSIX file outputPath) with write permission
            set eof outputFile to 0
            write artworkBytes to outputFile
            close access outputFile
            return outputPath
        on error
            try
                close access outputFile
            end try
            return ""
        end try
        """

        guard case .success(let path) = run(script), !path.isEmpty else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private static var artworkCacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("notch-911", isDirectory: true)
            .appendingPathComponent("artwork")
    }

    // MARK: osascript

    private enum RunError: Error {
        /// errAEEventNotPermitted — the Automation prompt was declined, or
        /// hasn't been answered yet. Worth telling the user about.
        case notPermitted
        /// Anything else: a dictionary that doesn't have what the script asked
        /// for, a browser that closed mid-poll. Not the user's problem.
        case failed
    }

    private func run(_ script: String) -> Result<String, RunError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            log.error("osascript failed to launch: \(error.localizedDescription, privacy: .public)")
            return .failure(.failed)
        }

        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self)
            if message.contains("-1743") || message.lowercased().contains("not authorized") {
                return .failure(.notPermitted)
            }
            log.error("osascript error: \(message, privacy: .public)")
            return .failure(.failed)
        }

        return .success(
            String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Monitor

/// Polls only while the peek is on screen. §11 puts idle CPU under 0.1%, and a
/// notch app that spawns a process every second while nothing is visible would
/// blow that for no benefit.
@MainActor
@Observable
final class MediaMonitor {

    private(set) var nowPlaying: MediaController.NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var isPermissionDenied = false
    /// A YouTube Music tab is open but its browser won't run scripts from Apple
    /// Events. Separate from `isPermissionDenied` because the fix is in the
    /// browser's Develop menu, not System Settings.
    private(set) var needsBrowserJavaScript = false

    @ObservationIgnored private let controller = MediaController()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isPeekOpen = false
    /// Fires when the track or play state changes, so the panel can show or hide
    /// the collapsed mini player without polling it itself.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Identity of the track the current artwork belongs to, so it is fetched
    /// once per track rather than once per poll.
    @ObservationIgnored private var artworkKey: String?

    /// Polls for the whole lifetime of the app, because the collapsed mini
    /// player has to notice music starting without anyone hovering the notch.
    ///
    /// This does move §11's idle profile: the app is no longer doing literally
    /// nothing when unattended. The cost is bounded by `MediaController` only
    /// scripting apps that are already running — with no player open a poll is
    /// a handful of in-process checks and spawns no process at all. Enabling
    /// YouTube Music widens that: browsers are usually running, so a poll costs
    /// one `osascript` per running browser.
    func start() {
        restartPolling()
    }

    /// 1s while the peek is up so the progress bar tracks; 5s otherwise, which
    /// is plenty for artwork and play state on a 22pt disc.
    func setPeekOpen(_ open: Bool) {
        guard open != isPeekOpen else { return }
        isPeekOpen = open
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        let interval: Duration = isPeekOpen ? .seconds(1) : .seconds(5)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func playPause() {
        guard let track = nowPlaying else { return }
        controller.playPause(track)
        // Flip locally so the button responds now rather than at the next poll.
        nowPlaying?.isPlaying.toggle()
        Task { await nudge() }
    }

    func next() {
        guard let track = nowPlaying else { return }
        controller.nextTrack(track)
        Task { await nudge() }
    }

    func previous() {
        guard let track = nowPlaying else { return }
        controller.previousTrack(track)
        Task { await nudge() }
    }

    /// Re-read shortly after a transport command so the panel catches up without
    /// waiting out the poll interval.
    private func nudge() async {
        try? await Task.sleep(for: .milliseconds(350))
        await refresh()
    }

    private func refresh() async {
        let before = nowPlaying.map { "\($0.artworkKey)|\($0.isPlaying)" }
        defer {
            let after = nowPlaying.map { "\($0.artworkKey)|\($0.isPlaying)" }
            if before != after { onChange?() }
        }

        let snapshot = await controller.snapshot()
        isPermissionDenied = snapshot.isPermissionDenied
        needsBrowserJavaScript = snapshot.needsBrowserJavaScript

        guard let track = snapshot.track else {
            nowPlaying = nil
            artwork = nil
            artworkKey = nil
            return
        }

        nowPlaying = track
        guard track.artworkKey != artworkKey else { return }
        artworkKey = track.artworkKey
        artwork = nil
        let fetched = await controller.artwork(for: track)
        // The track may have moved on while the art was loading.
        guard artworkKey == track.artworkKey else { return }
        artwork = fetched
    }
}
