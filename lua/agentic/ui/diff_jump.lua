local BufHelpers = require("agentic.utils.buf_helpers")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local Renderer = require("agentic.ui.tool_call_renderer")
local TextMatcher = require("agentic.utils.text_matcher")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- @class agentic.ui.DiffJump.Target
--- @field path string The target file, absolute or relative to the cwd
--- @field file_row integer 1-indexed line in target file
--- @field file_col integer 0-indexed byte column in target file

--- @class agentic.ui.DiffJump
local M = {}

--- Find the tool call block whose extmark range contains `row`.
--- @param bufnr integer
--- @param row integer 0-indexed buffer row
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @return agentic.ui.MessageWriter.ToolCallBlock|nil block
--- @return integer|nil block_start_row
--- @return integer|nil block_end_row
function M.find_block_at_row(bufnr, row, tool_call_blocks)
    for _, block in pairs(tool_call_blocks) do
        if block.extmark_id then
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                bufnr,
                Renderer.NS_TOOL_BLOCKS,
                block.extmark_id,
                { details = true }
            )
            local start_row = pos[1]
            local details = pos[3]
            if start_row and details and details.end_row then
                if row >= start_row and row <= details.end_row then
                    return block, start_row, details.end_row
                end
            end
        end
    end
    return nil, nil, nil
end

--- Map a chat (row, col) inside a diff block to a target file position.
--- The renderer emits hunks in order; within each hunk, all "old" lines
--- come before all "new" lines (see `insert_diff_line` in
--- tool_call_renderer.lua). We replay that order to count rows per pair
--- without storing extra state.
--- @param block agentic.ui.MessageWriter.ToolCallBlock
--- @param block_start_row integer 0-indexed first row of the block in chat buffer
--- @param chat_row integer 0-indexed
--- @param chat_col integer 0-indexed byte column from the chat line
--- @return agentic.ui.DiffJump.Target|nil target
function M.compute_target(block, block_start_row, chat_row, chat_col)
    if not block.diff or not block.argument or block.argument == "" then
        return nil
    end

    -- Prefer the diff_blocks captured by the renderer at first render. The
    -- target file's loaded buffer may have been refreshed to post-edit
    -- content since (e.g. by a previous tabedit triggering a reload), which
    -- breaks OLD-based matching. The cached result was correct at render
    -- time, so reuse it instead of re-extracting against possibly-stale
    -- buffer state.
    local diff_blocks = block.cached_diff_blocks
    if not diff_blocks or #diff_blocks == 0 then
        diff_blocks = ToolCallDiff.extract_diff_blocks({
            path = block.argument,
            old_text = block.diff.old,
            new_text = block.diff.new,
            replace_all = block.diff.all,
        })
    end

    -- Reverse-match fallback: extract_diff_blocks searches for OLD in the
    -- file. After an edit is applied, the file holds NEW, so OLD won't be
    -- found. Locate NEW directly to recover usable hunk positions. This is
    -- the only path that works for blocks rendered before the cache code
    -- was deployed.
    if #diff_blocks == 0 then
        local new_lines = ToolCallDiff.normalize_to_lines(block.diff.new)
        if not ToolCallDiff.is_empty_lines(new_lines) then
            local abs = FileSystem.to_absolute_path(block.argument)
            local file_lines = FileSystem.read_from_buffer_or_disk(abs) or {}
            local matches = TextMatcher.find_all_matches(file_lines, new_lines)
            if #matches > 0 then
                local m = matches[1]
                local old_lines =
                    ToolCallDiff.normalize_to_lines(block.diff.old)
                --- @type agentic.ui.ToolCallDiff.DiffBlock
                local synth = {
                    start_line = m.start_line,
                    end_line = m.end_line,
                    old_lines = old_lines,
                    new_lines = new_lines,
                }
                diff_blocks = { synth }
            end
        end
    end

    if #diff_blocks == 0 then
        return nil
    end

    --- @param file_row integer
    --- @param file_col integer
    --- @return agentic.ui.DiffJump.Target
    local function at(file_row, file_col)
        --- @type agentic.ui.DiffJump.Target
        local target = {
            path = block.argument,
            file_row = file_row,
            file_col = file_col,
        }
        return target
    end

    -- Layout: collapsed header (1) + opening fence (1). The filename now
    -- lives on the header line, so there is no separate `argument` row.
    local body_offset = block_start_row + 2
    local row_in_body = chat_row - body_offset

    if row_in_body < 0 then
        return at(diff_blocks[1].start_line, 0)
    end

    local cursor = 0
    for _, db in ipairs(diff_blocks) do
        local old_count = #db.old_lines
        local new_count = #db.new_lines
        local is_new_file = old_count == 0

        if is_new_file then
            for ni = 1, new_count do
                if cursor == row_in_body then
                    return at(db.start_line + ni - 1, chat_col)
                end
                cursor = cursor + 1
            end
        else
            local filtered =
                ToolCallDiff.filter_unchanged_lines(db.old_lines, db.new_lines)

            for _, pair in ipairs(filtered.pairs) do
                if pair.old_line then
                    if cursor == row_in_body then
                        if pair.new_idx then
                            -- Paired modification: jump to the matching new
                            -- line. Column is best-effort (chat shows old
                            -- content here, file has new — same byte index).
                            return at(
                                db.start_line + pair.new_idx - 1,
                                chat_col
                            )
                        end
                        return at(db.start_line, 0)
                    end
                    cursor = cursor + 1
                end
            end

            for _, pair in ipairs(filtered.pairs) do
                if pair.new_line and pair.new_idx then
                    if cursor == row_in_body then
                        return at(db.start_line + pair.new_idx - 1, chat_col)
                    end
                    cursor = cursor + 1
                end
            end
        end
    end

    -- Past last hunk row (closing fence / footer). Use the last hunk start.
    return at(diff_blocks[#diff_blocks].start_line, 0)
end

--- Open `target.path` with `open_cmd` and place the cursor at `target`, on
--- screen row `screen_row` of the window it lands in.
--- @param target agentic.ui.DiffJump.Target
--- @param open_cmd string Ex command that takes a file name, e.g. `edit`, `split`, `tab drop`
--- @param screen_row integer 1-indexed window row, as `winline()` reports it
function M.open(target, open_cmd, screen_row)
    local abs = FileSystem.to_absolute_path(target.path) or target.path
    vim.cmd(open_cmd .. " " .. vim.fn.fnameescape(abs))

    local file_line_count = vim.api.nvim_buf_line_count(0)
    local lnum = math.max(1, math.min(target.file_row, file_line_count))

    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
    local col = math.max(0, math.min(target.file_col, #line))

    -- Best effort: assumes no wrap on the target side. winrestview clamps
    -- topline if it would push the cursor off-screen.
    local desired_topline = math.max(1, lnum - screen_row + 1)
    vim.fn.winrestview({ topline = desired_topline, lnum = lnum, col = col })
end

--- The edited file and position for a buffer position inside an edit block.
--- The header, a removed row with no replacement, and rows past the last hunk
--- give a hunk's first line.
--- @param bufnr integer
--- @param row integer 0-indexed buffer row
--- @param col integer 0-indexed byte column
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock> The blocks rendered in `bufnr`
--- @return agentic.ui.DiffJump.Target|nil target Nil outside edit blocks, or when the edit's hunks are not found in the file
function M.target_at(bufnr, row, col, tool_call_blocks)
    local block, block_start_row =
        M.find_block_at_row(bufnr, row, tool_call_blocks)
    if not block or not block_start_row then
        return nil
    end
    return M.compute_target(block, block_start_row, row, col)
end

--- Native file-opening keys, each with the Ex command that opens a file the
--- same way.
local GOTO_FILE_KEYS = {
    gf = "edit",
    ["<C-w>f"] = "split",
    ["<C-w><C-f>"] = "split",
    ["<C-w>gf"] = "tabedit",
}

--- Make `gf`, `<C-w>f`, `<C-w><C-f>` and `<C-w>gf` in `bufnr` open the edited
--- file at the line where the native key fails and the cursor is inside one of
--- `writer`'s edit blocks. A count is ignored there. Elsewhere the keys act
--- natively.
--- @param bufnr integer
--- @param writer agentic.ui.MessageWriter The writer rendering `bufnr`
function M.set_goto_file_keymaps(bufnr, writer)
    for key, open_cmd in pairs(GOTO_FILE_KEYS) do
        BufHelpers.keymap_set(bufnr, "n", key, function()
            local count = vim.v.count > 0 and tostring(vim.v.count) or ""
            local ok, err = pcall(
                vim.cmd.normal,
                { count .. vim.keycode(key), bang = true }
            )
            if ok then
                return
            end
            local cursor = vim.api.nvim_win_get_cursor(0)
            local target = M.target_at(
                bufnr,
                cursor[1] - 1,
                cursor[2],
                writer.tool_call_blocks
            )
            if not target then
                local native_error = tostring(err):gsub("^Vim%(normal%):", "")
                Logger.notify(native_error, vim.log.levels.ERROR)
                return
            end
            M.open(target, open_cmd, vim.fn.winline())
        end, { desc = "Agentic: Open file under cursor" })
    end
end

return M
