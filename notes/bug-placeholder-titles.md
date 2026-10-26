# Bug: tool calls show placeholder text

The user does not want any placeholder text in a tool call's heading. While a tool's input is still streaming, the heading should stay empty until the real value arrives.

## Observed in code
- The Claude bridge returns a fallback title whenever the input field a title needs is still undefined: `Terminal`, `Task` (plus ` (<level> effort)`), `Preparing file…`, `Read File`, `Edit`, `grep`, `Find`, `Load skill`, `Fetch`, `Web search`, `Unknown Tool`, `Create task`, `Update task`, `Edit notebook`, and more (`~/.local/share/npm/lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/tool-calls/reporters/*.js`, the `title:` lines).
- The plugin blanks only the titles in `ClaudeUtils.PLACEHOLDER_TITLES` (`lua/agentic/acp/adapters/claude_utils.lua:340-369`). The list drifts with each bridge version: `Task (high effort)`, `Create task`, `Update task` and `Edit notebook` are missing.
- The bridge title reaches the heading through `acp_client.lua:802` (`argument = update.title`) and the Bash fallback at `claude_agent_acp_adapter.lua:432-435`.
- The plugin writes its own placeholders: `"unknown skill"` (`claude_agent_acp_adapter.lua:349`), `"unknown fetch"` (`acp_client.lua:684-686`), `"default"` and empty fields in the SubAgent head (`claude_agent_acp_adapter.lua:417-422`).

## Expected
No placeholder text, from the bridge or the plugin. Prefer a rule that cannot drift (e.g. the Claude adapter builds headings from `rawInput` only, as `ClaudeUtils.tool_head` already does for most tools) over a longer list of strings.

## Related
`provider-system` and `rendering` skills; audit `notes/audit-edge-cases.md` items 3.18, 3.21 and 0.7.
