# Plan: run Claude command hooks for opencode sessions
Status: reviewed spec
Priority: P2
Depends:

## Relevant files
- `lua/agentic/session_manager.lua` — `_on_request_permission`, `_on_tool_call_update`, `_handle_input_submit_inner`, `_end_turn`, `_busy_reason`, `_drain_side_records`, `send_from`, `stop_generation`
- `lua/agentic/session_recovery.lua` — `Recovery.return_as_draft`
- `lua/agentic/skeptic/init.lua` — the session-extension pattern (`session.extensions`, `turn_end`/`session_changed`/`destroy` listeners)
- `lua/agentic/acp/acp_client.lua` — override points, `HookRecord`/`HookRecordGroup`/`HookOutcome`, `_send_request`
- `lua/agentic/acp/adapters/opencode_acp_adapter.lua` — `unattended_env`, `__handle_tool_call(_update)`
- `lua/agentic/acp/agent_instance.lua` — env applied at spawn
- `lua/agentic/ui/permission_manager.lua` — `add_request`, `cancel_requests`, `record_causes`, `resolve_request`
- `lua/agentic/ui/side_records.lua` — hook display
- `lua/agentic/utils/permission_rules.lua` — `settings_paths`, mtime cache
- `lua/agentic/glyphs.lua` — `Glyphs.AUTHOR`, `Glyphs.HOOK`
- `lua/agentic/config_default.lua`
- Skills: `provider-system`, `permissions`, `session-lifecycle`, `rendering`; `claude` skill `references/hooks.md` (contract); `acp` skill `references/opencode.md`
- opencode source, tag `v2.3.0` (`https://github.com/anomalyco/opencode`): `packages/core/src/permission.ts`, `packages/core/src/session/runner/step.ts`, `packages/core/src/file-access.ts`, `packages/core/src/tool/plugin/*.ts`, `packages/cli/src/acp/{turn,agent,permission,translate}.ts`
- User hooks: `~/.config/claude/settings.json` `hooks`, `~/.config/claude/hooks/lib/core.zsh`

## Background
Claude command hooks are an executable per event, JSON on stdin, and an exit
code or JSON verdict on stdout. claude-agent-acp runs them for Claude
sessions; opencode sessions (the litellm models) run none. The guard logic for
opencode is a partial TS copy (`~/.config/opencode/plugins/guards.ts`). The
command contract is host- and language-neutral, so the plugin runs the same
hooks for opencode sessions, and the TS copy can go.

### What the user's hooks use
- Outputs: exit 2 with stderr; `permissionDecision: "deny"`; `additionalContext`.
  A deny from `lib/core.zsh` (`_emit_context`) carries a fixed
  `permissionDecisionReason` ("Blocked by a hook; reasons in the hook context.")
  and puts the reasons in `additionalContext` beside it. No hook uses `allow`,
  `ask`, `updatedInput` or `continue: false`.
- Handler fields: `if` as `Skill(<name>)` and `Write(<path>)`; `once: true`
  (`gitignore-guard.sh`).
- Matchers: `*` or `|`-lists of tool names.
- Input: Stop hooks read the last assistant text from `transcript_path`
  (`read_last_response`). PostToolUse hooks read
  `tool_response.structuredPatch[]` (`lines` with ` `/`+`/`-` prefixes,
  `newStart`) and `tool_response.type` for Edit/Write, and `tool_response` for
  WebFetch.
- PostToolUse matchers with no PreToolUse counterpart: `WebFetch`.
- Stop runs `bell.sh`, which duplicates the plugin's own bell.

### opencode 2.3.0
- **Gate.** A tool waits on `session/request_permission` only when its action
  evaluates to `ask`. Rules are last-match-wins; `OPENCODE_CONFIG_CONTENT` ranks
  above config files. Saved "always" rules are appended after config rules
  (`evaluateInput`), so an `always` reply stops later matching asks for the
  project, across sessions. An appended `{action, *, ask}` also beats an earlier
  configured `deny` for that action; the user's config has none.
- **Requests.** `rawInput` and `name` are on the request only when the tool part
  is known (`cli/src/acp/permission.ts`); shell requests can arrive without the
  command. One call can ask twice with the same `toolCallId`:
  `external_directory` then `edit` (`file-access.ts`), `skill` then `read` for
  `skill://` reads.
- **Reject ends the turn.** ACP sends no reject message, so the reply is a
  `DeclinedError`: the step interrupts, the tool result is "The user declined
  this tool call", every other pending ask of the session is rejected with it,
  and the prompt returns `stopReason: "cancelled"`. A reason reaches the model
  only in a later prompt. (opencode's own plugin API can deny with a message the
  model sees in the same turn; ACP cannot carry one.)
- **Steering.** `_session/steering` `{sessionId, prompt}` injects input into a
  running turn (promoted at the next step boundary) and returns
  `{outcome: "injected"}`, or `{outcome: "promptRequired"}` when idle.
- **Actions** are tool names: `shell`, `edit` (also write/patch), `read`,
  `grep`, `glob`, `skill`, `webfetch`, `subagent`.
- **Tool input fields:** shell `{command, workdir, timeout, background}`;
  edit `{path, oldString, newString, replaceAll}`; write `{path, content}`;
  read `{path, offset, limit}`; grep `{pattern, path, include}`;
  glob `{pattern, path}`; webfetch `{url, format}`; skill `{id}`;
  subagent `{agent, description, prompt}`.

## Changes

### Config (`config_default.lua`)
```lua
claude_hooks = {
    --- Run Claude command hooks from settings.json for providers whose bridge does not
    enabled = false,
    --- Hook commands not run, matched against the command's last path component
    skip = {},
}
```
Opt-in, because it forces opencode to ask for the hooked actions. The user's
config sets `enabled = true, skip = { "bell.sh" }`.

### Shared settings reader — new `lua/agentic/utils/claude_settings.lua`
- `ClaudeSettings.read(config_dir: string, cwd: string) -> table[]` — the
  decoded settings tables of `<config_dir>/settings.json`,
  `<cwd>/.claude/settings.json`, `<cwd>/.claude/settings.local.json`, in that
  order, missing files skipped, mtime-cached per `(config_dir, cwd)`.
- `PermissionRules.get_settings_patterns` uses it (its project path becomes
  `<cwd>/.claude/settings.json` with the session cwd passed in) and drops its
  own cache.

### Override points (`acp_client.lua`, defaults)
- `ACPClient:needs_client_hooks() -> boolean` — false. The claude adapter keeps
  false: its SDK runs the hooks.
- `ACPClient:ask_env(env, actions: string[]) -> table<string,string>|nil, string|nil` —
  nil and an error. Replaces `unattended_env`; its callers pass `{ "*" }`.
- `ACPClient:hook_tool(session_id: string, tool_call_id: string) -> string|nil, table|nil` —
  the Claude tool name and `tool_input` for a call; nil.
- `ACPClient:hook_response(session_id: string, tool_call_id: string) -> table|nil` —
  Claude `tool_response` for a completed call; nil.
- `ACPClient:steer(session_id: string, text: string, callback: fun(injected: boolean))` —
  calls `callback(false)`.

### opencode adapter
- `needs_client_hooks` → true.
- `ask_env(env, actions)` — today's `unattended_env` body, appending one
  `{action = a, resource = "*", effect = "ask"}` per action.
- Per-session call store `self._hook_calls[session_id][tool_call_id] = {name, raw_input, response}`,
  filled in `__handle_tool_call` / `__handle_tool_call_update` from `name` and
  the full `rawInput` of the `in_progress` update; on `completed`, `response`
  is built from that update's own content (not the tracker). Cleared per
  session on session end.
- `hook_tool` — reads the store, falling back to the request's `rawInput`
  (passed in by the caller through the store). Map:

  | opencode | Claude | input |
  |---|---|---|
  | `shell` | `Bash` | `command`, `timeout`, `run_in_background ← background` |
  | `edit` | `Edit` | `file_path ← path`, `old_string ← oldString`, `new_string ← newString`, `replace_all ← replaceAll` |
  | `write` | `Write` | `file_path ← path`, `content` |
  | `read` | `Read` | `file_path ← path`, `offset`, `limit` |
  | `grep` | `Grep` | `pattern`, `path`, `glob ← include` |
  | `glob` | `Glob` | `pattern`, `path` |
  | `webfetch` | `WebFetch` | `url` |
  | `skill` | `Skill` | `skill ← id` |
  | `subagent` | `Agent` | `subagent_type ← agent`, `description`, `prompt` |

  `file_path` is made absolute against the session cwd. Any other tool: its
  opencode name and raw input, which no Claude matcher names. No input at all:
  nil.
- `hook_response` — Edit/Write: `{type = oldText == nil and "create" or "update", filePath, structuredPatch}`
  from the completed update's `diff` entry (full `oldText`/`newText`): one
  hunk per `vim.diff(old, new, {result_type = "indices"})` range, with
  `oldStart/oldLines/newStart/newLines` and `lines` built from the two texts
  (context 3, ` `/`-`/`+` prefixes). Bash: `{stdout = <the completed update's content text>}`.
  WebFetch: that text. Else `{}`.
- `steer` — `_send_request("_session/steering", {sessionId, prompt = {{type = "text", text}}})`;
  `injected = result.outcome == "injected"`.
- `__handle_request_permission`: when hooks are on and the request's tool maps
  to a forced-ask action, a reply whose option kind is `allow_always` is sent as
  the `once` option. The plugin's always-cache keeps the choice; an opencode
  saved rule would stop the ask, and so the hooks, for good. Other tools keep
  opencode's `always`.

### Spawn (`agent_instance.lua`)
- Unattended instance: `ask_env(config.env, { "*" })`, as now; no hook env (it
  already asks for everything).
- Other instance, when `Config.claude_hooks.enabled` and
  `Adapter:needs_client_hooks()`: `ask_env(config.env, ClaudeHooks.pre_tool_actions(config_dir))`.
  Global settings only: one process serves every cwd. A matcher change needs a
  provider restart.

### New `lua/agentic/claude_hooks/settings.lua` — `ClaudeHookSettings`
- `groups(config_dir: string, cwd: string, event: string) -> agentic.ClaudeHooks.Group[]` —
  the event's `hooks` arrays from `ClaudeSettings.read`, concatenated; empty
  when any file sets `disableAllHooks`.
- `pre_tool_actions(config_dir: string) -> string[]` — the opencode actions of
  the Claude tools named by global PreToolUse matchers; `*` gives `{ "*" }`.
- Types: `Group {matcher?: string, hooks: Handler[]}`,
  `Handler {type: string, command: string, timeout?: number, ["if"]?: string, once?: boolean}`.

### New `lua/agentic/claude_hooks/match.lua` — `ClaudeHookMatch`
- `handlers(groups, tool_name: string|nil, tool_input: table|nil) -> agentic.ClaudeHooks.Handler[]` —
  - matcher `*`/empty/absent matches all; a `|`-list of names matches exactly;
    any other matcher: `Logger.notify` once per matcher and skip it.
  - `if`: `Skill(x)` matches `tool_input.skill == x`; `Read|Edit|Write(p)`
    matches `file_path` against `p` with Claude's path-rule reading (`//p`
    absolute, `/p` relative to the settings file's directory, `~/p` home) via
    `vim.glob.to_lpeg`; `Bash(...)` always runs (the hook filters itself).
  - only `type = "command"`; `skip` basenames dropped; dedup by `command`.

### New `lua/agentic/claude_hooks/runner.lua` — `ClaudeHookRunner`
- `run(event: string, handlers, input: table, opts: {cwd: string}, on_done: fun(result: agentic.ClaudeHooks.Result))` —
  one `vim.system({ "sh", "-c", command })` per handler, in parallel, stdin
  `vim.json.encode(input)`, env adds `CLAUDE_PROJECT_DIR = cwd`, timeout
  `handler.timeout` s else 600 s. `on_done` runs scheduled, once, after all end.
- `Result`:
  - `denials: string[]` — exit 2 stderr; `decision == "block"` `reason`.
    A `permissionDecision == "deny"` adds its reason **and the same run's
    `additionalContext`**, so a deny carries its real reasons.
  - `contexts: string[]` — `additionalContext` of non-denying runs; plain
    stdout of exit 0 for `SessionStart` and `UserPromptSubmit`.
  - `records: agentic.acp.SideRecord[]` — one `{kind = "hook"}` per run:
    `hook_name = event .. ":" .. (matcher or "*")`, `command`, `duration_ms`,
    group `context`/`passed`/`failure`, outcome `blocked`/`denied`.
  - Other exits and timeouts: a `failure` record only. Other JSON fields:
    `Logger.debug`.

### New `lua/agentic/claude_hooks/transcript.lua` — `HookTranscript`
- `path(session_id: string) -> string` — `stdpath("cache")/agentic/hook-transcripts/<session_id>.jsonl`.
- `append(path: string, role: "user"|"assistant", text: string)` — one line
  `{"type": role, "message": {"role": role, "content": [{"type": "text", "text": text}]}}`.
- `remove(path: string)`.

### New `lua/agentic/claude_hooks/init.lua` — `ClaudeHooks` (session extension)
Registered as `session.extensions.claude_hooks` by `SessionManager` when
`Config.claude_hooks.enabled` and `agent:needs_client_hooks()`, like the
skeptic. Listens to `session_changed` (SessionStart source: `continued` →
`"resume"`, else `"startup"`; `/new` → `"clear"`) and `destroy` (SessionEnd,
transcript removal, `agent` store cleanup).

State: `_verdicts[tool_call_id]` (first PreToolUse result per call),
`_posted[tool_call_id]`, `_once[command]`, `_feedback: string[]`,
`_denied_turn: boolean`, `_stop_hook_active: boolean`, `_running: integer`.
Base input `{session_id, transcript_path, cwd, permission_mode = "default", hook_event_name}`;
tool events add `tool_use_id` and, for a child's call,
`agent_id = session._subagents:owner_of(id)`.

- `new(session: agentic.SessionManager) -> agentic.ClaudeHooks`
- `running() -> boolean` — `_running > 0`.
- `pre_tool_use(request: agentic.acp.RequestPermission, done: fun(denials: string[]))` —
  a second request for a call reuses `_verdicts`. `agent:hook_tool` nil: no
  hooks, a `failure` record "no tool input", `done({})`. Contexts →
  `agent:steer`, wrapped `<hook-context event="PreToolUse">…</hook-context>`;
  not injected → `_feedback`.
- `post_tool_use(tool_call_id: string)` — once per call; any completed call
  with input (not only gated ones). Denials and contexts are steered the same way.
- `user_prompt_submit(prompt: agentic.acp.Content[], done: fun(blocked: string[]|nil, extra: agentic.acp.Content[]))` —
  `.prompt` is the `"\n"`-join of the prompt's text blocks (as Claude sees
  them through ACP), without hook contexts. Clears `_stop_hook_active`.
- `session_start(done: fun(extra: agentic.acp.Content[]))`.
- `stop(done: fun(reasons: string[]))` — `stop_hook_active = self._stop_hook_active`.
- `on_denied(tool_call_id: string, denials: string[])` — main call: add to
  `_feedback`, set `_denied_turn`. Child call: steer to the parent session
  (`Subagent <name>'s call was blocked: …`); not injected → `_feedback`.
- `take_feedback() -> string|nil` — `_feedback` joined, cleared.
- Every run passes its records to `session:place_side_records(records)`.
- `once` handlers run once per session (`_once`).

### `permission_manager.lua`
`add_request(request, callback, gate?)` — `gate: fun(done: fun(denials: string[]))`.
With a gate, the request enters the queue as gating: no auto-approve, no
float, until `done`. Denials → reply with the `reject_once` option and record a
`hook` cause whose detail is the denials (the rejection line). None → the
normal path (auto-approve, then the float). `cancel_requests` resolves a gating
request like any other; a later `done` is ignored. The return value (`prompted`)
becomes a callback, `on_prompted`, fired when the float opens, since the
decision is now async.

### `session_manager.lua`
- `_on_request_permission`: with the extension, pass
  `gate = function(done) hooks:pre_tool_use(request, function(d) if #d > 0 then hooks:on_denied(id, d) end done(d) end) end`;
  bell, hook and run-clock code move into `on_prompted`.
- `_on_tool_call_update`: on a call's first `completed`, `hooks:post_tool_use(id)`.
- `_busy_reason`: returns `"hooks"` while `hooks:running()`. The submit and
  drain gates treat it like `in_flight`.
- `_handle_input_submit_inner` (prose blocks only; command blocks are sent as
  now, with no hook context): on the session's first prose prompt run
  `session_start`, then `user_prompt_submit`. Their contexts and
  `take_feedback()` go before the user text as `<hook-context>` blocks. Blocked:
  the reasons as a `for_user` hook record, then
  `Recovery.return_as_draft(self, input_text, consumed)`. `send_prompt` moves
  into the callback, after a `destroyed`/epoch check. The user text is appended
  to the transcript when sent.
- `_end_turn`, not while retrying:
  - `stop_reason == "cancelled"` and `hooks._denied_turn`:
    `send_from("hook", take_feedback())`.
  - `stop_reason == "end_turn"` and not `busy`: append the turn's assistant text
    to the transcript; run `stop` before `_notify_attention` and `_drain_queue`,
    which move into its callback. Reasons → set `_stop_hook_active`,
    `send_from("hook", reasons)`; none → attention and drain as now.
  - Clear `_denied_turn`.
- New `SessionManager:place_side_records(records: agentic.acp.SideRecord[])` —
  the `store_placed` body of `_drain_side_records`, extracted: writes the
  records and keeps them in the history.
- `send_from("hook", …)` texts are appended to the transcript.

### `glyphs.lua`
`Glyphs.AUTHOR.hook = Glyphs.HOOK`.

## Tests
- `claude_settings.test.lua`: order, missing files, mtime reload.
- `claude_hooks/{settings,match,runner,transcript}.test.lua`: `disableAllHooks`;
  matcher list, `*`, unsupported matcher; `if` forms incl. `//`, `/`, `~/`;
  `skip`, dedup; runner exit 0/1/2, JSON deny with context, `additionalContext`,
  plain stdout per event, timeout (scripts in a temp dir).
- `opencode_acp_adapter.test.lua`: `hook_tool` per tool and the request
  fallback; `hook_response` `structuredPatch.lines` and `type`; `ask_env`;
  `always`→`once` only for forced-ask actions.
- `permission_manager.test.lua`: gate deny → reject with `hook` cause; gate
  pass → auto-approve; `cancel_requests` during a gate; late `done` ignored.
- `claude_hooks/init.test.lua` with a stub session: second request reuses the
  verdict; steer fallback; child deny steered to the parent; `once`;
  `stop_hook_active` cleared by a user prompt.
- `session_manager.test.lua`: deny → feedback prompt after the `cancelled`
  turn; `<C-c>` turn sends none; Stop block → feedback prompt, drain deferred;
  `_busy_reason` `hooks`; blocked prompt returns as a draft; command block gets
  no hook context.

## Expected outcome
In an opencode session with `claude_hooks.enabled`, the user's Claude hooks
run with Claude-shaped input:
- A PreToolUse block or deny rejects the call; its rejection line shows the
  reasons; the turn ends (with any parallel calls) and the reasons are sent as
  a hook-authored prompt, so the model retries.
- PreToolUse and PostToolUse context reaches the model at its next step,
  through steering. PostToolUse runs for every completed call, gated or not.
- SessionStart and UserPromptSubmit context is part of the prompt; a
  UserPromptSubmit block returns the prompt to the input as a draft.
- A Stop block makes the agent continue; the bell and the queue wait for Stop.
- Each hook run shows as a hook row or block, kept in the history.
- The opencode actions with a global PreToolUse matcher always ask; with the
  user's settings these are `shell`, `edit`, `read`, `grep`, `glob`, `skill`,
  which the plugin auto-approves or already asked for. No new prompts.

Claude sessions are unchanged.

## Non-goals
- `updatedInput`, `permissionDecision` `allow`/`ask`, `continue: false`,
  `prompt`/`agent`/`http` hook types, `async`.
- Events with no opencode source: `PreCompact`, `PostCompact`, `CwdChanged`,
  `UserPromptExpansion`, `Notification`, `SubagentStart`, `SubagentStop`.
- Hooks in background sessions (`background_session.lua`).
- PreToolUse matchers that only project settings have: they run when the
  action asks anyway, but do not force an ask.
- `patch` edits (no Claude counterpart; `Write|Edit` matchers do not see them).
- MCP calls made inside Code Mode `execute`.
- Calls an opencode saved "always" rule already allows (made before this
  change); they skip the ask and the PreToolUse hooks.
- Deleting `~/.config/opencode/plugins/guards.ts` (dotfiles repo, after this lands).

## Open questions
None.
