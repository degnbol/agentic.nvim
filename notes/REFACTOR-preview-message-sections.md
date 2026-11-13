# Plan: one layout for prompt and reply in the session preview
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/session_resume.lua` — `SessionResume.format_preview`
- `lua/agentic/session_resume.test.lua` — `describe("format_preview")`

## Background
`format_preview` writes a user prompt (its `user` branch) and an agent
reply (its `agent` branch) with the same three steps: a heading,
the non-empty lines of `msg.text`, a blank line. Only the heading differs.
A change to how text shows in the preview (for example, keeping blank lines)
must apply to both.

## Changes
1. Add the local `add_section` (Additions) above `format_preview`.
2. `format_preview`: the body of the
   `msg.type == "user" and not msg.synthetic` branch becomes
   `add_section(lines, "## You", msg.text)`, and the body of the
   `msg.type == "agent"` branch becomes
   `add_section(lines, "## Agent", msg.text)`. The branch conditions and
   the other branches stay as they are.

## Additions
### `session_resume.lua`
```lua
--- Append `heading`, the non-empty lines of `text` and a blank line to
--- `lines`.
--- @param lines string[]
--- @param heading string
--- @param text string
local function add_section(lines, heading, text)
```

### Tests
Existing `format_preview` cases pass unchanged ("formats user messages with
heading", "skips a synthetic prompt", "formats agent messages with
heading").

## Expected outcome
No behaviour change.

## Non-goals
- The thought, tool call and message branches.

## Open questions
None.
