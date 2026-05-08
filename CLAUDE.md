# agentic.nvim

Neovim plugin providing AI chat interface via ACP (Agent Client Protocol).
Fork of [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim).

- Neovim v0.11.0+, LuaJIT 2.1 (Lua 5.1)
- `goto`/`::label::` forbidden (Selene parser limitation)
- Never use `vim.notify` directly — use `Logger.notify`
- Logger has only `debug()`, `debug_to_file()`, and `notify()` — no warn/error/info

## Debugging at runtime

`Logger.debug()` (prints to `:messages`) is gated by `Config.debug`.
`Logger.debug_to_file()` (appends to `~/.cache/nvim/agentic_debug.log`) is
gated by `Config.log`. Both default to `false` and are independent — enable
`log` alone for file logging without screen distraction. For temporary
diagnostics that must fire unconditionally, use `io.open` directly:

```lua
do
    local f = io.open("/tmp/agentic_diag.log", "a")
    if f then
        f:write(string.format("%s %s\n", os.date("%H:%M:%S"), msg))
        f:close()
    end
end
```

Remove before committing. Never leave `io.open` debug logging in production code.

## Multi-tabpage architecture

One session instance per tabpage. `SessionRegistry` maps `tab_page_id -> SessionManager`.
One shared ACP provider subprocess, one ACP session ID per tabpage, full UI isolation.

- No module-level shared state for per-tabpage runtime data
- Namespaces are global, extmarks are buffer-scoped — module-level `nvim_create_namespace` is fine
- Highlight groups defined once globally in `lua/agentic/theme.lua`
- Keymaps and autocommands must be buffer-local
- See scoped storage: `vim.b`/`vim.bo`, `vim.w`/`vim.wo`, `vim.t`

## Validation

Run after ANY Lua file changes:

```bash
make validate
```

Outputs 4-5 lines (exit codes + log paths). Never redirect its output.
On failure, read the log file with `tail` or `rg`, never the Read tool.

Log paths: `.local/agentic_{luals,selene,test}_output.log`

## Key files

- `lua/agentic/config_default.lua` — all user-configurable options
- `lua/agentic/theme.lua` — highlight groups (update README.md when adding new ones)
- `lua/agentic/acp/adapters/` — provider-specific adapters

## Session cache location

Persisted chat sessions: `~/.cache/nvim/agentic/sessions/<normalized-cwd>_<hash>/<session-id>.json`.
Grep by `"title":"<name>"` to find a session renamed via `/rename` across all projects.

## Tool call block rendering

Border decorations (╭─ │ ╰─) use `sign_text` extmarks in the sign column, not
inline virtual text. This is more stable during buffer edits — signs survive
line content replacement without delete/recreate cycles.

Status text (" ✔ completed ", " ✖ failed ", etc.) is written directly into the
footer buffer line as real text using `nvim_buf_set_text` (not `set_lines` —
that shifts extmarks on the replaced line), then highlighted with an extmark
(`NS_STATUS` namespace). This avoids the entire class of overlay-to-static-text
timing bugs. Status changes just replace the footer line content in place. No
deferred freezing, no cleanup passes.

**All programmatic highlighting uses extmarks**, not vim syntax rules. Extmarks
work regardless of `vim.bo.syntax` state — whether treesitter has disabled it
(default after `vim.treesitter.start()`) or a user/plugin re-enables it with
`vim.bo.syntax = 'ON'`. This makes the highlighting robust against user
configuration. Highlight group definitions are set in `theme.lua` via
`nvim_set_hl`, which works independently of vim syntax state. The
`AgenticDimmedBlock` group (dims ` ```markdown ` fences only) is defined in
`ftplugin/AgenticChat.lua` via a targeted treesitter query override.

Content comparison in `update_tool_call_block` excludes the footer line (which
has status text in the buffer but `""` in `_prepare_block_lines` output), so
status-only updates skip the expensive content replacement path.

If a range extmark collapses (start >= end, indicating corruption),
`update_tool_call_block` bails out and removes the block from tracking rather
than proceeding with stale positions.

## Search tool call rendering

Search/grep results use two separate code fences in `_prepare_block_lines`:

1. **Command** — ` ```bash ` fence around the search command (argument)
2. **Results body** — ` ```console ` fence around result lines

The body always gets a `console` fence (prevents markdown parsing of `--`,
`*`, etc.). Fold markers (`{{{`/`}}}`) go inside the console fence when line
count exceeds `search_max_lines` (default 8). Never double-wrap — the body
from the adapter is raw text lines (no fences), so the console fence is the
only one.

Match highlighting: ANSI codes from the provider (preferred, rarely available)
or regex fallback that extracts the pattern from the command string and
re-matches against body lines. Highlights use `AgenticSearchMatch` extmark
with priority 200.

Grep-format line highlighting: lines matching `path:linenum:` get per-component
extmark highlights — `AgenticGrepPath` (file path), `AgenticGrepLineNr` (line
number), `AgenticGrepSeparator` (colons/dashes). These fire for all search
blocks and for execute blocks where the command is a grep-family tool (`grep`,
`rg`, `ag`, `ack`, `git grep`, `ugrep`). Grep-line highlights coexist with
search-term highlights in the same `search_matches` array via the optional
`hl_group` field on `SearchMatch`.

## Tool call body folding

Long tool call output uses vim-native folds (`foldmethod=marker`) instead of
truncation. Fold markers (`{{{`/`}}}`) are embedded in the buffer content and
concealed via extmarks (treesitter is active, so vim syntax `conceal` doesn't
work). The chat buffer sets `foldlevel=0` so folds start closed.

Folding thresholds are configured per tool kind:
- `search_max_lines` — search/grep tool output
- `execute_max_lines` — shell command stdout
- `fetch`/`WebSearch` — always folded (informational, rarely needed by users)

`lua/agentic/ui/foldtext.lua` provides a custom `foldtext` showing line count.
Users toggle with standard fold commands (`zo`/`zc`/`za`).

## Session lifecycle races and the epoch guard

Two race conditions can overwrite `self.session_id` during session restore:

1. **Constructor on-ready race:** `AgentInstance.get_instance()` calls `on_ready`
   synchronously when the instance already exists. The constructor wraps the
   inner logic in `vim.schedule`. When `load_acp_session()` is called immediately
   after construction (from the session picker), the deferred callback fires
   after `_do_load_acp_session` — without the `_restoring` guard it would call
   `new_session()`, replacing the loaded session.

2. **Stale create_session response race:** The constructor's `new_session()`
   sends `session/new` (async RPC). The user then browses the session picker for
   seconds/minutes. `_do_load_acp_session` sets `_restoring = true` and sends
   `session/load`. The load completes and clears `_restoring = false`. The
   `session/new` response then arrives — `_restoring` is false, so the callback
   overwrites `session_id` with the stale new-session ID.

3. **Cross-provider restore, three linked hazards.** Picking a saved session
   whose provider differs from `Config.provider` requires destroying the
   current tab's SessionManager, flipping `Config.provider`, and letting
   `get_session_for_tab_page` spawn a replacement bound to the new agent.
   This sequence surfaces three races that don't affect same-provider restore:

   a. **Capability check during agent init.** `agent_supports_load` is called
      synchronously inside the picker callback. A freshly-spawned agent has
      `agent_capabilities == nil` (initialize RPC still in flight). Treating
      nil as "no support" silently drops into the non-ACP fallback path.
      Treat nil as "support-assumed" — `load_acp_session` already queues via
      `_pending_load_session_id` until on_ready fires.

   b. **Tab-id-based deferred destroy.** `ChatWidget.on_hide` schedules
      `SessionRegistry.destroy_session(tab_page_id)` via `vim.schedule` when
      `chat_history.messages` is empty. If a replacement session has been
      installed on the same tab before that callback runs, a naive
      destroy-by-tab-id would wipe the replacement. The scheduled closure
      captures the session instance (`this`) and only destroys when
      `SessionRegistry.sessions[this.tab_page_id] == this` — so the replacement
      survives. `SessionManager:destroy` also disarms `on_hide` before
      `widget:destroy()` as belt-and-braces.

   c. **Stale `session/new` callback from the outgoing provider.** The
      original SessionManager's `create_session` RPC may still be in flight
      when it's destroyed. The callback closure holds a reference to the
      destroyed `self`. When the response arrives, the callback runs
      `_handle_new_config_options` → `_update_chat_header` →
      `WindowDecoration.set_headers_state(self.widget.tab_page_id, ...)`,
      stomping the replacement session's headers with the outgoing
      provider's model. Bail out at the top of the create_session callback
      when `self._destroyed` is true. Also clear
      `vim.t[tab_page_id].agentic_headers` in `SessionManager:destroy` so
      the replacement starts from a clean slate — per-tab header state
      outlives the session that wrote it.

**Guards:**

- `_restoring` flag — prevents the deferred on-ready callback (race 1) and
  catches in-flight create callbacks while load is active.
- `_session_epoch` counter — monotonically incremented by both `new_session()`
  and `_do_load_acp_session`. The `create_session` callback captures the epoch
  at call time and rejects the response if the epoch has advanced (race 2).
  This catches stale responses even after `_restoring` is cleared.
- `_destroyed` flag — set in `SessionManager:destroy`. Checked at the top of
  the `create_session` callback for race 3c (epoch/restoring can't catch it
  because they track the *replacement's* state, not the destroyed sender's).

**Rules:**

- Any code path that initiates a session transition must increment
  `_session_epoch`. Any async callback that sets `self.session_id` must check
  that its captured epoch matches `self._session_epoch`.
- Any async callback on a SessionManager that writes to tab-scoped state
  (`vim.t[tab].agentic_headers`, `SessionRegistry.sessions[tab]`, etc.) must
  check `self._destroyed` — the instance may have been replaced on the same
  tab while the RPC was in flight.
- `_do_load_acp_session` must feed `result.configOptions` through
  `_handle_new_config_options` on success (mirrors the `new_session` path) —
  otherwise the header stays on the previous provider's model after a
  cross-provider restore.

## Cross-turn state hazards in MessageWriter

MessageWriter carries mutable flags that persist across turns. Any flag set
during a turn MUST be cleared at the turn boundary (`append_separator`) or on
the next tool call — otherwise it silently corrupts all subsequent turns.

Known hazards (and their reset points):

| Flag | Set when | Reset in |
|------|----------|----------|
| `_suppressing_rejection` | Permission rejected | `append_separator`, `write_tool_call_block` |
| `_rejection_buffer` | With above | With above |
| `_last_wrote_tool_call` | Tool call block written | Next `write_message_chunk` |
| `_chunk_start_line` | First streamed chunk | `_reflow_chunks(flush_all=true)` via `append_separator` |

When adding new per-turn state to MessageWriter, always ensure it resets at the
turn boundary. The `send_prompt` response callback (which calls
`append_separator`) runs inside `vim.schedule` from `_handle_message` — do not
add another `vim.schedule` wrapper or the cleanup races with the next turn.

## Header state and external UI plugins

Runtime session data (mode, context %, session name) flows to external UI
plugins (incline.nvim, tabline plugins) through the **headers state pipeline**,
not through buffer names.

**Pipeline:** `SessionManager` → `ChatWidget:render_header()` /
`ChatWidget:set_chat_title()` → `WindowDecoration.set_headers_state()` →
`vim.t[tab].agentic_headers` → `AgenticHeadersChanged` User autocmd → external
plugin refresh.

`vim.t.agentic_headers` is the single source of truth for header display data.
Each panel has a `HeaderParts` table with `title`, `context`, and optional extra
fields (e.g. `session_name`). External plugins read these fields in their render
functions and refresh via the `AgenticHeadersChanged` autocmd.

**Do not rely on buffer names for UI display.** `nvim_buf_set_name` sets neovim's
internal buffer path (visible in `:ls`) but does not fire events that floating
window plugins respond to. The buffer name is a secondary artifact — the headers
state is the primary mechanism.

## Auto-scroll and attention notifications

User-facing behaviour is in `doc/agentic.txt § Auto-scroll`. This section
documents the control flow for future maintenance.

**Master switches:**
- `Config.auto_scroll.enabled` — runtime-toggleable via
  `keymaps.widget.toggle_auto_scroll` (`<localLeader>a`). When false,
  `BufHelpers.scroll_down_only` returns early. Mutated at runtime, not
  persisted.
- `Config.auto_scroll.pause_on_prose` — when false, no pin (auto-scroll
  always tracks the trailing edge during streaming).

**Per-instance state on `MessageWriter`:**
| Field | Purpose |
|---|---|
| `_prose_anchor_line` | 0-indexed buffer line of the first non-blank line of the current prose run. Set on the first prose chunk of a run while not paused. Cleared at run boundaries (`write_tool_call_block`, `append_separator`, `write_error_message`, `reset_turn_state`) and on user-scroll-away. |
| `_auto_scroll_paused` | True after the user scrolled away from the bottom; gates pin-setting and `_check_auto_scroll`. Survives turn boundaries — only `on_user_scroll` flips it back. |
| `_suppress_pin_release` | True only while the plugin is synchronously executing its own scroll commands or buffer writes. The `WinScrolled` autocmd checks this before treating an event as user-initiated. |
| `_should_auto_scroll`, `_scroll_scheduled` | Per-call coalescing. Captured by `_auto_scroll`, consumed by the deferred `vim.schedule` callback. |

**Flow per streaming chunk** (`MessageWriter:write_message_chunk`):
1. Sync: `_auto_scroll(bufnr)` records `_should_auto_scroll` from
   `_check_auto_scroll` (gated on `_auto_scroll_paused`, with a pin
   override) and queues a `vim.schedule` callback. `_scroll_scheduled`
   coalesces.
2. Sync: `_with_modifiable_and_notify_change` writes the chunk — the
   suppress flag is set for this whole block so any `WinScrolled` that
   fires from buffer-grow / topline auto-correct is filtered out.
3. Sync (still inside the write): pin the start of the prose run if
   `_prose_anchor_line` is nil **and** `_auto_scroll_paused` is false.
4. Async: the scheduled callback flips suppress on, calls
   `BufHelpers.scroll_down_only` with `max_topline = anchor + 1` (when
   the pin is set), flips suppress off.

**`scroll_down_only`** (`utils/buf_helpers.lua`) is the single point that
does the scroll. It runs `normal! G0zb`, then if `max_topline` is set and
the natural scroll would overflow it, parks the cursor inside the
anchored viewport and `winrestview`s the topline back. Cursor-park
position accounts for `scrolloff` so vim does not shift the topline
back to honour it.

**At-bottom rule** (`MessageWriter:_is_at_bottom`):
- Chat window is the current window → `cursor_line >= line_count`. The
  user can move the cursor; if they kept it off the last line, they're
  not at the bottom regardless of viewport state.
- Chat window is not focused → `getwininfo().botline >= line_count`. The
  user can't move the chat cursor (focus elsewhere) but can still scroll
  the chat with the OS pointer; viewport-reaches-end is the only signal.

**`on_user_scroll`** (`MessageWriter:on_user_scroll`) is bound to
`WinScrolled` on the chat buffer in `MessageWriter:new`. It returns
immediately if `_suppress_pin_release` is set, then calls `_is_at_bottom`
to either clear `_auto_scroll_paused` (resume) or set it and release the
pin (pause). The chat-widget autocmd that clears the unread badge uses
the same dual rule inline (see `chat_widget.lua` `_setup_autocommands`).

Attention notifications (`_notify_attention(badge)`) fire on two events:
- **Response complete** — badge `"[done]"`
- **Permission request** — badge `"[?]"`

Behaviour depends on focus state:
- **Chat window unfocused** → rings bell
- **Scrolled up from bottom** → sets badge in buffer name (visible in `:ls`/tabline)

Badge clears when:
- User reaches the bottom of the chat by the at-bottom rule above
  (`WinScrolled` autocmd on the chat buffer in `chat_widget.lua`)
- User submits next prompt (`clear_unread_badge()`)

## Input buffer completion

Completion for `/` slash commands and `@` file references uses an in-process LSP
server (`lua/agentic/completion/lsp_server.lua`), not custom completefunc/omnifunc.
The LSP declares `/` and `@` as trigger characters so any LSP-aware completion
framework (blink.cmp, nvim-cmp, built-in) picks them up automatically. No
plugin-specific keymaps needed.

- `vim.lsp.start()` with same `name` + `root_dir` reuses one client across
  buffers (handles multi-tabpage)
- Handler uses `nvim_get_current_buf()` not URI (all input buffers share name
  `agentic://prompt`)
- `States.getSlashCommandsForBuffer(bufnr)` reads from specific buffer (not
  `vim.b[0]` which is unreliable in LSP handler context)
- `@` file completion lists one directory level at a time via `vim.uv.fs_scandir`,
  not a pre-cached file list. Picking a directory inserts `@dir/` which re-triggers
  completion via the `/` trigger character. This is a deliberate reimplementation
  (~30 lines) to stay framework-agnostic (works with blink.cmp, nvim-cmp, or
  built-in completion via standard LSP) rather than delegating to a specific
  framework's path source

### Syntax highlighting for `/` and `@`

Slash commands (`/command`) and `@` mentions (`@path`) get vim syntax highlighting
in both input and chat buffers via `syntax/AgenticInput.vim` and
`syntax/AgenticChat.vim`, sourced by a deferred `vim.bo.syntax = "ON"` in
their respective ftplugins (needed because `vim.treesitter.start()` clears syntax
after the ftplugin runs).

The prefix character (`/`, `@`) and the body text are separate syntax groups using
`nextgroup` + `contained` — no character belongs to two groups, preventing
unintended style bleed (e.g. underline from the path group leaking onto `@`).
Prefix groups (`AgenticSlashCommandPrefix`, `AgenticMentionPrefix`) link to
`@punctuation.special`; body groups keep their existing links (`@function.call`,
`@string.special.path`).

**Slash commands are highlighted only at line start** (`^/`), not mid-line.
Line-start `/command` is intercepted by the CLI before the LLM sees it —
whether it's a built-in (`/model`, `/compact`), a skill (`/bevy`, `/commit`),
or an unknown command. The LLM never receives raw `/something` as a plain
message. Mid-line `/word` has no special meaning at the protocol level — it's
plain prose. The highlight (`AgenticSlashCommand` → `@function.call`) signals
"this is intercepted and acted upon" vs unmarked text.

## Keymaps and configuration

All user-configurable options live in `config_default.lua`. Keymaps are grouped
by scope: `keymaps.widget` (all Agentic buffers), `keymaps.prompt` (input
buffer only), `keymaps.chat` (chat buffer only), `keymaps.diff_preview`.

Keymap values use `BufHelpers.multi_keymap_set` which accepts a string, a list
of strings, or a list of `{ key, mode = ... }` tables for multi-mode bindings.
All widget keymaps are applied as buffer-local maps in `ChatWidget:_setup_keymaps`
over every buffer in `self.buf_nrs` (chat, input, todos, code, files, diagnostics).

The plugin's `ftplugin/` directory holds filetype-specific setup (e.g.
`AgenticChat.lua` for treesitter query overrides). Buffer filetypes are set in
`ChatWidget:_create_buf_nrs`: `AgenticChat`, `AgenticInput`, `AgenticTodos`,
`AgenticCode`, `AgenticFiles`, `AgenticDiagnostics`.

## Client-side auto-approval

The plugin extends the ACP provider's permission system with four client-side
auto-approval mechanisms in `PermissionManager:_try_auto_approve()`:

1. **Read-only tools** — ACP kinds `"read"` and `"search"` (covers Read, Grep,
   Glob) are always approved regardless of target path. These tools cannot mutate
   the filesystem. Controlled by `Config.auto_approve_read_only_tools` (default
   `true`).

2. **Compound Bash commands** — the upstream provider matches the full command
   string against each `Bash(...)` pattern, so `grep foo | head -20` prompts
   even when both `Bash(grep *)` and `Bash(head *)` are allowed. The plugin
   splits on shell operators, strips harmless wrappers (stdbuf, /dev/null
   redirects), and checks each segment independently against two merged
   pattern sources: the user's `~/.claude/settings.json` allow/deny/ask rules
   AND a curated built-in `Config.read_only_commands` /
   `read_only_commands_deny` list (covers `ls`, `cat`, `head`, `tail`,
   `find` minus `-exec`/`-delete`/`-ok`, etc.) that applies to every
   provider, not just Claude. Master switch:
   `Config.auto_approve_compound_commands` (default `true`); built-in list
   opt-out: `Config.auto_approve_read_only_commands` (default `true`).
   Implementation in `lua/agentic/utils/permission_rules.lua`.

3. **Allow/reject always cache** — when the user selects `allow_always` or
   `reject_always`, the decision is cached in `PermissionManager._always_cache`
   and subsequent matching requests are auto-approved/rejected without prompting.
   This compensates for providers that don't reliably persist `allow_always`
   decisions via ACP. File-scoped tool kinds (edit, write, create, delete, move)
   cache per `kind:file_path`. Other kinds cache per `kind` alone. The cache
   is cleared on `clear()` (session reset / `/new`).

4. **Trust scope (`/trust`)** — per-session scoped auto-approval for
   file-scoped tool kinds. The user picks a scope via `/trust` (with reserved
   literals `repo` / `here` / `off`, or any path/glob). For matching paths the
   plugin still requires git-recoverable safety: new file, tracked + clean,
   **pure addition** (diff.old is a contiguous line subsequence of diff.new,
   so `old_string`-anchored user content is preserved verbatim inside
   `new_string`), or tracked + dirty hunks that overlap a **recorded
   Claude-owned line range** whose content still matches disk. Ranges are
   captured at the initial `tool_call` via unique-subsequence match of
   `diff.old` (Claude's Edit tool enforces `old_string` uniqueness, so a
   non-unique match at recording time means the file has shifted and we skip
   recording). Symlink endpoints, mtime TOCTOU revalidation, and a wide-scope
   WARN are all enforced. Controlled by `Config.auto_approve_trust_scope`
   (default `true`). Implementation in `lua/agentic/utils/trust_safety.lua`
   and `lua/agentic/utils/git_files.lua`; range capture in
   `SessionManager:_record_pending_edit_range` and
   `PermissionManager:{record_pending_edit,finalize_edit_range}`.

See "Client-side auto-approval" in @lua/agentic/acp/AGENTS.md for the full
algorithm and safety rules (including the six trust-scope safety properties).

## ACP details

See @lua/agentic/acp/AGENTS.md for event pipeline, tool call lifecycle,
adapter override points, and permission flow.

### Upstream issues (claude-agent-sdk)

- **anthropics/claude-code#35298** — Skills with `paths` triggers crashed
  Read/Write/Edit for files outside cwd. Fixed in SDK 0.2.104 / claude-agent-acp
  0.27.0. See @.claude/skills/acp/references/claude-agent.md

## Testing

See @tests/AGENTS.md for test framework, file locations, and how to run tests.
