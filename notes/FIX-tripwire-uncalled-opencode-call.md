# Plan: Mark an opencode call that failed before it got its input as not run
Status: spec
Priority: P1
Depends:

## Relevant files
- `lua/agentic/acp/adapters/opencode_acp_adapter.lua` — `pre_run_rejection`, `OpenCodeACPAdapter:__handle_tool_call_update`
- `lua/agentic/acp/adapters/opencode_acp_adapter.test.lua` — the `shell_end` tests
- `lua/agentic/acp/canonical_tool_call.lua` — `status_word`; `ran`, `rejection_line` (read only)
- `lua/agentic/acp/canonical_tool_call.test.lua` — `status_word` tests
- `lua/agentic/ui/message_writer.lua` — `stamp_open_calls`, the `ended_as` field (read only)
- `lua/agentic/background_session.lua` — `_check_tripwire` (read only)
- `lua/agentic/skeptic/init.lua` — `_on_agent_destroyed` (read only)
- opencode v2.2.5: `packages/cli/src/acp/translate.ts` (`session.tool.input.started`, `session.tool.called`, `session.tool.failed`, `newTool`), `packages/cli/src/acp/tool.ts` (`errorToolUpdate`, `rawInput`), `packages/core/src/session/runner/step.ts` (`TOOLS_INTERRUPTED`), `packages/core/src/session/runner/publish-llm-event.ts` (`failTools`, `asRecord`)
- Skills: `implement`, `provider-system`, `subagents`

## Background
A background session's turn timeout sends `session/cancel`. If opencode is
streaming a tool call's input at that moment, it fails the call. The
tripwire then takes the failed call as one that ran without asking, and it
destroys the session.

Observed with opencode 2.2.5 (skeptic agent, 300 s `turn_timeout_ms`):

1. `tool_call`, `kind = "execute"`, `status = "pending"`, `title = "shell"`,
   `rawInput = { cwd = … }`. No `in_progress` update, no `command`.
2. Timeout, then `session/cancel`.
3. `tool_call_update`, `status = "failed"`,
   `rawOutput.error = "Tool execution interrupted"`, `rawInput = { cwd = … }`.
4. `CanonicalToolCall.ran` is true (failed, no rejection line).
   `decide("execute", { command = "shell" })` does not allow it, so
   `_check_tripwire` notifies "opencode ran a execute call without asking"
   and calls `destroy()`.

The call did not run. In opencode a tool runs only after
`session.tool.called`, which ACP sends as the `in_progress` update with the
tool's input. On an abort, opencode fails every unsettled tool with
`Tool execution interrupted` (`step.ts` calls `failUnsettledTools`, whose
default scope `"all"` reaches `failTools` in `publish-llm-event.ts`), also
tools whose input is still streaming. The failed update of such a tool
carries the empty input of `newTool` (`{}`); `tool.ts` `rawInput` adds `cwd`
for a shell tool.

Effect: `destroy()` passes no error, so `Skeptic:_on_agent_destroyed`
removes the agent and does not replace it. With one skeptic agent, the
skeptic turns off. The ERROR notification blames the opencode config,
which is false.

The rule must use the input, not the error text: a running tool that is
aborted gets the same text. The input rule needs no per-call state in the
shared adapter. A called tool's failed update carries the model's
arguments (`session.tool.called` sets the input). The rule is exact for the
guarded kinds: opencode's shell tool requires `command` and has no `cwd`
parameter, and its edit, write and patch tools require their arguments. A
call with an empty input fails validation and does not run either. The one
misclassification is a called tool that takes no arguments (kind `other`,
e.g. a no-argument MCP tool) and fails as it runs: its block shows
`Not run: …`. The tripwire does not guard that kind. An absent `rawInput`
does not match, so an unknown shape keeps today's fail-closed result.

## Changes
`lua/agentic/acp/adapters/opencode_acp_adapter.lua`:
- `local function pre_run_rejection(err, raw_input)`. New
  `@param raw_input table|nil` (the update's `rawInput`).
  - The two error-text matches stay first.
  - Then, when `raw_input` is a table with no key other than `cwd`,
    return `"Not run: "` and `err` joined to one line (as the scanner case).
  - Else nil.
  - Docstring: replace "only two error texts match" with the three cases.
    A failed call whose input is still empty was never called, so it did
    not run, whatever its error. Other errors still come from calls that
    ran.
- `__handle_tool_call_update`: pass `update.rawInput`. When the result is
  a `Not run: …` line and the error is `Tool execution interrupted`, also
  set `message.ended_as = "interrupted"`: the run's cancel ended the open
  call, which is what `ended_as` records.

`lua/agentic/acp/canonical_tool_call.lua`: in `status_word`, check
`ended_as` on a failed call before `rejection_line`, so this call shows
`interrupted`, not `rejected`. Update the docstring order. No path sets
both today: `stamp_open_calls` stamps only non-final calls, and every
rejection line is on a `failed` (final) update. The implementer confirms
this with `rg 'rejection =|ended_as ='` before the reorder. `ran` is
unchanged: the `Not run` line alone decides it.

`lua/agentic/acp/adapters/opencode_acp_adapter.test.lua`: give `shell_end`
an optional `raw_input` parameter, set as `rawInput`. New tests:
- failed, `rawInput = { cwd = "/x" }`, `Tool execution interrupted` →
  `rejection = "Not run: Tool execution interrupted"`,
  `ended_as = "interrupted"`, no body.
- failed non-shell call (its own tool call id, not `shell_end`'s
  `tc-shell`), `rawInput = {}`, `Provider did not return a tool result` →
  `rejection = "Not run: Provider did not return a tool result"`, no
  `ended_as`.
- failed, `rawInput = { command = "ls", cwd = "/x" }`,
  `Tool execution interrupted` → no rejection, body is the error.
- failed, `rawInput = { workdir = "/x" }` → no rejection: `workdir` is a
  model argument, so only `cwd` may be ignored.
- "keeps a failed call with another error as run" (no `rawInput`) stays.

`lua/agentic/acp/canonical_tool_call.test.lua`, `status_word`: a failed
call with both a rejection line and `ended_as = "interrupted"` →
`interrupted`; with a rejection line only → `rejected`.

## Expected outcome
- A cancel during a tool call's input stream no longer stops a background
  session or notifies the tripwire. The skeptic agent stays.
- The call's block shows `Not run: Tool execution interrupted` and no body.
  Its status word is `interrupted` (`CanonicalToolCall.status_word`), also
  in the session-resume icon and the tool timings; the history records
  `Result: Not run: Tool execution interrupted`.
- An opencode call that ran and then failed or was interrupted still counts
  as run, so the tripwire still stops on it.

## Non-goals
- A call cancelled after `in_progress` and before opencode's permission
  ask: still counts as run. Not observed; telling it apart needs state ACP
  does not carry.
- The status word of an uncalled call that failed for another reason
  (`Provider did not return a tool result`): it stays `rejected`. Not
  observed.
- The `turn_timeout_ms` default and why the turn took 300 s.
- The claude-agent-acp `Unexpected case` stderr notice.
- `notes/BUG-tripwire-display-path.md` (edit paths).

## Open questions
