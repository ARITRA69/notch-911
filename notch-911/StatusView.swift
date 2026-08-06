//
//  StatusView.swift
//  notch-911
//
//  The app's only window: is the server up, which hooks are registered,
//  and what has come through.
//

import SwiftUI

struct StatusView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            card {
                serverRow
                rowDivider
                hookRow
                if model.isCodexInstalled {
                    rowDivider
                    codexRow
                    rowDivider
                    accessibilityRow
                }
            }

            if let error = model.setupError { errorBox(error) }

            card {
                stopRow
                Divider().padding(.leading, 14)
                youTubeMusicRow
            }

            logSection
        }
        .padding(22)
        .frame(width: 580, height: 640, alignment: .topLeading)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.tint.opacity(0.16))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tint)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("notch-911")
                    .font(.title3.weight(.semibold))
                Text("Agent prompts — permission, selects and free text — answered from the notch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Rows

    private var serverRow: some View {
        row(color: serverColor, title: "Local hook server", detail: serverDescription, mono: true) {
            Menu {
                ForEach(AppModel.SimulatedShape.allCases) { shape in
                    Button(shape.rawValue) { model.simulate(shape) }
                }
            } label: {
                Label("Simulate", systemImage: "play.fill")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(model.port == nil)
        }
    }

    private var hookRow: some View {
        row(
            color: model.isConnected ? .green : .secondary,
            title: "Claude Code hook",
            detail: model.isConnected
                ? "PermissionRequest + Elicitation\(model.surfaceStop ? " + Stop" : "") in ~/.claude/settings.json"
                : "Not registered",
            logo: Agent.claudeCode.logoAsset
        ) {
            if model.isConnected {
                Button("Disconnect") { model.disconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Connect") { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.port == nil)
            }
        }
    }

    private var codexRow: some View {
        row(
            color: model.isCodexConnected ? .green : .secondary,
            title: "Codex hook",
            detail: model.isCodexConnected
                ? "Permissions via hook · plan questions via local task watcher"
                : "Plan questions watched locally · permission hook not registered",
            logo: Agent.codex.logoAsset
        ) {
            Button {
                model.simulate(.permission, agent: .codex)
            } label: {
                Label("Simulate", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.port == nil)

            if model.isCodexConnected {
                Button("Disconnect") { model.disconnectCodex() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Connect") { model.connectCodex() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.port == nil)
            }
        }
    }

    private var accessibilityRow: some View {
        row(
            color: model.accessibilityTrusted ? .green : .orange,
            title: "Direct Codex answers",
            detail: accessibilityDetail,
            logo: Agent.codex.logoAsset
        ) {
            if !model.accessibilityTrusted {
                Button("Enable") { model.enableAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private var accessibilityDetail: String {
        if model.accessibilityTrusted {
            return "Accessibility enabled · \(model.signatureStatus.detail)"
        }
        if model.signatureStatus.isStable {
            return "Accessibility required once · \(model.signatureStatus.detail)"
        }
        return model.signatureStatus.detail
    }

    private var stopRow: some View {
        toggleRow(
            isOn: $model.surfaceStop,
            title: "Surface Stop events",
            detail: "Ask \"anything else?\" at the end of every turn. Off by default — it fires a lot."
        )
    }

    private var youTubeMusicRow: some View {
        toggleRow(
            isOn: $model.youTubeMusic,
            title: "YouTube Music in the mini player",
            detail: "Spotify and Music work out of the box. YouTube Music lives in a browser tab, "
                + "so this needs Automation access for that browser plus "
                + "Develop → Allow JavaScript from Apple Events."
        )
    }

    private func toggleRow(isOn: Binding<Bool>, title: String, detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("Paste this into ~/.claude/settings.json instead:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.manualSnippet)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Button("Copy snippet") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.manualSnippet, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.orange.opacity(0.08))
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Events")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                Spacer()
                if !model.log.isEmpty {
                    Text("\(model.log.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            ScrollView {
                if model.log.isEmpty {
                    Text("Nothing yet — prompts show up here as they arrive.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.log.reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Self.clock.string(from: entry.at))
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption.monospaced())
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(cardShape.fill(.background.secondary))
            .overlay(cardShape.strokeBorder(.separator.opacity(0.5), lineWidth: 1))
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Building blocks

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(cardShape.fill(.background.secondary))
            .overlay(cardShape.strokeBorder(.separator.opacity(0.5), lineWidth: 1))
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 34)
    }

    private func row<Controls: View>(
        color: Color,
        title: String,
        detail: String,
        logo: String? = nil,
        mono: Bool = false,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(spacing: 10) {
            statusDot(color)
            if let logo {
                BrandMark(logo, size: 16)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(mono ? .caption.monospaced() : .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) { controls() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 4))
            .frame(width: 14, alignment: .center)
    }

    private var serverColor: Color {
        switch model.serverState {
        case .listening: return .green
        case .starting: return .yellow
        case .failed: return .red
        }
    }

    private var serverDescription: String {
        switch model.serverState {
        case .starting: return "starting…"
        case .listening(let port): return "127.0.0.1:\(port)\(ClaudeSettings.permissionPath)"
        case .failed(let message): return message
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
