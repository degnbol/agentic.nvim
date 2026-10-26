# Plan: inline-math dollar pairing in prose wrap
Status: blocked on clarification (Open questions 1-4)

## Relevant files
- `lua/agentic/utils/text_wrap.lua:26-62` — `wrap_line` word scanner (atomic `` ` `` and `$` spans)
- `lua/agentic/utils/text_wrap.test.lua:396-452` — existing inline-math wrap tests
- `queries/agentic/images.scm` — attaches snacks.image to AgenticChat; math found in the injected `latex` tree
- `lua/agentic/bootstrap.lua:23-31` — `agentic` language = the markdown parser
- Renderer (parent config, read-only here):
  - `~/.local/share/nvim/site/pack/core/opt/nvim-treesitter/runtime/queries/markdown_inline/injections.scm` — `(latex_block)` injected as `latex`
  - `~/.local/share/nvim/site/pack/core/opt/snacks.nvim/queries/latex/images.scm:1-3` — every `inline_formula` becomes a math image
  - `~/dotfiles/config/nvim/lua/plugins/pickers.lua:388-406,473-509` — `doc.transforms.latex` and `doc.find_visible` overrides; neither filters `$` pairs
  - `~/dotfiles/config/nvim/lua/plugins/pickers.lua:445-458` — `first_line_range`, applied at :494-498: an inline span that crosses a buffer line renders as one image on its first line; the rest stays literal source
  - markdown_inline scanner (source copy, `~/.local/share/nvim/tree-sitter-markdown_inline-tmp/tree-sitter-markdown-split_parser/tree-sitter-markdown-inline/src/scanner.c:95-151`) — `parse_leaf_delimiter`, shared by `` ` `` and `$`
- Skills: `math-images` (parent config), `rendering` (this repo)

## Background
Bug report: `notes/bug-inline-math-dollar-pairing.md`. In `wrap_line`, a `$` run opens a span and
`line:find(delim, run_end, true)` (text_wrap.lua:48) closes it at the next
`$`, with no flanking rule. `wrap_single_line("costs $5 and $10 more words here", 8)`
gives `{ "costs", "$5 and $10", "more", "words", "here" }`.

The renderer pairs the dollars the same way. The chat buffer parses as
markdown (bootstrap.lua:23-31). markdown_inline makes `latex_block` from a
`$` run plus a later run of the same length (scanner.c:95-133; no
whitespace, digit or flanking test). The parser injects that block as `latex`, and snacks
renders each `inline_formula` as an image. The parent config adds no
filter. So for `costs $5 and $10`, wrapping and rendering agree: the chat
shows `$5 and $` as a math image. The visible defect (prose dollar amounts
drawn as math) comes from the renderer's rule. If text_wrap used a
Pandoc-like rule by itself, a wrap could fall inside a span that snacks
still renders; `first_line_range` (pickers.lua:445-458) then shows the
image on the first line and the rest as literal source.

Measured with the installed parsers and the current `wrap_line`:

| input | `latex_block` (markdown_inline) | `wrap_line` words | agree |
|---|---|---|---|
| `costs $5 and $10` | `$5 and $` | `$5 and $10` | yes |
| `costs \$5 and \$10` | none (two `backslash_escape`) | `\$5 and \$10` | no |
| `x \\$a b$ y` | `$a b$` (after escape `\\`) | `\\$a b$` | yes |
| `x $a \$ b$ y` | `$a \$ b$` | `$a \$`, `b$` | no |
| `x $a $$ b$ y` | `$a $$` | `$a $$ b$` | yes (wider word) |

Two divergences. A backslash-escaped opening delimiter (`\$`, `` \` ``)
opens a span in `wrap_line` (text_wrap.lua:42) but not in the grammar. An
escaped `\$` inside a math span closes the span in `wrap_line` (:48) but
not in the grammar; only this one can put a break inside a rendered span.
Inside a code span a backslash is literal in both (`` `a \` `` closes at
the escaped backtick).

## Changes
1. `lua/agentic/utils/text_wrap.lua` `wrap_line` (:40-59): add a branch
   for `\` followed by ASCII punctuation (`%p`) that consumes both
   characters as literal text (`i = i + 2`), the way markdown_inline reads
   a backslash escape. A lookbehind test ("not directly after `\`") is
   wrong for `\\$`: the grammar opens a span there and the lookbehind
   would not. The `%p` test keeps `\ ` from joining two words. Update the
   comment at :26-28 and :37-38: a backslash escapes the next punctuation
   character, so an escaped delimiter is literal. Measured in a copy of
   the repo: `costs \$5 and \$10` then splits into words, `\\$a b$` stays
   one word, and the existing tests pass.
2. `lua/agentic/utils/text_wrap.test.lua`, next to :423:
   - `costs \$5 and \$10 …` at a narrow width wraps between words (no line
     contains `\$5 and \$10`; joined text equals the input).
   - `x \\$a b$ …` at a narrow width keeps `$a b$` on one line.
   - Subject to Open question 4: `costs $5 and $10 …` keeps `$5 and $10` as
     one word, which pins the agreement with the renderer.

## Expected outcome
- Escaped opening dollars and backticks wrap as ordinary text, matching
  the renderer.
- Unescaped `$…$` pairing does not change. Wrapping and rendering keep the
  same rule.

## Non-goals
- Changing what counts as math in rendering (see Open questions).
- An escaped `\$` inside an open math span (`$a \$ b$`). `wrap_line`
  closes at `\$`, so a break can fall inside the rendered span: one image
  on the first line, the rest literal on the next (`first_line_range`).
  A fix needs an escape-aware close search in place of `find` at :48.
- Run-length mismatches (`$a $$ b$`): the measured result is one wider
  word, never a break inside a span.
- Spans that cross a soft line break.

## Open questions
1. Should prose dollar amounts stop rendering as math? The fix belongs in the
   renderer, not here. Options, each with facts:
   - a. Keep the grammar rule. Agents must write `\$` for currency. Nothing
     tells them that now; it needs an instruction in the provider's system
     prompt, a provider rule file, or a skill. Change 1 makes escaped
     amounts wrap correctly. No renderer change.
   - b. Filter `latex_block` matches in the parent config with a
     Pandoc-like rule: in `doc.find_visible` (pickers.lua:473), or in a
     parent-config `queries/latex/images.scm` override with a predicate
     (none exists now). Treesitter
     still parses `$5 and $` as `latex_block` (highlight, conceal,
     injection), so the conceal and highlight queries would need the same
     filter. text_wrap would then need the same rule to stay aligned, as a
     shared predicate or a copy.
   - c. Patch the markdown_inline scanner (`parse_leaf_delimiter` /
     `parse_dollar`). This fixes highlighting, conceal, rendering and (if
     text_wrap copies the rule) wrapping together. The cost is maintaining
     a tree-sitter-markdown fork and pointing nvim-treesitter's parser
     install at it.
2. Under b or c, should text_wrap mirror the new rule in this change or in
   a later change after the renderer changes? If it changes before the
   renderer, the two disagree until the renderer changes.
3. Should change 1 ship now, or wait for the answer to 1? Under a it is the
   whole wrap-side fix; under b or c the escape handling stays correct, but
   the pairing rule around it changes.
4. Should the test that pins `$5 and $10` as one word ship now? It locks in
   the behaviour that 1b or 1c would change.
