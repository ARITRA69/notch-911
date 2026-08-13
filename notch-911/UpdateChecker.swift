//
//  UpdateChecker.swift
//  notch-911
//
//  Asks GitHub Releases whether a newer version exists — once at launch, every
//  24 hours after that, and on demand from the reload button in the status
//  window. No Sparkle: there is no Developer ID behind this app, so a
//  self-replacing updater would reintroduce the quarantine dance on every
//  update anyway. All this does is point the browser at the release page.
//
//  A background failure — offline, rate-limited, malformed JSON — is a silent
//  return; a poll nobody asked for is never worth an error dialog. A manual
//  check does report back, because a button that says nothing looks broken.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    // The repository whose latest release is the source of truth.
    private static let owner = "ARITRA69"
    private static let repo = "notch-911"

    struct Update {
        /// Normalized, without the tag's leading "v" — display as "v\(version)".
        let version: String
        let url: URL
    }

    /// What a manual check came back with when it found no new version. Cleared
    /// a few seconds later — it exists so the button can acknowledge the click.
    /// Never set by the background poll, which has no button to report to.
    enum Outcome { case upToDate, unreachable }

    /// Non-nil only when the latest release is strictly newer than the running
    /// build and hasn't been skipped. The menu and the status window watch this.
    private(set) var available: Update?

    /// A manual check is in flight. The background poll never sets this.
    private(set) var isChecking = false

    private(set) var lastOutcome: Outcome?

    /// "Skip this version" survives relaunch; a later release surfaces again
    /// because the comparison is against the exact skipped version.
    private static let skippedKey = "notchd.skippedUpdateVersion"

    private static let interval: Duration = .seconds(24 * 60 * 60)

    /// A check against a warm connection returns in tens of milliseconds, which
    /// reads as a flicker rather than a refresh. Hold the spinner this long.
    private static let minimumSpin: Duration = .milliseconds(600)

    /// The running build — the idle tooltip shows it, so "check for updates"
    /// can answer "which version am I on?" without a trip to the About box.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var manualTask: Task<Void, Never>?

    /// Idempotent — the app delegate calls this once per launch, never under
    /// XCTest (the same guard that keeps tests from starting the hook server).
    func start() {
        guard pollTask == nil else { return }
        schedulePoll(immediately: true)
    }

    private func schedulePoll(immediately: Bool) {
        pollTask?.cancel()
        pollTask = Task {
            if !immediately { try? await Task.sleep(for: Self.interval) }
            while !Task.isCancelled {
                await self.check()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// The reload button. Unlike the poll, this one answers: silence after an
    /// explicit click is indistinguishable from a dead control.
    func checkNow() {
        guard !isChecking else { return }
        // Asking is the opposite of "skip this version" — an old skip must not
        // swallow the answer the user just went looking for.
        UserDefaults.standard.removeObject(forKey: Self.skippedKey)
        lastOutcome = nil
        manualTask?.cancel()
        manualTask = Task {
            isChecking = true
            let started = ContinuousClock.now
            let reached = await check()
            let elapsed = ContinuousClock.now - started
            if elapsed < Self.minimumSpin {
                try? await Task.sleep(for: Self.minimumSpin - elapsed)
            }
            isChecking = false
            guard !Task.isCancelled else { return }

            // The daily clock restarts from here. A background poll two minutes
            // after an explicit check is pure noise.
            schedulePoll(immediately: false)

            // An update speaks for itself: the button becomes the way to get it.
            guard available == nil else { return }
            lastOutcome = reached ? .upToDate : .unreachable
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { lastOutcome = nil }
        }
    }

    func open(_ update: Update) {
        NSWorkspace.shared.open(update.url)
    }

    func skip(_ update: Update) {
        UserDefaults.standard.set(update.version, forKey: Self.skippedKey)
        available = nil
    }

    // MARK: - The check

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Returns whether GitHub answered with something parseable — *not* whether
    /// an update exists. Only the manual path cares; the poll discards it.
    @discardableResult
    private func check() async -> Bool {
        guard
            let currentString = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let current = SemanticVersion(currentString),
            let url = URL(string:
                "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")
        else { return false }

        var request = URLRequest(url: url)
        // GitHub's API rejects requests without a User-Agent.
        request.setValue("\(Self.repo)-update-check", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let release = try? JSONDecoder().decode(LatestRelease.self, from: data),
            let latest = SemanticVersion(release.tagName)
        else { return false }

        guard latest > current else { return true }

        let version = latest.description
        guard UserDefaults.standard.string(forKey: Self.skippedKey) != version else { return true }
        available = Update(version: version, url: release.htmlURL)
        return true
    }
}

// MARK: - Semver

/// Numeric comparison of "X.Y.Z" — string comparison would call "0.9.1" newer
/// than "0.10.0". Accepts a leading "v", fewer than three components ("1.0"
/// is what a dev build carries), and a prerelease suffix, which sorts below
/// the same release version per semver.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(_ string: String) {
        var core = string.hasPrefix("v") ? String(string.dropFirst()) : string
        if let plus = core.firstIndex(of: "+") {
            core = String(core[..<plus])  // build metadata never affects order
        }
        if let dash = core.firstIndex(of: "-") {
            prerelease = String(core[core.index(after: dash)...])
            core = String(core[..<dash])
        } else {
            prerelease = nil
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) }
        guard (1...3).contains(parts.count), !parts.contains(nil) else { return nil }
        let numbers = parts.compactMap { $0 }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // Same core: a prerelease precedes the release. Two prereleases fall
        // back to string order — close enough for tags this app will ever see.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, _), (_, nil): return lhs.prerelease != nil
        case let (l?, r?): return l < r
        }
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
            && lhs.prerelease == rhs.prerelease
    }
}

// MARK: - Menu

/// There is no status-bar item to hang this off, so it lives in the one menu
/// the app always has: the application menu, right under About. Invisible
/// unless an update is actually waiting.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let update = UpdateChecker.shared.available {
                Button("Update Available (v\(update.version))…") {
                    UpdateChecker.shared.open(update)
                }
                Button("Skip This Version") {
                    UpdateChecker.shared.skip(update)
                }
            }
        }
    }
}
