# Idea: background processes window

A panel listing currently-running background tool calls (Bash with
`run_in_background: true`, auto-backgrounded long bashes, web fetches still
in flight, etc.) with status, elapsed time, command/argument, and a kill
keymap.

Provider-agnostic — track by watching the ACP `tool_call` /
`tool_call_update` stream rather than asking the provider, since the SDK
task registry is internal and not exposed via ACP.

Motivation: Claude legitimately forgets about running `local_bash` shells
(post-compact re-injection in claude-agent-acp filters `local_agent` only —
see claude skill `references/internals.md` § "Background tasks"), and a
`nvim --headless` orphaned by a hung command leaves the harness showing
"generating" indefinitely with no surface telling the user *what* is still
running. The window also lets the user terminate stuck procs without
dropping to a shell.
