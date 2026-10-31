# Plan: show discovered-skill messages in the chat
Status: spec

## Relevant files
- `lua/agentic/acp/adapters/claude_transcript_records.lua` and `.test.lua` — module header, `M.records`, `FAILED_PREFIX` (precedent for a CLI-coupled constant)
- `lua/agentic/acp/adapters/claude_transcript_reader.lua` and `.test.lua` — `_read_line`, `anchor_of`, `_loaded_file_side_record`, `_notify_unreadable`
- `lua/agentic/acp/acp_client.lua` — `agentic.acp.SideRecord`, `drain_side_records`
- `lua/agentic/session_manager.lua` and `.test.lua` — `_drain_side_records`
- `lua/agentic/ui/message_writer.lua` and `.test.lua` — `write_hook_block`, `_resolve_anchor`, `_insert_after`, `_decorate_collapsed_region`, `_write_collapsed_region`
- `lua/agentic/glyphs.lua` — `Glyphs.KIND.skill`
- `.claude/skills/rendering/SKILL.md` — the time-order paragraph
- `.claude/rules/provider-specific.md`
- Skills: `provider-system`, `rendering`; global `acp` → `references/claude-agent.md`

## Background
When the agent works in a subdirectory with its own skills, the Claude Code CLI tells the model in a harness message. The ACP bridge forwards nothing, so this chat does not show it.

The CLI writes a `dynamic_skill` attachment to the transcript jsonl:

```json
{"type":"dynamic_skill","skillDir":"/abs/repo/.claude/skills","skillNames":["foo","bar"],"displayPath":".claude/skills"}
```

On each request, the CLI turns the attachment into this text (checked against the CLI in claude-agent-acp 0.97.0):

```
New skills discovered in <dir>, now available via the Skill tool:
- foo
- bar
```

- `<dir>` is `path.relative(projectRoot, skillDir)`. The writer sets `displayPath` to the same value, so the text is built from `displayPath`, not from `skillDir`. `skillDir` is absolute, and the session cwd is not always the project root.
- Before the CLI writes the record, it filters `skillNames` (no empty names, no control characters, no `<>`) and checks that `skillDir` is under the project root. It does not write a record with no names. The decoder checks only types and does not copy that filter.
- On each request the converter checks again: `skillDir` must still pass a path test and be under the current project root, and the names are filtered again. So the text the model gets can differ from the record, or be absent, when the project root changes (for example on a resume under another root) or the skill directory goes away. The decoder docstring states this limit.

Only the names reach the model. The body of a skill reaches the model only through a Skill tool call, which already renders as a Skill block.

The template is CLI wording, so it lives in the Claude decoder. The generic `SideRecord` carries finished rows, as hook records do.

The region shares `Glyphs.KIND.skill` with Skill tool calls. Both are about skills being made available to the model, and the region is dimmed and has no `###` head, so the two do not look the same.

## Changes
1. `acp_client.lua`: add the variant to the `SideRecord` alias.
   ```lua
   --- Skills the provider made available to the model during the session.
   --- @class agentic.acp.DiscoveredSkills : agentic.acp.Anchor
   --- @field title string The row announcing the skills
   --- @field body string[] One row per skill

   --- | { kind: "discovered_skills", discovered_skills: agentic.acp.DiscoveredSkills }
   ```
2. `claude_transcript_records.lua`:
   - Add `DISCOVERED_SKILLS_TITLE = "New skills discovered in %s, now available via the Skill tool:"`. Mark it as coupled to the CLI version, as `FAILED_PREFIX` is.
   - Add the class `agentic.acp.ClaudeDiscoveredSkillsRecord { kind: "discovered_skills", title: string, body: string[], timestamp?: string }`.
   - Add `local function discovered_skills_record(entry) -> ClaudeDiscoveredSkillsRecord|nil`. It returns nil unless `entry.type == "attachment"`, `attachment.type == "dynamic_skill"`, `displayPath` is a string and `skillNames` is a table with at least one string. Each string name becomes the row `- <name>`. The docstring states the project-root limit.
   - `M.records`: add a branch after `loaded_file_record`, and widen the return type.
   - Make the module header and the `M.records` docstring say "records" generically instead of listing the kinds.
3. `claude_transcript_reader.lua`:
   - In `_read_line`, turn the bare `else` (today every record that is not a hook goes to `_loaded_file_side_record`) into `elseif record.kind == "loaded_file"`, and add an `elseif record.kind == "discovered_skills"` branch. It calls `ClaudeTranscriptReader:_discovered_skills_side_record(record, place) -> agentic.acp.SideRecord`, which builds `anchor_of(place)` plus `title` and `body`.
   - Widen the record union in the `_pair_contexts` and `_read_line` annotations.
   - Make the `_notify_unreadable` message generic: "Claude transcript unreadable, activity it records outside ACP will not show: …".
4. `message_writer.lua`:
   - Rename `_write_collapsed_region` to `_append_collapsed_region`, so it does not read as a synonym of the new method. Update its callers and the mentions in `session_manager.lua` (comment), `.claude/skills/rendering/SKILL.md` § Body folding and `notes/PLAN-gutter-identity.md`.
   - Extract the place-or-append tail of `write_hook_block` into `MessageWriter:_place_collapsed_region(anchor, body, sign, opts)`, which writes a collapsed region under `anchor` when that is in the buffer and appends it otherwise. `anchor` is an `agentic.acp.Anchor`, and `body` is already wrapped, with the title as its first row when `opts.titled`. The thought-run flush and its comment move with it. It also takes over two rules from `write_hook_block`: an empty body writes nothing, and a titled region with one row under its title is left open. `write_hook_block` calls it and keeps only `open = block.failed`.
   - Add `MessageWriter:write_discovered_skills(skills)`, with `skills` an `agentic.acp.DiscoveredSkills`. It calls `_place_collapsed_region(skills, vim.list_extend({ skills.title }, skills.body), Glyphs.KIND.skill .. " ", { titled = true })`. The rows are not prose-wrapped, so each name stays whole. With two or more names the fold is closed and its foldtext leads with the title.
5. `session_manager.lua`, `_drain_side_records`: add an `elseif side.kind == "discovered_skills"` branch before the `side.hook.group` test, which calls `write_discovered_skills`. Make its docstring and the `ACPClient:drain_side_records` docstring generic.
6. `.claude/skills/rendering/SKILL.md`: in the time-order paragraph, replace "hook records and loaded files read from the CLI transcript" with "records read from the CLI transcript".
7. Tests (write them first):
   - `claude_transcript_records.test.lua`:
     - A `dynamic_skill` entry gives the title from `displayPath` and one `- name` row per name.
     - A namespaced name such as `foo.nvim:bar` passes through unchanged.
     - A missing `displayPath`, a non-table `skillNames` or an empty `skillNames` gives no record.
   - `claude_transcript_reader.test.lua`: the record takes the `tool_call_id` of the `tool_result` its chain ends at.
   - `session_manager.test.lua`: a drain of mixed kinds sends each to its writer method without error.
   - `message_writer.test.lua`:
     - The region goes under its tool block, with a closed fold and the skill sign.
     - A region with one name is open.
     - It is appended when the anchor is not in the buffer.
     - It goes below a hook region already placed at the same anchor.

## Expected outcome
- When the CLI tells the model about new skills, the chat shows a dimmed fold under the tool call that caused it, closed when it lists more than one skill. The title reads "New skills discovered in <dir>, …", and the body lists the skill names. Under CLI 0.97.0 and an unchanged project root, this is the text the model received.

## Non-goals
- Keeping the rows in the history: `PLAN-side-record-history.md` covers all side-record kinds.
- Subagent transcripts (`subagents/agent-*.jsonl`): the reader does not follow them.
- Resolving `skill_path` for a Skill call on a discovered skill. `ACPClient:session_roots` has no subdirectory roots, so such a call may render without a path; `skillDir` could add one.
- Other harness attachments (`date_change`, `task_reminder`, `skill_listing`, …): the same pattern, but each type needs its own decision.

## Open questions
None.
