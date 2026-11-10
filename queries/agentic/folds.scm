; Fold the body of fenced code blocks whose info string the MessageWriter
; tagged with a "-fold" suffix (```console-fold, ```markdown-fold,
; ```text-fold). The threshold policy lives in the writer (per-kind line
; counts, sidecar always-fold); this query just folds whatever the writer
; marked.
;
; A "-foldnext" fence (```zsh-foldnext) folds through the ```console or
; ```console-fold fence directly after it, and forms no fold alone, e.g. an
; execute block's command and output are one fold. Folds nest by
; containment, so that output's own "-fold" is a fold inside it.
;
; A "-foldfence" fence (```zsh-foldfence) folds its content through its own
; closing fence row, so a one-row body still forms a fold that closes.
;
; This is the chat buffer's ONLY fold source. `agentic.ui.folds` runs it over
; the root tree alone, so an injected language's own folds.scm — zsh heredocs,
; lua argument lists — never reaches the transcript; see that module for why.
; Do NOT `; inherits: markdown`: its (section) folds would fold prose.
;
; Fold the `code_fence_content` node, NOT the whole `fenced_code_block`: the
; fence delimiter rows are zero-height (`agentic.ui.FenceRows`), so
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

(fenced_code_block
  (info_string (language) @_lang)
  (code_fence_content) @fold
  .
  (fenced_code_block_delimiter) @fold.fence
  (#lua-match? @_lang "%-foldfence$"))
