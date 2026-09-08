# Bug: claude tool dispatch is keyed on `title`, and two gates have gone dead

Two user-visible features are silently off on the default provider:
`Config.auto_approve_skills` never fires, and the plan-exit flow — the
"Clear context & implement plan" permission option — is never offered.

Both have one cause. The adapter identifies a tool by its **display title**,
which the provider is free to reword, and claude-agent-acp 0.75.1 has reworded
two of them.

## The root cause

`claude_utils.lua:13` states the belief the design rests on:

> ACP has no stable tool-name field — `title` is the only identifier, and the
> provider may send a user-facing string (e.g. "Ready to code?", "Ready for
> implementation") instead of the internal tool name.

**There is a stable field, and this plugin already declares it.**
`claudeCodeMetaFromToolUse` (`acp-agent.js:7507-7525`) sets
`toolName: toolUse.name` on `_meta.claudeCode`, attached to all three
notifications the adapter sees — the initial `tool_call` (`:7622`), the
refining `tool_call_update` (`:7613`) and `streamedInputRefinement` (`:7648`)
— the same `_meta.claudeCode` the plugin already reads `parentToolUseId` from
(`acp_client.lua:639`). It also carries
`skill: <name>` when the tool is `Skill`. On the permission side,
`presentation.js:63` puts `name: value.toolName` on `request.toolCall`.

`acp_client.lua:1336` annotates `claudeCode?.{ parentToolUseId?, toolName?,
toolResponse? }`. Nothing reads `toolName`.

`provider-system/SKILL.md:327-328` already states the rule these gates break:
*"The `title` field is unstable — use pattern matching … rather than exact
string comparison."*

## Gate 1 — `Skill`, dead

`claude_agent_acp_adapter.lua:194` requires `update.title == "Skill"`.
`tools.js:287-294` has an explicit case:

```js
case "Skill": {
    const skillName = toolUse.input?.skill;
    return { title: skillName ? `Load skill: ${skillName}` : "Load skill",
             kind: "other", content: [] };
}
```

Consequences:

- **`auto_approve_skills` is unreachable.** `_try_auto_approve`
  (`permission_manager.lua:380-386`) substitutes `tracker.kind` for the wire
  kind precisely when the tracker says `skill`. With the mint dead the tracker
  holds `other`, so `decide`'s `kind_lc == "skill"` (`:325`) never matches.
  `config_default.lua:499` documents the option as covering exactly the case
  that fails.
- `message.argument` is never set to the skill name, and `rawInput.args` is
  never attached as the body — both live in the dead branch.
- The block renders with `Glyphs.KIND_DEFAULT`.

## Gate 2 — `ExitPlanMode`, dead

`ClaudeUtils.mode_switch_label` (`claude_utils.lua:18`) matches
`MODE_SWITCH_TOOLS` keys (`EnterPlanMode`/`ExitPlanMode`/`EnterWorktree`) then
falls back to `^Ready%s`. `tools.js:277-282` sends:

```js
case "ExitPlanMode":
    return { title: "Approve Plan", kind: "switch_mode", … };
```

Neither matches. `claude_agent_acp_adapter.lua:59-74` does not intercept, so
the block keeps the provider's title and renders as `Switch Mode` /
`Approve Plan`. `argument` is therefore `"Approve Plan"`, never `"Normal"`,
which independently breaks two things:

- `_on_request_permission`'s `is_plan_exit` (`:1245-1247`) recomputes
  `tracker.kind == "switch_mode" and tracker.argument == "Normal"` and fails,
  so the **"Clear context & implement plan" option (`:1252-1256`) is never
  injected**.
- `SessionManager:_track_plan_exit` (`session_manager.lua:1190`) never sets
  `_plan_exit_pending`.

These are independent, not a chain: `_plan_exit_pending` is **write-only**.
Its four references (`session_manager.lua:210`, `:1192`, `:2463`, `:2621`) are
an initialiser, one write and two resets — nothing reads it, and the
"turn-end callback" its docstring promises does not exist. Fixing the gate
will set a flag that is still unread; that dead state is a separate
pre-existing bug.

The `^Ready%s` fallback was matching something real: `presentation.js:56`
still sets the *permission* title to `"Ready to code?"` for ExitPlanMode. It is
only the `tool_call` notification's title that is now `"Approve Plan"`.
`EnterPlanMode` and `EnterWorktree` have no `case` in `tools.js`, fall to
`default: { title: name }` (`:337`), and still work.

## Gate 3 — `SlashCommand`, unverified

`claude_agent_acp_adapter.lua:191` requires `update.title == "SlashCommand"`.
That tool has no `case` in `tools.js`, so `default` should title it with the
tool name and the gate should hold. But the string appears nowhere in the
installed package, and `"kind":"SlashCommand"` appears **zero** times across
1,973 cached sessions — so there is no evidence the gate has ever fired.
Unresolved; the fix below moots it.

## Evidence this regressed

Counted structurally over cached session records, not by text match — the
literal `"Ready to code"` appears in 107 session files simply because
`claude_utils.lua` contains it and those sessions read that file. Only 13 hold
it as a tool-call `argument`.

| Cache record | Newest |
| --- | --- |
| `kind == "Skill"` (94 records) | 2026-06-07 |
| `argument == "Ready to code?"` (19 records) | 2026-03-20 |
| `argument == "Approve Plan"` | never |
| `kind == "SlashCommand"` | never |

Provider package installed 2026-09-08. Current sessions persist skill loads as
`{"kind":"other","argument":"Load skill"}`. So the Skill gate is datably dead;
for ExitPlanMode the cache only shows the old title's last use, and the
evidence that it is dead *now* is `tools.js:277-282`, not the cache.

## Fix

Dispatch on `_meta.claudeCode.toolName` (tool calls) and `toolCall.name`
(permission requests) instead of `title`, at all three gates. That fixes Skill,
ExitPlanMode and the three mode-switch labels in one change, and takes the
skill name from `_meta.claudeCode.skill` rather than re-deriving it.

**The permission half belongs in the adapter, not `PermissionManager`.**
`_meta.claudeCode` and `toolCall.name` are claude-only; `PermissionManager` is
provider-agnostic and kind-keyed. `__handle_request_permission` is the existing
override point for this (`GeminiACPAdapter:80` already uses it) — have the
claude adapter resolve the kind from `toolName` before forwarding. That also
retires the tracker-ordering hack at `permission_manager.lua:380-386` for
claude. Note this decides an open question in
`notes/refactor-acp-kind-normalisation.md` §1d: if the adapter rewrites
`request.toolCall.kind` to `skill`, that note's `CACHE_KEY_FIELDS.skill` row
stops being unreachable and must not be deleted.

**The skill name will not arrive on the initial `tool_call`.**
`__apply_raw_input` early-returns on empty `rawInput`
(`claude_agent_acp_adapter.lua:140-142`), and claude streams input separately —
which is why the cache holds a bare `argument: "Load skill"` 16 times and never
`"Load skill: <name>"`. To show the name immediately, the
`_meta.claudeCode.skill` read has to sit outside that guard.

Delete the false premise at `claude_utils.lua:13` with it, and check
`provider-system/SKILL.md:320-324`, whose ExitPlanMode title row is stale for
the same reason.

Keep the title fallbacks for providers that send no `_meta`; `toolName` is
claude-specific and the adapter is too, but `mode_switch_label` is called with
a bare title today and would need the identity threaded to it.

## Tests

Fixtures must carry the real wire shape — `title = "Load skill: foo"`,
`kind = "other"`, `_meta.claudeCode = { toolName = "Skill", skill = "foo" }`.
`permission_manager.test.lua:223` currently fixtures `toolCall.kind = "Skill"`,
a shape no provider produces; reshaping it to `{ kind = "other", name =
"Skill", rawInput = { skill = "foo" } }` keeps its two dependants (`:240`,
`:248`) green only once this fix lands, so change them together.

A mode-switch case needs the same: `title = "Approve Plan"`,
`kind = "switch_mode"`, `_meta.claudeCode.toolName = "ExitPlanMode"`, asserting
`_plan_exit_pending` and the injected option.
