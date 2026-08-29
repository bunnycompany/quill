//  SpeakerEmbedder.swift
//  Quill — Module 3a (DiarizationEngine)
//
//  Turns a speech segment's mel frames into a fixed-length, L2-normalized
//  "voice fingerprint". Hidden behind a protocol so a Core ML neural
//  embedder (x-vector / ECAPA) can be dropped in later without touching
//  the clusterer or engine.

import Foundation
import Accelerate

/// Anything that can turn a segment's audio features into an embedding.
protocol SpeakerEmbedding {
    /// Length of the vectors produced (constant per implementation).
    var dimension: Int { get }
    /// `melFrames`: one 40-dim log-mel vector per 10 ms hop of the segment.
    /// Must return an L2-normalized vector of `dimension` floats, so that
    /// cosine similarity reduces to a plain dot product.
    func embed(melFrames: [[Float]]) -> [Float]
}

/// Baseline embedder: per-band mean ⊕ per-band standard deviation
/// (40 + 40 = 80 dims). Mean captures average timbre; std-dev captures
/// how the voice moves. Cheap (vDSP) and dependency-free.
final class LogMelStatsEmbedder: SpeakerEmbedding {

    let dimension = AudioFeatureExtractor.melBands * 2

    func embed(melFrames: [[Float]]) -> [Float] {
        let bands = AudioFeatureExtractor.melBands
        guard !melFrames.isEmpty else {
            // Degenerate but valid: a fixed unit vector (never matches real voices well).
            var v = [Float](repeating: 0, count: dimension)
            v[0] = 1
            return v
        }
        let n = Float(melFrames.count)

        // Mean per band.
        var mean = [Float](repeating: 0, count: bands)
        for frame in melFrames {
            vDSP.add(mean, frame, result: &mean)
        }
        vDSP.divide(mean, n, result: &mean)

        // Std-dev per band: sqrt(E[(x-mean)²]).
        var variance = [Float](repeating: 0, count: bands)
        var diff = [Float](repeating: 0, count: bands)
        for frame in melFrames {
            vDSP.subtract(frame, mean, result: &diff)
            vDSP.multiply(diff, diff, result: &diff)
            vDSP.add(variance, diff, result: &variance)
        }
        vDSP.divide(variance, n, result: &variance)
        let std = variance.map { $0.squareRoot() }

        // Concatenate, remove the common DC offset (log-mel values share a
        // large negative baseline that would make every embedding near-
        // parallel under cosine), then L2-normalize.
        var v = mean + std
        var dc: Float = 0
        vDSP_meanv(v, 1, &dc, vDSP_Length(v.count))
        vDSP.add(-dc, v, result: &v)
        let norm = vDSP.sumOfSquares(v).squareRoot()
        if norm > .leastNormalMagnitude {
            vDSP.divide(v, norm, result: &v)
        }
        return v
    }
}
