# Plan: make lowercase an invariant of a tool-call `kind`

> **Scope.** Six byte-identical `kind_key` locals existed because `kind` reaches
> its readers in inconsistent casing. The inconsistency is **self-inflicted** —
> twelve sites in this plugin mint CamelCase kinds the protocol does not have.
> Lowercase those, fix everything that reads them raw, then delete the
> reader-side normalisation and the helper.
>
> The invariant holds on `update.kind` from the session-update boundary
> onward (§2) and on the block field derived from it. It does **not** hold on
> `request.toolCall.kind` — the permission path never crosses that boundary
> (§5). Trust *scope* kinds are out of scope; permission *option* kinds get one
> deletion (§4).
>
> Supersedes this file's earlier option-1/option-3 comparison. Option 1 (hoist
> the helper into `utils/acp_kind.lua`) is applied in the working tree,
> uncommitted; §6 removes it.

## The premise that justified normalising was false

Reader-side normalisation was defended by an unsourced claim that providers
differ in kind casing. It is wrong, from provider source:

- **opencode** (`opencode-ai` 1.18.29, the binary `config_default.lua:119`
  spawns) maps tool names to kinds in one function whose every return is a
  lowercase protocol kind — `bash`→`execute`, `read`→`read`, `task`→`think`,
  default `other`. It never returns the tool name. The specific claim that it
  emits `"Read"`/`"Search"` is contradicted, not merely unevidenced.
- **claude-agent-acp** 0.75.1 emits only
  read/edit/delete/move/search/execute/think/fetch/other/create/write/switch_mode.
- **Cache survey.** 1,973 sessions: `opencode-acp` sent 3,831 protocol kinds,
  all lowercase, zero capitalised. Every capitalised kind in the cache —
  `Skill` 94, `TodoWrite` 65, `SubAgent` 25, `WebSearch` 9, `SlashCommand` 0 —
  this plugin minted.
- **`acp_client.lua:490`** does a raw `KNOWN_ACP_KINDS[update.kind]` lookup into
  a strictly lowercase table on every inbound `tool_call`, with a user-facing
  *"Unknown ACP tool call kind… Please report this"* on miss. A provider
  capitalising `Read` would have spammed it.

**Four copies of the false claim must go with §1** (they instruct the opposite
of what this plan does):

1. `.claude/skills/provider-system/SKILL.md:330-339` — a whole section, *"Tool
   kind casing varies by provider"*, ending *"Any kind-based dispatch must
   lowercase before lookup"*.
2. `utils/acp_kind.lua:6-7` (was `permission_manager.lua:130` at HEAD) — the
   docstring the hoist carried forward.
3. `session_manager.test.lua:1625` — *"opencode capitalises kinds"*, in the
   comment of a test that exists to assert the behaviour §6 deletes.
4. `notes/feature-file-activity-panel.md:168`.

## The twelve mints

| Kind | Sites |
| --- | --- |
| `SubAgent` | `claude:174`, `claude:179`, `opencode:58`, `opencode:132`, `mistral:56` |
| `Skill` | `claude:195`, `opencode:60` |
| `WebSearch` | **`acp_client.lua:520`**, `codex:95`, `opencode:56` |
| `SlashCommand` | `claude:192` |
| `TodoWrite` | `opencode:64` |

`acp_client.lua:520` is in `__resolve_fetch_fields`, called from
`claude_agent_acp_adapter.lua:172` and `auggie_acp_adapter.lua:48` — the mint
that fires for the default provider, and the one most easily missed for not
being in an adapter.

`claude:195`'s `Skill` mint is **dead today** for an unrelated reason — its
title gate never matches, as does `ExitPlanMode`'s; see
`notes/bug-title-keyed-tool-dispatch.md`. Fix that bug before or after, not
inside §1; lowercasing a dead branch is still correct.

Tables these are looked up in, all keyed lowercase: `Glyphs.KIND`
(`glyphs.lua:19`), `CODE_KINDS` (`tool_call_renderer.lua:103`),
`FILE_MUTATING_KINDS` (`session_manager.lua:30`), `READ_ONLY_KINDS` /
`FILE_SCOPED_KINDS` (`permission_manager.lua:85`, `:91`), `KNOWN_ACP_KINDS`
(`acp_client.lua:44`).

## Where a protocol kind enters

Seven block assignments: `acp_client.lua:632` (default
`__build_tool_call_message`), `auggie:27`, `gemini:25`, `cursor:73`,
`codex:39`, `opencode:48`, and `mistral_vibe_acp_adapter.lua:34` — which
overrides `__build_tool_call_message` (a fourth override point the
`provider-system` skill does not list) and folds in a re-map,
`kind = update.kind == "other" and "execute" or update.kind`.

`claude_agent_acp_adapter.lua:65` (`kind = "switch_mode"`) is a hardcoded
lowercase literal and needs nothing.

**The update path also sets `kind`.** `MessageWriter:update_tool_call_block`
merges with `vim.tbl_deep_extend("force", tracker, tool_call_block)`
(`message_writer.lua:2078`), and per `session_manager.lua:1008` (*"Kind usually
resolves on the update, not here"*) that is the normal case for SubAgent.
Verified: that path carries **only mints**, never a protocol kind — the base
`__build_tool_call_update` never sets `kind`. So §1 covers it and §2 need not
touch it. Recorded so the next reader does not re-derive it.

## 1. One atomic commit

None of these can land alone.

### 1a. Rewrite the twelve mints
`subagent`, `skill`, `websearch`, `slashcommand`, `todowrite`.

### 1b. Rewrite the `agentic.acp.ToolKind` alias
`acp_client.lua:1188-1205` enumerates the five CamelCase literals (inside the
`CRITICAL: … DO NOT REMOVE` block at `:39`). Without this hunk §1a fails
`make validate` on `assign-type-mismatch`.

No `--[[@as]]` casts are needed anywhere: §2 assigns through an untyped
`update`, and §1e's `session_restore.lua:350` sits inside an already-annotated
constructor. Verified by applying §1a+§1b+§1e+§2 to a scratch copy and running
`make luals`' exact invocation — the only residual diagnostics are the six
CamelCase literals in tests (§1f's `message_writer.test.lua:4172`, `:4186`;
`tool_call_renderer.test.lua:752`, `:766`;
`permission_manager.test.lua:223`; `tests/integration/turn_desync.test.lua:31`).
§1f's other four are behavioural failures, not type errors.

### 1c. Fix the two raw CamelCase comparisons
- `tool_call_renderer.lua:990` — `elseif kind == "fetch" or kind ==
  "WebSearch" or kind == "SubAgent" then`. Not latent: lowercasing the mints
  drops those bodies into the generic `else`, which attempts JSON
  pretty-printing on prose, swaps unconditional folding for
  `other_max_lines`, and never sets `dim_range` (assigned only at `:1010`), so
  subagent bodies render undimmed.
- `claude_agent_acp_adapter.lua:177` — `update.kind == "SubAgent"`, a **wire**
  comparison. **Dead**: the string appears nowhere in claude-agent-acp 0.75.1
  or its bundled SDK, which maps `Agent`/`Task` → `kind: "think"`, already
  handled at `:173`. Delete the disjunct; keep
  `(kind == "other" and rawInput.subagent_type)`.

### 1d. Delete `CACHE_KEY_FIELDS`' four unreachable entries
`permission_manager.lua:116-119` keys `WebSearch`/`SlashCommand`/`SubAgent`/
`Skill` in CamelCase. **Lowercasing them would not make them reachable**:
`_build_cache_key` reads `tool_call.kind` (`:169`), a *wire* value from
`request.toolCall`, and these four are mints written onto the *block*. claude
sends `fetch` for WebSearch (`tools.js:212-219`) and `think`/`other` for Task;
opencode sends `other`. `_try_auto_approve:380-386` exists precisely because
the wire kind is uninformative here.

So delete the four rows with a one-line reason. Behaviour is unchanged, but not
uniformly "falls to the hybrid path": a claude WebSearch lands on
`CACHE_KEY_FIELDS.fetch = { "url" }` with only `query` in `rawInput`, so
`#parts == 1` at `:202` returns **nil** and `allow_always` is not cached at all.
Making the four reachable means passing the resolved kind into
`_build_cache_key`, which changes allow-always scoping — a separate decision,
not part of a rename.

### 1e. Normalise the restore boundary
`session_restore.lua:350` (`kind = msg.kind`) replays kinds persisted raw by
`session_manager.lua:1020`. **Sessions on disk hold `Skill` (94),
`TodoWrite` (65), `SubAgent` (25), `WebSearch` (9)** — all of them on
`messages[].type == "tool_call"` records, exactly what `:350` replays. Without a normalise here
§1a silently breaks every session predating it. Nothing tests this.

Two other persisted-kind readers are display-only and unaffected:
`session_restore.lua:249` (picker label) and `chat_history.lua:156`
(prompt reconstruction, `"Tool call (%s): %s"` — its text changes from
`Tool call (SubAgent)` to `Tool call (subagent)` on resume; cosmetic).

### 1f. Update the ten test assertions
`tool_call_renderer.test.lua:752`, `:766`; `message_writer.test.lua:4172`,
`:4186`; `permission_manager.test.lua:223`;
`opencode_acp_adapter.test.lua:54`, `:103`, `:169`;
`tests/integration/turn_desync.test.lua:31`; and
`session_manager.test.lua:1624` — *"lowercases the kind before dispatching"*,
which asserts the behaviour §6 removes and must be deleted or repurposed
there.

`permission_rules.test.lua:34`'s `"WebSearch"` is a Claude `settings.json`
permission entry in an `extract_bash_patterns` fixture, **not** a kind.

Add the coverage §1e lacks: restoring a fixture session that holds a CamelCase
kind must render as the lowercase kind's block.

## 2. Canonicalise once, at the session-update boundary

Normalise `update.kind` **in place** in `ACPClient:__handle_session_update`,
**above** the `if session_update_type == "tool_call"` at `acp_client.lua:489`
— not inside it, which would miss the `tool_call_update` branch at `:504`
where claude's kind normally resolves:

```lua
if
    type(update.kind) == "string"
    and (
        session_update_type == "tool_call"
        or session_update_type == "tool_call_update"
    )
then
    update.kind = update.kind:lower()
end
```

One edit. Everything downstream — every adapter's field assignment *and* every
adapter's dispatch, on both branches — then sees a canonical value.

`type(...) == "string"` rather than `(update.kind or ""):lower()`: the latter
turns a missing kind into `""`, changing what the block stores, what the
unknown-kind alarm prints, and `opencode_acp_adapter.lua:50`'s
`update.title ~= update.kind` comparison — three divergences for no gain. It
also throws on `vim.NIL`, which is truthy and which
`ACPClient:safe_split`'s docstring records some agents sending.

No cast is needed: `__handle_session_update`'s `params` is annotated `table`,
so `update` is untyped and the assignment is unchecked. (Verified with
`--checklevel=Warning` against the real config.)

Normalising per-assignment instead would be both incomplete and larger. Each
adapter takes `local kind = update.kind` and **dispatches** on it before
assigning, so the field would be canonical while the branch that decides the
mint, argument and diff still matched case-sensitively. The dispatch-only
sites a per-assignment edit misses: `claude:59` (`__handle_tool_call`),
`claude:144` (`__apply_raw_input`, which never assigns the field — claude's
comes from the base at `:632` — and which is reached from
`__build_tool_call_update` at `:123`, the path that matters), `mistral:40`,
and `opencode:151`/`:162` in `__handle_tool_call_update`. Nine sites, versus
one.

Safety of mutating `update`: `cursor_acp_adapter.lua:62` delegates to the base
and inherits it; `gemini:88` builds its synthetic update with `vim.tbl_extend`,
which copies, so the mutation cannot alias back into `request.toolCall`. The
`tool_call_update` subclasses do carry a kind
(`claude_agent_acp_adapter.lua:18`, `opencode_acp_adapter.lua:102`,
`mistral_vibe_acp_adapter.lua:70` all declare
`@field kind? agentic.acp.ToolKind`), which is why the gate covers both
branches; no other `sessionUpdate` type has the field.

**One path bypasses it:** `gemini_acp_adapter.lua:92` re-enters
`__handle_tool_call` directly with a tool call built from `request.toolCall`,
never passing through `__handle_session_update`. It needs its own normalise or
an explicit note that gemini's kinds are lowercase by premise.

Side effect worth having: `acp_client.lua:490`'s own unknown-kind alarm
currently compares a raw wire value against a lowercase table, so it would
false-positive on the very casing this plan says does not occur. After this it
is honest.

No provider has been observed to pad with whitespace, so no `vim.trim`.

**Needs a test.** Every adapter test calls `__handle_tool_call_update` /
`__build_tool_call_message` directly, bypassing `__handle_session_update`, so
after §6 nothing would exercise this boundary. Add an `acp_client` case
feeding a capitalised kind through `session/update` on both branches.

## 3. Uphold the invariant at the three producers outside `lua/agentic/acp/`

None is broken (all lowercase already), but all three reach `PermissionManager`
without passing §2:

- `permission_hook.lua:18` — `NAME_TO_KIND` maps a Claude tool name to
  `execute`/`edit`, read at `:69`, fed to `PermissionManager:decide`. A
  PreToolUse-hook producer entirely outside the session-update pipeline.
- `session_manager.lua:1253` — `kind = "plan_implement"`, a synthetic *option*
  kind injected into `request.options`.
- `permission_float.lua:118`, `:128` — `kind = "__reject_all__"`, a synthetic
  option kind minted into the option list *downstream* of any receive point.

A line at each naming the invariant.

Every other non-test **ACP-vocabulary** `kind = "…"` in the repo is one of
§1a's mints or an already-lowercase literal needing no change: `claude:65`,
`claude:203` (`switch_mode`) and `opencode:54` (`search`). A bare
`grep 'kind = "'` also returns trust-scope and bash-effect literals — those are
the other vocabularies under Hazards, not misses. `session_restore.lua:350`
(§1e) is `kind = msg.kind`, so it never appears in that grep at all.

## 4. Delete the four option-kind normalise calls

`session_manager.lua:1266`, `permission_manager.lua:902`, `:989`,
`permission_float.lua:114`. Option kinds are the ACP enum plus §3's two
lowercase plugin literals, and are **already read raw** in four places that
work in production — `find_option_id` (`permission_manager.lua:229`),
`PERMISSION_KIND_PRIORITY[a.kind]` (`:878`),
`option_kind == "reject_once"` (`session_manager.lua:1308`), and
`Config.permission_icons[option.kind]` (`permission_float.lua:143`, a
user-config surface). Both providers emit lowercase snake_case option kinds.

These four are a subset of §6's 28, so §6 deletes 24 if this runs first.

## 5. Leave the permission path's three normalise calls, and say why

`permission_manager.lua:169`, `:319`, `:844` normalise
`request.toolCall.kind` / `decide`'s `kind` — wire values arriving via
`session/request_permission`, which never pass through any adapter's
`__build_tool_call_message`. §2 does not reach them.

`:319` in particular is a **multi-producer junction**, which is the real
argument for keeping it: `decide`'s `kind` parameter arrives from the wire
`tool_call.kind`, from the *block* via `_try_auto_approve:385`
(`kind = tracker.kind`, covered by §1), and from `permission_hook.lua`'s
`NAME_TO_KIND` (§3).

Failure direction is safe on every branch: `READ_ONLY_KINDS[kind_lc]` (`:321`),
`kind_lc == "skill"` (`:325`) and `FILE_SCOPED_KINDS[kind_lc]` (`:354`) all
fail *closed* on a capitalised value, the two command branches (`:329-339`)
never read `kind`, and a case-sensitive cache key merely misses. The
load-bearing detail: `_check_trust` → `TrustSafety.safe_for_kind` sits
**behind** the `FILE_SCOPED_KINDS[kind_lc]` gate, so a missed lookup cannot
open trust — it only prompts.

So keep them and drop the shared helper in favour of an inline
`(kind or ""):lower()` at each. Alternative, if the invariant should cover this
path too: add `request.toolCall.kind` as an eighth §2 boundary — which must
also cover `gemini_acp_adapter.lua:85`, an eighth raw read of it.
**Decide, don't inherit.**

## 6. Delete the reader-side normalisation

All 24 remaining `AcpKind.normalise` call sites, and `utils/acp_kind.lua`.
Three of the 24 — §5's `permission_manager.lua:169`, `:319`, `:844` — become
inline `(kind or ""):lower()` rather than disappearing.

**Audit the nil axis per site, not by count.** The helper advertises two
contracts — casing *and* `nil`→`""` — and the second is load-bearing at
`permission_manager.lua:169`:

```lua
local kind = AcpKind.normalise(tool_call.kind)
if kind == "" then return nil end            -- goes dead
…
return kind .. ":" .. stable_repr(key_data)  -- :220 — concatenates nil
```

`agentic.acp.ToolCall.kind` is optional (`acp_client.lua:1238`), so a kindless
permission request reaches `:220` and errors inside the permission path. The
`{ kind }` branch is wrong too (`#parts == 0`, so the `== 1` guard misses and
`table.concat` yields `""` as a cache key). §5 keeps this site's normalise,
which resolves it — but the audit must be explicit.

All other deletions are safe: `t[nil]` is a legal read in Lua, and every
remaining use is an equality comparison or already guarded
(`tracker and … or ""`).

Per-file reader counts, verified: `session_manager` 10,
`permission_manager` 9, `message_writer` 5, `tool_call_renderer` 2,
`diff_preview` 1, `permission_float` 1.

The raw comparisons in `prepare_block_lines` (`kind == "execute"`, `"read"`,
`"search"`, `"fetch"`) and `apply_block_highlights` (`kind ~= "edit" and
kind ~= "switch_mode"`) then hold by invariant rather than by luck — for the
block field only, per § Scope.

## Hazards

- **`kind` names four other vocabularies. Every edit per-site; no sweeping
  replace.** Trust scope — `tmp`/`path`/`here`/`repo`/`off`, as `scope.kind`
  (`permission_manager.lua:464`+, `trust_safety.lua:90`+) and `choice.kind`
  (`session_manager.lua:825`+, same vocabulary in a different role); bash
  effects — `eff.kind`, `{ kind = "delete" }` / `{ kind = "write" }` from
  `permission_rules.lua:1265`, `:1526`, read at `permission_manager.lua:533`,
  **the one that genuinely collides with the ACP vocabulary and what a pattern
  replace would most plausibly corrupt**; `attachment.type` aliased to a local
  named `kind` (`claude_hook_records.lua:82`); LSP `CompletionItemKind`
  (`completion/lsp_server.lua`).
- **`trust_safety.lua:488`'s `safe_for_kind` is where two of them meet.**
  `permission_manager.lua:679` passes `kind_lc` (ACP), `:539` passes `eff.kind`
  (bash effects). `luals` is silent because `delete` and `write` happen to be
  members of both vocabularies, so the `@param kind agentic.acp.ToolKind` at
  `:484` is semantically wrong but not a diagnostic — do not go looking for a
  lint. Pre-existing; this plan neither creates nor fixes it.
- **Documentation §1a invalidates**, beyond the four premise copies:
  `tool_call_renderer.lua:33` (*"Leaves already-capitalised kinds (WebSearch,
  SubAgent, etc.) unchanged"*), `config_default.lua:499` (*"ACP kind
  `Skill`"*), `auggie_acp_adapter.lua:9`, `theme.lua:158`, `glyphs.lua:19`
  (*"keyed on the lowercased ACP kind"* — vacuous once lowercase is an
  invariant), `.claude/skills/rendering/SKILL.md:113`, `:158`. A
  prose-reviewer pass over `provider-system/SKILL.md` should follow §1: its
  ExitPlanMode title row (`:320-324`) and `display_kind` sentence (`:335-339`)
  go stale with the section at `:330`, and
  `notes/feature-file-activity-panel.md:166-172` cross-references that heading.
- **The adapter override contract changes.** "An adapter must hand downstream
  a lowercase `kind`" belongs in the `provider-system` skill, which also needs
  `__build_tool_call_message` added to its list of override points.
- **`display_kind` is unaffected.** Sole consumer `strip_kind_prefix:52`,
  match at `:53` case-insensitive, output length unchanged for all five mints.
  The kind name never appears in a heading (`collapsed_header` puts identity
  in the sign column), so no visible heading change.
- **Nothing outside the plugin reads a kind.** `WINDOW_HEADERS`
  (`window_decoration.lua:10`) carries only `title`; its `subagent` key is a
  window name.
- **`Glyphs.KIND` neither gains nor loses.** `skill`, `slashcommand` and
  `todowrite` have no entry before or after and fall to `KIND_DEFAULT`.

## Sequencing

§1 is one commit and must be. §2–§6 are then independently safe in any order,
§6 last. §4 before §6 changes only §6's count.

## Decisions needed

1. **§5** — keep the permission path's three normalise calls as a documented
   exception, or extend the invariant to `request.toolCall.kind` as an eighth
   boundary?
2. **§1f / `permission_manager.test.lua:223`** — lowercase that fixture in
   place, or sequence `notes/bug-title-keyed-tool-dispatch.md` first and
   reshape it to the real wire shape? See that note's § Tests for the
   trade-off.
3. **§1d, conditional on the bug fix.** If the `toolName` fix re-kinds the wire
   `request.toolCall.kind` (mapping `toolName == "Skill"` → `kind = "skill"`),
   then `CACHE_KEY_FIELDS`' `skill` row stops being unreachable and §1d's
   deletion becomes wrong for that one row. If instead the fix dispatches on
   `toolCall.name` without touching the kind, §1d stands as written. **§1d
   depends on which shape that fix takes.**
