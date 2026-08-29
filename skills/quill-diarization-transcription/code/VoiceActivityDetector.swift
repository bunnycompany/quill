//  VoiceActivityDetector.swift
//  Quill — Module 3a (DiarizationEngine)
//
//  Energy + zero-crossing VAD with an adaptive noise floor and
//  hangover smoothing. Fed one 25 ms window at a time; emits a finished
//  (start, end) speech range when one closes.
//
//  Plain final class (not an actor): it is owned by, and only ever called
//  from inside, the DiarizationEngine actor.

import Foundation

struct VADSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
}

final class VoiceActivityDetector {

    // MARK: Tunables

    /// Threshold = max(noiseFloor × this, absoluteMinRMS).
    var noiseMultiplier: Float = 3.0
    /// Never treat anything quieter than this as speech (dead-silent rooms).
    var absoluteMinRMS: Float = 0.003
    /// ZCR above this with our energies is broadband noise, not speech.
    var maxSpeechZCR: Float = 0.35
    /// Consecutive speech windows required to ENTER speech (3 ≈ 30 ms).
    var minSpeechWindows = 3
    /// Consecutive silent windows required to LEAVE speech (25 ≈ 250 ms):
    /// lets short pauses between words stay inside one segment.
    var hangoverWindows = 25
    /// Segments shorter than this are dropped (coughs, key clicks).
    var minSegmentDuration: TimeInterval = 0.3

    // MARK: State machine

    private enum State {
        case silence
        case maybeSpeech(run: Int, firstStart: TimeInterval)
        case speech(start: TimeInterval, silentRun: Int, lastSpeechEnd: TimeInterval)
    }

    private var state: State = .silence
    /// Exponential moving average of non-speech RMS.
    private var noiseFloor: Float = 0.003

    private let windowDuration = TimeInterval(AudioFeatureExtractor.windowSize) / AudioChunk.sampleRate

    /// True while a segment is currently open (engine accumulates mel
    /// frames only during this).
    var isInSpeech: Bool {
        if case .speech = state { return true }
        return false
    }

    /// Feed one window. Returns a finished segment iff one just closed.
    func process(rms: Float, zcr: Float, windowStart: TimeInterval) -> VADSegment? {
        let threshold = max(noiseFloor * noiseMultiplier, absoluteMinRMS)
        let isSpeechWindow = rms > threshold && zcr < maxSpeechZCR
        let windowEnd = windowStart + windowDuration

        // Track the noise floor only from windows we call non-speech,
        // so loud talking never inflates it.
        if !isSpeechWindow {
            noiseFloor = 0.95 * noiseFloor + 0.05 * rms
        }

        switch state {
        case .silence:
            if isSpeechWindow {
                state = .maybeSpeech(run: 1, firstStart: windowStart)
            }
            return nil

        case let .maybeSpeech(run, firstStart):
            if isSpeechWindow {
                if run + 1 >= minSpeechWindows {
                    // Confirmed: backdate the start to the first candidate window.
                    state = .speech(start: firstStart, silentRun: 0, lastSpeechEnd: windowEnd)
                } else {
                    state = .maybeSpeech(run: run + 1, firstStart: firstStart)
                }
            } else {
                state = .silence // flicker — abandon the candidate
            }
            return nil

        case let .speech(start, silentRun, lastSpeechEnd):
            if isSpeechWindow {
                state = .speech(start: start, silentRun: 0, lastSpeechEnd: windowEnd)
                return nil
            }
            let newRun = silentRun + 1
            if newRun >= hangoverWindows {
                state = .silence
                let seg = VADSegment(start: start, end: lastSpeechEnd)
                return seg.end - seg.start >= minSegmentDuration ? seg : nil
            }
            state = .speech(start: start, silentRun: newRun, lastSpeechEnd: lastSpeechEnd)
            return nil
        }
    }

    /// Call at end-of-stream: closes any segment still open.
    func flush() -> VADSegment? {
        defer { state = .silence }
        if case let .speech(start, _, lastSpeechEnd) = state,
           lastSpeechEnd - start >= minSegmentDuration {
            return VADSegment(start: start, end: lastSpeechEnd)
        }
        return nil
    }
}
