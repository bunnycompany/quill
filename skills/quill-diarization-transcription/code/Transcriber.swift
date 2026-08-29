//  Transcriber.swift
//  Quill — Module 3a (DiarizationEngine)
//
//  On-device transcription of the finished session WAV via
//  SFSpeechRecognizer. PRIVACY CONTRACT: requiresOnDeviceRecognition is
//  always true and supportsOnDeviceRecognition is checked first — we never
//  fall back to network recognition, silently or otherwise.
//
//  Requires Info.plist key NSSpeechRecognitionUsageDescription.

import Foundation
import Speech

enum TranscriberError: LocalizedError {
    case notAuthorized
    case onDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition permission was not granted. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .onDeviceUnavailable:
            return "On-device speech recognition is not available for this locale. Quill never sends audio off this Mac, so transcription is disabled."
        }
    }
}

actor Transcriber {

    struct Word: Sendable, Equatable {
        let text: String
        let start: TimeInterval
        let duration: TimeInterval
        var midpoint: TimeInterval { start + duration / 2 }
    }

    private var activeTask: SFSpeechRecognitionTask?

    /// Transcribe an audio file entirely on-device. Cancelling the calling
    /// Task promptly stops the recognizer (no CPU burned after Stop).
    func transcribe(fileURL: URL,
                    locale: Locale = Locale(identifier: "en_US")) async throws -> [Word] {

        // 1. Permission (system dialog appears once per install).
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriberError.notAuthorized }

        // 2. Recognizer with a local model available.
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw TranscriberError.onDeviceUnavailable
        }

        // 3. File-based request, pinned on-device.
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true   // NEVER change this.
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        // 4. Bridge callbacks → async/await, with cooperative cancellation.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Word], Error>) in
                // The handler can fire multiple times; a continuation may
                // resume exactly once (pitfall #3 in SKILL.md).
                var resumed = false
                let task = recognizer.recognitionTask(with: request) { result, error in
                    guard !resumed else { return }
                    if let error {
                        resumed = true
                        cont.resume(throwing: error)
                        return
                    }
                    guard let result, result.isFinal else { return } // partials: ignore
                    resumed = true
                    let words = result.bestTranscription.segments.map {
                        Word(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    cont.resume(returning: words)
                }
                self.activeTask = task
            }
        } onCancel: {
            // Runs on cancellation of the surrounding Task. Hop back onto
            // the actor to touch actor state.
            Task { await self.cancelActive() }
        }
    }

    private func cancelActive() {
        activeTask?.cancel()   // recognizer reports the cancellation as an
        activeTask = nil       // error → the continuation resumes throwing.
    }
}
