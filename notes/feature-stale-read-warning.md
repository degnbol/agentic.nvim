# Plan: stale-read warning on Edit/Write

## Problem

The Edit tool's `old_string` enforcement guarantees that `old_string`
appears verbatim in the current file. It does **not** guarantee that the
*surrounding* file state matches what the agent saw on its last Read.
When the user (or an external process) reworks part of the file between
Read and Edit, the agent's `new_string` is constructed from a stale
mental model and may silently overwrite that rework — even when the tool
call itself succeeds. The hazard is region-level: only edits whose
target overlaps the post-Read modification actually clobber.

## Constraints

- **Scope is every Edit/Write, not just trusted ones.** The trust scope
  (`/trust repo|here|<path>`) opts into auto-approval; staleness applies
  regardless and must run before/independently of `_check_trust`.
- **Provider-agnostic.** Reads from any ACP provider (Claude, opencode,
  Codex, …) must populate the snapshot. Hook on `tool_call` with
  `kind == "read"`, not on Claude-specific paths.
- **No new ACP message types.** Use the existing permission flow's deny
  path to surface the warning to the model — denial reason is forwarded
  as the tool result.

## Existing infrastructure to reuse

| Primitive | Location | Role |
| --- | --- | --- |
| `stat_snapshot` / `stat_unchanged` | `trust_safety.lua:368–399` | Capture and compare mtime_sec/nsec/size — generic external-change detector |
| `find_subsequence` / `find_unique_subsequence` | `trust_safety.lua:171–250` | Locate target lines in a file |
| `edit_target_range` | `trust_safety.lua:340–362` | Resolve an Edit's `diff.old` to a line range in the current file |
| `range_overlaps` / `any_overlap` | `trust_safety.lua:203–227` | Range arithmetic |
| `_try_record_edit_range` | `session_manager.lua:779` | Pattern for hooking `_on_tool_call` and stashing per-tool state on `PermissionManager` |
| `_check_trust` | `permission_manager.lua:208` | Per-tool gate run before approval UI; new check inserts here |
| `_pending_edits` / `_edit_records` table | `permission_manager.lua` | Storage shape to mirror for `_read_snapshots` |

`FileSystem.read_from_disk(path)` is already used by
`_try_record_edit_range`; reuse it for the Read-time snapshot.

## Approach decisions

### Channel: deny tool with structured reason

When staleness is detected, return `behavior = "deny"` from the
permission flow with a reason string of the form:

> `<path>` changed since your last Read (line N modified). Re-Read
> before constructing `old_string`/`new_string`.

The model receives this as the tool result and re-Reads. No new
injection channel needed. This is a hard block — staleness is a
correctness issue, not a steerable preference.

### Snapshot at Read time: lines, not just stat

`stat_unchanged` alone tells us "something changed" but not whether the
change overlaps the edit region. For region-level precision we need to
diff snapshot-at-Read vs current. Store the file's lines (returned by
`FileSystem.read_from_disk`) keyed by canonicalised absolute path on
`PermissionManager._read_snapshots`. Overwrite on subsequent Reads of
the same path.

Storage cost: O(session-read-bytes). Acceptable; cap with an LRU if it
becomes a problem.

### Write with `diff.all == true`

Whole-file overwrite. Any change since Read is at-risk because the
entire file content is replaced. Deny on any `stat_unchanged == false`
without further region analysis.

### Untracked / non-existent files

`git_files.Hunk` data isn't needed in this design — staleness is
computed by diffing the Read snapshot against the current file, not by
inspecting unstaged hunks. Files outside any git repo are handled
identically to tracked files.

### Files never Read this session

No snapshot → no comparison possible. Defer to the existing "must Read
before Edit" enforcement (already implemented in the Edit tool
itself); the new check exits early.

### Same-tool self-writes

Edit/Write succeeding updates the file's mtime, but the agent's own
write is not a stale source. After a successful Edit/Write, treat the
post-edit content as the new snapshot for that path (write the
finalised lines into `_read_snapshots`, same shape as
`_edit_records` finalisation).

## Implementation outline

1. **`SessionManager:_try_record_read_snapshot(tool_call_id)`** — mirror
   `_try_record_edit_range`. On `_on_tool_call` for `tool_call.kind ==
   "read"`, normalise the path from `rawInput`, read the file, and call
   `permission_manager:record_read_snapshot(path, lines)`.
2. **`PermissionManager:record_read_snapshot(path, lines)`** — store on
   `self._read_snapshots` keyed by path, value `{ lines = lines, stat = stat_snapshot(path) }`.
   Stat captured at the same instant — used as a fast-path skip when
   unchanged.
3. **`PermissionManager:_check_stale_read(tool_call) -> safe, reason`**
   — called from `_try_auto_approve` *before* `_check_trust` for edit /
   write / move kinds. Steps:
   - Resolve the target path. Look up the recorded snapshot. Miss →
     return safe (no baseline).
   - Fast path: `stat_unchanged(path, snapshot.stat)` → safe.
   - Compute `edit_target_range(diff, current_lines)`. For Write
     `diff.all` → range is whole file.
   - Diff `snapshot.lines` vs `current_lines` to find changed line
     ranges (use `vim.diff` with `result_type = "indices"`).
   - If any changed range overlaps `edit_target_range` → unsafe with
     reason naming the first overlapping line.
4. **Wire `_check_stale_read` into `_try_auto_approve`** — return
   `deny` on unsafe, threading the reason into the permission callback.
5. **Refresh snapshot after own writes.** On Edit/Write completion
   (`_on_tool_call_update` with `status = "completed"`), re-read the
   file and overwrite the recorded snapshot for that path. Already-running
   `_try_record_edit_range` reads the file pre-edit; finalisation
   should mirror it post-edit.
6. **Tests** under `lua/agentic/utils/trust_safety.test.lua` and a new
   integration test exercising Read → external edit → Edit denial.

## Residual open questions

1. **Diff granularity for the reason message.** `vim.diff` returns line
   ranges; reporting "line N changed since last Read" is fine. For
   multi-hunk changes, name the first overlapping hunk only or list
   all?
2. **Auto-approve read-only path.** `_try_auto_approve` short-circuits
   on read-only kinds before `_check_trust` (`permission_manager.lua:246`).
   `_check_stale_read` runs for Edit/Write/Move only — confirm Move's
   source path needs the same staleness gate as Edit.
3. **Snapshot eviction.** Cap at N paths or N total bytes? Default N
   high enough that typical sessions never evict.
4. **Cross-session resume.** Snapshots live on `PermissionManager` and
   are session-local. After a resume from JSON the snapshot is empty
   for all paths; the first Edit/Write after resume falls through to
   "no baseline → safe". Acceptable — the model will Read again before
   editing in practice. Document and move on.
