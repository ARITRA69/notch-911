//
//  GlobalHotkey.swift
//  notch-911
//
//  ⇧⌘V from anywhere. Carbon's `RegisterEventHotKey` is the only system-wide key
//  registration on macOS that costs the user nothing: the window server routes
//  exactly that one chord to us before the front app sees it, and no permission
//  is asked for or granted.
//
//  `NSEvent.addGlobalMonitorForEvents` is the modern-looking choice and is the
//  wrong one — global *keyboard* monitors are gated on Accessibility. The app
//  already asks for Accessibility once, for the Codex bridge, and that ask is
//  paid for by a feature that genuinely needs to drive another app's UI. Asking
//  for the right to read every keystroke the user types in order to open a list
//  of clippings is not a trade worth offering.
//
//  Carbon looks deprecated and isn't: `RegisterEventHotKey` is still the only
//  supported route, and is what every Spotlight-replacement has shipped on for
//  twenty years. It needs no entitlement, which matters here because the app is
//  unsandboxed and has no entitlements file at all — nothing to add, nothing to
//  re-provision, nothing to sign differently.
//

import AppKit
import Carbon.HIToolbox

/// The C trampoline.
///
/// Must be `nonisolated` explicitly. With `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` every top-level function is inferred `@MainActor`, and a
/// global-actor-isolated function cannot be converted to `@convention(c)` — the
/// compiler rejects it with "converting function value … loses global actor
/// 'MainActor'". This is the single most likely thing to go wrong in this file.
private nonisolated func notchHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    // Someone else's hot key on the same event target. Returning `noErr` here
    // would claim an event we didn't handle and stop Carbon walking the rest of
    // the handler chain.
    guard hotKeyID.signature == GlobalHotkey.signature else {
        return OSStatus(eventNotHandledErr)
    }

    // The only thing crossing the isolation boundary is a UInt32, so there is
    // nothing to make Sendable and nothing to launder through `Unmanaged` —
    // which would be the classic pattern here and is strictly worse: it hands
    // back a `@MainActor` (therefore non-Sendable) instance inside a
    // `nonisolated` function, which Swift 6 only accepts if you mark the class
    // `@unchecked Sendable`, and that would be a lie.
    //
    // `MainActor.assumeIsolated` is also tempting — handlers on the application
    // event target really are dispatched on the main run loop — but it is a
    // trapping precondition rather than a guarantee, and one runloop hop is
    // imperceptible for a keypress.
    let id = hotKeyID.id
    Task { @MainActor in GlobalHotkey.fire(id) }
    return noErr
}

@MainActor
final class GlobalHotkey {

    /// Four-char code identifying our hot keys inside Carbon's global namespace.
    /// Checked in the trampoline so a hot key some framework registered on the
    /// same event target can never reach our handler table.
    nonisolated static let signature: OSType = 0x6E39_3131   // 'n911'

    /// Main-actor isolated on purpose: `fire` is the only reader and the
    /// trampoline hops here before touching it, so there is no shared mutable
    /// state and no `nonisolated(unsafe)` anywhere in this file.
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    /// `nil` when the chord could not be registered.
    ///
    /// Note what this can and cannot tell you: `RegisterEventHotKey` returns an
    /// error only for a duplicate registration by *this* process. When another
    /// app already owns the chord, registration **succeeds and then never
    /// fires**, and there is no API that reports it. That is why the clipboard
    /// also has a visible way in from the peek.
    init?(keyCode: UInt32, carbonModifiers: UInt32, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return nil }
        hotKeyRef = ref
        Self.handlers[id] = handler
    }

    static func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        // `kEventClassKeyboard` ('keyb') — *not* `kEventClassKeyboardEvent`,
        // which doesn't exist. Both constants import as `Int`, hence the OSType
        // conversions.
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        // userData is nil: the `EventHotKeyID` carried by the event is enough to
        // get home, and a null pointer is one less lifetime to reason about.
        InstallEventHandler(
            GetApplicationEventTarget(),
            notchHotKeyHandler,
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    /// Explicit rather than `deinit`: a `@MainActor` class's `deinit` is
    /// `nonisolated` under Swift 6 and cannot touch `Self.handlers`
    /// synchronously — and in practice `AppModel` holds this for the process
    /// lifetime, so `deinit` never runs anyway.
    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        Self.handlers[id] = nil
    }
}
