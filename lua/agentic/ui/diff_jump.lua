local FileSystem = require("agentic.utils.file_system")
local Renderer = require("agentic.ui.tool_call_renderer")
local SessionRegistry = require("agentic.session_registry")
local TextMatcher = require("agentic.utils.text_matcher")
local Theme = require("agentic.theme")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- @class agentic.ui.DiffJump.Target
--- @field file_row integer 1-indexed line in target file
--- @field file_col integer 0-indexed byte column in target file
--- @field exact boolean True when row+col map to a "new" line; false for fallback (deletion, header, fence)

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
--- come before all "new" lines (see tool_call_renderer.lua:783-829). We
--- replay that order to count rows per pair without storing extra state.
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

    local lang = Theme.get_language_from_path(block.argument)
    local has_fences = lang ~= "md" and lang ~= "markdown"

    -- Layout: header (1) + `argument` (1) + opening fence (0 or 1).
    local body_offset = block_start_row + 2 + (has_fences and 1 or 0)
    local row_in_body = chat_row - body_offset

    local first_target = {
        file_row = diff_blocks[1].start_line,
        file_col = 0,
        exact = false,
    }

    if row_in_body < 0 then
        return first_target
    end

    local cursor = 0
    for _, db in ipairs(diff_blocks) do
        local old_count = #db.old_lines
        local new_count = #db.new_lines
        local is_new_file = old_count == 0

        if is_new_file then
            for ni = 1, new_count do
                if cursor == row_in_body then
                    --- @type agentic.ui.DiffJump.Target
                    local target = {
                        file_row = db.start_line + ni - 1,
                        file_col = chat_col,
                        exact = true,
                    }
                    return target
                end
                cursor = cursor + 1
            end
        else
            local filtered = ToolCallDiff.filter_unchanged_lines(
                db.old_lines,
                db.new_lines
            )

            for _, pair in ipairs(filtered.pairs) do
                if pair.old_line then
                    if cursor == row_in_body then
                        if pair.new_idx then
                            -- Paired modification: jump to the matching new
                            -- line. Column is best-effort (chat shows old
                            -- content here, file has new — same byte index).
                            --- @type agentic.ui.DiffJump.Target
                            local target = {
                                file_row = db.start_line + pair.new_idx - 1,
                                file_col = chat_col,
                                exact = false,
                            }
                            return target
                        end
                        --- @type agentic.ui.DiffJump.Target
                        local target = {
                            file_row = db.start_line,
                            file_col = 0,
                            exact = false,
                        }
                        return target
                    end
                    cursor = cursor + 1
                end
            end

            for _, pair in ipairs(filtered.pairs) do
                if pair.new_line and pair.new_idx then
                    if cursor == row_in_body then
                        --- @type agentic.ui.DiffJump.Target
                        local target = {
                            file_row = db.start_line + pair.new_idx - 1,
                            file_col = chat_col,
                            exact = true,
                        }
                        return target
                    end
                    cursor = cursor + 1
                end
            end
        end
    end

    -- Past last hunk row (closing fence / footer). Use the last hunk start.
    --- @type agentic.ui.DiffJump.Target
    local last_target = {
        file_row = diff_blocks[#diff_blocks].start_line,
        file_col = 0,
        exact = false,
    }
    return last_target
end

--- Open `path` (or focus an existing tab+window already showing it) and
--- place the cursor at `target`. `:tab drop` handles both cases: focus
--- the existing window if any tab has it on screen, else open a new tab.
--- @param path string
--- @param target agentic.ui.DiffJump.Target
--- @param chat_screen_row integer Result of vim.fn.winline() in chat window
function M.open_in_tab(path, target, chat_screen_row)
    local abs = FileSystem.to_absolute_path(path) or path
    vim.cmd("tab drop " .. vim.fn.fnameescape(abs))

    local file_line_count = vim.api.nvim_buf_line_count(0)
    local lnum = math.max(1, math.min(target.file_row, file_line_count))

    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
    local col = math.max(0, math.min(target.file_col, #line))

    -- topline so the cursor lands at the same screen row as it had in the
    -- chat. Best effort: assumes no wrap on the target side. winrestview
    -- clamps topline if it would push the cursor off-screen.
    local desired_topline = math.max(1, lnum - chat_screen_row + 1)
    vim.fn.winrestview({ topline = desired_topline, lnum = lnum, col = col })
end

--- @alias agentic.ui.DiffJump.Status
---| "ok"            # jump performed
---| "no_session"    # no SessionManager for this tabpage
---| "no_block"      # cursor not inside any tool call block
---| "no_diff"       # block has no diff (e.g. Read, Search)
---| "no_target"     # extract_diff_blocks returned no hunks

--- Top-level handler for the chat buffer's open_diff_file keymap.
--- @return agentic.ui.DiffJump.Status status
function M.handle()
    local win = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local chat_row = cursor[1] - 1
    local chat_col = cursor[2]
    local screen_row = vim.fn.winline()

    local tab_page_id = vim.api.nvim_get_current_tabpage()
    local session = SessionRegistry.sessions[tab_page_id]
    if not session or not session.message_writer then
        return "no_session"
    end

    local block, block_start_row = M.find_block_at_row(
        bufnr,
        chat_row,
        session.message_writer.tool_call_blocks
    )

    if not block or not block_start_row then
        return "no_block"
    end

    if not block.diff or not block.argument or block.argument == "" then
        return "no_diff"
    end

    local target = M.compute_target(block, block_start_row, chat_row, chat_col)
    if not target then
        return "no_target"
    end

    M.open_in_tab(block.argument, target, screen_row)
    return "ok"
end

return M
