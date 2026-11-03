; markdown's injections, copied rather than `; inherits markdown`: its
; html_block pattern sets injection.combined, and one combined pattern makes
; every range parse scan the whole document for injections
; (`LanguageTree:_get_injections`). Never set injection.combined here.

; The MessageWriter encodes its fold decision into the fence info string with a
; "-fold", "-foldnext" or "-foldfence" suffix on the base language
; (```markdown-fold, ```console-fold, ```zsh-foldnext). That suffix is a fold
; signal, not a language, so strip it before resolving the injected parser —
; otherwise the sidecar markdown body would lose its markdown highlighting
; (`markdown-fold` is not a parser). gsub is a no-op on fences without the
; suffix, so plain ```python / ```bash blocks inject as written.
(fenced_code_block
  (info_string (language) @injection.language)
  (code_fence_content) @injection.content
  (#gsub! @injection.language "%-foldnext$" "")
  (#gsub! @injection.language "%-foldfence$" "")
  (#gsub! @injection.language "%-fold$" ""))

; snacks.nvim's queries/markdown/injections.scm, an `; extends` that reaches
; markdown but not this copy.
(fenced_code_block
  (info_string (language) @_lang)
  (#eq? @_lang "math")
  (code_fence_content) @injection.content
  (#set! injection.language "latex"))

((html_block) @injection.content
  (#set! injection.language "html")
  (#set! injection.include-children))

((minus_metadata) @injection.content
  (#set! injection.language "yaml")
  (#offset! @injection.content 1 0 -1 0)
  (#set! injection.include-children))

((plus_metadata) @injection.content
  (#set! injection.language "toml")
  (#offset! @injection.content 1 0 -1 0)
  (#set! injection.include-children))

([
  (inline)
  (pipe_table_cell)
] @injection.content
  (#set! injection.language "markdown_inline"))
