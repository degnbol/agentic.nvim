# opencode ACP provider internals

Reference for provider-specific behaviour of `opencode` (the CLI tool). This
documents opencode-specific quirks that affect agentic.nvim — not the ACP
protocol itself (see SKILL.md for that).

## Edit tool call sequence

Opencode sends Edit tool calls in a sequence that differs from other providers:

### Sequence

1. **`tool_call`** with `kind="edit"`, `title="edit"`, but **empty diff data**:
   - `rawInput.filePath = nil`
   - `rawInput.oldString = ""` (0 chars)
   - `rawInput.newString = ""` (0 chars)

2. **`tool_call_update`** with `status="in_progress"` and the **actual diff** in `rawInput`:
   - `rawInput.filePath = "/absolute/path/to/file.lua"`
   - `rawInput.oldString = "..."` (populated)
   - `rawInput.newString = "..."` (populated)

3. **`tool_call_update`** with `status="completed"` and diff in `content[]`:
   - `content[1] = { type = "content", content = { type = "text", text = "Wrote file successfully." } }`
   - `content[2] = { type = "diff", path = "...", oldText = "...", newText = "..." }`

### Implications

- The initial `tool_call` **cannot be used for diff preview** — the diff data
  arrives later in `tool_call_update`.
- When edits are **auto-approved**, the file may already be modified by the
  time the diff data arrives for rendering, causing diff matching to fail
  ("Not found").
- The adapter (`opencode_acp_adapter.lua`) extracts diff from both
  `rawInput.newString` (in-progress status) and `content[].type="diff"` (completed
  status).

### Example debug log

```
17:26:23 tool_call: kind=edit title=edit rawInput=present
17:26:23   rawInput.filePath=nil oldString=0 chars newString=0 chars
17:26:26 tool_call_update: kind=edit title=edit status=in_progress rawInput=present content=nil
17:26:26   rawInput.filePath=/path/to/file.lua oldString=250 chars newString=242 chars
17:26:26 tool_call_update: kind=edit title=/path/to/file.lua status=completed rawInput=present content=2
17:26:26   rawInput.filePath=/path/to/file.lua oldString=250 chars newString=242 chars
17:26:26   content[1]: type=content path=nil oldText=0 chars newText=0 chars
17:26:26   content[2]: type=diff path=/path/to/file.lua oldText=250 chars newText=242 chars
```

## Tool kind detection

Opencode uses `kind="other"` for several tool types. The adapter detects
specific tool kinds by inspecting `rawInput` fields and `title`:

| `title` value        | Mapped `kind`  | Detected by                    |
| -------------------- | -------------- | ------------------------------ |
| `"list"`             | `"search"`     | `title == "list"`              |
| `"websearch"`        | `"WebSearch"`  | `title == "websearch"`         |
| `"google_search"`    | `"WebSearch"`  | `title == "google_search"`     |
| `"task"`             | `"SubAgent"`   | `title == "task"`              |
| `"skill"`            | `"Skill"`      | `title == "skill"`             |
| `"todowrite"`        | `"todowrite"`  | `title == "todowrite"`         |
| Sub-agent task       | `"SubAgent"`   | `rawInput.subagent_type`       |

## todowrite tool

The `todowrite` tool sends the full todo list as JSON in its body. This should
be hidden from the chat display since the todo window shows the rendered todos.

The adapter maps `title == "todowrite"` to `kind = "todowrite"`, and
`MessageWriter` strips the body for this kind (similar to `switch_mode`).

## Status reporting

Opencode may report `status="completed"` for edits that the diff matcher
cannot find in the file (e.g., when the file was already modified). The client
should report the provider's status faithfully rather than overriding it.

## Permission timing and bypass quirks

The on-disk write invariant is solid: `tool/edit.ts:140-150`,
`tool/write.ts:53-63`, and `tool/apply_patch.ts:200-220` all `yield* ctx.ask`
before `afs.writeWithDirs`. `permission/index.ts:178-213` suspends on
`Deferred.await` until the user replies, and a reject fails the deferred so
the subsequent write is never reached. But two issues complicate what the
client sees.

### Premature `in_progress` racing with `request_permission` ([#14301][1])

`session/processor.ts:287-303` flips the part status from `pending` →
`running` the moment the LLM emits its `tool-call` streaming event, *before*
`execute()` runs. The ACP agent at `acp/agent.ts:323-339` translates that
into `tool_call_update` with `status: "in_progress"`, dispatched in the same
event-loop tick as the `session/request_permission` triggered by `ctx.ask`.
Both arrive in the same TCP batch.

ACP spec says `pending` covers "awaiting approval" and `in_progress` means
the call is "currently running" — the disk write hasn't started yet, so
opencode's notification is mis-labelled. Clients that re-render the tool
call on every status update can clobber the permission dialog they just
showed (agent-shell did this; agentic.nvim renders permission prompts
separately and isn't affected). Issue auto-closed after 60 days of
inactivity, not fixed.

### `external_directory: "allow"` silently bypasses `edit` rules ([#18441][2])

`permission/index.ts:182-195` evaluates each pattern independently and sets
`needsAsk = false` if all evaluate to `allow`. When `external_directory:
"allow"` matches a path, `edit: "ask"` / `edit: "deny"` rules on the same
path resolve to `allow` regardless, so `ask` returns without prompting. The
write proceeds, no `request_permission` is ever sent.

From a client's perspective this is indistinguishable from "edit happened
without permission" — there is no permission step in that codepath. Open as
of opencode 1.2.27 (Windows).

[1]: https://github.com/anomalyco/opencode/issues/14301
[2]: https://github.com/anomalyco/opencode/issues/18441

## Why opencode Edit diffs fail to match the file

Three independent reasons compound, so literal match of `rawInput.oldString`
against the file state is unreliable even when no buffer/disk skew exists.
Verified against `/tmp/opencode` source 2026-04-24.

### 1. Fuzzy match cascade inside the edit tool

`packages/opencode/src/tool/edit.ts:680-702` runs the LLM's `oldString`
through 9 replacers in order, accepting the first that yields a match:

`SimpleReplacer → LineTrimmedReplacer → BlockAnchorReplacer →
WhitespaceNormalizedReplacer → IndentationFlexibleReplacer →
EscapeNormalizedReplacer → TrimmedBoundaryReplacer → ContextAwareReplacer →
MultiOccurrenceReplacer`

`BlockAnchorReplacer` uses first+last line as anchors with a **Levenshtein
similarity threshold of 0.0 for single candidates** (any candidate passes) and
0.3 for multiple. `WhitespaceNormalizedReplacer` collapses all whitespace;
`IndentationFlexibleReplacer` strips common leading indent;
`EscapeNormalizedReplacer` unescapes `\n`/`\t`/etc. sequences.

Each replacer yields the *text as it appears in the file* (not the LLM's
`oldString`). The tool then runs `content.indexOf(yielded_text)` and replaces
that resolved string with `newString`.

Contrast with claude-agent's `str_replace_based_edit_tool`, which requires a
unique **exact** substring match (documented in
`@.claude/skills/acp/references/claude-agent.md`). That's why literal matching
works for claude and not opencode.

### 2. `completed` update arrives after the disk write

Permission *is* requested before the write — `edit.ts:97` / `140` calls
`ctx.ask({ permission: "edit", ..., metadata: { filepath, diff } })` and
only after it resolves does `edit.ts:106` / `150` run
`afs.writeWithDirs(filePath, ...)`. That part matches claude-agent's
behaviour.

The mismatch appears in the **second** ACP notification. Opencode's
`message.part.updated` handler at `packages/opencode/src/acp/agent.ts:342-420`
emits a `tool_call_update` with `status: "completed"` and
`content[type=diff]` — this fires after the tool returns, i.e. after the
write. A client that re-renders the diff from this second notification
(or retries `FileSystem.read_from_disk` after the first render failed)
sees post-edit file content. Relevant only for code paths that match
after the completed update.

### 3. ACP payload carries the LLM's verbatim params, not the resolved text

`agent.ts:359-370` constructs the diff content as:

```ts
const oldText = input["oldString"]
const newText = input["newString"]
content.push({ type: "diff", path: filePath, oldText, newText })
```

These are the LLM's unmodified tool-call parameters, not the fuzzy-matched
file text that was actually replaced. So the client has no way to recover
the real pre-edit content from `rawInput` or `content[type=diff]`.

### Client mitigation

`tool_call_renderer.lua` falls back to rendering the raw `diff.old`/`diff.new`
arrays directly (no file-position lookup) when `extract_diff_blocks` returns
empty. Line numbers aren't real, but the before/after content is visible.
This is the best we can do from the ACP message alone.

### Possible upgrade: parse `rawOutput.metadata.diff`

`edit.ts:183-189` attaches a unified-diff string to
`ctx.metadata({ metadata: { diff, filediff, diagnostics } })`, built from
the real pre/post file content via `createTwoFilesPatch`. `agent.ts:411-415`
forwards this as `rawOutput.metadata` on the `completed` update. Parsing
that unified diff would recover the actual resolved content with real line
numbers. Only available for `completed` (not `in_progress`), and only for
edit tool calls that populate `metadata.diff`. Not currently implemented.
