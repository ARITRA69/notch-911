//
//  MirrorView.swift
//  notch-911
//
//  A mirror. The camera, shown back to you the way a mirror would, in the one
//  place on the machine that already sits directly under it.
//
//  Deliberately not a camera *app*: nothing is captured, nothing is written,
//  there is no shutter and no file. The session has a video input and a preview
//  layer and no output of any kind, which is what makes "is this recording me?"
//  answerable by reading thirty lines rather than by trusting a promise.
//
//  Portrait 9:16 because the subject is a face. The built-in camera hands over
//  a 16:9 landscape frame, so the preview fills the tall frame and lets the
//  sides fall outside it — cropping the room away rather than letterboxing the
//  face into a letterbox.
//

import AVFoundation
import AppKit
import Observation
import SwiftUI

// MARK: - Session

/// Owns the capture session away from the main actor.
///
/// `startRunning()` blocks until the camera has warmed up — a few hundred
/// milliseconds on a cold start, which on the main actor is a few hundred
/// milliseconds of frozen notch. Everything that touches the session is
/// therefore funnelled onto one serial queue, and `@unchecked Sendable` is the
/// claim that this is the only queue that ever does.
private nonisolated final class CameraEngine: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.aritra360.notch-911.mirror")

    /// Reports whether there is actually a camera feeding the session. A Mac
    /// with no usable camera is not an error state worth a permission prompt,
    /// but it is worth saying out loud rather than showing a black rectangle.
    func start(_ completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            if self.session.inputs.isEmpty {
                self.session.beginConfiguration()
                // `.high` rather than `.photo`: the preview is 252pt wide and
                // nothing is ever saved, so the extra pixels would cost power
                // for something no one can see.
                self.session.sessionPreset = .high
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                self.session.commitConfiguration()
            }
            guard !self.session.inputs.isEmpty else {
                completion(false)
                return
            }
            if !self.session.isRunning { self.session.startRunning() }
            completion(true)
        }
    }

    /// Stopping matters more here than it usually does: the camera light stays
    /// on for exactly as long as the session runs, and a mirror that leaves it
    /// lit after the notch has closed is indistinguishable from spyware.
    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
}

@MainActor
@Observable
final class MirrorSession {

    enum Permission: Equatable {
        case unknown
        case ready
        case denied
        /// Permission is fine; there is simply no camera to open.
        case unavailable
    }

    private(set) var permission: Permission = .unknown

    @ObservationIgnored private let engine = CameraEngine()

    nonisolated var captureSession: AVCaptureSession { engine.session }

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let granted: Bool
        switch status {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }
        guard granted else {
            permission = .denied
            return
        }

        let running = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // `@Sendable` because this is called back from the engine's own
            // queue — an inherited `@MainActor` here would trap on arrival, the
            // same way the audio tap did.
            engine.start { @Sendable ok in continuation.resume(returning: ok) }
        }
        permission = running ? .ready : .unavailable
    }

    func stop() {
        engine.stop()
    }

    func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Preview layer

/// The session's own preview layer, used as the view's backing layer so it
/// resizes with the frame for free rather than needing a layout pass to chase
/// it.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        // Fill the 9:16 frame from a 16:9 camera: crop the sides, keep the face
        // at the size it actually is.
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            // The whole point. An unmirrored camera is a video call; a mirrored
            // one is a mirror, and reaching up to fix the wrong side of your
            // collar is how you tell the difference.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer = preview
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Surface

/// The mirror as it sits in the notch: a tall 9:16 preview, a way back to the
/// peek, and `esc` to leave — the same frame the clipboard, Snake and voice
/// surfaces wear.
struct MirrorSurface: View {
    let coordinator: PromptCoordinator
    let session: MirrorSession

    /// 9:16, and the width the panel reserves for this surface. Stated once
    /// here and derived below, so the two can't drift into a nearly-portrait
    /// rectangle that no one notices is 0.58 instead of 0.5625.
    static let previewWidth: CGFloat = 252
    static var previewHeight: CGFloat { previewWidth * 16 / 9 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            preview
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shortcuts)
        .task { await session.start() }
        // Every way out lands here — `esc`, the back chevron, a click into
        // another app. The camera light going out is the acknowledgement that
        // the mirror is actually closed.
        .onDisappear { session.stop() }
    }

    private var heading: some View {
        HStack(spacing: 4) {
            Button { coordinator.backToPeek() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the notch overview")
            Image(systemName: "person.crop.square")
            Text("Mirror")
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.35))
    }

    @ViewBuilder
    private var preview: some View {
        switch session.permission {
        case .denied:
            blocked(
                title: "Camera access needed",
                detail: "notch-911 can't show you a mirror without it. Enable it in Privacy & Security, then reopen.",
                action: "Open Settings"
            ) { session.openCameraSettings() }
        case .unavailable:
            blocked(
                title: "No camera found",
                detail: "Nothing on this Mac is offering a video input right now.",
                action: nil
            ) {}
        case .unknown, .ready:
            CameraPreview(session: session.captureSession)
                .frame(width: Self.previewWidth, height: Self.previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
                // Black until the first frame lands, rather than the panel
                // showing through for the fraction of a second the camera takes
                // to wake up.
                .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func blocked(
        title: String,
        detail: String,
        action: String?,
        perform: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "video.slash")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        Text("Nothing is recorded · ⎋ close")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.25))
    }

    private var shortcuts: some View {
        Button("") { coordinator.closeMirror() }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}
