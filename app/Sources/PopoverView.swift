//
//  PopoverView.swift
//  Quill — SwiftUI content of the status-item popover.
//
//  Record/stop button, live level meters, vault selector, permission
//  onboarding banner, and status line.
//

import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var permissions = PermissionsManager.shared

    // Held on AppState rather than @State: the @State macro can't expand
    // under this project's bare-swiftc build (no SwiftUIMacros plugin).
    private var page: AppState.PopoverPage { appState.popoverPage }

    var body: some View {
        VStack(spacing: 14) {
            header
            switch page {
            case .main: mainPage
            case .settings: settingsPage
            }
        }
        .padding(16)
        .frame(width: 320)
        .task {
            // Re-check permissions every time the popover appears.
            await permissions.refreshStatuses()
        }
    }

    // MARK: - Pages

    /// Primary page: just record, meters, and the vault. Everything else
    /// lives behind the gear.
    private var mainPage: some View {
        Group {
            if !permissions.allGranted
                || (appState.captureSystemAudio && permissions.screenStatus != .granted) {
                PermissionBanner(needsScreen: appState.captureSystemAudio)
            }
            recordButton
            meters
            vaultRow
            Divider()
            footer
        }
    }

    /// Secondary page: capture/cleanup settings and the processing queue.
    private var settingsPage: some View {
        Group {
            systemAudioToggle
            if AppleIntelligence.isAvailable {
                cleanupToggle
            }
            voicesToggle
            Divider()
            if appState.queue.isEmpty {
                Text("Nothing processing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                queueSection
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "quote.bubble.fill")
                .foregroundStyle(.tint)
            Text(page == .settings ? "Settings" : "Quill").font(.headline)
            Spacer()
            Text(appState.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Badge the gear while work is queued so the queue is
            // discoverable even though it moved off the main page.
            Button {
                appState.popoverPage = page == .main ? .settings : .main
            } label: {
                Image(systemName: page == .main
                      ? (appState.queue.isEmpty ? "gearshape" : "gearshape.badge")
                      : "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(page == .main ? "Settings & activity" : "Back")
        }
    }

    private var recordButton: some View {
        Button {
            appState.toggleRecording()
        } label: {
            Label(
                appState.isRecording
                    ? "Stop  ·  \(formatted(appState.elapsed))"
                    : "Start Recording",
                systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(appState.isRecording ? .red : .accentColor)
        .disabled(!permissions.allGranted || appState.isProcessing)
        .keyboardShortcut("r", modifiers: [.command])   // works while popover has focus
    }

    private var meters: some View {
        VStack(spacing: 8) {
            LevelMeter(label: "Mic", level: appState.micLevel)
            if appState.captureSystemAudio {
                LevelMeter(label: "System", level: appState.systemLevel)
            }
        }
    }

    private var systemAudioToggle: some View {
        Toggle("Capture system audio", isOn: $appState.captureSystemAudio)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.callout)
            .disabled(appState.isRecording)
    }

    /// Only rendered when the on-device model is actually available.
    private var cleanupToggle: some View {
        Toggle("Clean up transcript (Apple Intelligence)",
               isOn: $appState.cleanupEnabled)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.callout)
    }

    /// Cross-meeting speaker recognition (local voice profiles).
    private var voicesToggle: some View {
        Toggle("Recognize known voices", isOn: $appState.voiceRecognitionEnabled)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.callout)
    }

    /// Compact processing queue: current item, waiting backlog, brief outcomes.
    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Processing")
                .font(.caption2.smallCaps())
                .foregroundStyle(.secondary)
            ForEach(appState.queue) { item in
                HStack(spacing: 6) {
                    switch item.state {
                    case .processing:
                        ProgressView().controlSize(.mini)
                    case .waiting:
                        Image(systemName: "clock").foregroundStyle(.secondary)
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Text(item.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if case .processing = item.state {
                        Text(appState.statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var vaultRow: some View {
        HStack {
            Image(systemName: "folder")
            Text(appState.vaultURL?.lastPathComponent ?? "No vault selected")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…", action: chooseVault)
                .controlSize(.small)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Text("⌥⌘R toggles recording")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }

    // MARK: - Actions

    private func chooseVault() {
        // Accessory apps are never "active", so a modal panel presented without
        // activation can't become key — its controls ignore clicks.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.level = .modalPanel
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Vault"
        panel.message = "Choose your Obsidian vault folder"
        if panel.runModal() == .OK, let url = panel.url {
            appState.setVault(url: url)
        }
    }

    private func formatted(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Level meter

/// A lightweight horizontal audio meter. Pure SwiftUI — GeometryReader sizes
/// the fill bar; no timers or animations run when the level is static.
struct LevelMeter: View {
    let label: String
    let level: Float          // 0...1

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private var color: Color {
        switch level {
        case ..<0.6: .green
        case ..<0.85: .yellow
        default: .red
        }
    }
}

// MARK: - Permission onboarding banner

struct PermissionBanner: View {
    var needsScreen = false
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permissions needed", systemImage: "exclamationmark.shield")
                .font(.callout.bold())

            if permissions.micStatus != .granted {
                permissionRow(
                    title: "Microphone",
                    granted: false,
                    action: { Task { await permissions.requestMicrophone() } }
                )
            }
            if needsScreen && permissions.screenStatus != .granted {
                permissionRow(
                    title: "Screen Recording (system audio)",
                    granted: false,
                    action: { permissions.requestScreenCapture() }
                )
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private func permissionRow(title: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            Text(title).font(.caption)
            Spacer()
            if !granted {
                Button("Grant", action: action).controlSize(.small)
            }
        }
    }
}

