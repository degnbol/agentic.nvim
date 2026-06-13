# Plan: Restructure and fix `doc/agentic.txt`

Target file: `doc/agentic.txt` (719 lines, vim help format, modeline at line 719).

## Verification results (what was confirmed vs refuted)

### Finding 1 (BLOCKING) — duplicate section number `9.` — CONFIRMED
- Body headings: line 506 `9. HIGHLIGHT GROUPS`, line 538 `9. AUTOCMDS` (duplicate `9`), line 555 `10. HEALTH CHECK`, line 561 `11. DEBUG MODE`, line 570 `12. COMPARISON WITH CLAUDE TUI`.
- ToC (lines 32-41): `9. Highlight groups`, `10. Autocmds`, `11. Health check`, `12. Debug mode`, `13. Comparison with Claude TUI`.
- So the **ToC is internally correct and self-consistent** (9,10,11,12,13). The **body is wrong** from line 538 onward: Autocmds is mislabeled `9` (should be `10`), Health `10`→`11`, Debug `11`→`12`, vs-tui `12`→`13`, and the vs-tui subsections `12.1–12.5` → `13.1–13.5`.
- Fix direction: **renumber the body**, leave the ToC alone.
- **Tags are NOT number-bearing.** Every tag is `*agentic-<word>*` with no embedded section number (e.g. `*agentic-autocmds*`, `*agentic-vs-tui*`, `*agentic-vs-tui-additions*`). Renumbering touches zero tags and zero `|cross-references|`. The cascade is purely the visible `N.` / `N.M` prefixes in body headings.

### Finding 2 (RECOMMENDED) — §4.6 Permissions coverage gap — CONFIRMED
`config_default.lua:443-464` exposes a `permissions` table and `auto_approve_trust_scope` that §4.6 (doc lines 187-198) does not document. §4.6 currently documents only `auto_approve_compound_commands` (line 190) and `auto_approve_read_only_tools` (line 196). Missing, with verified defaults/types:

| Option | Type | Default | Source line |
| --- | --- | --- | --- |
| `permissions.use_plugin_defaults` | boolean | `true` | 455 |
| `permissions.use_claude_settings` | boolean | `true` | 456 |
| `permissions.auto_approve` | `"allow"`\|`"read-only"`\|`nil` | `"allow"` | 457 |
| `permissions.read_only` | string[] (`Bash(...)` globs) | `{}` | 458 |
| `permissions.safe_write` | string[] | `{}` | 459 |
| `permissions.deny` | string[] | `{}` | 460 |
| `permissions.ask` | string[] | `{}` | 461 |
| `auto_approve_trust_scope` | boolean | `true` | 464 |

Semantics (verified from `config_default.lua:444-453` annotations and `permission_rules.lua`):
- `auto_approve = "allow"` → `read_only` ∪ `safe_write` patterns auto-approved; `"read-only"` → only `read_only`; `nil` → none auto-approved (deny/ask still respected) (`get_allow_patterns`, lines 661-674).
- `use_plugin_defaults` gates the bundled `lua/agentic/permissions.json` (confirmed present on disk); `use_claude_settings` gates the `~/.claude/settings.json` + `.claude/settings.json` merge (`load_patterns`, lines 176-232).
- `deny`/`ask` take precedence over allow (`should_auto_approve`, lines 741-748).
- `auto_approve_trust_scope = true` enables the `/trust` scope check; when false, `/trust` is rejected and the trust check is skipped entirely (per AGENTS.md:468-469).

### Finding 3 (RECOMMENDED) — §7 altitude + staleness — CONFIRMED on both counts
(a) Altitude: §7 is a top-level peer of Configuration, but compound-command approval is one of **four** client-side auto-approval mechanisms. AGENTS.md:256-258 states `_try_auto_approve()` runs four checks: read-only tools, compound Bash commands, allow/reject-always cache, trust scope. The doc scatters the other three: read-only as a config option (§4.6), and read-only + trust + allow/reject-cache as bullets under §12.1 Additions (lines 596-608).

(b) Staleness — both sub-claims confirmed against `permission_rules.lua`:
- **Split set**: doc line 472 says split on `| || && ;` only. Code `split_command` (lines 481-578, esp. 543 `ch == "\n"`) **also splits on bare newline**. Doc is stale. AGENTS.md:291 already documents the newline split correctly.
- **Pattern sources**: doc lines 478-479 say patterns come only from `~/.claude/settings.json` and `.claude/settings.json`. Code `load_patterns` (lines 156-232) merges **three** sources: (1) bundled `lua/agentic/permissions.json` when `use_plugin_defaults`, (2) the two Claude settings.json files when `use_claude_settings`, (3) `Config.permissions.{read_only,safe_write,deny,ask}` user additions. Doc is stale. AGENTS.md:309-320 documents all three correctly.
- Additional stale/incomplete detail: doc step 3 (lines 476-477) lists stripped wrappers as `stdbuf -oL` and `/dev/null` redirects only; code also strips fd duplications (`2>&1`, `>&N`, `N>&M`; `strip_devnull_redirects`, lines 437-446) and leading variable assignments + system-bin path prefixes (`strip_wrapper_prefixes`, `strip_command_path`). The doc need not enumerate all of these.

Decision: **Do not duplicate the dev reference.** The authoritative description lives in `lua/agentic/acp/AGENTS.md` § "Client-side auto-approval" (lines 244-469), which is correct and complete. The user doc should (i) fix the two stale claims so it isn't actively wrong, (ii) gain a short framing sentence naming all four mechanisms, and (iii) keep §7 user-facing (the disable toggle, the `Bash(...)` glob syntax) rather than restating the algorithm. Per `edit-docs.md` "Canonical sources" rule, point at the source file. The doc already does this at line 492 (`Implementation: lua/agentic/utils/permission_rules.lua`).

On folding §7 into §4.6: keep §7 as its own section but retitle/reframe. A full merge into §4.6 would bloat the Configuration chapter and lose the standalone `|agentic-compound-commands|` anchor that AGENTS.md and §4.6 both cross-reference. Lower-risk approach: add a 4-mechanism framing paragraph and fix the stale facts in place.

### Finding 4 (RECOMMENDED) — issue #16561 — REFUTED (not stale; it is correct)
WebFetch of `https://github.com/anthropics/claude-code/issues/16561` returns title: *"Feature: Parse compound Bash commands and match each component against permissions #16561"* — exactly the gap §7 describes. The number is **correct**; no change needed. (Grep confirms 16561 appears only in the doc, lines 467 and 601.) **Open item: none.** Do NOT touch the number.

### Finding 5 (NIT) — package name — CONFIRMED
`.claude/skills/acp/references/claude-agent.md:18-19`: "Package was renamed `@zed-industries/claude-agent-acp` → `@agentclientprotocol/claude-agent-acp` at v0.24+." Doc line 72 uses the old name. Update to `@agentclientprotocol/claude-agent-acp`.

### Finding 6 (NIT) — tag hyphen/underscore convention — CONFIRMED, do-not-touch
The pattern is deliberate and consistent: **section/sub-section tags use hyphens** (`*agentic-config-tool-display*` line 165, `*agentic-config-diff-preview*` line 178), while **option tags mirror the literal Lua key with its underscores** (`*agentic-config-tool_call_display*` line 167, `*agentic-config-diff_preview*` line 180, `*agentic-config-auto_approve_compound_commands*` line 189, `*agentic-config-session_restore*` line 203). New option tags added in finding 2 must follow the option convention (underscores matching the Lua key). Do not normalize existing tags.

## Tag-style rule for new tags (finding 2)
New option entries get tags of the form `*agentic-config-<lua_key>*` with underscores preserved, right-aligned to column 79 like the existing entries. New tags:
- `*agentic-config-permissions-tbl*` (the table itself — hyphen, mirrors `*agentic-config-windows-tbl*` / `*agentic-config-keymaps-tbl*` table-anchor style)
- `*agentic-config-auto_approve_trust_scope*` (option — underscores)

## Ordered edit sequence

Order chosen so numbering stays consistent at each step and content additions happen before the renumber so line targets are described against the original file.

### Edit A — Finding 5 (package name), line 72
Replace `@zed-industries/claude-agent-acp` with `@agentclientprotocol/claude-agent-acp` on line 72. Single-token change. No tag/ToC impact.

### Edit B — Finding 2 (Permissions coverage), within §4.6 (lines 187-198)
Append new option entries after the existing `auto_approve_read_only_tools` block (after line 198, before the `4.7` rule at line 200). Add, in this content order, each with a right-aligned option tag and an indented type/default body matching the style of lines 189-198:

1. `permissions` table anchor — tag `*agentic-config-permissions-tbl*`, then list the seven sub-fields (`use_plugin_defaults`, `use_claude_settings`, `auto_approve`, `read_only`, `safe_write`, `deny`, `ask`) with the types/defaults from the table above. Keep the bucket semantics to one line each; for `auto_approve` give the three-value meaning. Cross-reference `|agentic-compound-commands|` for how the patterns are consumed.
2. `auto_approve_trust_scope` — tag `*agentic-config-auto_approve_trust_scope*`, boolean, default `true`, one-line behaviour (enables the `/trust` per-session scope check; when false `/trust` is rejected). Cross-reference the §12.1 trust bullet via `|agentic-vs-tui-additions|`.

Style constraints: follow `.claude/rules/docs.md` (describe what it does, no "useful for X" framing) and `edit-docs.md` (don't restate the algorithm). This edit adds lines but does NOT change any section number or existing tag.

### Edit C — Finding 3 (§7 staleness + framing), within §7 (lines 461-492)
Three sub-edits inside §7, no section-number change yet:
1. **Framing sentence** — after the opening paragraph (after line 467), add one sentence: compound-command approval is one of four client-side auto-approval mechanisms (read-only tool approval, compound Bash commands, the per-session allow/reject-always cache, and `/trust` scope), and point at `lua/agentic/acp/AGENTS.md` § "Client-side auto-approval" for the full description.
2. **Fix split set** — line 472: change `(`|`, `||`, `&&`, `;`)` to include bare newline: `(`|`, `||`, `&&`, `;`, and bare newline)`. Optionally add the half-line rationale (a newline terminates a statement like `;`) — keep terse.
3. **Fix pattern sources** — lines 478-479 (step 4): replace "compiled patterns from `~/.claude/settings.json` and `.claude/settings.json` (project-local)" with the three merged sources: bundled `lua/agentic/permissions.json` (gated by `permissions.use_plugin_defaults`), the two Claude `settings.json` files (gated by `permissions.use_claude_settings`), and `permissions.{read_only,safe_write,deny,ask}` user additions. Reference `|agentic-config-permissions-tbl|`. Keep to 2-3 lines.

Leave line 467 (issue #16561) unchanged. Leave line 492 implementation pointer unchanged.

### Edit D — Finding 3 cross-reference at §12.1, line 599-601
Line 599 repeats the stale split set "splits on `|`, `&&`, `||`, `;`". Update to include bare newline for consistency with Edit C step 2. Line 601 (`anthropics/claude-code#16561`) is correct — leave unchanged.

### Edit E — Finding 1 (body renumber cascade)
Performed LAST. Change only the visible heading-number prefixes; tags and ToC stay untouched. Exact heading-text changes (locate by tag/title, not raw line number, since Edits B and C shift line numbers):

| Current heading text | New heading text | Original line |
| --- | --- | --- |
| `9. AUTOCMDS` (tag `*agentic-autocmds*`) | `10. AUTOCMDS` | 538 |
| `10. HEALTH CHECK` (tag `*agentic-health*`) | `11. HEALTH CHECK` | 555 |
| `11. DEBUG MODE` (tag `*agentic-debug*`) | `12. DEBUG MODE` | 561 |
| `12. COMPARISON WITH CLAUDE TUI` (tag `*agentic-vs-tui*`) | `13. COMPARISON WITH CLAUDE TUI` | 570 |
| `12.1 ADDITIONS` (tag `*agentic-vs-tui-additions*`) | `13.1 ADDITIONS` | 577 |
| `12.2 ACP PATCHES` (tag `*agentic-vs-tui-patches*`) | `13.2 ACP PATCHES` | 627 |
| `12.3 FORWARDED TRANSPARENTLY` (tag `*agentic-vs-tui-forwarded*`) | `13.3 FORWARDED TRANSPARENTLY` | 646 |
| `12.4 BEHAVIOUR DIFFERENCES` (tag `*agentic-vs-tui-diffs*`) | `13.4 BEHAVIOUR DIFFERENCES` | 665 |
| `12.5 NOT AVAILABLE` (tag `*agentic-vs-tui-missing*`) | `13.5 NOT AVAILABLE` | 677 |

`9. HIGHLIGHT GROUPS` (line 506) stays `9` — it was already correct. The right-alignment of each heading's tag is unaffected by the single→double digit change. Verify alignment after the edit anyway.

No ToC edit is needed — the ToC (lines 32-41) already shows the correct 9/10/11/12/13 numbering.

### Edit F — modeline integrity
No edit. The modeline at line 719 (`vim:tw=78:ft=help:norl:`) must remain the final line and unchanged. Confirm it is still last after all insertions.

## Validation (manual — `make validate` is Lua-only and does not cover docs)
1. **ToC ↔ body number match**: visually diff ToC lines 32-41 against the post-edit body headings; every `N.`/`N.M` must match.
2. **Tag consistency / no dupes**: re-run `rg -o '\*agentic-[a-z_-]+\*' doc/agentic.txt` — confirm (a) the two new tags appear exactly once, (b) no tag was duplicated or altered, (c) total tag count = previous 43 + 2 = 45.
3. **Cross-reference resolution**: grep for `|agentic-config-permissions-tbl|` usages and confirm the matching `*agentic-config-permissions-tbl*` definition exists; same for `*agentic-config-auto_approve_trust_scope*`.
4. **Tag right-alignment**: spot-check that new option tags and renumbered headings keep tags ending at column 79.
5. **Open `:help agentic`** in nvim after edits to confirm tag index resolves the new tags and ToC links jump correctly.
6. **No content dropped**: confirm line count increased only by the net additions of Edits B/C and that no §12.x body paragraphs were lost during the renumber.

## Open questions
None. All six findings resolved against source: 1 confirmed (renumber body), 2 confirmed (eight missing options enumerated), 3 confirmed (both stale claims + altitude), 4 refuted (issue number correct — do not touch), 5 confirmed (package rename), 6 confirmed (convention, do-not-touch).

## Critical files for implementation
- `doc/agentic.txt`
- `lua/agentic/config_default.lua`
- `lua/agentic/utils/permission_rules.lua`
- `lua/agentic/acp/AGENTS.md`
- `.claude/skills/acp/references/claude-agent.md`
