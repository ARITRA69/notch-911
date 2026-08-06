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
        .windowResizability(.contentSize)
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutDown()
    }

    /// Closing the status window leaves the server running — the app is a
    /// background listener that happens to have a debug window in M0.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
