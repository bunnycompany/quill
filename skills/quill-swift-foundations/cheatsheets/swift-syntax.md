# Swift syntax cheatsheet (Quill-scoped)

## Values & types
```swift
let name = "Quill"            // constant (prefer)
var count = 0                 // variable
let rate: Double = 48_000     // explicit type; _ = digit separator
let samples: [Float] = []     // array
let meta: [String: String] = ["title": "Sync"]   // dictionary
let pair: (Int, String) = (1, "one")             // tuple
```

## Strings
```swift
let s = "Rec: \(count) chunks"        // interpolation
let multi = """
    ---
    title: \(name)
    ---
    """                                // multiline (YAML frontmatter!)
s.isEmpty; s.count; s.hasPrefix("Rec"); s.lowercased()
```

## Optionals
```swift
var path: String? = nil
if let path { use(path) }              // shorthand if-let
guard let path else { return }         // early exit; path valid after
let shown = path ?? "No vault"         // default
let n = path?.count                    // chaining → Int?
// path!  ← banned in Quill app code
```

## Functions & closures
```swift
func db(fromLevel level: Float) -> Float { 20 * log10(level) }
func export(to url: URL, overwrite: Bool = false) throws { }
let f: (Float) -> Float = { $0 * 2 }
samples.map { $0 * 2 }.filter { $0 > 0 }.reduce(0, +)
handler = { [weak self] in self?.tick() }   // stored closure: weak self
```

## Control flow
```swift
for s in samples { }
for i in 0..<10 { }                    // 0...9   (0...10 includes 10)
while running { }
switch state {                         // must be exhaustive
case .idle: break
case .recording(let start): use(start)
}
```

## Types
```swift
struct Note { let date: Date; var body: String }        // value type, copied
final class Engine { }                                  // reference type
enum State { case idle, recording(startedAt: Date) }    // cases + payloads
protocol Exporter { func export(_ note: Note) throws }  // contract
extension Note { var slug: String { body.prefix(20).lowercased() } }
actor Buffer { private var data: [Float] = [] }         // race-free class
```

## Errors
```swift
enum ExportError: Error { case vaultMissing }
func export() throws { throw ExportError.vaultMissing }
do { try export() } catch { print(error) }
let ok = try? export()                 // → nil on error
```

## Property wrappers / macros you'll see
```swift
@main            // program entry point
@Observable      // class becomes SwiftUI-observable (import Observation)
@State           // view-local SwiftUI state
@MainActor       // pin type/func to the UI actor
@objc / #selector// AppKit target-action bridge
```

## Memory rules of thumb
- Structs/enums: copied, can't leak by themselves.
- Classes/actors: reference-counted (ARC). Cycles leak → `[weak self]` in
  stored closures; cancel long-lived Tasks.
- `deinit` on a class = your "was I freed?" tracer: add a `print` while learning.
