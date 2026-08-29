//
//  PermissionsManager.swift
//  Quill — microphone + screen-recording permission onboarding.
//
//  Quill needs two TCC permissions:
//  - Microphone   (AVFoundation)      → for the user's voice
//  - Screen Recording (ScreenCaptureKit) → macOS gates *system audio*
//    loopback capture behind the Screen Recording permission, even when we
//    never capture pixels.
//
//  Nothing leaves the machine — the permissions exist purely so the local
//  AudioRecorderEngine can read audio.
//

import Foundation
import AVFoundation
import CoreGraphics
import AppKit

@MainActor
final class PermissionsManager: ObservableObject {

    static let shared = PermissionsManager()
    private init() {}

    enum Status { case unknown, granted, denied }

    @Published private(set) var micStatus: Status = .unknown
    @Published private(set) var screenStatus: Status = .unknown

    var allGranted: Bool { micStatus == .granted && screenStatus == .granted }

    // MARK: - Refresh

    /// Cheap, side-effect-free checks. Call whenever the popover opens.
    func refreshStatuses() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:               micStatus = .granted
        case .denied, .restricted:      micStatus = .denied
        case .notDetermined:            micStatus = .unknown
        @unknown default:               micStatus = .unknown
        }

        // CGPreflightScreenCaptureAccess never shows UI; it just answers.
        screenStatus = CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    // MARK: - Requests

    /// Shows the system microphone prompt (first time only). If the user
    /// previously denied, the prompt will NOT reappear — send them to
    /// System Settings instead.
    func requestMicrophone() async {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        if current == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micStatus = granted ? .granted : .denied
        } else if current != .authorized {
            openSystemSettings(pane: "Privacy_Microphone")
        }
        await refreshStatuses()
    }

    /// Screen Recording has no in-app prompt API that returns a result;
    /// CGRequestScreenCaptureAccess() triggers the system dialog once, and
    /// the user must then relaunch-toggle the app in System Settings.
    func requestScreenCapture() {
        if !CGPreflightScreenCaptureAccess() {
            let prompted = CGRequestScreenCaptureAccess()
            if !prompted {
                openSystemSettings(pane: "Privacy_ScreenCapture")
            }
        }
        Task { await refreshStatuses() }
    }

    // MARK: - Helpers

    private func openSystemSettings(pane: String) {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}
