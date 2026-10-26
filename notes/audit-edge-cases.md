# Audit: edge-case code (2026-10-26)

Code that exists for a case that is rare, unreachable, or harmless when left alone. For the user's decisions: mark each `keep` / `remove` / `simplify`. Nothing has been changed.

Read-only reviewers produced this from source reading; claims are unverified unless marked. Line numbers are from the working tree on 2026-10-26.

Columns:
- **Kind**: cosmetic, correctness, race, data, safety.
- **Reach**: `dead` (never runs or gives the same result as the general path), `rare`, `reach` (reachable), `?` (unknown).
- **Harm**: what removal changes. "none" means the general path gives the same result.
- **Origin**: `up` = upstream (Carlos Gomes or other contributors); otherwise the fork, mostly agent-written. "spec" = speculative per its comment or commit; "obs" = cites an observed problem.

Not covered: `lua/agentic/utils/permission_rules.lua` (its reviewer did not finish).

## 0. Bugs found on the way (not edge cases)

Fixed on 2026-10-26, with tests (`make validate` passes):
- 0.1 `session_manager.lua` create callback: dropped `self._restoring or`. `restore_from_history` without `reuse_session` now keeps its session (`restart_session`, the `session/load` fallback, conflicting restores without `session/load`).
- 0.4 `ansi.lua`: SGR numbers capped at 255, so out-of-range colours build a valid hex.
- 0.5 `chat_widget.lua`: prompt-navigation keys read the config directly; `false` now disables them.
- 0.6 `agent_config_options.lua` `set_initial_mode`: no warning when `default_mode` is already current.
- 0.7 `claude_utils.lua`: `"Preparing file…"` replaces the dead `Write` placeholder. Not handled: `Task (… effort)`.
- 0.8 `claude_agent_acp_adapter.lua`: Bash description also read from `command_description`.
- 0.11 `text_matcher.lua`: the trailing-whitespace strategy trims all trailing whitespace (this also removes 6.1's unused `trim` modes).

Reports, each getting a plan:
- 0.2, 0.3 (git fails open; same-second cache) → `bug-git-files-fail-open.md`
- 0.9 (failed execute row offset) → `bug-failed-execute-body-offset.md`
- 0.12 (`$5 and $10` as math) → `bug-inline-math-dollar-pairing.md`
- 0.13 (deny gate over the flag cap) → `bug-deny-gate-flag-cap.md`
- 0.14 (completion reads the current buffer) → `bug-completion-current-buf.md`
- 0.16 (errors only in the debug log) → `bug-silent-errors.md`

Questions for the user:
- 0.10 `claude_utils.lua:11`: `EnterWorktree` is mapped to a mode switch labelled "Normal", which hides its body. Intended?
- 0.15 `diff_jump.lua:75-100`: the comment calls the reverse-match path legacy-only, but it is reachable for any edit block whose render found no match, and b2b6c2a "Drop reverse-match fallbacks" removed the same idea elsewhere. Is the comment stale, or should the path go?

## 1. Session layer

| # | Where | What | Kind | Reach | Harm | LOC | Origin |
|---|---|---|---|---|---|---|---|
| 1.1 | SM:384-387, 4312-4314, + `self.agent and` at 213, 464, 2986, 3958, 4139-4141; `session_restore.lua:41-43`; `session_recovery.lua:360,636` | nil checks on `get_instance`, which errors and never returns nil | correctness | dead | none | 14 | 020679c… |
| 1.2 | SM:2629, 2633 | `_budget_status` unit scaling "cheap insurance" | cosmetic | dead | none | 3 | 0ba65c2 spec |
| 1.3 | SM:4135, 4144-4148 | `opts and opts.set_pending_initial_model` | correctness | dead | none | 4 | 6df25d8 |
| 1.4 | SM:207, 217-218, 3801 | `self.file_activity` / `self.config_options` guards | correctness | dead | none | 3 | 64cbb2e |
| 1.5 | SM:1599-1601 | `_rename_session` empty-title guard | correctness | dead | none | 3 | 6c7058c |
| 1.6 | SM:193-196 | welcome header "unknown" fallback, unused param | cosmetic | dead | none | 1 | f02f7c0 |
| 1.7 | `session_restore_builtin.lua:171` | undo-index clamp | correctness | dead | none | 1 | cf2cf0b |
| 1.8 | `session_restore_builtin.lua:50-52` | `if current_idx then` around a nil-able assignment | cosmetic | dead | none | 3 | 292b0ee |
| 1.9 | `session_restore_builtin.lua:62-64` | empty early return; loop gives the same | correctness | dead | none | 3 | cf2cf0b |
| 1.10 | `session_restore_builtin.lua:80`; `session_restore.lua:264, 335` | `or` fallbacks for config with defaults | cosmetic | dead | none | 3 | — |
| 1.11 | `session_restore.lua:28` | `chat_history ~= nil` | correctness | dead | none | 1 | 463420a |
| 1.12 | `session_restore.lua:419-422` | empty-query early return | correctness | rare (Lua API only) | "ambiguous prefix" warning | 4 | 6bf816c |
| 1.13 | SM:3206-3211 | re-check gate before resubmitting a held prompt | cosmetic | reach | second "Message held" line | 5 | 5d55c36 |
| 1.14 | SM:2017 | `deep_equal` dedupe of deciders | cosmetic | reach | same footer redrawn, no-op save | 1 | 6e03546 |
| 1.15 | SM:1913-1915 | stdout text only while generating | cosmetic | reach | stray provider output between turns | 3 | abf0f18 |
| 1.16 | SM:2658, 2660, 2733-2737 | provider-specific display cases in general code (`default`/`build` mode hidden, `" Mode"` strip, `"Default…"` model name) | cosmetic | reach | default mode/`Default (recommended)` shown; also breaks the provider-specific rule | 7 | 48ef318, c6a4ac8, a07b596 |
| 1.17 | `session_restore.lua:97-104` | "no saved provider" warning | cosmetic | rare (legacy files) | one warning fewer | 8 | 6df25d8 |
| 1.18 | SM:605-610 | "chat stays modified" warning on `:w` mid-turn | cosmetic | reach | `:wqa` stops silently | 6 | c61b19f |
| 1.19 | `session_restore_builtin.lua:93-111` | quickfix picker cosmetics (current-line highlight, plurals) | cosmetic | reach | "1 sessions", wrong highlight | 8 | 5edcf28, cf2cf0b |
| 1.20 | `session_recovery.lua:58-68` | usage lines in the unexpected-stopReason error | cosmetic | reach | no token counts in that error | 11 | 67efbfe |
| 1.21 | `session_restore.lua:245-258` | thought truncation in picker preview | cosmetic | reach | longer previews | 12 | 8964594 |
| 1.22 | `session_recovery.lua:533-536` | `if not timer` after `new_timer()` | correctness | ? (allocation failure) | none in practice | 4 | 40f682b spec |
| 1.23 | SM:2641-2643, 2705-2707 | budget 5% noise floor and mark logic | cosmetic | reach | false warning glyph early in a window | 4 | 0ba65c2 |
| 1.24 | SM:3333-3353 | `_warn_unadvertised_command` (opencode drops unknown commands; the rationale sits in general code) | cosmetic | reach | silent drop on opencode | 21 | 944b6d6 obs |
| 1.25 | SM:1533-1553, 3641 | `_refresh` manual unwedge + `math.max(0, …)` floor | race | reach (keypress) | no manual unwedge | 20 | e8da343, 19fa6d6 |
| 1.26 | SM:2276-2295 | pcall around permission notify/hook | safety | ? | lockup could return if it throws | 12 | 03c775d obs |
| 1.27 | SM:2756-2801 | `announce_model_loaded` dedupe on `_announced_model_id` (planned for removal in `PLAN-restore-model.md`) | cosmetic | reach | duplicate model line | ~10 | a4c8974 |

## 2. Chat rendering

| # | Where | What | Kind | Reach | Harm | LOC | Origin |
|---|---|---|---|---|---|---|---|
| 2.1 | MW:1802-1811 | `was_empty` row correction | correctness | dead | none | 6 | e10df42 |
| 2.2 | MW:2182-2193 | `current == "" and last_line or last_line` | correctness | dead | none | 7→1 | abf0f18 |
| 2.3 | MW:3046-3050 | "shouldn't happen" anchor branch | correctness | dead (per its comment) | none | 4 | add3524 |
| 2.4 | MW:2862-2883, 2922-2933 | tracker-extmark sanity notifications (3 of 4 checks can't fire) | correctness | dead | none | 25 | 7847d59 |
| 2.5 | TCR:734-735, 781-782, 1171-1173, 1193-1195; MW:408, 2327, 2341, 2345; TCR:1855 | `Config.x and …` / `or {}` for defaulted config | correctness | dead | none | 12 | — |
| 2.6 | TCR:1771-1773, 1829, 1726-1728, 1747-1750 | diff-highlight early return and bounds checks | correctness | dead | none | 8 | — |
| 2.7 | `folds.lua:55-64, 118` | parser/query/levels fallbacks | correctness | dead | none | 7 | 312ac31 |
| 2.8 | `chat_buffer.lua:175-177` | markdown parser fallback | correctness | dead | none | 2 | — |
| 2.9 | TCR:1977; MW:2995, 40; `status_indicator.lua:285` | silent `pcall`s on valid buffers | correctness | dead | none | 10 | — |
| 2.10 | `status_indicator.lua:317`; TCR:1683 | `math.max(0, …)`, `nvim_get_hl() or {}` | correctness | dead | none | 2 | — |
| 2.11 | MW:1122-1260, 2900-2906, 1315-1320 | hook records anchored under their tool call | cosmetic | reach | hook output at buffer end | ~130 | 58bc192 obs |
| 2.12 | MW:1661-1734, 1789-1795, 1510-1528, 1640 | drop the prose paragraph that repeats the error | cosmetic | reach | error sentence shown twice | ~80 | a8469ab obs |
| 2.13 | MW:157-160, 1851-1882, 1904-1907, 1915 | error-rail joining for follow-up action lines | cosmetic | reach | action line outside the rail | ~45 | a8469ab |
| 2.14 | MW:757-829, 891, 942-996 | prose-run rail rules (multi-paragraph only, skip leading blank/`###`, corner placement, incremental extend path) | cosmetic | reach | rail covers more rows; per-chunk rebuild | ~100 | 1f6a29b, 8f01a8b |
| 2.15 | MW:2255-2277 | live tail wrap while streaming | cosmetic | reach | long line past the edge until the paragraph ends | 23 | 5d9f244 |
| 2.16 | TCR:1087-1112, 1610-1628, `search_ansi` plumbing | search-body ANSI path, "kept for future-proofing" | cosmetic | dead today | none | ~35 | 0915482 spec |
| 2.17 | TCR:816-835 | unwrap a pre-fenced execute body (adapter already strips it) | cosmetic | rare | double fence | 11 | 02326e5 spec |
| 2.18 | MW:2203-2218 | uppercase splice heuristic (space between run-together messages) | cosmetic | rare (no `messageId`) | messages run together; can misfire on `e.g.X` | 16 | 7847d59 obs |
| 2.19 | MW:1037-1052, 1072-1076, 920; TCR:1364 | one-line bodies get no fence | cosmetic | reach | probably none (fences concealed) | 8 | 58bc192, 4c94fb4 |
| 2.20 | MW:2841-2851 | merge differing bodies with a `---` divider | data | ? | later body replaces earlier | 10 | 0774466 up |
| 2.21 | MW:2000-2004 | skip an all-zero usage footer | cosmetic | reach | dim `0 in · 0 out` | 5 | 0cef2a3 |
| 2.22 | TCR:1389-1411 | pretty-print JSON in generic bodies | cosmetic | reach | raw one-line JSON | 20 | 1baf563 |
| 2.23 | TCR:654-727, 760-792 | hand-rolled `split_at_operators` before shfmt (a second shell tokenizer) | cosmetic | reach | long commands on one line | ~75 | 35e1654, 6d87991 |
| 2.24 | MW:2662-2672 / 2815-2823; 2825-2833 / TCR:849-856; MW:1277, 1600-1604 | duplicated body strips and range extraction, whitespace-thought skip, `error_type` fallback | cosmetic | mixed | — | 25 | — |

MW = `ui/message_writer.lua`, TCR = `ui/tool_call_renderer.lua`.

## 3. ACP layer

| # | Where | What | Kind | Reach | Harm | LOC | Origin |
|---|---|---|---|---|---|---|---|
| 3.1 | `acp_client.lua:862-973, 581-584` | `fs/read_text_file` / `fs/write_text_file` handlers; capability advertised false | data | dead | none | ~116 | 97d28bc spec |
| 3.2 | `acp_client.lua:439-451, 484-487, 501-504, 513-516, 1036, 1042` | `transport == nil` guards | correctness | dead | none | ~30 | 40f682b spec |
| 3.3 | `claude_agent_acp_adapter.lua:412-425` | old SubAgent format branch | cosmetic | dead | none | 14 | b140d1b up |
| 3.4 | `claude_utils.lua:53, 154-158`; adapter:342-344 | SlashCommand tool kind (tool no longer exists) | cosmetic | dead | none | ~8 | a809b95 |
| 3.5 | `acp_transport.lua:26-33` | stderr ignore patterns that no longer occur | cosmetic | dead | none | 5 | up |
| 3.6 | `acp_client.lua:141, 343-348` | unused `reconnect_count` callbacks | correctness | dead | none | 7 | up |
| 3.7 | `acp_client.lua:1210-1218` | `if not result` in `create_session` | correctness | dead | none | 9 | up |
| 3.8 | `acp_client.lua:1048-1054` | `_connect` error return (discarded by callers) | correctness | dead | none | 7 | up |
| 3.9 | adapter:429 | `__ensure_command_string` for claude | data | dead (claude) | none | 1 | 394db53 |
| 3.10 | `acp_client.lua:980-981`; `acp_payloads.lua:27-28`; `agent_instance.lua:219-220, 283` | dead lines after `error`, impossible types | correctness | dead | none | 5 | up |
| 3.11 | adapter:388-400 | parse Read range from title; `rawInput.limit` is already there | cosmetic | reach | none if replaced | 13 | 03cecb6 |
| 3.12 | `acp_client.lua:385-387`; `agent_config_options.lua:219, 320`; `agent_instance.lua:210` | redundant empty/nil checks | correctness | dead | none | 8 | mixed |
| 3.13 | `agent_config_options.lua:320-366, 85, 106-108, 127-129` | deferred model selector before the agent is ready | cosmetic | reach (startup) | press the key again | ~30 | 6f30033 |
| 3.14 | `acp_transport.lua:207-209, 238-240`; `acp_client.lua:298-309, 337-342`; SM:1912-1918 | non-JSON stdout/stderr written into the chat | cosmetic | reach (stderr) | stderr noise no longer in the chat | ~25 | abf0f18 |
| 3.15 | `acp_transport.lua:158-169`; `acp_client.lua:332-336` | auto-reconnect loop (off unless `reconnect = true`, not in defaults) | race | rare | none by default | ~15 | up |
| 3.16 | `acp_client.lua:643-655` | unknown-kind WARN linking the upstream tracker | cosmetic | ? (opencode casing) | lose a diagnostic | 12 | up |
| 3.17 | `acp_client.lua:530-542` | skip chunk logging in the debug file | cosmetic | reach | larger debug log | 13 | up |
| 3.18 | `claude_utils.lua:347-368` | placeholder-title suppression (drifted, see 0.7) | cosmetic | reach | placeholder text for a frame | 22 | 4843aa0 obs |
| 3.19 | `claude_utils.lua:334-339` | rewrite `grep …` title to `rg …` (prefix only) | cosmetic | reach | title says grep | 6 | a165e21 |
| 3.20 | adapter:176-180 | description from the body echo (see 0.8) | cosmetic | reach | lost description | 4 | 02326e5 |
| 3.21 | adapter:349; `acp_client.lua:684-686`; adapter:406-411 | sentinel strings, empty-description guard | cosmetic | reach (streaming) | blank/`": "` for a frame | 7 | mixed |
| 3.22 | `agent_modes.lua:74-78` | ignore `current_mode_update` without legacy modes | cosmetic | reach | spurious WARN | 5 | up |
| 3.23 | `agent_config_options.lua:158-161` | skip `set_model` when already current | cosmetic | reach | one redundant request | 4 | 6df25d8 |
| 3.24 | adapter:514, 519; `claude_utils.lua:385`; adapter:69; `acp_client.lua:611-619`; `acp_transport.lua:69-72` | checks on fields the bridge or schema always sends | data | dead | none | ~20 | mixed |

## 4. UI widgets and utils

| # | Where | What | Kind | Reach | Harm | LOC | Origin |
|---|---|---|---|---|---|---|---|
| 4.1 | `file_system.lua:161-196` | reload an open buffer of the session JSON after save | data | rare | stale buffer until `:checktime` | 36 | 0d456d0 (broader than its bug) |
| 4.2 | `tool_call_diff.lua:161-163` | single-line fast path | cosmetic | dead (same result) | none | 4 | up |
| 4.3 | `code_selection.lua:141-147` | empty-render branch | cosmetic | dead (same result) | none | 7 | up |
| 4.4 | `chat_widget.lua:651-653, 783-785, 615-617, 768-770` | visual-mode and negative-mark checks | correctness | dead | none | 12 | 34f4173 spec |
| 4.5 | `chat_history.lua:435-439, 457-461` | missing session folder branch | cosmetic | dead (same result) | none | 10 | up |
| 4.6 | `file_activity.lua:206, 434, 452-453` | fallbacks for an enum `op` | data | rare (hand-edited file) | — | 4 | 64cbb2e spec |
| 4.7 | `diagnostics_list.lua:147-148, 164-166` | severity/message fallbacks | correctness | dead | none | 5 | up |
| 4.8 | `file_list.lua:96,121`; `diagnostics_list.lua:193, 220-223` | content checks repeating bounds checks | correctness | dead | none | 6 | up |
| 4.9 | `chat_widget.lua:494, 742, 419`; `window_decoration.lua:79`; `file_picker.lua:223`; `file_system.lua:264-266`; `todo_list.lua:57-58`; `theme.lua:234` | one-line redundant guards | mixed | dead | none | 8 | mixed |
| 4.10 | `lsp_server.lua:314-317` | empty completion line | race | rare | — | 4 | cd31d17 spec |
| 4.11 | `tool_call_diff.lua:175-178` | empty diff patch | correctness | ? | — | 4 | up |
| 4.12 | `todo_list.lua:106-147` | auto-scroll to unfinished tasks | cosmetic | reach | no auto-scroll | 42 | a234265 up |
| 4.13 | `todo_list.lua:74-100` | `[~]` conceal workaround | cosmetic | reach | `[~]` concealed | 27 | 1f482b0 obs |
| 4.14 | `file_activity.lua:93-136, 210-214` | project/other/tmp location sort | cosmetic | reach | plain sort | ~40 | 64cbb2e spec |
| 4.15 | `file_picker.lua:73-82, 139-182, 216-249` | breadth-first collection (only matters above `max_files`) | cosmetic | rare | deep files may win the cut | ~40 | 80ffb39 spec |
| 4.16 | `diagnostics_list.lua:43-65, 78-80`; `file_list.lua:30-34` | dedupe of added diagnostics / paths | cosmetic | reach | duplicate rows | 30 | up |
| 4.17 | `chat_widget.lua:1012-1025` | restore panel layout after a refused `:q` | cosmetic | reach | panels stay closed | 14 | 9ace8c5 obs |
| 4.18 | `diagnostics_list.lua:142-144, 171` | truncate to window width (`nowrap` already, goes stale on resize) | cosmetic | reach | — | 4 | 6d8a30d |
| 4.19 | `widget_layout.lua:30-41` | `eob` fillchars blanking | cosmetic | reach | `~` rows | 12 | f6bc5da spec |
| 4.20 | `chat_widget.lua:172-180` | delete the blank unnamed buffer the chat replaces | cosmetic | reach | extra buffer in the list | 9 | b66361e |
| 4.21 | `file_activity.lua:29, 440-444`; `diagnostics_list.lua:150-154` | placeholder and `[unnamed:N]` labels | cosmetic | reach | — | 10 | mixed |
| 4.22 | `theme.lua:56-77` | glyph colour fallbacks | cosmetic | reach | — | 12 | 77f0b6a, 6d8a30d |
| 4.23 | `theme.lua:79-114` | highlight ownership record | cosmetic | reach | groups freeze after a colorscheme change | ~12 | f95944b obs |
| 4.24 | `chat_widget.lua:1527-1529`; `file_activity.lua:255-257`; `code_selection.lua:103`; `diff_jump.lua:124-126`; `file_activity.lua:485-487`; `widget_layout.lua:168`; `subagent_transcript.lua:38-40` | small skips and one-off choices | cosmetic | reach | — | ~15 | mixed |
| 4.25 | `lsp_server.lua:88, 239, 221, 118-131` | completion tunables (min lengths, dot-files last, excludes) | cosmetic | reach | — | 15 | mixed |
| 4.26 | `file_picker.lua:122-189, 320-358` | glob fallback when rg, fd and git are all missing | correctness | rare | no `@` completion then | ~105 | 5d13cf1 up |
| 4.27 | `subagent_transcript.lua:60-65`; `chat_widget.lua:1046-1053, 1260-1262` | stray-buffer deletion, reattach after `:e!`, leave visual mode | correctness | reach | — | 15 | mixed |
| 4.28 | `chat_widget.lua:1377, 1442-1445`; `floating_message.lua:28` | silent `pcall(vim.treesitter.start)` | correctness | rare | — | 6 | mixed |

## 5. Permissions (excluding `permission_rules.lua`)

Safety checks that stop an auto-approval were skipped. "Fails closed" = removal only adds a prompt.

| # | Where | What | Kind | Reach | Harm | LOC | Origin |
|---|---|---|---|---|---|---|---|
| 5.1 | `permission_float.lua:8,31`; `permission_manager.lua:676`; `grant_safety.lua:499` | fields stored, never read (`_buf_nrs`, `write_all`) | cosmetic | dead | none | 4 | 59f37f8 spec |
| 5.2 | PM:66; `permission_float.lua:343` | fallbacks for always-passed args | correctness | dead | none | 2 | spec |
| 5.3 | PM:413-415, 284-286, 984-986 | `tool_call` nil guards after `add_request` validated it | correctness | dead | none | 8 | dd24f2d spec |
| 5.4 | PM:907, 925-927, 947, 1036-1038, 1338-1340 | "no current request" guards on internal callers | correctness | dead | none | 15 | mixed spec |
| 5.5 | PM:1311-1313, 1333 | `_watch_layout` re-entry guard; silent pcall on autocmd delete | race | dead | none | 4 | c61b19f |
| 5.6 | PM:219-221, 741 | redundant empty/`dest_snap` checks | data | dead | none | 2 | — |
| 5.7 | PM:691-747 | `reason` return of `_check_grant` (discarded) | cosmetic | dead | none | ~10 | 59f37f8 spec |
| 5.8 | `grant_safety.lua:615-617, 625` | unreachable move/unsupported-kind fallbacks | safety (fails closed) | dead | none | 4 | 59f37f8 |
| 5.9 | `grant_safety.lua:286-289, 361-363, 414, 483-485` | short-circuits the general code already covers | correctness | dead | none | 10 | spec |
| 5.10 | `git_files.lua:33-35, 82, 136, 139-140` | impossible-value fallbacks | correctness | dead | none | 5 | 59f37f8 |
| 5.11 | PM:503-531, 708-745; `grant_safety.lua:610-623` | move-kind grant path ("no surveyed provider sends it… defensive") | safety (fails closed) | dead in practice | none (moves already prompt) | ~50 | 59f37f8 spec |
| 5.12 | PM:503-513 | `raw_input_path` aliases `path`, `target`, `source_path`, `sourcePath` | data (fails closed) | ? | extra prompt | 4 | 59f37f8 spec |
| 5.13 | PM:185-202 | tracker `argument` fallback in the cache key (duplicate; breaks `decide`'s tracker-free contract) | data | reach (one caller) | none with a 1-line caller fix | 18 | 238facd obs |
| 5.14 | PM:18-26, 1015-1030 | sort provider options by kind priority | cosmetic | reach | provider order | 25 | ad75c57 up |
| 5.15 | `permission_float.lua:112-137` | "Reject all" placement rules | cosmetic | reach | line order | ~20 | af80788 |
| 5.16 | `permission_float.lua:178-223` | key-hint compression `\{e,s,v,t}` | cosmetic | reach | keys joined by spaces | 46 | 1057547 |
| 5.17 | `permission_float.lua:225-240, 418-428, 352-354` | two hint layouts by border type | cosmetic | reach | one layout | ~28 | 1057547 |
| 5.18 | `permission_float.lua:253` | manual hint truncation (nvim truncates footers itself) | cosmetic | reach | none | 1 | 1057547 |
| 5.19 | `permission_float.lua:374-382` | skip re-place when unchanged | cosmetic | reach | flicker | 7 | obs |
| 5.20 | PM:904-918 | `on_hidden` once per request | cosmetic | reach | repeated bell/badge per tab switch | 8 | 2ff6fde |
| 5.21 | PM:920-940, 1342-1344 + SM:438-445 | `_sync_proxy_hold` pins the subagent block | cosmetic | reach | chat keeps scrolling | ~30 | 1057547 |
| 5.22 | PM:1234-1238, 810-818 | dedupe of key buffers / grant scopes | cosmetic | reach | duplicate scope in picker | 9 | mixed |
| 5.23 | PM:996-1002, 1010 | highlight-helper nil checks | cosmetic | dead | none | 6 | mixed |
| 5.24 | `grant_safety.lua:32-42, 245-271` | wide-scope WARN on `/grant ~` | cosmetic | reach | no warning | ~38 | 59f37f8 |
| 5.25 | `grant_safety.lua:210-221, 435-440, 86` | tmp-root dedupe, `diff.all` edit range, `/` scope case | mixed (fails closed) | rare | extra prompt | ~11 | mixed |
| 5.26 | PM:797-805 | `has_edit_range` skips a second disk read | race | reach | one extra read | 4 | 6a54e8a |
| 5.27 | `permission_structured.lua:121-126, 133-145, 214-216, 502, 865` | always-true or repeated checks | correctness | dead | none | ~12 | 45fb99d, c55d7d1 |
| 5.28 | `permission_structured.lua:147-158, 176-184, 98-100, 1011, 1064` | double option dedupe; `args_dynamic or {}` test shim | correctness | dead in production | none | ~13 | 45fb99d, c55d7d1 |
| 5.29 | `permission_structured.lua:885-901` | `validate_auto_approve` config warning | cosmetic | reach (user config) | no warning | 17 | 97b1925 |

PM = `ui/permission_manager.lua`. Not candidates: the one-element gate fast path and `MULTI_ELEMENT_FLAG_CAP` (performance; see 0.13).

## 6. Shell, grep and text utilities

| # | Where | What | Kind | Reach | Harm | LOC | Origin |
|---|---|---|---|---|---|---|---|
| 6.1 | `text_matcher.lua:10-27, 50-52, 102-104, 170-172, 205-207` | unused `trim` modes, repeated bounds and length checks (keep `#target_lines == 0`) | correctness | dead | none | ~20 | 7a4765d, 9030d2c up |
| 6.2 | `text_wrap.lua:187-189`; `ansi.lua:37, 231` | impossible-value guards | cosmetic | dead | none | 6 | c6de2e3, cc624ab |
| 6.3 | `ansi.lua:89, 98, 163-165` | SGR `dim` parsed into the cache key, never applied | cosmetic | reach | fewer highlight groups | 5 | cc624ab |
| 6.4 | `grep_regex.lua:547-554` | `pcall(vim.regex)` "safety net" that hides errors the caller already reports | correctness | ? | failure shows instead of hiding | 5 | 3e21bf0 spec |
| 6.5 | `grep_regex.lua:480` | newline check before `lex` | cosmetic | dead | none | 1 | 3e21bf0 |
| 6.6 | `grep_args.lua` ag/ack support (270-360, 485-551, `number_opts`, `perl_bytes`) | grep highlighting for ag and ack | cosmetic | rare | no highlights in their output | ~170 | 58f14b2 spec |
| 6.7 | `grep_args.lua` ugrep support (142-179, 379-395, 433-435, 692; `grep_regex.lua` 202-210, 290-297, 351, 357, 424) | grep highlighting for ugrep | cosmetic | rare | different highlights | ~75 | 58f14b2, 3e21bf0 spec |
| 6.8 | `text_wrap.lua:111-289` | markdown table realignment (incl. conceal heuristics tied to the user's dotfiles, 204-215) | cosmetic | reach | tables as written | ~170 | c6de2e3, b0b77b9 obs |
| 6.9 | `grep_regex.lua:27-36, 191-196, 371, 384-399` | per-dialect fidelity rules | cosmetic | rare | an occasional wrong highlight | ~35 | 3e21bf0 spec |
| 6.10 | `grep_args.lua:795-827, 846-863, 105-114, 650, 758-762, 621` | newline patterns, git-grep revisions, context/stats suppression, `-NUM`, `--files`, smart-case escapes | cosmetic | rare–reach | wrong or missing highlights | ~60 | 58f14b2, 3e21bf0, a8d3a1e |
| 6.11 | `text_wrap.lua:19-24, 26-59, 91-99, 319, 341-343, 426, 440-455` | hanging indent, atomic inline code/math, narrow-width return, count abbreviation | cosmetic | reach | — | ~50 | mixed |
| 6.12 | `shell_parse.lua:463-477, 497-498, 513` + `permission_rules.lua:1104` | static `$((…))` mode; its original case no longer reaches it | cosmetic | rare | number-only `$((N))` prompts | ~14 | 4e0c6e4 obs, now stale |
| 6.13 | `shell_parse.lua:1825-1827, 829-831, 874-876, 2148` | fd-0 heredoc clause, early returns, `src == ""` (gives `nil` where the contract says `{}`) | correctness | dead | none | ~10 | 6a03d39, ff6fd4d, 19710f8 |
| 6.14 | `shell_parse.lua:886, 1161, 1196-1205` | `offset > 0` guard; `read -k/-t` number parsing | correctness (fails closed) | rare | extra prompt | ~12 | ff6fd4d, dc31f13 |
| 6.15 | `shell_parse.lua:676-678` | empty-heredoc fallback (permissive, not fail-closed) | safety | ? (probably dead) | — (an `assert` would be more honest) | 3 | 6a03d39 |
| 6.16 | `shell_parse.lua:364-366, 380-382, 441-443, 533-535, 541` | unreachable fail-closed checks | safety (fails closed) | dead | none | ~13 | mixed |
