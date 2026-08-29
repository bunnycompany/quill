//
//  LevelMeterModel.swift
//  HelloQuill — Quill Module 0
//
//  A miniature of Quill's AudioRecorderEngine pattern:
//    * an actor holding BOUNDED data (no unbounded growth, ever)
//    * a Task producing values on a background executor
//    * @MainActor @Observable state the SwiftUI popover reads
//    * cooperative cancellation with cleanup in `defer`
//
//  The "signal" here is synthetic (a wandering sine amplitude). Module 1
//  swaps it for real AVAudioEngine / ScreenCaptureKit PCM taps without
//  changing this architecture.
//

import Foundation
import Observation   // the @Observable macro (macOS 14+)

// MARK: - Bounded sample store (actor)

/// An actor: the compiler guarantees its mutable state is touched by only
/// one caller at a time — no locks, no data races. In real Quill this is
/// the circular audio buffer shared between the capture callback and the
/// transcription pipeline.
actor BoundedLevelStore {
    private var levels: [Float]
    private var writeIndex = 0
    let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = capacity
        // Pre-allocate ONCE. The array never grows — this is the
        // "bounded circular buffer" discipline in its simplest form.
        self.levels = [Float](repeating: 0, count: capacity)
    }

    func push(_ level: Float) {
        levels[writeIndex] = level
        writeIndex = (writeIndex + 1) % capacity   // wrap around, overwrite old
    }

    /// A smoothed recent level for the UI (average of the last 8 samples).
    func recentAverage() -> Float {
        var sum: Float = 0
        for offset in 1...8 {
            // Walk backwards from the write position, wrapping safely.
            let index = (writeIndex - offset + capacity * 2) % capacity
            sum += levels[index]
        }
        return sum / 8
    }
}

// MARK: - UI-facing model

/// @Observable: SwiftUI views that read `level` / `isRunning` re-render
/// automatically when they change.
/// @MainActor: all mutations happen on the main actor — the compiler
/// enforces that we never touch UI state from a background task directly.
@Observable
@MainActor
final class LevelMeterModel {
    /// Current smoothed level, 0...1. The popover's bar reads this.
    private(set) var level: Float = 0
    private(set) var isRunning = false

    private let store = BoundedLevelStore()

    /// The running meter task. Stored so we can CANCEL it — an unstored,
    /// never-ending Task is an immortal retain of everything it captured.
    private var meterTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }   // idempotent — double-start safe
        isRunning = true

        // Task inherits @MainActor context here; the `await`s inside yield
        // the main thread, so the UI stays responsive. Heavy real DSP work
        // would live on the actor / a background task instead.
        meterTask = Task { [store] in
            // `defer` runs no matter HOW the task exits (cancel, error,
            // normal return). This is where Quill puts all cleanup.
            defer {
                self.level = 0          // reset the meter for the UI
                print("meter task exiting cleanly")
            }

            var phase: Float = 0
            while !Task.isCancelled {   // cooperative cancellation check
                // --- fake signal generation (Module 1 replaces this) ---
                phase += 0.15
                let synthetic = abs(sin(phase)) * .random(in: 0.6...1.0)
                await store.push(synthetic)

                // Publish the smoothed value to the UI (we are already on
                // the MainActor, so this assignment is legal and safe).
                self.level = await store.recentAverage()

                // ~30 fps. Task.sleep THROWS when cancelled — waking the
                // task promptly instead of sleeping through a Stop click.
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    break   // cancelled mid-sleep — exit the loop, run defer
                }
            }
        }
    }

    func stop() {
        meterTask?.cancel()   // cooperative: the loop/sleep notices and exits
        meterTask = nil       // drop our reference so the task can deallocate
        isRunning = false
    }
}
