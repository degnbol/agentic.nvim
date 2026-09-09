# Refactor: give `doc/agentic.txt` a table of contents that leads somewhere

Verified against `HEAD` (`5d55c36`) and the nvim 0.12 runtime tag file. Every
count below was measured, not estimated — a prose review supplied the leads and
several of its numbers were wrong in both directions, noted inline.

The help has grown a section at a time and has never had a structural pass. Two
frames a reader would look for do not exist (Permissions, Commands), and §15.1
"Additions" — nominally a TUI comparison — is the only home for several shipped
features, so the contents page does not lead to them.

## Correctness first

These four are wrong, not merely misplaced, and are worth landing before any
restructure. Each is a small independent edit.

**The provider table gives names that do not work.** §2 lists seven providers;
`Config.provider` must be a key of `acp_providers` (`config_default.lua:91`), and
the table mixes valid keys with binary names:

| §2 says | actual key | works? |
| --- | --- | --- |
| `claude-agent-acp` | `claude-agent-acp` | yes |
| `codex-acp` | `codex-acp` | yes |
| `gemini` | `gemini-acp` | no |
| `opencode` | `opencode-acp` | no |
| `cursor-agent-acp` | `cursor-acp` | no |
| `auggie` | `auggie-acp` | no |
| `vibe-acp` | `mistral-vibe-acp` | no |

Two of seven happening to be right is what makes this hard to spot. Give the key
and the binary as separate columns; §4.1 already says the value "must match a key
in `acp_providers`".

**File logging is documented under the wrong option.** §14 says
`setup({ debug = true })`, then "View logs with `:messages` or in
`~/.cache/nvim/agentic_debug.log`". `Config.debug` gates `Logger.debug`, which
only prints (`logger.lua:64`); the file is written by `Logger.debug_to_file`,
gated on `Config.log` (`logger.lua:78`). `log` appears nowhere in the help — the
only match for the word is the filename on that same line. Document `log` in §4
and split the sentence.

**Twenty `|tag|` links do not resolve** (the review said twelve). Three groups,
and they do not take the same fix:

- `|LineNr|`, `|NonText|`, `|Search|`, `|DiffAdd|`, `|DiffChange|`, `|DiffDelete|`,
  `|DiffText|`, `|DiagnosticError|`, `|DiagnosticHint|`, and the four
  `|DiagnosticVirtualText*|` → prefix with `hl-`; all confirmed to resolve then.
- `|Comment|`, `|Delimiter|`, `|hl-Added|`, `|hl-Changed|`, `|hl-Removed|` →
  **no tag exists in either form.** `hl-Comment` and `hl-Delimiter` do not
  resolve either, so the review's blanket "add the `hl-` prefix" is wrong here.
  Backtick them, or link `|group-name|` once.
- `|winbar|`, `|operatorfunc|` → these are options: `'winbar'`, `'operatorfunc'`
  per `lang-vimdoc.md`.

**Five config keys are absent entirely**: `status_icons`, `diagnostic_icons`,
`permission_icons`, `permission_float`, `auto_approve_skills`. Plus `log` above,
and `settings` — whose four keys (`move_cursor_to_chat_on_submit`,
`send_register`, `write_submit`, `storage_path`) have no field block anywhere,
even though §6.2 twice instructs the reader to set two of them.

That is 7 of 29 top-level keys, not "about a third" — the rest of §4 is sound
and should be left alone.

## Structure

§15.1 is a feature reference wearing a comparison heading. These appear *only*
there: `/trust` scopes and their recoverability checks, the allow/reject-always
cache, what permission keys `4` and `5` do (§6.5 documents only "1 - typically
Allow once"), the unread badge, multi-tabpage isolation, `AgenticHeadersChanged`
and `vim.t.agentic_headers`, the collapsed thought run, the hook-context row. A
reader who has never used the Claude TUI has no reason to open §15.

Permissions has no frame at all: the material is spread across §4.6 (config
fields), §6.5 (key table), §7 (Bash approval), §11 (one highlight paragraph) and
§15.1, with §4.6 forward-referencing `|agentic-compound-commands|` and nothing
referencing back. §7 "Shell command auto-approval" sits as a top-level peer of
"Keymaps" while being one branch of permission handling.

Commands has no frame either. `/trust`, `/rename` and `/context` are used as
known vocabulary in §4.6 and §10 before anything introduces them; `/trust`'s
subcommands (`repo`, `here`, `tmp`, `off`, a path or glob —
`acp/slash_commands.lua:51-55`) appear nowhere; `:AgenticResume`
(`plugin/agentic.lua:57`) is undocumented.

Proposed contents:

```
 1. Introduction          2. Requirements        3. Setup
 4. Configuration         4.1 Provider           4.2 Windows
                          4.3 Keymaps            4.4 Tool call display
                          4.5 Diff preview       4.6 Permissions
                          4.7 Session restore    4.8 Hooks
                          4.9 Settings           4.10 Miscellaneous
 5. Lua API               (unchanged, + the model arg on load_acp_session)
 6. Keymaps               (6.1-6.6, tables only — see below)
 7. Commands              7.1 Local  7.2 Forwarded (was 15.3)
                          7.3 Notices (was 10)  7.4 :AgenticResume
 8. Permissions           8.1 The prompt (keys 1-5, from 6.5 + 15.1)
                          8.2 Read-only and skill auto-approval
                          8.3 Trust scopes (from 15.1)
                          8.4 Shell command auto-approval (was 7, trimmed)
 9. Chat behaviour        9.1 Auto-scroll and attention (was 8, + badge)
                          9.2 Message queue (prose lifted out of 6.2)
                          9.3 File activity (was 9)  9.4 Subagents
10. Highlight groups     11. Autocmds (+ AgenticHeadersChanged)
12. Health check         13. Debug and logging
14. Comparison with Claude TUI   14.1 Behaviour differences (was 15.4)
                                 14.2 Not available (was 15.5)
```

§15 shrinks to what its heading promises. Nothing is deleted; every §15.1 bullet
moves to the section that owns it.

### Frame leakage to fix while moving

- **§6.1** is a keymap table but carries the whole `keymaps.prompts`
  configuration contract (value forms, `vim.NIL` disabling, a worked example).
  That is §4.3 material, and §4.3's scope list omits `prompts` entirely.
- **§6.2** carries the message-queue *behaviour* — dispatch order, what drops a
  region, the `<C-c>` and early-turn-end rules — under a Keymaps heading. It
  moves to §9.2 and the table stays.

## Prose rules to apply during the move

`.claude/rules/docs.md`: state what a feature does, do not frame it as useful
for X. Offenders: §8 "so the response can be read from the beginning"; §9 "so
the count is available with the panel closed"; §10 "Since the glyph says which
command ran…"; §11 "`AgenticGlyphOff` needs a foreground of its own to strike
through, so…"; §2 "The `zsh` grammar is currently the more actively maintained
of the two" (also an opinion that dates); §4.9 `winbar` "Disable if using an
external plugin (e.g. incline.nvim)".

No internals in user-facing help: §7 line 634 names
`lua/agentic/utils/permission_rules.lua`; §7 writes `Config.permissions.{...}`
where the user-facing form is `permissions.read_only` inside `setup()`, as §4.6
already has it; §7's four-step parse-tree walk, "compiled patterns cached with
mtime-based invalidation" and "fails closed" are design-note altitude; §11 gives
a default as "(set in ftplugin)"; §15.3 points at
`.claude/skills/acp/references/claude-agent.md`, a repo-internal path; §15.5
says "the plugin's dispatch code path is ready but unreachable".

Three statements are made three times each: deny/ask precedence (§4.6, and twice
in §7) and the shell parse-tree mechanism (§2, §7, §15.1, with issue 16561 cited
twice). Pick one canonical site and point at it.

## Smaller corrections

- §12 documents one of two `User` autocmds; `AgenticHeadersChanged`
  (`window_decoration.lua:63`) is described only in §15.1.
- §11 omits `AgenticPickerDate` and `AgenticPickerDelim` (`theme.lua:180-181`).
- §6.3 omits the `keymaps.chat.open_diff_file = "gf"` default.
- §4.9's `notifications.bell` says it rings on response complete and permission
  prompts; it rings only when the widget is unfocused, a condition stated in
  §15.1. Fold it in.
- §4.2's `windows.position` union omits `"tab"`.
- §5's `load_acp_session({session_id}, {cwd})` takes a third argument, `model`
  (`init.lua:342`).
- §15.2 is headed "ACP patches" but its content is locally-intercepted commands,
  and it lists four of the six (`/delete` and `/trust` missing).
- §7's tag is `agentic-compound-commands` while its heading is "Shell command
  auto-approval"; every other section's tag tracks its title.
- 43 lines exceed the `tw=78` modeline. §11's three-column table cannot fit
  without restructuring — either accept it as a known exception or move its
  "Purpose" column into following prose. The rest rewrap.
- Non-ASCII beyond the glyph vocabulary: `…` (line 519) and `→` (line 582).
  The glyphs themselves are the plugin's deliberate vocabulary and stay. Em
  dashes are already the file's house style and are left alone.

## Open questions

- **§6.6 lists `<Plug>(agentic-send)` as `n/x` "Send motion/selection", but in
  visual mode it is mapped to `add_selection` (`plugin/agentic.lua:52`)**, which
  adds to the context panel rather than sending. Doc wrong, or mapping wrong?
- **`config_default.lua`'s `settings.write_submit` docstring says `:wq` / `:x`
  "submit and emit a warning instead of closing"**, while `chat_widget.lua`
  closes the input window and §6.2 matches the code. The source comment looks
  stale, but that is a guess.
- CLAUDE.md asks that new glyphs be listed here. §10 shows three of six notice
  glyphs by example and the seven `Glyphs.KIND` gutter glyphs appear nowhere. A
  legend under §9 or §10 would discharge it — worth doing, or drop the CLAUDE.md
  rule?

## Order

1. The four correctness fixes. Independent, landable now, no restructure needed.
2. The smaller corrections, in place.
3. The move: §15.1 out, then the two new frames, then the TOC.
4. Prose rules and rewrapping, as each section is touched.

Steps 1 and 2 are worth doing even if 3 never happens.
