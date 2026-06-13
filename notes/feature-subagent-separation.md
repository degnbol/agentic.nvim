# Plan: separating subagent work in the chat

## Problem

When Claude spawns a subagent (the `Task` tool), the subagent's prose,
thinking, and tool calls render in the chat identically to and interleaved
with the main agent's. Multiple parallel subagents mix together with no way
to tell which call belongs to which agent.

## The wire signal (claude-agent-acp)

The bridge runs every subagent in the *same* ACP session as the main agent
but tags each notification with the spawning `Task` tool's id. In
`acp-agent.js`, the SDK message's `parent_tool_use_id` is `null` for
top-level (main agent) messages and set to the parent Task's `tool_use_id`
for subagent messages. `toAcpNotifications(...)` stamps it onto **every**
notification type it emits — `agent_message_chunk`, `agent_thought_chunk`,
`tool_call`, `tool_call_update`, and terminal sub-notifications — as
`update._meta.claudeCode.parentToolUseId`. Top-level messages omit the field.

Routing rule:

| Origin | `_meta.claudeCode.parentToolUseId` |
| --- | --- |
| Main agent | absent |
| Subagent spawned by Task `toolu_X` | `"toolu_X"` |
| Parallel subagent spawned by Task `toolu_Y` | `"toolu_Y"` |

The grouping key is ready-made: each `Task` spawn has a unique
`tool_use_id`, and that id is exactly the `toolCallId` of the `SubAgent`
block the plugin already renders for the parent (detected in
`claude_agent_acp_adapter.lua` — `kind == "SubAgent"` /
`rawInput.subagent_type`). Its `subagent_type` + `description` give a human
label.

## Why it currently mixes

The plugin never reads `_meta`. The full `update` object carries it intact
all the way through (`acp_client.lua __handle_session_update` →
`session_manager.lua _on_session_update` → `message_writer:write_message_chunk`,
and the adapter's `__build_tool_call_update`), but no code copies
`parentToolUseId` onto the rendered block or chunk. A repo-wide grep for
`parentToolUseId` returns zero hits.

## Provider scope

This is **claude-agent-acp only**. opencode runs subagents in an internal SDK
session not registered with the ACP bridge; their streaming and permission
events are dropped, and the subagent's output arrives bundled as the body of
the parent `task` tool's `completed` update (see `opencode-subagent-fix.md`).
There is nothing to demux for opencode — the subagent is already one opaque
block. Other providers are untested. The plumbing must degrade gracefully
(treat absent `parentToolUseId` as main-agent), which also covers opencode.

## Plumbing plan

Make the owning-agent id available on every rendered unit, without yet
deciding how to display it.

1. **Capture at the adapter.** In `ClaudeAgentACPAdapter`, read
   `update._meta and update._meta.claudeCode and
   update._meta.claudeCode.parentToolUseId` in `__handle_tool_call`,
   `__build_tool_call_update`, and copy it onto the built
   `ToolCallBlock`/`ToolCallBase` as a new field (e.g. `parent_tool_call_id`).
   Base-class default: nil.
2. **Capture for message chunks.** `agent_message_chunk` /
   `agent_thought_chunk` reach `MessageWriter:write_message_chunk(update)`
   with `_meta` intact — read it there (or normalise once at the
   `acp_client`/`session_manager` boundary so non-Claude providers stay
   uniform). Decide one read site to avoid scattering `_meta` access.
3. **Track the SubAgent registry.** When a `SubAgent` tool-call block is
   written, record `toolCallId → { subagent_type, description }` on the
   `MessageWriter` (per-instance, cleared at turn boundary — see CLAUDE.md
   "Cross-turn state hazards"). Children look up their label by
   `parent_tool_call_id`.

This is the whole shared substrate. Every UI option below consumes the same
`parent_tool_call_id` field + registry.

## Starting point: gutter agent number

Keep the marker out of the buffer text. The chat buffer is markdown (the
`agentic` treesitter clone), so any in-text device — indent, blockquote `>`,
a label line — becomes real bytes that interfere with yank, `safe_fence`,
folding, and the sign-column borders. The gutter is the one channel that is
already non-textual decoration.

Show a small per-turn ordinal: **blank for the main agent, `1` for the first
SubAgent block seen, `2` for the next**, and so on. Assigned in spawn order
on the SubAgent registry (§ plumbing step 3). Per-turn, not per-session, so
the numbers stay small and reset at the turn boundary — two turns each having
an "agent 1" is unambiguous because the turn divider separates them.

The spawning `SubAgent` tool-call block is main-agent content
(`parent_tool_call_id` nil), but its `toolCallId` is what the children
reference. Annotate that block with the same number as a spawn marker, so the
launch point and the launched agent's work share an identifier.

Colour derived from the number reinforces the distinction for parallel
agents, but the number carries it alone (robust past 2-3 agents and for
colour-blind users).

### Key open question: where the number goes

The sign column already holds tool-call border glyphs (`╭─ │ ╰─`), and
`sign_text` is capped at 2 cells — full. Prose chunks have a free gutter, but
a subagent's *tool-call* lines do not. This is the same number-column vs
border contention `feature-diff-line-numbers.md` hit; its answer is a
`statuscolumn` function that decides per row whether to render a border glyph,
a number, or both. The two features would share that implementation. Resolve
this before building — `line_hl_group` (per-agent line tint) is a fallback
that sidesteps the sign column but loses the explicit number.

## Out of scope (future UI ideas)

- **Nesting under the SubAgent block.** Fold child tool calls beneath the
  parent's block using the existing treesitter body folding. The user flagged
  this can nest too deep; it also needs a way to insert children at the
  parent's position rather than the buffer tail (streaming arrives in wire
  order, not grouped).
- **A subagent surface.** Move subagent output off the main chat. Do *not*
  tie window count to agent count — a window per subagent breaks under many
  parallel agents. Scalable variants, both leaning on the gutter number to
  separate agents *within* one surface:
  - **One shared subagent buffer** in the widget (fits the existing
    `ChatWidget:_create_buf_nrs` multi-buffer pattern — chat, input, todos,
    code, files, diagnostics already coexist). All subagent chunks demux into
    it by parent id, numbered; the main chat keeps only main-agent content.
  - **Focus-by-folding.** Subagent work stays inline (gutter-numbered) — no
    rewrite, no demux. Focusing agent N folds the other agents' work closed;
    the buffer stays canonical and it reverses by reopening the folds. Scales:
    more agents means more folded blocks, not more windows.

    A subagent's work is *not* contiguous (interleaved with the main agent and
    other subagents in wire order), so there is no single per-agent container.
    Fold per *block* instead and close every block owned by the other agents —
    each block is contiguous, so it folds; an agent just owns many small folds.

    Two mechanisms for the per-block fold:
    - **Treesitter container folds** (keeps the current design). The query
      provides foldability structurally; the writer closes only the containers
      it tagged as owned by agents ≠ N — exactly the existing
      `MessageWriter:_close_fold` pattern (deferred `:{line}foldclose`, which
      dodges the treesitter foldlevel-recompute race / E490). Preserves the
      built-in `vim.treesitter.foldexpr()` and its incremental updates.

      Tool-call blocks already carry this container: each is a `### Kind` ATX
      heading, i.e. a markdown `section`, so adding `(section) @fold` to
      `folds.scm` makes them foldable with no new markup, folding from the
      visible heading line. Two gaps remain. (1) Agent prose runs are bare
      paragraphs with no heading (thinking chunks are hidden, so only prose
      matters) — they need a container that folds yet renders transparently
      when *open* (a fence turns prose to code; a heading adds a visible line).
      (2) A markdown section runs heading → next heading, so a `### Kind`
      section greedily absorbs trailing bare prose; under parallel subagents
      that prose can belong to a *different* agent, so a section fold would
      hide the wrong owner's content. Precise folding needs an explicit block
      *end* boundary, not just the heading. The `---` divider is no help here
      — it is a `thematic_break` emitted only between body updates *inside* a
      tool call's fence (`message_writer.lua:1044`), not a section boundary.
    - **Window-local manual folds** in a focus window on the same buffer
      (`foldmethod=manual`), folding the non-focused agents' ranges from the
      gutter extmarks. Folds arbitrary ranges, so prose needs no container, and
      the main window's treesitter folds stay untouched. Cost: a side window,
      and no incremental fold updates in that view.

    An agent-aware foldexpr in the main window is the worst trade of the three
    — it forfeits the incremental updates the current design relies on.
- **Inline text separators.** A labelled divider (`── subagent 1:
  code-reviewer ──`) when the active agent changes between consecutive
  writes. Markdown-native but it adds buffer text, so it carries the yank and
  fence concerns the gutter number avoids.

## Caveats before building

- **Deep nesting.** A subagent can spawn its own subagent, so
  `parent_tool_use_id` forms a chain. The bridge carries only the
  *immediate* parent; a tree view would have to reconstruct ancestry from
  the chain of SubAgent blocks.
- **Interleaved ordering.** Parallel subagents' notifications arrive
  interleaved in wire order. Grouping by id is fine for marking/nesting; a
  per-window split must demux a single ordered stream.
- **Turn-boundary reset.** The SubAgent registry is per-turn mutable state —
  clear it at `append_separator` to avoid stale labels leaking across turns.
