local ToolCallDiff = require("agentic.ui.tool_call_diff")
local Ansi = require("agentic.utils.ansi")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local DiffPreview = require("agentic.ui.diff_preview")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local Logger = require("agentic.utils.logger")
local TextWrap = require("agentic.utils.text_wrap")
local Theme = require("agentic.theme")

--- Format a tool kind for display: capitalise each word, replace underscores with spaces.
--- Leaves already-capitalised kinds (WebSearch, SubAgent, etc.) unchanged.
--- @param kind string
--- @return string
local function display_kind(kind)
    local result = kind:gsub("(%a)([%a]*)", function(first, rest)
        return first:upper() .. rest
    end):gsub("_", " ")
    return result
end

--- Return a backtick fence string long enough to avoid clashing with any
--- literal backtick runs inside `body_lines`.
--- @param body_lines string[]
--- @return string fence e.g. "```" or "````"
local function safe_fence(body_lines)
    local fence = "```"
    for _, line in ipairs(body_lines) do
        for ticks in line:gmatch("(`+)") do
            if #ticks >= #fence then
                fence = string.rep("`", #ticks + 1)
            end
        end
    end
    return fence
end

--- Format a long single-line shell command for readability by inserting
--- newlines after top-level operators (&&, ||, ;, |) outside of quotes and
--- subshells. Already-multiline commands or short commands are returned as-is.
--- @param cmd string
--- @return string
local function format_long_command(cmd)
    -- Skip if already multiline or short enough to read comfortably
    if cmd:find("\n", 1, true) or #cmd <= 80 then
        return cmd
    end

    local parts = {}
    local i = 1
    local len = #cmd
    local in_single = false
    local in_double = false
    local depth = 0 -- parenthesis/brace depth for $(...), (...), {...}

    while i <= len do
        local c = cmd:sub(i, i)

        if c == "'" and not in_double and depth == 0 then
            in_single = not in_single
            parts[#parts + 1] = c
            i = i + 1
        elseif c == '"' and not in_single and depth == 0 then
            in_double = not in_double
            parts[#parts + 1] = c
            i = i + 1
        elseif c == "\\" and not in_single then
            parts[#parts + 1] = cmd:sub(i, i + 1)
            i = i + 2
        elseif not in_single and not in_double then
            if c == "(" or c == "{" then
                depth = depth + 1
                parts[#parts + 1] = c
                i = i + 1
            elseif (c == ")" or c == "}") and depth > 0 then
                depth = depth - 1
                parts[#parts + 1] = c
                i = i + 1
            elseif depth == 0 then
                local two = cmd:sub(i, i + 1)
                local op, op_len
                if two == "&&" or two == "||" then
                    op, op_len = two, 2
                elseif c == ";" or c == "|" then
                    op, op_len = c, 1
                end

                if op then
                    parts[#parts + 1] = op
                    i = i + op_len
                    while i <= len and cmd:sub(i, i) == " " do
                        i = i + 1
                    end
                    if i <= len then
                        parts[#parts + 1] = "\n"
                    end
                else
                    parts[#parts + 1] = c
                    i = i + 1
                end
            else
                parts[#parts + 1] = c
                i = i + 1
            end
        else
            parts[#parts + 1] = c
            i = i + 1
        end
    end

    return table.concat(parts)
end

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DECORATIONS = vim.api.nvim_create_namespace("agentic_tool_decorations")
local NS_PERMISSION_BUTTONS =
    vim.api.nvim_create_namespace("agentic_permission_buttons")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")
local NS_STATUS = vim.api.nvim_create_namespace("agentic_status_footer")

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"old"|"new"|"new_modification" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)

--- @class agentic.ui.MessageWriter.SearchMatch
--- @field line_index integer Line index relative to block lines (0-based)
--- @field col_start integer Start column (byte offset)
--- @field col_end integer End column (byte offset)

--- @class agentic.ui.MessageWriter.ToolCallDiff
--- @field new string[]
--- @field old string[]
--- @field all? boolean

--- @class agentic.ui.MessageWriter.ToolCallBase
--- @field tool_call_id string
--- @field status agentic.acp.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff
--- @field kind? agentic.acp.ToolKind
--- @field argument? string
--- @field search_pattern? string Regex pattern for highlighting matches in search output

--- @class agentic.ui.MessageWriter.ToolCallBlock : agentic.ui.MessageWriter.ToolCallBase
--- @field kind agentic.acp.ToolKind
--- @field argument string
--- @field extmark_id? integer Range extmark spanning the block
--- @field decoration_extmark_ids? integer[] IDs of decoration extmarks from ExtmarkBlock
--- @field search_matches? agentic.ui.MessageWriter.SearchMatch[] Pattern match positions (relative to block lines)
--- @field search_ansi? agentic.utils.Ansi.Span[][] ANSI highlight spans for search body

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field _last_message_type? string
--- @field _should_auto_scroll? boolean
--- @field _scroll_scheduled? boolean
--- @field _on_content_changed? fun()
local MessageWriter = {}
MessageWriter.__index = MessageWriter

--- @param bufnr integer
--- @return agentic.ui.MessageWriter
function MessageWriter:new(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
        tool_call_blocks = {},
        _last_message_type = nil,
        _should_auto_scroll = nil,
        _scroll_scheduled = false,
        _chunk_start_line = nil,
        _last_wrote_tool_call = false,
    }, self)

    return instance
end

--- @param callback fun()|nil
function MessageWriter:set_on_content_changed(callback)
    self._on_content_changed = callback
end

function MessageWriter:_notify_content_changed()
    if self._on_content_changed then
        self._on_content_changed()
    end
end

--- Wraps BufHelpers.with_modifiable and fires _notify_content_changed after.
--- The callback may return false to suppress the notification (e.g. on early-return without edits).
--- with_modifiable returns false for invalid buffers, which also suppresses notification.
--- @param fn fun(bufnr: integer): boolean|nil
function MessageWriter:_with_modifiable_and_notify_change(fn)
    local result = BufHelpers.with_modifiable(self.bufnr, fn)
    if result ~= false then
        self:_notify_content_changed()
    end
end

--- Returns the text area width of the chat window (excluding sign column), or 80.
--- The chat window always has signcolumn=yes:1 (2 columns).
--- @return integer
function MessageWriter:_get_wrap_width()
    local winid = vim.fn.bufwinid(self.bufnr)
    if winid ~= -1 then
        return vim.api.nvim_win_get_width(winid) - 2
    end
    return 80
end

--- Writes a full message to the chat buffer and append two blank lines after.
--- Prose lines are hard-wrapped to the chat window width; code blocks are untouched.
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    local text = update.content
        and update.content.type == "text"
        and update.content.text

    if not text or text == "" then
        return
    end

    local lines = vim.split(text, "\n", { plain = true })
    lines = TextWrap.wrap_prose(lines, self:_get_wrap_width())

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function()
        self:_append_lines(lines)
        self:_append_lines({ "" })
    end)
end

--- Append trailing blank lines to separate from the next message.
--- If streamed chunks preceded this call, reflow their prose first.
function MessageWriter:append_separator()
    self:_with_modifiable_and_notify_change(function(bufnr)
        self:_reflow_chunks(bufnr, true)
        self:_append_lines({ "" })
    end)
end

--- Reflow prose in the region written by write_message_chunk.
--- When `flush_all` is false (during streaming), only reflows complete
--- paragraphs — up to the last blank line, leaving the in-progress
--- paragraph untouched. When true (response finished), reflows everything.
--- @param bufnr integer
--- @param flush_all? boolean
function MessageWriter:_reflow_chunks(bufnr, flush_all)
    local start = self._chunk_start_line
    if not start then
        return
    end

    local buf_end = vim.api.nvim_buf_line_count(bufnr)
    if start >= buf_end then
        return
    end

    local reflow_end = buf_end -- 0-indexed exclusive

    if not flush_all then
        -- Find the last blank line in the range (excluding the final line
        -- which is still being appended to). Reflow up to and including it.
        local last_blank = nil
        local lines = vim.api.nvim_buf_get_lines(bufnr, start, buf_end, false)
        for i = #lines - 1, 1, -1 do -- skip last line (index #lines)
            if lines[i]:match("^%s*$") then
                last_blank = start + (i - 1) -- lines[1] = buffer line `start`
                break
            end
        end
        if not last_blank then
            return -- no complete paragraph yet
        end
        reflow_end = last_blank + 1 -- exclusive, include the blank line
    end

    local raw = vim.api.nvim_buf_get_lines(bufnr, start, reflow_end, false)
    local wrapped = TextWrap.wrap_prose(raw, self:_get_wrap_width())

    if not vim.deep_equal(raw, wrapped) then
        vim.api.nvim_buf_set_lines(bufnr, start, reflow_end, false, wrapped)
    end

    if flush_all then
        self._chunk_start_line = nil
    else
        -- Advance past the reflowed region
        self._chunk_start_line = start + #wrapped
    end
end

--- Appends message chunks to the last line and column in the chat buffer
--- Some ACP providers stream chunks instead of full messages
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message_chunk(update)
    -- Hide thinking chunks from chat
    if update.sessionUpdate == "agent_thought_chunk" then
        return
    end

    local text = update.content
        and update.content.type == "text"
        and update.content.text

    if not text or text == "" then
        return
    end

    if
        self._last_message_type == "agent_thought_chunk"
        and update.sessionUpdate == "agent_message_chunk"
    then
        -- Different message type, add newline before appending, to create visual separation
        -- only for thought -> message
        text = "\n\n" .. text
    end

    -- Add blank line before text that follows a tool call block,
    -- so responses between tool calls have visual breathing room
    if self._last_wrote_tool_call then
        text = "\n" .. text
        self._last_wrote_tool_call = false
    end

    self._last_message_type = update.sessionUpdate

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        local last_line = vim.api.nvim_buf_line_count(bufnr) - 1

        -- Record where streamed content starts (0-indexed)
        if not self._chunk_start_line then
            local current = vim.api.nvim_buf_get_lines(
                bufnr,
                last_line,
                last_line + 1,
                false
            )[1] or ""
            -- If appending to a non-empty line, this line is the start
            -- If the line is empty, the new content starts here
            self._chunk_start_line = current == "" and last_line or last_line
        end

        local current_line = vim.api.nvim_buf_get_lines(
            bufnr,
            last_line,
            last_line + 1,
            false
        )[1] or ""
        local start_col = #current_line

        local lines_to_write = vim.split(text, "\n", { plain = true })

        local success, err = pcall(
            vim.api.nvim_buf_set_text,
            bufnr,
            last_line,
            start_col,
            last_line,
            start_col,
            lines_to_write
        )

        if not success then
            Logger.debug("Failed to set text in buffer", err, lines_to_write)
        end

        -- Reflow complete paragraphs when a paragraph boundary was written
        if text:find("\n") then
            self:_reflow_chunks(bufnr)
        end
    end)
end

--- @param lines string[]
--- @return nil
function MessageWriter:_append_lines(lines)
    local start_line = BufHelpers.is_buffer_empty(self.bufnr) and 0 or -1

    local success, err = pcall(
        vim.api.nvim_buf_set_lines,
        self.bufnr,
        start_line,
        -1,
        false,
        lines
    )

    if not success then
        Logger.debug("Failed to append lines to buffer", err, lines)
    end
end

--- @param bufnr integer
--- @return boolean
function MessageWriter:_check_auto_scroll(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return true
    end
    local winid = wins[1]
    local threshold = Config.auto_scroll and Config.auto_scroll.threshold

    if threshold == nil or threshold <= 0 then
        return false
    end

    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local distance_from_bottom = total_lines - cursor_line

    return distance_from_bottom <= threshold
end

--- @param bufnr integer Buffer number to scroll
function MessageWriter:_auto_scroll(bufnr)
    if self._should_auto_scroll ~= true then
        self._should_auto_scroll = self:_check_auto_scroll(bufnr)
    end

    if self._scroll_scheduled then
        return
    end
    self._scroll_scheduled = true

    vim.schedule(function()
        self._scroll_scheduled = false

        if vim.api.nvim_buf_is_valid(bufnr) then
            if self._should_auto_scroll then
                local wins = vim.fn.win_findbuf(bufnr)
                if #wins > 0 then
                    vim.api.nvim_win_call(wins[1], function()
                        vim.cmd("normal! G0zb")
                    end)
                end
            end
        end

        self._should_auto_scroll = nil
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:write_tool_call_block(tool_call_block)
    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        -- Flush any pending prose reflow before writing the tool call block.
        -- Without this, append_separator's _reflow_chunks would later process
        -- a range that includes these tool call lines, destroying extmarks
        -- (decorations, status, range tracking) via nvim_buf_set_lines.
        self:_reflow_chunks(bufnr, true)

        local kind = tool_call_block.kind

        local lines, highlight_ranges, ansi_highlights =
            self:_prepare_block_lines(tool_call_block)

        self:_append_lines(lines)

        -- Compute start/end AFTER _append_lines: when the buffer was empty,
        -- _append_lines replaces instead of appending, so line_count before
        -- the call would over-count by 1.
        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1
        local start_row = end_row - #lines + 1

        self:_apply_block_highlights(
            bufnr,
            start_row,
            end_row,
            kind,
            highlight_ranges,
            ansi_highlights,
            tool_call_block.search_matches,
            tool_call_block.search_ansi
        )

        tool_call_block.decoration_extmark_ids =
            ExtmarkBlock.render_block(bufnr, NS_DECORATIONS, {
                header_line = start_row,
                body_start = start_row + 1,
                body_end = end_row - 1,
                footer_line = end_row,
                hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
            })

        tool_call_block.extmark_id =
            vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
                end_row = end_row,
                right_gravity = false,
                end_right_gravity = false,
            })

        self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block

        self:_apply_tool_header_syntax(start_row, NS_STATUS)
        self:_apply_status_footer(end_row, tool_call_block.status)

        self:_append_lines({ "" })
        self._last_wrote_tool_call = true
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBase
function MessageWriter:update_tool_call_block(tool_call_block)
    local tracker = self.tool_call_blocks[tool_call_block.tool_call_id]

    if not tracker then
        Logger.debug(
            "Tool call block not found, ID: ",
            tool_call_block.tool_call_id
        )

        return
    end

    -- Some ACP providers don't send the diff on the first tool_call
    local already_has_diff = tracker.diff ~= nil
    local previous_body = tracker.body

    tracker = vim.tbl_deep_extend("force", tracker, tool_call_block)

    -- Merge body: append new to previous with divider if both exist and are different
    if
        previous_body
        and tool_call_block.body
        and not vim.deep_equal(previous_body, tool_call_block.body)
    then
        local merged = vim.list_extend({}, previous_body)
        vim.list_extend(merged, { "", "---", "" })
        vim.list_extend(merged, tool_call_block.body)
        tracker.body = merged
    end

    self.tool_call_blocks[tool_call_block.tool_call_id] = tracker

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        Logger.debug(
            "Extmark not found",
            { tool_call_id = tracker.tool_call_id }
        )
        return
    end

    local start_row = pos[1]
    local details = pos[3]
    local old_end_row = details and details.end_row

    if not old_end_row then
        Logger.debug(
            "Could not determine end row of tool call block",
            { tool_call_id = tracker.tool_call_id, details = details }
        )
        return
    end

    if start_row >= old_end_row then
        Logger.debug_to_file(
            "COLLAPSED EXTMARK — tool call block range is degenerate, bailing out",
            {
                tool_call_id = tracker.tool_call_id,
                kind = tracker.kind,
                argument = tracker.argument,
                start_row = start_row,
                old_end_row = old_end_row,
                status = tool_call_block.status,
                already_has_diff = already_has_diff,
                line_count = vim.api.nvim_buf_line_count(self.bufnr),
            }
        )
        -- Remove from tracking — the block is corrupt and cannot be updated
        self.tool_call_blocks[tool_call_block.tool_call_id] = nil
        return
    end

    self:_with_modifiable_and_notify_change(function(bufnr)
        -- Diff blocks don't change after the initial render
        -- only update status highlights - don't replace content
        if already_has_diff then
            if old_end_row > vim.api.nvim_buf_line_count(bufnr) then
                Logger.debug("Footer line index out of bounds", {
                    old_end_row = old_end_row,
                    line_count = vim.api.nvim_buf_line_count(bufnr),
                })
                return false
            end

            -- Decorations (╭│╰ borders) are stable — leave them in place.
            -- Only refresh status footer which changes on completion.
            self:_apply_status_footer(old_end_row, tracker.status)

            return false
        end

        local new_lines, highlight_ranges, ansi_highlights =
            self:_prepare_block_lines(tracker)

        -- Compare content lines excluding the footer — the buffer's footer
        -- has status text while _prepare_block_lines produces "" for it.
        local current_lines =
            vim.api.nvim_buf_get_lines(bufnr, start_row, old_end_row + 1, false)
        local content_unchanged = #new_lines == #current_lines
        if content_unchanged then
            for i = 1, #new_lines - 1 do
                if new_lines[i] ~= current_lines[i] then
                    content_unchanged = false
                    break
                end
            end
        end

        if content_unchanged then
            self:_apply_status_footer(old_end_row, tracker.status)
            return false
        end

        self:_clear_decoration_extmarks(tracker.decoration_extmark_ids)
        self:_clear_status_namespace(start_row, old_end_row)

        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row,
            old_end_row + 1,
            false,
            new_lines
        )

        local new_end_row = start_row + #new_lines - 1

        pcall(
            vim.api.nvim_buf_clear_namespace,
            bufnr,
            NS_DIFF_HIGHLIGHTS,
            start_row,
            old_end_row + 1
        )

        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                self:_apply_block_highlights(
                    bufnr,
                    start_row,
                    new_end_row,
                    tracker.kind,
                    highlight_ranges,
                    ansi_highlights,
                    tracker.search_matches,
                    tracker.search_ansi
                )
            end
        end)

        vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
            id = tracker.extmark_id,
            end_row = new_end_row,
            right_gravity = false,
            end_right_gravity = false,
        })

        tracker.decoration_extmark_ids =
            self:_render_decorations(start_row, new_end_row)

        self:_apply_tool_header_syntax(start_row, NS_STATUS)
        self:_apply_status_footer(new_end_row, tracker.status)
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string[] lines Array of lines to render
--- @return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges Array of highlight range specifications (relative to returned lines)
--- @return agentic.utils.Ansi.Span[][]|nil ansi_highlights Per-line ANSI highlight spans (execute blocks only)
function MessageWriter:_prepare_block_lines(tool_call_block)
    local kind = tool_call_block.kind
    local argument = tool_call_block.argument

    --- @type string[]
    local lines
    if kind == "execute" then
        local cmd_lines =
            vim.split(format_long_command(argument), "\n", { plain = true })
        lines = { string.format("%s ", display_kind(kind)), "```zsh" }
        vim.list_extend(lines, cmd_lines)
        table.insert(lines, "```")
    elseif kind == "search" then
        local cmd_lines = vim.split(argument, "\n", { plain = true })
        lines = { string.format("%s ", display_kind(kind)), "```bash" }
        vim.list_extend(lines, cmd_lines)
        table.insert(lines, "```")
    else
        -- Sanitize argument to prevent newlines in the header line
        -- nvim_buf_set_lines doesn't accept array items with embedded newlines
        argument = argument:gsub("\n", "\\n")
        lines = {
            string.format("%s `%s` ", display_kind(kind), argument),
        }
    end

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    if kind == "read" then
        -- Count lines from content, we don't want to show full content that was read
        local line_count = tool_call_block.body and #tool_call_block.body or 0

        if line_count > 0 then
            table.insert(lines, string.format("Read %d lines", line_count))

            --- @type agentic.ui.MessageWriter.HighlightRange
            local range = {
                type = "comment",
                line_index = #lines - 1,
            }

            table.insert(highlight_ranges, range)
        end
    elseif kind == "search" then
        local body = tool_call_block.body
        if body then
            local max_lines = Config.tool_call_display.search_max_lines
            local count = #body

            -- Wrap in a code fence to prevent markdown parsing (setext
            -- headings from "--", emphasis from "*", etc.). Comment highlight
            -- is applied by the generic path in _apply_block_highlights which
            -- already skips ``` lines.
            -- Add fold markers when body exceeds threshold.
            local use_fold = max_lines > 0 and count > max_lines
            local fence = safe_fence(body)
            table.insert(lines, fence .. "console")
            if use_fold then
                table.insert(lines, "{{{")
            end

            -- Match highlighting strategy:
            -- 1. ANSI codes from grep --color (ideal — zero re-work). ACP
            --    providers currently strip ANSI before sending, so this
            --    path rarely fires. Kept for future-proofing.
            -- 2. Regex fallback: extract the search pattern from the
            --    command string and re-match against body lines. Not
            --    ideal (double work) but necessary while ACP strips ANSI.
            local ansi_result = Ansi.process_lines(body)

            for i = 1, count do
                local line = ansi_result.has_ansi and ansi_result.lines[i]
                    or body[i]
                table.insert(lines, line)
            end

            if ansi_result.has_ansi then
                local displayed = {}
                for i = 1, count do
                    displayed[i] = ansi_result.highlights[i]
                end
                tool_call_block.search_ansi = displayed
            else
                local pattern = tool_call_block.search_pattern
                if not pattern then
                    -- Extract first quoted string from command
                    pattern = argument:match('"([^"]+)"')
                        or argument:match("'([^']+)'")
                end
                local regex
                if pattern and pattern ~= "" then
                    -- \v = very magic: makes |, +, (, ) etc. work like PCRE
                    local ok, r = pcall(vim.regex, "\\v" .. pattern)
                    if ok then
                        regex = r
                    end
                end

                if regex then
                    --- @type agentic.ui.MessageWriter.SearchMatch[]
                    local search_matches = {}
                    for i = 1, count do
                        local line = body[i]
                        local line_index = #lines - count + i - 1
                        local offset = 0
                        while offset < #line do
                            local s, e = regex:match_str(line:sub(offset + 1))
                            if not s then
                                break
                            end
                            table.insert(search_matches, {
                                line_index = line_index,
                                col_start = offset + s,
                                col_end = offset + e,
                            })
                            offset = offset + math.max(e --[[@as integer]], 1)
                        end
                    end
                    if #search_matches > 0 then
                        tool_call_block.search_matches = search_matches
                    end
                end
            end

            if use_fold then
                table.insert(lines, "}}}")
            end
            table.insert(lines, fence)
        end
    elseif tool_call_block.diff then
        local diff_blocks = ToolCallDiff.extract_diff_blocks({
            path = argument,
            old_text = tool_call_block.diff.old,
            new_text = tool_call_block.diff.new,
            replace_all = tool_call_block.diff.all,
        })

        local lang = Theme.get_language_from_path(argument)

        -- Hack to avoid triple backtick conflicts in markdown files
        local has_fences = lang ~= "md" and lang ~= "markdown"
        if has_fences then
            table.insert(lines, "```" .. lang)
        end

        for _, block in ipairs(diff_blocks) do
            local old_count = #block.old_lines
            local new_count = #block.new_lines
            local is_new_file = old_count == 0
            local is_modification = old_count == new_count and old_count > 0

            if is_new_file then
                for _, new_line in ipairs(block.new_lines) do
                    local line_index = #lines
                    table.insert(lines, new_line)

                    --- @type agentic.ui.MessageWriter.HighlightRange
                    local range = {
                        line_index = line_index,
                        type = "new",
                        old_line = nil,
                        new_line = new_line,
                    }

                    table.insert(highlight_ranges, range)
                end
            else
                local filtered = ToolCallDiff.filter_unchanged_lines(
                    block.old_lines,
                    block.new_lines
                )

                -- Insert old lines (removed content)
                for _, pair in ipairs(filtered.pairs) do
                    if pair.old_line then
                        local line_index = #lines
                        table.insert(lines, pair.old_line)

                        --- @type agentic.ui.MessageWriter.HighlightRange
                        local range = {
                            line_index = line_index,
                            type = "old",
                            old_line = pair.old_line,
                            new_line = is_modification and pair.new_line or nil,
                        }

                        table.insert(highlight_ranges, range)
                    end
                end

                -- Insert new lines (added content)
                for _, pair in ipairs(filtered.pairs) do
                    if pair.new_line then
                        local line_index = #lines
                        table.insert(lines, pair.new_line)

                        if not is_modification then
                            --- @type agentic.ui.MessageWriter.HighlightRange
                            local range = {
                                line_index = line_index,
                                type = "new",
                                old_line = nil,
                                new_line = pair.new_line,
                            }

                            table.insert(highlight_ranges, range)
                        else
                            --- @type agentic.ui.MessageWriter.HighlightRange
                            local range = {
                                line_index = line_index,
                                type = "new_modification",
                                old_line = pair.old_line,
                                new_line = pair.new_line,
                            }

                            table.insert(highlight_ranges, range)
                        end
                    end
                end
            end
        end

        -- Close code fences, if not markdown, to avoid conflicts
        if has_fences then
            table.insert(lines, "```")
        end
    elseif kind == "fetch" or kind == "WebSearch" then
        if tool_call_block.body then
            -- Fetch/WebSearch body is informational text that the agent wrote
            -- to itself. Wrap in a code fence to prevent markdown parsing
            -- artefacts and always fold since users rarely need it.
            -- `markdown` info string dims the block via AgenticDimmedBlock
            -- (priority 101, set in ftplugin/AgenticChat.lua) while keeping
            -- injected bold/underline styling.
            local fence = safe_fence(tool_call_block.body)
            table.insert(lines, fence .. "markdown")
            table.insert(lines, "{{{")
            vim.list_extend(lines, tool_call_block.body)
            table.insert(lines, "}}}")
            table.insert(lines, fence)
        end
    else
        if tool_call_block.body then
            --- @type string[]
            local body = tool_call_block.body
            local max_lines = kind == "execute"
                    and Config.tool_call_display.execute_max_lines
                or 0
            local count = #body
            local use_fold = max_lines > 0 and count > max_lines

            if use_fold then
                table.insert(lines, "{{{")
            end
            vim.list_extend(lines, body)
            if use_fold then
                table.insert(lines, "}}}")
            end
        end
    end

    -- Process ANSI escape codes in execute block body output
    --- @type agentic.utils.Ansi.Span[][]|nil
    local ansi_highlights
    if kind == "execute" and tool_call_block.body then
        local body_count = #tool_call_block.body
        -- Body lines end just before the footer ("") and optional closing fold fence
        local body_end_index = #lines -- last body line (1-indexed)
        -- Check if the last line before footer is a fold closing marker
        local has_fold_close = lines[body_end_index]
            and lines[body_end_index] == "}}}"
        if has_fold_close then
            body_end_index = body_end_index - 1 -- skip }}}
        end
        local body_start_index = body_end_index - body_count
        -- Check if a fold opening marker was inserted before body
        if body_start_index >= 1 and lines[body_start_index] == "{{{" then
            body_start_index = body_start_index -- fold marker line, body starts after
        end
        local result = Ansi.process_lines(tool_call_block.body)
        if result.has_ansi then
            for i = 1, body_count do
                lines[body_start_index + i] = result.lines[i]
            end
            ansi_highlights = {}
            for i = 1, body_count do
                ansi_highlights[i] = result.highlights[i]
            end
        end
    end

    table.insert(lines, "")

    return lines, highlight_ranges, ansi_highlights
end

--- Display permission request buttons at the end of the buffer
--- @param options agentic.acp.PermissionOption[]
--- @return integer button_start_row Start row of button block
--- @return integer button_end_row End row of button block
--- @return table<integer, string> option_mapping Mapping from number (1-N) to option_id
function MessageWriter:display_permission_buttons(tool_call_id, options)
    local option_mapping = {}

    local lines_to_append = {
        "### Allow?",
        "",
    }

    local tracker = self.tool_call_blocks[tool_call_id]

    if tracker and tracker.kind ~= "execute" then
        -- Sanitize argument to prevent newlines in the permission request, neovim throws error
        local sanitized_argument = tracker.argument:gsub("\n", "\\n")

        vim.list_extend(lines_to_append, {
            string.format(
                "%s `%s`",
                display_kind(tracker.kind),
                sanitized_argument
            ),
            "", -- Blank line prevents markdown inline markers from spanning to next content
        })
    end

    -- Insert "Reject all" before reject_always (permanent rule is stronger).
    -- Build a merged list of ACP options + our local reject-all entry.
    local merged_options = {}
    local reject_all_inserted = false
    for _, option in ipairs(options) do
        if option.kind == "reject_always" and not reject_all_inserted then
            table.insert(merged_options, {
                kind = "__reject_all__",
                name = "Reject all",
                optionId = "__reject_all__",
            })
            reject_all_inserted = true
        end
        table.insert(merged_options, option)
    end
    if not reject_all_inserted then
        table.insert(merged_options, {
            kind = "__reject_all__",
            name = "Reject all",
            optionId = "__reject_all__",
        })
    end

    for i, option in ipairs(merged_options) do
        table.insert(
            lines_to_append,
            string.format(
                "%d. %s %s",
                i,
                Config.permission_icons[option.kind] or "",
                option.name
            )
        )
        option_mapping[i] = option.optionId
    end

    table.insert(lines_to_append, "--- ---")

    local hint_line_index =
        DiffPreview.add_navigation_hint(tracker, lines_to_append)

    table.insert(lines_to_append, "")

    -- Ensure exactly one empty separator line before the permission block.
    -- During reanchor, remove_permission_buttons leaves a trailing empty
    -- line — reuse it instead of adding another one.
    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    local last_line = vim.api.nvim_buf_get_lines(
        self.bufnr,
        line_count - 1,
        line_count,
        false
    )[1]

    if last_line == "" then
        -- Buffer already ends with an empty line (left by
        -- remove_permission_buttons during reanchor). Reuse it as
        -- separator — include it in the block range so it gets
        -- cleaned up, but don't add another one.
        line_count = line_count - 1
    else
        -- No trailing empty line — prepend one as separator
        table.insert(lines_to_append, 1, "")
    end

    -- The separator line shifts hint position by 1 in both cases:
    -- existing empty line included in block range, or prepended empty line.
    if hint_line_index then
        hint_line_index = hint_line_index + 1
    end

    local button_start_row = line_count

    self:_auto_scroll(self.bufnr)

    BufHelpers.with_modifiable(self.bufnr, function()
        self:_append_lines(lines_to_append)
    end)

    local button_end_row = vim.api.nvim_buf_line_count(self.bufnr) - 1

    if hint_line_index then
        DiffPreview.apply_hint_styling(
            self.bufnr,
            NS_PERMISSION_BUTTONS,
            button_start_row,
            hint_line_index
        )
    end

    -- Apply syntax highlighting to the tool call header line within the permission block
    if tracker then
        for row = button_start_row, button_end_row do
            local row_line =
                vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1]
            if
                row_line
                and (
                    row_line:find("^%a[%a_]*[(`]")
                    or row_line:find("^%a[%a_]*%s*$")
                )
            then
                self:_apply_tool_header_syntax(row, NS_PERMISSION_BUTTONS)
                break
            end
        end
    end

    -- Create extmark to track button block
    vim.api.nvim_buf_set_extmark(
        self.bufnr,
        NS_PERMISSION_BUTTONS,
        button_start_row,
        0,
        {
            end_row = button_end_row,
            right_gravity = false,
        }
    )

    return button_start_row, button_end_row, option_mapping
end

--- Remove permission buttons by finding their extmark position.
--- Falls back to no-op if the extmark is missing (already removed).
function MessageWriter:remove_permission_buttons()
    local extmarks = vim.api.nvim_buf_get_extmarks(
        self.bufnr,
        NS_PERMISSION_BUTTONS,
        0,
        -1,
        { details = true }
    )

    -- Find the range extmark (has end_row)
    local start_row, end_row
    for _, mark in ipairs(extmarks) do
        local details = mark[4]
        if details.end_row then
            start_row = mark[2]
            end_row = details.end_row
            break
        end
    end

    if not start_row then
        return
    end

    vim.api.nvim_buf_clear_namespace(self.bufnr, NS_PERMISSION_BUTTONS, 0, -1)

    BufHelpers.with_modifiable(self.bufnr, function(bufnr)
        pcall(
            vim.api.nvim_buf_set_lines,
            bufnr,
            start_row,
            end_row + 1,
            false,
            {
                "", -- a leading as separator from previous content
            }
        )
    end)
end

--- Apply highlights to block content (either diff highlights or Comment for non-edit blocks)
--- @param bufnr integer
--- @param start_row integer Header line number
--- @param end_row integer Footer line number
--- @param kind string Tool call kind
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[] Diff highlight ranges
--- @param ansi_highlights? agentic.utils.Ansi.Span[][] Per-line ANSI highlight spans
--- @param search_matches? agentic.ui.MessageWriter.SearchMatch[] Search pattern match positions
--- @param search_ansi? agentic.utils.Ansi.Span[][] ANSI highlights for search body
function MessageWriter:_apply_block_highlights(
    bufnr,
    start_row,
    end_row,
    kind,
    highlight_ranges,
    ansi_highlights,
    search_matches,
    search_ansi
)
    if #highlight_ranges > 0 then
        self:_apply_diff_highlights(start_row, highlight_ranges)
    elseif kind ~= "edit" and kind ~= "switch_mode" then
        -- Execute and search blocks have a code fence after the header that
        -- gets treesitter injection from the markdown parser — skip those lines.
        local body_start = start_row + 1
        if kind == "execute" or kind == "search" then
            -- Find the closing ``` to skip the command code fence
            for i = start_row + 2, end_row - 1 do
                local l = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
                if l == "```" then
                    body_start = i + 1
                    break
                end
            end
        end

        -- Execute blocks with ANSI codes get per-character colour highlights
        if ansi_highlights then
            Ansi.apply_highlights(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                body_start,
                ansi_highlights
            )
            return
        end

        -- Apply Comment highlight for body lines outside code fences.
        -- Content inside ```markdown fences is dimmed by treesitter via
        -- AgenticDimmedBlock (ftplugin/AgenticChat.lua). Other fences
        -- (zsh, console) keep their injected syntax highlights.
        local in_fence = false
        for line_idx = body_start, end_row - 1 do
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                line_idx,
                line_idx + 1,
                false
            )[1]
            if line and vim.startswith(line, "`") then
                in_fence = not in_fence
            elseif not in_fence and line and #line > 0 then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_DIFF_HIGHLIGHTS,
                    line_idx,
                    0,
                    {
                        end_col = #line,
                        hl_group = "Comment",
                    }
                )
            end
        end
    end

    -- Apply search highlights on top of Comment (higher priority).
    -- Prefer ANSI colours from grep --color output; fall back to regex matches.
    if search_ansi then
        -- Find the ```console fence that starts the search body
        -- (after the header and ```bash command code fence).
        local body_start = start_row + 2
        for i = start_row + 1, end_row - 1 do
            local l = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
            if l and l:match("^`+console$") then
                body_start = i + 1
                break
            end
        end
        Ansi.apply_highlights(
            bufnr,
            NS_DIFF_HIGHLIGHTS,
            body_start,
            search_ansi
        )
    elseif search_matches then
        for _, match in ipairs(search_matches) do
            vim.api.nvim_buf_set_extmark(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                start_row + match.line_index,
                match.col_start,
                {
                    end_col = match.col_end,
                    hl_group = "AgenticSearchMatch",
                    priority = 200,
                }
            )
        end
    end

    -- Conceal fold markers ({{{ and }}}) embedded in code fence lines.
    -- Treesitter is active on the chat buffer so vim syntax conceal rules
    -- don't apply; extmark conceal works alongside treesitter.
    for line_idx = start_row, end_row - 1 do
        local line =
            vim.api.nvim_buf_get_lines(bufnr, line_idx, line_idx + 1, false)[1]
        if line then
            local col = line:find("{{{", 1, true)
            if col then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_DECORATIONS,
                    line_idx,
                    col - 1,
                    {
                        end_col = col + 2,
                        conceal = "",
                    }
                )
            end
            col = line:find("}}}", 1, true)
            if col then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_DECORATIONS,
                    line_idx,
                    col - 1,
                    {
                        end_col = col + 2,
                        conceal = "",
                    }
                )
            end
        end
    end
end

--- @param start_row integer
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
function MessageWriter:_apply_diff_highlights(start_row, highlight_ranges)
    if not highlight_ranges or #highlight_ranges == 0 then
        return
    end

    for _, hl_range in ipairs(highlight_ranges) do
        local buffer_line = start_row + hl_range.line_index

        if hl_range.type == "old" then
            DiffHighlighter.apply_diff_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        elseif hl_range.type == "new" then
            DiffHighlighter.apply_diff_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                nil,
                hl_range.new_line
            )
        elseif hl_range.type == "new_modification" then
            DiffHighlighter.apply_new_line_word_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        elseif hl_range.type == "comment" then
            local line = vim.api.nvim_buf_get_lines(
                self.bufnr,
                buffer_line,
                buffer_line + 1,
                false
            )[1]

            if line then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    NS_DIFF_HIGHLIGHTS,
                    buffer_line,
                    0,
                    {
                        end_col = #line,
                        hl_group = "Comment",
                    }
                )
            end
        end
    end
end

--- Apply syntax highlighting to a tool call header line.
--- Handles formats:
---   " kind `argument` " — highlights kind with TOOL_KIND, argument with TOOL_ARGUMENT
---   " kind "            — highlights kind with TOOL_KIND only (e.g. execute, rendered as code fence)
--- @param line_row integer 0-indexed row
--- @param ns integer Namespace to use for extmarks
function MessageWriter:_apply_tool_header_syntax(line_row, ns)
    local line =
        vim.api.nvim_buf_get_lines(self.bufnr, line_row, line_row + 1, false)[1]
    if not line then
        return
    end

    -- Match header formats:
    --   "kind(argument) "    → kind + argument (legacy)
    --   "kind `argument` "   → kind + argument (backtick-wrapped)
    --   "kind "              → kind only
    local kind_str, arg_str, arg_col

    -- "kind(argument) "
    local _, _, k, a = line:find("^(%a[%a_]*)%((.-)%)%s*$")
    if k then
        kind_str, arg_str = k, a
        arg_col = #k + 1 -- kind + "("
    end

    -- "kind `argument` "
    if not kind_str then
        local bt_start = line:find("`")
        if bt_start then
            local bt_end = line:find("`", bt_start + 1)
            if bt_end then
                kind_str = line:sub(1, bt_start - 2) -- strip trailing space before backtick
                arg_str = line:sub(bt_start + 1, bt_end - 1)
                arg_col = bt_start -- 0-indexed = bt_start (1-indexed) - 1 + 1 (after `)
            end
        end
    end

    -- "kind " (no argument)
    if not kind_str then
        _, _, kind_str = line:find("^(%a[%a_]*)%s*$")
    end

    if not kind_str then
        return
    end

    local kind_col = 0
    local kind_col_end = #kind_str

    vim.api.nvim_buf_set_extmark(self.bufnr, ns, line_row, kind_col, {
        end_col = kind_col_end,
        hl_group = Theme.HL_GROUPS.TOOL_KIND,
        priority = 200,
    })

    if arg_str and #arg_str > 0 then
        local arg_col_end = arg_col + #arg_str

        vim.api.nvim_buf_set_extmark(self.bufnr, ns, line_row, arg_col, {
            end_col = arg_col_end,
            hl_group = Theme.HL_GROUPS.TOOL_ARGUMENT,
            priority = 200,
        })
    end
end

--- Write status text directly into the footer buffer line and apply highlight.
--- Uses set_text (not set_lines) so sign_text extmarks on the footer line
--- are not shifted — set_lines replaces the line, displacing extmarks.
--- @param footer_line integer 0-indexed footer line number
--- @param status string Status value (pending, completed, etc.)
function MessageWriter:_apply_status_footer(footer_line, status)
    if
        not vim.api.nvim_buf_is_valid(self.bufnr)
        or not status
        or status == ""
    then
        return
    end

    local icons = Config.status_icons or {}
    local icon = icons[status] or ""
    local status_text = string.format(" %s %s ", icon, status)
    local hl_group = Theme.get_status_hl_group(status)

    local current = vim.api.nvim_buf_get_lines(
        self.bufnr,
        footer_line,
        footer_line + 1,
        false
    )[1] or ""

    vim.api.nvim_buf_set_text(
        self.bufnr,
        footer_line,
        0,
        footer_line,
        #current,
        { status_text }
    )

    vim.api.nvim_buf_set_extmark(self.bufnr, NS_STATUS, footer_line, 0, {
        end_col = #status_text,
        hl_group = hl_group,
    })
end

--- @param ids integer[]|nil
function MessageWriter:_clear_decoration_extmarks(ids)
    if not ids then
        return
    end

    for _, id in ipairs(ids) do
        pcall(vim.api.nvim_buf_del_extmark, self.bufnr, NS_DECORATIONS, id)
    end
end

--- @param start_row integer
--- @param end_row integer
--- @return integer[] decoration_extmark_ids
function MessageWriter:_render_decorations(start_row, end_row)
    return ExtmarkBlock.render_block(self.bufnr, NS_DECORATIONS, {
        header_line = start_row,
        body_start = start_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

--- @param start_row integer
--- @param end_row integer
function MessageWriter:_clear_status_namespace(start_row, end_row)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_STATUS,
        start_row,
        end_row + 1
    )
end

return MessageWriter
