//  BoundedRingBuffer.swift
//  Quill — Module 2 (quill-audio-capture)
//
//  A fixed-capacity single-producer / single-consumer ring buffer of Float
//  samples. Safe to WRITE from the real-time audio thread (short unfair-lock
//  critical section, zero allocation) and READ from an async drain task.
//
//  Policy: drop-newest on overflow. The write reports how much it accepted;
//  `overrunCount` accumulates what was rejected so the UI can warn the user.
//
//  Memory is bounded forever at `capacity * 4` bytes. That is the point.

import Foundation
import os

public final class BoundedRingBuffer: @unchecked Sendable {
    // `@unchecked Sendable`: we hand-verify thread safety — every access to
    // mutable state below happens inside `lock.withLock`. The compiler cannot
    // prove that, hence "unchecked". Keep ALL mutable state behind the lock.

    private let lock = OSAllocatedUnfairLock()
    private var storage: [Float]          // fixed size, allocated once
    private var readIndex = 0             // next slot to read
    private var writeIndex = 0            // next slot to write
    private var stored = 0                // number of valid samples
    private var overrun: Int = 0

    public let capacity: Int

    /// - Parameter capacity: number of Float samples (e.g. 10 s @ 16 kHz = 160_000).
    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Samples currently readable.
    public var available: Int { lock.withLock { stored } }

    /// Total samples dropped because the consumer fell behind.
    public var overrunCount: Int { lock.withLock { overrun } }

    /// Write `count` samples from `src`. Called from the AUDIO THREAD:
    /// no allocation, no unbounded waiting. Returns samples accepted.
    @discardableResult
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return lock.withLock {
            let free = capacity - stored
            let toWrite = min(count, free)
            if toWrite < count { overrun += count - toWrite }   // drop-newest
            var remaining = toWrite
            var srcOffset = 0
            while remaining > 0 {
                // Contiguous run before the array wraps around.
                let run = min(remaining, capacity - writeIndex)
                storage.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: writeIndex)
                        .update(from: src + srcOffset, count: run)   // memcpy
                }
                writeIndex = (writeIndex + run) % capacity
                srcOffset += run
                remaining -= run
            }
            stored += toWrite
            return toWrite
        }
    }

    /// Read up to `dst.count` samples into `dst`. Called from the drain Task.
    /// Returns samples actually read (0 if empty — caller should sleep/await).
    public func read(into dst: inout [Float]) -> Int {
        dst.withUnsafeMutableBufferPointer { buf in
            read(into: buf.baseAddress!, maxCount: buf.count)
        }
    }

    public func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }
        return lock.withLock {
            let toRead = min(maxCount, stored)
            var remaining = toRead
            var dstOffset = 0
            while remaining > 0 {
                let run = min(remaining, capacity - readIndex)
                storage.withUnsafeBufferPointer { src in
                    (dst + dstOffset).update(from: src.baseAddress! + readIndex,
                                             count: run)
                }
                readIndex = (readIndex + run) % capacity
                dstOffset += run
                remaining -= run
            }
            stored -= toRead
            return toRead
        }
    }

    /// Discard everything. Used by the engine's reset path after stop().
    public func clear() {
        lock.withLock {
            readIndex = 0; writeIndex = 0; stored = 0
            // Deliberately NOT resetting overrun: it is a session statistic
            // the engine reads before calling clear(). Engine owns that choice.
        }
    }
}
