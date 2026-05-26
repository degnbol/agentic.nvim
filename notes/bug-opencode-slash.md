# opencode slash command detection broken by context blocks

## Bug

Slash commands (`/compact`, `/model`, `/context`, etc.) sent via the ACP
interface to **opencode** as the provider were silently ignored — the command
was never dispatched (e.g. `/compact` never triggered `session.summarize`).

The plugin constructs the `session/prompt` payload as an array of text blocks:

```
[system_info, code_selection, files, diagnostics, user_input]
```

This order was chosen for **claude-agent-acp**, whose SDK extracts
`inputString` from the **last** `{type:"text"}` block and gates slash-command
parsing on `inputString.startsWith("/")`. Context before user text works fine
there.

**opencode** works differently. Its ACP agent (`acp/agent.ts:1467-1478`)
joins **all** text blocks together and checks if the combined text starts with
`/`:

```typescript
const text = parts
  .filter((p) => p.type === "text")
  .map((p) => p.text)
  .join("")
  .trim()

if (!text.startsWith("/")) return  // ──→ cmd is nil, falls to prose path
```

Since system info (`<environment_info>...`) comes first, the joined text never
starts with `/`, so the command path is never entered.

## Fix

`lua/agentic/session_manager.lua` — when the user input starts with `/`, skip
all context blocks (system info, selected code, attached files, diagnostics).

Only the user's text is sent:

```lua
local is_slash_command = input_text:match("^/")
```

This guard wraps each context block insertion. Slash commands are CLI
instructions to the provider (compact, model switch, rename, etc.) — they
don't need conversation context anyway.

## Affected providers

- **opencode** — broken (joins all text blocks)
- **claude-agent-acp** — unaffected (reads only the last text block)
- **codex-acp**, **gemini-acp**, **mistral-acp** — untested but assumed
  safe; the change is purely additive (skipping context) for slash inputs
