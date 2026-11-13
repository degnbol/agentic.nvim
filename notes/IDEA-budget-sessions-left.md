# Idea: estimate how many sessions the budget has left

The budget lines show the fraction of each window used (`- 7d  96% used …`).
Add an estimate of how many typical sessions the rest of the window holds,
e.g. `≈ 5 sessions`, and perhaps the tokens left.

The provider reports only a fraction per window, with no token counts. So the
estimate must come from data that this plugin records: the change in
`utilization` while a session runs, compared with that session's token use
and duration. This needs the per-session tracking in
`IDEA-session-stats-logging.md` first.

Open points:
- Other clients (the TUI, claude.ai, other machines) use the same budget, and
  this plugin does not see their use. How to stop that use from inflating a
  session's cost: for example, take only spans where one session ran, or the
  median over many sessions.
- Whether the budget weights models or cache reads differently. If it does, a
  token count does not convert to one fraction, and the estimate is per model
  or in sessions only.
- What a "typical session" is: the mean, the median, or the user's recent
  sessions.
- How the estimate is marked as an estimate in the line (`≈`, `~`).
