# Edit/diff fence filetype via `vim.filetype.match`

## Problem

A tool-call diff for a file with no extension renders a bare ` ``` ` fence
with no language label and no treesitter injection. Extensionless files that
neovim itself detects fine — special filenames (`justfile`, `Dockerfile`,
`Makefile`) — should get a label too.

## Current mechanism

`Theme.get_language_from_path(file_path)` (`lua/agentic/theme.lua`):

```lua
local ext = FileSystem.get_file_extension(file_path)  -- fnamemodify ":e"
if not ext or ext == "" then return "" end
return lang_map[ext] or ext
```

`lang_map` is a hand-rolled 34-entry table mapping extensions whose name
differs from the treesitter parser (`py`→`python`, `sh`→`bash`, `rs`→`rust`,
…). No-extension files return `""` → bare fence.

Callers (both pass a real path):
- `tool_call_renderer.lua:611` — diff fence label, then strips a trailing
  `-fold` suffix via `gsub`.
- `code_selection.lua:208` — `file_type` of a visual selection (`buf_name`).

## Decision: replace the body with neovim's own detection

`vim.filetype.match` is neovim's filetype engine — the same one that labels
`justfile`. Use it instead of re-deriving filetypes from extensions by hand.

Two facts established by live test against the real config:

1. **`vim.filetype.match{filename=…}` + `vim.treesitter.language.get_lang`
   reproduces all 34 `lang_map` entries.** So `lang_map` and the
   extension-splitting are fully redundant and can be deleted (~37 lines).

2. **The `get_lang` step is necessary, not cosmetic.** Markdown fence
   injection resolves the info-string as a parser/language name *directly* —
   it does NOT run filetype detection on it. `vim.filetype.match` returns the
   *filetype* (`sh`); the fence needs the *injection name* (`bash`).
   `get_lang` does that conversion — exactly what `lang_map` did. Skipping it
   would silently break injection for every filetype whose name ≠ its parser
   (`sh`, `md`→`markdown`, etc.).

Final shape — filename only, no `contents`:

```lua
--- @param file_path string
--- @return string language  Treesitter injection name, or "" if undetected
function Theme.get_language_from_path(file_path)
    local ft = vim.filetype.match({ filename = file_path })
    return ft and vim.treesitter.language.get_lang(ft) or ""
end
```

- `ft == nil` (unrecognised file) → `""`, same as today's no-extension case.
- `get_lang` returns the filetype itself when no parser alias is registered,
  so it never nils for a known filetype — the `or ""` only guards `ft == nil`.

The trailing-`-fold` strip in `tool_call_renderer` stays at the call site: it
is a fold-marker collision guard for the rendering layer, not language
detection.

## Shebang detection — cut

`vim.filetype.match` also accepts `contents` (a line array) for shebang /
modeline detection, combinable with `filename`. It is **not used here.** The
only case it serves is an *extensionless* file whose type is determined by a
shebang. That case is not worth covering:

- **Mid-file Edit of an extensionless shebang script** — the shebang (file
  line 1) is absent from a mid-file hunk, so covering it needs an extra disk
  read (`readfile(path, "", 1)`). Rare case, real cost. Cut.
- **Newly-*created* extensionless shebang script** — `contents = diff.new`
  would be free (already in hand), but yields **zero** benefit on the claude
  path: claude creates arrive as `kind == "create"`, and the adapter only
  populates `message.diff` for `kind == "read"`/`"edit"`
  (`claude_agent_acp_adapter.lua:118`) — so a create renders no diff fence and
  never calls `get_language_from_path`. It would fire only for non-claude
  providers (gemini/codex/opencode) that route creates through `message.diff`,
  for the rare extensionless-created-script case, and only to add a cosmetic
  fence label. Not worth the extra param. Cut.

`code_selection` likewise stays on `{filename}` (via the unchanged call). A
`{buf = bufnr}` variant would add content-based accuracy only for the same
extensionless edge case — the selection always comes from a real named file,
so `{filename}` matches today's `lang_map` result. No divergent path.

## The change

1. **`theme.lua`** — swap the `get_language_from_path` body to
   `vim.filetype.match{filename=path}` + `get_lang`; delete `lang_map`
   (~37 lines). Net-negative diff.
2. **`tool_call_renderer.lua:611`** — unchanged (still strips `-fold`; the
   gated buffer-load context-highlighting path at `:630` is untouched).
3. **`code_selection.lua`** — unchanged (body swap is transparent to it).

## Verification

- A test in `theme.test.lua` asserting: known extensions (`foo.py`→`python`,
  `foo.sh`→`bash`), unmapped extension passthrough (`foo.lua`→`lua`), special
  filename (`justfile`→`just` — the real win), and unrecognised
  (`script_no_ext`→`""`).
- `make validate`.
