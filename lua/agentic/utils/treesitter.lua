--- Treesitter walk helpers for reconstructing syntactic context.
---
--- These functions compute highlights for a snippet "as if" it were spliced
--- into a real file, so captures that depend on structural context
--- (strings, comments, docstrings, injections) come out right. The chat
--- buffer's markdown treesitter injection only sees the isolated diff lines
--- and can't know they live inside e.g. a Python triple-quoted string.
---
--- @class agentic.utils.Treesitter
local M = {}

--- Walk up from `node` until its parent is `root`, returning the direct child
--- of `root` that contains `node`. Returns `root` itself if `node == root`.
--- @param node TSNode
--- @param root TSNode
--- @return TSNode
function M.top_level_ancestor(node, root)
    if node:id() == root:id() then
        return node
    end
    local current = node
    local parent = current:parent()
    while parent and parent:id() ~= root:id() do
        current = parent
        parent = current:parent()
    end
    return current
end

--- Clamp a (start_row, end_row) range to the buffer's line count.
--- Returns nil if the range is unsalvageable (buffer empty, start past end).
--- @param bufnr integer
--- @param start_row integer
--- @param end_row integer
--- @return integer? start
--- @return integer? end_
local function clamp_range(bufnr, start_row, end_row)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count == 0 then
        return nil, nil
    end
    local s = math.max(0, math.min(start_row, line_count - 1))
    local e = math.max(s, math.min(end_row, line_count - 1))
    return s, e
end

--- Find the union of top-level ancestors containing rows [splice_start, splice_end).
--- Uses `named_descendant_for_range` to locate a starting node, then walks up to
--- a direct child of the tree root. For edits spanning multiple top-level nodes,
--- returns the union of their row ranges.
--- @param bufnr integer
--- @param lang string Parser language (e.g. "python")
--- @param splice_start integer 0-indexed row (inclusive)
--- @param splice_end integer 0-indexed row (exclusive)
--- @return integer? ctx_start 0-indexed row (inclusive)
--- @return integer? ctx_end 0-indexed row (exclusive)
function M.get_context_range(bufnr, lang, splice_start, splice_end)
    local s, e = clamp_range(bufnr, splice_start, splice_end)
    if not s or not e then
        return nil, nil
    end

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if not ok or not parser then
        return nil, nil
    end

    local trees = parser:parse()
    if not trees or not trees[1] then
        return nil, nil
    end
    local root = trees[1]:root()

    -- Zero-width range (pure insertion): widen end to start + 1 for descendant
    -- lookup so we find the surrounding node.
    local probe_end = e
    if splice_start == splice_end then
        probe_end = math.min(e + 1, vim.api.nvim_buf_line_count(bufnr))
    end

    local ctx_start, ctx_end
    for probe_row = s, probe_end do
        local line = vim.api.nvim_buf_get_lines(
            bufnr,
            probe_row,
            probe_row + 1,
            false
        )[1] or ""
        local probe_col_end = math.max(#line - 1, 0)
        local node = root:named_descendant_for_range(
            probe_row,
            0,
            probe_row,
            probe_col_end
        )
        if node then
            local ancestor = M.top_level_ancestor(node, root)
            local a_start, _, a_end, _ = ancestor:range()
            ctx_start = ctx_start and math.min(ctx_start, a_start) or a_start
            ctx_end = ctx_end and math.max(ctx_end, a_end + 1) or (a_end + 1)
        end
    end

    if not ctx_start then
        return nil, nil
    end
    return ctx_start, ctx_end
end

--- Parse `new_lines` spliced into the buffer's surrounding context, then
--- extract highlight captures for just the new_lines rows. The result maps
--- 0-indexed row-within-new_lines to a byte-col -> capture-name map.
---
--- @param bufnr integer Source buffer containing the file
--- @param lang string Parser language
--- @param splice_start integer 0-indexed row where new_lines replaces content (inclusive)
--- @param splice_end integer 0-indexed row (exclusive) — end of replaced range in bufnr
--- @param new_lines string[] Lines to splice in and highlight
--- @return table<integer, table<integer, string>>? highlight_map
function M.build_highlight_map(bufnr, lang, splice_start, splice_end, new_lines)
    local ok_parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if not ok_parser then
        return nil
    end

    local ctx_start, ctx_end =
        M.get_context_range(bufnr, lang, splice_start, splice_end)
    if not ctx_start or not ctx_end then
        return nil
    end

    -- Build the reconstruction: context rows with new_lines spliced in.
    local prefix =
        vim.api.nvim_buf_get_lines(bufnr, ctx_start, splice_start, false)
    local suffix = vim.api.nvim_buf_get_lines(bufnr, splice_end, ctx_end, false)

    local reconstructed = {}
    vim.list_extend(reconstructed, prefix)
    vim.list_extend(reconstructed, new_lines)
    vim.list_extend(reconstructed, suffix)

    local source = table.concat(reconstructed, "\n")
    local ok_lang, lang_tree =
        pcall(vim.treesitter.get_string_parser, source, lang)
    if not ok_lang or not lang_tree then
        return nil
    end
    local trees = lang_tree:parse(true)
    if not trees or not trees[1] then
        return nil
    end

    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
        return nil
    end

    local target_start = #prefix
    local target_end = target_start + #new_lines

    --- @type table<integer, table<integer, string>>
    local map = {}

    -- Iterate all trees to include injections (markdown inside docstrings, etc.).
    lang_tree:for_each_tree(function(tree, ltree)
        local tree_lang = ltree:lang()
        local q = vim.treesitter.query.get(tree_lang, "highlights")
        if not q then
            return
        end
        local root = tree:root()
        local r_start, _, r_end, _ = root:range()
        -- Skip trees that can't overlap our target rows.
        if r_end < target_start or r_start > target_end then
            return
        end
        for id, node, _ in
            q:iter_captures(root, source, target_start, target_end)
        do
            local name = q.captures[id]
            if name and not name:match("^_") then
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
