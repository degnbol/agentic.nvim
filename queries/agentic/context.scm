; treesitter-context: pin the tool-call section header (### Read / ### Edit /
; …) when the cursor scrolls into a code block. Scoped to sections that
; directly contain a fenced code block so prose-only headings in assistant
; messages are not pinned. Injected languages pin their own function/class
; context independently via their own context.scm.
(section
  (fenced_code_block)) @context
