# Bug: a fold in the chat buffer runs to EOB

Found investigating the report "heredoc folds are never closed". Line numbers
are against `3f548f7`.

## Verdict up front

**Two independent defects produce the same symptom.** Only the second is what
the user sees in practice; the first was found first and is fixed.

1. **Unbalanced fence — the parse runs away.** An unclosed ` ``` ` in *prose*
   leaves `fenced_code_block` unterminated, so the fence's injection region —
   and every injected fold inside it — extends to the next bare ` ``` ` line
   elsewhere in the buffer, or to EOB. Measured: a fold from a heredoc opener at
   line 4 through line 13, swallowing the intervening prose *and* a whole
   following tool-call block. Fixed — see "Fix (implemented)".

2. **Stale fold levels — the parse is right, the display is not.** Nvim caches
   one fold level per line and only ever recomputes the *edited range*, seeding
   it from the cached level of the line above. A level that was correct while a
   fold was legitimately open stays baked into every line below it for the rest
   of the session. Streaming hits this constantly because each turn appends
   thousands of lines underneath a transiently-open fold. Fixed by Option A —
   see "Stale fold levels".

Heredoc folds themselves are not the bug in either case: they are the injected
zsh parser's, not agentic's, and they terminate correctly for every realistic
command shape.

`TODO.md`'s old "Fold marker not closed" entry described this and was stale in
its own way — it blamed `{{{`/`}}}` markers, but the chat buffer is
`foldmethod=expr` + `vim.treesitter.foldexpr()` (`widget_layout.lua:205-206`)
and the plugin has no marker folds anywhere.

## Context: where chat-buffer folds actually come from

Two sources, and only the first is the plugin's:

1. `queries/agentic/folds.scm` — `code_fence_content` under a `fold$`-suffixed
   info string. One fold per marked body, non-overlapping, single level.
2. **Every injected language's own `folds.scm`**, because
   `vim.treesitter.foldexpr()` iterates *all* trees
   (`$VIMRUNTIME/lua/vim/treesitter/_fold.lua:100-102`:
   `parser:for_each_tree(... ts.query.get(ltree:lang(), 'folds') ...)`) with no
   way to restrict it to the root tree.

For source 2 the relevant file is `~/.local/share/nvim/site/queries/zsh/folds.scm`
(installed alongside the zsh parser, not tracked in dotfiles):

```query
[
  (function_definition)
  (if_statement)
  (case_statement)
  (for_statement)
  (while_statement)
  (c_style_for_statement)
  (heredoc_redirect)
] @fold
```

`heredoc_redirect` is why heredocs fold at all. It reaches the chat buffer
through the zsh injection on execute/search command fences and on any
` ```bash `/` ```zsh ` prose fence.

**Source 2 is tolerated by design, not accidental.** Two places say so:
`widget_layout.lua:208-213` ("injected-language folds and our own `*-fold`
blocks both default open") and `MessageWriter:_queue_fold`'s docstring ("leaving
injected folds and other blocks untouched"). The `difffold` exclusion in
`injections.scm` suppresses injection only for diff fences, and for a different
reason (per-structure folds shattering one diff into many). So do **not** treat
"heredoc folds exist" as the bug — see "Optional hardening" below if you want to
revisit that decision, but it needs the user's call first.

## Ruled out — do not re-litigate

Each of these was tested, not reasoned about:

- **shfmt mangling the heredoc.** `shfmt -ln bash -i 2 -ci` (the exact argv at
  `tool_call_renderer.lua:404`) preserves heredoc bodies and terminators
  byte-for-byte, tabs included, so `<<-` still terminates. Verified against
  shfmt 3.13.1.
- **`safe_fence` failing.** It guarantees the command fence closes and is wider
  than any backtick run in the content, which bounds the injected region. A
  heredoc body containing a bare ` ``` ` line renders inside a ` ```` ` fence
  and folds correctly.
- **A truncated / still-streaming command with no heredoc terminator.** The
  `heredoc_redirect` node stops at the end of the fence content; it cannot
  escape the fence.
- **`split_at_operators` breaking a heredoc.** It returns early on any input
  containing `\n` (`tool_call_renderer.lua:339`), and heredoc commands are
  always multi-line.
- **Marker folds.** There are none; `{{{` in `TODO.md:84` is stale.

Nine command shapes were rendered through the real `prepare_block_lines` and
every heredoc fold was bounded: plain heredoc, `<<'EOF' 2>&1`, heredoc followed
by another command, tab-indented `<<-` inside `if`, unquoted tag with `$var`
body, body containing a ` ``` ` fence, heredoc inside `$( )`, two heredocs,
terminator absent.

## Root cause

Prose is the one text in the chat buffer written verbatim with no fence
protection. `MessageWriter:write_message` (`:319`) and
`write_message_chunk` (`:821`) append the model's markdown as-is; tool-call
fences go through `safe_fence`, prose does not.

With an odd number of fence-toggling lines in a message, tree-sitter-markdown
leaves `fenced_code_block` open. It closes at the next line that qualifies as a
closing fence — bare backticks, no info string, at least as long as the opener —
which in a chat buffer is typically the closing fence of a *later* tool-call
block. Everything between inherits the runaway range: the zsh injection, and
with it the injected `heredoc_redirect` fold.

Confirmed by the info-string rule in the measurement: an opener of ` ```bash `
skipped a later ` ```zsh ` line and closed on the bare ` ``` ` after it.

## Fix (implemented)

Balance the fence at the end of **every prose run**, not at the turn boundary.

Closing only in `finalize_turn` was measured to be a no-op on the case above:
the first line that qualifies as a closer wins, and that is the tool-call
block's own closing fence, which comes *before* the turn boundary. Both the
buggy state and the turn-boundary variant gave `fold zsh heredoc_redirect lines
4..12`; only a closer placed where the prose ends bounded it (`4..7`).

Implemented as `close_fence()` in `message_writer.lua`, applied at the three
places text reaches the buffer verbatim: `write_message`, `write_user_prompt`
(before the `---`), and `_reflow_chunks(flush_all)` — whose callers *are* the
prose-run ends (turn boundary, tool call, prompt, error, divider).
`write_error_message` did not flush before this work, so an error arriving
mid-prose landed inside the open fence and `finalize_turn`'s reflow then spanned
the error block and its `NS_ERROR` extmarks.

One dependency that had to be fixed with it: `_reflow_chunks`' streaming path
advanced `_chunk_start_line` past any blank line, including blank lines *inside*
a fence, so the flush-time region could start below the opener and see a
balanced region. It now stops short of an open fence — which also stops
`wrap_prose` (it assumes each region starts outside a fence) from hard-wrapping
code as prose.

Measured A/B through the real writer, one streamed prose chunk + one tool call:
without balancing the zsh injection covers lines 4..10 with a
`heredoc_redirect` fold at 4..9; with it, the injection is the tool call's own
command fence and the fold is gone.

### 1. A fence-parity helper that follows the markdown rule

`TextWrap.wrap_prose` already tracks `in_fence` (`text_wrap.lua:361-387`) but
its toggle is `line:match("^%s*```")` — it flips on *any* ` ``` ` line,
including typed ones. tree-sitter-markdown does not: a closing fence must carry
no info string and be at least as long as the opener. **Do not reuse
`wrap_prose`'s notion of "in fence" to decide balance** — it disagrees with the
parser in exactly the case that matters here.

Landed as `TextWrap.unclosed_fence(lines)` → `open_fence, open_index`, where
`open_fence` is the delimiter run that would close it.

Opener: at most 3 leading spaces (4+ is an indented code block), 3+ delimiters,
and — for backtick fences only — an info string carrying no backtick. Closer:
same indent rule, the opener's own delimiter character, at least as long, and
nothing but whitespace after it. Checked case-by-case against
tree-sitter-markdown's own parse (23 cases, all agreeing) — the indent,
delimiter-character, info-string-backtick and trailing-whitespace rules all
matter and were not guesses.

Leaving `wrap_prose`'s own toggle alone is fine — it is deliberately lenient so
a stray fence passes through unwrapped (see the comment at `:376-381`). Just
don't conflate the two.

### 2. Close the fence when the prose run ends

All four `_reflow_chunks(bufnr, true)` call sites already run inside
`_with_modifiable_suppressed` (`:275`), so the appended line is not read as a
user scroll.

`finalize_turn` deliberately does **not** call `_auto_scroll` despite growing
the buffer: it releases the prose pin first (`:643`), so a scroll there would
drop the reader to the bottom of the finished response, which is exactly what
the pin exists to prevent. The balancing write follows the existing
`_append_lines({ "" })` in that respect.

Never balance during streaming: an open fence is correct mid-stream and closing
it early would corrupt the render.

## Stale fold levels — open, and the one that bites

Balancing the fence does not help here: the parse is already correct and the
fold levels are not.

### Evidence

A live chat buffer, 2922 lines, with **no unbalanced fence anywhere**
(`TextWrap.unclosed_fence` over the whole buffer returns nil):

| Source | Result |
| --- | --- |
| folds queries over the current parse | `zsh heredoc_redirect 1141..1151`, then `1161..1174`, `1176..1186`, `1254..1411`, … all bounded |
| injected regions | bounded (`zsh 1126..1153`, inside the ```` ```zsh ```` fence at 1125–1153) |
| `foldlevel()` in the chat window | one continuous level ≥1 run, `1141..2253` — to the end of the buffer, swallowing ~20 separate folds |

### Mechanism

`$VIMRUNTIME/lua/vim/treesitter/_fold.lua` caches one level per line
(`FoldInfo.levels` / `levels0`) and evaluates `foldexpr` from that cache.

- `compute_folds_levels(bufnr, info, srow, erow)` only walks `srow+1 .. erow`,
  seeding `level0_prev = info.levels0[srow]`. Lines past `erow` are never
  re-derived, so a base level that was right while a fold was open stays baked
  in below it.
- `on_bytes` shifts levels for inserted/removed lines rather than recomputing —
  the file says so outright at the comment above the shift.
- A full-buffer recompute happens in exactly one place: `M.foldexpr` when
  `foldinfos[bufnr]` is nil, i.e. first use, `BufUnload`, `VimEnter` or
  `FileType`.

Streaming is the pathological case: every turn appends thousands of lines below
a fold that is transiently open while its closing fence has not arrived yet.

### Options — A implemented

Landed as `lua/agentic/ui/folds.lua` (`M.levels` + `M.foldexpr`, wired at
`widget_layout.lua`'s `chat_win_opts`). `foldtext.lua` was renamed into it, so
the module owns all of the chat buffer's fold behaviour. `parser:parse()` with
no range is what excludes injections; levels are recomputed for the whole
buffer on every `b:changedtick` change (0.8 ms over a 2820-line, 60-fold
buffer — measured), which is the caching shape `:help fold-expr-slow`
prescribes.

Measured in a real UI (headless cannot compute injected folds), streaming the
example transcript in line by line: with core's foldexpr the zsh
`heredoc_redirect` fold is present at lines 5–19; with ours no injected fold
appears and a `console-fold` body still folds body-only, with levels returning
to 0 for every line appended below it.

The E490 race the deferred `:foldclose` was written for was against core's
scheduled recompute; ours computes on demand from `:foldclose`'s own fold
update. The deferral is kept for the no-visible-window flush path.

**A. Custom foldexpr over the `agentic` tree only.** We own the cache, so we
control when levels are recomputed (turn boundary, after each block write).
Also drops injected folds entirely — not just heredocs but
`if`/`for`/`while`/`case`/`function` from zsh, plus `lua arguments` and
`python argument_list` folds inside command fences. Every fold bug so far has
come from that source, so losing them is arguably the point rather than a cost.

- `foldtext.lua` used to own a foldexpr — its module docstring records why it
  was dropped. Reinstating means computing levels from the `agentic` tree only
  and wiring it at `widget_layout.lua:206`. agentic's folds are non-overlapping
  and single-level, so the expression is trivial (`">1"` on the fold's first
  line, `"1"` inside, `"0"` outside) over a cached range set invalidated on
  `on_changedtree`.
- **Cost to budget for:** `_queue_fold`'s deferred `:foldclose` depends on
  treesitter's own scheduled recompute landing first (E490 race, documented as
  verified in its docstring at `:1168-1171`). A custom foldexpr changes that
  timing and the race must be re-verified.

**B. Force nvim to drop its level cache at the turn boundary.** Keeps injected
folds and leaves foldexpr alone. No public API reaches `foldinfos`; the only
documented trigger is firing `FileType` on the chat buffer, which re-runs every
`FileType` handler there (ftplugin, syntax, plugin autocmds) and can reset
buffer-local state. Cheaper to write than A, more likely to have side effects,
and it re-runs on every turn of a long session.

- A whole-buffer no-op `nvim_buf_set_lines` would also force the recompute via
  `on_bytes`, but it moves or invalidates every extmark in the buffer
  (decorations, tool-block ranges, fold anchors). Not viable.
- `zx` in the chat window recomputes but also undoes manually opened/closed
  folds, so it fights the explicit `:foldclose`/`:foldopen` calls the renderer
  makes.

Rejected for either route: suppressing the zsh injection on command fences
(loses shell highlighting, the entire point of the injection); shipping
`after/queries/zsh/folds.scm` in the plugin (queries resolve per *language*,
not per buffer — it would kill heredoc folds in real zsh buffers too).

## Measurement caveat for whoever verifies this

`foldlevel()` cannot be read under headless nvim. Fold levels are computed on
redraw, and `compute_folds_levels` calls `parser:parse(nil, cb)` — a `nil` range
parses no injections, so injected folds only land once the highlighter has
parsed the region on screen (the `_fold.lua:66` TODO). Every range in this note
comes from running each language's `folds` query over the parsed trees, which is
exactly what `compute_folds_levels` consumes.

Repro (adjust paths; `plugin/treesitter.lua` is sourced for the config's
`#inject-by-ext!` directive, without which the zsh injections query errors):

```lua
vim.cmd "source " .. vim.fn.expand "~/nvim/plugin/treesitter.lua"
vim.opt.runtimepath:prepend(vim.fn.expand "~/nvim/modules/agentic.nvim")
local md = vim.api.nvim_get_runtime_file("parser/markdown.so", false)[1]
vim.treesitter.language.add("agentic", { path = md, symbol_name = "markdown" })
vim.treesitter.language.register("agentic", "AgenticChat")

local lines = {
    "Here is a script:",
    "",
    "```bash", -- never closed
    "cat >/tmp/x <<'EOF'",
    "hello",
    "  ✔ completed",
    "",
    "Assistant prose after the block.",
    "",
    "### 󰆍 `next`",
    "```zsh",
    "ls -la",
    "```",
    "final line of chat",
}
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].filetype = "AgenticChat"
local parser = vim.treesitter.get_parser(buf, nil)
parser:parse(true)
parser:for_each_tree(function(tree, ltree)
    local q = vim.treesitter.query.get(ltree:lang(), "folds")
    if not q then
        return
    end
    for _, match, metadata in q:iter_matches(tree:root(), buf, 0, -1) do
        for id, nodes in pairs(match) do
            if q.captures[id] == "fold" then
                local r = vim.treesitter.get_range(nodes[1], buf, metadata[id])
                io.write(("fold %s %s lines %d..%d\n"):format(
                    ltree:lang(),
                    nodes[1]:type(),
                    r[1] + 1,
                    (r[5] == 0) and r[4] or r[4] + 1
                ))
            end
        end
    end
end)
```

Expected on the buggy state: `fold zsh heredoc_redirect lines 4..13`. Expected
after the fix: the region is bounded by the appended closing fence, so the fold
ends inside the prose block.

## Tests

- `text_wrap.test.lua` § `unclosed_fence` — the parser's rule, case by case.
- `message_writer.test.lua` § `fence balancing` — streamed / full-message /
  prompt paths, matching opener width, closing before a following tool call
  block, and the blank-line-inside-a-fence case that the reflow-marker clamp
  exists for.

Not covered: the nine command shapes from the "ruled out" list. They need the
treesitter repro harness rather than the plain-Lua test env, and nothing in the
fix touches the command-fence path.
