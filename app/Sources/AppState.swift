//
//  AppState.swift
//  Quill — shared observable state + pipeline orchestration.
//
//  Owns the AudioRecorderEngine and, on stop, runs the full pipeline:
//  diarization → on-device transcription → note structuring →
//  Obsidian export → SQLite history.
//

import Foundation
import Combine
import AVFoundation
import CryptoKit

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var isRecording = false
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var vaultURL: URL?
    @Published var statusText = "Idle"
    /// SECONDARY path: system-audio loopback via ScreenCaptureKit. Off by default.
    @Published var captureSystemAudio = false
    /// True while the post-stop pipeline (transcribe/parse/export) runs.
    @Published private(set) var isProcessing = false
    /// Visible pipeline queue: the item being processed plus anything waiting
    /// (e.g. recovered recordings). Empty when idle.
    @Published private(set) var queue: [QueueItem] = []

    /// Which page the popover shows. Lives here because the bare-swiftc
    /// build can't expand SwiftUI's @State macro inside views.
    enum PopoverPage { case main, settings }
    @Published var popoverPage: PopoverPage = .main

    struct QueueItem: Identifiable, Equatable {
        let id: String          // audio path
        let label: String       // human name, e.g. "Meeting 16:51 (72 min)"
        var state: State
        enum State: Equatable { case waiting, processing, done, failed(String) }
    }
    /// Optional Apple Intelligence transcript cleanup. OFF by default;
    /// only offered in the UI when the on-device model is available.
    @Published var cleanupEnabled = UserDefaults.standard.bool(forKey: "quill.cleanup.enabled") {
        didSet { UserDefaults.standard.set(cleanupEnabled, forKey: Self.cleanupKey) }
    }
    /// Cross-meeting speaker recognition (local voice profiles). Default ON.
    /// When off, matching AND enrollment are skipped, but per-meeting
    /// centroids are still stored so nothing is lost.
    @Published var voiceRecognitionEnabled: Bool =
        UserDefaults.standard.object(forKey: "quill.voices.enabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "quill.voices.enabled") {
        didSet { UserDefaults.standard.set(voiceRecognitionEnabled, forKey: Self.voicesKey) }
    }

    var onRecordingChanged: ((Bool) -> Void)?

    // MARK: - Engines

    private let recorder = AudioRecorderEngine()
    private let exporter = ObsidianExporter()
    private let lexiconStore = LexiconStore()
    private var store: QuillStore?

    private var timerTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private static let bookmarkKey = "quill.vault.bookmark"
    private static let cleanupKey = "quill.cleanup.enabled"
    private static let voicesKey = "quill.voices.enabled"
    /// Conservative cosine-similarity threshold for voice matching — the
    /// current log-mel-stats embedder is weak, so only very confident matches
    /// get a name, and even those are suffixed "(?)".
    private static let voiceMatchThreshold: Float = 0.92

    init() {
        restoreVaultBookmark()
        do {
            store = try QuillStore(url: try QuillStore.defaultURL())
        } catch {
            statusText = "History DB error: \(error.localizedDescription)"
        }
    }

    // MARK: - Recording control

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording, pipelineTask == nil else { return }
        isRecording = true
        statusText = "Recording…"
        elapsed = 0
        onRecordingChanged?(true)

        timerTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }

        let wantSystem = captureSystemAudio
        pipelineTask = Task { [weak self] in
            await self?.runSession(captureSystem: wantSystem)
            await MainActor.run { self?.pipelineTask = nil }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged?(false)
        timerTask?.cancel()
        timerTask = nil
        levelTask?.cancel()
        levelTask = nil
        micLevel = 0
        systemLevel = 0
        statusText = "Processing…"
        Task { await recorder.requestStop() }   // unblocks runSession
    }

    // MARK: - Session pipeline

    private func runSession(captureSystem: Bool) async {
        let startedAt = Date()
        do {
            var cfg = AudioCaptureConfiguration(outputDirectory: try Self.audioDirectory())
            cfg.captureSystemAudio = captureSystem
            try await recorder.start(configuration: cfg)

            // Level meter: consume the engine's RMS stream while recording.
            let levels = await recorder.levelStream!
            levelTask = Task { [weak self] in
                for await rms in levels {
                    guard let self else { return }
                    self.micLevel = min(1, rms * 8)
                    if captureSystem { self.systemLevel = self.micLevel }
                }
            }

            // Wait here until stopRecording() fires.
            let result = try await recorder.waitForStop()

            isProcessing = true
            defer { isProcessing = false }

            try await process(fileURL: result.url, duration: result.duration,
                              startedAt: startedAt)
        } catch is CancellationError {
            statusText = "Cancelled"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
        // Ensure UI state is consistent if start() itself failed.
        if isRecording {
            isRecording = false
            onRecordingChanged?(false)
            timerTask?.cancel(); timerTask = nil
        }
    }

    /// Runs diarize → transcribe → structure → export → history on an audio
    /// file. Shared by live sessions and the QUILL_PROCESS_FILE self-test.
    func process(fileURL: URL, duration: TimeInterval, startedAt: Date) async throws {
        let mins = duration > 0 ? " (\(Int(duration / 60)) min)" : ""
        enqueue(QueueItem(id: fileURL.path,
                          label: Self.queueFormatter.string(from: startedAt) + mins,
                          state: .processing))
        defer {
            // Done/failed items linger briefly so the user sees the outcome.
            setQueueState(id: fileURL.path,
                          to: statusText.hasPrefix("Error") ? .failed(statusText) : .done)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.queue.removeAll { $0.id == fileURL.path && $0.state != .processing }
            }
        }
        do {
            // ---- Diarization + transcription -------------------------------
            statusText = "Transcribing…"
            // Custom vocabulary: cached lexicon is available immediately;
            // background rebuilds (vault selection, exports) keep it fresh.
            let lexicon = await lexiconStore.lexicon()
            let diarizer = DiarizationEngine()
            try await diarizer.run(stream: Self.chunkStream(fileURL: fileURL))
            let transcript = try await diarizer.finish(audioFileURL: fileURL,
                                                       lexicon: lexicon)

            guard !transcript.utterances.isEmpty else {
                statusText = "No speech detected"
                return
            }

            // ---- Voice recognition (local profiles, opt-out) ---------------
            // Match each cluster centroid against stored voice profiles.
            // Matched clusters get the profile name with an explicit "(?)"
            // suffix — never plain — so the user knows the name is inferred.
            var labelMap: [String: String] = [:]
            if voiceRecognitionEnabled, let store {
                let profiles = (try? await store.allProfiles()) ?? []
                for (speakerID, centroid) in transcript.speakerCentroids {
                    guard let best = profiles
                        .map({ (name: $0.name, sim: Self.cosine(centroid, $0.centroid)) })
                        .max(by: { $0.sim < $1.sim }),
                        best.sim >= Self.voiceMatchThreshold else { continue }
                    labelMap["Speaker \(speakerID)"] = "\(best.name) (?)"
                }
            }

            // ---- Note structuring (rule-based, fully local) ----------------
            statusText = "Structuring notes…"
            let segments = transcript.utterances.map {
                TranscriptSegment(speaker: labelMap[$0.speakerLabel] ?? $0.speakerLabel,
                                  text: $0.text,
                                  start: $0.start, end: $0.end)
            }
            let title = "Meeting \(Self.titleFormatter.string(from: startedAt))"
            let note = try await LocalAIParsingEngine().makeNote(
                from: segments,
                metadata: MeetingMetadata(title: title, date: startedAt,
                                          duration: duration),
                cleanupEnabled: cleanupEnabled,
                lexicon: lexicon)

            // ---- Obsidian export -------------------------------------------
            var exportedURL: URL?
            if let vaultURL {
                statusText = "Exporting…"
                // Learn speaker names the user renamed in earlier exports,
                // then refresh the lexicon for the NEXT recording. A rename
                // also enrolls that speaker's voice profile (when enabled).
                await lexiconStore.learnFromEdits(vaultURL: vaultURL,
                                                  store: store,
                                                  enrollVoices: voiceRecognitionEnabled)
                exportedURL = try await exporter.export(note: note, vaultURL: vaultURL,
                                                        audioURL: fileURL)
            }

            // ---- SQLite history --------------------------------------------
            if let store {
                let hash = Self.sha256(of: fileURL)
                let recordingID = try await store.insertRecording(
                    startedAt: startedAt, title: title,
                    audioPath: fileURL.path, contentHash: hash)
                try await store.updateDuration(recordingID: recordingID,
                                               seconds: duration)
                // Indices come from the ORIGINAL "Speaker N" labels, not the
                // (possibly renamed) note labels, so they stay aligned with
                // meeting_speaker rows.
                try await store.insertSegments(transcript.utterances.map {
                    Segment(id: 0, recordingID: recordingID,
                            speakerIndex: Self.speakerIndex($0.speakerLabel),
                            startSeconds: $0.start, endSeconds: $0.end,
                            text: $0.text)
                }, recordingID: recordingID)
                // Persist per-speaker centroids (0-based, matching
                // segment.speaker_index) even when recognition is off, so a
                // later rename can still be traced to its voice.
                var centroidsByIndex: [Int: [Float]] = [:]
                for (speakerID, centroid) in transcript.speakerCentroids {
                    centroidsByIndex[speakerID - 1] = centroid
                }
                try await store.saveMeetingSpeakers(recordingID: recordingID,
                                                    centroids: centroidsByIndex)
                try await store.saveNote(ParsedNote(
                    attendees: note.attendees,
                    actionItems: note.actionItems.map { "\($0.task) (\($0.owner))" },
                    keyTakeaways: note.keyTakeaways,
                    markdown: note.renderMarkdown()), recordingID: recordingID)
                if let exportedURL {
                    try await store.markExported(recordingID: recordingID,
                                                 path: exportedURL.path)
                }
            }

            statusText = exportedURL.map { "Saved \($0.lastPathComponent)" }
                ?? "Done (no vault selected)"
        } catch is CancellationError {
            statusText = "Cancelled"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Crash recovery

    /// Finds audio files that never became an exported note (crash, force-quit,
    /// power loss mid-processing) and finishes them. Runs at launch.
    func recoverOrphanedRecordings() async {
        guard let store else { return }
        do {
            let exported = try await store.exportedAudioPaths()
            let dir = try Self.audioDirectory()
            let files = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "caf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            // Surface everything we're about to recover before starting, so
            // the popover shows the whole backlog, not just the active item.
            let pending = files.filter { !exported.contains($0.path) }
            for url in pending {
                enqueue(QueueItem(id: url.path,
                                  label: "Recovered · " + url.lastPathComponent,
                                  state: .waiting))
            }

            for url in files where !exported.contains(url.path) {
                // Skip files still being written (active recording).
                let mtime = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard Date().timeIntervalSince(mtime) > 60 else { continue }

                guard let file = try? AVAudioFile(forReading: url) else { continue }
                let duration = Double(file.length) / file.processingFormat.sampleRate
                guard duration > 5 else { continue }   // ignore stub files

                statusText = "Recovering \(url.lastPathComponent)…"
                let startedAt = Self.startDate(fromFileName: url.lastPathComponent) ?? mtime
                try await process(fileURL: url, duration: duration, startedAt: startedAt)
            }
        } catch {
            statusText = "Recovery error: \(error.localizedDescription)"
        }
    }

    // MARK: - Queue bookkeeping

    private func enqueue(_ item: QueueItem) {
        if let i = queue.firstIndex(where: { $0.id == item.id }) {
            queue[i].state = item.state
        } else {
            queue.append(item)
        }
    }

    private func setQueueState(id: String, to state: QueueItem.State) {
        if let i = queue.firstIndex(where: { $0.id == id }) { queue[i].state = state }
    }

    private static let queueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    /// "quill-2026-08-14T23-51-15Z.caf" -> Date
    private static func startDate(fromFileName name: String) -> Date? {
        guard name.hasPrefix("quill-"), name.hasSuffix(".caf") else { return nil }
        let stamp = String(name.dropFirst(6).dropLast(4))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f.date(from: stamp)
    }

    // MARK: - Helpers

    /// Reads the finished 16 kHz mono CAF back as 1-second AudioChunks.
    private static func chunkStream(fileURL: URL) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                guard let file = try? AVAudioFile(forReading: fileURL,
                                                  commonFormat: .pcmFormatFloat32,
                                                  interleaved: false) else { return }
                let format = file.processingFormat
                let chunkFrames: AVAudioFrameCount = 16_000
                guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: chunkFrames) else { return }
                var t: TimeInterval = 0
                while file.framePosition < file.length {
                    do { try file.read(into: buf, frameCount: chunkFrames) }
                    catch { break }
                    let n = Int(buf.frameLength)
                    guard n > 0, let ch = buf.floatChannelData else { break }
                    let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
                    continuation.yield(AudioChunk(samples: samples, startTime: t))
                    t += TimeInterval(n) / AudioChunk.sampleRate
                }
            }
        }
    }

    private static func audioDirectory() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("Quill/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return UUID().uuidString
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Cosine similarity; inputs are L2-normalized so the dot product is it,
    /// but guard against length mismatches from an older embedder version.
    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }

    private static func speakerIndex(_ label: String) -> Int {
        (Int(label.split(separator: " ").last.map(String.init) ?? "1") ?? 1) - 1
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Vault selection (security-scoped bookmarks)

    func setVault(url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            vaultURL = url
            rebuildLexicon(for: url)
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
            _ = url.startAccessingSecurityScopedResource()
            vaultURL = url
            if stale { setVault(url: url) }
            rebuildLexicon(for: url)
        }
    }

    /// Fire-and-forget vault scan; the LexiconStore actor serializes it and
    /// persists a cache so future launches have vocabulary immediately.
    private func rebuildLexicon(for url: URL) {
        let store = lexiconStore
        Task.detached(priority: .utility) {
            await store.rebuild(vaultURL: url)
        }
    }
}
