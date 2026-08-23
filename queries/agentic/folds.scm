; Fold the body of fenced code blocks whose info string the MessageWriter
; tagged with a "fold" suffix: the "-fold" marker on sidecar bodies
; (```console-fold, ```markdown-fold) and the "difffold" marker on edit diffs
; (```lua-difffold). The threshold policy lives in the writer (per-kind line
; counts, sidecar always-fold, diffs always foldable); this query just folds
; whatever the writer marked.
;
; This is the chat buffer's ONLY fold source. `agentic.ui.folds` runs it over
; the root tree alone, so an injected language's own folds.scm — zsh heredocs,
; lua argument lists — never reaches the transcript; see that module for why.
; It also flattens every match to level 1, so this query must stay
; non-nesting: do NOT `; inherits: markdown`, whose (section) folds nest and
; would be silently truncated.
;
; Fold the `code_fence_content` node, NOT the whole `fenced_code_block`: the
; fence delimiters carry conceal_lines metadata (markdown highlights query), so
; a fold whose first line is the opening delimiter renders zero-height when
; closed — hiding the foldtext. Folding the body only keeps the fold's first
; line on real (visible) content.
(fenced_code_block
  (info_string (language) @_lang)
  (code_fence_content) @fold
  (#lua-match? @_lang "fold$"))
