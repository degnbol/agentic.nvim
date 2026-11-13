# Ideas

Loose ideas with no design yet. An item that grows past a few lines becomes
an `IDEA-` note in `notes/`.

## Chat rendering

- **Stop paragraph at the top**: if text from the Stop event can be told
  apart, follow output through exploration but stop with the first line of
  the Stop paragraph at the top of the screen.
- **Nested fence injection**: inner ` ```bash `/` ```python ` blocks inside a
  widened `safe_fence` lose injection; markdown treesitter injects only on
  exact-width nested fences. Low priority: the content is mostly read raw.
- **Edit preview folding**: long Edit previews not folded by default, but
  `zc` works.
- **Strike-through for completed todo items**: opt-out config option.
- **Read path highlight**: show a Read tool's path as
  `@string.special.path`. Is there a default markdown way to mark a path?
- **Skill block body**: drop the `Launching skill: <name>` body; the head
  already names the skill.
- **No-output execute body**: hide `(Bash completed with no output)`; the
  status footer already says the command completed. If the provider sends
  it, the wording varies, so weigh detection against the gain.
- **Failed edits and commands**: fold the diff of a failed edit (pattern not
  found, hook block) and the output of a failed command, above a configurable
  line threshold (0 folds always).
- **Folded Read block**: for a read of a few lines, a pre-folded block with
  the lines read. Not for whole-file reads (`<C-w>gf` goes there) or large
  ranges (session size).
- **Thought noise**: thought runs already collapse to one dimmed row.
  Dimming "noise" sentences needs a definition of noise first.
- **Subagent ID in its buffer**: `SubagentInfo.agent_id` arrives with the
  Agent tool's result, about 2 s after launch, usually after the heading.
  When it arrives, append a line with the ID; do not edit the heading.
- **opencode placeholders**: hide `pending...` before an edit, and the
  `bash` an execute block shows while the command streams (does opencode
  really use zsh?).
- **opencode `todowrite` call**: suppress it in chat; the todos panel shows
  the list (claude sends no such call).
- **Error display**: `error_display = "chat" | "notify" | "both"`, using
  `vim.notify`, `vim.diagnostic` or a float besides the inline
  `AgenticErrorHeading`/`AgenticErrorBody`.

## Input

- **Comment filtering**: render HTML comments (`<!-- … -->`) in the chat
  but strip them before sending; conceal the delimiters in both buffers.
- **Selective queue cancel**: a quickfix-like window over the queued
  regions, to drop some of them.
- **argument-hint**: show a skill's `argument-hint` (e.g. `[message]` for
  `/commit`) in the completion entry, maybe as a snippet.
- **Peek file**: on a permission prompt to run a script, `K` opens a hover
  with the script's contents.

## Sessions

- **Better titles**: derive the title from the first prompt: drop basic
  words ("can", "let's", "this"), lowercase, join with a delimiter.
- **Quick resume**: like the TUIs, print a resume command to stdout when
  nvim closes with a session active (opt-out).
- **Edited line ranges in the file activity panel**: the ranges are recorded
  (`FileActivity.Op.ranges`, persisted); show them per file (claude-owned vs
  other). A quickfix list would conflict with resume's quickfix use.
- **Persistent undo**: step through claude's edits of a file with `u`.
- **Session completion**: tell finished sessions from open ones (a user
  prompt last: open; a commit last: probably finished), or mark one with a
  close keymap. Resume lists open work, or browses the archive.
- **Cross-model / cross-provider resume** on purpose. Auto-switch on resume
  exists only because resume fails otherwise.
- **Model handover**: after a model switch the new model does not know it
  happened. Usually unimportant; maybe note it in a comment or the ACP docs.

## Permissions

- **Arithmetic on number-bound variables**: approve a name bound to a number
  literal in the same sequence (`i=3; echo $((i+1))`,
  `for i in {1..3}; do echo $((i*2)); done`) using the walker's `known`
  bindings.
- **Hex, base and exponent literals**: `$((0x1F))`, `$((16#ff))`, `$((1e3))`
  prompt because `reads_value` sees letters; they are numbers.
- **`$/cancel_request` and the permission float**: claude-agent-acp attaches
  a `cancellationSignal` to `session/request_permission`, so a cancelled
  turn should retract an open float. Never observed (0 of 1331 requests in
  7.9 M debug-log lines); confirm it arrives before building a handler.
- **Status label from permission state**: show "pending" while a permission
  request is open for a `toolCallId`, instead of the opencode adapter's
  `in_progress` → `pending` relabel (acp skill `references/opencode.md` §
  "Premature `in_progress`"). Needs PermissionManager → renderer plumbing or
  a per-tracker `awaiting_permission` flag.
- **`/grant` for `git rm`**: without `-f`, it is the same recoverable delete
  as `rm` of a tracked, clean file, but emits no delete effect. Maybe a
  `recoverable` category between `safe_write` and `ask`.

## Tooling

- **`just` instead of `make`?**
