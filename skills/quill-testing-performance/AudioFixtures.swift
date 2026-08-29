//
//  AudioFixtures.swift
//  QuillTests — deterministic, generated PCM fixtures.
//
//  Why generated instead of .wav files on disk?
//    * Deterministic: same samples every run, exact expected values.
//    * Tiny: no binary blobs in the repo.
//    * Privacy-clean: no real voices ever enter the test suite.
//
//  All fixtures use Quill's canonical format: 48 kHz, mono, Float32,
//  non-interleaved — matching what AVAudioEngine taps deliver by default
//  on macOS.
//

import AVFoundation

enum AudioFixtures {

    /// Canonical test format. `standardFormatWithSampleRate` = Float32,
    /// non-interleaved — the "standard" in-memory format on Apple platforms.
    static let format = AVAudioFormat(
        standardFormatWithSampleRate: 48_000, channels: 1)!

    /// A pure sine tone. RMS is exactly amplitude/√2 — handy for asserting
    /// level-meter math with a tight tolerance.
    ///
    /// - Parameters:
    ///   - frequency: Hz. Use distinct frequencies to fake distinct speakers.
    ///   - duration:  seconds.
    ///   - amplitude: 0…1 peak. Default 0.5 leaves headroom.
    static func sineBuffer(frequency: Double,
                           duration: Double,
                           amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: frames)!
        buffer.frameLength = frames               // capacity ≠ length; set it!
        let data = buffer.floatChannelData![0]    // channel 0 (mono)
        let w = 2.0 * Double.pi * frequency / format.sampleRate
        for i in 0..<Int(frames) {
            data[i] = amplitude * Float(sin(w * Double(i)))
        }
        return buffer
    }

    /// Digital silence — below any sane VAD threshold.
    static func silenceBuffer(duration: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: frames)!
        buffer.frameLength = frames
        // floatChannelData memory from AVAudioPCMBuffer is zeroed, but be
        // explicit — tests should not rely on allocator behavior.
        buffer.floatChannelData![0].update(repeating: 0, count: Int(frames))
        return buffer
    }

    /// Low-level pseudo-noise (deterministic LCG, NOT random()) — for VAD
    /// "background hum" cases. Seeded so every run is identical.
    static func noiseBuffer(duration: Double,
                            amplitude: Float = 0.01,
                            seed: UInt64 = 0xDEADBEEF) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        var state = seed
        for i in 0..<Int(frames) {
            // Linear congruential generator: fast, deterministic.
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)   // 0…1
            data[i] = (unit * 2 - 1) * amplitude
        }
        return buffer
    }

    /// Simulated two-speaker meeting: alternating 2 s turns of 440 Hz
    /// ("Speaker 1") and 220 Hz ("Speaker 2") separated by 0.5 s silence.
    /// A diarizer should segment this into 4 speech segments, 2 clusters.
    static func twoSpeakerSequence(turns: Int = 2) -> [AVAudioPCMBuffer] {
        var result: [AVAudioPCMBuffer] = []
        for turn in 0..<(turns * 2) {
            let freq: Double = turn.isMultiple(of: 2) ? 440 : 220
            result.append(sineBuffer(frequency: freq, duration: 2.0))
            result.append(silenceBuffer(duration: 0.5))
        }
        return result
    }

    /// Concatenate buffers into one — for engines that take a single buffer.
    static func concatenated(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer {
        let total = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
        var offset = 0
        let dst = out.floatChannelData![0]
        for b in buffers {
            let n = Int(b.frameLength)
            dst.advanced(by: offset)
                .update(from: b.floatChannelData![0], count: n)
            offset += n
        }
        out.frameLength = total
        return out
    }
}
