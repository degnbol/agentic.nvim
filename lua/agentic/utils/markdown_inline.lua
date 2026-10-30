--- Inline markdown split into words that can be rearranged onto lines
--- without gaining or losing markup.
--- @class agentic.utils.MarkdownInline
local M = {}

--- @class agentic.utils.MarkdownInline.Word
--- @field text string the word's source text
--- @field span? agentic.utils.MarkdownInline.Span outermost splittable span holding it
--- @field prefix? string text glued before the span, on the span's first word
--- @field suffix? string text glued after the span, on the span's last word

--- @class agentic.utils.MarkdownInline.Span
--- @field open string markup before the span's words, e.g. "**" or "["
--- @field close string markup after them, e.g. "**" or "](url \"title\")"

--- Nodes whose markup can be repeated around any run of their words.
local SPLITTABLE = {
    inline_link = true,
    emphasis = true,
    strong_emphasis = true,
    strikethrough = true,
}

--- @param text string
--- @param i integer 0-based byte, may be out of range
--- @return boolean
local function is_glue(text, i)
    return text:sub(i + 1, i + 1):match("%S") ~= nil
end

--- Byte range of a node in its source text.
--- @param node TSNode
--- @return integer start 0-based byte
--- @return integer stop 0-based byte, exclusive
local function byte_range(node)
    local _, _, start, _, _, stop = node:range(true)
    return start, stop
end

--- The bytes of an emphasis-like node between its leading and trailing
--- delimiters, and the named nodes in them.
--- @param node TSNode
--- @return integer start 0-based byte
--- @return integer stop 0-based byte, exclusive
--- @return TSNode[] nested
local function between_delimiters(node)
    local delimiters, nested = {}, {}
    for child in node:iter_children() do
        if child:type() == "emphasis_delimiter" then
            delimiters[#delimiters + 1] = child
        elseif child:named() then
            nested[#nested + 1] = child
        end
    end
    local start, stop = byte_range(node)
    for _, delimiter in ipairs(delimiters) do
        local d_start, d_stop = byte_range(delimiter)
        if d_start == start then
            start = d_stop
        end
    end
    for i = #delimiters, 1, -1 do
        local d_start, d_stop = byte_range(delimiters[i])
        if d_stop == stop then
            stop = d_start
        end
    end
    return start, stop, nested
end

--- Where a splittable span's words are: the `link_text` of a link, else
--- the bytes between its delimiters.
---
--- A strikethrough only splits as `~~a~~`, which parses as a strikethrough
--- wholly wrapping another: the markdown highlights conceal no single `~`,
--- and the parser pairs stray ones (`~5 to 10~`), so repeating them around
--- each line would show tildes the source did not have.
--- @param node TSNode
--- @return integer|nil start 0-based byte, nil when the span cannot split
--- @return integer stop 0-based byte, exclusive
--- @return TSNode[] nested nodes inside the words
local function span_content(node)
    if node:type() == "inline_link" then
        for child in node:iter_children() do
            if child:type() == "link_text" then
                local start, stop = byte_range(child)
                return start, stop, child:named_children()
            end
        end
        return nil, 0, {}
    end

    local start, stop, nested = between_delimiters(node)
    if node:type() ~= "strikethrough" then
        return start, stop, nested
    end
    local inner = nested[1]
    if #nested ~= 1 or inner:type() ~= "strikethrough" then
        return nil, 0, {}
    end
    local inner_start, inner_stop = byte_range(inner)
    if inner_start ~= start or inner_stop ~= stop then
        return nil, 0, {}
    end
    return between_delimiters(inner)
end

--- Byte ranges of the whitespace-separated runs in `text[start, stop)`.
--- Whitespace inside an `atoms` node does not separate.
--- @param text string
--- @param start integer 0-based byte
--- @param stop integer 0-based byte, exclusive
--- @param atoms TSNode[] nodes of `text` that do not split
--- @return { [1]: integer, [2]: integer }[] runs 0-based start and exclusive end bytes, in order
local function runs(text, start, stop, atoms)
    local shielded = {} --- @type table<integer, true>
    for _, atom in ipairs(atoms) do
        local a_start, a_stop = byte_range(atom)
        for i = a_start, a_stop - 1 do
            shielded[i] = true
        end
    end

    local out = {}
    local run_start --- @type integer|nil
    for i = start, stop do
        local blank = i == stop
            or (not shielded[i] and text:sub(i + 1, i + 1):match("%s") ~= nil)
        if blank and run_start then
            out[#out + 1] = { run_start, i }
            run_start = nil
        elseif not blank and not run_start then
            run_start = i
        end
    end
    return out
end

--- Words of inline markdown, split at whitespace except inside an atomic
--- node. Splittable spans are the outermost `inline_link` (its `link_text`),
--- `emphasis`, `strong_emphasis` and `strikethrough` nodes of the
--- `markdown_inline` treesitter grammar. Every other node, such as
--- `code_span` or `image`, and every span nested in a splittable one is
--- atomic, and so is a span that shares glued text with the span before it.
--- Text glued to a span without whitespace, such as trailing punctuation,
--- rides on the span's first or last word as its `prefix` or `suffix`.
--- @param text string inline markdown
--- @return agentic.utils.MarkdownInline.Word[] words in source order, {} for empty text
function M.words(text)
    local root = vim.treesitter
        .get_string_parser(text, "markdown_inline")
        :parse()[1]
        :root()

    local words = {} --- @type agentic.utils.MarkdownInline.Word[]
    local gap_start, gap_atoms = 0, {}
    local last_span_stop --- @type integer|nil

    --- @param stop integer 0-based byte, exclusive
    local function flush_gap(stop)
        for _, run in ipairs(runs(text, gap_start, stop, gap_atoms)) do
            local run_text = text:sub(run[1] + 1, run[2])
            if run[1] == last_span_stop then
                words[#words].suffix = run_text
            else
                words[#words + 1] = { text = run_text }
            end
        end
    end

    for node in root:iter_children() do
        if node:named() then
            local start, stop = byte_range(node)
            local glued_before = is_glue(text, start - 1)
            local gap_runs = runs(text, gap_start, start, gap_atoms)
            local glue_start = gap_runs[#gap_runs] and gap_runs[#gap_runs][1]
                or start
            local shares_glue = glued_before and glue_start == last_span_stop
            local span_runs = {}
            if SPLITTABLE[node:type()] and not shares_glue then
                local c_start, c_stop, nested = span_content(node)
                if c_start then
                    span_runs = runs(text, c_start, c_stop, nested)
                end
            end

            if #span_runs == 0 then
                gap_atoms[#gap_atoms + 1] = node
            else
                flush_gap(start)
                local prefix = glued_before and table.remove(words).text or nil
                --- @type agentic.utils.MarkdownInline.Span
                local span = {
                    open = text:sub(start + 1, span_runs[1][1]),
                    close = text:sub(span_runs[#span_runs][2] + 1, stop),
                }
                for _, run in ipairs(span_runs) do
                    words[#words + 1] =
                        { text = text:sub(run[1] + 1, run[2]), span = span }
                end
                words[#words - #span_runs + 1].prefix = prefix
                gap_start, gap_atoms, last_span_stop = stop, {}, stop
            end
        end
    end
    flush_gap(#text)
    return words
end

return M
