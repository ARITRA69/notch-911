//
//  CodeSignatureInspector.swift
//  notch-911
//
//  Small runtime diagnostic for the settings window. Accessibility approval
//  is durable only when successive builds keep the same designated identity.
//

import Foundation

nonisolated struct AppSignatureStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case stable
        case adHoc
        case unavailable
    }

    let kind: Kind
    let authority: String?

    var isStable: Bool { kind == .stable }

    var detail: String {
        switch kind {
        case .stable:
            return "Stable signature · \(authority ?? "local identity")"
        case .adHoc:
            return "Ad-hoc build · Accessibility may reset after rebuild"
        case .unavailable:
            return "Signature could not be verified"
        }
    }
}

nonisolated enum CodeSignatureInspector {
    static func current(bundleURL: URL = Bundle.main.bundleURL) -> AppSignatureStatus {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--display", "--verbose=2", bundleURL.path]
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let diagnostics = String(data: data, encoding: .utf8)
            else {
                return AppSignatureStatus(kind: .unavailable, authority: nil)
            }
            return parse(diagnostics)
        } catch {
            return AppSignatureStatus(kind: .unavailable, authority: nil)
        }
    }

    static func parse(_ diagnostics: String) -> AppSignatureStatus {
        let lines = diagnostics.split(whereSeparator: { $0.isNewline }).map(String.init)
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Signature=adhoc" }) {
            return AppSignatureStatus(kind: .adHoc, authority: nil)
        }
        if let authorityLine = lines.first(where: { $0.hasPrefix("Authority=") }) {
            let authority = String(authorityLine.dropFirst("Authority=".count))
            return AppSignatureStatus(kind: .stable, authority: authority)
        }
        return AppSignatureStatus(kind: .unavailable, authority: nil)
    }
}
