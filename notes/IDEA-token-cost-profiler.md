# Idea: per-message token cost and session profiler

Surface how expensive each prompt/turn is and which messages dominate the
running context. Two views:

1. Inline indication per user prompt or assistant turn (delta input/output
   tokens, maybe a sparkline in the gutter).
2. A profiler view ranking top offenders for the session — large tool
   outputs, long file reads, verbose build/test logs.

Goal: spot when a single `cargo build` blows the budget so the user can
adjust workflow (output filtering, smaller scope, manual context pruning)
before hitting auto-compact. Data is in `usage_update` deltas; attribution
needs to associate the delta with the preceding tool call or message.

Offline measurement over transcripts and output filtering are parts 1 and 7
of `TRACK-token-usage.md`.
