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
import Combine

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
    private var levelSink: AnyCancellable?

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

        // Headless self-test: QUILL_PROCESS_FILE=<caf> runs the full
        // post-recording pipeline on an existing file, then quits.
        if let path = ProcessInfo.processInfo.environment["QUILL_PROCESS_FILE"] {
            let url = URL(fileURLWithPath: path)
            Task { @MainActor [appState] in
                do {
                    try await appState.process(fileURL: url, duration: 0,
                                               startedAt: Date())
                    Self.selfTestLog("QUILL_SELFTEST: \(appState.statusText)")
                } catch {
                    Self.selfTestLog("QUILL_SELFTEST FAILED: \(error)")
                }
                NSApp.terminate(nil)
            }
            return   // self-test runs never scan for orphans
        }

        // Crash resilience: finish any recording that never became a note.
        Task { @MainActor [appState] in
            await appState.recoverOrphanedRecordings()
        }
    }

    /// stderr is unbuffered, so this survives NSApp.terminate() (stdout
    /// redirected to a file is block-buffered and gets dropped).
    private static func selfTestLog(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
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

        // While recording, the icon doubles as a live input meter: the
        // waveform symbol's variableValue fills with mic level. Throttled to
        // ~7 fps — status-bar redraws are cheap but not free.
        levelSink = appState.$micLevel
            .throttle(for: .milliseconds(150), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] level in
                guard let self, self.appState.isRecording else { return }
                self.updateStatusIcon(recording: true, level: level)
            }
    }

    private func updateStatusIcon(recording: Bool, level: Float = 0) {
        guard let button = statusItem?.button else { return }
        if recording {
            button.image = NSImage(systemSymbolName: "waveform",
                                   variableValue: Double(min(max(level, 0), 1)),
                                   accessibilityDescription: "Quill — recording")
            button.contentTintColor = .systemRed
        } else {
            button.image = NSImage(systemSymbolName: "quote.bubble",
                                   accessibilityDescription: "Quill")
            button.contentTintColor = nil
        }
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
