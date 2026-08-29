//  DiarizationEngine.swift
//  Quill — Module 3a (DiarizationEngine)
//
//  The actor that owns the whole pipeline:
//
//    AsyncStream<AudioChunk> ─► windows ─► VAD ─► segment ─► embedding
//                                                     │
//                                                     ▼
//                                          online clusterer → Speaker N
//    session WAV ─► Transcriber (on-device) ─► words
//                                                     │
//                              TranscriptMerger ◄─────┘
//                                     │
//                                     ▼
//                             DiarizedTranscript
//
//  MEMORY CONTRACT (project rule "zero leaks, bounded buffers"):
//    • `pending` never exceeds windowSize + one incoming chunk — consumed
//      samples are dropped every window, with an O(1) read index instead
//      of O(n) Array.removeFirst.
//    • mel frames are accumulated only while a VAD segment is OPEN and
//      released the instant it closes and is embedded.
//    • every loop iteration is a cancellation point.

import Foundation

actor DiarizationEngine {

    enum Progress: Sendable {
        case listening(speakers: Int)
        case transcribing
        case merging
        case done
    }

    // MARK: Pipeline components (single-threaded helpers guarded by this actor)

    private let extractor = AudioFeatureExtractor()
    private let vad = VoiceActivityDetector()
    private let embedder: any SpeakerEmbedding
    private let clusterer: OnlineSpeakerClusterer

    // MARK: Bounded state

    /// Samples awaiting analysis. Compacted every window — see `ingest`.
    private var pending: [Float] = []
    /// Index of the next unconsumed sample in `pending` (O(1) "removeFirst").
    private var readIndex = 0
    /// Session time of `pending[readIndex]`.
    private var pendingStartTime: TimeInterval = 0
    /// Mel frames of the currently OPEN VAD segment only.
    private var melAccumulator: [[Float]] = []
    /// Finished, speaker-labeled segments (small: a few per minute).
    private var segments: [SpeakerSegment] = []

    private var progressContinuation: AsyncStream<Progress>.Continuation?

    init(embedder: any SpeakerEmbedding = LogMelStatsEmbedder(),
         similarityThreshold: Float = 0.85,
         maxSpeakers: Int = 8) {
        self.embedder = embedder
        self.clusterer = OnlineSpeakerClusterer(similarityThreshold: similarityThreshold,
                                                maxSpeakers: maxSpeakers)
    }

    /// UI-facing progress. `for await p in engine.progress()` in the popover.
    func progress() -> AsyncStream<Progress> {
        AsyncStream { continuation in
            self.progressContinuation = continuation
        }
    }

    // MARK: Phase 1 — live analysis

    /// Consume the recorder's stream until it finishes (Stop) or the
    /// surrounding Task is cancelled.
    func run(stream: AsyncStream<AudioChunk>) async throws {
        for await chunk in stream {
            try Task.checkCancellation()   // cooperative cancellation point
            ingest(chunk)
        }
        // Stream ended: close any segment still open.
        if let seg = vad.flush() {
            closeSegment(seg)
        }
    }

    private func ingest(_ chunk: AudioChunk) {
        if pending.isEmpty && readIndex == 0 {
            pendingStartTime = chunk.startTime
        }
        pending.append(contentsOf: chunk.samples)

        let win = AudioFeatureExtractor.windowSize
        let hop = AudioFeatureExtractor.hopSize

        // Peel off every complete window, sliding by `hop`.
        while pending.count - readIndex >= win {
            let window = Array(pending[readIndex ..< readIndex + win])
            let t = pendingStartTime + TimeInterval(readIndex) / AudioChunk.sampleRate

            let rms = extractor.rms(window)
            let zcr = extractor.zeroCrossingRate(window)

            let wasInSpeech = vad.isInSpeech
            let finished = vad.process(rms: rms, zcr: zcr, windowStart: t)

            if vad.isInSpeech || wasInSpeech {
                // Segment open (or just closed this window): keep features.
                melAccumulator.append(extractor.logMel(window))
            }
            if let seg = finished {
                closeSegment(seg)
            }

            readIndex += hop
        }

        // Compact: drop consumed samples so `pending` stays bounded.
        // Done in bulk (not per hop) so the copy cost is amortized.
        if readIndex > 8 * win {
            pending.removeFirst(readIndex)
            pendingStartTime += TimeInterval(readIndex) / AudioChunk.sampleRate
            readIndex = 0
        }
    }

    /// Embed the closed segment, assign a speaker, release its features.
    private func closeSegment(_ seg: VADSegment) {
        let frames = melAccumulator
        melAccumulator.removeAll(keepingCapacity: true) // release NOW — bounded memory
        guard !frames.isEmpty else { return }

        let embedding = embedder.embed(melFrames: frames)
        let id = clusterer.assign(embedding, duration: seg.end - seg.start)
        segments.append(SpeakerSegment(speakerID: id, start: seg.start, end: seg.end))
        progressContinuation?.yield(.listening(speakers: clusterer.clusters.count))
    }

    // MARK: Phase 2 — transcription + merge (after recording stops)

    /// `audioFileURL`: the finished session WAV written by AudioRecorderEngine.
    func finish(audioFileURL: URL,
                locale: Locale = Locale(identifier: "en_US")) async throws -> DiarizedTranscript {
        progressContinuation?.yield(.transcribing)
        let words = try await Transcriber().transcribe(fileURL: audioFileURL, locale: locale)

        try Task.checkCancellation()
        progressContinuation?.yield(.merging)

        // Renumber so Speaker 1 = most speaking time (stable, meaningful labels).
        let relabeled = clusterer.relabelBySpeakingTime(segments: segments)
        let utterances = TranscriptMerger.merge(words: words, segments: relabeled)

        progressContinuation?.yield(.done)
        progressContinuation?.finish()

        return DiarizedTranscript(utterances: utterances,
                                  speakerCount: clusterer.clusters.count,
                                  duration: segments.last?.end ?? 0)
    }
}
