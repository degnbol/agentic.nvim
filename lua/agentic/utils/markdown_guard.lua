local TextWrap = require("agentic.utils.text_wrap")

--- Code-span guards that keep markdown from reinterpreting a line of text.
--- @class agentic.utils.MarkdownGuard
local M = {}

--- Wrap `segment` in a code span delimited by `run`.
---
--- `run` must be longer than every backtick run in the line the span lands
--- in, else a tick in it closes the span early: `` `Run `make x` now` ``
--- parses as two spans with the middle left bare. A segment that starts or
--- ends in a backtick is padded with a space inside the delimiters, so its own
--- run does not merge into them. CommonMark strips the pad when it renders.
--- @param segment string
--- @param run string
--- @return string span
local function wrap_code_span(segment, run)
    local abuts = segment:sub(1, 1) == "`" or segment:sub(-1) == "`"
    local pad = abuts and " " or ""
    return run .. pad .. segment .. pad .. run
end

--- @param text string
--- @return string span `text` whole as one code span
local function guard_whole(text)
    return wrap_code_span(
        text,
        string.rep("`", TextWrap.longest_backtick_run(text) + 1)
    )
end

--- Characters that can open inline markdown in any context: code spans,
--- emphasis, strikethrough, links, HTML, autolinks and escapes. `!`, `]` and
--- `>` are absent, as an image, link or tag needs a `[` or `<` too. `$`, `#`
--- and `&` are absent, as they act only in certain shapes.
local MARKDOWN_INLINE_SPECIALS = "[`*_~%[<\\]"

--- Whether markdown could reinterpret `word`: it holds an always-special
--- character, a `$` on a line with math pairs, an entity, or only `#` (a
--- heading's closing sequence).
--- @param word string Word with its code spans removed
--- @param math_pairs boolean Whether the line holds two or more `$`
--- @return boolean
local function needs_guard(word, math_pairs)
    return (
        word:find(MARKDOWN_INLINE_SPECIALS)
        or (math_pairs and word:find("$", 1, true))
        or word:find("&#?%w+;")
        or word:find("^#+$")
    ) ~= nil
end

--- @param s string
--- @return integer surplus How many more `)` than `(` `s` holds
local function surplus_closes(s)
    return select(2, s:gsub("%)", "")) - select(2, s:gsub("%(", ""))
end

--- Split leading `("'` and trailing `.,:!?)"'` off `word`. A parenthesis
--- stays in `core` when its partner does, so `core` never holds an
--- unmatched one that the split made.
--- @param word string
--- @return string head
--- @return string core
--- @return string tail
local function strip_punctuation(word)
    local head, core = word:match("^([(\"']*)(.*)$")
    local tail = ""
    while core:find("[.,:!?)\"']$") do
        local last = core:sub(-1)
        if last == ")" and surplus_closes(core) <= 0 then
            break
        end
        core, tail = core:sub(1, -2), last .. tail
    end
    while head:sub(-1) == "(" and surplus_closes(core) > 0 do
        head, core = head:sub(1, -2), "(" .. core
    end
    return head, core, tail
end

--- Code spans that CommonMark and tree-sitter `markdown_inline` both read
--- in `text`, ignoring escapes, HTML and autolinks: a backtick run paired
--- with the next run of equal length, kept only if no run between them is
--- as long. Tree-sitter closes a span at the first run at least as long,
--- CommonMark only at an equal one.
--- @param text string
--- @return { start: integer, stop: integer }[] spans 0-based `[start, stop)`, sorted
local function backtick_spans(text)
    --- @type { start: integer, stop: integer }[]
    local runs = {}
    for start, stop in text:gmatch("()`+()") do
        table.insert(runs, { start = start - 1, stop = stop - 1 })
    end
    local function length(i)
        return runs[i] and runs[i].stop - runs[i].start or math.huge
    end

    --- @type { start: integer, stop: integer }[]
    local spans = {}
    local i = 1
    while runs[i] do
        local j = i + 1
        while length(j) < length(i) do
            j = j + 1
        end
        if length(j) == length(i) then
            table.insert(spans, { start = runs[i].start, stop = runs[j].stop })
            i = j + 1
        else
            i = i + 1
        end
    end
    return spans
end

--- Wrap in a code span each word of `text` that holds a markdown-special
--- character, so that code in prose (mainly identifiers like `foo_bar`)
--- reads as code. A word is a whitespace-delimited run, and a code span
--- already in `text` counts as one unit of its word: it stays as it is,
--- unless the rest of its word needs a guard. Then the guard covers the whole
--- word. Punctuation at the word's ends stays outside the guard.
---
--- The result renders as text and code spans only. An escaped tick can make
--- the pairing differ from CommonMark's on `text`, which moves the code
--- colour but renders nothing as markdown.
--- @param text string Single line
--- @return string guarded
local function guard_words(text)
    -- CommonMark and tree-sitter pair every run the same way, because:
    -- 1. Outside the guards and kept spans, no byte can start markdown.
    -- 2. Every guard's backtick run is longer than any run in `text`.
    -- 3. A kept span holds no run as long as its delimiters.
    local run = string.rep("`", TextWrap.longest_backtick_run(text) + 1)
    local math_pairs = select(2, text:gsub("%$", "")) >= 2
    -- NUL is neither whitespace nor special, so a masked span splits no word
    -- and triggers no guard.
    local masked = text
    for _, span in ipairs(backtick_spans(text)) do
        masked = masked:sub(1, span.start)
            .. ("\0"):rep(span.stop - span.start)
            .. masked:sub(span.stop + 1)
    end

    local parts, cursor = {}, 1
    for start, stop in masked:gmatch("()%S+()") do
        table.insert(parts, text:sub(cursor, start - 1))
        local word = text:sub(start, stop - 1)
        local bare = masked:sub(start, stop - 1):gsub("%z", "")
        if needs_guard(bare, math_pairs) then
            local head, core, tail = strip_punctuation(word)
            word = head .. wrap_code_span(core, run) .. tail
        end
        table.insert(parts, word)
        cursor = stop
    end
    table.insert(parts, text:sub(cursor))
    return table.concat(parts)
end

--- @param text string
--- @param width number display cells; `math.huge` for no limit
--- @return string span `text` whole as one code span, cut to fit `width`
function M.whole_within(text, width)
    -- Cutting cannot lengthen a backtick run, so the uncut text's guard is
    -- the most the cut one can cost.
    local guard_cost = #guard_whole(text) - #text
    return guard_whole(TextWrap.truncate_to_width(text, width - guard_cost))
end

--- The text is cut before it is guarded, so a cut never leaves a guard open.
--- If no cut fits, `text` is guarded whole instead.
--- @param text string single line
--- @param width number display cells; `math.huge` for no limit
--- @return string guarded words of `text` that hold a markdown-special character guarded, cut to fit `width`
function M.words_within(text, width)
    local cut_width = math.min(width, vim.fn.strdisplaywidth(text))
    -- The guards' cost depends on where the cut lands, so each overshoot
    -- shortens the cut until it fits or reaches the shortest cut
    -- `truncate_to_width` makes.
    repeat
        local guarded = guard_words(TextWrap.truncate_to_width(text, cut_width))
        local overflow = vim.fn.strdisplaywidth(guarded) - width
        if overflow <= 0 then
            return guarded
        end
        local shortest = cut_width <= 4
        cut_width = math.max(4, cut_width - overflow)
    until shortest
    return M.whole_within(text, width)
end

return M
