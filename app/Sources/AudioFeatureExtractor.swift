//  AudioFeatureExtractor.swift
//  Quill — Module 3a (DiarizationEngine)
//
//  Turns a 25 ms window of 16 kHz mono samples into:
//    • RMS energy + zero-crossing rate (for VAD)
//    • a 40-band log-mel vector (for speaker embeddings)
//
//  All heavy math uses Accelerate/vDSP (SIMD on the CPU's vector units).
//  Expensive setup (FFT plan, Hann window, mel filterbank) is built ONCE
//  in init — never per window (pitfall #8 in SKILL.md).

import Foundation
import Accelerate

final class AudioFeatureExtractor {

    // MARK: Constants (shared by the whole pipeline)

    /// 25 ms @ 16 kHz.
    static let windowSize = 400
    /// 10 ms hop — windows overlap by 60%.
    static let hopSize = 160
    /// Number of mel filterbank bands.
    static let melBands = 40

    /// FFT length: next power of two ≥ windowSize (vDSP requires 2^n).
    private let fftSize = 512
    private let log2n: vDSP_Length = 9 // 2^9 = 512
    private let sampleRate: Float = Float(AudioChunk.sampleRate)

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let hannWindow: [Float]
    /// Sparse mel filterbank: for each band, the (fftBin, weight) pairs.
    private let melFilterbank: [[(bin: Int, weight: Float)]]

    // Reused scratch buffers — allocated once, so the hot path allocates nothing.
    private var windowed = [Float](repeating: 0, count: 512)
    private var realPart = [Float](repeating: 0, count: 256)
    private var imagPart = [Float](repeating: 0, count: 256)
    private var outReal  = [Float](repeating: 0, count: 256)
    private var outImag  = [Float](repeating: 0, count: 256)
    private var power    = [Float](repeating: 0, count: 256)

    init() {
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("vDSP.FFT setup failed — fftSize must be a power of two")
        }
        self.fft = fft
        self.hannWindow = vDSP.window(ofType: Float.self,
                                      usingSequence: .hanningDenormalized,
                                      count: Self.windowSize,
                                      isHalfWindow: false)
        self.melFilterbank = Self.buildMelFilterbank(bands: Self.melBands,
                                                     fftSize: 512,
                                                     sampleRate: Float(AudioChunk.sampleRate))
    }

    // MARK: - Simple time-domain features (for VAD)

    /// Root-mean-square energy of the window: "how loud".
    func rms(_ samples: [Float]) -> Float {
        vDSP.rootMeanSquare(samples)
    }

    /// Fraction of sample pairs where the signal crosses zero.
    func zeroCrossingRate(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) {
            crossings += 1
        }
        return Float(crossings) / Float(samples.count)
    }

    // MARK: - Log-mel spectrum (for speaker embeddings)

    /// `samples.count` must equal `windowSize` (400).
    /// Returns `melBands` (40) log-energies.
    func logMel(_ samples: [Float]) -> [Float] {
        precondition(samples.count == Self.windowSize)

        // 1. Apply the Hann taper, zero-pad 400 → 512.
        vDSP.multiply(samples, hannWindow, result: &windowed[0..<Self.windowSize])
        for i in Self.windowSize..<fftSize { windowed[i] = 0 }

        // 2. Pack real signal into split-complex form (even samples → real,
        //    odd → imag), as vDSP's real FFT requires.
        windowed.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                realPart.withUnsafeMutableBufferPointer { re in
                    imagPart.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
            }
        }

        // 3. Forward FFT, then power spectrum |X[k]|² per bin.
        realPart.withUnsafeBufferPointer { inRe in
            imagPart.withUnsafeBufferPointer { inIm in
                outReal.withUnsafeMutableBufferPointer { oRe in
                    outImag.withUnsafeMutableBufferPointer { oIm in
                        let input = DSPSplitComplex(realp: .init(mutating: inRe.baseAddress!),
                                                    imagp: .init(mutating: inIm.baseAddress!))
                        var output = DSPSplitComplex(realp: oRe.baseAddress!, imagp: oIm.baseAddress!)
                        fft.forward(input: input, output: &output)
                        vDSP.squareMagnitudes(output, result: &power)
                    }
                }
            }
        }

        // 4. Pool FFT-bin powers through the triangular mel filters, take log.
        var mel = [Float](repeating: 0, count: Self.melBands)
        for (band, taps) in melFilterbank.enumerated() {
            var e: Float = 0
            for tap in taps { e += power[tap.bin] * tap.weight }
            mel[band] = log(max(e, 1e-10)) // floor avoids log(0) = -inf
        }
        return mel
    }

    // MARK: - Mel filterbank construction (once, at init)

    private static func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
    private static func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

    /// Triangular filters, evenly spaced on the mel scale from 0 Hz to Nyquist.
    private static func buildMelFilterbank(bands: Int, fftSize: Int, sampleRate: Float)
        -> [[(bin: Int, weight: Float)]] {

        let nyquist = sampleRate / 2
        let maxMel = hzToMel(nyquist)
        // bands + 2 edge points: each filter spans [edge[i], edge[i+2]],
        // peaking at edge[i+1].
        let edges = (0...(bands + 1)).map { melToHz(maxMel * Float($0) / Float(bands + 1)) }
        let binHz = sampleRate / Float(fftSize) // Hz per FFT bin
        let binCount = fftSize / 2

        var filters: [[(bin: Int, weight: Float)]] = []
        filters.reserveCapacity(bands)
        for b in 0..<bands {
            let lo = edges[b], mid = edges[b + 1], hi = edges[b + 2]
            var taps: [(Int, Float)] = []
            for bin in 0..<binCount {
                let f = Float(bin) * binHz
                let w: Float
                if f > lo && f <= mid {
                    w = (f - lo) / max(mid - lo, .leastNormalMagnitude)   // rising slope
                } else if f > mid && f < hi {
                    w = (hi - f) / max(hi - mid, .leastNormalMagnitude)   // falling slope
                } else {
                    continue
                }
                taps.append((bin, w))
            }
            filters.append(taps)
        }
        return filters
    }
}
