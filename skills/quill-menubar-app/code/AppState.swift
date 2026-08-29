//
//  AppState.swift
//  Quill — shared observable state for the menu bar app.
//
//  One source of truth, owned by AppDelegate, injected into SwiftUI via
//  .environmentObject(). Marked @MainActor: every mutation happens on the
//  main thread, so SwiftUI never sees a torn update.
//

import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published UI state

    /// True while the AudioRecorderEngine is capturing.
    @Published private(set) var isRecording = false

    /// 0.0 ... 1.0 smoothed microphone level for the meter.
    @Published var micLevel: Float = 0

    /// 0.0 ... 1.0 smoothed system-audio (loopback) level.
    @Published var systemLevel: Float = 0

    /// Seconds elapsed in the current recording.
    @Published private(set) var elapsed: TimeInterval = 0

    /// The user's Obsidian vault folder, restored from a security-scoped bookmark.
    @Published private(set) var vaultURL: URL?

    /// Human-readable status line ("Idle", "Recording…", "Transcribing…").
    @Published var statusText = "Idle"

    // MARK: - Callbacks (AppKit side listens without Combine)

    /// AppDelegate sets this to update the status-bar icon.
    /// Stored closure => the CALLER must use [weak self] when it captures
    /// an object that (transitively) owns AppState.
    var onRecordingChanged: ((Bool) -> Void)?

    // MARK: - Private

    private var timerTask: Task<Void, Never>?
    private static let bookmarkKey = "quill.vault.bookmark"

    init() {
        restoreVaultBookmark()
    }

    // MARK: - Recording control

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        statusText = "Recording…"
        elapsed = 0
        onRecordingChanged?(true)

        // Structured-concurrency timer. Cancelling the task ends the loop;
        // no Timer object to invalidate, no runloop retain to forget.
        timerTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
        // Component 2 (AudioRecorderEngine) is started here in the full app.
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        statusText = "Idle"
        onRecordingChanged?(false)

        // Cancellation cleanup: kill the timer task and drop the reference.
        timerTask?.cancel()
        timerTask = nil
        micLevel = 0
        systemLevel = 0
    }

    // MARK: - Vault selection (security-scoped bookmarks)

    /// Sandboxed apps lose access to user-picked folders on relaunch unless
    /// they store a *security-scoped bookmark* and resolve it at startup.
    func setVault(url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            vaultURL = url
        } catch {
            statusText = "Vault error: \(error.localizedDescription)"
        }
    }

    private func restoreVaultBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            // Must balance every start with a stop; here we hold access for
            // the app's lifetime, releasing implicitly at exit.
            _ = url.startAccessingSecurityScopedResource()
            vaultURL = url
            if stale { setVault(url: url) }   // refresh the bookmark
        }
    }
}
