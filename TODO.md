# TODO

Release goal and versioning: [`RELEASING.md`](RELEASING.md).

Priority: P1 high (breakage), P2 medium (cosmetic), P3 low (edge-case). A
note without one sorts last. Loose ideas: [`IDEAS.md`](IDEAS.md).

## Inline bugs

- File activity panel keeps a deleted file until toggled off and on
  (`FileActivity:reconcile` runs once per toggle).
- Visual-mode `<Plug>(agentic-send)` adds the selection to context instead
  of sending it (`plugin/agentic.lua:52`); `:h agentic-plug-mappings` is right.
- Cursor flickers while a command runs, e.g. a `git push` with heavy hooks.
- The cancel sweep keys on `stopReason == "cancelled"`: an errored turn, a
  provider that never answers (needs a sweep in `SessionManager:_refresh`),
  or a call cut off by a cancel keeps a status line that never reaches a
  final status.
- A search command with nested quotes displays wrong:
  `rg -n ""todowrite"|@alias" …`.
- Markdown in a prompt leaks into the chat (`##` makes a heading); provider
  colours sometimes break the same way.
- Treesitter highlighting from a previous block sometimes bleeds into the
  permission prompt.
- A Fetch tool call shows a wrong title; the format varies.
- Large tool outputs (long file reads) lag the chat write.
- Edit diff highlighting reconstructs and parses the file once per hunk per
  side (`highlight_map_in_context` from `hunk_rows`, `tool_call_layout.lua`).
- The terminal bell rings at every turn end while the chat is unfocused,
  not only when input is needed.
- A mouse click from insert mode in the input into the chat leaves insert
  mode on in the chat. Leave insert mode whenever the chat gets focus.
- Resume right after compacting shows only the compaction summary, not the
  history before it.
- A `/word` line inside a prompt's code fence dispatches and highlights as a
  command; a CRLF line classifies differently in the two (`\s` vs `%s`).
- opencode: a write of a new file shows only `### Edit` and the path.
- opencode: parallel tasks do not show in the chat (fixed for claude; audit
  the claude-only fixes).
- `ExitWorktree` is missing from `ClaudeUtils.MODE_SWITCH_TOOLS` and renders
  as an unrecognised tool (never observed).
- `allow_always` caches on kinds its own table cannot match:
  [`REFACTOR-acp-kind-normalisation.md`](notes/REFACTOR-acp-kind-normalisation.md) §1d.

## Index

<!-- BEGIN plan-index -->

### Tracks

**Failed execute block body offset**
1. P2 [FIX-silent-errors.md](notes/FIX-silent-errors.md): no error reported only through `Logger.debug` — reviewed — blocked on open questions 2 and 3 (items 1 and 7 wait on them); items 2-6, 8-9 ready
2. P3 [FIX-failed-execute-body-offset.md](notes/FIX-failed-execute-body-offset.md): Failed execute block body offset — reviewed (open questions); the offset is fixed, open question 2 stays; may retire: a rejected call no longer draws the deny-rule merged body, its only reachable case (after 1)

**Guard a heading whole when the adapter knows it is a command**
1. P2 [FIX-placeholder-titles.md](notes/FIX-placeholder-titles.md): Claude tool call heads from rawInput, not the bridge title — reviewed (open questions)
2. P3 [FIX-heading-command-flag.md](notes/FIX-heading-command-flag.md): Guard a heading whole when the adapter knows it is a command — reviewed spec — on hold, no reproducer (after 1)

**opencode subagents in their own transcripts**
1. P2 [FIX-opencode-child-title-prefix.md](notes/FIX-opencode-child-title-prefix.md): opencode child-call titles without the subagent prefix — reviewed spec
2. P2 [FEAT-opencode-subagent-transcripts.md](notes/FEAT-opencode-subagent-transcripts.md): opencode subagents in their own transcripts — reviewed spec (after 1)

**one approve walk; the tally is that walk with no effects pinned**
1. P3 [REFACTOR-leaf-classification.md](notes/REFACTOR-leaf-classification.md): one structured classification and one leaf front per command leaf — spec
2. P3 [REFACTOR-redirect-effect.md](notes/REFACTOR-redirect-effect.md): one classifier for what a file redirect does — spec
3. P3 [REFACTOR-one-shell-walk.md](notes/REFACTOR-one-shell-walk.md): one approve walk; the tally is that walk with no effects pinned — spec (after 1, 2)

**one file activity tally per agent**
1. P3 [REFACTOR-subagent-shared-keys.md](notes/REFACTOR-subagent-shared-keys.md): one binding of a subagent's keys on its transcript and its input — spec
2. P3 [FEAT-per-agent-file-activity.md](notes/FEAT-per-agent-file-activity.md): one file activity tally per agent — draft (after 1)

**one-row fold rule and collapsed-region layout**
1. P3 [REFACTOR-prose-run-rows.md](notes/REFACTOR-prose-run-rows.md): one shift rule for prose-run rows, one end-of-run reflow — spec
2. P3 [REFACTOR-tool-block-rows.md](notes/REFACTOR-tool-block-rows.md): one reader of a tool call block's rows; the diff freeze recorded on the block — reviewed spec (after 1)
3. P3 [REFACTOR-collapsed-region-layout.md](notes/REFACTOR-collapsed-region-layout.md): one-row fold rule and collapsed-region layout — spec (after 2)

### Bugs

- P1 [FIX-tripwire-uncalled-opencode-call.md](notes/FIX-tripwire-uncalled-opencode-call.md): Mark an opencode call that failed before it got its input as not run — spec
- P2 [FIX-cancel-request-handler.md](notes/FIX-cancel-request-handler.md): Handle `$/cancel_request` for permission requests — spec
- P2 [FIX-deny-gate-flag-cap.md](notes/FIX-deny-gate-flag-cap.md): exact multi-element positional matching (remove the flag cap) — reviewed (open questions)
- P2 [FIX-v2-edit-write-gaps.md](notes/FIX-v2-edit-write-gaps.md): ACP v2 Edit/Write diffs — every hunk, and the patch facts — draft
- P3 [BUG-glob-redirect-as-argument.md](notes/BUG-glob-redirect-as-argument.md): a redirect with no space before a glob or brace target auto-approves
- P3 [BUG-tripwire-display-path.md](notes/BUG-tripwire-display-path.md): the background-session tripwire judges an edit by its display path
- P3 [FIX-context-highlight-parser-gate.md](notes/FIX-context-highlight-parser-gate.md): check that a parser exists before context highlighting — reviewed spec
- P3 [FIX-inline-math-dollar-pairing.md](notes/FIX-inline-math-dollar-pairing.md): inline-math dollar pairing in prose wrap — reviewed (open questions)
- P3 [FIX-model-selector-order.md](notes/FIX-model-selector-order.md): Model selector order — reviewed spec
- [BUG-bd-panel-loses-state.md](notes/BUG-bd-panel-loses-state.md): main panels lose buffer options, b-vars and keymaps after `:bd`
- [BUG-child-todowrite-overwrites-todos.md](notes/BUG-child-todowrite-overwrites-todos.md): a subagent's TodoWrite list replaces the main agent's todos
- [BUG-create-fold-never-fires.md](notes/BUG-create-fold-never-fires.md): `create_max_lines` folds a created file only on the streaming path
- [BUG-ctrl-c-reject-continues.md](notes/BUG-ctrl-c-reject-continues.md): `<C-c>` at a permission prompt rejects, and the agent continues
- [BUG-duplicate-unordered-effect.md](notes/BUG-duplicate-unordered-effect.md): an unordered walk lists a write effect twice — draft
- [BUG-error-classification-structured-errorkind.md](notes/BUG-error-classification-structured-errorkind.md): Usage-limit errors without a reset clause are not classified
- [BUG-family-head-reset.md](notes/BUG-family-head-reset.md): a family kind's head drops its detail on a later update
- [BUG-header-defaults-missing-panels.md](notes/BUG-header-defaults-missing-panels.md): panels missing from the `headers` defaults get a winbar
- [BUG-matcher-depth-overflow.md](notes/BUG-matcher-depth-overflow.md): a long command overflows the permission matchers' stack
- [BUG-no-reply-after-auto-continue.md](notes/BUG-no-reply-after-auto-continue.md): no reply shown after auto-continue
- [BUG-partial-send-char-range.md](notes/BUG-partial-send-char-range.md): a charwise partial send cuts or drops the last char — draft
- [BUG-path-b-replay-empty-argument.md](notes/BUG-path-b-replay-empty-argument.md): Path B replays tool calls with an empty argument
- [BUG-project-root-from-process-cwd.md](notes/BUG-project-root-from-process-cwd.md): project root comes from the process cwd, not the session's cwd
- [BUG-reject-pass-value-words.md](notes/BUG-reject-pass-value-words.md): the reject pass rejects on an ambiguous parse — draft
- [BUG-replayed-subagent-empty-transcript.md](notes/BUG-replayed-subagent-empty-transcript.md): a subagent block from a session/load replay points to an empty transcript
- [BUG-streamed-code-lines-get-hard-wrapped.md](notes/BUG-streamed-code-lines-get-hard-wrapped.md): a long code line inside a streamed prose fence is hard-wrapped into two
- [BUG-subagent-unknown-state-ends.md](notes/BUG-subagent-unknown-state-ends.md): a provider's `unknown` subagent state ends the subagent
- [BUG-table-punctuation-highlight.md](notes/BUG-table-punctuation-highlight.md): punctuation highlight lands on random cells of markdown tables
- [BUG-tar-bundle-ask.md](notes/BUG-tar-bundle-ask.md): tar ask gates miss letters in an old-style bundle — draft
- [BUG-unknown-jsonrpc-method-handling.md](notes/BUG-unknown-jsonrpc-method-handling.md): unknown JSON-RPC method dispatch
- [FIX-ansi-escape-payload-shown.md](notes/FIX-ansi-escape-payload-shown.md): Strip every escape sequence whole in `Ansi` — spec
- [FIX-comment-code-conflicts.md](notes/FIX-comment-code-conflicts.md): Resolve three comment/code conflicts — spec
- [FIX-permission-setup-failure.md](notes/FIX-permission-setup-failure.md): Resolve a permission request whose prompt setup fails — reviewed spec
- [FIX-prefix-match-suffix-offset.md](notes/FIX-prefix-match-suffix-offset.md): cut the prefix-boundary suffix where the match ends — spec
- [FIX-record-cwd-scope.md](notes/FIX-record-cwd-scope.md): record cwd that the command ends in — reviewed spec
- [FIX-xargs-highlight-range.md](notes/FIX-xargs-highlight-range.md): Clip wrapper-inner highlight ranges to the command — reviewed spec

### Plans

- P1 [TRACK-token-usage.md](notes/TRACK-token-usage.md): Reduce token usage — reviewed
- P2 [FEAT-auto-mode-integration.md](notes/FEAT-auto-mode-integration.md): deterministic permission ladder as a PreToolUse hook, classifier as fallback
- P2 [FEAT-stale-read-warning.md](notes/FEAT-stale-read-warning.md): stale-read warning on Edit/Write
- P3 [FEAT-context-usage.md](notes/FEAT-context-usage.md): tell the agent its context usage past a threshold — reviewed spec
- P3 [FEAT-diff-line-numbers.md](notes/FEAT-diff-line-numbers.md): line numbers in Edit tool diff previews
- P3 [FEAT-gutter-identity.md](notes/FEAT-gutter-identity.md): gutter identity glyphs — reviewed (open questions)
- P3 [FEAT-permission-always-allow-wording.md](notes/FEAT-permission-always-allow-wording.md): per-kind wording for the "Allow always" permission option
- P3 [FEAT-permission-resolve-known-vars.md](notes/FEAT-permission-resolve-known-vars.md): resolve known-literal vars before the safety check
- P3 [FEAT-to-chat-key.md](notes/FEAT-to-chat-key.md): key from a subagent to its chat — spec
- P3 [FEAT-updated-input-display.md](notes/FEAT-updated-input-display.md): show when a hook rewrote a tool call's input — reviewed (open questions)
- P3 [PERF-append-session-log.md](notes/PERF-append-session-log.md): append finished messages to the session file — reviewed (open questions)
- P3 [REFACTOR-acp-kind-normalisation.md](notes/REFACTOR-acp-kind-normalisation.md): make lowercase an invariant of a tool-call `kind`
- P3 [REFACTOR-acp-tool-call-builders.md](notes/REFACTOR-acp-tool-call-builders.md): adapters extend the base tool-call builders — reviewed spec
- P3 [REFACTOR-agent-chunk-filter.md](notes/REFACTOR-agent-chunk-filter.md): `ResponseBoundary:filter_chunk` takes any agent chunk — spec
- P3 [REFACTOR-agent-config-lookup.md](notes/REFACTOR-agent-config-lookup.md): AgentConfigOptions — one entry lookup, and callbacks given once — spec
- P3 [REFACTOR-agent-scoped-lookups.md](notes/REFACTOR-agent-scoped-lookups.md): one side-record drain and one transcript lookup per agent — reviewed spec
- P3 [REFACTOR-ansi-parse-copies.md](notes/REFACTOR-ansi-parse-copies.md): one extended-colour parse and one text emit in `Ansi` — spec
- P3 [REFACTOR-blocking-stopped-name.md](notes/REFACTOR-blocking-stopped-name.md): name the blocking-subagent stop by the plugin's mode — spec
- P3 [REFACTOR-chat-replay.md](notes/REFACTOR-chat-replay.md): one replay of the history into the main chat — spec
- P3 [REFACTOR-claude-agent-reference.md](notes/REFACTOR-claude-agent-reference.md): tidy the `acp` skill's claude-agent-acp reference — draft
- P3 [REFACTOR-fence-parse.md](notes/REFACTOR-fence-parse.md): one fence-line parse in `TextWrap` — spec
- P3 [REFACTOR-file-scan-result.md](notes/REFACTOR-file-scan-result.md): one handler for a file scan's output in `FilePicker` — spec
- P3 [REFACTOR-grant-target.md](notes/REFACTOR-grant-target.md): one per-path grant step for Bash effects and file tool calls — spec
- P3 [REFACTOR-option-selector.md](notes/REFACTOR-option-selector.md): one option selector for modes, models and config options — spec
- P3 [REFACTOR-preview-message-sections.md](notes/REFACTOR-preview-message-sections.md): one layout for prompt and reply in the session preview — spec
- P3 [REFACTOR-read-range-on-load.md](notes/REFACTOR-read-range-on-load.md): split old read ranges once, where a session file is read — reviewed spec
- P3 [REFACTOR-redirect-expansions.md](notes/REFACTOR-redirect-expansions.md): the expanded part of each redirect in `RedirectedParts` — spec
- P3 [REFACTOR-return-prompt.md](notes/REFACTOR-return-prompt.md): one draft return for a returned prompt — reviewed spec
- P3 [REFACTOR-session-list-order.md](notes/REFACTOR-session-list-order.md): one order for session lists — spec
- P3 [REFACTOR-show-session-opts.md](notes/REFACTOR-show-session-opts.md): one reading of `OpenOpts` in `init.lua` — spec
- P3 [REFACTOR-slash-command-items.md](notes/REFACTOR-slash-command-items.md): one builder of slash command completion items — spec
- P3 [REFACTOR-substitution-word.md](notes/REFACTOR-substitution-word.md): one branch for a `$(…)` argument word in `extract_args` — spec
- P3 [REFACTOR-tool-call-record-lookup.md](notes/REFACTOR-tool-call-record-lookup.md): one newest-record search over the history's tool calls — spec
- P3 [REFACTOR-widget-clear-chat.md](notes/REFACTOR-widget-clear-chat.md): the widget clears only the chat buffer — reviewed spec
- [FEAT-file-activity-reads.md](notes/FEAT-file-activity-reads.md): file activity lists files the agent read — draft
- [FEAT-record-bare-name.md](notes/FEAT-record-bare-name.md): bare program name in shell_parse command records — spec
- [FEAT-shell-changes-from-git.md](notes/FEAT-shell-changes-from-git.md): file activity infers shell-command changes from git — draft

### Ideas and audits

- [AUDIT-edge-cases.md](notes/AUDIT-edge-cases.md): edge-case code (2026-10-26)
- [IDEA-archive-pre-compaction-sessions.md](notes/IDEA-archive-pre-compaction-sessions.md): archive sessions from before a compaction
- [IDEA-auto-allow-non-zsh.md](notes/IDEA-auto-allow-non-zsh.md): auto-allow beyond zsh
- [IDEA-background-processes-window.md](notes/IDEA-background-processes-window.md): background processes window
- [IDEA-cross-provider-editing-guidance.md](notes/IDEA-cross-provider-editing-guidance.md): editing guidance for every provider
- [IDEA-login-service-check.md](notes/IDEA-login-service-check.md): check the provider service before offering a login
- [IDEA-lsp-rename-tooling.md](notes/IDEA-lsp-rename-tooling.md): LSP rename and lookup tools for the agent
- [IDEA-permission-arity.md](notes/IDEA-permission-arity.md): permission rules with arity
- [IDEA-pi-support.md](notes/IDEA-pi-support.md): Pi coding agent support in agentic.nvim
- [IDEA-provider-drift-detection.md](notes/IDEA-provider-drift-detection.md): detect provider drift
- [IDEA-queue-overlooked-question.md](notes/IDEA-queue-overlooked-question.md): a queued message answers a question that was never seen
- [IDEA-scoped-cancel-subagents.md](notes/IDEA-scoped-cancel-subagents.md): Scoping `<C-c>` — sparing subagents from the interrupt
- [IDEA-session-retention.md](notes/IDEA-session-retention.md): session retention
- [IDEA-session-stats-logging.md](notes/IDEA-session-stats-logging.md): more session logging, and a stats panel apart from the info panel
- [IDEA-token-cost-profiler.md](notes/IDEA-token-cost-profiler.md): per-message token cost and session profiler
- [IDEA-tui-parity.md](notes/IDEA-tui-parity.md): slash command parity with the Claude Code TUI

<!-- END plan-index -->

## Housekeeping

- **README demos**: images or gifs showing the differences from the TUI.
- **Claude tool-name vocabulary in two places**: `ClaudeUtils` (`tool_name`,
  `MODE_SWITCH_TOOLS`) and `NAME_TO_KIND` in `permission_hook.lua`. Give it
  one home, or record that the hook's table is scoped to its three tools.
- **Manual code review**: this repo is heavily vibe-coded.
- **Claude-specific code behind the adapter**: move each behind a neutral
  `ACPClient` default that `ClaudeAgentACPAdapter` overrides:
  `ACPClient:claude_config_dir()` (called for every provider);
  `_session_roots` and `SkillPath` in `acp_client.lua`; `AGENTIC_SOCK` in
  `acp_transport.lua` (only the Claude hooks read it).
