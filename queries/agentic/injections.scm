; inherits markdown

; The MessageWriter encodes its fold decision into the fence info string with a
; "-fold" suffix on the base language (```markdown-fold, ```console-fold). That
; suffix is a fold signal, not a language, so strip it before resolving the
; injected parser — otherwise the sidecar markdown body would lose its markdown
; highlighting (`markdown-fold` is not a parser). gsub is a no-op on fences
; without the suffix, so plain ```python / ```bash blocks inject as before.
(fenced_code_block
  (info_string (language) @injection.language)
  (code_fence_content) @injection.content
  (#gsub! @injection.language "%-fold$" ""))
