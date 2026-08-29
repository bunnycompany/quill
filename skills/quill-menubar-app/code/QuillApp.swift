//
//  QuillApp.swift
//  Quill — Component 1: MenuBar app core
//
//  Entry point + AppDelegate owning the NSStatusItem and NSPopover.
//  Targets: macOS 15+, Swift 5.10+, Xcode 16+.
//
//  Key ideas demonstrated:
//  - SwiftUI app with an AppKit AppDelegate (NSApplicationDelegateAdaptor)
//  - LSUIElement-style "menu bar only" app (no Dock icon)
//  - NSStatusItem with an SF Symbol icon that reflects app state
//  - NSPopover hosting a SwiftUI view (NSHostingController)
//  - Weak/unowned references and explicit teardown so nothing leaks
//

import SwiftUI
import AppKit

@main
struct QuillApp: App {
    // Bridges the AppKit delegate lifecycle into a SwiftUI `App`.
    // SwiftUI instantiates AppDelegate exactly once and keeps it alive
    // for the life of the process.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A menu bar app has no main window. `Settings` gives us a valid
        // (but empty) scene so SwiftUI is satisfied; the real UI lives in
        // the popover created by AppDelegate.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Owned objects
    // The delegate is the single owner of these. Everything else that
    // needs them receives a weak reference or is passed values.

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    /// Shared observable state for the whole app (recording flag, levels, vault URL).
    let appState = AppState()

    /// Global hotkey registration (Carbon). Owns unregistration in deinit.
    private var hotkeyManager: HotkeyManager?

    /// Monitors clicks *outside* the popover so we can close it.
    /// Event monitors MUST be removed or they leak and keep firing.
    private var eventMonitor: Any?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar apps should never grab focus at launch.
        NSApp.setActivationPolicy(.accessory)   // same effect as LSUIElement = YES

        configureStatusItem()
        configurePopover()
        configureHotkey()

        // Kick off permission onboarding on first run (async, non-blocking).
        Task { await PermissionsManager.shared.refreshStatuses() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Explicit teardown. Not strictly required at process exit, but it
        // is the habit that prevents leaks when this code is reused in
        // longer-lived contexts (tests, previews).
        removeEventMonitor()
        hotkeyManager = nil            // deinit unregisters the hotkey
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Status item

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "quote.bubble",
                                   accessibilityDescription: "Quill")
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Accept both left and right mouse-up so we can offer a
            // context menu later if we want to.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Update the icon whenever recording state changes.
        // [weak self] breaks the retain cycle:
        //   AppDelegate -> appState -> closure -> AppDelegate
        appState.onRecordingChanged = { [weak self] isRecording in
            self?.updateStatusIcon(recording: isRecording)
        }
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = recording ? "record.circle.fill" : "quote.bubble"
        button.image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: recording ? "Quill — recording" : "Quill")
        button.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient        // auto-close on outside interaction
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 420)
        // NSHostingController retains the SwiftUI view; the popover retains
        // the controller; the delegate retains the popover. Single chain,
        // no cycles.
        popover.contentViewController = NSHostingController(
            rootView: PopoverView().environmentObject(appState)
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // `.transient` handles most outside clicks, but not clicks in other
        // apps' status items; a global monitor covers that gap.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeEventMonitor()
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)  // REQUIRED — monitors leak otherwise
            self.eventMonitor = nil
        }
    }

    // MARK: - Global hotkey

    private func configureHotkey() {
        // ⌥⌘R toggles recording from anywhere, no Accessibility permission needed
        // because we use Carbon's RegisterEventHotKey, not an event tap.
        hotkeyManager = HotkeyManager(keyCode: KeyCode.r,
                                      modifiers: [.command, .option]) { [weak self] in
            self?.appState.toggleRecording()
        }
    }
}
