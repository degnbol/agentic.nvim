--- Treesitter helpers: the language of a file, and syntactic context for a
--- snippet of one.
---
--- `highlight_map_in_context` parses a snippet "as if" it were spliced into
--- a real file, so captures that depend on structural context (strings,
--- comments, docstrings, injections) come out right. The chat buffer's
--- markdown treesitter injection only sees the isolated diff lines and
--- can't know they live inside e.g. a Python triple-quoted string.
---
--- @class agentic.utils.Treesitter
local M = {}

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

    local source = table.concat(reconstructed, "\n")
    -- A zsh-hang trigger anywhere in the reconstructed file would freeze the
    -- editor at parse() (see zsh_parse_guard); skip highlighting instead.
    if ZshParseGuard.contains_hang_trigger(source) then
        return nil
    end
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

return M
