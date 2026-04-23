local ToolCallDiff = require("agentic.ui.tool_call_diff")
local Ansi = require("agentic.utils.ansi")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local FileSystem = require("agentic.utils.file_system")
local TextWrap = require("agentic.utils.text_wrap")
local Theme = require("agentic.theme")
local Treesitter = require("agentic.utils.treesitter")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DECORATIONS = vim.api.nvim_create_namespace("agentic_tool_decorations")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")
local NS_STATUS = vim.api.nvim_create_namespace("agentic_status_footer")

--- @class agentic.ui.ToolCallRenderer
local M = {}

M.NS_TOOL_BLOCKS = NS_TOOL_BLOCKS
M.NS_DECORATIONS = NS_DECORATIONS
M.NS_DIFF_HIGHLIGHTS = NS_DIFF_HIGHLIGHTS
M.NS_STATUS = NS_STATUS

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------

--- Format a tool kind for display: capitalise each word, replace underscores with spaces.
--- Leaves already-capitalised kinds (WebSearch, SubAgent, etc.) unchanged.
--- @param kind string
--- @return string
function M.display_kind(kind)
    local result = kind:gsub("(%a)([%a]*)", function(first, rest)
        return first:upper() .. rest
    end):gsub("_", " ")
    return result
end

--- Strip redundant kind prefix from an argument string.
--- The header already shows the kind, so "Read filename.txt" → "filename.txt".
--- @param kind string ACP tool kind
--- @param argument string|nil
--- @return string
function M.strip_kind_prefix(kind, argument)
    if not argument or argument == "" then
        return ""
    end
    local display = M.display_kind(kind)
    if argument:sub(1, #display + 1):lower() == display:lower() .. " " then
        return argument:sub(#display + 2)
    end
    return argument
end

--- Parse a trailing "(N - M)" range suffix from a read argument string.
--- Returns the cleaned path and a range table, or nil if no range is present.
--- @param argument string e.g. "file.lua (10 - 50)"
--- @return string|nil path Argument without the range suffix
--- @return { offset: integer, limit: integer }|nil range
function M.parse_read_range(argument)
    local path, a, b = argument:match("^(.-)%s*%((%d+)%s*%-%s*(%d+)%)%s*$")
    if not path then
        return nil, nil
    end
    local na = tonumber(a) --[[@as integer]]
    local nb = tonumber(b) --[[@as integer]]
    return path, { offset = na, limit = nb - na + 1 }
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

--- Check if a command string starts with a grep-family tool.
--- Handles leading env vars (VAR=val) and common pipe patterns.
--- @param argument string Shell command string
--- @return boolean
local function is_grep_command(argument)
    -- Strip leading env var assignments (e.g. "LANG=C grep ...")
    local cmd = argument:gsub("^%s*[%w_]+=[^%s]*%s+", "")
    -- Extract first word
    local first = cmd:match("^%s*(%S+)")
    if not first then
        return false
    end
    -- Check grep-family tools
    if
        first == "grep"
        or first == "rg"
        or first == "ag"
        or first == "ack"
        or first == "ugrep"
    then
        return true
    end
    -- "git grep"
    if first == "git" then
        local second = cmd:match("^%s*git%s+(%S+)")
        if second == "grep" then
            return true
        end
    end
    return false
end

--- Match a search pattern against body lines and return SearchMatch entries.
--- Extracts the pattern from a command argument's first quoted string if not
--- provided explicitly. Uses vim's \v (very magic) mode for PCRE-like matching.
--- @param body string[] Raw body lines
--- @param line_index_offset integer Offset added to each line_index
--- @param pattern string|nil Explicit search pattern (falls back to argument extraction)
--- @param argument string|nil Command string to extract pattern from
--- @return agentic.ui.MessageWriter.SearchMatch[]
local function extract_search_term_highlights(
    body,
    line_index_offset,
    pattern,
    argument
)
    if not pattern and argument then
        pattern = argument:match('"([^"]+)"') or argument:match("'([^']+)'")
    end
    if not pattern or pattern == "" then
        return {}
    end

    local ok, regex = pcall(vim.regex, "\\v" .. pattern)
    if not ok then
        return {}
    end

    --- @type agentic.ui.MessageWriter.SearchMatch[]
    local matches = {}
    for i, line in ipairs(body) do
        local idx = line_index_offset + i - 1
        local offset = 0
        while offset < #line do
            local s, e = regex:match_str(line:sub(offset + 1))
            if not s then
                break
            end
            table.insert(matches, {
                line_index = idx,
                col_start = offset + s,
                col_end = offset + e,
            })
            offset = offset + math.max(e --[[@as integer]], 1)
        end
    end
    return matches
end

--- Parse grep-format lines (path:linenum: or path:linenum-) and return
--- SearchMatch entries for the path, line number, and separator characters.
--- @param body string[] Raw body lines
--- @param line_index_offset integer Offset added to each line_index (accounts for fences/headers)
--- @return agentic.ui.MessageWriter.SearchMatch[]
local function extract_grep_line_highlights(body, line_index_offset)
    --- @type agentic.ui.MessageWriter.SearchMatch[]
    local matches = {}
    for i, line in ipairs(body) do
        -- Match path:linenum: or path:linenum- (context lines from grep -C)
        local path, sep1, linenum, sep2 = line:match("^([^:]+)(:)(%d+)([:-])")
        if path then
            local idx = line_index_offset + i - 1
            local col = 0
            -- File path
            table.insert(matches, {
                line_index = idx,
                col_start = col,
                col_end = col + #path,
                hl_group = Theme.HL_GROUPS.GREP_PATH,
            })
            col = col + #path
            -- First separator (:)
            table.insert(matches, {
                line_index = idx,
                col_start = col,
                col_end = col + #sep1,
                hl_group = Theme.HL_GROUPS.GREP_SEPARATOR,
            })
            col = col + #sep1
            -- Line number
            table.insert(matches, {
                line_index = idx,
                col_start = col,
                col_end = col + #linenum,
                hl_group = Theme.HL_GROUPS.GREP_LINE_NR,
            })
            col = col + #linenum
            -- Second separator (: or -)
            table.insert(matches, {
                line_index = idx,
                col_start = col,
                col_end = col + #sep2,
                hl_group = Theme.HL_GROUPS.GREP_SEPARATOR,
            })
        end
    end
    return matches
end

--- Fallback formatter: split a long single-line shell command at top-level
--- operators (&&, ||, ;, |) outside of quotes and subshells. Does not indent
--- control structures. Already-multiline or short commands are returned as-is.
--- @param cmd string
--- @return string
local function split_at_operators(cmd)
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

--- Try to format a shell command using an external formatter (shfmt by default).
--- Returns nil if the formatter is disabled, not installed, or errors.
--- @param cmd string
--- @return string|nil
local function try_external_formatter(cmd)
    local formatter = Config.tool_call_display
        and Config.tool_call_display.execute_formatter
    if not formatter then
        return nil
    end

    if vim.fn.executable(formatter) ~= 1 then
        return nil
    end

    -- Use vim.fn.system (NOT vim.system():wait()) because the latter
    -- processes the event loop while waiting, allowing re-entrant ACP
    -- callbacks to fire mid-render and corrupt buffer state.
    local output =
        vim.fn.system({ formatter, "-ln", "bash", "-i", "2", "-ci" }, cmd)

    if vim.v.shell_error ~= 0 or not output or output == "" then
        return nil
    end

    -- shfmt adds a trailing newline
    local formatted = output:gsub("%s+$", "")
    return formatted
end

--- Format a shell command for display. First splits long single-line commands
--- at top-level operators (|, &&, ||, ;), then runs the external formatter
--- (shfmt) to clean up indentation of the result. The order matters: shfmt
--- preserves one-liners, so splitting must happen first to give it multi-line
--- input that it can then indent properly.
--- @param cmd string
--- @return string
local function format_long_command(cmd)
    local split = split_at_operators(cmd)
    return try_external_formatter(split) or split
end

-- ---------------------------------------------------------------------------
-- Block line preparation
-- ---------------------------------------------------------------------------

--- Prepare the buffer lines for a tool call block.
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param wrap_width integer Chat window text width (0 = soft wrap, skip hard wrapping)
--- @return string[] lines Array of lines to render
--- @return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges
--- @return agentic.utils.Ansi.Span[][]|nil ansi_highlights Per-line ANSI highlight spans (execute blocks only)
function M.prepare_block_lines(tool_call_block, wrap_width)
    local kind = tool_call_block.kind
    local argument = M.strip_kind_prefix(kind, tool_call_block.argument)

    -- For read blocks, strip a trailing "(N - M)" range from the argument
    -- (often baked into the ACP title) — it belongs on the info line, not here.
    if kind == "read" then
        local path, range = M.parse_read_range(argument)
        if path then
            argument = path
            if not tool_call_block.read_range then
                tool_call_block.read_range = range
            end
        end
    end

    --- @type string[]
    local lines
    local header = string.format("### %s", M.display_kind(kind))
    if kind == "execute" then
        local cmd_lines =
            vim.split(format_long_command(argument), "\n", { plain = true })
        lines = { header, "```bash" }
        vim.list_extend(lines, cmd_lines)
        table.insert(lines, "```")
    elseif kind == "search" then
        local cmd_lines = vim.split(argument, "\n", { plain = true })
        lines = { header, "```bash" }
        vim.list_extend(lines, cmd_lines)
        table.insert(lines, "```")
    elseif kind == "fetch" then
        -- Fetch argument is "URL prompt" — show only the URL. The prompt
        -- is repeated in the body (model instructions to itself).
        local url = argument:match("^(%S+)")
        if url then
            lines = { header, string.format("`%s`", url) }
        else
            argument = argument:gsub("\n", "\\n")
            lines = { header, string.format("`%s`", argument) }
        end
    else
        -- Sanitize argument to prevent newlines
        -- nvim_buf_set_lines doesn't accept array items with embedded newlines
        argument = argument:gsub("\n", "\\n")
        lines = {
            header,
            string.format("`%s`", argument),
        }
    end

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    -- When a tool call fails, render the failure reason in place of
    -- kind-specific body/diff rendering. The summary a kind normally shows
    -- ("Read N lines", search results, a diff, fetch body) describes what
    -- the tool attempted — misleading when it never ran. `failure_reason`
    -- comes from `rawOutput` (unwrapped by extract_failure_reason), so this
    -- renders cleanly without the ``` fences that toAcpContentUpdate wraps
    -- around `content` on is_error.
    local failure_reason = tool_call_block.failure_reason
    if
        tool_call_block.status == "failed"
        and failure_reason
        and #failure_reason > 0
    then
        local fence = safe_fence(failure_reason)
        table.insert(lines, fence .. "console")
        for _, reason_line in ipairs(failure_reason) do
            table.insert(lines, reason_line)
            --- @type agentic.ui.MessageWriter.HighlightRange
            local range = { type = "error", line_index = #lines - 1 }
            table.insert(highlight_ranges, range)
        end
        table.insert(lines, fence)
    elseif kind == "read" then
        -- Count lines from content, we don't want to show full content that was read
        local line_count = tool_call_block.body and #tool_call_block.body or 0

        if line_count > 0 then
            local rr = tool_call_block.read_range
            local line_info
            if rr then
                local n = rr.limit or line_count
                local first = rr.offset
                local last = rr.limit and (first + rr.limit - 1)
                line_info = last
                        and string.format(
                            "Read %d lines (%d - %d)",
                            n,
                            first,
                            last
                        )
                    or string.format("Read %d lines (%d - …)", n, first)
            else
                line_info = string.format("Read %d lines", line_count)
            end
            table.insert(lines, line_info)

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
                local term_hl = extract_search_term_highlights(
                    body,
                    #lines - count,
                    tool_call_block.search_pattern,
                    argument
                )
                if #term_hl > 0 then
                    tool_call_block.search_matches = term_hl
                end
            end

            -- Highlight grep-format path:linenum: prefixes on each body line.
            -- Body lines occupy indices [#lines - count .. #lines - 1] in the
            -- lines array (0-based).
            local grep_hl = extract_grep_line_highlights(body, #lines - count)
            if #grep_hl > 0 then
                if tool_call_block.search_matches then
                    vim.list_extend(tool_call_block.search_matches, grep_hl)
                else
                    tool_call_block.search_matches = grep_hl
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
        local is_markdown = lang == "md" or lang == "markdown"
        local has_fences = not is_markdown
        if has_fences then
            table.insert(lines, "```" .. lang)
        end

        -- Load the target file buffer to enable context-aware syntax
        -- highlighting. The injected markdown parser only sees the diff
        -- lines in isolation, so structurally-dependent captures (strings,
        -- comments, docstrings, language injections) come out wrong.
        -- Reparsing the snippet inside its surrounding ancestor in the real
        -- file reconstructs the correct captures. Falls back silently when
        -- the file can't be loaded or no parser is available.
        local target_bufnr, target_lang
        local abs_path = FileSystem.to_absolute_path(argument)
        local max_lines = Config.tool_call_display
                and Config.tool_call_display.diff_context_max_lines
            or 0
        if max_lines > 0 and abs_path and abs_path ~= "" then
            -- bufadd returns the existing buffer if one already has this
            -- name, otherwise creates a new (unloaded) buffer.
            local ok_add, b = pcall(vim.fn.bufadd, abs_path)
            if ok_add and b and b ~= 0 and vim.api.nvim_buf_is_valid(b) then
                if not vim.api.nvim_buf_is_loaded(b) then
                    pcall(vim.fn.bufload, b)
                end
                if vim.api.nvim_buf_is_loaded(b) then
                    -- Reparse cost grows with file length; skip the feature
                    -- entirely above the configured threshold rather than
                    -- block the render thread on huge files.
                    local lc = vim.api.nvim_buf_line_count(b)
                    if lc <= max_lines then
                        local ok_p, parser = pcall(vim.treesitter.get_parser, b)
                        if ok_p and parser then
                            target_bufnr = b
                            target_lang = parser:lang()
                        end
                    end
                end
            end
        end

        -- For markdown diffs, wrap prose lines so they don't overflow the
        -- chat window. Code blocks (inside fences) stay untouched.
        local diff_wrap = is_markdown and wrap_width or 0
        local in_fence = false

        --- Insert a diff line into `lines`, wrapping if markdown prose.
        --- Tracks fence state so lines inside code blocks are not wrapped.
        --- Creates a highlight_range entry for each resulting buffer line.
        --- Wrapped sub-lines drop `col_hl` because the column positions
        --- refer to the original unwrapped content.
        --- @param content string
        --- @param hl_type string
        --- @param old_line string|nil
        --- @param new_line string|nil
        --- @param col_hl table<integer, string>|nil
        local function insert_diff_line(
            content,
            hl_type,
            old_line,
            new_line,
            col_hl
        )
            if content:match("^%s*```") then
                in_fence = not in_fence
            end
            local sub_lines, offsets
            if diff_wrap > 0 and not in_fence then
                sub_lines, offsets =
                    TextWrap.wrap_single_line_with_offsets(content, diff_wrap)
            else
                sub_lines = { content }
                offsets = { { orig_start = 0, indent_len = 0 } }
            end
            local single = #sub_lines == 1

            -- For a wrapped modification line (both old_line and new_line),
            -- compute the inline change range ONCE on the unwrapped strings,
            -- then map it onto each sub-line's local byte coords. Without
            -- this, find_inline_change runs against the full unwrapped
            -- line per sub-line and paints the highlight at original-line
            -- offsets on every wrapped row regardless of overlap.
            local change
            local wrapped_mod = not single
                and old_line ~= nil
                and new_line ~= nil
                and (hl_type == "new_modification" or hl_type == "old")
            if wrapped_mod then
                change = DiffHighlighter.find_inline_change(old_line, new_line)
            end

            for i, sub in ipairs(sub_lines) do
                local line_index = #lines
                table.insert(lines, sub)
                local sub_old, sub_new = old_line, new_line
                if wrapped_mod and change then
                    local off = offsets[i]
                    local change_start = hl_type == "old" and change.old_start
                        or change.new_start
                    local change_end = hl_type == "old" and change.old_end
                        or change.new_end
                    local orig_start = off.orig_start
                    local orig_end = orig_start + (#sub - off.indent_len)
                    local isect_start = math.max(change_start, orig_start)
                    local isect_end = math.min(change_end, orig_end)
                    if isect_start >= isect_end then
                        -- No change overlaps this sub-line. For "old" keep
                        -- the full-line DIFF_DELETE bg (pure-delete path);
                        -- for "new_modification" emit nothing by making
                        -- old == new so the highlighter returns early.
                        if hl_type == "old" then
                            sub_old, sub_new = sub, nil
                        else
                            sub_old, sub_new = sub, sub
                        end
                    else
                        -- Map intersection into sub-line-local byte cols,
                        -- accounting for the continuation indent that the
                        -- wrapper prepended (indent bytes have no origin in
                        -- the source line).
                        local local_start = isect_start
                            - orig_start
                            + off.indent_len
                        local local_end = isect_end
                            - orig_start
                            + off.indent_len
                        -- Build a synthetic counterpart with a sentinel byte
                        -- at the change position. find_inline_change then
                        -- returns exactly [local_start, local_end).
                        local synth = sub:sub(1, local_start)
                            .. "\1"
                            .. sub:sub(local_end + 1)
                        if hl_type == "old" then
                            sub_old, sub_new = sub, synth
                        else
                            sub_old, sub_new = synth, sub
                        end
                    end
                end
                --- @type agentic.ui.MessageWriter.HighlightRange
                local hl_range = {
                    line_index = line_index,
                    type = hl_type,
                    old_line = sub_old,
                    new_line = sub_new,
                }
                if single and col_hl then
                    hl_range.block_col_hl = col_hl
                end
                table.insert(highlight_ranges, hl_range)
            end
        end

        -- No matching block and a non-empty old_text means the Edit's
        -- old_string isn't in the file (the Edit will fail). Render a single
        -- placeholder line where the diff would have appeared so the chat
        -- still shows what was attempted.
        if
            #diff_blocks == 0
            and tool_call_block.diff.old
            and #tool_call_block.diff.old > 0
        then
            local first = tool_call_block.diff.old[1] or ""
            local label = "Not found: " .. first
            if #tool_call_block.diff.old > 1 then
                label = label .. " ..."
            end
            table.insert(lines, label)
        end

        for _, block in ipairs(diff_blocks) do
            local old_count = #block.old_lines
            local new_count = #block.new_lines
            local is_new_file = old_count == 0
            local is_modification = old_count == new_count and old_count > 0

            -- Compute context-aware highlight maps for this block. The same
            -- splice range works for both old and new: splicing old_lines
            -- back at the matched location reconstructs the pre-edit file
            -- state; splicing new_lines gives the post-edit state.
            local old_map, new_map
            if target_bufnr and target_lang then
                local splice_start = math.max(0, block.start_line - 1)
                local splice_end = block.end_line
                if not is_new_file then
                    old_map = Treesitter.build_highlight_map(
                        target_bufnr,
                        target_lang,
                        splice_start,
                        splice_end,
                        block.old_lines
                    )
                end
                new_map = Treesitter.build_highlight_map(
                    target_bufnr,
                    target_lang,
                    splice_start,
                    splice_end,
                    block.new_lines
                )
            end

            if is_new_file then
                -- Format tables so they render with aligned columns
                local fmt_new = is_markdown
                        and TextWrap.format_tables_in_lines(block.new_lines)
                    or block.new_lines
                for ni, new_line in ipairs(fmt_new) do
                    local col_hl = new_map and new_map[ni - 1] or nil
                    insert_diff_line(new_line, "new", nil, new_line, col_hl)
                end
            else
                local filtered = ToolCallDiff.filter_unchanged_lines(
                    block.old_lines,
                    block.new_lines
                )

                -- Collect old/new lines, format tables within each
                -- group independently so they don't merge across the
                -- old→new boundary.
                local old_raw = {} ---@type string[]
                local new_raw = {} ---@type string[]
                local old_pair_idx = {} ---@type integer[]
                local new_pair_idx = {} ---@type integer[]
                for _, pair in ipairs(filtered.pairs) do
                    if pair.old_line then
                        old_raw[#old_raw + 1] = pair.old_line
                        old_pair_idx[#old_pair_idx + 1] = pair.old_idx
                    end
                    if pair.new_line then
                        new_raw[#new_raw + 1] = pair.new_line
                        new_pair_idx[#new_pair_idx + 1] = pair.new_idx
                    end
                end

                local fmt_old = is_markdown
                        and TextWrap.format_tables_in_lines(old_raw)
                    or old_raw
                local fmt_new = is_markdown
                        and TextWrap.format_tables_in_lines(new_raw)
                    or new_raw

                -- Insert old lines (removed content)
                local oi = 0
                for _, pair in ipairs(filtered.pairs) do
                    if pair.old_line then
                        oi = oi + 1
                        local source_idx = old_pair_idx[oi]
                        local col_hl = old_map
                                and source_idx
                                and old_map[source_idx - 1]
                            or nil
                        insert_diff_line(
                            fmt_old[oi],
                            "old",
                            pair.old_line,
                            is_modification and pair.new_line or nil,
                            col_hl
                        )
                    end
                end

                -- Insert new lines (added content)
                local ni = 0
                for _, pair in ipairs(filtered.pairs) do
                    if pair.new_line then
                        ni = ni + 1
                        local hl_type = is_modification and "new_modification"
                            or "new"
                        local source_idx = new_pair_idx[ni]
                        local col_hl = new_map
                                and source_idx
                                and new_map[source_idx - 1]
                            or nil
                        insert_diff_line(
                            fmt_new[ni],
                            hl_type,
                            is_modification and pair.old_line or nil,
                            pair.new_line,
                            col_hl
                        )
                    end
                end
            end
        end

        -- Close code fences, if not markdown, to avoid conflicts
        if has_fences then
            table.insert(lines, "```")
        end
    elseif kind == "fetch" or kind == "WebSearch" or kind == "SubAgent" then
        if tool_call_block.body then
            -- Fetch/WebSearch/SubAgent body is informational text that the
            -- agent wrote to itself. Wrap in a code fence to prevent markdown
            -- parsing artefacts and always fold since users rarely need it.
            -- `markdown` info string dims the block via AgenticDimmedBlock
            -- (priority 101, set in ftplugin/AgenticChat.lua) while keeping
            -- injected bold/underline styling.
            local wrapped =
                TextWrap.wrap_prose(tool_call_block.body, wrap_width)
            local fence = safe_fence(wrapped)
            table.insert(lines, fence .. "markdown")
            table.insert(lines, "{{{")
            vim.list_extend(lines, wrapped)
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

    -- Grep-format highlighting for execute tool calls.
    -- Detect grep-family commands and highlight path:linenum: prefixes + search term.
    if
        kind == "execute"
        and tool_call_block.body
        and is_grep_command(argument)
    then
        --- @type string[]
        local body = tool_call_block.body
        local body_count = #body
        local bend = #lines
        if lines[bend] == "}}}" then
            bend = bend - 1
        end
        local bstart = bend - body_count

        local grep_hl = extract_grep_line_highlights(body, bstart)
        if #grep_hl > 0 then
            tool_call_block.search_matches = grep_hl
        end

        local term_hl =
            extract_search_term_highlights(body, bstart, nil, argument)
        if #term_hl > 0 then
            if tool_call_block.search_matches then
                vim.list_extend(tool_call_block.search_matches, term_hl)
            else
                tool_call_block.search_matches = term_hl
            end
        end
    end

    table.insert(lines, "")

    return lines, highlight_ranges, ansi_highlights
end

-- ---------------------------------------------------------------------------
-- Highlight application
-- ---------------------------------------------------------------------------

--- Apply highlights to block content (either diff highlights or Comment for non-edit blocks)
--- @param bufnr integer
--- @param start_row integer Header line number
--- @param end_row integer Footer line number
--- @param kind string Tool call kind
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[] Diff highlight ranges
--- @param ansi_highlights? agentic.utils.Ansi.Span[][] Per-line ANSI highlight spans
--- @param search_matches? agentic.ui.MessageWriter.SearchMatch[] Search pattern match positions
--- @param search_ansi? agentic.utils.Ansi.Span[][] ANSI highlights for search body
function M.apply_block_highlights(
    bufnr,
    start_row,
    end_row,
    kind,
    highlight_ranges,
    ansi_highlights,
    search_matches,
    search_ansi
)
    -- This runs via vim.schedule — buffer may have changed since the
    -- caller captured start_row/end_row. Bail if rows are now out of range.
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if start_row >= line_count or end_row > line_count then
        return
    end

    if #highlight_ranges > 0 then
        M.apply_diff_highlights(bufnr, start_row, highlight_ranges)
    elseif kind ~= "edit" and kind ~= "switch_mode" then
        -- Header is "### Kind" (1 line) for execute/search, or "### Kind" +
        -- "`argument`" (2 lines) for others. Skip both before body content.
        local body_start = start_row + 2
        if kind == "execute" or kind == "search" then
            -- Find the closing ``` to skip the command code fence
            for i = start_row + 2, end_row - 1 do
                local l = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
                if l and l == "```" then
                    body_start = i + 1
                    break
                end
            end
        end

        -- Skip a fold-open marker line ("{{{") that sits between the fence
        -- and the actual body lines. ANSI spans are computed against body
        -- content, not the marker.
        local marker = vim.api.nvim_buf_get_lines(
            bufnr,
            body_start,
            body_start + 1,
            false
        )[1]
        if marker == "{{{" then
            body_start = body_start + 1
        end

        -- Execute blocks with ANSI codes get per-character colour highlights
        if ansi_highlights then
            Ansi.apply_highlights(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                body_start,
                ansi_highlights
            )
        else
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
        -- Skip a fold-open marker line ("{{{") between the fence and the body.
        local marker = vim.api.nvim_buf_get_lines(
            bufnr,
            body_start,
            body_start + 1,
            false
        )[1]
        if marker == "{{{" then
            body_start = body_start + 1
        end
        Ansi.apply_highlights(
            bufnr,
            NS_DIFF_HIGHLIGHTS,
            body_start,
            search_ansi
        )
    elseif search_matches then
        for _, match in ipairs(search_matches) do
            local row = start_row + match.line_index
            if row < line_count then
                local line_len = #(
                    vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
                    or ""
                )
                if match.col_start <= line_len then
                    local end_col = math.min(match.col_end, line_len)
                    vim.api.nvim_buf_set_extmark(
                        bufnr,
                        NS_DIFF_HIGHLIGHTS,
                        row,
                        match.col_start,
                        {
                            end_col = end_col,
                            hl_group = match.hl_group or "AgenticSearchMatch",
                            priority = 200,
                        }
                    )
                end
            end
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

--- Cache of derived "clean" highlight groups: target capture name →
--- generated group name with the same fg/bg as the target but typography
--- attributes (bold/italic/underline/etc.) explicitly forced off. Cleared
--- on `ColorScheme` since `:hi clear` wipes every group.
--- @type table<string, string>
local _clean_hl_cache = {}

vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
        _clean_hl_cache = {}
    end,
})

--- Look up (and cache) a derived highlight group for `name` that inherits
--- its fg/bg/sp from the original but with typography attributes
--- explicitly set to false. This stops bold/italic from a lower-priority
--- highlight (e.g. the markdown injection's `@keyword.python`) from
--- bleeding through when our `fg`-only override sits at higher priority.
--- Returns the original name as fallback when it resolves to nothing.
--- @param name string
--- @return string
local function get_clean_hl_group(name)
    local cached = _clean_hl_cache[name]
    if cached then
        return cached
    end

    local hl = vim.api.nvim_get_hl(0, { name = name, link = false }) or {}
    if vim.tbl_isempty(hl) then
        _clean_hl_cache[name] = name
        return name
    end

    -- `nvim_set_hl` silently drops typography attributes assigned to
    -- `false` (only `true` survives the roundtrip), so we cannot suppress
    -- bold/italic per-attribute. The fix is `nocombine = true` — neovim's
    -- screen renderer then fully replaces the lower-priority highlight at
    -- this position rather than OR-merging boolean attributes. Verified
    -- with a headless `nvim_set_hl` roundtrip: only `nocombine` survived.
    hl.nocombine = true

    local clean_name = "AgenticClean_" .. name:gsub("[^%w]", "_")
    vim.api.nvim_set_hl(0, clean_name, hl --[[@as vim.api.keyset.highlight]])
    _clean_hl_cache[name] = clean_name
    return clean_name
end

--- Apply per-column treesitter capture highlights from a context-aware
--- reparse. The col_hl map is byte-col → language-qualified capture name
--- (e.g. `@string.python`). Adjacent cols with identical capture names are
--- merged into a single extmark to keep the count bounded. Each capture
--- is mapped through `get_clean_hl_group` so that typography attributes
--- from the underlying markdown-injected highlights don't leak through.
--- Priority 200 beats markdown's priority-100 injected highlights.
--- @param bufnr integer
--- @param buffer_line integer 0-indexed buffer row
--- @param col_hl table<integer, string>
local function apply_block_col_highlights(bufnr, buffer_line, col_hl)
    local cols = {}
    for c, _ in pairs(col_hl) do
        cols[#cols + 1] = c
    end
    table.sort(cols)

    local i = 1
    while i <= #cols do
        local start_col = cols[i]
        local hl = col_hl[start_col]
        local end_col = start_col + 1
        local j = i + 1
        while j <= #cols and cols[j] == end_col and col_hl[cols[j]] == hl do
            end_col = end_col + 1
            j = j + 1
        end
        vim.api.nvim_buf_set_extmark(
            bufnr,
            NS_DIFF_HIGHLIGHTS,
            buffer_line,
            start_col,
            {
                end_col = end_col,
                hl_group = get_clean_hl_group(hl),
                priority = 200,
            }
        )
        i = j
    end
end

--- @param bufnr integer
--- @param start_row integer
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
function M.apply_diff_highlights(bufnr, start_row, highlight_ranges)
    if not highlight_ranges or #highlight_ranges == 0 then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for _, hl_range in ipairs(highlight_ranges) do
        local buffer_line = start_row + hl_range.line_index

        if hl_range.type == "old" then
            DiffHighlighter.apply_diff_highlights(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        elseif hl_range.type == "new" then
            DiffHighlighter.apply_diff_highlights(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                nil,
                hl_range.new_line
            )
        elseif hl_range.type == "new_modification" then
            DiffHighlighter.apply_new_line_word_highlights(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        elseif hl_range.type == "comment" or hl_range.type == "error" then
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                buffer_line,
                buffer_line + 1,
                false
            )[1]

            if line then
                local hl_group = hl_range.type == "error"
                        and Theme.HL_GROUPS.ERROR_BODY
                    or "Comment"
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_DIFF_HIGHLIGHTS,
                    buffer_line,
                    0,
                    {
                        end_col = #line,
                        hl_group = hl_group,
                    }
                )
            end
        end

        if hl_range.block_col_hl and buffer_line < line_count then
            apply_block_col_highlights(
                bufnr,
                buffer_line,
                hl_range.block_col_hl
            )
        end
    end
end

--- Apply syntax highlighting to a tool call header line.
--- Header format: "### Kind" — highlights the kind portion with TOOL_KIND.
--- The argument (if any) is on the next line as `` `argument` `` and gets
--- TOOL_ARGUMENT highlight.
--- @param bufnr integer
--- @param line_row integer 0-indexed row of the "### Kind" line
--- @param ns integer Namespace to use for extmarks
function M.apply_tool_header_syntax(bufnr, line_row, ns)
    local lines =
        vim.api.nvim_buf_get_lines(bufnr, line_row, line_row + 2, false)
    local line = lines[1]
    if not line then
        return
    end

    -- "### Kind" — highlight the kind after "### "
    local prefix = line:match("^###%s+")
    if prefix then
        vim.api.nvim_buf_set_extmark(bufnr, ns, line_row, #prefix, {
            end_col = #line,
            hl_group = Theme.HL_GROUPS.TOOL_KIND,
            priority = 200,
        })
    end

    -- Next line: "`argument`" — highlight the argument text inside backticks
    local arg_line = lines[2]
    if arg_line then
        local bt_start = arg_line:find("`")
        if bt_start then
            local bt_end = arg_line:find("`", bt_start + 1)
            if bt_end then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    ns,
                    line_row + 1,
                    bt_start,
                    {
                        end_col = bt_end - 1,
                        hl_group = Theme.HL_GROUPS.TOOL_ARGUMENT,
                        priority = 200,
                    }
                )
            end
        end
    end
end

--- Write status text directly into the footer buffer line and apply highlight.
--- Uses set_text (not set_lines) so sign_text extmarks on the footer line
--- are not shifted — set_lines replaces the line, displacing extmarks.
--- @param bufnr integer
--- @param footer_line integer 0-indexed footer line number
--- @param status string Status value (pending, completed, etc.)
function M.apply_status_footer(bufnr, footer_line, status)
    if not vim.api.nvim_buf_is_valid(bufnr) or not status or status == "" then
        return
    end

    local icons = Config.status_icons or {}
    local icon = icons[status] or ""
    local status_text = string.format(" %s %s ", icon, status)
    local hl_group = Theme.get_status_hl_group(status)

    local current = vim.api.nvim_buf_get_lines(
        bufnr,
        footer_line,
        footer_line + 1,
        false
    )[1] or ""

    vim.api.nvim_buf_set_text(
        bufnr,
        footer_line,
        0,
        footer_line,
        #current,
        { status_text }
    )

    vim.api.nvim_buf_set_extmark(bufnr, NS_STATUS, footer_line, 0, {
        end_col = #status_text,
        hl_group = hl_group,
    })
end

-- ---------------------------------------------------------------------------
-- Decoration borders
-- ---------------------------------------------------------------------------

--- @param bufnr integer
--- @param ids integer[]|nil
function M.clear_decoration_extmarks(bufnr, ids)
    if not ids then
        return
    end

    for _, id in ipairs(ids) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, NS_DECORATIONS, id)
    end
end

--- @param bufnr integer
--- @param start_row integer
--- @param end_row integer
--- @return integer[] decoration_extmark_ids
function M.render_decorations(bufnr, start_row, end_row)
    return ExtmarkBlock.render_block(bufnr, NS_DECORATIONS, {
        header_line = start_row,
        body_start = start_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

--- @param bufnr integer
--- @param start_row integer
--- @param end_row integer
function M.clear_status_namespace(bufnr, start_row, end_row)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        bufnr,
        NS_STATUS,
        start_row,
        end_row + 1
    )
end

return M
