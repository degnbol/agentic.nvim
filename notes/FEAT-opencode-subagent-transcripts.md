# Plan: opencode subagents in their own transcripts
Status: reviewed spec
Priority: P2
Depends: FIX-opencode-child-title-prefix.md

Implement after `FIX-opencode-child-title-prefix.md` (`tool_title`,
still needed: child updates keep the prefixed title).

## Relevant files
- `lua/agentic/acp/adapters/opencode_acp_adapter.lua`, `.test.lua`
- New `lua/agentic/acp/adapters/opencode_spawns.lua`, `.test.lua`
  (precedent: `claude_transcript_reader.lua`)
- `lua/agentic/acp/acp_client.lua` (`capability_meta`, `_handle_notification`,
  `__handle_session_update`, `__handle_request_permission`, `_children`,
  `subagent_record`, `unsubscribe`)
- `lua/agentic/subagents.lua` (`update`, `_open_agent`, `_agent_block`,
  `read_record`)
- `.claude/skills/subagents/SKILL.md` § Providers
- opencode v2.2.5 at `/tmp/opencode-src`: `packages/cli/src/acp/`
  `capabilities.ts`, `child.ts`, `translate.ts`, `turn.ts`, `permission.ts`,
  `replay.ts`, `tool.ts`; `packages/core/src/tool/plugin/subagent.ts`

## Background
A subagent's work arrives today on the parent session's stream
(`translate.ts` `route`): its chunks and tool calls, with `toolCallId`
prefixed `<childId>:`, `title` prefixed `<child title>: ` and
`_meta["opencode/child-session"] = {id, parentID, depth, title?}`. The
plugin writes all of it into the main chat. Nothing marks a child's start
or end on that stream.

With `clientCapabilities._meta["opencode/child-session-updates"] = true`
(`capabilities.ts`) opencode instead sends each child event as an
extension notification, method `opencode/session/child_update` (sent
literally, like `session/update`), params
`{rootSessionId, childSessionId, parentSessionId, depth, title?}` plus
either `{type: "status", status, error?}` — `created`, then `running`, then
one of `completed`, `failed` (`error: {type, message}`), `interrupted`; a
child that runs again in the turn sends `running` again — or
`{type: "update", update}`, the projected session update. `title` is
omitted when the description is empty. For a child created in a turn the
client prompted, the opt-in is what keeps its events after that turn ends:
`turn.ts` drops plain session updates once `turn.background`, but still
sends `ChildUpdate`s. A child resumed in a later turn sends no
`session.created`, so its events are dropped either way (`translate.ts`
`fold`).

Permission requests for a child's calls keep `sessionId` = the root and
carry the child `_meta` (`permission.ts` `ask`). With a tool source their
`toolCallId` is the child call's; without one it is
`<child>:<permission id>`, which no `tool_call` announced, so
`claim_tool_call` cannot find the owner by id.

The link from the parent's `subagent` call to its child: the child is
created with `title = input.description` and `parentID` = the calling
session (`subagent.ts`). The call's terminal update carries
`rawOutput.metadata = {sessionID, status}` once the child exists
(`tool.ts`; `translate.ts` keeps the progress metadata for `failed`); a
call that fails before `sessions.create` has `metadata = {}`. No earlier
update names the child. A resume (`rawInput.sessionID`) creates no child
and sends no `created`.

`session/load` replay (`replay.ts`) sends no child sessions but re-sends
the parent's `subagent` calls with their terminal metadata; the plugin's
own session file restores transcripts (`Subagents:add_history_transcripts`).

## Changes

### `acp_client.lua`
- New override point, default false:

  ```lua
  --- Handle a provider's extension notification. Returns false for a method
  --- the adapter does not know, which `_handle_notification` reports.
  --- @protected
  --- @param method string
  --- @param params table
  --- @return boolean handled
  function ACPClient:__handle_ext_notification(method, params)
  ```

  `_handle_notification` calls it before its unknown-method notice.

### `opencode_spawns.lua` (new)
`agentic.acp.OpenCodeSpawns`, one instance per root session: the
`subagent` calls of that root's sessions and the children they spawned.

```lua
--- @param session_id string Session that made the call (root or a child)
--- @param tool_call_id string
--- @param input { agent: string, description: string, background?: boolean }
function OpenCodeSpawns:add(session_id, tool_call_id, input)

--- Link a created child to the one unlinked spawn of `parent_id` whose
--- description is `title`; nil when none or several match, or `title` is nil.
--- @return string|nil tool_call_id
function OpenCodeSpawns:on_created(parent_id, child_id, title)

--- Link the spawn to `child_id` when given, then forget the pending spawn.
--- @param child_id string|nil From `rawOutput.metadata.sessionID`
function OpenCodeSpawns:on_ended(tool_call_id, child_id)

--- @return agentic.acp.SubagentRecord|nil record Nil while unlinked
function OpenCodeSpawns:record(child_id)
```

`record` gives `{agent_type = agent, background, task_id = tool_call_id}`.
Links outlive `on_ended`; pending spawns do not.

### `opencode_acp_adapter.lua`
- `new` override (as `ClaudeAgentACPAdapter:new`): `self._spawns = {}`,
  root id → `OpenCodeSpawns`. `unsubscribe` override drops the root's entry.
- `capability_meta()`: `{ ["opencode/child-session-updates"] = true }`.
- Spawn recording, in the tool-call hooks: a `kind == "think"` call with
  full `rawInput` calls `add` with the session id the hook received, unless
  `rawInput.sessionID` is set or the root is loading
  (`_loading_sessions`). Its `completed`/`failed` update calls `on_ended`
  with `rawOutput.metadata.sessionID`.
- `__handle_ext_notification` for `opencode/session/child_update`:
  - `self._children[childSessionId] = rootSessionId` when the root is
    subscribed. This is the record; the synthesised `subagent_update` below
    needs no `_children` write of its own.
  - `status`: for `created`, `on_created(parentSessionId, childSessionId,
    title)` first, then dispatch through `__handle_session_update` with
    `sessionId = parentSessionId` and a synthesised
    `subagent_update {sessionId = childSessionId, title, state}`, so
    `_open_agent`'s `read_record` finds the record (true `background`) at
    once:

    | opencode status | `state` |
    | --- | --- |
    | `created` | absent (announce only) |
    | `running` | `{state = "running"}` |
    | `completed` | `{state = "idle", stopReason = "end_turn"}` |
    | `interrupted` | `{state = "idle", stopReason = "cancelled"}` |
    | `failed` | `{state = "idle", stopReason = "error"}`, plus `error = {code = 0, message}` only when opencode sent `error` |

  - `update`: dispatch through `__handle_session_update` with
    `sessionId = childSessionId` and the update unchanged.
  - Unknown `type` or `status`: `Logger.debug`, return true.
- `subagent_record(session_id, child_id)`: the root's `OpenCodeSpawns:record`.
  An unlinked child's record stays nil until the spawn's terminal update
  names it; `read_record` retries on each of the child's `tool_call`s.
- The parent's `subagent` call takes the shape claude-agent-acp gives an
  Agent call (`launchReply` and `unexposedControlFallback` in its
  `native-subagents.js`), so one
  launch shows the `Subagents` block, a `task` row and a one-line reply:
  - Its notifications are held, not passed on. These pass on the held
    `tool_call` and every later update instead (the call's own block, as the
    bridge's `unexposedControlFallback`): a `request_permission` naming it,
    and a terminal update of a call with no linked child (a failure before
    the child exists, or a resume: `rawInput.sessionID` set, no `created`).
  - At the link: a `session_message` `{messageId = <call id>,
    senderSessionId = <caller>, recipientSessionId = <child>, content =
    prompt}`, dispatched once on each of the two sessions, after the
    synthesised `subagent_update` that announces the child (as the bridge
    publishes the prompt after the announce): `_message_info` needs the
    agent announced, and `Subagents:message` drops a view on an unknown
    child session. A link made only by `on_ended` writes this row after the
    child's run.
  - At a `completed` terminal update with a linked child, unless a
    permission request passed the call on (its own block shows the
    result): a `session_message` `{messageId = <call id> .. ":reply",
    senderSessionId = <child>, recipientSessionId = <caller>, content =
    the update's text content}` on the caller's session. A foreground
    result's `<subagent sessionID=… state="completed">` wrapper
    (`subagent.ts`) is stripped to its inner text. A background call
    completes at launch with its own text, so on opencode its block settles
    then, where claude's settles at the child's end. A `failed` one with a
    child sends nothing: the child's end settles the block.
  - During load, a held call whose terminal metadata names a child emits
    the same `task` and `:reply` messages, without `add`: the replay tail
    matches them against the session file's `message:<id>` entries, and a
    launch in the tail, or a load with no file, still shows.
- `launch_reply_task(update)`: `ACPClient.strip_reply_suffix(messageId)`.
- `__handle_request_permission` override: when
  `toolCall._meta["opencode/child-session"].id` is set, use it as
  `request.sessionId`, then the base. The base resolves the root through
  `_children`, and the subscriber's `claim_tool_call` gets the child as
  source.
- Types in the adapter: `agentic.acp.OpenCodeChildUpdate` for the ext
  params.

### `subagents` SKILL.md
- § Providers: add that opencode reaches `Subagents` through
  `opencode/session/child_update` (adapter-synthesised `subagent_update`),
  linked to its spawning call by a unique description match, else by the
  call's `rawOutput.metadata.sessionID`. Drop "opencode … subagent calls
  are plain `SubAgent` blocks".

### Tests
- `opencode_spawns.test.lua`: unique match links; two pending spawns with
  the same description link neither; a spawn of another parent does not
  match; nil title links nothing; `on_ended` with a child id links,
  without one drops the spawn; `record` is nil before the link.
- `opencode_acp_adapter.test.lua`: each status maps to its
  `subagent_update` on the parent session (`failed` without `error` has no
  `error`); `created` links before the dispatch, so the record is present
  at dispatch; an `update` event reaches the subscriber with the child as
  `source_session_id`; `_children` records the child; a spawn with
  `rawInput.sessionID` or during load is not recorded; a child permission
  request is passed on with the child's session id; a linked `subagent`
  call reaches no subscriber as a tool call, sends the `task` message on
  both sessions after the child's announce and the `:reply` message (the
  wrapper stripped) at `completed`; a permission request, a child-less
  `failed` and a completed resume pass the held call on; a call a
  permission request passed on sends no `:reply`; during load a linked call
  emits the `task` and `:reply` messages.
- `acp_client.test.lua`: an unknown ext method still reaches the notice; a
  handled one does not.

## Expected outcome
On opencode, a subagent's messages, thoughts, tool calls and permission
prompts show in its own transcript, opened at its start and ended with its
end state, background subagents included after the parent's turn ends.

## Non-goals
- Child sessions on `session/load` replay (opencode sends none).
- A child resumed in a later turn (opencode drops its events).
- Messaging a background subagent (`subagent_message_instruction`): the
  subagent tool resumes a child by `sessionID`, a separate feature.
- `opencode/session/child_update` elicitation (`toolCallSent`): the plugin
  advertises no elicitation.

## Open questions
None.
