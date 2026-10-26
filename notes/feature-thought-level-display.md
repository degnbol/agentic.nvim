# Feature: show the thought level

The bridge sends a `thought_level` config option (`id = "effort"`) for the main
agent (`session-effort.js:94`) and for subagents (`acp-agent.js:7655-7663`).
`AgentConfigOptions` stores it (`agent_config_options.lua:101-102`), but no
window shows it.

## Open question
Where to show it. The header has little room, and the model is a body line
(`announce_model_loaded`, `session_manager.lua:2756`), not header context
(`:2650`). Recommendation: on the model line, `Loaded <name> · <id> · <effort>`,
and in a change notice, because the bridge sends the effort levels per model
(`session-effort.js`).

## Subagents
`PLAN-rfd-subagents.md` shows a subagent's config with the main agent's code,
so subagent transcripts get the same display.
