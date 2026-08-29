# Swift Concurrency cheatsheet (Quill-scoped)

## async / await
```swift
func transcribe(_ audio: [Float]) async throws -> String { ... }
let text = try await transcribe(chunk)      // suspends, doesn't block a thread
async let a = loadModel()                   // start in parallel...
async let b = loadVault()
let (model, vault) = try await (a, b)       // ...join
```

## Task — starting & owning async work
```swift
let job = Task { try await transcribe(chunk) }        // inherits actor context
let bg = Task.detached(priority: .utility) { ... }    // no inherited context
let result = try await job.value                      // wait for the result
job.cancel()                                          // request cancellation
```
**Rule:** any Task that could run long is STORED and CANCELLED in
`stop()` / `deinit` / `onDisappear`. Unstored infinite Task = immortal retain.

## Cooperative cancellation
```swift
while !Task.isCancelled { ... }             // check in loops
try Task.checkCancellation()                 // throws CancellationError
try await Task.sleep(for: .milliseconds(33)) // throws immediately if cancelled
defer { cleanup() }                          // runs on every exit path
withTaskCancellationHandler(operation: { ... },
                            onCancel: { engine.stop() })  // for non-async APIs
```

## Actors
```swift
actor RingBuffer {
    private var data: [Float] = []           // protected state
    func append(_ c: [Float]) { ... }        // sync inside the actor
}
await buffer.append(chunk)                   // await from outside

@MainActor final class UIModel { }           // pinned to the UI actor
await MainActor.run { model.level = v }      // hop to main explicitly
```
- Actor state can only be touched via `await` from outside → no data races,
  checked at compile time (strict concurrency).
- Don't block inside an actor (no `sleep`, no sync disk I/O on @MainActor).

## AsyncStream — bridging callbacks to for-await
```swift
let (stream, continuation) = AsyncStream.makeStream(of: Float.self,
    bufferingPolicy: .bufferingNewest(16))   // BOUNDED — drops old, no growth
// producer (e.g. audio tap callback):
continuation.yield(level)
continuation.finish()                        // ends the loop below
// consumer:
levelTask = Task {
    for await level in stream { model.level = level }
}
```
`bufferingNewest(n)` is Quill's default: a slow consumer never causes
unbounded memory growth.

## Sendable (crossing actor boundaries)
- Values passed into Tasks/actors must be `Sendable` (safe to share).
- Structs of value types are Sendable automatically; classes generally aren't.
- Compiler errors about Sendable = you're sharing mutable class state across
  concurrency domains → move it into an actor.

## The Quill lifecycle pattern
```swift
func start() {
    guard task == nil else { return }
    task = Task {
        defer { /* release resources, reset UI */ }
        while !Task.isCancelled {
            // produce / consume
            try? await Task.sleep(for: .milliseconds(33))
        }
    }
}
func stop() { task?.cancel(); task = nil }
```
Verify with Instruments ▸ Leaks: N start/stop cycles → flat memory, zero leaks.
