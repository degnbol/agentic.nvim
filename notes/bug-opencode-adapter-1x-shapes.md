# Bug: the opencode adapter matches opencode 1.x tool shapes

Affects opencode 2.x (measured on 2.2.5). Several checks in
`lua/agentic/acp/adapters/opencode_acp_adapter.lua` never match:

- Subagent calls are not marked `SubAgent`. 2.x sends `title: "subagent"`,
  `kind: "think"`, `rawInput: {agent, description, prompt, model?,
  background?}`. The adapter checks `title == "task"` (`__handle_tool_call`)
  and `rawInput.subagent_type` (`__handle_tool_call_update` and its argument
  branch). Neither occurs in 2.x, so a subagent call renders as a plain
  `think` block with no `agent: description` head and no prompt body.
- `title == "list"` and `"google_search"`: 2.x has no such tools.
- Edit, write and read input uses `path`; the adapter's argument branch reads
  `rawInput.filePath`, so these heads likely fall through to a later branch
  or stay at the title.
- The comment on the completed-update diff names `"Wrote file
  successfully."`; 2.x sends e.g. `Edited a.txt (1 replacement)`. The code
  (`find_content_diff`) is still right; only the comment is stale.

2.x wire shapes: `acp` skill `references/opencode.md` (§ Tools, § Edit tool
calls). Raw logs of an edit and a read outside cwd:
`/tmp/opencode-inline-test/edit.jsonl`, `extread.jsonl` (lost on reboot).

Also update `provider-system` § "opencode kind remapping": its `task`,
`list` and `google_search` rows describe the dead checks.

Reproduce: adapter test feeding a 2.x `tool_call` with `title = "subagent"`,
`kind = "think"`, `rawInput = {agent = "general", description = "d", prompt
= "p"}`; expect kind `SubAgent`. Same for an `edit` update with
`rawInput.path`; expect the path as argument.
