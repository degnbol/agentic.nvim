; Fold the body of fenced code blocks whose info string the MessageWriter
; tagged with a "-fold" suffix (e.g. ```console-fold, ```markdown-fold). The
; threshold policy lives in the writer (per-kind line counts, sidecar always-
; fold); this query just folds whatever the writer marked.
;
; Fold the `code_fence_content` node, NOT the whole `fenced_code_block`: the
; fence delimiters carry conceal_lines metadata (markdown highlights query), so
; a fold whose first line is the opening delimiter renders zero-height when
; closed — hiding the foldtext. Folding the body only keeps the fold's first
; line on real (visible) content.
(fenced_code_block
  (info_string (language) @_lang)
  (code_fence_content) @fold
  (#lua-match? @_lang "%-fold$"))
