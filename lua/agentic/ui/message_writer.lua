local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local Logger = require("agentic.utils.logger")
local Renderer = require("agentic.ui.tool_call_renderer")
local TextWrap = require("agentic.utils.text_wrap")
local Theme = require("agentic.theme")

local NS_PERMISSION_BUTTONS =
    vim.api.nvim_create_namespace("agentic_permission_buttons")
local NS_ERROR = vim.api.nvim_create_namespace("agentic_error")

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"old"|"new"|"new_modification" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)

--- @class agentic.ui.MessageWriter.SearchMatch
--- @field line_index integer Line index relative to block lines (0-based)
--- @field col_start integer Start column (byte offset)
--- @field col_end integer End column (byte offset)
--- @field hl_group? string Highlight group override (default: AgenticSearchMatch)

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
--- @field read_range? { offset: integer, limit?: integer } Line range for partial reads

--- @class agentic.ui.MessageWriter.ToolCallBlock : agentic.ui.MessageWriter.ToolCallBase
--- @field kind agentic.acp.ToolKind
--- @field argument string
--- @field extmark_id? integer Range extmark spanning the block
--- @field decoration_extmark_ids? integer[] IDs of decoration extmarks from ExtmarkBlock
--- @field search_matches? agentic.ui.MessageWriter.SearchMatch[] Pattern match positions (relative to block lines)
--- @field search_ansi? agentic.utils.Ansi.Span[][] ANSI highlight spans for search body
--- @field diff_tab? integer Tabpage ID of the diff preview tab (set by SessionManager)

--- Known prefix of the rejection boilerplate injected by the provider after
--- a permission denial. Streamed as agent_message_chunk but meant for the
--- model, not the user.
local REJECTION_PREFIX = "The user doesn't want to proceed"

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field _last_message_type? string
--- @field _should_auto_scroll? boolean
--- @field _scroll_scheduled? boolean
--- @field _on_content_changed? fun()

--- @field _suppressing_rejection boolean When true, buffering chunks to detect rejection boilerplate
--- @field _rejection_buffer string Accumulated text while detecting rejection
--- @field _status_animation? agentic.ui.StatusAnimation Reference for auto-scroll virt_lines awareness
local MessageWriter = {}
MessageWriter.__index = MessageWriter

--- @param bufnr integer
--- @param status_animation? agentic.ui.StatusAnimation
--- @return agentic.ui.MessageWriter
function MessageWriter:new(bufnr, status_animation)
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
        _suppressing_rejection = false,
        _rejection_buffer = "",
        _status_animation = status_animation,
    }, self)

    return instance
end

--- Start buffering the next message chunks to detect and suppress the
--- rejection boilerplate that the provider injects after permission denial.
function MessageWriter:suppress_next_rejection()
    self._suppressing_rejection = true
    self._rejection_buffer = ""
end

--- Reset all per-turn mutable state. Called by refresh to unstick a
--- desynchronised display without restarting the session.
function MessageWriter:reset_turn_state()
    self._suppressing_rejection = false
    self._rejection_buffer = ""
    self._last_wrote_tool_call = false
    self._last_message_type = nil
    self._chunk_start_line = nil
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
--- Capped by `Config.windows.max_wrap_width` when set.
--- Returns 0 when the chat window has soft wrap enabled (no hard wrapping needed).
--- @return integer
function MessageWriter:_get_wrap_width()
    local winid = vim.fn.bufwinid(self.bufnr)
    if winid ~= -1 and vim.wo[winid].wrap then
        return 0
    end
    local win_width
    if winid ~= -1 then
        win_width = vim.api.nvim_win_get_width(winid) - 2
    else
        win_width = 80
    end
    local max = Config.windows.max_wrap_width
    if max and max > 0 then
        return math.min(win_width, max)
    end
    return win_width
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

--- Hints for known API error types.
--- authentication_error is handled by the caller (provider-specific re-auth flow).
--- @type table<string, string>
local error_hints = {
    overloaded_error = "The API is overloaded. Try again in a moment.",
    rate_limit_error = "Rate limited. Wait a moment before retrying.",
}

--- Parse a reset time like "5pm (Europe/London)" or "17:30 (Europe/London)"
--- into epoch seconds. Returns nil if parsing fails.
--- @param time_str string e.g. "5pm", "5:30pm", "17:00"
--- @param tz string e.g. "Europe/London"
--- @return number|nil epoch
local function parse_reset_time(time_str, tz)
    -- Use GNU date to parse the time in the given timezone
    local cmd =
        string.format("TZ=%s date -d 'today %s' +%%s 2>/dev/null", tz, time_str)
    local result = vim.fn.system(cmd)
    local epoch = tonumber(vim.trim(result))
    if not epoch then
        return nil
    end
    -- If the parsed time is in the past, it means tomorrow
    if epoch <= os.time() then
        epoch = epoch + 86400
    end
    return epoch
end

--- Format an ACP error into human-readable lines.
--- Parses embedded JSON in the message to extract the meaningful error type
--- and description, rather than dumping the raw Lua table.
---
--- Example input message:
---   "Internal error: Failed to authenticate. API Error: 401\n
---    {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",
---    \"message\":\"Invalid authentication credentials\"}}"
--- Output: {"401 Invalid authentication credentials", "", "Try running /login ..."}
--- @param err agentic.acp.ACPError
--- @return string[] lines
--- @return string|nil error_type Parsed API error type (e.g. "authentication_error")
--- @return number|nil reset_epoch Epoch seconds when usage resets (for usage_limit errors)
local function format_error_lines(err)
    local lines = {}
    local msg = err.message or "Unknown error"

    -- Try to extract embedded JSON from messages like:
    -- 'Internal error: API Error: 529\n{"type":"error","error":{"type":"overloaded_error","message":"Overloaded."}}'
    local json_str = msg:match("%b{}")
    if json_str then
        local ok, parsed = pcall(vim.json.decode, json_str)
        if ok and type(parsed) == "table" then
            local inner = parsed.error or parsed
            local error_type = inner.type or ""
            local error_msg = inner.message or ""

            -- Extract HTTP status code from prefix (e.g. "API Error: 401")
            local prefix = msg:sub(1, msg:find("{", 1, true) - 1)
            local http_code = prefix:match("(%d%d%d)%s*$")

            -- Build the main error line: "401 Invalid authentication credentials"
            -- or just the message if no HTTP code is available
            if http_code and error_msg ~= "" then
                table.insert(lines, http_code .. " " .. error_msg)
            elseif error_msg ~= "" then
                table.insert(lines, error_msg)
            elseif error_type ~= "" then
                local readable = error_type:gsub("_", " ")
                readable = readable:sub(1, 1):upper() .. readable:sub(2)
                table.insert(lines, readable)
            end

            local hint = error_hints[error_type]
            if hint then
                table.insert(lines, "")
                table.insert(lines, hint)
            end

            local resolved_type = error_type ~= "" and error_type or nil
            return lines, resolved_type
        end
    end

    -- Detect usage limit errors: "You're out of extra usage · resets 5pm (Europe/London)"
    local time_str, tz = msg:match("resets%s+(%d+:?%d*%s*[ap]m)%s+%(([%w/]+)%)")
    if not time_str then
        -- Try 24h format: "resets 17:00 (Europe/London)"
        time_str, tz = msg:match("resets%s+(%d+:%d+)%s+%(([%w/]+)%)")
    end
    if time_str then
        vim.list_extend(lines, vim.split(msg, "\n", { plain = true }))
        local reset_epoch = parse_reset_time(time_str, tz)
        return lines, "usage_limit", reset_epoch
    end

    -- Fallback: just use the raw message, split on newlines
    vim.list_extend(lines, vim.split(msg, "\n", { plain = true }))
    return lines, nil
end

local HEADING = "### Error"
local HEADING_PREFIX_LEN = #"### "

--- Write an error message to the chat buffer with red error highlighting.
--- Uses `### Error` heading (same pattern as tool call headers) so markdown
--- treesitter renders the `###` as heading punctuation.
--- @param err agentic.acp.ACPError
--- @return string|nil error_type Parsed API error type for caller to act on
--- @return number|nil reset_epoch Epoch seconds when usage resets (for usage_limit errors)
function MessageWriter:write_error_message(err)
    local body_lines, error_type, reset_epoch = format_error_lines(err)
    local all_lines = { HEADING, "" }
    vim.list_extend(all_lines, body_lines)

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        local was_empty = BufHelpers.is_buffer_empty(bufnr)
        self:_append_lines(all_lines)

        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1
        local start_row = end_row - #all_lines + 1
        -- When the buffer was empty, _append_lines replaces instead of
        -- appending, so the heading is at row 0.
        if was_empty then
            start_row = 0
        end

        -- Highlight "Error" portion of "### Error" (after "### ")
        vim.api.nvim_buf_set_extmark(
            bufnr,
            NS_ERROR,
            start_row,
            HEADING_PREFIX_LEN,
            {
                end_col = #HEADING,
                hl_group = Theme.HL_GROUPS.ERROR_HEADING,
                priority = 200,
            }
        )

        -- Highlight body lines (skip the blank separator at start_row + 1)
        for i = start_row + 2, end_row do
            local line = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
            if line and line ~= "" then
                vim.api.nvim_buf_set_extmark(bufnr, NS_ERROR, i, 0, {
                    end_col = #line,
                    hl_group = Theme.HL_GROUPS.ERROR_BODY,
                })
            end
        end

        self:_append_lines({ "" })
    end)

    return error_type, reset_epoch
end

--- Write an action hint line after an error, styled with ERROR_BODY highlight.
--- @param text string The action hint text (e.g. "Press [r] to re-authenticate")
function MessageWriter:write_error_action(text)
    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        self:_append_lines({ text, "" })

        local row = vim.api.nvim_buf_line_count(bufnr) - 2
        vim.api.nvim_buf_set_extmark(bufnr, NS_ERROR, row, 0, {
            end_col = #text,
            hl_group = Theme.HL_GROUPS.ERROR_BODY,
        })
    end)
end

--- Append trailing blank lines to separate from the next message.
--- If streamed chunks preceded this call, reflow their prose first.
function MessageWriter:append_separator()
    -- Reset ALL per-turn state at the turn boundary. Any flag that was set
    -- during the turn must be cleared here, otherwise it silently corrupts
    -- subsequent turns (the "stuck 1 message behind" family of bugs).
    self._suppressing_rejection = false
    self._rejection_buffer = ""
    self._last_wrote_tool_call = false
    self._last_message_type = nil

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
        -- Nothing to reflow, but still clear the marker on flush so the
        -- next turn recalculates from scratch. Without this, the stale
        -- _chunk_start_line carries over and corrupts the next turn's reflow.
        if flush_all then
            self._chunk_start_line = nil
        end
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

    -- After a permission rejection, the provider streams boilerplate
    -- instructions meant for the model ("The user doesn't want to proceed…").
    -- Buffer incoming chunks and check for the known prefix. Once we have
    -- enough text: if it matches, suppress the whole paragraph; if not, flush
    -- the buffer and continue rendering normally.
    if self._suppressing_rejection then
        self._rejection_buffer = self._rejection_buffer .. text
        local buf = self._rejection_buffer

        -- Still accumulating — not enough text to decide yet
        if #buf < #REJECTION_PREFIX then
            -- Check that what we have so far could still match
            if REJECTION_PREFIX:sub(1, #buf) == buf then
                return
            end
            -- Mismatch — not rejection text, flush below
        elseif buf:sub(1, #REJECTION_PREFIX) == REJECTION_PREFIX then
            -- Confirmed rejection boilerplate — suppress entirely.
            -- Keep _suppressing_rejection true to drop remaining chunks
            -- of this paragraph. Reset on next tool call via
            -- write_tool_call_block.
            return
        end

        -- Not rejection text — stop suppressing and flush the buffer
        self._suppressing_rejection = false
        text = self._rejection_buffer
        self._rejection_buffer = ""
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

        -- Guard against two messages being concatenated with no whitespace
        -- (e.g. auto-compaction text followed by resumed response). Normal
        -- streaming tokens include leading whitespace at word boundaries, so
        -- an uppercase letter directly after a lowercase letter, digit, or
        -- sentence-ending punctuation means the provider spliced two separate
        -- messages together. Uppercase after uppercase is left alone to avoid
        -- splitting abbreviations like "CWD" streamed as "C" + "WD".
        if
            start_col > 0
            and current_line:sub(-1):match("[%l%d%.%!%?%)\"']")
            and text:sub(1, 1):match("%u")
        then
            text = " " .. text
        end

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
            Logger.notify(
                "Failed to write message chunk:\n" .. tostring(err),
                vim.log.levels.ERROR,
                { title = "Agentic buffer write error" }
            )
        end

        -- Wrap the last line immediately if it overflows, so the user sees
        -- wrapping during streaming instead of after the line completes.
        -- Skip when wrap_width is 0 (soft wrap enabled on the window).
        local wrap_width = self:_get_wrap_width()
        local end_line = vim.api.nvim_buf_line_count(bufnr) - 1
        local tail = vim.api.nvim_buf_get_lines(
            bufnr,
            end_line,
            end_line + 1,
            false
        )[1] or ""
        if wrap_width > 0 and #tail > wrap_width then
            local wrapped = TextWrap.wrap_single_line(tail, wrap_width)
            if #wrapped > 1 then
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    end_line,
                    end_line + 1,
                    false,
                    wrapped
                )
            end
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
        Logger.notify(
            "Failed to append lines to buffer:\n" .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic buffer write error" }
        )
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

--- Whether the cursor is near the bottom of the chat buffer.
--- Public wrapper for the threshold check used by auto-scroll.
--- @return boolean
function MessageWriter:is_near_bottom()
    return self:_check_auto_scroll(self.bufnr)
end

--- Scroll the chat window to the bottom if the cursor is near the end.
--- Respects the same proximity threshold as streaming auto-scroll so that
--- users reading earlier content are not interrupted.
function MessageWriter:scroll_to_bottom()
    if not self:_check_auto_scroll(self.bufnr) then
        return
    end

    local wins = vim.fn.win_findbuf(self.bufnr)
    if #wins == 0 then
        return
    end

    BufHelpers.scroll_down_only(wins[1])
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
                    local has_virt_lines = self._status_animation
                        and self._status_animation:is_active()
                    BufHelpers.scroll_down_only(wins[1], has_virt_lines)
                end
            end
        end

        self._should_auto_scroll = nil
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:write_tool_call_block(tool_call_block)
    -- A new tool call means any rejection boilerplate is over
    if self._suppressing_rejection then
        self._suppressing_rejection = false
        self._rejection_buffer = ""
    end

    -- Mode-switch tool calls (EnterPlanMode, ExitPlanMode, EnterWorktree)
    -- carry internal instructions in their body — strip it so only the
    -- compact header renders (e.g. "Switch Mode `EnterPlanMode`").
    if tool_call_block.kind == "switch_mode" then
        tool_call_block.body = nil
    end

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        -- Flush any pending prose reflow before writing the tool call block.
        -- Without this, append_separator's _reflow_chunks would later process
        -- a range that includes these tool call lines, destroying extmarks
        -- (decorations, status, range tracking) via nvim_buf_set_lines.
        self:_reflow_chunks(bufnr, true)

        local kind = tool_call_block.kind

        local lines, highlight_ranges, ansi_highlights =
            Renderer.prepare_block_lines(
                tool_call_block,
                self:_get_wrap_width()
            )

        self:_append_lines(lines)

        -- Compute start/end AFTER _append_lines: when the buffer was empty,
        -- _append_lines replaces instead of appending, so line_count before
        -- the call would over-count by 1.
        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1
        local start_row = end_row - #lines + 1

        Renderer.apply_block_highlights(
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
            Renderer.render_decorations(bufnr, start_row, end_row)

        tool_call_block.extmark_id = vim.api.nvim_buf_set_extmark(
            bufnr,
            Renderer.NS_TOOL_BLOCKS,
            start_row,
            0,
            {
                end_row = end_row,
                right_gravity = false,
                end_right_gravity = false,
            }
        )

        self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block

        Renderer.apply_tool_header_syntax(bufnr, start_row, Renderer.NS_STATUS)
        Renderer.apply_status_footer(bufnr, end_row, tool_call_block.status)

        self:_append_lines({ "" })
        self._last_wrote_tool_call = true
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBase
function MessageWriter:update_tool_call_block(tool_call_block)
    local tracker = self.tool_call_blocks[tool_call_block.tool_call_id]

    if not tracker then
        Logger.notify(
            "Tool call update for unknown block: "
                .. tostring(tool_call_block.tool_call_id),
            vim.log.levels.WARN,
            { title = "Agentic sync: missing tracker" }
        )
        return
    end

    -- Strip internal instructions from switch_mode updates
    if tracker.kind == "switch_mode" then
        tool_call_block.body = nil
    end

    -- For read blocks, extract range from the current argument before the merge
    -- overwrites it — the initial title may contain "(N - M)" that the adapter
    -- update replaces with just the file path.
    if tracker.kind == "read" and not tracker.read_range then
        local _, range = Renderer.parse_read_range(tracker.argument)
        if range then
            tracker.read_range = range
        end
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
        Renderer.NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        Logger.notify(
            "Tool call extmark lost: " .. tostring(tracker.tool_call_id),
            vim.log.levels.WARN,
            { title = "Agentic sync: extmark lost" }
        )
        return
    end

    local start_row = pos[1]
    local details = pos[3]
    local old_end_row = details and details.end_row

    if not old_end_row then
        Logger.notify(
            "Tool call extmark has no end_row: "
                .. tostring(tracker.tool_call_id),
            vim.log.levels.WARN,
            { title = "Agentic sync: extmark corrupt" }
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
                Logger.notify(
                    string.format(
                        "Tool call footer out of bounds: row %d, buf has %d lines",
                        old_end_row,
                        vim.api.nvim_buf_line_count(bufnr)
                    ),
                    vim.log.levels.WARN,
                    { title = "Agentic sync: footer OOB" }
                )
                return false
            end

            -- Decorations (╭│╰ borders) are stable — leave them in place.
            -- Only refresh status footer which changes on completion.
            Renderer.apply_status_footer(bufnr, old_end_row, tracker.status)

            return false
        end

        local new_lines, highlight_ranges, ansi_highlights =
            Renderer.prepare_block_lines(tracker, self:_get_wrap_width())

        -- Compare content lines excluding the footer — the buffer's footer
        -- has status text while prepare_block_lines produces "" for it.
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
            Renderer.apply_status_footer(bufnr, old_end_row, tracker.status)
            return false
        end

        Renderer.clear_decoration_extmarks(
            bufnr,
            tracker.decoration_extmark_ids
        )
        Renderer.clear_status_namespace(bufnr, start_row, old_end_row)

        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row,
            old_end_row + 1,
            false,
            new_lines
        )

        local new_end_row = start_row + #new_lines - 1

        -- Adjust _chunk_start_line for the line count change so that
        -- _reflow_chunks does not accidentally process tool call block
        -- lines after the block expands (e.g. diff data arriving late).
        local line_delta = new_end_row - old_end_row
        if line_delta ~= 0 and self._chunk_start_line then
            if self._chunk_start_line > old_end_row then
                self._chunk_start_line = self._chunk_start_line + line_delta
            elseif self._chunk_start_line > start_row then
                -- Chunk start was inside the old block range — push it
                -- past the new block so reflow never touches block lines.
                self._chunk_start_line = new_end_row + 1
            end
        end

        pcall(
            vim.api.nvim_buf_clear_namespace,
            bufnr,
            Renderer.NS_DIFF_HIGHLIGHTS,
            start_row,
            old_end_row + 1
        )

        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                Renderer.apply_block_highlights(
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

        vim.api.nvim_buf_set_extmark(
            bufnr,
            Renderer.NS_TOOL_BLOCKS,
            start_row,
            0,
            {
                id = tracker.extmark_id,
                end_row = new_end_row,
                right_gravity = false,
                end_right_gravity = false,
            }
        )

        tracker.decoration_extmark_ids =
            Renderer.render_decorations(bufnr, start_row, new_end_row)

        Renderer.apply_tool_header_syntax(bufnr, start_row, Renderer.NS_STATUS)
        Renderer.apply_status_footer(bufnr, new_end_row, tracker.status)
    end)
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
        local sanitized_argument =
            Renderer.strip_kind_prefix(tracker.kind, tracker.argument)
                :gsub("\n", "\\n")

        vim.list_extend(lines_to_append, {
            string.format("### %s", Renderer.display_kind(tracker.kind)),
            string.format("`%s`", sanitized_argument),
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

    local permission_keys = Config.keymaps.permission or {}

    for i, option in ipairs(merged_options) do
        local key_label = permission_keys[i] or tostring(i)
        table.insert(
            lines_to_append,
            string.format(
                "%s. %s %s",
                key_label,
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
            if row_line and row_line:find("^### %a") then
                Renderer.apply_tool_header_syntax(
                    self.bufnr,
                    row,
                    NS_PERMISSION_BUTTONS
                )
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

--- @private
--- @param err agentic.acp.ACPError
--- @return string[] lines
--- @return string|nil error_type
--- @return number|nil reset_epoch
function MessageWriter._format_error_lines(err)
    return format_error_lines(err)
end

--- @private
--- @param time_str string
--- @param tz string
--- @return number|nil epoch
function MessageWriter._parse_reset_time(time_str, tz)
    return parse_reset_time(time_str, tz)
end

return MessageWriter
