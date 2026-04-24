# TODO

## Bugs

### Rendering

- **Markdown formatting leak**: md formatting leaks from chat blocks since we
  often write directly to chat without protection. E.g. `##` in a prompt
  injects a heading. Same happens with colours breaking in rare cases from the
  ACP's side. Fix: always put contents in a protected block, or detect special
  characters before pasting and protect more targeted.

- **Markdown table column alignment**: subtle misalignment when the table is
  wider than the chat buffer *and* there's conceal involved on a row, visible
  as we scroll. `conceallevel=2` hides e.g. ticks `` ``` ``, but when scrolled
  out of view they are not concealed anymore. A fix besides `conceallevel=1`
  might be extmark/virtual text tricks, or an autocommand updating visuals on
  scroll (probably overkill).

- **Fold marker not closed**: rare issue where a fold marker (`{{{`) is
  inserted but the closing marker (`}}}`) is missing, causing everything from
  that point to the end of the chat buffer to be folded into a single fold.

- **Syntax highlighting overflow**: rare issue where treesitter syntax
  highlighting from a previous block bleeds into the permission prompt,
  colouring parts of it incorrectly.

- **Fetch shows wrong title**: the format varies. Probably need to reproduce
  the issue unless we can do something more stable/clever in how that task is
  presented in chat.

### Streaming / performance

- **Large tool call outputs** (e.g. long file reads) can cause visible lag
  when writing to the chat buffer. Investigate.

### Interactions

- **Ctrl-c behaviour**: while claude is writing prose, ctrl-c works — it
  stops claude completely. While claude prompts for allow for editing a file,
  ctrl-c rejects, but then claude starts thinking and gives a response like
  "I was trying to do x and since I couldn't here's the instructions for you
  to do it". Intended behaviour: ctrl-c stops and blocks claude fully in all
  scenarios (but not persistent stopping based on task etc.). The numbered
  options are for other reject behaviours.

- **Message queuing during resume**: queuing a message doesn't work while
  waiting for a slow resume.

- **Command queuing**: `/compact\nContinue` should fire `/compact` correctly
  (it doesn't), and then fire `Continue` when compaction is complete.
  Essentially work as if the user prompts `/compact` and then a moment later
  the rest.

- **Resume after compacting**: resume right after compacting doesn't show
  history from before compacting, just the compacting summary. Both would be
  ideal.

### OpenCode adapter

Several issues cluster here; suggests work done for claude wasn't generalised
to all ACPs.

- **`todowrite` shown in chat**: opencode (not claude) shows the todo
  operation in chat as raw JSON:
  ```json
  [
    {
      "priority": "high",
      "content": "Rename config keys: stash_send_* → send_*, stash_register → send_register",
      "status": "in_progress"
    }
  ]
  ```
  Should be hidden — the todo window already shows this. The JSON does reveal
  `priority`, which could be added to the todo window. Opencode also writes
  the whole todo list on every change; we could diff and have chat mention
  only the changed item so the history shows which items were crossed out
  when. Robust corner cases: what if the edit adds an item, or undoes a
  crossed-out item.

- **Pending vs `in_progress`**: while waiting for approval opencode shows
  the suggested edit with `in_progress` where claude shows `pending`. Should
  be pending — the command is not in progress.

- **Failed edit reported as completed**: an Edit that fails with `Not
  found: function …` doesn't have the expected error colour and shows
  `completed` status:
  ```
  ### Edit
  `lua/agentic/ui/chat_widget.lua`
  ```lua
  Not found: function ChatWidget:_stash_send_visual() ...
  ```
   ✔ completed
  ```

- **Search command doesn't show the term**:
  ```
  ### Search
  ```bash
  grep
  ```
  ```
  No search pattern visible in the argument.

- **Default mode leaks to incline**: opencode's default mode is `build`.
  It should be hidden from the header state pushed to incline and be implied.

- **Ctrl-c adds an error block**: interrupting shows this in chat:
  ```markdown
  ### Error

  stopReason: end_turn
  usage: input=0 output=0 total=0
  ```
  Shouldn't appear after a manual interrupt.

- **Compound command splitting not applied**: opencode doesn't get the
  benefit of our compound-command matching (or its settings don't reach the
  ACP side). E.g.:
  ```bash
  cd /tmp/opencode && \
  grep -r "rawInput" --include="*.ts" --include="*.tsx" |
  grep -v test |
  grep -v node_modules |
  head -20
  ```
  Doesn't auto-allow.

- **Parallel tasks not showing in chat**: previously fixed for claude, now
  reappearing for opencode. Audit claude-specific fixes for ones that should
  have been general across adapters.


## Feature ideas

### TUI parity — missing slash commands

Full comparison is in `doc/agentic.txt §12.4`. Ordered by value-to-effort.

**Worth doing**

- **Session dashboard** — a dedicated window (*not* `:checkhealth`,
  which is reserved for setup validation) showing live session runtime
  state: model, provider, mode, context %, prompt count, accumulated
  input/output token usage, proximity to limits. Data is already in
  `usage_update` notifications plus local session state. Subsumes the
  TUI's `/status`, `/cost`, `/stats`, `/usage` — none of which are
  forwarded over ACP.

**Already works — just undocumented**

Verified via a live `available_commands_update` probe of claude-agent-acp:
these commands forward through and the plugin does not intercept them,
so typing them in the input buffer runs the TUI flow via the LLM.

- **`/init`** — generates a project `CLAUDE.md`.
- **`/review`** — pull-request review.
- **`/security-review`** — security review of pending changes.
- **`/compact`**, **`/extra-usage`**, **`/insights`**,
  **`/team-onboarding`**, **`/heapdump`** — all forwarded.

Action: mention these in README/docs so users know they work.

**Maybe**

- **PDF attachments**: the plugin supports image paste (see `image_paste`
  config). PDF support depends on provider capability advertised through
  ACP.

- **Background jobs**: would require surfacing background state in the
  UI. Revisit if a concrete use case emerges.

**Blocked upstream or out of scope**

- **`/effort`**: claude-agent-acp 0.29.0 does not emit the `thought_level`
  ConfigOption. Dispatch code is ready, unreachable until the bridge
  changes. See `lua/agentic/acp/AGENTS.md §
  "thought_level ConfigOption not emitted (claude-agent-acp)"`.

- **`/permissions`**: no ACP surface for reading or writing persistent
  rules. Users edit `settings.json` directly.

- **`/cost`, `/login`, `/logout`**: explicitly filtered out by the bridge
  (`UNSUPPORTED_COMMANDS` in `getAvailableSlashCommands`).

- **`/status`, `/stats`, `/usage`, `/doctor`, `/mcp`, `/agents`,
  `/skills`, `/config`, `/bug`, `/memory`, `/hooks`, `/bashes`,
  `/pr-comments`, `/vim`, `/ide`**: not advertised by the bridge at all
  (verified absent from `available_commands_update`). These rely on TUI
  interactive I/O that doesn't map to the ACP chat stream. A **Session
  dashboard** (above) would cover the runtime-state subset.

- **`/diff`, `/rewind`, `/branch`, `/teleport`**: provider-level features
  or conversation-state primitives not exposed through ACP.

### Rendering

- **Shebang/modeline detection for Edit tool previews**: scripts without a
  file extension but with a shebang (or vim modeline) should infer filetype
  for code injection preview in chat. Not a common case.

- **Edit tool preview folding**: long Edit tool previews need a folding
  mechanism — not folded by default but `zc` works.

- **Strike-through for completed todo items**: opt-out config option.

### Session / workflow

- **Session dashboard**: see TUI parity above — runtime state (model,
  provider, mode, context %, token usage, limit proximity) in one window.

- **Edited files window**: the original agentic.nvim had a window listing
  edited files; removed to save screen space. Could reinstate with `:q`
  closing and a `<localLeader>` keymap to reopen. Improved version: use
  the line-range edit tracking (claude-owned vs other) we already have per
  file. A quickfix menu could work (multiple entries per file for multiple
  edits) but conflicts with resume's quickfix use.

- **Persistent undo integration**: opening a file in neovim allows for undo
  via the persistent undo file. Optionally integrate so a user can step
  through the edit history from claude with `u`.

- **Session completion heuristic**: some sessions are more clearly completed
  than others. If the user prompt is last, the session is not completed.
  If it ends in a commit etc., it probably is. Detection is heuristic;
  alternatively a specific close keymap (instead of `:qa!`) could mark a
  session for archive. For resume: list only unfinished work, or browse
  the archive specifically.

- **Cross-model / cross-provider resume**: auto-switch on resume is
  implemented because resume fails otherwise. Is it possible to resume a
  session with a different model, and even a different provider, on
  purpose?

### Permissions

- **`/trust` completion and typo tolerance**: `/trust heree` goes through.
  Completion for subcommands (`repo`, `here`, `off`) would prevent typos.

- **`/trust` glob coverage**: verify the `/trust` system works with glob
  patterns using `~/`, relative paths, and absolute folders.

### Error display

- Errors are currently shown inline in the chat buffer with red highlighting
  (`AgenticErrorHeading`/`AgenticErrorBody`). A future option could use
  neovim's native error display (`vim.notify`, `vim.diagnostic`, or a
  floating window) instead of or in addition. Config toggle:
  `error_display = "chat" | "notify" | "both"`.


## Investigations

- **Claude internals reference**: use the claude leak shared by Matteo on
  gdrive so we do less guessing about claude internals for dev of this
  plugin.

- **Manual code review**: this repo is heavily vibe-coded.


## Housekeeping

- **Clean environment testing**: for proper sharing of this plugin we need
  to see it in action with `nvim --clean` plus plugin.

- **README demos**: gifs in the readme or elsewhere demoing the differences
  between this plugin and the stock TUI.
