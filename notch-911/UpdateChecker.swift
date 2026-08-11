//
//  UpdateChecker.swift
//  notch-911
//
//  Asks GitHub Releases whether a newer version exists — once at launch, then
//  every 24 hours. No Sparkle: there is no Developer ID behind this app, so a
//  self-replacing updater would reintroduce the quarantine dance on every
//  update anyway. All this does is point the browser at the release page.
//
//  Every failure — offline, rate-limited, malformed JSON — is a silent return.
//  An update check is never worth an error dialog.
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

    /// Non-nil only when the latest release is strictly newer than the running
    /// build and hasn't been skipped. The menu watches this.
    private(set) var available: Update?

    /// "Skip this version" survives relaunch; a later release surfaces again
    /// because the comparison is against the exact skipped version.
    private static let skippedKey = "notchd.skippedUpdateVersion"

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Idempotent — the app delegate calls this once per launch, never under
    /// XCTest (the same guard that keeps tests from starting the hook server).
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await self.check()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
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

    private func check() async {
        guard
            let currentString = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let current = SemanticVersion(currentString),
            let url = URL(string:
                "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")
        else { return }

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
            let latest = SemanticVersion(release.tagName),
            latest > current
        else { return }

        let version = latest.description
        guard UserDefaults.standard.string(forKey: Self.skippedKey) != version else { return }
        available = Update(version: version, url: release.htmlURL)
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
