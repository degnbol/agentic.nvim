# Idea: a usage panel, and session logging

The info panel (`lua/agentic/ui/info_panel.lua`) mixes facts the user rarely
reads (agent, model, account) with numbers they read during a session to
decide whether to go on, start a new session, or hold off. The budget lines
are the second kind. The context line duplicates the chat title.

## Usage panel
A panel for the numbers a user reads during a session:
- The budget lines (`FEAT-budget-limit-eta.md`), updated live.
- This session's share of each window, e.g. `this session: 8% of 5h in 40m`,
  so a user can see whether this session uses up the budget.
- Later, the sessions-left estimate (`IDEA-budget-sessions-left.md`).

The info panel keeps the facts and loses the budget and context lines.

Claude's `/usage` command (also over ACP) already shows the limits, this
session's cost, API and active time, a token breakdown, and what uses the
limits, on demand. The panel does not repeat these. What it adds is a live
view and the forecast (`limit in ~`) that `/usage` does not give.

Per-model weekly windows (e.g. `Weekly · Fable`) stay out. Over ACP,
claude-agent-acp sends them only as `/usage` markdown, and the rate-limit
event has no named per-model window.

## Session logging
Record per-session measurements for analysis across sessions, with no view
for now:
- Turn count, duration, and token use per turn and per model.
- Utilization at the start and end of each turn, for the session's share of
  the budget.
- Permission decisions by decider: auto-approved, rejected, prompted.
- Per background agent (for example a skeptic): findings sent, and how many
  the main agent acted on.

Open points:
- Where the log lives: the session JSON, or a separate file per session
  (see `PERF-append-session-log.md`).
- How a session's share is measured while other sessions and clients use
  the same budget (see `IDEA-budget-sessions-left.md`).
