# Quill AI Parsing — Prompt & Foundation Models Cheatsheet

## Foundation Models quick reference (macOS 26+)

```swift
import FoundationModels

// 1. Check the model exists and is ready — ALWAYS, before any session.
switch SystemLanguageModel.default.availability {
case .available:                      // good to go
case .unavailable(let reason):        // .deviceNotEligible, .appleIntelligenceNotEnabled,
                                      // .modelNotReady, …  -> use RuleBasedAnalyzer
}

// 2. Session = instructions (system prompt) + growing conversation context.
let session = LanguageModelSession(instructions: "You are …")

// 3a. Free-text response
let r = try await session.respond(to: "…")            // r.content: String

// 3b. Guided generation (preferred): output is ALWAYS a valid MyStruct.
@Generable struct MyStruct {
    @Guide(description: "what this field means") var field: String
}
let r = try await session.respond(to: "…", generating: MyStruct.self,
                                  options: GenerationOptions(temperature: 0.1))

// 3c. Streaming partials (for live UI)
for try await partial in session.streamResponse(to: "…", generating: MyStruct.self) {
    // partial has optional fields filling in as tokens arrive
}
```

Rules of thumb:
- Fresh session per chunk; sessions accumulate context and overflow.
- Temperature 0.0–0.2 for extraction tasks; higher only for creative text.
- `tokens ≈ characters / 4` (English). Budget: instructions + prompt + expected
  output must fit the window; keep chunk prompts ≤ ~2500 tokens.
- Everything runs on-device. No network entitlement needed; nothing leaves the Mac.

## Prompt patterns that work for extraction

| Pattern | Example |
|---|---|
| Role + scope in instructions | "You analyze meeting transcript excerpts." |
| Anti-hallucination clause | "Extract only facts explicitly present. Never invent names, dates, or commitments." |
| Label discipline | "Speakers are labeled 'Speaker N'; refer to them only by those labels." |
| Length caps in @Guide | "under 15 words", "2-3 sentences" |
| Empty-is-valid | "Empty if none." (stops the model from fabricating action items) |
| Injection containment | Transcript text goes ONLY in the prompt body, never in `instructions:` |

## Chunking math worked example

60-min meeting ≈ 9000 spoken words ≈ 50,000 chars ≈ 12,500 tokens.
Budget 2500 tokens/chunk → 5 chunks → 5 map calls + 1 reduce call.
At a few seconds per on-device call, a full hour summarizes in well under a minute.

## Map-reduce vs running-context

| | Map-reduce (this module) | Running context (Exercise 3) |
|---|---|---|
| Calls | N + 1 | N |
| Cross-chunk references | lost | preserved |
| Parallelizable | yes (map step) | no (sequential) |
| Complexity | lower | higher |

## Determinism checklist for the markdown layer

- LLM fills structs; Swift renders markdown. Never ask the model for markdown/YAML.
- `DateFormatter` with `en_US_POSIX` locale + explicit `dateFormat`.
- Sorted attendee lists; order-preserving dedupe for takeaways/actions.
- Escape `"` in YAML string values.
- `- [ ]` for action items → Obsidian Tasks-compatible.
- Unit test: render twice, assert byte equality.

## Cancellation & leak checklist

- `try Task.checkCancellation()` between every chunk and before reduce.
- Sessions are function-locals: cancelled task → function unwinds → session freed.
- ViewModel nils its `Task` handle in `stop()` and on completion.
- Never store progress closures on the engine actor.
- Instruments Leaks: 3 summarize/stop cycles → flat allocation graph.
