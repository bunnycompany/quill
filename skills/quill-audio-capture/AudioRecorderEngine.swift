//  AudioRecorderEngine.swift
//  Quill — Module 2 (quill-audio-capture)
//
//  Captures microphone (AVAudioEngine) + system loopback audio
//  (ScreenCaptureKit, no third-party drivers), converts both to the canonical
//  16 kHz mono Float32 format, mixes them through bounded ring buffers, and
//  writes a CAF file. Exposes an AsyncStream of RMS levels for the UI meter.
//
//  Privacy: everything local. No network. Files only where the caller says.
//
//  Concurrency model:
//    * The engine is an ACTOR — all control-plane state is serialized.
//    * Audio taps run on real-time threads OUTSIDE the actor (`nonisolated`),
//      touching only lock-protected rings and thread-confined converters.
//    * A drain Task bridges real-time → async and owns file writing pacing.
//  Lifecycle guarantee: stop() (or cancellation) tears down everything
//  start() created, in producer → consumer → file → streams order.

import AVFoundation
import CoreMedia
import ScreenCaptureKit
import os

// MARK: - Public surface types

public struct RecordingResult: Sendable {
    public let url: URL              // finished .caf file
    public let duration: TimeInterval
    public let droppedSamples: Int   // > 0 means the UI should show a warning
}

public enum AudioCaptureError: Error {
    case notIdle, notRecording
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case noDisplay
    case fileCreationFailed(URL)
    case converterUnavailable
}

public struct AudioCaptureConfiguration: Sendable {
    public var captureSystemAudio: Bool = true
    public var outputDirectory: URL
    public var ringSeconds: Double = 10        // bounded buffer size per source
    public init(outputDirectory: URL) { self.outputDirectory = outputDirectory }
}

// MARK: - Canonical format

enum QuillAudio {
    /// 16 kHz mono Float32 non-interleaved — the one format all of Quill speaks.
    static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    static let sampleRate: Double = 16_000
}

// MARK: - Engine

public actor AudioRecorderEngine {

    private enum State { case idle, recording, stopping }
    private var state: State = .idle

    // -- capture graph (created in start(), destroyed in stop()) --
    private let avEngine = AVAudioEngine()
    private var scCapture: SystemAudioCapture?     // helper class, below
    private var micPipeline: ConversionPipeline?
    private var sysPipeline: ConversionPipeline?

    // -- rings (bounded!) --
    private var micRing: BoundedRingBuffer?
    private var sysRing: BoundedRingBuffer?

    // -- output --
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    private var framesWritten: AVAudioFramePosition = 0
    private var drainTask: Task<Void, Never>?

    // -- UI level meter --
    public private(set) var levelStream: AsyncStream<Float>!
    private var levelContinuation: AsyncStream<Float>.Continuation?

    private let log = Logger(subsystem: "com.quill.app", category: "audio")

    public init() {}

    // ============================================================ MARK: Start

    public func start(configuration cfg: AudioCaptureConfiguration) async throws {
        guard state == .idle else { throw AudioCaptureError.notIdle }

        // 1. Permissions — always ask BEFORE touching hardware.
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // 2. Output file. CAF: streams forever, no 4 GB WAV ceiling.
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let url = cfg.outputDirectory.appendingPathComponent("quill-\(stamp).caf")
        guard let file = try? AVAudioFile(
            forWriting: url,
            settings: QuillAudio.canonicalFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else { throw AudioCaptureError.fileCreationFailed(url) }
        audioFile = file
        fileURL = url
        framesWritten = 0

        // 3. Bounded rings — one per source, mixed in the drain task.
        let ringCapacity = Int(cfg.ringSeconds * QuillAudio.sampleRate)
        let micRing = BoundedRingBuffer(capacity: ringCapacity)
        let sysRing = BoundedRingBuffer(capacity: ringCapacity)
        self.micRing = micRing
        self.sysRing = sysRing

        // 4. Level stream for the popover meter.
        var cont: AsyncStream<Float>.Continuation!
        levelStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        levelContinuation = cont

        // 5. Mic tap. Tap in the HARDWARE format; convert ourselves.
        let input = avEngine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let micPipe = ConversionPipeline(from: hwFormat,
                                               to: QuillAudio.canonicalFormat,
                                               maxInputFrames: 4096) else {
            throw AudioCaptureError.converterUnavailable
        }
        micPipeline = micPipe
        // [weak self] breaks the engine→closure→self→engine retain cycle.
        // The closure body is `nonisolated` work: converter + ring only.
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
            micPipe.ingest(buffer, into: micRing)   // no self capture at all
        }
        avEngine.prepare()
        try avEngine.start()

        // 6. System loopback via ScreenCaptureKit.
        if cfg.captureSystemAudio {
            let capture = SystemAudioCapture()
            do {
                try await capture.start { [sysRing] pcmBuffer in
                    // Runs on SCK's sampleHandlerQueue (not the actor).
                    capture.pipeline?.ingest(pcmBuffer, into: sysRing)
                }
                scCapture = capture
            } catch {
                // Roll back what we built so far — start() is all-or-nothing.
                input.removeTap(onBus: 0)
                avEngine.stop()
                audioFile = nil
                cont.finish()
                throw AudioCaptureError.systemAudioPermissionDenied
            }
        }

        // 7. Drain task: real-time world → async world → disk + meter.
        drainTask = Task { [weak self] in
            // 200 ms scratch, allocated once. Bounded memory in the loop.
            let chunk = 3200
            var mic = [Float](repeating: 0, count: chunk)
            var sys = [Float](repeating: 0, count: chunk)
            var mix = [Float](repeating: 0, count: chunk)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let nMic = micRing.read(into: &mic)
                let nSys = sysRing.read(into: &sys)
                let n = max(nMic, nSys)
                guard n > 0 else { continue }
                // Sum with zero-fill for the shorter source, clip to [-1, 1].
                for i in 0..<n {
                    let a = i < nMic ? mic[i] : 0
                    let b = i < nSys ? sys[i] : 0
                    mix[i] = max(-1, min(1, a + b))
                }
                // Actor hop for the file write; weak self so a dead engine
                // ends the loop instead of being kept alive by its own task.
                guard let self else { break }
                await self.append(samples: mix, count: n)
            }
        }

        state = .recording
        log.info("Recording started → \(url.lastPathComponent, privacy: .public)")
    }

    // ============================================================= MARK: Stop

    /// Idempotent-ish teardown. Order matters:
    /// producers → drain → flush → file close → streams finished.
    public func stop() async throws -> RecordingResult {
        guard state == .recording else { throw AudioCaptureError.notRecording }
        state = .stopping

        // 1. Producers off (no more ring writes).
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        await scCapture?.stop()
        scCapture = nil

        // 2. Drain task: cancel, then WAIT — never race the file close.
        drainTask?.cancel()
        _ = await drainTask?.result
        drainTask = nil

        // 3. Flush whatever is still in the rings.
        await flushRemaining()

        // 4. Gather stats, finish streams so UI `for await` loops exit.
        let dropped = (micRing?.overrunCount ?? 0) + (sysRing?.overrunCount ?? 0)
        let duration = Double(framesWritten) / QuillAudio.sampleRate
        levelContinuation?.finish()
        levelContinuation = nil

        // 5. AVAudioFile has no close(); releasing it finalizes the header.
        let url = fileURL!
        audioFile = nil
        fileURL = nil
        micRing = nil
        sysRing = nil
        micPipeline = nil
        sysPipeline = nil

        state = .idle
        log.info("Recording stopped, \(duration, format: .fixed(precision: 1))s, dropped \(dropped)")
        return RecordingResult(url: url, duration: duration, droppedSamples: dropped)
    }

    // ===================================================== MARK: File writing

    /// Runs on the actor: AVAudioFile is not thread-safe, and the ring has
    /// already decoupled us from the real-time thread, so blocking briefly
    /// on disk here is fine.
    private func append(samples: [Float], count: Int) {
        guard let file = audioFile, count > 0 else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: QuillAudio.canonicalFormat,
                                         frameCapacity: AVAudioFrameCount(count))
        else { return }
        buf.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: count)
        }
        do {
            try file.write(from: buf)
            framesWritten += AVAudioFramePosition(count)
            levelContinuation?.yield(Self.rms(samples, count))
        } catch {
            log.error("File write failed: \(error.localizedDescription)")
        }
    }

    private func flushRemaining() async {
        guard let micRing, let sysRing else { return }
        var mic = [Float](repeating: 0, count: 3200)
        var sys = [Float](repeating: 0, count: 3200)
        var mix = [Float](repeating: 0, count: 3200)
        while true {
            let nMic = micRing.read(into: &mic)
            let nSys = sysRing.read(into: &sys)
            let n = max(nMic, nSys)
            guard n > 0 else { break }
            for i in 0..<n {
                mix[i] = max(-1, min(1, (i < nMic ? mic[i] : 0) + (i < nSys ? sys[i] : 0)))
            }
            append(samples: mix, count: n)
        }
    }

    static func rms(_ samples: [Float], _ count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        return (sum / Float(count)).squareRoot()
    }
}

// MARK: - ConversionPipeline
//
// One AVAudioConverter + one preallocated scratch buffer per source.
// REUSED across callbacks (converter filter state must persist) and
// confined to that source's callback thread — never shared.

final class ConversionPipeline: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let scratch: AVAudioPCMBuffer     // preallocated: zero alloc on hot path

    init?(from: AVAudioFormat, to: AVAudioFormat, maxInputFrames: AVAudioFrameCount) {
        guard let conv = AVAudioConverter(from: from, to: to) else { return nil }
        // Worst-case output frames for maxInputFrames, with 2x safety margin
        // (converters can hold and release frames across calls).
        let ratio = to.sampleRate / from.sampleRate
        let cap = AVAudioFrameCount((Double(maxInputFrames) * ratio * 2).rounded(.up)) + 64
        guard let buf = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: cap) else { return nil }
        converter = conv
        scratch = buf
    }

    /// Real-time-safe: no allocation, no locks except the ring's short one.
    func ingest(_ src: AVAudioPCMBuffer, into ring: BoundedRingBuffer?) {
        guard let ring else { return }
        var fed = false
        var err: NSError?
        scratch.frameLength = 0
        let status = converter.convert(to: scratch, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return src
        }
        guard status != .error,
              scratch.frameLength > 0,
              let ch = scratch.floatChannelData else { return }
        ring.write(ch[0], count: Int(scratch.frameLength))
    }
}

// MARK: - SystemAudioCapture
//
// Wraps SCStream's delegate/output plumbing (NSObject protocols) so the
// actor above stays pure Swift Concurrency. No third-party audio drivers:
// ScreenCaptureKit provides the OS-native loopback.

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private var stream: SCStream?
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "com.quill.audio.sck")
    private(set) var pipeline: ConversionPipeline?

    func start(_ onAudio: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        handler = onAudio

        // SCK's API is screen-centric: audio still needs a content filter.
        // "One display, exclude no windows" == all system audio.
        let content = try await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true   // Quill never records itself
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        // Minimize the video path we don't use.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let scFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 48_000, channels: 2,
                                     interleaved: false)!
        pipeline = ConversionPipeline(from: scFormat,
                                      to: QuillAudio.canonicalFormat,
                                      maxInputFrames: 4800)

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        handler = nil
    }

    // SCStreamOutput — called on `queue` with each audio CMSampleBuffer.
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              let handler,
              let fmtDesc = sampleBuffer.formatDescription,
              let asbd = fmtDesc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: withUnsafePointer(to: asbd) { $0 })
        else { return }

        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0 else { return }

        // Zero-copy view into the CMSampleBuffer's audio data. The pointers
        // are ONLY valid inside this closure — pipeline.ingest copies out
        // (ring write) before we return, so lifetime is respected.
        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                                 bufferListNoCopy: audioBufferList.unsafePointer)
                else { return }
                handler(pcm)
            }
        } catch {
            // Malformed buffer: drop it. Never crash the capture path.
        }
    }

    // SCStreamDelegate — fires if the user revokes screen-recording
    // permission mid-session. Surface it; the engine's stop() finalizes
    // the file instead of leaving it corrupt.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NotificationCenter.default.post(name: .quillSystemAudioStopped,
                                        object: nil,
                                        userInfo: ["error": error])
    }
}

public extension Notification.Name {
    static let quillSystemAudioStopped = Notification.Name("quill.systemAudioStopped")
}
