# Idea: session retention

Session files are never deleted. Add a config option, e.g.
`sessions.max_age_days` (default 60), that deletes session files older than
that when the sessions are listed.

On 2026-10-03, 1774 of 2176 files (198 of 271 MB) were older than 60 days.

Compression (gzip about 3.8× smaller) was rejected for now: Neovim has no
zlib, and every reader (`list_sessions`, the fzf preview, grepping by title)
would have to decompress.
