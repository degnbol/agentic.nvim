# Idea: more session logging, and a stats panel apart from the info panel

The info panel (`lua/agentic/ui/info_panel.lua`) mixes session facts with a
few stats. Record more per-session measurements and show them in their own
panel, so the info panel keeps only facts.

Candidate measurements:
- Turn count, duration, and token use per turn and per model.
- Permission decisions by decider: auto-approved, rejected, prompted.
- Per background agent (for example a skeptic): findings sent, and how many
  the main agent acted on.

Open points:
- Where the log lives: the session JSON, or a separate file per session
  (see `PERF-append-session-log.md`).
- Which stats a user reads during a session, and which only matter for later
  analysis.
