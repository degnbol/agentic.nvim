# Plan: a configurable auto mode classifier for every model
Status: draft
Priority: P3
Depends: FEAT-claude-auto-mode.md

## Relevant files
- `FEAT-claude-auto-mode.md` — the verdict on the permission request
  (`safeguard`) and how Neovim applies it
- `pi/agentic.ts`; `lua/agentic/pi/pi_permission.lua`,
  `lua/agentic/ui/permission_manager.lua`, `lua/agentic/session_manager.lua`
  (`_handle_input_submit_inner`: the context blocks put in front of the
  user's words)
- pi 1.6.1 docs: `extensions.md` § Handler Composition, § `tool_call`
  (`ctx.sessionManager` is current through the tool-calling assistant
  message), § `ctx.modelRegistry` (`streamSimple`; `classify` is pi's own
  decision-model API, not this), § `pi.registerFlag`, § `pi.appendEntry`
- `pi-automode-classifier` 0.5.1 (MIT,
  https://github.com/deepu105/pi-automode-classifier): `automode.ts`
  (`buildSystemPrompt`, `STAGE1_INSTRUCTION`, `stage2Instruction`,
  `buildTranscript`, `parseVerdict` with `leading`, `denyMessage`),
  `core/llm.ts` (`decideWithLlm`, `transcriptItems`, `ownWords`)
- Claude Code: `claude auto-mode config`; the local classifier prompt in the
  binary ("You are a security monitor for autonomous AI coding agents.",
  used for sites other than the API's `safeguards`)

## Background
`FEAT-claude-auto-mode.md` gives calls on Claude models Claude Code's
server-side verdict. Other models get none, and its prompt, model and rules
are not configurable. This plan adds a classifier in the extension that
gives the same verdict for any model, with a configurable model and
thinking level, for the undecided calls that have no server verdict.

A pi package cannot be this classifier as a package: a `tool_call` handler
can block a call or do nothing, never allow it past later handlers
(`extensions.md` § Handler Composition). The classifier is a function in
the extension, called when Neovim reports a call undecided.

It follows Claude Code's local classifier:
- Rules from `claude auto-mode config` (the user's `autoMode` settings over
  Claude Code's defaults). `claude` on PATH is a requirement; the bridge's
  bundled Claude Code is a different install.
- The prompt frame of `pi-automode-classifier`'s `automode.ts`, a copy of
  Claude Code's local prompt; Claude Code does not print it. Used as a
  package dependency, not copied, so its fixes arrive with updates.
- A transcript of the user's own words and the agent's tool calls, with an
  outcome line under each finished call; the agent's prose and the tool
  results left out. User text is the user's own words only: the plugin's
  context blocks and pi's skill and file wrappers are cut (`ownWords`).
- Two stages: a filter stage that must open with its verdict tag, then a
  reasoning stage for what it does not clearly allow.
- A classifier error (model error, timeout, no verdict, an action that does
  not fit the model's window) gives no verdict, so the call prompts.

## Changes
1. `session_manager.lua`: the context blocks before the user's words go in
   one fixed tag that `ownWords` cuts (or that the classifier's transcript
   function cuts).
2. `pi/package.json`: `pi-automode-classifier` as a dependency.
3. `pi/agentic.ts`:
   - `pi.registerFlag("agentic-classifier-model")` and
     `"agentic-classifier-thinking"`, read in the handler; the model is
     `provider/id` split at the first `/`; unset is `ctx.model`.
   - The first `select` offers `classify` when the call has no `safeguard`.
     On a `classify` answer: rules from `claude auto-mode config` (once per
     process; a failure is kept and every classification is an error),
     `transcriptItems(getBranch(), …)` stopped at the action's
     `toolCallId`, then `decideWithLlm` with a 60 s timeout per stage.
     The result becomes a `safeguard` (`not_flagged`, or the cited rule)
     and a second `select` carries it, without `classify`; Neovim applies
     it as for a server verdict.
   - An aborted signal blocks the call with no second `select`. Any throw
     in this path gives no verdict.
   - Outcomes for the transcript come from `pi.appendEntry`, so they
     survive a restart: `ok`, `error`, `rejected-by-user`,
     `blocked-by-permissions`, `automode-blocked`, `automode-unavailable`.
     The Neovim answer says which reject it was.
4. `pi_permission.lua`, `permission_manager.lua`: an undecided call with no
   `ask` cause and no `safeguard` answers `classify` when
   `Config.permissions.classifier` is set; the causes stay stashed for the
   second request.
5. `config_default.lua`: `permissions.classifier = { model, thinking }`, or
   nil for none.
6. Tests: the transcript cut of context blocks and of the calls after the
   action; Lua: `classify` only with no `safeguard` and no `ask` cause.
7. Before step 3: a `decideWithLlm` call during a live bridge turn on a
   Claude model, from inside a `tool_call` handler: the main turn
   continues, the classifier's system prompt is its own (the bridge's
   `systemPromptPreset`), and no Claude Code session is left behind. A
   LiteLLM model the same way.

## Expected outcome
- On any model, an undecided call with no server verdict is classified by
  the configured model; the result is applied as in
  `FEAT-claude-auto-mode.md`.

## Non-goals
- Screening tool results for prompt injection.
- Classifying subagent handoffs.

## Open questions
