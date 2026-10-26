---
paths: "lua/**/*.lua,hooks/**"
---

# Provider-specific code

Code for one provider lives in that provider's own files or folders, e.g.
`lua/agentic/acp/adapters/claude_*.lua`. General code reaches it only through
an `if`-gate on the provider.
