# Plan: blame a line to the agent turn that wrote it
Status: draft
Priority: P3
Depends:

## Relevant files
- pi session files (`<agent-dir>/sessions/--<cwd>--/<timestamp>_<session-id>.jsonl`,
  pi docs `session-format.md`, `message-types.md`): an `edit` tool call has
  `path` and `edits: [{ oldText, newText }]`; its `toolResult` message has
  `details.patch` (a unified patch) and a `timestamp`. A `write` call has
  `path` and `content`. Claude turns through `pi-claude-bridge` are in
  these files too, as pi runs the tools.
- Chat sessions: `~/.cache/nvim/agentic/sessions/<cwd>_<hash>/<chat-id>.json`.
- `REFACTOR-pi-only.md` step 10 (harness and UI).

## Background
`git blame` names the commit of a line, not the session, turn and prompt
that wrote it. One commit often holds the edits of several turns, and
uncommitted lines have no commit. pi's session files already record each
edit as a patch with a timestamp, so the writer of a line can be found
from them.

## Changes
1. A command-line tool: `<tool> <file> <line>` (or a line range). It prints
   one record per line: session id, session file, timestamp, the user
   prompt of the turn, the tool call id, the patch hunk. Output is JSON, so
   any UI can use it.
2. Index: for each session file below the file's project, the edit tool
   calls on that path, ordered by time.
3. Match: walk the edits from newest to oldest, and replay each patch's line
   map on the line, until a patch adds the line. With `git blame`, start
   only from edits before the line's commit time; an uncommitted line
   starts from now. A `write` call has no patch: it adds every line of its
   `content`.
4. Neovim: a command that runs the tool for the cursor line and opens the
   matched turn in the chat view. Designed separately (step 9 of
   `REFACTOR-pi-only.md`).

## Expected outcome
- For a line written by an agent edit tool, the tool names the session,
  the turn and the prompt.
- For a line with no matching edit, it says so and gives the `git blame`
  result.

## Non-goals
- Lines written by shell commands (`sed -i`, scripts, formatters): they
  have no patch in the session file.
- Edits by the user between agent turns, beyond reporting "no match".
- Claude Code session files (`~/.claude/projects/`): sessions from before
  Claude ran on pi.

## Open questions
1. Whether to replay patches from each session's start (exact, slow for
   long sessions) or match the line text against added lines with the
   hunk's context lines (fast, wrong for repeated lines such as `end`).
   Failed edits (`isError`) have no patch and are skipped in either case.
2. Which session files to search. pi keys a session directory by the
   session's cwd, and a session started in a parent or sibling directory
   can edit the file. Subagent and child sessions too?
3. Session trees: an edit on an abandoned branch still changed the disk.
   Match in file order (time) or in tree order?
4. Language and place of the tool. It is a CLI that reads session files,
   not a pi extension.
