# Idea: archive sessions from before a compaction

When the provider compacts and a new session_id replaces the current one,
the previous cache JSON keeps its full message history but the new session
inherits the same title (user often `/rename`s the continuation to the same
short name). Two cache entries end up sharing a title; completion and the
resume picker both surface the older one. We usually don't want to resume a
compacted conversation — the provider only has the summary anyway.

Idea: on compaction, mark the pre-compaction session as archived (e.g.
append " (pre-compaction)" to its title, or move its JSON to an archive
subfolder) so the active session keeps the clean name. The full
pre-compaction history stays preserved as a record.

Related: resume right after compacting shows only the compaction summary,
not the history before it (bug in `TODO.md`).

## Open questions

- How to detect the compaction event from ACP (session_update? title
  change? new session_id under same tab?)
- The cache filename uses session_id, so archival requires a parallel
  naming scheme or a marker field inside the JSON.
