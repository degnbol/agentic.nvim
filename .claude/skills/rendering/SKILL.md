---
name: rendering
description:
  Chat-buffer rendering — tool call blocks, code fences, search highlighting,
  body folding, heading levels, where new content goes in the chat. Use when
  adding a tool kind or a new kind of chat content, changing the fence info-string,
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
Buffer-wide rules:

- Folding uses `agentic.ui.folds`'s own foldexpr over `queries/agentic/folds.scm`,
  isolated from real markdown buffers. Not `vim.treesitter.foldexpr()` — that
  one folds every injected tree too; the module docstring says why that is
  unusable here.
- All programmatic highlighting goes through extmarks, never vim syntax rules —
  treesitter clears `vim.bo.syntax` and the chat buffer has to render correctly
  with or without a user re-enable. Highlight group names are in
  `lua/agentic/theme.lua` (`Theme.HL_GROUPS`).
- Fence delimiter rows are hidden by `agentic.ui.fence_rows` extmarks; the
  chat's highlighter gets markdown's highlights query without `conceal_lines`
  (rationale in that module's docstring).
- Horizontal scroll moves every row by displayed columns, not raw ones, via
  the `agentic.ui.edge_conceal` decoration provider (rationale in its module
  docstring).
- The chat is in time order: content shows where it happened relative to
  everything else. Content the client learns of after later output is written,
  such as records read from the CLI transcript, goes beneath the item it
  belongs to and below anything already placed there
  (`MessageWriter:_resolve_anchor`, `_insert_after`). Only
  content whose item is not in the buffer goes at the end.

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

## Region layout (sign column)

```
󰆍  ### <argument>         ← header (sign extmark = kind glyph, NS_DECORATIONS)
│  ```<lang>              ← optional command fence (execute/search)
│  <command lines>
│  ```
│  ```<lang>              ← optional body fence
│  <body lines>
│  ```
╰─  ✔ completed · grant   ← footer (sign + status text + cause note — NS_STATUS)
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
`ErrorReport.format` builds (the provider's words, then any class hint), and a
rail over heading and body. Its identity sign is in
`NS_DECORATIONS`, not `NS_USER_ACTIONS` — `[[`/`]]` walks user actions. What
the client does about the error (a send time, a login offer) goes in dimmed
rows directly under the rail. See `write_error_message` and
`write_error_action`.

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
| Execute command (argument fence) | the block's `shell` (e.g. `zsh`), `bash` fallback; `<shell>-foldnext` once output arrives, except with `output_file` | The shell label is cosmetic (zsh is aliased to `bash`) |
| Search command (argument fence) | `bash`; `bash-foldnext` once output arrives | |
| Execute body | `console`, or `console-fold` past one row | A body that arrives as one fenced block is unwrapped by `CanonicalToolCall.normalise` |
| Execute body with `output_file` | unfenced path row, then `console` over the tail | No fold in the block, command fence included: a tail re-render would reopen a fold the user closed (`command_fold_state`) |
| Search body | `console`, or `console-fold` past one row | `console` prevents markdown parsing of `--`, `*` |
| Prose body (`prose_section`) | `markdown-fold` (multi-line) or `markdown` | Dimmed (sidecar) via `set_dim_range` (`AgenticDimmedBlock`) |
| Generic and todowrite body | `json`, `markdown` (flat JSON table) or `console`, `-fold` past `other_max_lines` | todowrite folds closed past one row; not dimmed |
| Diff content (edit/write/create) | `text`, `text-fold` past one row; `text-foldnext` when failed with a reason | Fold `open`, or `closed` when the edit failed or a created file exceeds `create_max_lines`. Highlighting via `block_col_hl` extmarks, language inferred from the path (contents only as a fallback for extensionless files). Never prose-wrapped (rendered faithfully to file, including markdown) |
| Failure reason | `console`, or `console-fold` past one row (closed) | Dimmed. Replaces the kind-specific body when `status == "failed"` — **except edits**, which keep the diff and append the reason beneath it, and execute, which shows it as output |
| Rejected call (`CanonicalToolCall.rejection_line` set) | command or diff fence `<lang>-foldfence` (closed); then `console`, or `console-fold` with agent text (closed) | Replaces every kind's body. The reason section is titled: its first row is the rejection line, the rest the text the agent was sent |

`injections.scm` strips a trailing
`-fold`, `-foldnext` or `-foldfence` before resolving the injected parser (so sidecar markdown still
highlights). A `text` label names no parser, so it is never injected — an
injected zsh diff can hang the editor (`ZshParseGuard`).

**Downstream fence consumers never match a fixed backtick pattern.** Body rows
can be delimiter-shaped. Use `FenceRows:marked` for zero-height delimiter rows
in the chat, `Treesitter.code_block_rows` for rows inside a block, or
`TextWrap.closes_fence` for the closer of a known opener.

## Body folding

A fold marker on the fence language is the only fold trigger — and, because
levels come from the root tree alone, the chat buffer's only fold source at
all. Three variants:

- `<lang>-fold` (sidecar bodies past their threshold, thought runs via
  `_append_collapsed_region`, hook output and discovered skills via
  `_place_collapsed_region`, edit diffs) folds its content.
- `<lang>-foldnext` (execute and search commands, failed edits) folds through
  the `console`/`console-fold` fence after it; the output's own fold nests
  inside.
- `<lang>-foldfence` (a rejected call's command or diff) folds through its own
  closing fence row, so a one-row body still forms a fold that closes.

Mechanism is split across four files; read them in this order when changing
fold behaviour:

1. `queries/agentic/folds.scm` — folds `code_fence_content`, not the whole
   `fenced_code_block` (the file's top comment explains why and both patterns).
2. `lua/agentic/ui/folds.lua` — the foldexpr: root-tree-only levels, updated
   per edit. Its module docstring is the record of why core's
   `vim.treesitter.foldexpr()` cannot be used here.
3. `lua/agentic/ui/tool_call_layout.lua` — `assemble`: a section with
   `fold` set gets `-fold`, or the marker its `fold_through` names; each
   `Layout.folds[i].anchor` is the first row inside that fold, and
   `Layout.titled` holds the opening fence row of each `titled` section.
4. `lua/agentic/ui/message_writer.lua` — `_render_block_folds` places a tool
   call's folds. `_queue_fold`'s docstring explains why the fold op is
   deferred, why it goes through `BufHelpers.set_fold`, and how anchor
   extmarks survive edits and chat-window hides.

`folds.lua` provides the `··· N lines ···` foldtext, led by the body's first
row for a `-foldnext` or `-foldfence` fold and where the writer marks the
fence row in `Folds.NS_TITLED` (a titled section, a titled collapsed region).

Adding a new foldable kind:

1. Decide the threshold policy and set `fold` on the body section in its
   `BODIES` builder when the body exceeds it; `assemble` adds `-fold` and
   the anchor.
2. No changes needed to `folds.scm`, `injections.scm` or `folds.lua` — they
   match the fold markers generically.

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
