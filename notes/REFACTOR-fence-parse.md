# Plan: one fence-line parse in `TextWrap`
Status: spec

## Relevant files
- `lua/agentic/utils/text_wrap.lua` — `unclosed_fence`, `is_fence_delimiter`,
  `fenced_inner` (calls `unclosed_fence`)
- `lua/agentic/utils/text_wrap.test.lua` — `describe("unclosed_fence")`
  (no `is_fence_delimiter` tests exist yet)
- Behaviour reaches, code unchanged: `MessageWriter` `last_drawn_row` and
  `_reflow_chunks`; the `is_fence_delimiter(head)` check in
  `session_resume.lua`'s summary function; `CanonicalToolCall.normalise`
  (through `fenced_inner`)

## Background
`unclosed_fence` and `is_fence_delimiter` both parse a line with
`^( *)([`~]+)(.*)$`. Both then test "at most 3 spaces of indent, at least 3
delimiter characters, and a backtick opener with no backtick in its info
string". `is_fence_delimiter`'s docstring says it "applies `unclosed_fence`'s
parser rule to a single line". So there are two copies of one rule.

Both copies also accept a mixed run (`` ``~ ``, `` `~~~ ``) as one
delimiter. CommonMark §4.5 allows only a run of one character, and so does
the tree-sitter-markdown scanner (`scanner.c`, source dated 2025-06-17 in
`~/.local/share/nvim/tree-sitter-markdown-tmp`; the installed `markdown.so`
is newer and was not read). ```` ```~ ```` is a backtick fence with info
string `~`. One parse fixes this in one place.

## Changes
1. `unclosed_fence` uses `parse_fence` (Additions). While a fence is open, a
   line closes it when its `delim` has the same character, is at least as
   long, and has a blank `info`. When no fence is open, any parsed line opens
   one.
2. `is_fence_delimiter(line)` returns `parse_fence(line) ~= nil`. Its
   docstring keeps the conceal note and drops the restated rule.

## Additions
### `text_wrap.lua`, above `unclosed_fence`
```lua
--- @param line string
--- @return string|nil delim The run of 3+ backticks or 3+ tildes opening `line`, after at most 3 spaces; nil when `line` is no fence delimiter
--- @return string|nil info The rest of the line after `delim`
local function parse_fence(line)
```
Two patterns, `^( *)(`+)(.*)$`, then `^( *)(~+)(.*)$`. A back-reference
pattern does not work in Lua patterns. It returns nil for more than 3 spaces
of indent, fewer than 3 characters, or a backtick run whose rest holds a
backtick.

### Tests (`text_wrap.test.lua`)
Baseline, written first, passing on today's code
(`describe("is_fence_delimiter")`): ```` "```lua" ```` true; `` "~~~`x`" ``
true; ```` "```foo`bar" ```` false; ```` "    ```" ```` false; `` "``" ``
false; ```` "   ````" ```` true.

Then the new behaviour (these fail on today's code):
- `is_fence_delimiter("``~")` and `` is_fence_delimiter("`~~~") `` are false.
- `unclosed_fence({ "```~", "x" })` returns ```` "```" ````, index 1.
- `unclosed_fence({ "```", "```~", "x" })` returns ```` "```" ````, index 1:
  ```` ```~ ```` no longer closes an open ```` ``` ````.
- `fenced_inner({ "```~", "x", "```" })` returns `{ "x" }`.

Existing `unclosed_fence` and `fenced_inner` tests pass unchanged.

## Expected outcome
There is one parse of a fence line. Lines that change meaning:
- A mixed run (`` ``~ ``, `` `~~~ ``) is not a fence. Before, it opened or
  closed one.
- ```` ```~ ```` opens a backtick fence with info `~`. Before, it was a
  4-character run and could close an open ```` ``` ````. Now it is content
  inside that fence.

Callers that see this, with no code change:
- `CanonicalToolCall.normalise` (through `fenced_inner`) now unwraps
  `{ "```~", "x", "```" }` and `{ "```", "```~", "```" }`. Both were nil
  before.
- `last_drawn_row` and `_reflow_chunks` in `MessageWriter`, and the
  `session_resume.lua` head check, classify such lines by the new rule.

## Non-goals
- The lenient fence toggle in `wrap_prose` (deliberate, per its comment).
- `fenced_inner`'s closer test `lines[#lines]:match("^`+$")`. It is stricter
  than `parse_fence`: no indent and no trailing space. Its docstring asks for
  "a bare backtick run", so it looks deliberate. Routing it through
  `parse_fence` would change which tool bodies unwrap.
- Fence matchers outside `text_wrap.lua` (`^`+$` patterns in callers).

## Open questions
None.
