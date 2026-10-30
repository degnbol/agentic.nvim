---
name: rendering
description:
  Chat-buffer rendering — tool call blocks, code fences, search highlighting,
  body folding. Use when adding a tool kind, changing the fence info-string,
  modifying tool_call_layout/_renderer or message_writer render paths, editing
  queries/agentic/folds.scm or injections.scm, or wiring in a new foldable
  body. Per-site rationale (sign_text vs virt_text, set_text vs set_lines,
  fold-anchor scheduling, priority numbers) lives in docstrings at the
  relevant functions — read those first.
---

# Chat-buffer rendering

The chat buffer is `filetype=AgenticChat` parsed as the private `agentic`
treesitter language — a clone of the markdown parser registered in
`bootstrap.lua` (see the `language.add` block there for the registration rationale).
Two consequences worth carrying in your head:

- Folding uses `agentic.ui.folds`'s own foldexpr over `queries/agentic/folds.scm`,
  isolated from real markdown buffers. Not `vim.treesitter.foldexpr()` — that
  one folds every injected tree too; the module docstring says why that is
  unusable here.
- All programmatic highlighting goes through extmarks, never vim syntax rules —
  treesitter clears `vim.bo.syntax` and the chat buffer has to render correctly
  with or without a user re-enable. Highlight group names are in
  `lua/agentic/theme.lua` (`Theme.HL_GROUPS`).
- Horizontal scroll moves every row by displayed columns, not raw ones, via
  the `agentic.ui.edge_conceal` decoration provider (rationale in its module
  docstring).

## Heading levels

The chat buffer is one markdown document and its ATX level says *whose* row it
is, never how deep in the turn the row was written:

| Level | Rows | Written by |
| --- | --- | --- |
| `#` | Session header (`<timestamp> · <session-id>`) | `SessionManager._generate_welcome_header` |
| `##` | User prompts, command notices, `## Error`; a subagent transcript's heading | `write_user_prompt`, `write_notice`, `write_error_message`, `write_subagent_heading` |
| `###` | Tool call heads, and the empty `###` that closes one | `write_tool_call_block`, `write_message_chunk` |

Level 2 is the turn's own participants — what the user asked, what the user did
mid-turn (`/grant`, `/rename`, a mode or model switch), what the provider reported back.
Level 3 is one step inside such a turn: its tool calls. A row that is not a tool
call never takes `###`, even when it lands in the middle of one turn's tool
calls; the cost is a breadcrumb (see `write_notice`), not a level.

Agent prose carries no heading of its own — it belongs to the `##` prompt
section above it. Headings *inside* agent markdown are the agent's content at
whatever level it chose, and are not part of this scheme; `[[`/`]]` navigation
therefore reads `NS_USER_ACTIONS` extmarks rather than scanning for `## `.

Only levels 2 and 3 are dimmed by the chat window's `winhighlight`
(`chat_buffer.lua`).

## Tool call block layout

```
󰆍  ### <argument>         ← header (sign extmark = kind glyph, NS_DECORATIONS)
│  ```<lang>              ← optional command fence (execute/search)
│  <command lines>
│  ```
│  ```<lang>              ← optional body fence
│  <body lines>
│  ```
╰─  ✔ completed · grant   ← footer (sign + status text + decider note — NS_STATUS)
```

The sign column says what a region *is*, the buffer text what it *contains*:
the opening row carries an identity sign (the kind glyph, from `glyphs.lua`),
continuation rows `│`, the last row `╰─`. A single-row region carries the
identity sign alone. Signs are `sign_text` extmarks via
`utils/extmark_block.lua` (`render_block` = identity + rail, `render_rail` =
rail only, for a region whose identity mark lives in another namespace — see
`MessageWriter:write_user_prompt`). The identity sign takes
`AgenticGlyph{User,Agent}` rather than the rail's `AgenticCodeBlockFence`,
which would dim it.

An error is a region too: `## Error` under `Glyphs.ERROR`, the wrapped body
`format_error_lines` builds (the provider's words, then any class hint), and a
rail that `write_error_action` re-stamps as the
countdown or login offer that follows joins the block. Its identity sign is in
`NS_DECORATIONS`, not `NS_USER_ACTIONS` — `[[`/`]]` walks user actions. See
`write_error_message` and `_extend_error_block`.

Prose is the exception with no identity to announce: a run of it opens on a
plain `╭─` instead, on its first row of text — never on the empty `###`
boundary above, which belongs to the block that boundary closes. Only a run
holding more than one paragraph is bracketed. See `render_prose_region` and the
three `MessageWriter:_{rebuild,extend}_prose_region` / `_end_prose_run` methods
around it: every writer that interrupts prose ends the run through
`_end_prose_run`, and the rail is re-stamped as the run streams.

Because the chat window is `signcolumn=yes:1`, one row holds one sign — a
second extmark on the identity row silently loses. Status text is real buffer
text written with `nvim_buf_set_text` then highlighted with an extmark in
`NS_STATUS`. All extmarks share priority 200 so they win over markdown
injections (priority 100) — see the comment on `get_clean_hl_group`
for why a higher priority alone is not enough.

A tool head with no name renders as a bare `###`, byte-identical to the
section-close boundary `write_message_chunk` emits; both must stay uncaptured
by `queries/agentic/context.scm`.

`collapsed_header` (`tool_call_layout.lua`) backtick-guards the whole name
when the kind is in `CODE_KINDS`, else each word that needs it
(`MarkdownGuard`). The docstrings carry the rationale.

## Fence info-strings — cross-kind reference

`TextWrap.safe_fence(body_lines)` returns a backtick run one longer than the
longest run in the content, so embedded triple-backticks never close the outer
fence. The same fence string is used for open and close. The info-string after
the fence is set per kind:

| Site | Info string | Notes |
| --- | --- | --- |
| Execute command (argument fence) | the block's `shell` (e.g. `zsh`), `bash` fallback; `<shell>-fold` once output arrives | The shell label is cosmetic (zsh is aliased to `bash`). The fold runs through the `console` output fence (`execute_fold_state`) |
| Search command (argument fence) | `bash` | |
| Execute body | `console` | Folded with the command fence above it. A body that arrives as one fenced block is unwrapped by `CanonicalToolCall.normalise` |
| Search body | `console`, or `console-fold` when `search_max_lines` exceeded | `console` prevents markdown parsing of `--`, `*` |
| Fetch / WebSearch / SubAgent / switch_mode body | `markdown-fold` (multi-line) or `markdown` | Dimmed (sidecar) via `set_dim_range` (`AgenticDimmedBlock`) |
| Generic and todowrite body | `json`, `markdown` (flat JSON table) or `console`, `-fold` past `other_max_lines` | todowrite folds closed past one row; not dimmed |
| Diff content (edit/write/create) | `<lang>-difffold` — `lang` inferred from path | Always foldable as ONE block: `open`, or `closed` when the edit failed (e.g. rejected permission) or a created file exceeds `create_max_lines`. No language injection (see below); highlighting via `block_col_hl` extmarks. Diff content is never prose-wrapped (rendered faithfully to file, including markdown); `lang` is inferred from the path (contents only as a fallback for extensionless files) and serves as both the fence label and the context-highlighting language |
| Failure reason | `console` | Replaces the kind-specific body when `status == "failed"` — **except edits**, which keep the diff (folded closed) and append the reason beneath it |

`injections.scm` strips a trailing
`-fold` before resolving the injected parser (so sidecar markdown still
highlights) but **excludes `difffold$` from injection entirely** — a diff's
syntax colour comes from `block_col_hl` extmarks (`highlight_map_in_context`),
which override any injection at priority 200, so injecting the base language
would only buy a second parse of the same text.

**Downstream fence consumers must handle variable width.** Match `^\`+$`
(any backtick-only line) instead of literal triple-backticks, and
`^\`+<lang>$` for typed fences.

## Body folding

A `fold$`-suffixed fence language is the only fold trigger — and, because
levels come from the root tree alone, the chat buffer's only fold source at
all. Two variants: `<lang>-fold` (sidecar bodies past their threshold, thought
runs and hook blocks via `_write_collapsed_region`, the execute command fence)
and `<lang>-difffold` (every edit diff). A `-fold` fence directly followed by a
`console` fence folds through that fence's content too (execute command and
output). A second word after the language (`markdown-fold guard.sh`) is
ignored by the queries and read by the foldtext as the body's name. Mechanism
is split across four files; read them in this order when changing fold
behaviour:

1. `queries/agentic/folds.scm` — folds `code_fence_content`, not the whole
   `fenced_code_block` (the file's top comment explains why and both patterns).
2. `lua/agentic/ui/folds.lua` — the foldexpr: root-tree-only levels, cached
   per `b:changedtick`. Its module docstring is the record of why core's
   `vim.treesitter.foldexpr()` cannot be used here.
3. `lua/agentic/ui/tool_call_layout.lua` — `assemble`: a section with
   `fold` set gets `-fold`; `Layout.fold.anchor` is the first row inside the
   fold.
4. `lua/agentic/ui/message_writer.lua` — `_render_block_fold` places a tool
   call's fold. `_queue_fold`'s docstring explains why the fold op is
   deferred and how anchor extmarks survive edits and chat-window hides.

`folds.lua` provides the `··· N lines ···` foldtext, led by the fence's name
word, or for a joined fold by its first row, plus a character count where the writer marks the
fence row in `Folds.NS_CHAR_COUNT`.

Adding a new foldable kind:

1. Decide the threshold policy and set `fold` on the body section in its
   `BODIES` builder when the body exceeds it; `assemble` adds `-fold` and
   the anchor.
2. No changes needed to `folds.scm`, `injections.scm` or `folds.lua` — they
   match the `fold$` suffix generically. A `-fold` section directly before a
   `console` section joins its fold.

## Wrapped tables

`TextWrap.wrap_prose` wraps body cells of a table wider than the wrap width
onto continuation rows; the last line of each logical row carries
`AgenticTableRowEnd` (rationale in `Renderer.mark_table_row_end`).

## Search match highlighting

`GrepHighlights.terms` (`utils/grep_highlights.lua`) matches a pattern
against the body via `AgenticSearchMatch` extmarks (priority 200, over ANSI
spans at 150).
Terms match only the text of a match line, after its `path:N:` prefix, and a
match must be the same under every layout the grep's flags allow (see
`GrepOutput`); a missing highlight is acceptable, a false one is not.
Search blocks take the pattern from `search_pattern`, else the command's
first quoted string, and `-i` from the title (a ` -P` multiline title gets
no term highlights). Execute blocks that contain a
grep-family command anywhere (`ShellParse.extract_commands`) take each
command's patterns, case rule, dialect, `-w`/`-x` and layouts from its argv
(`GrepArgs.parse`). Patterns are translated from the grep's dialect
(`GrepRegex.translate`); a construct outside the supported set gives no term
highlight.
Grep-format lines (`path:linenum:rest`) get per-component highlights
(`AgenticGrepPath` / `AgenticGrepLineNr` / `AgenticGrepSeparator`); these
fire for all search blocks and for those same execute blocks. Execute
blocks whose grep asked for line numbers (`GrepArgs.Invocation.line_numbers`)
also accept a path-less `linenum:rest`. The two coexist via the optional
`hl_group` field on `GrepHighlights.Match`.

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
