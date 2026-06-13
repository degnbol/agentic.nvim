# Plan: Restructure and fix `lua/agentic/acp/AGENTS.md`

## Verification results (all findings checked against source)

| # | Finding | Result |
|---|---------|--------|
| 1a | AGENTS.md:737 / :743 `"Prompt loop stall" above` lives elsewhere | **CONFIRMED.** Target is `.claude/skills/acp/references/claude-agent.md:174` `## Prompt loop stall — silent notification loss with working permissions`. Not in AGENTS.md. |
| 1b | AGENTS.md:429 `"Edits are not applied before permission"` lives elsewhere | **CONFIRMED.** Target is `claude-agent.md:168` `### Edits are not applied before permission`. Not in AGENTS.md. |
| 2 | AGENTS.md:551 says "three layers", correct is four | **CONFIRMED.** AGENTS.md:257 says "runs **four** independent checks"; CLAUDE.md:499 says "**four** client-side auto-approval mechanisms" enumerating Read-only / Compound Bash / Allow-reject cache / Trust scope. The `## § Trust scope (/trust)` section exists at AGENTS.md:397. So :551 omits trust and undercounts. |
| 3 | Demote `## Execute tool call rendering` (:153) to `###` | **Cross-ref RISK CONFIRMED.** `CLAUDE.md:122` contains `@lua/agentic/acp/AGENTS.md § Execute tool call rendering`. Heading **text** must stay `Execute tool call rendering` (only the level `##`→`###` changes). A `§` ref matches by text, not level, so demotion is safe **as long as the text is unchanged**. No other refs. |
| 4 | Move `## Adapter override points` (:518) up | No external `§` ref to this heading text. Safe to move. |
| 5 | Split `## Known ACP limitations` | Cross-ref scan results below. |
| 6 | Redundancy: "Status is always real buffer text" (:124-129 vs :144-147), sign-borders (:102 vs :148-151) | **CONFIRMED** duplicated; no external refs to "Status is always real buffer". |
| 7 | Trailing colons :20, :27 | **CONFIRMED** `## Provider adapters:` and `## ACP provider configuration:`. No other heading has a trailing colon. No external `§` refs. |
| 8 | :686 "user_message_chunk replay point below" vs heading :693 | **CONFIRMED.** Heading at :693 is `### user_message_chunk contains full prompt content`. |
| 9 | :183 redundant `see shell_lang()` | **CONFIRMED.** `shell_lang()` introduced at :158 (same `## Execute tool call rendering` section), re-referenced at :183. |

### Cross-reference scan for finding 5 (headings moving under new parents)

External refs to limitation subsections (whole repo, `--no-ignore`):

- `CLAUDE.md:220` → `@lua/agentic/acp/AGENTS.md § "Chat buffer is UI only"`. Moves under new parent `## Session restore and history`. **Heading text unchanged** → safe.
- `TODO.md:209-210` → `AGENTS.md § "thought_level (effort) ConfigOption — claude-agent-acp"`. Moves under `## Provider-specific quirks`. **Heading text unchanged** → safe.
- `SKILL.md:148` → `AGENTS.md § "Silent upstream failure"`. **Stays** under `## Known ACP limitations` → safe.
- `CLAUDE.md:534` → `AGENTS.md § Allow/reject always cache`. Not touched by finding 5 → safe.
- `notes/agentic-treesitter-permissions.md:437` → `AGENTS.md § "Compound Bash commands"`. Not touched → safe.
- `README.md:46` mentions "Compound Bash command auto-approval" as prose, not a `§` ref → no lockstep needed.

**Conclusion: every reorder preserves heading TEXT, so no `§` pointer is orphaned. No lockstep edits to other files are required.** Invariant the implementer must hold: *change heading level and parent freely, never change heading text for any heading that is the target of a `§` ref* (Execute tool call rendering, Chat buffer is UI only, thought_level…, Silent upstream failure, Allow/reject always cache, Compound Bash commands).

All referencing files are git-tracked. AGENTS.md currently has uncommitted modifications (` M`).

## Existing cross-ref style in AGENTS.md

Two styles coexist:
- Full @-path (line 611): `` `@.claude/skills/acp/references/claude-agent.md` § "ConfigOptions — `thought_level` (effort)"``
- Relative "acp skill" (lines 275, 348): ``see acp skill `references/opencode.md` § "Permission request shape"``

**Finding 1 uses the @-path style** (line 611 is the precedent), since the targets are in `claude-agent.md`.

---

## Ordered edit sequence

Edits are ordered **NITS and text-only fixes first** (no line-number shifts to reasoning), then **reorders last** (largest content-movement risk). Within reorders, do them one at a time and re-locate ranges after each.

### Phase A — text-only fixes (no structural movement)

**A1. Finding 7 — strip trailing colons.**
- Line 20: `## Provider adapters:` → `## Provider adapters`
- Line 27: `## ACP provider configuration:` → `## ACP provider configuration`

**A2. Finding 1 — qualify the three stale cross-refs (text-only, preserve surrounding prose).**
- Line 429 (inside `### Trust scope`, item 3): replace `(before the SDK applies the edit — see "Edits are not applied before permission")` with `(before the SDK applies the edit — see @.claude/skills/acp/references/claude-agent.md § "Edits are not applied before permission")`.
- Line 737 (in `### Silent upstream failure`): replace `Same response shape as the claude-agent-acp stall (see "Prompt loop stall" above)` with `Same response shape as the claude-agent-acp stall (see @.claude/skills/acp/references/claude-agent.md § "Prompt loop stall")`. Drop the word "above".
- Line 743 (same section): replace `stalled generators per "Prompt loop stall"` with `stalled generators per @.claude/skills/acp/references/claude-agent.md § "Prompt loop stall"`.

**A3. Finding 8 — fix the quoted replay-point phrase at line 686.**
- Replace `This is the inverse of the "user_message_chunk replay" point below:` with `This is the inverse of the "user_message_chunk contains full prompt content" point below:`.

**A4. Finding 9 — remove the redundant backward `shell_lang()` ref at line 183.**
- In the sentence ending `…directly under `### Execute`, above the command fence (see `shell_lang()`).`, delete ` (see `shell_lang()`)`.

**A5. Finding 2 — fix the count and list at line 551.**
- Change "three" → "four" and add the trust-scope layer. New text:
  > This is why agentic.nvim implements **four** independent client-side layers (see "Client-side auto-approval" above): read-only tool approval, compound Bash command matching against `settings.json`, the per-session allow/reject always cache, and per-session `/trust` scope (git-recoverable auto-approval of file edits). For persistent rule management, users edit `~/.claude/settings.json` directly (or `.claude/settings.json` for project-local rules).
- Preserve the trailing settings.json sentence verbatim.

**A6. Finding 6 — deduplicate. Canonical home = the `## Key design rules for adapters` bullets (:144-151); trim the prose copy at :124-129.**

- *"Status is always real buffer text"*: full statement at :124-129 AND :144-147. Canonical = the bullet at :144-147 (keep verbatim). Trim :124-129 to a one-line pointer:
  > Status text is real buffer content, not virtual text, so it is robust to `vim.bo.syntax` state and survives line replacement (see "Status is always real buffer text" and "Sign column for borders" under Key design rules below).
- **Open question (preserve nuance):** the :124-129 paragraph carries the `vim.bo.syntax`/treesitter-independence detail the bullet lacks. Recommended: append "robust to `vim.bo.syntax` state" to the canonical bullet at :144-147 so no information is lost.
- *Sign-column borders*: the parenthetical at :102 (Phase-1 step 3) is a legitimate lifecycle step and **stays**. The rationale duplication is the :148-151 bullet, which is the canonical home; nothing to trim at :102. **Refined conclusion: the only true prose duplication to trim is the :124-129 paragraph.**

### Phase B — reorders (do last, one at a time, re-locate ranges after each)

**B1. Finding 3 — demote `## Execute tool call rendering` to `###` under `## Tool call lifecycle`.**
- Section spans lines **153-221** inclusive (includes child `### Description and output separation (claude-agent-acp)` at :170).
- Change line 153 `## Execute tool call rendering` → `### Execute tool call rendering` (**text unchanged** — preserves CLAUDE.md:122 ref).
- Demote the child `### Description and output separation` at :170 to `####`.
- **Placement:** move the 153-221 block to sit immediately after the Tool call lifecycle content (:88-129, trimmed by A6) and before `## Key design rules for adapters` (:131). New order: Tool call lifecycle → `### Execute tool call rendering` → `## Key design rules for adapters`. No prose dropped.

**B2. Finding 4 — move `## Adapter override points` up to the routing cluster.**
- Section spans lines **518-532** inclusive (heading + intro + 4-row table + the "Override when…" paragraph).
- Destination: insert immediately **after `## Session update routing`** (ends at :86) and **before `## Tool call lifecycle`** (:88). Puts the override-method table right after the routing table that references the same override points.
- Heading text unchanged; no `§` ref to update.

**B3. Finding 5 — split `## Known ACP limitations` into three top-level sections.**

Current children of `## Known ACP limitations` (:534) in document order:
1. `### No permission rule management via ACP` — :536-555
2. `### Buffer/disk divergence in diff matching` — :557-574
3. `### Slash commands intercepted locally` — :576-596
4. `### `thought_level` (effort) ConfigOption — claude-agent-acp` — :598-612
5. `### Mode switch kind inconsistency (claude-agent-acp)` — :614-625
6. `### Tool kind casing varies by provider` — :627-636
7. `### Permission optionId is opaque` — :638-644
8. `### Chat buffer is UI only — the model never reads it` — :646-691
9. `### user_message_chunk contains full prompt content` — :693-712
10. `### Non-JSON stdout/stderr forwarding` — :714-720
11. `### Silent upstream failure — opencode + litellm` — :722-761
12. `### opencode Edit diff not at content[1]` — :763-784 (EOF)

Target three-bucket layout:
- **`## Provider-specific quirks`** (new): Mode switch kind inconsistency (#5), Tool kind casing varies (#6), opencode Edit diff not at content[1] (#12), `thought_level` ConfigOption (#4).
- **`## Session restore and history`** (new): Chat buffer is UI only (#8), user_message_chunk contains full prompt content (#9).
- **`## Known ACP limitations`** (retained): No permission rule management (#1), Buffer/disk divergence (#2), Slash commands intercepted locally (#3), Permission optionId is opaque (#7), Silent upstream failure (#11), Non-JSON stdout/stderr forwarding (#10).

Mechanics (heading text on every subsection stays identical; only `##`/`###` nesting and ordering change):
1. Insert `## Provider-specific quirks`. Move #5, #6, #12, #4 (as `###`) under it, in that order.
2. Insert `## Session restore and history` after that. Move #8 and #9 (as `###`) under it, in document order (#8 then #9) so the :686 "below" pointer in #8 still points forward to #9.
3. Leave #1, #2, #3, #7, #11, #10 under `## Known ACP limitations`. Optional cosmetic reorder for coherence (suggested: #1, #2, #3, #7, #11, #10) — preserve all prose.
4. Verify the #8 → #9 "below" pointer (fixed in A3) still resolves: #9 must remain physically after #8.

**Caution:** #8 contains a "below" pointer to #9, so both must stay in the same relative order and same section.

### Phase C — final verification pass (read-only)

After all edits:
- `rg -n --no-ignore 'AGENTS.md § ' .` and confirm each target heading text still exists in AGENTS.md.
- Confirm `§ Execute tool call rendering`, `§ "Chat buffer is UI only"`, `§ "thought_level…"`, `§ "Silent upstream failure"`, `§ Allow/reject always cache`, `§ "Compound Bash commands"` all still resolve.
- Confirm no heading retains a trailing colon.
- Confirm the AGENTS.md:686 "below" pointer text matches the :693 heading and is physically after it.

No build step applies to markdown. No lockstep edits to other files are needed.

## Open questions for the author

1. **A6 nuance:** the :124-129 paragraph carries the `vim.bo.syntax`/treesitter-independence detail that the canonical bullet (:144-147) lacks. Recommend appending that clause to the canonical bullet rather than dropping it. Confirm.
2. **A6 scope:** :102 is judged a legitimate lifecycle step (not a rationale duplicate), so the only prose to trim is :124-129 — narrower than the review implied. Confirm.
3. **Finding 5, #7 `Permission optionId is opaque`:** not assigned a bucket by the review; recommend keeping under `## Known ACP limitations`. Confirm.
4. **Finding 5 intra-section reorder** of the retained `## Known ACP limitations` children is optional/cosmetic — confirm whether to reorder or leave in place.

## Critical files for implementation
- `lua/agentic/acp/AGENTS.md` (file being edited)
- `.claude/skills/acp/references/claude-agent.md` (finding-1 cross-ref targets at :168 and :174)
- `CLAUDE.md` (finding-2 count source at :499; `§` refs at :122 and :220 that constrain heading text)
- `TODO.md` (`§` ref at :209 to the thought_level heading being re-parented)
- `.claude/skills/acp/SKILL.md` (`§` ref at :148 to "Silent upstream failure")
