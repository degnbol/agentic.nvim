---
name: rendering
description:
  Chat-buffer rendering — tool call blocks, code fences, search highlighting,
  body folding. Use when adding a tool kind, changing the fence info-string,
  modifying tool_call_renderer or message_writer rendering paths, editing
  queries/agentic/folds.scm or injections.scm, or wiring in a new foldable
  body. Per-site rationale (sign_text vs virt_text, set_text vs set_lines,
  fold-anchor scheduling, priority numbers) lives in docstrings at the
  relevant functions — read those first.
---

# Chat-buffer rendering

The chat buffer is `filetype=AgenticChat` parsed as the private `agentic`
treesitter language — a clone of the markdown parser registered in
`init.lua` (see the `language.add` block there for the registration rationale).
Two consequences worth carrying in your head:

- Folding uses `vim.treesitter.foldexpr()` driven by `queries/agentic/folds.scm`,
  isolated from real markdown buffers.
- All programmatic highlighting goes through extmarks, never vim syntax rules —
  treesitter clears `vim.bo.syntax` and the chat buffer has to render correctly
  with or without a user re-enable. Highlight group names are in
  `lua/agentic/theme.lua` (`Theme.HL_GROUPS`).

## Tool call block layout

```
╭─ ### <Kind>             ← header (sign extmark = ╭─, NS_DECORATIONS)
│  `<argument>`           ← argument or kind-specific
│  ```<lang>              ← optional command fence (execute/search)
│  <command lines>
│  ```
│  ```<lang>[-fold]       ← optional body fence
│  <body lines>
│  ```
╰─  ✔ completed           ← footer (sign + status text — NS_STATUS)
```

Borders (╭ │ ╰) are `sign_text` extmarks via `utils/extmark_block.lua`; status
text is real buffer text written with `nvim_buf_set_text` then highlighted with
an extmark in `NS_STATUS`. The header `### Kind` and argument backticks get
extmark highlights from `apply_block_highlights`. All extmarks share priority
200 so they win over markdown injections (priority 100) — see the comment on
`get_clean_hl_group` for why a higher priority alone is not enough.

## Fence info-strings — cross-kind reference

`safe_fence(body_lines)` in `tool_call_renderer.lua` returns a backtick run
one longer than the longest run in the content, so embedded triple-backticks
never close the outer fence. The same fence string is used for open and
close. The info-string after the fence is set per kind:

| Site | Info string | Notes |
| --- | --- | --- |
| Execute command (argument fence) | `shell_lang()` — basename of `$SHELL` (e.g. `zsh`), `bash` fallback | Cosmetic; zsh parser is aliased to `bash`, identical highlighting |
| Search command (argument fence) | `bash` | |
| Execute body | `console`, or `console-fold` when `execute_max_lines` exceeded | claude-agent-acp pre-wraps in its own console fence; `prepare_block_lines` unwraps an already-fenced execute body before re-wrapping |
| Search body | `console`, or `console-fold` when `search_max_lines` exceeded | `console` prevents markdown parsing of `--`, `*` |
| Fetch / WebSearch / SubAgent body | `markdown-fold` (multi-line) or `markdown` | Always folded + dimmed (sidecar) when multi-line; dim via `set_dim_range` (`AgenticDimmedBlock`) |
| Diff content (edit/write/create) | `<lang>-difffold` — `lang` inferred from path | Always foldable as ONE block. Fold state is set **explicitly** at render (`fold_open` return): open normally, closed when the edit failed (e.g. rejected permission). The explicit open is required — a fold created after a closed one inherits the closed state under `foldmethod=expr`, so relying on the foldlevel default would leave applied edits collapsed after any earlier close (see `MessageWriter:_open_fold`). No language injection (see below); highlighting via `block_col_hl` extmarks. Diff content is never prose-wrapped (rendered faithfully to file, including markdown); `lang` is inferred from the path (contents only as a fallback for extensionless files) and serves as both the fence label and the context-highlighting language |
| Failure reason | `console` | Replaces the kind-specific body when `status == "failed"` — **except edits**, which keep the diff (folded closed) and append the reason beneath it |

**A `fold$`-suffixed info-string is the fold signal.** Two variants:
`<lang>-fold` (sidecar bodies — appended by `prepare_block_lines` when a body
exceeds its per-kind threshold) and `<lang>-difffold` (every edit diff).
`folds.scm` matches `fold$` on the language. `injections.scm` strips a trailing
`-fold` before resolving the injected parser (so sidecar markdown still
highlights) but **excludes `difffold$` from injection entirely** — injecting the
diff's base language ships its `folds.scm`, whose per-structure folds would
shatter the diff into one fold per function/block. With no injection the diff
folds as one block; its syntax colour comes from `block_col_hl` extmarks
(`highlight_map_in_context`), which already override the injection at
priority 200.

**Downstream fence consumers must handle variable width.** Match `^\`+$`
(any backtick-only line) instead of literal triple-backticks, and
`^\`+<lang>$` for typed fences. See `apply_block_highlights` for the
existing pattern.

## Body folding

A `fold$`-suffixed info-string on `code_fence_content`'s parent fence is the
only fold trigger (`<lang>-fold` for sidecar bodies, `<lang>-difffold` for edit
diffs). Mechanism is split across three files; read them in this order
when changing fold behaviour:

1. `queries/agentic/folds.scm` — folds `code_fence_content`, not the whole
   `fenced_code_block` (the file's top comment explains why).
2. `lua/agentic/ui/tool_call_renderer.lua` — `prepare_block_lines` decides
   per-kind whether to append `-fold`, and returns `fold_anchor` (0-indexed
   offset of the first body line).
3. `lua/agentic/ui/message_writer.lua` — `MessageWriter:_close_fold` (and
   its docstring) explain why the fold close is deferred via `vim.schedule`
   and how anchor extmarks survive edits and chat-window hides.

Threshold config keys (in `config_default.lua`):

- `search_max_lines` — search/grep bodies
- `execute_max_lines` — shell stdout (and execute failure_reason)
- Fetch / WebSearch / SubAgent — always folded when multi-line, no config

`lua/agentic/ui/foldtext.lua` provides the `··· N lines ···` foldtext.

Adding a new foldable kind:

1. Decide the threshold policy and append `-fold` to the info-string in
   `prepare_block_lines` when the body exceeds it.
2. Return the correct `fold_anchor` (offset within the returned `lines` to
   the first body line — the line *inside* the fold, not the fence
   delimiter).
3. No changes needed to `folds.scm` or `injections.scm` — they match the
   `fold$` suffix generically (use `<lang>-fold` to fold *and* inject the base
   language; the `difffold` marker is the special case that suppresses
   injection).

## Search match highlighting

`extract_search_term_highlights` in `tool_call_renderer.lua` extracts the
pattern from the command's first quoted string (or an explicit `pattern`
argument). Highlights via `AgenticSearchMatch` extmarks (priority 200).
Grep-format lines (`path:linenum:rest`) get per-component highlights
(`AgenticGrepPath` / `AgenticGrepLineNr` / `AgenticGrepSeparator`); these
fire for all search blocks and for execute blocks whose command starts with
a grep-family tool (`is_grep_command`). The two coexist via the optional
`hl_group` field on `SearchMatch`.

## Update-path invariants (read before changing `update_tool_call_block`)

These are enforced in `MessageWriter:update_tool_call_block`; the existing
inline comments explain the why, but the constraints to *preserve*:

- The range extmark on the block (NS_TOOL_BLOCKS) is the position anchor.
  If it collapses (`start >= end`), bail out and drop the tracker — do not
  proceed with stale positions.
- Content comparison excludes the footer line (`new_lines` produces `""`
  there; the buffer holds the status text). Status-only updates must skip
  the expensive content replacement path.
- Diff blocks are frozen after first render — only status footer refreshes
  on subsequent updates. `already_has_diff` gates this.
