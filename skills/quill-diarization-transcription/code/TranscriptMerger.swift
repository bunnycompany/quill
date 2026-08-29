//  TranscriptMerger.swift
//  Quill — Module 3a (DiarizationEngine)
//
//  Pure functions that merge two timelines:
//    • diarization:   [SpeakerSegment]  — who was talking when
//    • transcription: [Transcriber.Word] — which word was said when
//  into speaker-attributed [Utterance].
//
//  No state, no actors — trivially unit-testable.

import Foundation

enum TranscriptMerger {

    /// Consecutive same-speaker words separated by more than this start a
    /// new utterance (paragraph break).
    static let maxIntraUtteranceGap: TimeInterval = 1.5

    static func merge(words: [Transcriber.Word],
                      segments: [SpeakerSegment]) -> [Utterance] {
        guard !words.isEmpty else { return [] }
        let sorted = segments.sorted { $0.start < $1.start }

        var utterances: [Utterance] = []
        var currentSpeaker: Int?
        var currentWords: [Transcriber.Word] = []

        func flush() {
            guard let sp = currentSpeaker, let first = currentWords.first,
                  let last = currentWords.last else { return }
            utterances.append(Utterance(
                speakerLabel: "Speaker \(sp)",
                start: first.start,
                end: last.start + last.duration,
                text: currentWords.map(\.text).joined(separator: " ")))
            currentWords.removeAll(keepingCapacity: true)
        }

        for word in words {
            // Fall back to the previous word's speaker when the word lands
            // in a VAD gap (recognizer timestamps are slightly loose).
            let sp = speaker(at: word.midpoint, in: sorted) ?? currentSpeaker ?? 1
            let gap = currentWords.last.map { word.start - ($0.start + $0.duration) } ?? 0
            if sp != currentSpeaker || gap > maxIntraUtteranceGap {
                flush()
                currentSpeaker = sp
            }
            currentWords.append(word)
        }
        flush()
        return utterances
    }

    /// Binary search for the segment containing time `t`.
    /// `segments` must be sorted by start and non-overlapping.
    static func speaker(at t: TimeInterval, in segments: [SpeakerSegment]) -> Int? {
        var lo = 0, hi = segments.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = segments[mid]
            if t < s.start {
                hi = mid - 1
            } else if t > s.end {
                lo = mid + 1
            } else {
                return s.speakerID
            }
        }
        return nil
    }
}
