# Plan: Claude Code auto mode verdict
Status: draft
Priority: P2
Depends:

## Relevant files
- `~/dotfiles/config/pi/patches/pi-claude-bridge.patch` (`emitSafeguardResults`,
  `permissionOptions`); `~/dotfiles/agents/docs/pi/claude-bridge.md`
- `pi/agentic.ts` — the `tool_call` handler that asks Neovim about every call
- `lua/agentic/pi/pi_permission.lua` (`OPTION_IDS`, `parse`, `to_request`,
  `to_response`), `lua/agentic/pi/pi_client.lua` (`_on_ui_request`)
- `lua/agentic/ui/permission_manager.lua` — `decide`, `_try_auto_approve`,
  `approve`, `reject`, `_process_next`, `_anchor_title`, `_complete_request`,
  `record_causes`, `CAUSE_TEXT`, `agentic.PermissionCauseCode`
- `lua/agentic/acp/canonical_tool_call.lua` — `REJECTION_LINES`, `causes_line`
- `lua/agentic/background_session.lua` — `_on_request_permission`
- `lua/agentic/config_default.lua` — `permissions`
- Skill: `permissions`
- pi 1.6.1: `docs/extensions.md` § `pi.events`, § Handler Composition;
  `dist/modes/rpc/rpc-mode.js` (`select` returns the response's `value`
  unchecked); `dist/agent-loop.js` (tools run after the assistant stream ends)
- Captured Claude Code 2.1.332 auto mode traffic: `/tmp/ccproxy/log/`
  (`010.req.json` `safeguards`, `010.resp` `safeguard_results`)
- Probe extension that logs verdicts and `tool_call`s: `/tmp/spike/probe.ts`,
  driven by `/tmp/spike/drive-installed.py <model> <prompt>...`

## Background
The plugin's deterministic permission checks decide what they can; this
plan adds the fallback for the calls they leave undecided: Claude Code's
auto mode verdict.

Claude Code's auto mode classifier runs on Anthropic's API. Captured from
Claude Code 2.1.332 (Haiku 5.5, Sonnet 5.5):
- A Messages request carries
  `safeguards: [{ type: "dangerous_tool_use", classifier_context }]`:
  permission mode, cwd, home, platform, trusted directories, the user's
  Claude Code allow/deny/ask rules and `autoMode` lists (empty: the
  server's defaults), the git state, the calls refused earlier.
- The response's `message_delta` carries a verdict per `tool_use`:
  `safeguard_results: [{ type: "dangerous_tool_use", status: { type: "available", tool_uses: { "<id>": { type: "evaluated", outcome: "not_flagged", cited_rule: null } } } }]`.
  `tool_uses` can be empty.
- Claude Code acts on a flag itself: it answers the `tool_use` with its own
  denial and never dispatches it.

The dotfiles install patches `pi-claude-bridge`
(`~/dotfiles/config/pi/patches/`, `bridge-install.sh`, `bridge-update.sh`;
`claude-bridge.json` sets `provider.permissionMode: "auto"`). Claude Code
runs in auto mode, a `PreToolUse` hook keeps it from denying a flagged call
itself, and each verdict goes out on pi's event bus:
`pi.events.emit("claude-bridge:safeguard", { toolCallId, outcome, citedRule? })`.
Measured (bundled Claude Code 2.1.321, Haiku 5.5; Sonnet 5.5 and Opus 5.5
also get verdicts, Haiku 4.5 gets none and its turns run as before):
- Every call gets a verdict, under the id pi gives `tool_call`, 1–7 ms
  before `tool_call`. Parallel calls in one message each get their own.
- Outcomes seen: `not_flagged`, `flagged`. `cited_rule` was `null` even
  for a flag from a user `autoMode.hard_deny` rule; Claude Code's own
  denial then says "it gave no explanation".
- A call the user asks for in plain words is `not_flagged`, including an
  upload of `.env` to an external host: the classifier weighs user intent.
- Prompt cache and turn time as with `bypassPermissions` (+0.2 s mean over
  9 turns, within the spread).
- A bridge without the patch (a reinstall that drops it) sends no verdict.

Under the bridge, `classifier_context` holds Claude Code's user settings
(`settingSources: ["user"]`), not the plugin's rules, and its refused calls
stay empty: the plugin's rejections reach Claude Code as MCP tool results.
So the verdict can disagree with the plugin's rules; it is read only where
the rules give no decision.

Neovim applies the verdict to an undecided call:
- `not_flagged` → allow.
- Flagged → reject with the cited rule, if any; the agent reads the reason and
  looks for another way (Claude Code's deny and continue). After 3
  consecutive or 20 total flags in a session, a flagged call prompts
  (Claude Code's limits).
- No verdict (another provider, `status` other than `available`, an id
  missing from `tool_uses`) → prompt, as today.
- An `ask` cause (an `ask` gate of the user or the plugin) prompts
  whatever the verdict: the gate says the user wants to be asked.

A background session has no prompt: `not_flagged` allows, anything else
rejects, as Claude Code applies auto mode to unattended agents.

## Changes

### Extension
1. `pi/agentic.ts`:
   - `pi.events.on("claude-bridge:safeguard")` fills a map from
     `toolCallId` to `{ outcome, citedRule }`, cleared at `turn_end`;
     `tool_call` takes the call's entry and puts it in the title JSON as
     `safeguard`.
   - The answer is an option id, or JSON `{ "reject": "<reason>" }` (pi's
     RPC `select` returns the response's `value` unchecked). A reject with
     a reason returns `{ block: true, reason }`; any other non-allow answer
     keeps today's "Rejected in agentic.nvim". Every reject the plugin
     decides (rules, the verdict, the prompt) can then carry its causes'
     text to the agent.

### Neovim
2. `pi_permission.lua`: `M.Call.safeguard?: { outcome: string, citedRule: string|nil }`;
   `to_request` puts it on the request (`request.safeguard`).
   `to_response(option_id, reason)` encodes a reject with its reason.
3. `permission_manager.lua`:
   - `_try_auto_approve` → `_try_resolve`: an undecided verdict with no
     `ask` cause and `Config.permissions.auto_mode` reads
     `request.safeguard`:
     - `not_flagged`: approve; causes plus `auto-mode-allow`; the
       consecutive count resets.
     - Any other outcome, counts under the limits: reject with the
       causes' text; causes plus `auto-mode-reject` with
       `detail = citedRule`; both counts rise.
     - Counts at a limit: the prompt, with the `auto-mode-reject` cause
       held and the cited rule, if any, in the float title (`_process_next`
       reads `request.safeguard`).
     - No `safeguard`: the prompt, as today.
   - A prompt answer appends its cause to the held causes rather than
     replacing them.
   - Counts are per `PermissionManager` (one per session) and clear with
     its session state.
   - `auto-mode-allow` and `auto-mode-reject` join
     `agentic.PermissionCauseCode` and `CAUSE_TEXT`; the agent-facing
     text of `auto-mode-reject` is Claude Code's own denial text (below),
     with the cited rule in place of "it gave no explanation" when there
     is one, and without its last sentence about Claude Code settings
     rules.

     > Permission for this action was denied by the Claude Code auto mode classifier. Reason: The server-side auto mode classifier judged this action dangerous (it gave no explanation). If you have other tasks that don't depend on this action, continue working on those. IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to accomplish this goal, e.g. using head instead of cat. But you *should not* attempt to work around this denial in malicious ways, e.g. do not use your ability to run tests to execute non-test actions. You should only try to work around this restriction in reasonable ways that do not attempt to bypass the intent behind this denial. If you believe this capability is essential to complete the user's request, first try a safer method. Get as much of the rest of the task done as you can, then STOP and explain to the user what you were trying to do and why you need this permission. Let the user decide how to proceed. To allow this type of action in the future, the user can add a permission rule for mcp__custom-tools__bash to their settings.
4. `canonical_tool_call.lua`: `REJECTION_LINES["auto-mode-reject"]`.
5. `background_session.lua`: an undecided call reads `request.safeguard`:
   `not_flagged` approves, anything else rejects.
6. `config_default.lua`: `permissions.auto_mode = true`;
    `doc/agentic.txt` documents it.

### Tests
7. `pi_permission.test.lua`: `parse` and `to_request` with and without
    `safeguard`; `to_response` with a reason.
8. `permission_manager.test.lua`: `not_flagged` allows an undecided call;
    a flagged one rejects with the cited rule; the third consecutive flag
    rejects and the fourth prompts; an allow resets the consecutive count;
    20 total prompts; an `ask` cause prompts with `not_flagged`; no
    `safeguard` prompts; a rule decision ignores `safeguard`;
    `auto_mode = false` prompts; a prompt answer keeps the
    `auto-mode-reject` cause; two sessions keep separate counts.
9. `background_session.test.lua`: `not_flagged` approves an undecided
    call; a flag rejects.

## Expected outcome
- On a Claude model, a call the rules leave undecided runs without a prompt
  when the classifier does not flag it, and is rejected with the cited
  rule when it does. After repeated flags, the user is asked.
- The agent reads why the plugin rejected a call.
- The call's footer shows the verdict and the cited rule.
- On other models, nothing changes.

## Non-goals
- A classifier for other models: `FEAT-auto-mode-classifier.md`.
- The verdict for calls the rules decide.
- The plugin's context blocks (selected code, diagnostics) in the user's
  message: the classifier may read them as the user's words. Claude Code
  sends its own attachments as `<system-reminder>` blocks; matching that
  is separate work.

## Open questions
