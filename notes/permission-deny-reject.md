# Remaining: remove the `auto_approve_compound_commands` switch

The deny-reject feature is implemented: a structured/glob `deny` now rejects a
shell command immediately (no prompt) via `PermissionRules.should_auto_reject`,
wired into `PermissionManager._try_auto_approve` before `should_auto_approve`.
`ask` still only withholds approval and prompts. Concrete-only deny matching
(`PermissionStructured.deny_leaf`) and the audit of bundled `deny` entries
(in-place edits `sed -i`/`mlr -I`/`ruff --fix`/`stylua --replace`/`sort -o`
moved to `ask`; `rm -f`/`rm -rf` added as `deny`) shipped with it.

## What's left

The parse-tree classification is strictly more precise than glob matching and is
the canonical mechanism, not an optional supplement. The
`auto_approve_compound_commands` switch should not exist as a toggle around it:

- **Remove the switch** — always run the parse-tree classification. A master
  off-switch only adds prompts and removes the deny-reject safety layer, with
  zero safety upside (the provider's SDK still runs its own permission check
  underneath). The layer only ever turns SDK `ask`s into approvals for
  provably-safe commands or rejections for provably-dangerous ones — both
  strictly better than the prompt you'd get without it. "I want to confirm every
  shell command" is already achievable by leaving the allow rules empty.

This touches `config_default.lua`, `permission_manager.lua`, README,
`doc/agentic.txt`, and the `permissions` skill. While the switch exists, a user
who sets `auto_approve_compound_commands = false` loses deny-reject (a deny
command falls back to a prompt — strictly no worse than before the feature).
That is acceptable: respect the explicit switch, build no separate always-on
gate for deny in the interim (it would just be churn to merge away when the
switch goes).

## Out of scope

- Tri-state refactor of the universal approve `walk` (rejected — too invasive;
  reject is a separate existential pass instead).
- Changing the user's manual response keys (`1`-`5`, `<C-c>`).
- Persistent rule storage (no ACP method exists; unchanged).
- Extending auto-allow/reject classification beyond zsh (see TODO § "Auto-allow
  non-zsh").
