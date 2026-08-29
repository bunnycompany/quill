# YAML Frontmatter + Dataview Cheatsheet (Quill)

Quick reference for emitting frontmatter that Obsidian Properties and the Dataview plugin both parse correctly.

## Golden rules

| Rule | Right | Wrong |
|---|---|---|
| Keys: lowercase snake_case | `duration_minutes:` | `Duration Minutes:` |
| Dates: bare ISO-8601, **unquoted** | `date: 2026-08-12` | `date: "2026-08-12"` (becomes a string) |
| Free text: double-quoted, escaped | `title: "Q3 \"Kickoff\""` | `title: Q3: Kickoff` (`: ` breaks YAML) |
| Numbers: bare | `duration_minutes: 42` | `duration_minutes: "42"` |
| Lists: block or flow, flat | `attendees:`<br>`  - "Speaker 1"` | nested maps inside list items |
| Tags | `tags: [meeting, quill]` | `tags: #meeting` (`#` starts a YAML comment) |
| Fence | `---` first line of file, `---` after block | blank line before opening `---` |

## Characters that MUST be escaped/quoted in scalars

`: ` (colon+space), `#`, leading `-`, `"`, `\`, newline, leading/trailing spaces, and strings that look like booleans/numbers (`yes`, `no`, `3.14`) when you want strings.

Quill's `yamlQuote(_:)` escapes `\`, `"`, and `\n` then wraps in double quotes — sufficient for the double-quoted YAML style.

## Dataview type inference

| Emitted | Dataview type |
|---|---|
| `2026-08-12` | date |
| `2026-08-12T14:30:00` | datetime |
| `42` / `3.5` | number |
| `true` / `false` | boolean |
| `"anything quoted"` | string |
| `[a, b]` / block list | list |

## Sample queries against Quill notes

```dataview
TABLE date, duration_minutes, attendees
FROM #meeting
WHERE date >= date(2026-08-01)
SORT date DESC
```

```dataview
TASK FROM #meeting WHERE !completed
```

(The second works because Quill emits action items as `- [ ]` checkboxes in the body.)

## Body conventions Quill uses

- `# Title` H1 matches the `title` property.
- `## Key Takeaways` — plain bullets.
- `## Action Items` — `- [ ]` task checkboxes (queryable via `TASK`).
- `## Speaker Timestamps` — `- **Speaker 1** [03:07] text`.

## Filename convention

`Meetings/YYYY-MM-DD-<Slug>.md`, slug = title with non-alphanumerics collapsed to `-`. On collision append `-2`, `-3`, … — never overwrite (sync-conflict avoidance).
