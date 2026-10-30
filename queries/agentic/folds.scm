; Fold the body of fenced code blocks whose info string the MessageWriter
; tagged with a "fold" suffix: the "-fold" marker on sidecar bodies
; (```console-fold, ```markdown-fold) and the "difffold" marker on edit diffs
; (```lua-difffold). The threshold policy lives in the writer (per-kind line
; counts, sidecar always-fold, diffs always foldable); this query just folds
; whatever the writer marked.
;
; A "-foldnext" fence (```zsh-foldnext) folds through the ```console or
; ```console-fold fence directly after it, and forms no fold alone: an
; execute or search block's command and output are one fold. Folds nest by
; containment, so that output's own "-fold" is a fold inside it.
;
; This is the chat buffer's ONLY fold source. `agentic.ui.folds` runs it over
; the root tree alone, so an injected language's own folds.scm — zsh heredocs,
; lua argument lists — never reaches the transcript; see that module for why.
; Do NOT `; inherits: markdown`: its (section) folds would fold prose.
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

(_
  (fenced_code_block
    (info_string (language) @_lang)
    (code_fence_content) @fold)
  .
  (fenced_code_block
    (info_string (language) @_output)
    (code_fence_content) @fold.end)
  (#lua-match? @_lang "%-foldnext$")
  (#any-of? @_output "console" "console-fold"))
