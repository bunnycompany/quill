//  OnlineSpeakerClusterer.swift
//  Quill — Module 3a (DiarizationEngine)
//
//  Online (streaming) centroid clustering of L2-normalized speaker
//  embeddings. Each new segment is assigned to the nearest existing
//  speaker (cosine ≥ threshold) or mints a new one — bounded by
//  maxSpeakers so memory can never grow without limit.

import Foundation
import Accelerate

final class OnlineSpeakerClusterer {

    struct Cluster {
        /// Running-mean embedding, kept L2-normalized.
        var centroid: [Float]
        /// Number of segments assigned so far.
        var count: Int
        /// Total speaking time (used for post-hoc relabeling).
        var totalDuration: TimeInterval
    }

    private(set) var clusters: [Cluster] = []
    let similarityThreshold: Float
    let maxSpeakers: Int

    init(similarityThreshold: Float = 0.85, maxSpeakers: Int = 8) {
        self.similarityThreshold = similarityThreshold
        self.maxSpeakers = maxSpeakers
    }

    /// Assign an embedding to a speaker; returns the 1-based speaker ID.
    /// `duration` is the segment length, tracked for relabeling.
    func assign(_ embedding: [Float], duration: TimeInterval = 0) -> Int {
        var bestIndex = -1
        var bestSim = -Float.infinity
        for (i, c) in clusters.enumerated() {
            // Both vectors are unit-length ⇒ dot product IS cosine similarity.
            let sim = vDSP.dot(embedding, c.centroid)
            if sim > bestSim {
                bestSim = sim
                bestIndex = i
            }
        }

        // Join the best cluster if similar enough — or if we've hit the
        // speaker cap (force-assign rather than grow unbounded).
        if bestIndex >= 0, bestSim >= similarityThreshold || clusters.count >= maxSpeakers {
            update(clusterAt: bestIndex, with: embedding, duration: duration)
            return bestIndex + 1
        }

        clusters.append(Cluster(centroid: embedding, count: 1, totalDuration: duration))
        return clusters.count
    }

    /// Incremental mean, then re-normalize (the mean of unit vectors is
    /// not itself unit length).
    private func update(clusterAt i: Int, with e: [Float], duration: TimeInterval) {
        var c = clusters[i]
        let n = Float(c.count)
        var merged = [Float](repeating: 0, count: e.count)
        vDSP.multiply(n, c.centroid, result: &merged)  // centroid·n
        vDSP.add(merged, e, result: &merged)           // + e
        vDSP.divide(merged, n + 1, result: &merged)    // / (n+1)
        let norm = vDSP.sumOfSquares(merged).squareRoot()
        if norm > .leastNormalMagnitude {
            vDSP.divide(merged, norm, result: &merged)
        }
        c.centroid = merged
        c.count += 1
        c.totalDuration += duration
        clusters[i] = c
    }

    /// Online clustering numbers speakers by first appearance. For stable,
    /// meaningful labels in exported notes, renumber by total speaking time
    /// (most talkative = Speaker 1). Returns segments with rewritten IDs.
    func relabelBySpeakingTime(segments: [SpeakerSegment]) -> [SpeakerSegment] {
        // Old (1-based) ID → rank by descending totalDuration.
        let order = clusters.enumerated()
            .sorted { $0.element.totalDuration > $1.element.totalDuration }
            .map { $0.offset + 1 }                        // old IDs in rank order
        var mapping: [Int: Int] = [:]
        for (rank, oldID) in order.enumerated() {
            mapping[oldID] = rank + 1
        }
        return segments.map { seg in
            var s = seg
            s.speakerID = mapping[seg.speakerID] ?? seg.speakerID
            return s
        }
    }

    /// Final per-cluster centroids keyed by the RELABELED 1-based speaker ID
    /// (same speaking-time ordering as relabelBySpeakingTime, so key 1 is
    /// "Speaker 1"). Used for cross-meeting voice recognition.
    func centroidsByRelabeledIndex() -> [Int: [Float]] {
        let ranked = clusters.sorted { $0.totalDuration > $1.totalDuration }
        var out: [Int: [Float]] = [:]
        for (rank, cluster) in ranked.enumerated() {
            out[rank + 1] = cluster.centroid
        }
        return out
    }
}
