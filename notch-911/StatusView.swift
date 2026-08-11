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

    /// Three panes rather than one long column. The window used to be a fixed
    /// 580×640 with everything stacked inside it, which meant the event log was
    /// clipped off the bottom with no way to reach it — and the clipboard had
    /// nowhere to live at all beyond a count.
    enum Tab: String, CaseIterable, Identifiable {
        case status = "Status"
        case clipboard = "Clipboard"
        case events = "Events"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .status: "gearshape"
            case .clipboard: "doc.on.clipboard"
            case .events: "list.bullet.rectangle"
            }
        }
    }

    @State private var tab: Tab = .status

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tabPicker

            // Each pane scrolls on its own. The log and the clipboard both grow
            // without bound, so a single outer scroller would leave you hunting
            // for the settings under a thousand events.
            ScrollView {
                Group {
                    switch tab {
                    case .status: statusTab
                    case .clipboard: clipboardTab
                    case .events: eventsTab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(22)
        // Was a hard `width:height:`, which is what made the content unreachable.
        // A minimum plus an ideal lets the window open at the old size and be
        // dragged bigger when a pane has more in it.
        .frame(minWidth: 560, idealWidth: 600, minHeight: 480, idealHeight: 680,
               alignment: .topLeading)
        .background(.background)
    }

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(Tab.allCases) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Tabs

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                Divider().padding(.leading, 14)
                clipboardRow
                Divider().padding(.leading, 14)
                clipboardStorageRow
            }
        }
    }

    private var eventsTab: some View { logSection }

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

    private var clipboardRow: some View {
        toggleRow(
            isOn: $model.clipboardCapture,
            title: "Clipboard history",
            detail: "Keeps the last \(ClipboardStore.maxItems) things you copied, in the notch. "
                + "Nothing leaves this Mac, and anything an app marks confidential — "
                + "password managers do — is never captured."
        )
    }

    /// The clear button lives in its own row rather than inside `toggleRow`:
    /// `.toggleStyle(.switch)` puts the switch on the trailing edge of its own
    /// frame, so squeezing a button in beside it strands the switch mid-row.
    /// This also gives the hotkey somewhere to report from — a chord another app
    /// already owns registers successfully and then never fires, so "it's on" is
    /// worth stating rather than assuming.
    private var clipboardStorageRow: some View {
        row(
            color: clipboardColor,
            title: "Stored clippings",
            detail: model.isClipboardHotkeyRegistered
                ? "\(model.clipboard.items.count) stored · ⇧⌘V opens the notch"
                : "⇧⌘V could not be registered — another app may own it. "
                    + "The clipboard button in the notch peek always works."
        ) {
            Button("Clear") { model.clearClipboardHistory() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.clipboard.items.isEmpty)
        }
    }

    private var clipboardColor: Color {
        guard model.clipboardCapture else { return .secondary }
        return model.isClipboardHotkeyRegistered ? .green : .orange
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

    // MARK: - Clipboard

    /// Everything the notch is holding, at a size you can actually read — the
    /// notch surface is a picker you glance at, this is where you go to see what
    /// is in there and throw things out.
    private var clipboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(model.clipboard.items.count) of \(ClipboardStore.maxItems)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !model.clipboardCapture {
                    Label("Capture is off", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Clear all") { model.clearClipboardHistory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.clipboard.items.isEmpty)
            }

            if model.clipboard.items.isEmpty {
                emptyClipboard
            } else {
                card {
                    ForEach(Array(model.clipboard.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 56) }
                        clipRow(item)
                    }
                }
            }
        }
    }

    private var emptyClipboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.clipboardCapture ? "Nothing copied yet." : "Clipboard history is off.")
                .font(.callout.weight(.medium))
            Text(model.clipboardCapture
                 ? "Copy anything and it shows up here, newest first. ⇧⌘V opens the notch."
                 : "Turn it on under Status to start keeping what you copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape.fill(.background.secondary))
        .overlay(cardShape.strokeBorder(.separator.opacity(0.5), lineWidth: 1))
    }

    private func clipRow(_ item: ClipItem) -> some View {
        let isStale = ClipboardStore.isStale(item)
        return HStack(spacing: 12) {
            clipThumbnail(item)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(isStale ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(ClipboardStore.preview(for: item))
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)

                HStack(spacing: 5) {
                    if let icon = model.clipboard.sourceIcon(for: item) {
                        Image(nsImage: icon).resizable().frame(width: 11, height: 11)
                    }
                    Text(clipCaption(item))
                }
                .font(.caption)
                .foregroundStyle(isStale ? AnyShapeStyle(Color.orange.opacity(0.8)) : AnyShapeStyle(.secondary))
            }

            Spacer(minLength: 8)

            // Puts it back on the pasteboard without going through the notch —
            // the same `copy` the card uses, so the auto-generated marker and
            // the change-count bookkeeping come along with it.
            Button("Copy") { model.clipboard.copy(item) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isStale)

            Button {
                model.clipboard.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove this clipping")
            .accessibilityLabel("Remove this clipping")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func clipCaption(_ item: ClipItem) -> String {
        var parts: [String] = []
        parts.append(ClipboardStore.isStale(item) ? "File missing" : item.kind.label)
        if let name = item.source?.name { parts.append(name) }
        parts.append(Self.clock.string(from: item.lastCopiedAt))
        if item.copyCount > 1 { parts.append("copied \(item.copyCount)×") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func clipThumbnail(_ item: ClipItem) -> some View {
        if let image = model.clipboard.thumbnails[item.id] {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if item.kind == .files, let url = item.urls.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Rectangle().fill(.background.secondary)
                Image(systemName: item.kind.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
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

            // No inner `ScrollView` any more: this pane already lives inside the
            // window's scroller, and a nested one gives you two scrollbars, a
            // fixed-height window inside a resizable one, and a wheel that
            // scrolls whichever container the pointer happens to be over.
            Group {
                if model.log.isEmpty {
                    Text("Nothing yet — prompts show up here as they arrive.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(cardShape.fill(.background.secondary))
            .overlay(cardShape.strokeBorder(.separator.opacity(0.5), lineWidth: 1))
        }
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
