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

    var body: some View {
        VStack(spacing: 14) {
            header
            if !permissions.allGranted {
                PermissionBanner()
            }
            recordButton
            meters
            vaultRow
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .task {
            // Re-check permissions every time the popover appears.
            await permissions.refreshStatuses()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "quote.bubble.fill")
                .foregroundStyle(.tint)
            Text("Quill").font(.headline)
            Spacer()
            Text(appState.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .disabled(!permissions.allGranted)
        .keyboardShortcut("r", modifiers: [.command])   // works while popover has focus
    }

    private var meters: some View {
        VStack(spacing: 8) {
            LevelMeter(label: "Mic", level: appState.micLevel)
            LevelMeter(label: "System", level: appState.systemLevel)
        }
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
        let panel = NSOpenPanel()
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
            if permissions.screenStatus != .granted {
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

#Preview {
    PopoverView().environmentObject(AppState())
}
