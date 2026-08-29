//
//  HelloQuillApp.swift
//  HelloQuill — Quill Module 0 deliverable
//
//  A minimal menubar (NSStatusItem + NSPopover) app hosting a SwiftUI view.
//  This is the embryonic form of Quill's component 1
//  (QuillApp / AppDelegate / PopoverView).
//
//  Requires: Xcode 16+, Swift 5.10+, macOS 15.
//  Pair with LevelMeterModel.swift in the same target.
//

import SwiftUI   // SwiftUI views + the App protocol
import AppKit    // NSStatusItem, NSPopover — menubar machinery

// MARK: - App entry point

/// `@main` marks the program's entry point. A menubar app has no windows,
/// so `body` provides only an empty Settings scene to satisfy the protocol.
@main
struct HelloQuillApp: App {
    /// Bridges SwiftUI's lifecycle to an AppKit delegate object.
    /// SwiftUI creates one AppDelegate and keeps it alive for the app's life.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }   // no real windows; the popover is our UI
    }
}

// MARK: - AppDelegate

/// @MainActor: everything here touches UI, so the compiler pins it to the
/// main actor. NSObject + NSApplicationDelegate are AppKit requirements.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Strong references — without a stored property, ARC would deallocate
    // the status item immediately and the menubar icon would vanish.
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model = LevelMeterModel()   // shared app state

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Claim a slot in the system menubar.
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)

        // 2. Give it an icon. SF Symbols ship with macOS — no assets needed.
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "waveform.circle",
                accessibilityDescription: "Quill")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item   // keep it alive

        // 3. Configure the popover to host our SwiftUI view.
        popover.behavior = .transient   // clicking elsewhere closes it
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model))
    }

    /// AppKit buttons still use the Objective-C target/action mechanism.
    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button,
                         preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()   // cancel any running tasks — cleanup discipline
    }
}

// MARK: - PopoverView (SwiftUI)

struct PopoverView: View {
    /// @Observable model: SwiftUI re-renders this view automatically
    /// whenever a property the body reads changes.
    var model: LevelMeterModel

    var body: some View {
        VStack(spacing: 12) {
            Text("HelloQuill")
                .font(.headline)

            // Live level meter: bar width follows model.level (0...1).
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.isRunning ? .green : .gray)
                        .frame(width: geo.size.width * CGFloat(model.level))
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.05), value: model.level)

            Button(model.isRunning ? "Stop" : "Record") {
                model.isRunning ? model.stop() : model.start()
            }
            .keyboardShortcut("r")   // ⌘R while the popover is open

            Button("Quit HelloQuill") {
                NSApp.terminate(nil)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 260)
    }
}
