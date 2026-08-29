# Quill Skills

Eight self-contained teaching modules that take a learner from zero macOS/Swift knowledge to a shipped, verified build of **Quill** — a privacy-first macOS menubar meeting recorder that diarizes, transcribes, summarizes, and exports markdown to Obsidian, entirely on-device.

Start with [`CURRICULUM.md`](CURRICULUM.md) for the recommended order, time estimates, and per-module demo milestones.

## Layout

Each folder is one skill:

```
skills/
  quill-swift-foundations/          # Module 0: Swift + Xcode from zero
  quill-menubar-app/                # Component 1: NSStatusItem + popover UI
  quill-audio-capture/              # Component 2: AudioRecorderEngine
  quill-diarization-transcription/  # Component 3a: DiarizationEngine
  quill-ai-parsing/                 # Component 3b: LocalAIParsingEngine
  quill-obsidian-export/            # Component 4: ObsidianExporter
  quill-storage-history/            # Component 5: SQLite history & cache
  quill-testing-performance/        # Verification: tests, leaks, perf, QA
```

Every skill folder contains:

- **`SKILL.md`** — the module itself. Begins with YAML frontmatter (`name`, `description`) followed by: concepts explained from zero, how the component fits Quill's architecture, an annotated step-by-step implementation walkthrough, pitfalls/leak traps, graded exercises with collapsible answers, and a checkpoint checklist.
- **Reference code** — complete, typecheck-verified Swift sources (in `code/` or at the folder root) matching the walkthrough.
- **Cheatsheets** — one-page quick references (API tables, magic numbers, command lines).

## Plugging into a skill system

The folders follow the standard skill convention (Claude Code / Agent Skills style): a directory whose `SKILL.md` frontmatter carries the skill's `name` and a `description` used for triggering.

- **Claude Code:** copy or symlink the folders into `.claude/skills/` (project) or `~/.claude/skills/` (user). Each becomes invocable as `/quill-<name>` and auto-triggers when a task matches its description.
- **Other agent frameworks:** point the skill loader at this directory; each subfolder is one skill, `SKILL.md` is the entry point, and all referenced files use paths relative to the skill folder — no external dependencies.
- **Human self-study:** read `SKILL.md` top to bottom in each module in curriculum order; no tooling required.

## Conventions shared by all modules

- **Target:** Apple Silicon, macOS 15 SDK, Xcode 16+, Swift 5.10+. (Exception: `quill-ai-parsing`'s Foundation Models path is `@available(macOS 26.0, *)`-gated, with a rule-based fallback for macOS 15.)
- **Privacy-first:** no network entitlement, no third-party dependencies, all processing on-device.
- **Zero leaks:** every module teaches the same lifecycle discipline — stored cancellable Tasks, `defer` cleanup, bounded buffers — and `quill-testing-performance` is the module that proves it.
- **Canonical type names:** `AudioRecorderEngine`, `DiarizationEngine`, `LocalAIParsingEngine`, `ObsidianExporter`, `QuillStore`, `AppState`, `HotkeyManager`, `PermissionsManager`.
