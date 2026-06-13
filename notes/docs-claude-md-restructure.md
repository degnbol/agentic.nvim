# Plan: Restructure agentic.nvim CLAUDE.md

Target file: `CLAUDE.md`
(git-tracked; markdown, no build step). This is a **project-instructions**
file loaded by Claude Code, not just a reference doc — the heading structure
affects how it reads as instructions.

## Verification results (done before planning)

All findings checked against the actual file and the repo.

1. **Load-bearing move — CONFIRMED.**
   - `## Code fence handling` is at **line 107**.
   - Its `safe_fence` table (lines **122-125**) already uses the
     `-fold` / `console-fold` / `markdown-fold` vocabulary, and line 122
     contains the forward reference `(see Tool call body folding)`.
   - `## Tool call body folding` is at **line 159** — 52 lines *after* the
     section that consumes its vocabulary.
   - This is a genuine read-order dependency: the fence table names the
     `-fold` mechanism, the folding section defines it. The author's own
     forward-pointer confirms the dependency. **Fix: move folding above
     fences.**

2. **Cross-reference safety — CONFIRMED safe to move.**
   - Internal mentions of the two section titles (repo-wide grep):
     - `CLAUDE.md:107` — the `## Code fence handling` heading itself.
     - `CLAUDE.md:122` — `(see Tool call body folding)` inside the fence table.
     - `CLAUDE.md:159` — the `## Tool call body folding` heading itself.
   - No internal cross-reference uses line numbers — all are section-name
     anchors, so reordering does not break them. After the move, the
     `:122` pointer becomes a **backward** reference (improvement).
   - External: `notes/agentic-fold-failed-edit-diffs.md:233` references
     "the `Tool call body folding` section" by **name only** (a to-do note).
     Unaffected by reordering. No source file references either section.

3. **Redundancy — CONFIRMED acceptable, leave as-is.**
   - Sidecar dimming: defined at `:95-97` (AgenticDimmedBlock), referenced at
     `:124` ("see AgenticDimmedBlock note above" — correct backward ref) and
     touched at `:181`/`:187-188` (folding section, different angle: which
     bodies fold). The cross-refs resolve and point the right direction.
   - "Never double-wrap": stated at `:122` (execute body, cites AGENTS.md
     unwrap) and `:143-144` (search body, explains the body arrives raw).
     Two distinct tool kinds with distinct reasons — not true duplication.
   - **Decision: no trim.** The cross-refs make the repetition intentional
     and each instance is locally self-contained. Trimming would force a
     reader to jump sections to understand one tool kind. Not worth churn.

## Phase 1 — Load-bearing move (DO REGARDLESS)

Move the entire `## Tool call body folding` section to sit immediately
**above** `## Code fence handling`. Pure block relocation: no prose edited,
added, or dropped.

### Exact line ranges (current file)

- **Block to move:** lines **159-214 inclusive** — from `## Tool call body
  folding` (159) through the end of that section. The section's last content
  line is 214 (`pitfall").`); line 215 is the blank separator before
  `## Session lifecycle races...` at 216.
- **Insertion point:** immediately before line **107** (`## Code fence
  handling`), i.e. after line 106 (the blank line following the
  `## Tool call block rendering` section that ends at 105).

### Resulting order (sections 76-214 region)

1. `## Tool call block rendering`  (unchanged, currently 76-105)
2. `## Tool call body folding`      (moved up — was 159-214)
3. `## Code fence handling`         (was 107-131)
4. `## Search tool call rendering`  (was 133-157)
5. `## Session lifecycle races...`  (unchanged, 216+)

Rationale for this exact slot: folding defines the `-fold` vocabulary, so it
must precede the fence table that uses it. Placing it directly after
"Tool call block rendering" keeps the three tool-call-rendering sections
contiguous and orders them frame → fold-mechanism → fence-detail → search.

### Mechanical edit recipe (content-preserving)

The mover must perform a cut-and-paste with **zero** text changes to the
moved block:

1. Cut lines 159-214 (the `## Tool call body folding` section body) plus
   handle the surrounding blank lines so exactly one blank line separates
   sections at both the old and new locations:
   - At the **old** location, after removal, ensure `## Search tool call
     rendering` ... is followed by `## Session lifecycle races` separated by
     a single blank line (the blank at 158 that preceded the moved block, and
     the blank at 215 that followed it, must collapse to one).
   - At the **new** location, insert the block between line 106 (blank) and
     line 107 (`## Code fence handling`), with one blank line after the moved
     block's last line and before `## Code fence handling`.
2. Do not touch any word inside the moved block, including the
   `(see Tool call body folding)` pointer at old line 122 — it now resolves
   backward, which is fine.

### Phase 1 verification (after edit)

- Re-grep `CLAUDE.md` for `## Tool call body folding` and `## Code fence
  handling`: confirm folding heading now appears at a smaller line number
  than the fence heading.
- Re-grep for `-fold` / `console-fold` / `markdown-fold`: confirm the first
  *definition* (folding section) now precedes the first *use* (fence table).
- Confirm no `(see ...)` pointer now references a forward section.
- `git diff --stat CLAUDE.md` should show a near-equal add/delete count
  (block relocation), and `git diff` body lines should be identical text,
  just repositioned.

## Phase 2 — Optional H2 grouping (USER DECIDES — independent of Phase 1)

The review proposes wrapping the ~20 flat `##` sections under a handful of
new top-level groups (Conventions & gotchas / Tool-call rendering /
Architecture / ...), demoting current `##` to `###`.

### Recommendation: DO NOT do the deep grouping. Skip Phase 2.

Honest assessment for an **instructions** file (not a reference manual):

- **Instruction files are read top-to-bottom by the model, not browsed by a
  human via a ToC.** A two-level ToC's main payoff (scan-and-jump) does not
  apply. The model ingests the whole file regardless of nesting.
- **Demoting 20 `##` to `###` under 4-5 new `##` adds a heading layer
  without removing any content.** That is pure churn against a git-tracked
  instructions file — every section line changes, inflating the diff and any
  future blame, for no behavioural gain.
- **`@`-mention anchors and the existing cross-refs are section-name based.**
  Re-nesting risks nothing functionally but gains nothing either.
- The one place ordering *matters* (folding-before-fences) is fixed by
  Phase 1 alone. Grouping does not fix a correctness problem; it is cosmetic.

### If the user still wants grouping (minimal variant only)

Should the user prefer some structure, do the **lightest** possible version
and nothing more:

- Add **only** the `## Tool-call rendering` group, since those four sections
  (Tool call block rendering, Tool call body folding, Code fence handling,
  Search tool call rendering) are already contiguous after Phase 1 and form
  one genuine topic. Demote those four to `###` under it.
- Do **not** introduce `## Conventions & gotchas` or `## Architecture`
  umbrellas — those bundle unrelated sections (e.g. "You are running through
  this plugin" is a runtime-host caveat, not a "convention"; "Key files" is a
  pointer list) and the umbrella label adds interpretation the reader must
  undo.
- Keep Phase 2 as a **separate commit** from Phase 1 so the load-bearing move
  is reviewable on its own and can land independently.

Default stance to present to the user: **Phase 1 only; decline Phase 2.**

## Sequencing & commits

1. Apply Phase 1 (the move). Verify as above. This is the whole required
   change.
2. Present Phase 2 to the user as optional, with the recommendation to skip.
   If accepted, do only the minimal `## Tool-call rendering` variant, in a
   second commit.

No build step (markdown). `make validate` is for Lua only — not needed here.

## Critical files for implementation

- `CLAUDE.md` (the only file edited)
- `notes/agentic-fold-failed-edit-diffs.md` (external name-only reference to verify still resolves; not edited)
