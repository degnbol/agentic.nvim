# Plan: per-kind wording for the "Allow always" permission option

## Problem

On an execute (Bash) permission prompt, option 2 reads **"Always Allow all
bash"**. That label is the claude-agent-acp bridge's wording for the
`allow_always` option, rendered verbatim by the plugin
(`permission_float.lua:152`, `option.name`). It implies a persistent, tool-wide
allow rule. Our actual behaviour is narrower and differs per tool kind, so the
label misrepresents what the user is committing to.

## Why the label is wrong for us

There is no ACP method to write persistent SDK permission rules (permissions
skill § "Known ACP limitation"). When the user picks `allow_always` the plugin
does **not** write a `Bash(...)` rule — it caches the decision itself in
`PermissionManager._always_cache`, **keyed per-resource** by
`_build_cache_key` (`permission_manager.lua:159`). Cache identity per kind
(`CACHE_KEY_FIELDS`, `:86`):

| ACP kind | Cache key field(s) | "Allow always" actually means |
|---|---|---|
| `execute` | `command` (falls back to `tracker.argument`) | this **exact command** re-approves; a different command re-prompts |
| `edit` | `file_path` | future edits to **this file** |
| `write` | `file_path` | future writes to **this file** |
| `create` | `file_path` | future creates of **this file** |
| `delete` | `file_path` | future deletes of **this file** |
| `move` | `file_path` | future moves of **this file** |
| `fetch` | `url` | this **URL** |
| `WebSearch` | `query` | this **query** |
| `SlashCommand` | `command`, `name` | this **slash command** |
| `SubAgent` | `subagent_type` | this **subagent type** |
| `Skill` | `skill` | this **skill** |
| `switch_mode` | `mode` | switching to this **mode** |
| (unknown) | hybrid `rawInput` repr | this **exact invocation** |

The cache is per-session (clears on `/new`, cancel, tab close) — same lifetime
as the bridge's `destination: "session"` rules, so "always" is session-scoped
in both, but neither label says so.

Read-only kinds (`read`, `search`) are auto-approved before any prompt
(mechanism 1), so option 2 is never shown for them — no wording needed there.

## What claude-agent-acp currently provides

`describeAlwaysAllow(suggestions, toolName)`
(`dist/acp-agent.js:217`) builds the `allow_always` option name:

- No SDK rule suggestions → `` `Always Allow all ${toolName}` `` → **"Always Allow all Bash"**
- SDK `addRules`/allow suggestion with `ruleContent` → `` `Always Allow Bash(npm test:*)` `` (per rule, joined with ", "); without ruleContent → `all ${rule.toolName}`
- SDK `addDirectories` suggestion → `` `Always Allow access to /path` ``

The standard tool permission request (`:1585`) always offers exactly three
options, in this order:

1. `allow_always` — name = `describeAlwaysAllow(...)`
2. `allow_once` — name = **"Allow"**
3. `reject_once` — name = **"Reject"**

Notes:
- The claude path sends **no `reject_always`**. Our reject_always handling
  (and the per-resource reject cache) exists for other providers (opencode).
- `ExitPlanMode` is a special case (`:1510`) with its own mode-switch options
  (`allow_always` "Yes, and use auto mode" / "auto-accept edits" / "bypass
  permissions"). These are genuine session-mode switches, **not** cached
  per-resource — leave their wording alone.
- The plugin re-sorts options by `KIND_ORDER` (`permission_manager.lua:17`:
  allow_once=1, allow_always=2, reject_once=3, reject_always=4), which is why
  `allow_always` appears as **option 2** to the user even though the bridge
  sends it first.

## Proposed override wording

Override only the `*_always` kinds; keep `allow_once`/`reject_once` and the
synthetic "Reject all" as-is. Fall back to the ACP-provided `option.name` for
any kind not in the table (covers `ExitPlanMode`'s mode-switch `allow_always`
options, future kinds, and other providers).

Keyed on the **tool_call kind** (not the option kind), so the same map drives
both allow and reject phrasing:

| kind | allow_always | reject_always |
|---|---|---|
| `execute` | Always allow this command | Always reject this command |
| `edit` | Always allow edits to this file | Always reject edits to this file |
| `write` | Always allow writing this file | Always reject writing this file |
| `create` | Always allow creating this file | Always reject creating this file |
| `delete` | Always allow deleting this file | Always reject deleting this file |
| `move` | Always allow moving this file | Always reject moving this file |
| `fetch` | Always allow fetching this URL | Always reject fetching this URL |
| `WebSearch` | Always allow this search | Always reject this search |
| `SlashCommand` | Always allow this command | Always reject this command |
| `SubAgent` | Always allow this subagent | Always reject this subagent |
| `Skill` | Always allow this skill | Always reject this skill |
| `switch_mode` | Always allow this mode | Always reject this mode |
| (fallback) | `option.name` (ACP) | `option.name` (ACP) |

Deictic ("this command" / "this file") rather than echoing the value — the
tool-call block already shows the command/path, so repeating it bloats the
float. Optionally append the basename for file kinds if disambiguation proves
useful in practice; defer until asked.

"this session" scope is **not** added to the wording — matches the bridge's
own omission and the float stays terse.

## Implementation

1. **Thread the tool kind into rendering.** `PermissionFloat:open(options)`
   (`permission_float.lua:253`) and the inner `build_lines(options)` (`:110`)
   currently receive only the options list. Add a `tool_call` (or `kind`)
   parameter. Caller is `permission_manager.lua:694`
   (`self.permission_float:open(sorted_options)`) — pass `request.toolCall`.

2. **Resolve the kind with the execute fallback.** Reuse the same logic as the
   cache key: `kind_key(tool_call.kind)`, and for `execute` with no kind, fall
   back to the tracker entry
   (`message_writer.tool_call_blocks[toolCallId].kind`) exactly as
   `_build_cache_key` does (`:165`) — opencode sends `metadata:{}` /
   `kind="other"` on shell requests.

3. **Add the wording map** as a module-local table in `permission_float.lua`
   (two sub-keys per kind: `allow_always`, `reject_always`). In `build_lines`,
   when `kind_key(option.kind)` is `allow_always` or `reject_always` and the
   resolved tool kind has an entry, use the override; else keep `option.name`.

4. **No behavioural change.** This is display-only. The cache key, the
   approval logic, and the option ordering are untouched. The synthetic
   "Reject all" entry (`build_lines:125`) keeps its own name.

## Test

`permission_float` rendering is pure (`build_lines` is a pure transformation).
Add one assertion-style check: feed a synthetic `execute` tool_call + the
three claude options, assert line 2 contains "Always allow this command" and
that an unknown kind falls back to the provider's `option.name`. No framework
beyond the existing `*.test.lua` setup.

## Out of scope

- Persistent (cross-session) rules — no ACP method exists.
- `/trust` scope wording — that's a separate mechanism set via `/trust`, not
  via this prompt.
- Echoing the concrete command/path in the label.
