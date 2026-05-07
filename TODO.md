# TODO

Start doing some version tracking so we can separate bug fixes from feature releases.

## Bugs

### Rendering

- After auto-continue after reaching a limit the "Continue" is sent correctly to chat but then nothing appears in chat from the model.
  After closing the program (nvim), restarting and resuming the session a response is visible immidiately in chat, i.e. the continue was successful but the chat didn't show the response from the model.
  This is a long standing and difficult bug.

- Doesn't always show the search tool command correctly, e.g. bad display of nested quotes:

```markdown
### Search
```bash
rg -n ""todowrite"|@alias|@class.*ToolCall" /Users/cmadsen/dotfiles/config/nvim/modules/agentic.nvim/lua/agentic/ui/message_writer.lua
```
```console
26:--- @class agentic.ui.MessageWriter.ToolCallDiff
31:--- @class agentic.ui.MessageWriter.ToolCallBase
42:--- @class agentic.ui.MessageWriter.ToolCallBlock : agentic.ui.MessageWriter.ToolCallBase
694:        or tool_call_block.kind == "todowrite"
782:    if tracker.kind == "switch_mode" or tracker.kind == "todowrite" then
```
 ✔ completed
```

- AgenticClean__punctuation_special_markdown is showing up in seemingly random places in markdown tables.
  My guess is it's placed correctly for the `|` delimiters before we do my custom auto-align of tables which then leaves it highlighting random letters.
  The fix might simply be to remove the code adding AgenticClean__punctuation_special_markdown, what is it used for? We have proper hl of `|` in md tables already.

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

- Insert mode in AgenticInput then mouse click in AgenticChat leaves cursor in input mode in chat which is never valid.
  I think we should switch to normal mode automatically when changing window focus to AgenticChat (regardless of the way focus was changed).

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

- **Write is empty**: it seems the chat block is empty on a new write and I 
suspect it's because the diff is null for the "before" state and the code can't 
find a match since there's no file yet. We don't have this problem for claude.

- **Pending vs `in_progress`**: while waiting for approval opencode shows
  the suggested edit with `in_progress` where claude shows `pending`. Should
  be pending — the command is not in progress.

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

- Asked for permission from Read tool and basic `ls`. We should consider 
increasing the auto-allow system here to allow all read tools, and either reuse 
the settings.json list from claude or have a local copy of all the basic 
commands like `ls` that are read-only. The plugin opt-out setting should be 
whether to allow all read-only commands and then have a config list of 
read-only commands that we can populate from my claude settings.json.

- **Write tool shows minimal header**: opencode Write tool shows just
  `### Edit` with the file path, not the file contents. Should show the
  written content (folded) like other providers.

- **Fetch tool output not folded**: Fetch/WebFetch output dumps full text
  into chat without folding, causing clutter.

#### Fixed

- **`todowrite` shown in chat**: ~~opencode (not claude) shows the todo~~
  ~~operation in chat as raw JSON~~. Fixed by mapping `title == "todowrite"`
  to `kind = "todowrite"` and stripping the body in `MessageWriter`.

- **Edit diff "Not found"**: ~~diff matching failed when opencode sends diff
  data after the edit has been applied.~~ Fixed by rendering the diff
  directly from `old`/`new` arrays when file matching fails, instead of
  showing "Not found" placeholder.


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

**Maybe**

- **PDF attachments**: the plugin supports image paste (see `image_paste`
  config). PDF support depends on provider capability advertised through
  ACP.

- **Background jobs**: see "Background processes window" under
  Session/workflow.

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

- If we can distinguish text coming into chat from Stop event then maybe we 
could stop scrolling when the model is writing a stop even block of text? Could 
be useful to auto-scroll as the model goes through reading/exploration/etc but 
have the scroll stop with the first line of a stop paragraph at the top of 
screen so we can read it.

- **Shebang/modeline detection for Edit tool previews**: scripts without a
  file extension but with a shebang (or vim modeline) should infer filetype
  for code injection preview in chat. Not a common case.

- **Edit tool preview folding**: long Edit tool previews need a folding
  mechanism — not folded by default but `zc` works.

- **Strike-through for completed todo items**: opt-out config option.

- Read tool should show the filepath captured as @string.special.path. Is there any default way in markdown for formatting filepath?

### Session / workflow

- **Session dashboard**: see TUI parity above — runtime state (model,
  provider, mode, context %, token usage, limit proximity) in one window.

- **Per-message token cost & session profiler**: surface how expensive
  each prompt/turn is and which messages dominate the running context.
  Two views: (1) inline indication per user prompt or assistant turn
  (delta input/output tokens, maybe a sparkline in the gutter); (2) a
  profiler view ranking top offenders for the session — large tool
  outputs, long file reads, verbose build/test logs. Goal: spot when a
  single `cargo build` blows the budget so the user can adjust workflow
  (output filtering, smaller scope, manual context pruning) before
  hitting auto-compact. Data is in `usage_update` deltas; attribution
  needs to associate the delta with the preceding tool call or message.
  Worth piloting against the Bevy project where `cargo` output is
  suspected to be the main context eater. (Related: [rtk-ai/rtk](https://github.com/rtk-ai/rtk)
  is an external CLI proxy that compresses verbose dev-command output —
  if a profiler confirms `cargo`/`pytest` are the offenders, an in-plugin
  filter or rtk-style wrapper could be a follow-up.)

- **Background processes window**: a panel listing currently-running
  background tool calls (Bash with `run_in_background: true`,
  auto-backgrounded long bashes, web fetches still in flight, etc.)
  with status, elapsed time, command/argument, and a kill keymap.
  Provider-agnostic — track by watching the ACP `tool_call` /
  `tool_call_update` stream rather than asking the provider, since the
  SDK task registry is internal and not exposed via ACP. Motivation:
  Claude legitimately forgets about running `local_bash` shells
  (post-compact re-injection in claude-agent-acp filters
  `local_agent` only — see claude skill `references/internals.md` §
  "Background tasks"), and a `nvim --headless` orphaned by a hung
  command leaves the harness showing "generating" indefinitely with
  no surface telling the user *what* is still running. The window
  also lets the user terminate stuck procs without dropping to a
  shell.

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

- Consider benefits of supporting https://pi.dev/ and using it instead of opencode for the liteLLM models.

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

### LSP

If claude is refactoring, e.g. renaming all occurances of a variable it essentially does a search/replace plus looking at context around word to understand.
Why not rename like I would in the editor using the LSP?
The LSP is often a program that can be run from the shell, it's almost a CLI, but not quite.
I think we should be able to write some thin wrapper around LSPs to call them like CLIs (like `lsp rename <old name, row and col?> <new name> <filename>`) that then writes a bit of json(?) boilerplate and sends it to based-pyright if `<filename>` is python etc.

### Quick resume

When closing opencode or claude TUI there's a message left in the shell about the session id with a command hint to resume the session.
We could consider an opt-out feature where something like this is written to stdout on nvim close with a session active.

### argument-hint

Skills can have argument-hint field, currently e.g. `[message]` for /commit.
Completion should show this, e.g. the menu entry and might need snippet.

## Investigations

- **Manual code review**: this repo is heavily vibe-coded.


## Housekeeping

- **README demos**: images or gifs in the readme or elsewhere demoing the differences
  between this plugin and the stock TUI.

- Should we switch to `just` instead of `make`?