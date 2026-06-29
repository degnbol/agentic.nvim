# Plan: "Allow always" on execute remembers the command's *parts*

## Problem

Picking "always allow" on an execute prompt caches the **whole command
string** and re-approves only a byte-identical block. `_complete_request`
(`permission_manager.lua:761`) calls `_build_cache_key`, which for `execute`
keys on `rawInput.command` (`CACHE_KEY_FIELDS.execute = { "command" }`, `:92`).
Any variation — an extra line, reordering, different args elsewhere in the
block — re-prompts in full.

Desired: "always allow" should remember the individual **parts** (leaf
commands) it was prompted about, so a later block that shares those parts does
not re-prompt for them. A safe test-script call vouched for once stays vouched
for, even when it reappears inside a different multi-line block. This is an
improvement to the *always-allow* choice and should read as one to the user.

This is a behavioural change, distinct from the display-only relabel in
[permission-always-allow-wording.md](permission-always-allow-wording.md) ("No
behavioural change") and from the parser-extension work in
[perm-extend-auto-approve.md](perm-extend-auto-approve.md) (what auto-approves
with *no* prompt). Neither touches cache granularity.

**Not** solved by a settings rule. A `Bash(./run-tests.sh:*)` glob is *not* the
intended fix and is strictly worse than the structural permission system: globs
are unsound against option clustering and GNU abbreviation (permissions skill
§ "Shell command parsing"), and nobody should be hand-writing an arbitrary
filename into their config to silence one prompt. If a *command* is genuinely
safe it belongs in `permissions.json` as a structured entry; allow-always is for
vouching for *this specific invocation* in-session, nothing more.

## Why "find all", not "first bail"

`PermissionRules` has two parse-tree traversals:

- **Decision walk** (`should_auto_approve`/`evaluate` → `walk`, `:881`) is
  **first-bail**: it returns `false` at the first un-approvable leaf.
- **Highlight tally** (`tally_unapproved` → `tally_*`, `:2006`/`:1947`) is
  **find-all**: it recurses every branch and records *every* unapproved part,
  never stopping early.

If "always allow" remembered only the first-bail leaf, a block with two
unapproved leaves `[X, Z]` would prompt three times: allow → remember `X`;
block reappears, bails at `Z` → prompt → remember `Z`; reappears clean. The
find-all traversal already enumerates *all* unapproved leaves, so one
"always allow" can remember every rememberable part of the block at once — no
repeated prompting for the same call.

## Design

Treat the vouched-for leaves as **session-local allow patterns** and let the
unchanged decision walk do the rest. The walker is all-or-nothing and matches
each leaf against `ctx.allow` (`walk_command:1194`,
`leaf = name .. " " .. args` at `:1087`); injecting the remembered leaves as
extra allow patterns makes a future block auto-approve iff every leaf is either
rule-allowed *or* remembered — with **deny/ask still gating** (remembered
leaves are allow-only; they never override a deny/ask). No new approval logic;
reuse the audited walker.

Two storage channels, because a block can prompt for two different reasons:

1. **Leaf-level** — a clean, modelled `command` leaf that is unapproved *solely
   because no allow rule covers it* (`./run-tests.sh`). Rememberable as a leaf
   signature. This is the common case and the one the user describes.
2. **Whole-command fallback** — any unapproved part that is *not* a clean
   no-allow-rule leaf: a structural/unmodelled node (write redirect, `eval`,
   process substitution, dynamic command name, a dirty `$(...)` inside an
   otherwise-safe leaf), **or a leaf that is unapproved because it matched
   `deny`/`ask`**. For these, keep the existing whole-command-string cache so
   "always allow THIS block" still holds for the identical block.

### The deny/ask leaf is *not* rememberable (the critical distinction)

A part is unapproved for one of two reasons, and only the first is rememberable:

- **No allow rule matched it.** Injecting it as an allow pattern works — the
  walker finds it in `ctx.allow` next time and passes it.
- **`deny`/`ask` matched it** (`command_known_safe:1729`, or the structured
  deny/ask path). Injecting it as an allow pattern does **nothing** —
  `deny`/`ask` are checked *before* `allow` in `walk_command` (`:1093`) and gate
  it regardless. The injected pattern is dead.

Conflating the two silently breaks allow-always. Trace `safe-cmd; ask-cmd`: it
prompts (ask withholds approval; `should_auto_reject` does not fire on ask). If
the collector recorded `ask-cmd` as a clean leaf and therefore stored no
whole-command fallback, the *identical* block re-prompts forever — the injected
allow for `ask-cmd` is gated by the same `ask`, and the old whole-command cache
that used to re-approve it is gone. That is **worse than today**.

So: collect a leaf **only** when it is unapproved purely for lack of an allow
match. Any `deny`/`ask`-gated leaf (and any structural/sub-range part) forces
`complete = false`, which stores the whole-command fallback — preserving today's
stickiness for the identical block. A `deny`-gated leaf can only reach a prompt
when it is dynamic (a concrete deny rejects pre-prompt via `should_auto_reject`);
either way it is not rememberable.

Dynamic-but-ungated leaves (`./run-tests.sh $foo`) *are* remembered, as their
literal text — see Soundness.

### One find-all function, two call sites

The highlighter and the allow-always collector both want the find-all result,
but they cannot share one *computed result*: the highlighter parses the
**displayed** command body (chat-buffer lines between the fences,
`permission_highlight.lua`) so its byte ranges map to the rendered extmark
positions, while the collector needs leaf signatures from the **raw**
`rawInput.command` that `evaluate` will re-walk. Different input string (the
displayed/raw split is deliberate — it is why highlight ranges align with
rendered text) and different output (coordinate ranges vs leaf strings).

They *can* share one **function**. Extend the existing find-all traversal so it
emits both, and let each caller read the field it needs:

```
--- @return ranges agentic.utils.PermissionRules.Range[]|nil
--- @return leaves string[]   -- stripped, rememberable leaf signatures
--- @return complete boolean  -- false if any unapproved part isn't a rememberable leaf
M.tally_unapproved(command)
```

`command_known_safe` (`:1695`) already reconstructs `leaf` internally (`:1723`)
but returns only `safe, sub_ranges`. Add the leaf string as a **third return,
populated only on the allow-fallthrough path** — the final
`local safe = glob_safe or struct_safe` / `return safe` (`:1786`/`:1792`) when
`safe` is false and there are no `subst_ranges`. Every other `return false`
(deny/ask at `:1729`; structured deny/ask; missing args/name;
`CODE_TAKING_BUILTINS`; transparent-prefix inner-unsafe; dirty substitution)
returns a `nil` leaf.

In `tally_walk`'s `command` branch (`:1957`):

- third value non-nil → collect it into `leaves`.
- range recorded with a nil third value, **or** a `sub_ranges` result, **or**
  any structural/`else` record site (`:1965`,`:1983`,`:1989`) → set
  `complete = false`.

`complete = true` iff every unapproved part was a clean no-allow-rule leaf.
(`leaves`/`complete` thread alongside `ranges` — put them on the threaded `ctx`
or a richer accumulator; implementation detail.)

Callers:
- **Highlighter** — unchanged input (displayed body); reads `ranges`, ignores
  the rest.
- **Allow-always** — calls it once on the raw command when "2" is pressed
  (`_complete_request`); reads `leaves`/`complete`, ignores `ranges`.

Each call site runs the traversal at most once per prompt (highlight at display
time, collector at keypress). The decision walk (`evaluate`) and reject walk
(`should_auto_reject`) stay separate: they run *pre-queue* to gate whether a
prompt is shown at all, and the decision walk is first-bail by design — folding
the find-all into them would slow the common gate path for no benefit.

### Injection

`M.evaluate(command, extra_allow)` — optional second arg, a list of compiled
`CompiledPattern`s. **Merge `extra_allow` into the local `allow` list before the
empty-rules guard** (`:2217-2223`). The guard then needs no special clause: with
injected leaves `#allow > 0`, so it iterates normally; with an empty
`extra_allow` it is a no-op and the guard short-circuits exactly as today.
`should_auto_approve(command, extra_allow)` forwards the arg to `evaluate`.
Existing callers pass nothing — unchanged.

`M.literal_pattern(leaf)` → `CompiledPattern`: an exact-match pattern built from
**`M.strip_command_path(leaf)`** (escape Lua-magic chars via the existing
`MAGIC_CHARS`, anchor `^…$` — same shape as `glob_to_lua_pattern`, `:99`, but no
`*` wildcarding). The strip matters: `matches_any_pattern` strips the segment's
bin-dir prefix before matching (`:311`), so a pattern built from the raw leaf
would fail to match its own future occurrence for path-prefixed commands
(`/usr/bin/foo …` → segment strips to `foo …`, raw pattern keeps `/usr/bin/`).
Stripping both sides keeps the path-less convention the rest of the matcher uses.

## Implementation

1. **`permission_rules.lua`**
   - `command_known_safe` (`:1695`): add the reconstructed `leaf` as a third
     return, **non-nil only on the allow-fallthrough path** (`:1786`/`:1792`).
   - `tally_walk` (`:1947`) + `M.tally_unapproved` (`:2006`): collect leaf
     signatures and a `complete` flag per the rules above; return
     `ranges, leaves, complete`.
   - `M.literal_pattern(leaf)` → `CompiledPattern` (from the stripped leaf).
   - `M.evaluate(command, extra_allow)` / `M.should_auto_approve(command,
     extra_allow)`: merge `extra_allow` into `allow` before the `:2221` guard.

2. **`permission_manager.lua`**
   - New per-session `self._execute_leaf_allow` (string set), initialised in
     `new` (`:45`) and cleared in `clear` (`:797`) alongside `_always_cache`.
   - Helper `self:_remembered_leaf_patterns()` → compiles each entry of
     `_execute_leaf_allow` via `PermissionRules.literal_pattern`, returning `{}`
     when empty.
   - `_complete_request` (`:761`), on `allow_always` + execute:
     `local _, leaves, complete = PermissionRules.tally_unapproved(command)`;
     add each `leaves` entry to `_execute_leaf_allow`; if `not complete`, also
     set the whole-command `_always_cache[key] = "allow"` (today's behaviour as
     fallback). `reject_always` stays whole-command (per-leaf reject would
     over-reject — the user rejected *this command*, not "any block containing
     this part").
   - `_try_auto_approve` execute path (`:317`): replace the bare
     `should_auto_approve(command)` with a **single** call passing the remembered
     patterns: `should_auto_approve(command, self:_remembered_leaf_patterns())`.
     Empty set → identical to today. The whole-command `_always_cache` check
     (`:322-338`) stays after it, as the fallback for `ask`/deny-gated blocks.

## Granularity

The remembered unit is the **exact reconstructed (stripped) leaf**
(`./run-tests.sh --fast`, not `./run-tests.sh`). A different-args invocation
re-prompts. We vouch for *this invocation*; a genuinely-safe command belongs in
`permissions.json`, not the always-cache.

Harvest **unapproved-only**, not all clean leaves. A future subset block whose
parts were rule-approved is still approved by those rules, so it never needed
remembering; emitting all-clean only grows the set and muddies the "parts we
were prompted for" meaning.

## Soundness

- Remembered leaves enter only `ctx.allow`; the deny/ask gates and all-or-nothing
  structure are untouched, so a remembered leaf can never override a deny/ask and
  a structurally-unsafe future block still bails.
- Leaves are collected only at genuine execution positions (the collector reuses
  the tally traversal, which skips bail-contexts), only from the allow-fallthrough
  path, and only from a block the user approved as a whole — so every remembered
  leaf was actually vouched for and is actually rememberable.
- A dynamic token in a remembered leaf is stored as its literal text (`$var`);
  as an exact pattern it matches only an identically-written future leaf, and a
  dynamic token in *that* future leaf wildcard-fires deny/ask anyway. Over-prompt
  at worst, never under-prompt.
- Injection never adds an effect: a leaf approved via an injected allow pattern
  matches `ctx.allow` and emits no file-mutating effect, so
  `should_auto_approve = ok and #effects == 0` is unaffected.

## Tests (`permission_rules.test.lua`, `permission_manager` spec)

- `tally_unapproved` leaves/complete: a two-unsafe-leaf block (both
  no-allow-rule) returns both leaves, `complete = true`; existing range
  assertions still hold. A block with a write redirect returns `complete =
  false`. A dirty-substitution leaf returns `complete = false`.
- **Q2 — ask-gated fallback**: a block with an `ask`-gated leaf returns
  `complete = false` (so the manager stores the whole-command fallback); the
  identical block then auto-approves on replay via that fallback.
- Injection: `should_auto_approve("a; b", { literal_pattern("b") })` still
  prompts (`a` unknown); with both leaves remembered, approves. A remembered
  leaf that also matches a deny still prompts (deny gates).
- **Q3 — path strip**: a remembered `/usr/bin/foo --x` leaf re-approves its own
  future occurrence (proves `literal_pattern` builds from the stripped form).
- **Q4 — empty-rules no-op**: with `use_plugin_defaults = false` and no allow
  globs, a block of only remembered leaves approves; with an empty remembered
  set it still bails cleanly (proves merge-before-guard ordering).
- Manager: allow_always on `[safe-rule-leaf, X]` then a later block
  `[safe-rule-leaf, X, Y]` prompts only about `Y`; allow_always on the
  redirect-bail block falls back to whole-command re-approval.

## Out of scope

- Cross-session persistence (no ACP method — permissions skill § "Known ACP
  limitation").
- The option label (separate wording plan).
- `/trust` scope (file-kind mechanism, not execute).
