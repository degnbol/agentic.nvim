# Plan: show Stop hook feedback in the chat
Status: reviewed spec

## Relevant files
- `lua/agentic/acp/adapters/claude_hook_records.lua` and `.test.lua` — module doc, `M.decode`, `classify`, `body_lines`
- `lua/agentic/hook_record_reader.lua` and `.test.lua` — `HookRecordReader:drain`
- `lua/agentic/session_manager.lua` and `.test.lua` — `_on_agent_chunk` (`filter_chunk`, `starts_response`), `_drain_hook_records`, `_finalize_turn`; the response-boundary describe block in the test
- `lua/agentic/ui/message_writer.lua` — `write_hook_block` docstring
- `notes/PLAN-hooks_in_chat.md`, `notes/PLAN-adapter-hook-records.md` — touch the same files. Any order; edit the files where they are.
- Skills: `rendering`, `provider-system`

## Background
A Stop hook that exits 2 sends its stderr to the model, and the model takes one more turn to reply to it. In the chat the user sees the reply but not the text it replies to. Example: `completion-review.sh` in session `07d29e41`.

The text does not reach the plugin on any path:
- The bridge (claude-agent-acp) sends no update for it. Its `informational` notice is for a hook that stops the turn, not for one that continues it.
- `claude_hook_records.decode` reads only `type = "attachment"` lines. The CLI writes Stop feedback to two other lines:
  - `{"type":"system","subtype":"stop_hook_summary","hookErrors":[…],"toolUseID":"<uuid>",…}`.
  - `{"type":"user","isMeta":true,"message":{"content":"Stop hook feedback:\n[<command>]: <stderr>…"}}`, all blocking entries joined into one message.

Read `stop_hook_summary.hookErrors`. A blocking hook's entry has the form `[<command>]: <stderr>`, one per hook, so each hook gets its own block and script name. Entries without that prefix are non-blocking errors (in all transcripts: only the `NO_STDERR` placeholder). The `hook_non_blocking_error` attachment already carries those, so drop them here.

The text is context the model received, so it belongs in the `context` group: a closed 󰛢 region like the other injected context.

Placement: the reply comes in the same prompt turn, as a new response (`starts_response`). The turn-end drain would put the block after the reply. Draining on `starts_response` puts it before the reply text. The CLI writes the summary before the API request for the reply (`07d29e41…jsonl`: summary line 1558 at `18:03:23.831`, `api-request` at `23.886`, reply at `26.113`). If a record is late, the turn-end drain still shows it, after the reply.

## Changes
1. `claude_hook_records.lua`
   - Module doc: one line gives zero or more records, not one.
   - `M.decode(line)` returns `agentic.acp.HookRecord[]`: JSON parse and dispatch only. A blank line gives `{}`; an unparsable line gives `{ verbatim }`.
   - `local function attachment_record(entry)` → `agentic.acp.HookRecord|nil`: the current body of `decode` after the parse.
   - `local function split_command(text)` → `string|nil command, string body`: matches `^%[(.-)%]: (.*)$` (`.` keeps a multi-line stderr).
   - `local function stop_feedback_records(entry)` → `agentic.acp.HookRecord[]`: for `entry.type == "system"` and `entry.subtype == "stop_hook_summary"`, one `context` record per string `hookErrors` entry that `split_command` matches. Fields: `command`, `body = body_lines(body)`, `uuid`, `parent_uuid`, `timestamp`. No `tool_call_id`: `toolUseID` here is not a `toolu_` id.
2. `hook_record_reader.lua`: loop over the list that `decode` returns. Records from one summary share a `uuid`; index `_commands` only for attachment records, not summary records.
3. `session_manager.lua`
   - `_on_agent_chunk`, main-writer branch: when `starts_response` and not `self._loading`, call `self:_drain_hook_records()` before `write_message_chunk`. The subagent branch does not drain: subagent hooks write to another transcript.
   - `_finalize_turn` comment: it is no longer the only drain that appends records naming no tool call.
4. `message_writer.lua`: `write_hook_block` docstring, the claim that no drain trigger can place unanchored records by buffer position: reword for the response-start drain.
5. Tests
   - `claude_hook_records.test.lua`: two prefixed `hookErrors` give two `context` records with commands and bodies; an empty `hookErrors` gives none; an unprefixed entry is dropped; a non-string entry is dropped; existing cases use the list form.
   - Reader test: summary records do not enter `_commands`.
   - `session_manager.test.lua`: stub `_drain_hook_records` in the existing response-boundary fixture. New: a main chunk with `starts_response` drains before it is written; a subagent chunk does not; no drain while `_loading`.

## Expected outcome
- When a Stop hook exits 2, a closed 󰛢 region named after the script shows above the text of the agent's reply. If the reply starts with thinking, the region is between the thinking and the text.
- Other records that name no tool call (`SessionStart`, `UserPromptSubmit` context) also move from after the reply to above its text.

## Non-goals
- Edit-tracking accuracy and what `completion-review.sh` reports: `~/dotfiles/config/claude/hooks/TODO.md`.
- A drain on the first thought chunk of a response. Thought chunks have no response-boundary verdict.
- `SubagentStop` feedback: subagent transcripts are not followed.
- Persistence of hook rows: `notes/PLAN-hook-history.md`.

## Open questions
None.
