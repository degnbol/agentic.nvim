# Bug: two command interceptions match on prefix, not on the command word

Line numbers against `bbbfe7e`. Found while planning
[`feature-block-dispatch.md`](feature-block-dispatch.md); live today, independent
of it.

Four of the six locally-intercepted commands are anchored at both ends
(`^/clear%s*$`, `^/context%s*$`, `^/delete%s*$`, `^/rename%s+(.+)$`) and are safe.
Two are not, so they fire on any word that merely *starts* with the command name.
Verified under `nvim -l`:

| Submitted first line | Pattern | Captures |
| --- | --- | --- |
| `/newsflash: build broken` | `^/new%s*` (`:1625`) | `"/new"` |
| `/trustworthy people` | `^/trust%s*(.*)$` (`:1651`) | `"worthy people"` |

`%s*` matches the empty string, so the command name needs no delimiter after it.

## Impact

**`/new` — data loss.** `/newsflash: build broken` runs `new_session()`, which
calls `_cancel_session` (`:2262`) and destroys the current session. The text is
discarded without ever reaching the provider, and the user sees a fresh session
instead of an answer.

**`/trust` — silent permission-state change plus data loss.** The captured
remainder falls through every recognised subcommand and reaches
`TrustSafety.compile_path_scope(arg, cwd)` (last line of `_handle_trust_command`),
so `"worthy people"` is compiled as a path/glob edit-trust scope and applied,
replacing whatever scope was active. The prose is discarded. Whether a
nonsense scope can compile to something *broader* than intended is unverified —
check `compile_path_scope` before assuming the effect is merely a no-op scope.

## Fix

Require a word boundary after the command name in both patterns: `^/new%f[%W]`,
or an explicit `^/new%s` / `^/new$` pair, or the exact-word table proposed as
`LOCAL_COMMANDS` in [`feature-block-dispatch.md`](feature-block-dispatch.md).

Fixing it standalone is a two-pattern change. Doing it via the table is only
worthwhile if that plan lands, since the table also serves the deferral gate and
the block sequencer.

## Why it gets worse under block dispatch

Today only the *first* line of a submit is tested, so the bug needs a prompt that
opens with `/newsflash…`. Block dispatch classifies every line, so any line
anywhere in a prompt triggers it — including a pasted transcript. Anchor the
patterns before or with that change, not after.

## Test

- `/newsflash: build broken` → sent as prose, session intact.
- `/trustworthy people` → sent as prose, trust scope unchanged.
- `/new`, `/new ` and `/trust repo` → still intercepted.
