//  DiarizationTypes.swift
//  Quill — Module 3a (DiarizationEngine)
//
//  Shared value types for the diarization + transcription pipeline.
//  All are `Sendable` structs: value semantics = free thread-safety when
//  crossing actor boundaries.

import Foundation

/// One chunk of mono 16 kHz Float32 PCM audio delivered by AudioRecorderEngine.
public struct AudioChunk: Sendable {
    /// Samples in −1.0 … +1.0.
    public let samples: [Float]
    /// Seconds since the start of the recording session.
    public let startTime: TimeInterval

    /// Analysis sample rate for the whole module. The recorder downsamples
    /// mic/loopback audio to this before handing it to us.
    public static let sampleRate: Double = 16_000

    public init(samples: [Float], startTime: TimeInterval) {
        self.samples = samples
        self.startTime = startTime
    }
}

/// A contiguous stretch of a single speaker talking, in session time.
public struct SpeakerSegment: Sendable, Equatable {
    /// 1-based cluster ID ("Speaker 1" is ID 1).
    public var speakerID: Int
    public var start: TimeInterval
    public var end: TimeInterval

    public var duration: TimeInterval { end - start }
    public var speakerLabel: String { "Speaker \(speakerID)" }

    public init(speakerID: Int, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// One merged, speaker-attributed span of transcript text.
public struct Utterance: Sendable, Equatable {
    public let speakerLabel: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(speakerLabel: String, start: TimeInterval, end: TimeInterval, text: String) {
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Final product of Module 3a, consumed by LocalAIParsingEngine (3b).
public struct DiarizedTranscript: Sendable {
    public let utterances: [Utterance]
    public let speakerCount: Int
    public let duration: TimeInterval

    public init(utterances: [Utterance], speakerCount: Int, duration: TimeInterval) {
        self.utterances = utterances
        self.speakerCount = speakerCount
        self.duration = duration
    }

    /// Plain-text render, useful for clipboard copy and debugging.
    /// Example line: `[00:01:23] Speaker 2: Let's ship it Friday.`
    public var plainText: String {
        utterances.map { u in
            let s = Int(u.start)
            let stamp = String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            return "[\(stamp)] \(u.speakerLabel): \(u.text)"
        }.joined(separator: "\n")
    }
}
