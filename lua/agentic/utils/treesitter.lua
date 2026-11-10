--- Treesitter helpers: the language of a file or an injection name,
--- syntactic context for a snippet of one, the conceal the highlights
--- queries set in a buffer or a line of text, and query source edits.
---
--- `highlight_map_in_context` parses a snippet "as if" it were spliced into
--- a real file, so captures that depend on structural context (strings,
--- comments, docstrings, injections) come out right. The chat buffer's
--- markdown treesitter injection only sees the isolated diff lines and
--- can't know they live inside e.g. a Python triple-quoted string.
---
--- @class agentic.utils.Treesitter
local M = {}

local Conceal = require("agentic.utils.conceal")
local ZshParseGuard = require("agentic.utils.zsh_parse_guard")

--- Treesitter language of a file, detected from its name, else from
--- `contents` when the name alone does not decide it (e.g. an extensionless
--- zsh `#compdef` completion). The result is the parser registered for the
--- filetype (e.g. `bash` for `sh`).
--- @param file_path string
--- @param contents string[]|nil Body lines
--- @return string language Empty when no filetype matches
function M.language_for_path(file_path, contents)
    local ft = vim.filetype.match({ filename = file_path, contents = contents })
    return ft and vim.treesitter.language.get_lang(ft) or ""
end

--- @type table<string, boolean>
local has_parser = {}

--- Language that an injection of language name `alias` gets, as `resolve_lang`
--- in $VIMRUNTIME/lua/vim/treesitter/languagetree.lua resolves it: the
--- normalised name when it has a parser, else the language of the filetype of
--- that name when it has a parser. Parser presence is cached per name, as in
--- core, so a parser added later is not seen.
--- @param alias string
--- @return string|nil lang nil when no parser resolves
function M.resolve_lang(alias)
    local name = (alias:gsub("%s+", ""):lower():gsub("%-", "_"))
    if name:match("[%w_]+") ~= name then
        return nil
    end
    for _, lang in ipairs({ name, vim.treesitter.language.get_lang(name) }) do
        if has_parser[lang] == nil then
            -- Core's test: a parser that exists, without loading it.
            has_parser[lang] = vim._ts_has_language(lang)
                or #vim.api.nvim_get_runtime_file(
                        "parser/" .. lang .. ".*",
                        false
                    )
                    > 0
        end
        if has_parser[lang] then
            return lang
        end
    end
    return nil
end

--- Whether a query `predicate` node is a `#set!` directive whose key, its
--- first parameter after an optional capture, is `key`.
--- @param predicate TSNode
--- @param source string
--- @param key string
--- @return boolean
local function is_set_of(predicate, source, key)
    --- Text of the first named node in `field`. The `name` field also holds
    --- the anonymous `#`.
    --- @param field string
    --- @return string|nil
    local function field_text(field)
        for _, node in ipairs(predicate:field(field)) do
            if node:named() then
                return vim.treesitter.get_node_text(node, source)
            end
        end
    end
    if field_text("name") ~= "set" or field_text("type") ~= "!" then
        return false
    end
    local parameters = predicate:field("parameters")[1]
    for parameter in parameters:iter_children() do
        if parameter:named() and parameter:type() ~= "capture" then
            return vim.treesitter.get_node_text(parameter, source) == key
        end
    end
    return false
end

--- Query source `text` without its `conceal_lines` directives:
--- `(#set! conceal_lines "")` and the capture form
--- `(#set! @c conceal_lines "")`.
--- @param text string
--- @return string
function M.strip_conceal_lines(text)
    local root =
        vim.treesitter.get_string_parser(text, "query"):parse()[1]:root()
    local predicates = vim.treesitter.query.parse("query", "(predicate) @p")
    local kept = {} --- @type string[]
    local from = 0
    for _, node in predicates:iter_captures(root, text) do
        if is_set_of(node, text, "conceal_lines") then
            local _, _, start_byte, _, _, end_byte = node:range(true)
            table.insert(kept, text:sub(from + 1, start_byte))
            from = end_byte
        end
    end
    table.insert(kept, text:sub(from + 1))
    return table.concat(kept)
end

--- Parse `new_lines` spliced into the surrounding file content, then extract
--- highlight captures for just the new_lines rows. The result maps
--- 0-indexed row-within-new_lines to a byte-col → capture-name map.
---
--- Captures include injected languages, also from an injection that opens
--- above the new_lines rows. Cost scales with the whole file, not with
--- new_lines.
---
--- @param file_lines string[] Content of the file the snippet lives in
--- @param lang string Parser language
--- @param splice_start integer 0-indexed row where new_lines replaces content (inclusive)
--- @param splice_end integer 0-indexed row (exclusive) — end of replaced range
--- @param new_lines string[] Lines to splice in and highlight
--- @return table<integer, table<integer, string>>|nil highlight_map
function M.highlight_map_in_context(
    file_lines,
    lang,
    splice_start,
    splice_end,
    new_lines
)
    local s = math.max(0, math.min(splice_start, #file_lines))
    local e = math.max(s, math.min(splice_end, #file_lines))

    local prefix = vim.list_slice(file_lines, 1, s)
    local suffix = vim.list_slice(file_lines, e + 1)

    local reconstructed = {}
    vim.list_extend(reconstructed, prefix)
    vim.list_extend(reconstructed, new_lines)
    vim.list_extend(reconstructed, suffix)

    -- Any language can inject zsh, so defuse the whole text.
    local source =
        ZshParseGuard.defuse_hang_triggers(table.concat(reconstructed, "\n"))
    local ok_lang, lang_tree =
        pcall(vim.treesitter.get_string_parser, source, lang)
    if not ok_lang or not lang_tree then
        return nil
    end

    local target_start = #prefix
    local target_end = target_start + #new_lines

    -- The root tree parses the whole source, injections only where their
    -- region overlaps the range (`:h LanguageTree:parse()`). Do not window
    -- the source to a smaller ancestor instead: a too-narrow window drops
    -- the surrounding structure (string opener/closer, injection root) and
    -- yields bare-code captures for content inside a docstring, and a
    -- window start at a top-level node needs the root parse it would skip.
    local trees = lang_tree:parse({ target_start, 0, target_end, 0 })
    if not trees or not trees[1] then
        return nil
    end

    --- @type table<integer, table<integer, string>>
    local map = {}

    -- Iterate all trees to include injections (markdown inside docstrings,
    -- regex inside python strings, etc.).
    lang_tree:for_each_tree(function(tree, ltree)
        local tree_lang = ltree:lang()
        local q = vim.treesitter.query.get(tree_lang, "highlights")
        if not q then
            return
        end
        local root = tree:root()
        local r_start, _, r_end, _ = root:range()
        if r_end < target_start or r_start > target_end then
            return
        end
        for id, node, _ in
            q:iter_captures(root, source, target_start, target_end)
        do
            local name = q.captures[id]
            -- Skip private (`_`-prefixed) captures and `@spell` family —
            -- the latter is a content marker for spellcheck integration
            -- with no foreground colour, so writing it into the map would
            -- shadow the parent `@string` capture and produce no visible
            -- override over the markdown injection's keyword colours.
            if name and not name:match("^_") and not name:match("^spell") then
                local n_start_row, n_start_col, n_end_row, n_end_col =
                    node:range()
                if n_start_row < target_end and n_end_row >= target_start then
                    local qualified = "@" .. name .. "." .. tree_lang
                    local first = math.max(n_start_row, target_start)
                    local last = math.min(n_end_row, target_end - 1)
                    for row = first, last do
                        local rel = row - target_start
                        map[rel] = map[rel] or {}
                        local row_line = reconstructed[row + 1] or ""
                        local col_start = (row == n_start_row) and n_start_col
                            or 0
                        local col_end = (row == n_end_row) and n_end_col
                            or #row_line
                        for c = col_start, col_end - 1 do
                            map[rel][c] = qualified
                        end
                    end
                end
            end
        end
    end)

    return map
end

--- Intersection of two ranges, nil when they do not overlap.
--- @param a Range4 0-based, end exclusive
--- @param b Range4
--- @return Range4|nil
local function intersect(a, b)
    local function before(row_a, col_a, row_b, col_b)
        return row_a < row_b or (row_a == row_b and col_a < col_b)
    end
    local start = before(a[1], a[2], b[1], b[2]) and b or a
    local stop = before(a[3], a[4], b[3], b[4]) and a or b
    if not before(start[1], start[2], stop[3], stop[4]) then
        return nil
    end
    return { start[1], start[2], stop[3], stop[4] }
end

--- @class agentic.utils.Treesitter.HighlightTree
--- @field root TSNode
--- @field query vim.treesitter.Query highlights query of the tree's language
--- @field regions Range4[] the tree's included ranges
--- @field start_row integer 0-based
--- @field end_row integer 0-based, inclusive

--- Trees of a parsed language tree on rows srow..erow-1, in drawing order,
--- each with its highlights query. Trees of a language without one are left
--- out.
--- @param language_tree vim.treesitter.LanguageTree
--- @param srow integer
--- @param erow integer exclusive
--- @return agentic.utils.Treesitter.HighlightTree[]
local function trees_with_highlights(language_tree, srow, erow)
    --- @type agentic.utils.Treesitter.HighlightTree[]
    local trees = {}
    language_tree:for_each_tree(function(tstree, ltree)
        local root = tstree:root()
        local start_row, _, end_row = root:range()
        local query = vim.treesitter.query.get(ltree:lang(), "highlights")
        if query and start_row < erow and end_row >= srow then
            trees[#trees + 1] = {
                root = root,
                query = query,
                regions = tstree:included_ranges(false),
                start_row = start_row,
                end_row = end_row,
            }
        end
    end)
    return trees
end

--- Trees the active treesitter highlighter of `bufnr` draws on rows
--- srow..erow-1, in its drawing order, each with its language's highlights
--- query file (`vim.treesitter.query.get`), not the highlighter's own query.
--- Returns {} when no highlighter is active on the buffer.
--- @param bufnr integer
--- @param srow integer
--- @param erow integer exclusive
--- @return agentic.utils.Treesitter.HighlightTree[]
function M.highlight_trees(bufnr, srow, erow)
    local highlighter = vim.treesitter.highlighter.active[bufnr]
    if not highlighter then
        return {}
    end
    return trees_with_highlights(highlighter.tree, srow, erow)
end

--- Trees of one line of `lang` text, injected trees included, in drawing
--- order, each with its highlights query.
--- @param text string one line
--- @param lang string parser language
--- @return agentic.utils.Treesitter.HighlightTree[] {} when no parser for `lang` is installed
function M.string_highlight_trees(text, lang)
    if not vim.treesitter.language.add(lang) then
        return {}
    end
    local parser = vim.treesitter.get_string_parser(text, lang)
    parser:parse(true)
    return trees_with_highlights(parser, 0, 1)
end

--- Display cells of one line of `lang` text under the conceal its
--- highlights queries set, at `conceallevel`.
--- @param text string one line
--- @param lang string parser language
--- @param conceallevel integer 0 to 3
--- @return integer
function M.concealed_width(text, lang, conceallevel)
    local ranges =
        M.conceal_ranges(text, M.string_highlight_trees(text, lang), 0, 1)
    local columns = Conceal.columns(text, ranges, {}, 8, conceallevel)
    return columns.shown[#text]
end

--- Conceal ranges one tree draws on rows srow..erow-1, in capture order.
--- @param source integer|string buffer or text the tree was parsed from
--- @param tree agentic.utils.Treesitter.HighlightTree
--- @param srow integer
--- @param erow integer exclusive
--- @return agentic.utils.Conceal.Range[]
local function tree_conceal_ranges(source, tree, srow, erow)
    --- @type agentic.utils.Conceal.Range[]
    local ranges = {}
    for capture, node, metadata in
        tree.query:iter_captures(tree.root, source, srow, erow)
    do
        local capture_meta = metadata[capture] or {}
        local conceal = metadata.conceal or capture_meta.conceal
        if conceal then
            local priority = tonumber(
                metadata.priority or capture_meta.priority
            ) or vim.hl.priorities.treesitter
            local r = vim.treesitter.get_range(node, source, capture_meta)
            local node_range = { r[1], r[2], r[4], r[5] }
            for _, region in ipairs(tree.regions) do
                local clipped = intersect(region, node_range)
                if clipped then
                    vim.list_extend(
                        ranges,
                        Conceal.split_rows(
                            clipped,
                            conceal,
                            priority,
                            srow,
                            erow
                        )
                    )
                end
            end
        end
    end
    return ranges
end

--- Conceal ranges `trees` draw on rows srow..erow-1, in the highlighter's
--- drawing order: tree by tree, captures in query order. Mirrors
--- `on_range_impl` in $VIMRUNTIME/lua/vim/treesitter/highlighter.lua.
--- @param source integer|string buffer or text the trees were parsed from
--- @param trees agentic.utils.Treesitter.HighlightTree[]
--- @param srow integer
--- @param erow integer exclusive
--- @return agentic.utils.Conceal.Range[]
function M.conceal_ranges(source, trees, srow, erow)
    --- @type agentic.utils.Conceal.Range[]
    local ranges = {}
    for _, tree in ipairs(trees) do
        if tree.start_row < erow and tree.end_row >= srow then
            vim.list_extend(
                ranges,
                tree_conceal_ranges(source, tree, srow, erow)
            )
        end
    end
    return ranges
end

return M
