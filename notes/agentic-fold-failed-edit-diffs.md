# Fold (and explain) the diff of an edit that never happened

## Why this note exists

A plan exists at `~/.claude/plans/agentic-fold-rejected-diffs.md` marked
**"IMPLEMENTED (2026-06-02)"**. The implementation was real but lived only as
**uncommitted working-tree changes**, and the user **reverted them** after
seeing a folding bug (see "Observed bug" below). So it was never committed —
`git log` on `tool_call_renderer.lua` / `message_writer.lua` shows no
fold-reject commit, `git status` is clean apart from `TODO.md` + untracked
notes, and all three code sites are back in the pre-implementation state. The
reverted diff was discarded (no stash, no named commit), so it is not
recoverable for inspection.

This note records the verified current behaviour, the **bug that sank the first
attempt**, and a revised, smaller plan, with line numbers as they are **now**.

## Observed bug (why the first attempt was reverted)

User report on the reverted (uncommitted) implementation:

> weird folding — edits that shouldn't be folded, where every single line was a
> single line fold.

Two distinct symptoms:

1. **Edits that shouldn't be folded were folded.** Directly caused by the
   original decision 4 ("emit `-fold` on **every** diff fence so applied diffs
   become user-foldable"). Making every diff a `*-fold` fence means
   applied/in-progress diffs fold too, not just failed ones. This is the part
   to drop — see revised plan step 1.
2. **Every single line became its own single-line fold** — and the user saw
   this **on a diff that did NOT fail**. This is the load-bearing data point.
   Under the reverted approach every diff got a `*-fold` fence, so symptom 2 is
   triggered by putting `-fold` on a **diff fence itself**, independent of
   failure status. This is NOT what a single `*-fold` fence over
   `code_fence_content` should produce (that yields one whole-body fold), so
   something about a *diff* fence specifically — as opposed to the
   `console-fold` / `markdown-fold` fences that fold fine — breaks the fold
   shape. Likely the diff body's injected language (lua/python/… inferred from
   the path) interacting with `vim.treesitter.foldexpr()`, since console and
   markdown bodies do not carry a foreign injected parser the way a diff does.
   **Blocking unknown — must be root-caused, not worked around.**

   **Critical implication:** because the cause is `-fold`-on-a-diff and not
   failure, the failed-only approach below **does not avoid symptom 2** — the
   failed diff still gets a `-fold` fence. The failed-only change is still right
   (it kills symptom 1 and limits blast radius), but symptom 2 must be solved
   before this ships. If the injected-language interaction is the cause, the fix
   may be to fold the failed diff by a mechanism other than the info-string
   `-fold` suffix (e.g. an imperative manual fold over the body range, or
   stripping the injection on a failed diff so it folds as plain text).

## Verified current behaviour (read from source, not run)

For a rejected (or hook-blocked, or `old_string`-not-found) **edit**:

1. The diff-bearing `tool_call_update` arrives. At that point the *old*
   `tracker.diff` is nil, so `already_has_diff` (`message_writer.lua:1032`,
   computed **before** the merge at `:1035`) is `false`. The block renders in
   full — the diff appears, unfolded.
2. The rejection arrives as a `tool_call_update` with `status == "failed"`. Now
   `tracker.diff` is set, so `already_has_diff` is `true`, and the short-circuit
   at `message_writer.lua:1108` fires: only the status footer is rewritten
   (`apply_status_footer`), content is untouched, function returns early.

Result on screen: the **full unfolded diff**, with the footer flipped to
`failed`. The `failure_reason` is never rendered, because the short-circuit
pre-empts the re-render (`prepare_block_lines`) that would render it. The
streamed rejection boilerplate ("The user doesn't want to proceed…") is a
separate `agent_message_chunk`, suppressed by `suppress_next_rejection`
(`session_manager.lua:972-973`, `message_writer.lua:66`) — unrelated to the
`rawOutput` `failure_reason`.

Note: the renderer unit test "bypasses diff rendering when Edit fails"
(`tool_call_renderer.test.lua:264`) exercises `prepare_block_lines` directly
with `status="failed"` + `failure_reason`. That is NOT the live path — live,
the short-circuit means `prepare_block_lines` is never reached on the failed
transition. Do not treat that test as evidence of live behaviour.

## Goal

When an edit (or write/create/move) never executed, collapse its verbose diff
with the existing treesitter fold, **closed**, and show the short failure reason
beneath the fold. Hide the noise, keep the explanation. Do not substitute the
reason for the diff (the reverted first attempt's mistake).

Out of scope: `execute`. A non-zero exit **did** run, so its output stays as
today (folded only past `execute_max_lines`).

## The fold mechanism is already complete — only the trigger is missing

Fold-closing is automatic: `write_tool_call_block` / `update_tool_call_block`
call `_close_fold(start_row + fold_anchor)` whenever `prepare_block_lines`
returns a non-nil `fold_anchor` (`message_writer.lua:956-957`, `1234-1235`).
`folds.scm` folds the body of any fence whose info string ends in `-fold`.

Today an edit yields `fold_anchor = nil` on every branch:
- Diff branch (`tool_call_renderer.lua:605-620`) deliberately strips `-fold`
  (the `foo.x-fold` path-collision guard) and emits a plain `lang` fence.
- Failure branch (`tool_call_renderer.lua:463-488`) gates the fold to
  `kind == "execute"` (`exec_max_lines = kind == "execute" and … or 0`,
  `:470-473`).

So no fold node exists → nothing for `_close_fold` to close.

## Plan

Three decoupled concerns: *does a fold exist*, *does it start closed*, *what
else renders*. **Revised from the stale `~/.claude/plans/` version**: that
version's decision 4 (fence *every* diff) caused symptom 1 above, so this plan
drops it. Only **failed** diffs get a fold. Applied/in-progress diffs are left
exactly as today — no fence change, no fold, zero behaviour change and zero
risk of unwanted folding (symptom 1). This does **not** address symptom 2,
which afflicts any `-fold` diff fence including the failed one — see the
blocking root-cause step in Verification.

### 1. Renderer: `-fold` on the diff fence ONLY when failed

`tool_call_renderer.lua:611,619-620` — keep stripping a path-inferred `-fold`
(the collision guard), then append our own `-fold` **only when
`status == "failed"`**. Applied / in-progress diffs keep the plain `lang`
fence and never fold (identical to today). This is the key divergence from the
reverted attempt — it eliminates symptom 1 by construction.

### 2. Renderer: emit `fold_anchor` only when failed

In the diff branch, return `fold_anchor` (0-indexed offset of the first diff
body line) **only when `status == "failed"`** — the sole trigger for
`_close_fold`. Pairs with step 1:
- applied / in-progress diff → plain fence, `fold_anchor` nil → no fold
- failed diff → `*-fold` fence, `fold_anchor` set → auto-closed

### 3. Renderer: render diff + reason, not reason-instead-of-diff

The `status == "failed"` check (`:463`) currently precedes the diff branch, so
for a failed edit it would render reason-only. Flip the order so the diff branch
handles the failed case internally:

```
if diff then
    -- render diff with the -fold suffix
    if status == "failed" and failure_reason then
        -- append failure_reason lines below the closing fence
        -- set fold_anchor to the first diff body line
    end
elseif status == "failed" and failure_reason then
    -- non-diff kinds (execute/read/search/fetch): reason-only, as today
end
```

Keep the existing reason styling — short denial strings keep the red
`ERROR_BODY` highlight (rejection / hook block / `old_string` not found are all
short, non-execute). Execute keeps its current soft-console no-tint handling.

### 4. message_writer: re-render on the failed transition only

`message_writer.lua:1108` — change the short-circuit from `if already_has_diff`
to `if already_has_diff and tool_call_block.status ~= "failed"` (or equivalent
on the merged `tracker.status`; pick whichever is in scope at that line — the
merge has already happened by `:1108`, so `tracker.status` is current).

The failed transition then re-renders, which (a) appends the reason and (b)
applies the fold via the existing `fold_anchor` → `_close_fold` path. **Safe
despite the frozen-diff invariant**: a failed file-mutating tool never applied
its change, so the file is unchanged and re-extraction reproduces the same
diff. The `completed` path keeps the short-circuit (file DID change — must not
re-extract). Prefer `tracker.cached_diff_blocks` when present so the re-render
never re-extracts at all (`cached_diff_blocks` set at `tool_call_renderer.lua:602`).

Edge cases already covered by existing fallbacks:
- `old_string` not found, non-empty `diff.old` → array fallback renders from
  `diff.old`/`diff.new` directly.
- new-file creation rejected (`diff.old` empty) → `extract_diff_blocks` returns
  a valid new-file block, `+` lines render normally.

### Why not the alternatives

- Re-render that lets the failure branch replace the diff → the reverted first
  attempt. Discards the diff.
- Rewrite the fence to `-fold` on the failed transition without re-rendering →
  re-setting the fence line reopens the fold, forcing a re-close dance. Emitting
  `-fold` up front is simpler.

## Failure-reason contents (previously observed live — spot-check on build)

Recorded in the stale plan from a live claude-agent-acp run. Re-confirm during
implementation, since `rawOutput` shape is provider-specific and not
reproducible headless:

- user rejection → `User refused permission to run tool`
- hook block → the hook's own message, e.g. `Load /coding skill first.`
- `old_string` not found → expected to be the SDK edit-error string — not yet
  spot-checked.

The reason text distinguishes the cases on its own, so no `is_rejection`
render-time branch is needed.

## Verification (when authorised to build)

**Blocking first step — reproduce symptom 2 before building.** Render a failed
edit with a multi-line diff in a headless chat buffer and inspect
`foldlevel`/`foldclosed` per line. Confirm the `*-fold` diff fence produces
**one** whole-body fold, not a fold per line. If per-line folds appear, root-
cause it (diff body not parsing as one `code_fence_content`, injected-language
sub-folds, or foldexpr level drift) and fix that *first* — the close logic is
irrelevant until the fold shape is correct. This is the symptom that sank the
first attempt and it must be understood, not worked around.

Then (mirror the migration plan's fold spike, reuse `fold_fence_lines` /
`wait_closed` from `message_writer.test.lua`):

1. Edit block with `status="failed"` + `failure_reason` → assert a `*-fold` diff
   fence exists, `foldclosed(body_start)` reports closed after the deferred
   close, exactly ONE fold spans the diff body, and the reason lines render
   **after** the diff fence, not in place of it.
2. Applied (`completed`) and `in_progress` edits → diff fence is the **plain**
   `lang` fence (no `-fold`), no whole-body fold, identical to today. (Guards
   symptom 1 — no unwanted folding on edits that ran.)
3. `in_progress` → `failed` transition → folds the diff and appends the reason
   **without** discarding the diff (guards the reverted regression).

Live: rejection and hook block already observed; spot-check `old_string`-not-
found `rawOutput` against the real provider.

## Tests / docs to touch

- `lua/agentic/ui/message_writer.test.lua` — add cases under the existing
  `tool call folding` describe block: failed diff folds + reason-below, applied
  diff foldable-but-open, transition folds without discarding the diff.
- `CLAUDE.md` — update the `safe_fence` fence table row for diffs (now
  `*-fold`, auto-closed on failure, reason rendered below) and the
  `Tool call body folding` section.
- After landing, either delete `~/.claude/plans/agentic-fold-rejected-diffs.md`
  or flip its status to reflect reality.
