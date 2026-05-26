# Dim ```markdown blocks only when wrapped in fold markers

## Motivation

Currently `ftplugin/AgenticChat.lua` dims every ` ```markdown ` fence via
`AgenticDimmedBlock`. The intent is to mark sidecar content (fetch / WebSearch
/ SubAgent informational text) as visually distinct from the main
conversation. The fence label conflates two axes — content language
(markdown) and semantic role (sidecar) — so markdown file diffs cannot
share the same fence label and are special-cased to render unfenced in
`tool_call_renderer.lua`.

Decoupling by fold-marker presence lets the same ` ```markdown ` label
serve both roles:
- with fold markers → sidecar → dim
- without fold markers → file diff → no dim

## Reliability of the signal

Fetch / WebSearch / SubAgent insert `{{{` / `}}}` unconditionally
(`tool_call_renderer.lua:876-878`, no threshold). So every sidecar block
has them. No other markdown-fenced output uses fold markers today.

## Changes

### 1. Query (`ftplugin/AgenticChat.lua`)

Replace the current dim query with one that also requires `{{{` as the
first line inside the fence:

```scheme
((fenced_code_block
  (info_string (language) @_lang)
  (#eq? @_lang "markdown")
  (#lua-match? @block "^[^\n]*\n{{{\n")) @block
(#set! priority 101))
```

`^[^\n]*` skips the opening fence delimiter line; `\n{{{\n` requires a
standalone `{{{` line right after.

### 2. Drop the markdown-diff special case (`tool_call_renderer.lua`)

Remove the `is_markdown` / `has_fences` branch. Markdown diffs become
ordinary fenced blocks using `safe_fence + "markdown"`, same as every
other language. Diffs don't insert fold markers, so they won't match the
new dim predicate.

Code to delete:

```lua
local is_markdown = lang == "md" or lang == "markdown"
local has_fences = not is_markdown
local fence
if has_fences then
    -- ...
end
```

and the matching `if has_fences then table.insert(lines, fence) end` at
the close. Replace with unconditional fence emit.

The diff loop's prose-wrap-on-markdown logic (`diff_wrap = is_markdown
and wrap_width or 0`) also goes — wrap behaviour should match other
languages (no prose wrap) once the diff is fenced.

### 3. CLAUDE.md update

`CLAUDE.md` mentions `AgenticDimmedBlock` dimming ` ```markdown ` fences
in two places:
- top-level § "Tool call block rendering"
- "Cross-turn state hazards" section indirectly via the dim mechanism

Update both to say "dims ` ```markdown ` fences whose body starts with a
`{{{` fold marker (sidecar content)".

## Verification

1. `make validate` — existing tests should still pass.
2. Manual: trigger a fetch (sidecar, should be dimmed) and an Edit on a
   markdown file (diff, should NOT be dimmed). Both render in the same
   fence label now.
3. Edge case: an Edit whose `diff.new` starts with a literal `{{{` line
   would incorrectly dim. Unlikely (folds aren't used in diffs); if it
   ever shows up, tighten the pattern further with closing-marker
   presence.

## Out of scope

- Folding long markdown diffs — separate feature (see TODO §
  "Edit tool preview folding").
- Custom fence labels (`markdown-sub`) — rejected in favour of this
  approach to keep the fence label consistent with the content language.
