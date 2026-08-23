# Plan: block-oriented dispatch — one command, one turn

Line numbers against `bbbfe7e`. Realises TODO "Command queuing" and the pass
deferred by [`feature-mid-turn-queue.md`](feature-mid-turn-queue.md) § Deferred.

Prerequisites, in order:

1. [`bug-command-interception-prefix-match.md`](bug-command-interception-prefix-match.md)
   — this plan classifies every line, so a prefix-matching `/new` becomes reachable
   from any line of a paste rather than only the first.
2. [`refactor-unify-message-queues.md`](refactor-unify-message-queues.md) — the
   sequencer here is that plan's queue with the drain yielding one block instead of
   all regions concatenated, and it needs that plan's gate predicate.

## Problem

`_handle_input_submit_inner` classifies the **whole** submitted text with
`is_slash_command = input_text:match("^/")` (`:1689`), and the local interception
patterns above it are anchored at the start of that same whole text. Every command
therefore needs its own turn, not just `/compact`, and mixing one with anything else
fails in three ways:

- **Silent truncation.** `^/new%s*` (`:1625`) has no end anchor, so
  `/new\nStart on X` matches (returning `"/new\n"`), starts a new session, and
  discards `Start on X` entirely. `/new` is the only command with this shape.
- **Argument capture.** `^/rename%s+(.+)$` (`:1638`) and `^/trust%s*(.*)$` (`:1651`)
  both use `.`, which matches newlines in Lua patterns, so `/trust repo\nAlso do X`
  passes `"repo\nAlso do X"` as the trust scope.
- **No interception at all.** `^/context%s*$` (`:1632`), `^/clear%s*$` (`:1625`) and
  `^/delete%s*$` (`:1576`) all require end-of-string, so `/context\nfoo` falls
  through the whole chain and reaches the provider as prose. Symmetrically, any
  command that is not the *first* line (`Continue\n/compact`) is classified as prose
  and never intercepted by either side.

All of the above is confirmed by running the patterns under `nvim -l`, not inferred.

The provider path adds a fourth failure: a command must arrive with no preceding
text at all, because opencode joins every text block to detect the leading `/` and
the Claude SDK reads its `inputString` from the last text block only (the rationale
already at `:1683-1688`).

## Split rule

A line begins a command block iff it matches the boundary the chat highlight already
uses (`syntax/AgenticChat.vim`): `^/`, then one or more of `[%w_-]`, then whitespace
or end-of-line. Requiring whitespace-or-EOL after the word is what excludes paths —
`/usr/bin/env` fails because `usr` is followed by `/`. Verified false for
`/usr/bin/env foo`, `/etc/hosts`, `  /compact` and `/`; true for `/compact`,
`/compact focus on X` and `/a-b_c`.

**A command block is exactly one line and never absorbs the following line.**
Arguments go on the same line as the command. `/compact\nFocus on the refactor` is
two blocks, matching TODO "Command queuing"'s stated intent for
`/compact\nContinue`. (`feature-mid-turn-queue.md` § Deferred called for
"block-oriented, not single-line" dispatch; that refers to *prose* blocks spanning
lines, which they still do.)

Runs of consecutive non-command lines form one prose block. **Prose-only text yields
exactly one block**, so the common case is byte-identical to today; that is the
property that makes this safe to land.

Drop any block with no `%S`, so `/context\n\n/compact` does not emit a blank prose
block. Trim each block individually.

### Trim order

`ChatWidget:submit` currently trims the whole prompt (`chat_widget.lua:423`, `:427`)
*before* `SessionManager` sees it, which would strip the indentation from a
first-line `  /compact` and defeat the escape hatch. The splitter therefore runs in
the widget on the **raw buffer lines**, and the whole-prompt trim is replaced by
per-block trimming. Then indenting by one space reliably sends a `/`-leading line as
prose, on any line including the first.

### Command-ness is line shape, not membership

Do **not** classify against the advertised command list, even though
`States.getSlashCommandsForBuffer` (`states.lua:72`) has it per input buffer:

1. `_cancel_session` calls `SlashCommands.setCommands(input_buf, {})` (`:2150`), so
   the list is empty during every reset and pre-ready window — a membership test
   would reclassify `/compact` as prose exactly when the user is most likely queueing
   it.
2. Line-start commands are intercepted whether or not the provider advertised them.
   Measured, see § Provider behaviour.

Membership is still used for two things: picking local versus provider handling at
dispatch time, and warning on an unrecognised command block (§ Provider behaviour).

### Where the splitter lives

`lua/agentic/utils/prompt_blocks.lua`, pure, with its own `.test.lua` — siblings
`shell_parse.lua` and `text_wrap.lua` set the pattern:

```
prompt_blocks.split(lines) -> { { kind = "command"|"prose", text = ..., sr = ..., er = ... } }
```

No buffer access. `ChatWidget` calls it (it owns the buffer and the line ranges) and
`SessionManager` keeps local-versus-provider dispatch and the gate. Note the "block"
name collision with `utils/extmark_block.lua` and the rendering vocabulary in the
module docstring.

The splitter runs on **buffer submits only**. `Agentic.send_prompt` and
`Config.keymaps.prompts` strings are dispatched whole, as today — they have no range
to tag, so a remainder block would need a second queue.

## Local command table

The six local commands are currently an if/elseif chain in
`_handle_input_submit_inner`. Three separate needs now want the same facts, so make
it one table — `lua/agentic/local_commands.lua`, or a `LOCAL_COMMANDS` local —
keyed by exact command word:

```
{ handler = fn, arg = "none"|"line"|"optional", async = boolean }
```

- **Exact-word keys** eliminate the prefix bug by construction.
- **`arg`** gives each command its argument grammar in one place instead of six
  ad-hoc patterns.
- **`async`** tells the sequencer whether to wait, which the gate cannot answer
  (below).
- The deferral gate in the sibling plan reads the same table for its exemption list
  instead of re-matching text.

## Sequencing

Flatten the submit into an ordered block list, dispatch the first, leave the rest
tagged as queued regions, and let each benign-clear edge dispatch the next.

**Buffer order carries the semantics**, including around session resets: blocks
above `/new` run in the old session, blocks below it run in the new one. No
timestamps, no separate in-flight store, no before/after bookkeeping. Two worked
cases:

- `/commit` then `/new` — clear after the turn finishes. `/commit` takes its turn;
  `/new` is gated by the sibling plan's `in_flight` reason and fires at that turn's
  normal Stop.
- `/new` then `Fresh session prompt.` — the prose block is gated `not_ready` after
  `_cancel_session` and drains at the session-created edge.

Both require that regions **survive** `_cancel_session`, which they do in shipped
code (nothing clears `NS_QUEUED`) and which the sibling plan preserves by not adding
a `cancel_queue()` call there.

### The gate does not answer everything

`/context`, `/rename` and `/trust <scope>` complete synchronously, so the gate is
clear and the next block dispatches immediately. Two commands return with the gate
clear while still pending:

- **`/delete`** defers to `vim.fn.confirm` inside `vim.schedule`, calling
  `do_delete()` from within the confirm callback (`:907-922`).
- **bare `/trust`** opens a picker (`:793-825`), possibly followed by `vim.ui.input`.

Dispatching the next block then races an open dialog. Hence `async` in the table:
an async command supplies a completion callback and the sequencer waits for it.

**`/delete` truncates the sequence.** A block after `/delete` has no coherent
destination. Warn, leave the remaining blocks as untagged draft, and stop — the one
place where blocking with a warning about dropped work beats designing a path.

### Region bookkeeping

Regions stay in the buffer between blocks; only the dispatched block's lines are
deleted, so pending blocks keep the visible-and-editable property the sibling plan
depends on. Two mechanics:

- The `_draining` flag (`chat_widget.lua:765`, `:777`) already stops `on_bytes` from
  untagging on drain-deletes.
- **Delete the extmark when its last block is consumed.** Partial deletes shift the
  mark correctly (start stays, `end_row` decrements), but consuming the final block
  collapses the mark to zero width at the deletion point, and the next drain then
  reads the *following untagged draft line* as a queued region and sends it. The
  current whole-region drain is immune because it deletes marks explicitly.

`drain_queued_regions` becomes `drain_next_block`, returning one block.

## Destructive commands in pasted content

The hazard is not turn count, it is that **a single pasted line executes a
session-destroying command**. Paste a note, changelog, or transcript containing
`/new`, `/clear` or `/delete` as example text and it runs. This repo's own
`TODO.md` and `doc/agentic.txt` contain such lines.

Rule: **confirm before executing `/new`, `/clear` or `/delete` when it is not the
first block of the submit.** A lone command, or a command opening the submit
(`/new\nFresh prompt`), is unambiguous intent and needs no confirm; the same word
appearing after other content is the signature of pasted data. The confirm names
the command and the block count.

This risk exists today for the first line; block dispatch extends it to every line,
which is why the prefix bug is a prerequisite rather than a follow-up.

## Once-per-submit state

| State | Today | Becomes |
| --- | --- | --- |
| `chat_history.title` (`:1677-1679`) | first submit's whole text | first **prose** block; unset if there is none, so the provider's auto-summary still applies |
| `_is_first_message` system info (`:1691-1699`) | first submit, skipped for commands | first prose block |
| Selected code (`:1721`), files (`:1775`), diagnostics (`:1791`) | attached and cleared on any submit | attached to and cleared by the first prose block; dropped when every block is a command, matching the display buffers that `submit` wipes at `chat_widget.lua:442-452` regardless |
| `_history_to_send` (`:1673-1676`) | first submit | first **prose** block, not merely the first block — `prepend_restored_messages` inserts text blocks *before* the user text, exactly the shape that shadows a command for opencode |
| `P.invoke_hook("on_prompt_submit")` (`:1833`) | once per submit | N per submit — a public hook contract change; document it |
| `chat_history:add_message` (`:1829`) | one user entry | N user entries, affecting replay |
| `clear_unread_badge`, `todo_list:close_if_all_completed()` (`:1618-1619`) | in `_inner`, per dispatch | move to the user-initiated submit path — in `_inner` they also run on automatic drains, so the `[done]` badge set at `:1907` is cleared by the drain that follows it and the user never sees it |

Without the title row, `/compact` as a first block names the session `/compact`.

Separately: `code_selection._selections` already survives a slash-command submit
(`:1706` is gated on `not is_slash_command`) while `ChatWidget:submit` wipes its
display buffer, so a later prose submit attaches selections the user can no longer
see. Pre-existing; worth its own fix rather than being designed into this path.

## Provider behaviour

Measured against the two providers installed here, by sending an unadvertised
line-start command:

| Provider | Advertised | Unknown `/word` |
| --- | --- | --- |
| claude-agent-acp | 72, all `[%w_-]+` | `end_turn`, zero usage, one chunk `Unknown command: …` |
| opencode | 32, all `[%w_-]+` | `end_turn` with **no session updates at all** — intercepted and silently dropped |

No advertised name on either provider escapes the shape rule, so shape-only
classification is safe for both. But opencode's silent drop means a stray `/word`
line that today reaches the model as part of the prose would, after the split,
vanish without a trace.

Mitigation: when a command block matches neither the local table nor a **non-empty**
advertised list, `write_error_action` before dispatching it. That is membership as a
*warning*, which leaves reason 1 against membership-based classification intact.

gemini, codex, cursor, auggie and vibe are not installed here and are unverified.
Their adapters contain no slash-command logic at all (only `rawInput.command`
display remaps), so nothing in-repo either supports or contradicts the interception
claim for them.

## Revised invariant

"One submit, one prompt" becomes "one submit, one block per turn, in order".
`feature-mid-turn-queue.md` § Constraints rejected making `:w` a "stateful
multi-press splitter"; that rejection still holds — this split is deterministic from
content within a single press and carries no cross-press state. `force` on the write
commands bypasses the gate, not the splitter.

## Tests

Splitter (`prompt_blocks.test.lua`, pure):

- Prose-only → one block. Guard this first.
- `/compact\nContinue` → command, prose.
- `Continue\n/compact` → prose, command.
- `/compact\nFocus on X` → two blocks (no argument absorption).
- `/usr/bin/env foo`, `/etc/hosts`, `//`, `/` → one prose block.
- `  /compact` on the first line → prose (guards the trim order).
- `/context\n\n/compact` → two command blocks, no blank prose block.

Sequencing:

- `/new\nStart on X` → new session, then `Start on X` sent to it (today `X` is
  discarded).
- `/commit\n/new` → `/commit` turn completes, then the session clears.
- `/rename a b\nthen do X` → title exactly `a b`, `then do X` sent as prose.
- `/trust repo\nAlso do X` → scope exactly `repo`.
- `/delete\nfoo` → confirm resolves, `foo` warned about and left as draft.
- Region whose last block is consumed → mark deleted, following draft line not sent.
- Abnormal Stop mid-sequence → remaining blocks stay tagged and visible.
- `foo\n/new` → confirm required; `/new\nfoo` → no confirm.

## Deferred

- **Fence awareness.** A `/word` line inside a fenced code block in the prompt
  splits. The existing highlight has the same false positive. A treesitter-markdown
  pass over the input buffer would fix both.
- **`\s` versus `%s`.** The vim highlight's `\s` is space/tab; Lua `%s` includes
  `\r` and `\n`. Harmless, but a pasted CRLF line classifies differently in
  highlight than in the splitter.
