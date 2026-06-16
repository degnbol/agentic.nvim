# Highlight unapproved parts of an execute permission prompt

## Goal

When an `execute` (Bash) tool call escalates to a permission prompt, an
execute call often mixes commands the rules consider safe with ones that
need the user's attention. Highlight the parts that need attention in the
rendered command block, so the user can scan before pressing OK. The
highlight is transient: it appears while the prompt is displayed and
disappears on accept/reject.

## Core constraint (non-negotiable)

The SDK executes `rawInput.command` — the **raw** command. Our display
reformatting (`format_long_command` = `split_at_operators` + shfmt) is
client-side UI that never goes back to the SDK.

Therefore the **auto-approve decision** must keep binding to the raw bytes.
Deciding against the reformatted string would authorize a derivative of what
runs, opening a laundering hole (the user-configurable `execute_formatter`
would sit in the security TCB; the matcher is syntactic, so semantic
preservation by shfmt is not sufficient). The decision walk
(`PermissionRules.should_auto_approve`, on `rawInput.command`) is unchanged.

The **highlight** is pure UI. It binds to the **displayed** text so its
coordinates land on buffer rows. It never grants anything — worst case it
highlights nothing while the prompt still fires. These are two walks over
two different strings *by necessity*, not redundancy.

## Classification: what gets highlighted

Classify each leaf by its intrinsic **category** (NOT by whether the current
`auto_approve` mode happens to approve it — a `safe_write` like `git add` is
intrinsically safe even in `read-only` mode and must never be highlighted).

Highlight a leaf ⟺ it is **not** classified `read_only` or `safe_write`:

| Bucket | Highlight? |
| --- | --- |
| matches `read_only` rule (and no deny/ask) | no — known-safe |
| matches `safe_write` rule (and no deny/ask) | no — known-safe |
| matches `deny` rule | yes |
| matches `ask` rule | yes |
| matches no rule at all (unknown command) | yes |
| structural refusal (`$(...)`, unsafe redirect, `eval`, dynamic name, unknown node) | yes |

Rationale for including no-match and structural (rather than strictly
`ask`/`deny`): an unrecognized binary or an opaque `$(...)` is exactly a
"look before OK" case — arguably more than a deliberately-configured `ask`
rule. Excluding them would leave the scariest thing (a command the rules
have never seen) silent.

This classification is independent of `Config.permissions.auto_approve` and
of the `auto_approve_*` master switches — it answers "is this leaf
known-safe", not "was this auto-approved". (Dissolves the degenerate "no
allow sources configured" case: leaves still classify by their rules, so
only non-safe leaves light up.)

The intent is "highlight what we are being prompted for", with one
deliberate exception: a `safe_write` leaf (e.g. `git add`) under
`auto_approve = "read-only"` *does* trigger the prompt, but is intrinsically
safe and is **not** highlighted. In this one edge, the category rule
(known-safe ⇒ never highlight) wins over literally-what-prompted. Everywhere
else the two coincide.

This is the settled classification (the broad "not-known-safe" set,
including no-match and structural). If no-match/structural highlighting ever
proves noisy, narrowing to strictly `ask`/`deny` is a one-line change (the
reason is available at record time) — no config knob for it now (YAGNI).

## Mechanism

### 1. Tally walk (`permission_rules.lua`)

Parameterize the **existing** `walk` with a mode (option (i), single source
of truth for "what counts as safe structure"):

- Decision mode (current behaviour): early `return false` on first
  non-approval; ranges accumulator is `nil`.
- Tally mode: instead of `return false`, append the offending node's
  `node:range()` (0-indexed `start_row, start_col, end_row, end_col`,
  byte cols) to `ctx.ranges` and **continue** walking — container loops stop
  early-returning and record-and-continue; opaque nodes (substitution)
  record their range and do not descend.

The per-leaf classification must be **category-level**, not the mode-resolved
allow set: "does this leaf match `read_only`/`safe_write`?" vs
"does it match `ask`/`deny`?". Likely needs a `classify_leaf` entry point in
`permission_structured.lua` returning the kind (`read_only`/`safe_write`/
`ask`/`deny`/none) rather than the mode-resolved decision, plus the existing
`get_*_patterns` glob buckets used per-category.

New exported function, e.g.:

```lua
--- @return [integer,integer,integer,integer][] ranges  -- relative to the parsed string
function M.tally_unapproved(command)
```

Returns ranges relative to the parsed string's lines. Empty list when the
parse fails or there is nothing to highlight (caller decides fallback).

Keep the decision walk (`should_auto_approve`) bail-fast and unchanged.

### 2. Source text from the buffer

The buffer already contains the exact formatted command lines, written
verbatim between the fences (`prepare_block_lines` does
`vim.list_extend(lines, cmd_lines)`). Read them back rather than stashing
anything (no second shfmt, no stored row that goes stale):

1. Resolve the block's start row from its `NS_TOOL_BLOCKS` range extmark
   (the position anchor of record — see `message_writer` tracker /
   `tool_call_blocks[id]`).
2. Scan downward for the opening fence (`^\`+%a*$`) and matching close
   (`^\`+$`) — the variable-width fence convention downstream consumers
   already use.
3. Read the lines between them, join with `\n`, run `tally_unapproved`.
4. Map: buffer row = `fence_open_row + 1 + range_row`; cols pass through
   (extmark cols are byte offsets, as are tree-sitter cols).

Block stable during the prompt window (agent is blocked waiting on
permission, so nothing appends; folds are display-only and do not shift line
numbers).

Fallbacks (degenerate, prompt still fires — just bare or whole-block):
- Block or fences not found (e.g. provider sends permission before render):
  no-op.
- Parsed command text fails to parse (`root:has_error()`): highlight all
  command-content lines (whole-block fallback (b)).

### 3. Highlight group (`theme.lua` + README)

Add to `Theme.HL_GROUPS`:

```lua
UNAPPROVED_COMMAND = "AgenticUnapprovedCommand",
```

and in `Theme.setup()`:

```lua
{ Theme.HL_GROUPS.UNAPPROVED_COMMAND, { link = "DiagnosticVirtualTextWarn" } },
```

(`default = true` is applied in the existing loop.) Single group for all
highlighted buckets — they're one category to the user ("needs your eyes").
The reason is available at record time if a future deny-vs-ask colour split
is wanted.

- Extmarks at **priority ≥ 200** so the warning bg wins over injected bash
  syntax (injections are priority 100), consistent with other chat extmarks.
- README: document the group. Caveat — `DiagnosticVirtualTextWarn` is fg+bg
  in some themes, fg-only in others; on a bare theme set an explicit `bg` for
  the wash.

### 4. Lifecycle (`permission_manager.lua`)

Mirror the existing `_setup_keymaps` / `_remove_keymaps` per-request pairing.

- One module-level `NS_PERMISSION_HIGHLIGHT = vim.api.nvim_create_namespace(...)`.
  Clearing is per-buffer, so each tab's manager only touches its own chat
  buffer (no cross-tab interference despite the shared ns id).
- **Apply** in `_process_next`, right after `permission_float:open(...)`,
  gated on:
  - `Config.permissions.highlight_unapproved`
  - request kind is `execute` (with the same `tracker.kind` fallback used
    elsewhere in this file — opencode quirk)
  - valid chat buffer (`message_writer.bufnr`)
  Non-execute kinds (edit/write/fetch/...) have no command to decompose →
  no-op.
- **Clear** (`nvim_buf_clear_namespace(chat_bufnr, ns, 0, -1)`) in:
  - `_complete_request`
  - `reject_and_cancel_remaining`
  - `clear`
  (`remove_request_by_tool_call_id` routes through `_complete_request(nil)`,
  already covered.)

Sequential queue means at most one block highlighted at a time, matching the
float.

### 5. Config (`config_default.lua`)

```lua
permissions = {
    -- ...
    highlight_unapproved = true,  -- highlight non-known-safe parts of an
                                  -- execute permission prompt while it is shown
}
```

Independent of the `auto_approve_*` switches (highlight answers "is this
known-safe", useful even when compound auto-approval is off; the per-feature
toggle is the escape hatch for noise).

## Tests (`permission_rules.test.lua`)

Extend with `tally_unapproved` cases:
- mixed leaf pipeline: safe leaf (`read_only`) + `ask`/`deny` leaf → only the
  latter's range returned.
- `safe_write` leaf → not returned (even though it would prompt in
  `read-only` mode).
- unknown command → returned.
- structural: `$(...)`, `> file`, `eval`, dynamic name → returned (node span).
- multiple unapproved leaves → all returned (record-and-continue, no
  bail-on-first).
- parse failure → empty list (caller does whole-block fallback).

## Files touched

- `lua/agentic/utils/permission_rules.lua` — parameterize `walk` with tally
  mode; add `tally_unapproved`.
- `lua/agentic/utils/permission_structured.lua` — add category-level
  `classify_leaf` (or equivalent) if not derivable from existing entry points.
- `lua/agentic/ui/permission_manager.lua` — apply/clear methods + namespace,
  wired into `_process_next` / `_complete_request` /
  `reject_and_cancel_remaining` / `clear`; buffer read + fence scan + extmark
  placement (or a small `permission_highlight.lua` helper if it grows).
- `lua/agentic/theme.lua` — new `UNAPPROVED_COMMAND` group.
- `lua/agentic/config_default.lua` — `highlight_unapproved` flag.
- `README.md` — document the new highlight group + theme caveat.
- `lua/agentic/utils/permission_rules.test.lua` — tally cases.

## Validation

`make validate` (luals + selene + tests). On failure read the log files with
`tail`/`rg`, not the Read tool (per CLAUDE.md).
