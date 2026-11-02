; inherits markdown

; The MessageWriter encodes its fold decision into the fence info string with a
; "-fold", "-foldnext" or "-foldfence" suffix on the base language
; (```markdown-fold, ```console-fold, ```zsh-foldnext). That suffix is a fold
; signal, not a language, so strip it before resolving the injected parser —
; otherwise the sidecar markdown body would lose its markdown highlighting
; (`markdown-fold` is not a parser). gsub is a no-op on fences without the
; suffix, so plain ```python / ```bash blocks inject as before.
;
; This rule fires ONLY on suffixed fences (#match? below). Plain
; ```python / ```bash fences are already injected by the inherited markdown rule
; above, so matching them here too would inject the same language twice. The
; suffixed languages ("markdown-fold") aren't real parsers, so the inherited
; rule no-ops on them and this rule is what actually resolves them.
(fenced_code_block
  (info_string (language) @injection.language)
  (code_fence_content) @injection.content
  (#match? @injection.language "-fold(next|fence)?$")
  (#gsub! @injection.language "%-foldnext$" "")
  (#gsub! @injection.language "%-foldfence$" "")
  (#gsub! @injection.language "%-fold$" ""))
