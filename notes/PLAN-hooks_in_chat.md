# Plan: show hook failures and stray hook output in the chat
Status: spec

## Relevant files
- `lua/agentic/acp/adapters/claude_hook_records.lua` and `.test.lua` — module doc, `classify`, `NO_STDERR`, `KNOWN_OUTPUT_KEYS`, `is_known_output`, alias `agentic.acp.HookRecordGroup`, class `agentic.acp.HookRecord`
- `lua/agentic/hook_record_reader.lua` and `.test.lua` — `HookRecordReader:drain`, `_script_of`
- `lua/agentic/session_manager.lua` and `.test.lua` — `RENDERED_HOOK_GROUPS`, `SessionManager:_drain_hook_records`, describe `"_drain_hook_records"`
- `lua/agentic/ui/message_writer.lua` and `.test.lua` — `write_hook_block`, `_write_collapsed_region`, `_insert_collapsed_region`, `_decorate_collapsed_region`
- `lua/agentic/glyphs.lua` — `Glyphs.HOOK`
- `notes/PLAN-gutter-identity.md` — unit 6 and § "Glyph vocabulary"
- `notes/PLAN-adapter-hook-records.md` — moves the reader into the adapter (`claude_hook_record_reader.lua`) and the group alias into `acp_client.lua`. Either plan can land first; edit the files where they are.
- Skills: `rendering`

## Background
The CLI's transcript jsonl is read for hook records (the ACP bridge drops hook events). `_drain_hook_records` writes each record as a collapsed region under the tool call it names, with `Glyphs.HOOK` as the sign. The drain renders the groups `context` and `verbatim`, and drops `failure` and `unrecognised`.

**What a successful hook leaves** (CLI in claude-agent-acp 0.85.1, hooks docs § "Exit code 0"):
- Plain-text stdout on exit 0 becomes `hook_success.content`. No `hook_additional_context` record is written for it.
- On `SessionStart`, `UserPromptSubmit`, `UserPromptExpansion` and `PostModelSwitch` the model receives that `content` as context. The decoder must treat it as `context`, the same as `hook_additional_context`.
- On other events the model does not see it. A non-empty `content` there is a hook that writes to stdout by mistake. An example is the `m='`:help'` leak from `nvim-cmd-guard.sh`, since fixed. Showing it exposes the bug early. This is `unrecognised`.
- Stdout that looks like JSON but does not validate becomes a `hook_non_blocking_error`, not a `hook_success`.
- The current `unrecognised` group is keyed on stdout, not content. All 223 records in it are `Stop` runs of `completion-review.sh` with empty stdout and empty content. These are silent.

**What a failed hook leaves.**
- `hook_non_blocking_error` has several `stderr` shapes. Only `"Failed with non-blocking status code: <stderr>"` comes with a real process `exitCode`. Other shapes (parse errors, `Failed to run: …`, HTTP hooks, async hooks) have an `exitCode` that is forced, or that is an HTTP status. With no stderr the text is the placeholder `NO_STDERR`, which is a guard exiting 1 to mean "nothing to report", so it stays silent.
- Transcript counts (2026-10-12): 1320 of 1379 carry the placeholder. 59 carry real stderr, all exit 127: a missing script (`plan-reminder.sh`) and a missing shell function (`shell-guard.sh`).
- `hook_cancelled` is a timeout when `timedOut` is true. It is a user interrupt when `timedOut` is false. An interrupt is not a hook bug.

**The script name is lost on some rows.** `collapsed_region_lines` puts the script name in the fence's info string, and only the foldtext shows it. A one-row body has no fence, and an open fold conceals the fence. This affects 1505 of about 2028 injected-context records, which have one line. A failure without its script name tells the reader nothing.

## Changes
1. `claude_hook_records.lua`
   - `HookRecordGroup`: `unrecognised` now means "stdout the model did not see". `failure` now means "timed out, or exited non-zero with an error". Update the module doc to match.
   - Add `--- @field hook_name? string` to `HookRecord`, from `attachment.hookName`.
   - `classify` for `hook_success`:
     - empty `content`: `silent`;
     - event in `local STDOUT_CONTEXT_EVENTS = { SessionStart = true, UserPromptSubmit = true, UserPromptExpansion = true, PostModelSwitch = true }` (keyed on `hookEvent`): `context`;
     - otherwise: `unrecognised`.
     Delete `KNOWN_OUTPUT_KEYS` and `is_known_output`.
   - `classify` for `hook_cancelled`: `silent` when `timedOut` is false.
   - Add `local FAILED_PREFIX = "Failed with non-blocking status code: "` and build `NO_STDERR` from it.
   - Add the function below. `classify` calls it for both failure kinds.
     ```lua
     --- What happened to a failed hook run, without naming the script (the
     --- reader attributes it).
     --- @param attachment table `hook_non_blocking_error` or a timed-out `hook_cancelled`
     --- @return string[]
     local function failure_body(attachment)
     ```
     - Timeout: `{ "timed out after <timeoutMs / 1000> s" }`.
     - `stderr` starts with `FAILED_PREFIX`: `"exited <exitCode>"`, then the stderr lines with the prefix removed.
     - Any other `stderr`: its lines unchanged.
2. Reader `_script_of`: fall back to `record.hook_name` when no command is found.
3. `glyphs.lua`: add
   ```lua
   --- Identity of a hook run that failed: it timed out or exited non-zero with
   --- an error (`MessageWriter:write_hook_block`).
   Glyphs.HOOK_FAILED = "󰛣" -- nf-md-hook_off, U+F06E3
   ```
4. `message_writer.lua`
   - Add the class below. Change `write_hook_block(body, script, tool_call_id)` to `write_hook_block(block)`.
     ```lua
     --- @class agentic.ui.MessageWriter.HookBlock
     --- @field body string[] The hook's output, unwrapped
     --- @field script? string Basename of the script it came from
     --- @field tool_call_id? string The call the hook fired on
     --- @field failed? boolean The hook timed out or exited non-zero with an error
     ```
   - A failed block uses the sign `Glyphs.HOOK_FAILED .. " "` and is left open. Its reason must be readable without `zo`.
   - `_decorate_collapsed_region(bufnr, body_start, body_end, sign, source, open)`: when `source` is set, stamp it as end-of-line `virt_text` on the first body row, in the highlight the foldtext uses. This covers one-row bodies and open folds; a closed fold hides the row and shows the foldtext instead. When `open` is set, skip the `_queue_fold(body_start, false)`. Thread `source` and `open` through `_write_collapsed_region` and `_insert_collapsed_region`.
5. `session_manager.lua`: delete `RENDERED_HOOK_GROUPS` and its docstring. The reader returns only `context`, `unrecognised`, `failure` and `verbatim`, and all four render. `_drain_hook_records` calls `write_hook_block({ body, script, tool_call_id, failed = record.group == "failure" })`.
6. `notes/PLAN-gutter-identity.md`: in unit 6, mark failures and unrecognised output as covered by this plan, and remove "renders through `write_notice`". In § "Glyph vocabulary", mark 󰛣 as spent.
7. `notes/PLAN-adapter-hook-records.md` § Non-goals: remove the `RENDERED_HOOK_GROUPS` line if this plan lands first.
8. Tests
   - `claude_hook_records.test.lua`:
     - replace the four "surfaces …" `hook_success` cases with: empty content is silent; content on `UserPromptSubmit` is context; content on `PreToolUse` is unrecognised;
     - failures: a prefixed stderr gives `"exited 127"` and loses the prefix; an unprefixed stderr is kept as it is; a timeout names the seconds; an interrupted `hook_cancelled` is silent.
   - Reader test: a record with no command is named after its `hookName`.
   - `session_manager.test.lua`: replace "holds back the groups whose rendering is not built" with "marks a failure as failed" and "renders unrecognised output". The stub takes `block`.
   - `message_writer.test.lua`:
     - a failed block carries `HOOK_FAILED` and its fold stays open;
     - a one-row block shows its script as `virt_text`;
     - update the existing calls to the table form.

## Expected outcome
- A hook that times out, or exits non-zero with an error, shows as an open 󰛣 region under the call it fired on. The region shows the script name, then the exit code and stderr. Turn-boundary records show at the next drain.
- Plain stdout that the model received on the four context events shows as a 󰛢 row. Stray stdout on other events shows as a 󰛢 row too.
- Every hook row shows its script name, folded or not.
- No row shows for: a hook that exits non-zero without stderr, a hook interrupted by the user, or a successful hook with no output.

## Non-goals
- Persistence of hook rows: `notes/PLAN-hook-history.md`.
- An earlier drain on the bridge's PostToolUse callback update. The callback runs in the same PostToolUse batch as the user's hooks, so its arrival does not mean their records are on disk.
- Hook-blocked `UserPromptSubmit`/`Stop` text that arrives as model prose. claude-agent-acp 0.85.1 marks that chunk `_meta.claudeCode.kind = "informational"` with a `level`. To a client that advertises `clientCapabilities.session.notices`, it sends a `notice` session update instead. Use either one, not the `**Warning:**` text prefix. This is a separate feature, and it is not specific to hooks.
- Subagent transcripts.

## Open questions
None.
