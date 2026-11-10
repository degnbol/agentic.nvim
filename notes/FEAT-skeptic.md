# Plan: background skeptic
Status: reviewed spec

Skeptics run as `lua/agentic/background_session.lua` sessions. Claim extraction calls
`lua/agentic/utils/text_model.lua`.

## Relevant files
- `lua/agentic/session_manager.lua` — `_dispatch_turn` (3251; `retrying` 3314, `on_response_complete` 3421), `_send_user_prompt` (3160-3188, `user_msg`), `_relay` (2787), `LOCAL_COMMANDS` (2578), `parse_local_command` (2596), `_run_local_command` (2616), `AgenticSessionChanged` (3551, 3673), session/load user-row replay (1121)
- `lua/agentic/session_registry.lua` — `create` (49), `destroy` (79)
- `lua/agentic/acp/slash_commands.lua` — builtin completions (25-61)
- `lua/agentic/ui/message_writer.lua` — `write_user_prompt` (1699), `prompt_sign` (1683)
- `lua/agentic/ui/chat_history.lua` — `messages`, `subagent_messages` (101), `agent_key`, `UserMessage`
- `lua/agentic/session_resume.lua` — saved-row replay (417)
- `lua/agentic/glyphs.lua`, `lua/agentic/config_default.lua`, `doc/agentic.txt`
- Skills: `session-lifecycle`, `provider-system`, `rendering`, `implement`, `neovim`, `lua-class`
- `.claude/rules/session-isolation.md`

## Background
Reviewer agents routinely find flaws in an agent's claims, and the user
otherwise does that arguing. A skeptic does it in the background, so the user
sees fewer wrong claims and argues less.

Research behind the design:
- Multi-round debate adds little over a vote and drifts toward agreement;
  independent checks and model-family diversity help. So skeptics are
  verifiers, one round, and never see the main agent's reasoning.
- Splitting text into single claims before checking is cheap and works
  (SAFE, Chain-of-Verification). A small model extracts claims.
- Single review models have 50–80% precision on code-review benchmarks. Two
  skeptics from different labs that agree are a strong signal; the main agent
  decides whether to check.

Pipeline, per main session, at each completed turn:
1. Collect everything not yet checked: user prompts, agent text, main edit
   diffs, subagent reports and subagent edit diffs. Positions do not
   separate turns (a prompt sent mid-turn adds its user row while the
   earlier turn still writes), and rows change in place (a call's `diff` and
   `body` arrive by later updates; a background subagent's report lands in a
   row written long before). So tool calls and subagent results are taken
   when completed and not yet in the checked set, keyed by id; only
   prompts and main agent text use a mark into `messages`.
   Subagent reports are checked here, where they enter the main agent's
   context; skeptics cannot address a subagent.
2. Extract (text model): numbered checkable claims, leaving out claims
   checked earlier in the session. No claims → stop.
3. Verify: each skeptic gets the user prompts, the claims and the diffs, and
   returns a verdict per claim with evidence.
4. Gate: forward a claim when the verdicts meet `gate`.
5. Deliver: one prompt to the main session, from the skeptic, sent at once.
   It runs after the current turn. Skeptics never stop the main agent's turn.

A turn whose `user_msg` came from the skeptic is collected, so its content
counts as checked, but not sent on: one round.

A turn that ends with any stop reason but `end_turn`, or with an error, is
not checked and nothing is collected; its content is checked at the next
turn that ends normally. So a skeptic never restarts an agent the user
stopped.

Core gets generic extension points; it never requires the skeptic module, and
per-session skeptic state lives on the session, not in a module table.

## Changes
### Core
`session_manager.lua`:
```lua
--- @alias agentic.SessionEvent "turn_end"|"session_changed"|"destroy"

--- @class agentic.SessionEventData
--- @field user_msg? agentic.ui.ChatHistory.UserMessage turn_end: the turn's prompt row
--- @field stop_reason? string turn_end: nil on an error
--- @field continued? boolean session_changed: true when the conversation carries on (`renew_session`, `replace_with_history`), false for /new and load

--- Run `listener` on `event`. `turn_end`: in `_dispatch_turn`'s callback
--- when not retrying, beside `on_response_complete`. `session_changed`:
--- where `AgenticSessionChanged` fires. `destroy`: first in
--- `SessionManager:destroy`, before `_cancel_session` and `widget:destroy`.
--- @param event agentic.SessionEvent
--- @param listener fun(session: agentic.SessionManager, data: agentic.SessionEventData)
--- @return fun() unsubscribe
function SessionManager:on(event, listener)

--- Per-session state of extensions, keyed by extension name.
--- @field extensions table<string, any>

--- `_relay` with an author: no context panels, the history row and the
--- prompt sign carry `author`. Held when the gate holds it.
--- @param author string
--- @param text string
--- @return string|nil held_cause
function SessionManager:send_from(author, text)

--- Add a synchronous local slash command (`async` and `session_ending`
--- false) and its completion.
--- @param name string
--- @param spec { takes_arg: boolean, description: string, run: fun(session: agentic.SessionManager, arg: string|nil) }
function SessionManager.register_local_command(name, spec)
```
- `on_prompt_submit` is not invoked for `send_from` prompts.
- `MessageWriter:write_user_prompt(text, extra_lines, author)`: a non-nil
  `author` makes the file-local `prompt_sign(text, author)` return
  `Glyphs.AUTHOR[author]`.

`acp/slash_commands.lua`: the builtin list moves out of its function to a
module-level table, and `M.register_builtin(name, description)` adds to it;
`register_local_command` calls it.

`session_registry.lua`:
```lua
--- Run `listener` for each session `create` makes, after registration.
--- @param listener fun(session: agentic.SessionManager)
function SessionRegistry.on_create(listener)
```
The listener list is extension registration, not per-session state.

`chat_history.lua`: `UserMessage.author?: string`. Rendering: the prompt
sign uses `Glyphs.AUTHOR[author]` (new; `skeptic` gets one glyph) in place of
the user's sign; the text is unchanged — the skeptic's prompt names itself in
its first line. `session_resume.lua` (417) keeps `author` when it replays
saved rows; Path B (`prepend_history_messages`) writes `"<Author>: …"` for
them. The session/load handler (1121) adds only rows the file lacks, which
have no author; they render with the user's sign.

### Skeptic (`lua/agentic/skeptic/`)
- `init.lua`:
  ```lua
  function M.setup()   -- register /skeptic; on_create: Skeptic:new(session), enable when Config.skeptic.enabled
  function Skeptic:new(session)       -- session.extensions.skeptic = self; subscribes turn_end, session_changed, destroy
  function Skeptic:enable()           -- needs TextModel.available(); else notify and stay off
  function Skeptic:disable()          -- destroy skeptic sessions; marks stay
  function Skeptic:restart()
  function Skeptic:_on_turn_end(session, data)
  ```
  `session_changed`: the mark moves to the end of the installed history and
  every row in it counts as checked; with `continued = false` the checked
  claims are also cleared. `destroy` disables. `/skeptic` with no argument
  reports on or off. A checkpoint arriving while one runs is merged into the
  next run. A held delivery is kept and sent at the next normal turn end.
- `turn.lua`:
  ```lua
  --- @class agentic.skeptic.Seen
  --- @field mark integer Index into `messages` after the last collected row
  --- @field ids table<string, true> Collected tool_call ids and subagent result keys

  --- @class agentic.skeptic.Turn
  --- @field prompts string[] User rows since the mark without `author`
  --- @field text string Main agent rows (no `agent_key`) since the mark; thought rows excluded
  --- @field diffs string[] Completed tool_call rows with `diff`, in `messages` and `subagent_messages`, not in `seen.ids`; unified-diff text per file
  --- @field reports string[] Subagent results not in `seen.ids`: completed tool_call rows with `subagent` set (their `body`; on opencode `body` is the prompt until completion), and `session_message` rows with `kind = "result"` (keyed by `agent_key`)

  --- Collect and add what it took to `seen`.
  --- @return agentic.skeptic.Turn
  function M.collect(history, seen)
  ```
- `claims.lua`: `M.extract(turn, checked: string[], on_done: fun(claims: string[]|nil, err: string|nil))`
  via `TextModel.complete`; parses a JSON array of strings.
- `verdicts.lua`: `M.parse(text): table<integer, { verdict: "refuted"|"supported"|"unsure", evidence: string }>|nil`
  from the last fenced `json` block of a skeptic's reply.
- `gate.lua`: `M.findings(claims, per_skeptic, gate): { claim: string, evidence: string[] }[]`.
  `"agree"`: every skeptic `refuted`. `"either"`: any skeptic `refuted` with
  evidence.
- `prompts.lua`: default `extract`, `verify`, `deliver` and `refusal` texts.

`config_default.lua`:
```lua
skeptic = {
    enabled = false,
    gate = "agree",
    extractor = { model = "deepseek-v4.1-flash" },
    skeptics = {
        { provider = "opencode-acp", model = "litellm/glm-5.3" },
        { provider = "opencode-acp", model = "litellm/kimi-k3" },
    },
    turn_timeout_ms = 300000,
    max_refusals = 3,
    prompts = {}, -- overrides for prompts.lua keys
},
```
`deliver` says the findings come from background skeptics and that the main
agent decides whether one needs checking.

`doc/agentic.txt`: `agentic-skeptic` — what it does, `/skeptic`, the config
keys, the `text_model` and opencode permission requirements.

Tests: `skeptic/*.test.lua` for `turn` (mid-turn prompt row interleaved,
a diff arriving after an earlier collect, a background subagent report on
an old row, claude result rows, opencode body before completion), `claims`
(stubbed TextModel), `verdicts`, `gate`, `init` (one round via
`user_msg.author`, stopped and errored turns deferred, merged checkpoints,
held delivery, disable mid-run, `session_changed` with and without
`continued`). `session_manager.test.lua` for
`on` (not on retry, not on local commands), `send_from`,
`register_local_command`; `session_registry.test.lua` for `on_create`.

## Expected outcome
With `/skeptic on` (or `skeptic.enabled`), after each turn two skeptics on
other models check its claims in the background. Disputed claims reach the
main agent as a skeptic prompt; the user sees only that exchange, and can open
each skeptic's transcript.

## Non-goals
- Skeptic statistics and their display (`IDEA-session-stats-logging.md`).
- Checking during a turn, or after each tool call.
- Stopping the main agent's turn.
- Skeptics on providers other than opencode.

## Open questions
None.
