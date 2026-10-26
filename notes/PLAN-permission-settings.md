# Plan: one setting for whole-tool approval, one for the execute tier
Status: reviewed spec

## Relevant files
- `lua/agentic/config_default.lua:472-505`: `auto_approve_read_only_tools`, `auto_approve_skills`, `permissions` (with `auto_approve`, `default_grant`), `auto_approve_grant`
- `lua/agentic/ui/permission_manager.lua`: `PermissionDecider` alias `:30`, `READ_ONLY_KINDS` `:96`, `decide` docstring `:325-326`, its kind branches `:347-353`, grant check `:391-394`, tracker-kind fallback `:417-426`, `_bash_effects_clear` `:572`, `:592`
- `lua/agentic/session_manager.lua`: `_apply_default_grants` `:1704-1709`, `/grant` guard `:1817-1822`
- `lua/agentic/utils/permission_structured.lua`: `PermAutoApprove` alias `:29`, `validate_auto_approve` `:885-900`
- `lua/agentic/utils/permission_rules.lua`: `WalkCtx` alias `:528`, its `auto_approve` readers `:1281`, `:1353`, its writer `:2785`; `Config.permissions.auto_approve` read `:2754`
- `lua/agentic/init.lua:254`
- Tests: `permission_manager.test.lua` (`:143-154`, `:498-507`, `:1528-1537`, `:1756`, `:1808-1821`, `:1873-1876`), `permission_rules.test.lua` (`:607-613`, `:780`, `:797`, `:1640`, `:1969`, `:1978`, `:4357`), `session_manager.test.lua` (`:4240-4242`, `:4280`, `:4336-4341`, `:4414-4419`)
- `doc/agentic.txt`: `:243-252`, `:261`, `:275-280`, `:730-731`, `:785`, `:816-819`
- Skill `permissions`: `SKILL.md` `:59`, `:62`, `:84`, `:177`, `:274`; `references/parsing.md:260`
- Skill `provider-system`: `SKILL.md:381` (names `READ_ONLY_KINDS`)
- `README.md:50`
- Related: `notes/PLAN-claude-allowed-tools.md` (its `allowed_tools` approves inside the CLI, before these settings)

## Background
Four settings decide what runs without a prompt:

| Setting | Gates |
|---|---|
| `auto_approve_read_only_tools` | Tool calls of ACP kind `read` or `search` |
| `auto_approve_skills` | Tool calls of kind `skill` |
| `permissions.auto_approve` | How far the shell classifier may approve an execute call (`"read_only"`, `"safe_write"`, nil) |
| `auto_approve_grant` | Grant scopes: `default_grant` at session start and the `/grant` command |

The first two are the same kind of setting: approve a whole tool kind. One list replaces both. It also works for any provider, because the check only sees the ACP kind.

The name `permissions.auto_approve` doesn't say that it only covers execute calls. Calling it `auto_approve_tier` makes clear that it is the classifier's tier.

The two kinds of setting stay separate. A user can trust the Grep tool without trusting the plugin's shell classifier, and the reverse.

`auto_approve_grant` is redundant. Without default grants and without `/grant`, there are no grant scopes, so every grant check finds nothing (`#self._grant_scopes > 0` at `:392`, and the scope match in `_bash_effects_clear`). `default_grant = {}` is the off switch.

## Changes

### `lua/agentic/config_default.lua`
- Delete `auto_approve_read_only_tools`, `auto_approve_skills` and `auto_approve_grant`.
- In `permissions`:
  - add `auto_approve_kinds = { "read", "search", "skill" }`, with the field doc "ACP tool kinds approved without a prompt, whatever the target path";
  - rename `auto_approve` to `auto_approve_tier`, and update its `@field` doc to say "execute calls";
  - in the `default_grant` field doc, replace "Requires `auto_approve_grant`" with "`{}` starts a session without grants".
- Update the `highlight_unapproved` field doc: "independent of the auto_approve switches" becomes "independent of `auto_approve_tier`".

### `lua/agentic/ui/permission_manager.lua`
- Delete `READ_ONLY_KINDS`.
- `decide`: delete the two branches at `:347-353`. Add one check after the settings.json deny step (`:355-361`) and the always-cache lookup (`:363-371`), so deny rules and "Reject always" win over a listed kind:
  ```lua
  local listed = vim.tbl_contains(Config.permissions.auto_approve_kinds, function(k)
      return AcpKind.normalise(k) == kind_lc
  end, { predicate = true })
  if listed then
      return "allow", { kind_lc }
  end
  ```
  Entries are normalised like the incoming kind, so `"Read"` matches. The decider is now the kind itself: add `| agentic.acp.ToolKind` to the `agentic.PermissionDecider` alias, and drop `"skill"` as its own decider word. `"read-only"` stays: the shell classifier's `read_only` source still produces it (`decider_word`, `:315`).
- Update the `decide` docstring checks 1 and 2 (`:325-326`) to one check against `auto_approve_kinds`.
- Tracker-kind fallback (`:424`): recover the tracker's kind when it is in `auto_approve_kinds`. This replaces the fixed `READ_ONLY_KINDS`/`"skill"` test. Update the comment at `:417-419`: Claude's Skill requests also arrive with kind `"other"`, and only the tracker has the minted `"Skill"` kind.
- Remove the `Config.auto_approve_grant` guards at `:392` and `:592`, and update the `_bash_effects_clear` docstring (`:572`).

### `lua/agentic/session_manager.lua`
- `_apply_default_grants`: remove the guard and its docstring clause.
- `/grant` handler: remove the "/grant is disabled" branch (`:1817-1822`).

### `lua/agentic/utils/permission_structured.lua`, `permission_rules.lua`, `init.lua`
- Rename `agentic.PermAutoApprove` to `agentic.PermAutoApproveTier`, and `validate_auto_approve` to `validate_auto_approve_tier`. Update the warning text to say `permissions.auto_approve_tier`.
- Rename the `WalkCtx` field `auto_approve` to `auto_approve_tier`. Readers: `:1281`, `:1353`. Writer: `:2785`. Rename the `Config.permissions.auto_approve` read at `:2754`.

### Tests
- `permission_manager.test.lua:143-154`, `:1873-1876`: set `auto_approve_kinds = { "skill" }`, not the read-only flag.
- `permission_manager.test.lua:498-507`: set `auto_approve_kinds = { "read", "search" }`.
- `permission_manager.test.lua:1808-1821`: "allows read-only kinds" expects deciders `{ "read" }` and `{ "search" }`, not `{ "read-only" }`.
- Delete "respects the auto_approve_grant switch" (`:1528-1537`).
- Rename `Config.permissions.auto_approve` to `.auto_approve_tier` everywhere.
- `session_manager.test.lua`: drop the `auto_approve_grant` save, set and restore (`:4240-4242`, `:4280`). Delete "is rejected when the switch is off" (`:4336-4341`) and "do nothing when the switch is off" (`:4414-4419`). Any test that needs no grants uses `default_grant = {}`.
- New test in `decide`: a kind added to `auto_approve_kinds` (for example `"fetch"`) approves, with the kind as the decider.
- New test in `decide`: with `"execute"` listed, a command that a deny rule matches is still denied, and one cached as "Reject always" is still rejected.

### `doc/agentic.txt`
- Replace the `auto_approve_read_only_tools` and `auto_approve_skills` entries (`:243-252`) with `*agentic-config-auto_approve_kinds*` under `permissions`. It lists the default. A kind is the one shown in a tool call's heading (protocol kinds plus adapter-minted ones such as `skill`, `websearch`), compared case-insensitively. Listing `"execute"`, `"edit"` or `"other"` approves every such call. With claude-agent-acp, tools named in `allowed_tools` are approved by the CLI whatever this list holds (|agentic-config-allowed_tools|).
- Delete `*agentic-config-auto_approve_grant*` (`:275-280`), and the sentence at `:785`. `default_grant` says that `{}` turns default grants off, and its stated default becomes the real one, `{ "/tmp", "$TMPDIR", ".", "root" }` (also stale at `permissions/SKILL.md:278`).
- `:730-731`: one item for `auto_approve_kinds`, with the kind as the footer word. A read-only shell command still shows `read-only`.
- `:261` (field in the `permissions` table), `:816`, `:819`: `auto_approve_tier`.

### Skills and README
- Skill `permissions`: correct the stale names at `SKILL.md` `:59` (the `Config.auto_approve_*` master switches), `:62`, `:84`, `:177`, `:274`, and `references/parsing.md:260`. Section 1 covers `auto_approve_kinds`. In section 4, the heading drops `Config.auto_approve_grant`.
- Skill `provider-system` `SKILL.md:381`: the casing example names `READ_ONLY_KINDS`; use the `auto_approve_kinds` lookup.
- `README.md:50`: say that the approved tool kinds are configurable.

## Expected outcome
- `permissions.auto_approve_kinds` decides which tool kinds run without a prompt. The default behaves as today.
- `permissions.auto_approve_tier` does what `permissions.auto_approve` did.
- `/grant` is always available. `default_grant = {}` starts sessions without grants.
- The status footer of a call approved by kind shows `read`, `search` or `skill`. A Read used to show `read-only`.
- The old keys are ignored, with no warning.

## Non-goals
- Checking `auto_approve_kinds` entries against a known set of kinds. An unknown name never matches, so the call prompts.
- A shim for the old keys.
- Any dependency between `auto_approve_kinds` and Claude's `allowed_tools`. The user decided they stay independent; the help text of each names the other.

## Open questions
None. Decided (user, 2026-10-26): the kinds check runs after the deny step and the always-cache, option (a).
