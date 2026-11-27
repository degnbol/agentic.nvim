# Idea: slash command parity with the Claude Code TUI

Ordered by value-to-effort.

## Already works — undocumented

Verified via a live `available_commands_update` probe of claude-agent-acp:
these commands forward through and the plugin does not intercept them,
so typing them in the input buffer runs the TUI flow via the LLM.

- **`/init`** — generates a project `CLAUDE.md`.
- **`/review`** — pull-request review.
- **`/security-review`** — security review of pending changes.
- **`/compact`**, **`/extra-usage`**, **`/insights`**,
  **`/team-onboarding`**, **`/heapdump`** — all forwarded.

## Maybe

- **PDF attachments**: the plugin supports image paste (see `image_paste`
  config). PDF support depends on provider capability advertised through
  ACP.
- **Background jobs**: `IDEA-background-processes-window.md`.

## Blocked upstream or out of scope

- **`/permissions`**: no ACP surface for reading or writing persistent
  rules. Users edit `settings.json` directly.
- **`/cost`, `/login`, `/logout`**: explicitly filtered out by the bridge
  (`UNSUPPORTED_COMMANDS` in `getAvailableSlashCommands`).
- **`/status`, `/stats`, `/usage`, `/doctor`, `/mcp`, `/agents`,
  `/skills`, `/config`, `/bug`, `/memory`, `/hooks`, `/bashes`,
  `/pr-comments`, `/vim`, `/ide`**: not advertised by the bridge at all
  (verified absent from `available_commands_update`). These rely on TUI
  interactive I/O that doesn't map to the ACP chat stream. The session
  info panel (`:h agentic-info-panel`) covers the runtime-state subset.
- **`/diff`, `/teleport`**: provider-level features
  or conversation-state primitives not exposed through ACP.
