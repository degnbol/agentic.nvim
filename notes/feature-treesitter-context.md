# Feature: treesitter-context for code blocks in the chat buffer

## Goal

When scrolling through a long fenced code block in the chat buffer, keep useful
context pinned at the top of the window (the way treesitter-context pins a
function signature when its first line scrolls out of view).

Two layers of context:

1. **Injected language context** — inside a ```lua / ```python block, pin the
   enclosing function/class. Free: treesitter-context descends into injection
   trees (`context.lua` `get_parent_langtrees`) and runs each injected
   language's own `context.scm`.
2. **The filename** — for an **Edit** diff, pin which file the diff applies to.
   This is the real win (see below).

## Where the win actually is: Edit, not Read

- **Read** renders only a one-line summary `Read N lines (10 - 50)` — *no code
  fence* (`tool_call_renderer.lua` `kind == "read"`). Nothing to scroll, nothing
  to pin. Out of scope.
- **Edit** renders the diff as one foldable fence (```lua-difffold). Applied
  edits fold **open**, so a long diff is scrollable, and both `### Edit` and the
  `` `/path` `` line scroll off the top. Pinning the filename here is the win.
- Execute / Search also emit fences (command output, grep results), but their
  argument is a command, not a file — the filename framing doesn't apply.

**Key constraint specific to Edit:** the diff fence is deliberately *excluded*
from language injection (the `-difffold` marker, `injections.scm`) so it folds
as one block. That means layer 1 (injected function context) **never fires
inside a diff**. So for the Edit win, the section-header pin is the *only*
lever — the filename has to be made pinnable.

## How pinning works (the binding constraint)

treesitter-context only ever pins **ancestor** nodes of the cursor, and renders
each ancestor's **first buffer line** (`context.lua` walks `n:parent()` /
`child_with_descendant`; there is no hook to inject custom text — config is all
layout: `max_lines`, `mode`, `separator`, `zindex`, `on_attach`).

The Edit block parses as:

```
section "### Edit"          ← ancestor of the fence; first line "### Edit"
├─ atx_heading "### Edit"
├─ paragraph  "`/file.lua`"  ← SIBLING of the fence, never an ancestor
└─ fenced_code_block         ← cursor scrolls inside here
```

The filename is a **sibling paragraph**, not an ancestor → it can never be
pinned as-is. To pin the filename it must become the first line of an *ancestor*
node, i.e. either fold it into the `### Edit` heading, or give it its own
sub-section heading.

## Done (committed in this session)

- **C — re-enable.** `lua/plugins/treesitter.lua` `on_attach` previously
  disabled treesitter-context for all `^Agentic` buffers; now excludes only
  `^AgenticInput` (the prompt box), so it attaches to the chat buffer.
- **A — scoped section query.** `queries/agentic/context.scm`:
  `(section (fenced_code_block)) @context`. Pins the tool-call `### Edit`
  header, scoped to code-bearing sections so prose-only headings in assistant
  messages are not pinned. Lives in agentic.nvim's own rtp — `query.get` finds
  it, no site symlink needed.

Result so far: scrolling a diff pins `### Edit`; scrolling an injected block
(```lua in assistant prose) pins its function/class. The filename is **not yet**
pinned.

## B — pin the filename (the remaining work)

The filename must head an ancestor node. Two shapes:

### B-subheading (recommended)

Render the Edit filename as a level-4 heading instead of inline code:

```
### Edit
#### /file.lua          ← was: `/file.lua`
```lua-difffold
…diff…
```
```

Parse becomes `section(### Edit) > section(#### /file.lua) > fenced_code_block`.
The scoped query `(section (fenced_code_block))` matches the **inner** section
(the only one directly containing the fence), so it pins `#### /file.lua` — the
filename. `### Edit` no longer directly contains the fence, so it stops being
pinned (acceptable — filename is more useful).

- **Layout preserved** — still one filename line, so `fold_anchor`, diff
  block offsets, and **diff_jump row math are untouched** (diff_jump tests and
  runtime assume `row 0: ### Edit / row 1: filename / row 2: fence`).
- **Changes required:**
  - `tool_call_renderer.lua` diff branch (`elseif tool_call_block.diff`): emit
    the filename line as `#### <path>` instead of `` `<path>` ``. Scope to the
    diff branch only — leave other kinds' `` `arg` `` lines alone.
  - `apply_tool_header_syntax` (`tool_call_renderer.lua:1421`): currently
    highlights the arg line by finding backticks. Add a `####`-heading branch so
    the path still gets `TOOL_ARGUMENT` highlight.
  - Visual: the filename renders as an h4 heading (markdown heading colour)
    rather than inline code. Decide if that's wanted; if too heavy, keep an
    extmark to restyle it back toward the inline-code look.
- **Test impact:** any test asserting the Edit filename line is `` `…` ``.
  diff_jump tests unaffected (row count unchanged). No `### Edit` equality
  assert exists.

### B-merge (not recommended)

Fold the filename into the heading: `### Edit /file.lua`, drop the separate
line.

- `apply_tool_header_syntax` already highlights everything after `### ` as
  `TOOL_KIND` to end-of-line — would need splitting into kind + path spans.
- **Drops a line → shifts every diff row by one**, breaking diff_jump's runtime
  offset computation *and* its tests (they pass explicit cursor rows computed
  from the current layout, e.g. `compute_target(block, 0, 7, 3)`).

That row-shift is the deciding factor: B-subheading keeps the layout, B-merge
rewrites the diff coordinate system. Prefer B-subheading.

## Decision needed

Proceed with B-subheading for Edit? Open question: render the pinned filename as
a visible h4 heading, or extmark it back to an inline-code appearance.
