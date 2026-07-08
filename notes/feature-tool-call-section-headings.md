# Feature: tool-call section headings as breadcrumb anchors

Supersedes `feature-treesitter-context.md` (folded in below).

## Goal

Two coupled changes to how tool-call blocks and prompts render in the chat
buffer:

1. **Collapse the tool-call head to one informative line.** Replace the
   constant kind word (`### Read`, `### Execute`, …) with the *content* that
   currently sits on the second line: the filename for read/edit/write, the
   agent-written description for execute. A per-kind glyph carries the kind
   identity so the word is not missed.
2. **Make those headings useful treesitter-context breadcrumbs.** Scrolling a
   long Edit diff should pin the *filename*; landing on a post-tool summary
   should pin the *prompt*; neither should show a stale filename.

The two are one design: the chat buffer is a **section tree**, and a "title" is
a section anchor chosen so treesitter-context pins the right thing.

## How treesitter-context pins (the binding constraint)

Verified against the installed plugin (`context.lua`):

- `get_parent_nodes` builds the **full ancestor chain** root→cursor; no early
  stop.
- The main loop iterates **every** ancestor and pins each that the query
  captures as `@context`, **skipping** non-matching ancestors and continuing
  upward (`if range0 and …`).
- `context_range` returns a range only when the node **itself** is the
  `@context` capture (`node == node0`, `max_start_depth = 0`). An unmatched
  node contributes nothing — it does **not** render as a blank line.
- It renders each pinned node's **first buffer line**. There is no hook to
  inject custom text — config is layout only (`max_lines`, `mode`,
  `trim_scope`, `separator`, `zindex`, `on_attach`).

Current config (`lua/plugins/treesitter.lua`): `max_lines = 1`,
`min_window_height = 15`, `multiwindow = true`, `on_attach` excludes only
`^AgenticInput`. `trim_scope` defaults to `'outer'` (plugin default).

**Consequence exploited below:** with `max_lines = 1` + `trim_scope = 'outer'`,
when several ancestors match, the **innermost** wins and outer ones are
trimmed. So filename (inner, `###`) beats prompt (outer, `##`) inside a diff,
while the prompt shows when it is the only match (summaries, intro prose).

## Chat parses as a private `agentic` language

`lua/agentic/init.lua:435` adds language `agentic` as a markdown-grammar clone;
`:440` registers it for `AgenticChat`. Its queries live in `queries/agentic/`
and are **isolated** from real markdown — `queries/agentic/context.scm` is
standalone (no `; inherits`/`; extends`), so it fully controls what pins in the
chat buffer. (A live test in a `.md` file exercises nvim-treesitter-context's
*stock* markdown query, which is unguarded and pins bare headings — not
representative of the chat buffer.)

## Grammar facts (verified via parse tree)

```
### filename.lua   → atx_heading { atx_h3_marker, inline }   ← has inline
###   (empty)      → atx_heading { atx_h3_marker }           ← NO inline child
## prompt text     → atx_heading { atx_h2_marker, inline }   ← has inline
```

An empty ATX heading has **no `inline` child**. So an `(atx_heading (inline))`
guard in the query excludes empty headings — the basis for the boundary
mechanism below. Markdown has **no section-close token**: a section is closed
only by the next heading of equal/shallower level or EOF. `---` is a
`thematic_break` and does **not** close a section (and setext only offers
H1/H2, so it cannot close a `###`). The only way to close a `###` is a
subsequent `###`/`##`.

## Design decisions

### Tool-call head — collapse to one line

- `### <glyph> <name>` where `<name>` is backtick-wrapped
  (`` ### <glyph> `path` ``) so markdown inline parsing (emphasis on `_`,
  stray `` ` ``, etc.) cannot corrupt the heading.
  - read / edit / write → filename.
  - execute → agent description; if absent, the command's **first line**,
    truncated to one screen line: `wrap_width` minus `### `, glyph+space, and
    one cell for `…`; fallback ~80 when `wrap_width == 0`. Full command still
    renders in the fence below.
- The glyph is keyed on kind. edit and write intentionally share identity
  (both arrive as `kind == "edit"`, distinguished only by diff content — write
  is an empty-`old_string` pure-addition diff); this matches today's behaviour.
- delete/move are ACP-spec kinds but not emitted by the providers in use
  (deletes/moves go through `rm`/`mv` as `execute`); no dedicated handling
  needed — they fall to the generic branch.

### Prompt — first line onto the heading

Today `_handle_input_submit_inner` (and the replay path in `session_manager`)
build the user message as `{"##", input_text, …}`, rendering an **empty** `##`
heading with the text as a paragraph below. Move the prompt's **first line onto
the `##`** (`## <first line>`); remaining lines become body. This is what makes
the prompt a meaningful breadcrumb.

### Section boundaries — close the tool section before resumed prose

Assistant prose that resumes **after** a tool-call block would otherwise stay
*inside* that `### filename` section (no heading closes it), so the breadcrumb
would pin the stale filename while reading the summary. Fix: emit an **empty
`###`** before such prose. It is fence-less and empty, so the query (below)
never pins it; the walk skips it and lands on `## prompt`.

- Only needed where **prose follows a fence** — a mid-turn resume, and the
  final summary. Between two tool calls, the next `###` already closes the
  prior one; no extra boundary.
- Emit **once per contiguous prose run**, not per stream chunk.
- **Visible for v1** (unconcealed, like the existing empty `##`). Re-evaluate
  concealing to zero height (`conceal_lines`) in v2 after seeing it in use.

### ts-context query (`queries/agentic/context.scm`)

Capture, both guarded with `(atx_heading (inline))` so empty headings never
match:

- non-empty **fence-bearing** sections (tool calls) — pins the filename inside
  a diff;
- the non-empty **`## prompt`** section — pins the prompt when it is the only
  matching ancestor.

Resulting behaviour under `max_lines=1` + `trim_scope='outer'`:

- inside a diff → ancestors `{## prompt, ### filename}` → innermost wins →
  **filename** (prompt trimmed; still one line, no extra real estate);
- in post-tool summary / intro prose → only `## prompt` matches → **prompt**;
- empty boundary `###` → never pins.

This is **not** the stacked "prompt + file" option (rejected for real estate);
it is "innermost wins," capped at one line.

### Styling

- Drop the Function-colour extmark that highlighted the old kind word (its
  reason — a kind reads like a function call — is gone).
- Tone down the markdown heading highlight **buffer-locally in AgenticChat** so
  `##`/`###` are not double-underlined. Decouples "is a heading (for
  ts-context)" from "looks important." The visible boundary `###` inherits this
  toned-down style.

## Implementation surface

- `lua/agentic/ui/tool_call_renderer.lua`
  - `prepare_block_lines`: collapse the head — glyph + backtick-wrapped
    name/description on the `###` line; drop the separate argument line for the
    collapsed kinds. Execute fallback + truncation.
  - `apply_tool_header_syntax`: remove the kind-word Function highlight; adjust
    to the new single-line head (backtick span highlight).
- `lua/agentic/ui/diff_jump.lua`: `body_offset = block_start_row + 3` → `+ 2`
  (comment: header + opening fence, filename line removed). **Update its tests**
  (`diff_jump.test.lua`) — they pass explicit cursor rows computed from the old
  3-line layout.
- `lua/agentic/session_manager.lua`: prompt first line onto `##` (live path
  `_handle_input_submit_inner`, replay path `user_message_chunk`).
- `lua/agentic/ui/message_writer.lua`: emit the empty `###` boundary before a
  prose run that follows a tool-call block (once per run).
- `queries/agentic/context.scm`: rewrite per the query section above.
- Heading highlight tone-down: buffer-local highlight setup for AgenticChat
  (theme / ftplugin).
- Glyph set: per-kind, in `theme.lua` or the renderer.

## Test impact

- `diff_jump.test.lua`: row math shifts by one (the deciding cost).
- Any test asserting the tool head is `### <Kind>` or the filename is a
  separate `` `…` `` line.
- No `### Edit` equality assert exists in diff_jump tests (row-count based).

## Folded-in facts from the retired ts-context note

- **Read is not a ts-context win** — it renders only a `Read N lines` summary,
  no fence, nothing to scroll or pin. It still gets the aesthetic one-line
  collapse, just no breadcrumb benefit.
- **Edit is the win** — its diff is one foldable fence, applied edits fold open
  and scroll, so the filename must be pinnable. Injected-language context never
  fires inside a diff (the `-difffold` marker suppresses injection so it folds
  as one block), so the section-header pin is the only lever there.
- **Execute/Search** emit fences too, but their argument is a command, not a
  file — the filename framing does not apply; the description/command-first-line
  is what pins.
- Already committed previously: ts-context re-enabled for the chat buffer
  (`on_attach` excludes only `^AgenticInput`); the initial scoped query
  `(section (fenced_code_block)) @context`. This plan **replaces** that query.
- The earlier B-subheading/B-merge dilemma is **obsolete**: it existed only
  because that session kept the kind word and needed a 4th heading level for
  the filename. Dropping the kind word lets the collapsed `### filename`
  directly head the fence — cleaner, at the bounded cost of the diff_jump
  `+3→+2` fix.

## Open for v2

- Conceal the boundary `###` to zero height if the visible empty heading reads
  as noise.
