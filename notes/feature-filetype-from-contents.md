# Plan: Colorize content-defined extensionless files in diffs

## Problem

A newly **created** extensionless file whose type is content-defined renders
gray in the chat diff. Motivating case: zsh completion files (`_git`, `_brew`)
— no extension, type decided by a first line `#compdef`/`#autoload` (neovim's
own rule, `$VIMRUNTIME/lua/vim/filetype.lua:2173-2174`).

The diff's visible colors come from the `target_lang` reparse path
(`tool_call_renderer.lua:649-671`): `bufadd`+`bufload` the real file, then
reparse the snippet inside it. Files **already on disk** colorize correctly —
`bufload` reads real content and runs neovim's full detection, including content
rules. A **create** is the gap: the file isn't on disk yet, `bufload` yields an
empty buffer, `get_parser(b)` returns no parser, `target_lang` stays nil, and
highlighting is skipped.

`Theme.get_language_from_path` (`theme.lua:128`) is filename-only:

```lua
local ft = vim.filetype.match({ filename = file_path })
```

Its return does **not** drive diff colors (those come from `target_lang`). It
only feeds the markdown prose-wrap decision (`tool_call_renderer.lua:618`) and
the cosmetic `-difffold` fence label (injection suppressed for `difffold$`).
The one place it *does* drive real highlighting is `code_selection.lua` — that
fence injects directly with no reparse.

## Why not an underscore heuristic

Rejected: "prefix `_` + no extension -> zsh". Wrong signal — `_notes`,
`_backup` are not zsh; the real signal is the `#compdef`/`#autoload` content
line, which `vim.filetype.match` already checks. Reimplementing it is both
over-broad and redundant.

## Design

`vim.filetype.match` already accepts `contents` (verified
`$VIMRUNTIME/lua/vim/filetype.lua` `M.match`):

- Works with `filename` + `contents` and no buf.
- Ordering: filename patterns and extension are tried **first**; contents is a
  **fallback**. Passing both is safe — `.lua` still wins by extension, contents
  only fills the extensionless gap.
- `contents` is a `string[]` (only first 100 lines + last line inspected).

`tool_call_block.diff.old`/`.new` are already `string[]`, so the content is in
hand at every call site.

### 1. `theme.lua` — content-aware detection

```lua
--- @param file_path string
--- @param contents string[]|nil Body lines, used as a fallback when the
---        filename alone doesn't resolve a type (e.g. extensionless files
---        whose type is content-defined, like zsh `#compdef` completions).
--- @return string language
function Theme.get_language_from_path(file_path, contents)
    local ft = vim.filetype.match({ filename = file_path, contents = contents })
    return ft and vim.treesitter.language.get_lang(ft) or ""
end
```

`vim.filetype.match` returns zero values (not `nil`) on no match; `local ft =
...` coerces to `nil`, so the `ft and ... or ""` guard is correct.
`get_lang("zsh")` returns `"zsh"` — the dedicated `georgeharker/tree-sitter-zsh`
parser is registered, so the detected filetype maps to a valid injection name.
`contents` is optional, so existing behaviour is unchanged when omitted.

### 2. `tool_call_renderer.lua` — colorize creates (the real fix)

`build_highlight_map` (`treesitter.lua:28`) does **not** parse the buffer; line
29's `get_parser(bufnr, lang)` is only an existence guard, and the actual parse
runs on a reconstructed string via `get_string_parser(source, lang)`. For a
create (`old_count == 0`), prefix/suffix are empty, so the reconstructed source
is just `diff.new`. The buffer machinery already works — the only missing piece
is `target_lang`.

- **Line 617** — make `lang` content-aware so it feeds both prose-wrap and the
  fallback below. Keep the existing `gsub("%-fold$", "")` strip inline; pass
  `tool_call_block.diff.new` as the second arg to `get_language_from_path`.
  Secondary benefit (free, not the motivation): a content-aware `lang` also
  resolves the prose-wrap decision and the cosmetic `-difffold` label correctly
  for content-defined creates.

- **Target block (~668)** — when the buffer yields no parser (empty buffer =
  not-yet-on-disk create) but `lang ~= ""`, fall back to the content-detected
  language:
  ```lua
  local ok_p, parser = pcall(vim.treesitter.get_parser, b)
  if ok_p and parser then
      target_bufnr = b
      target_lang = parser:lang()   -- on-disk file: content detection already ran
  elseif lang ~= "" then
      target_bufnr = b
      target_lang = lang            -- create: no buffer filetype, use detected lang
  end
  ```
  Verified: `get_parser(b)` on an empty no-filetype buffer returns
  `ok=true, parser=nil`, so the existing `if ok_p and parser` guard is falsy and
  the fallback fires. `build_highlight_map`'s own line-29 guard returns nil if no
  parser is installed for `lang`, so this stays safe.

- **Reparse guard (Q2)** — the threshold at line 666-667 (`lc <= max_lines`)
  uses the buffer's line count, which is `1` for an empty create-buffer and so
  always passes regardless of `#diff.new`. Gate the create branch on
  `#tool_call_block.diff.new <= max_lines` instead. Leave `diff_context_max_lines`
  at 5000 — a pure backstop that effectively never fires (real creates are
  ≪1000 lines), so nothing to tune.

### 3. Collapse large creates

A create's fold is exactly the file, trivially inspectable; an edit shows only
fragments and is rarely large. So **creates start folded closed above a
threshold; edits are never collapsed.**

- New config in `tool_call_display`:
  ```lua
  --- @field create_max_lines integer Fold a created-file diff closed when it
  ---        exceeds this many lines (0 = always open).
  create_max_lines = 50,
  ```
  `0 = always open` matches the sibling `*_max_lines` keys' "0 disables"
  semantics.

- **Line 639**:
  ```lua
  local is_create = not tool_call_block.diff.old
      or #tool_call_block.diff.old == 0
  local create_max = Config.tool_call_display.create_max_lines
  local collapse = is_create and create_max > 0
      and #tool_call_block.diff.new > create_max
  fold_open = tool_call_block.status ~= "failed" and not collapse
  ```
  `fold_open == false` routes to `_close_fold` (`message_writer.lua:1057,
  1351`) — the exact path failed edits already use, so no new fold machinery.
  The reparse/highlight guard is independent: a closed fold still gets its
  extmarks computed.

### 4. `code_selection.lua` call site

The selected lines are in hand at `code_selection.lua:190`, so pass them free:

```lua
file_type = Theme.get_language_from_path(buf_name, lines),
```

This fence (`code_selection.lua:154`) injects directly — no `target_lang`
reparse — so it's the one spot the `contents` fallback gives real highlighting
today: selecting from an unsaved extensionless content-defined buffer now fences
as `zsh`. `lines` is only the selected range, so a mid-file fragment without the
`#compdef` first line degrades to `""` (same as today — no regression; helps the
common "send the whole new file from the top" case).

## Verification

Two cheap test groups; skip the colorize integration test (parser-availability
fragile for ~3 lines of wiring already covered by detection + fold tests + luals).

1. **`theme.test.lua`** — extend the existing `get_language_from_path` block:
   - `get_language_from_path("_brew", { "#compdef brew", "..." })` -> `"zsh"`
   - `get_language_from_path("_brew", nil)` -> `""` (no regression without contents)
   - `get_language_from_path("foo.lua", { "#compdef x" })` -> `"lua"`
     (filename/extension still wins over a misleading content line)

2. **`tool_call_renderer.test.lua`** — mirror the failed-edit `fold_open` case
   (line 278/306). Set `Config.create_max_lines` explicitly (don't rely on the
   default 50):
   - create (`diff.old = {}`) with `#diff.new > create_max_lines` -> `fold_open == false`
   - create with few lines -> `fold_open == true`
   - edit (`diff.old` non-empty) over threshold -> `fold_open == true` (edits not collapsed)

3. **By hand** — create a `_brew` (`#compdef brew`) and confirm it colorizes,
   folded closed when large.

`make validate` to confirm luals + selene + tests.
