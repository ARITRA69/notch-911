//
//  notch_911App.swift
//  notch-911
//
//  Created by Aritra on 05/08/26.
//

import AppKit
import SwiftUI

@main
struct notch_911App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("notch-911", id: "status") {
            StatusView(model: model)
        }
        // `.contentSize` pinned the window to exactly the view's frame, which is
        // what left the event log clipped with no way to reach it. `.contentMinSize`
        // keeps the view's minimum as the floor and lets the window grow.
        .windowResizability(.contentMinSize)
        .commands { UpdateCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit-test host runs this delegate too. Starting for real would
        // bind the next free port and rewrite the *installed* app's hook
        // registration out from under it — every test run would silently
        // disconnect the notch.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] == nil
        else { return }
        AppModel.shared.start()
        UpdateChecker.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Same guard as launch, for the same reason plus one more: touching
        // `AppModel.shared` here would *construct* it, and with it a
        // `ClipboardStore` pointed at the real Application Support directory —
        // which restores, sweeps orphan blobs and then writes the manifest back.
        // A test run has no business rewriting the installed app's clipboard
        // history on its way out.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] == nil
        else { return }
        AppModel.shared.shutDown()
    }

    /// Closing the status window leaves the server running — the app is a
    /// background listener that happens to have a debug window in M0.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
