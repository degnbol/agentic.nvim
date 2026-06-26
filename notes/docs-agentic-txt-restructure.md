# Plan: document the `permissions` table in `doc/agentic.txt` §4.6

The only open item from the original multi-finding review. The others are
closed: body renumber (dup `9.`) and the `@zed-industries`→`@agentclientprotocol`
package name are fixed; §7's stale split-set / pattern-source facts were
resolved when §7 was rewritten; the issue-number and tag-convention findings
were no-ops.

## Open — §4.6 PERMISSIONS coverage gap

§4.6 (`doc/agentic.txt`, currently lines 191–202) documents only
`auto_approve_compound_commands` and `auto_approve_read_only_tools`. The
`permissions` table (`config_default.lua:455-465`) and its sibling
`auto_approve_trust_scope` (`:467`) are undocumented. Add entries, matching the
style of the existing §4.6 option blocks:

| Option | Type | Default |
| --- | --- | --- |
| `permissions.use_plugin_defaults` | boolean | `true` |
| `permissions.use_claude_settings` | boolean | `true` |
| `permissions.auto_approve` | `"allow"`\|`"read-only"`\|`nil` | `"allow"` |
| `permissions.read_only` | string[] (`Bash(...)` globs) | `{}` |
| `permissions.safe_write` | string[] | `{}` |
| `permissions.deny` | string[] | `{}` |
| `permissions.ask` | string[] | `{}` |
| `permissions.structured` | cmd-keyed table | `{}` |
| `permissions.highlight_unapproved` | boolean | `true` |
| `auto_approve_trust_scope` | boolean | `true` |

Semantics (from `config_default.lua:443-453` annotations, `permission_rules.lua`):
- `auto_approve = "allow"` → `read_only` ∪ `safe_write` auto-approved; `"read-only"`
  → only `read_only`; `nil` → none (deny/ask still respected).
- `deny`/`ask` override allow.
- `structured` deep-merges over the bundled `permissions.json`; a cmd key
  replaces that command's kind-arrays wholesale, `vim.NIL` disables a bundled
  entry. Already described prose-side in §7 — cross-reference, don't restate.
- `auto_approve_trust_scope` gates the `/trust` per-session scope check.

Tag style (verified convention in this file): section/sub-section tags use
hyphens, **option tags mirror the literal Lua key with underscores**. New tags:
- `*agentic-config-permissions-tbl*` (table anchor — hyphen, like
  `*agentic-config-session-restore*`)
- `*agentic-config-auto_approve_trust_scope*` (option — underscores)

Cross-reference `|agentic-compound-commands|` for how the patterns are consumed.
Follow `.claude/rules/docs.md` (what it does, not "useful for X") and don't
restate the matching algorithm — that lives in §7 and the `permissions` skill.

## Validation
- ToC (lines 32–43) needs no change — §4.6 keeps its number.
- After editing: `rg -o '\*agentic-[a-z_-]+\*' doc/agentic.txt` — confirm the two
  new tags appear once each, nothing else altered.
- Tag right-alignment: new option tags end at the same column as siblings.
