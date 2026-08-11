local ToolCallDiff = require("agentic.ui.tool_call_diff")
local Ansi = require("agentic.utils.ansi")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local ExecShell = require("agentic.utils.exec_shell")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local TextWrap = require("agentic.utils.text_wrap")
local Theme = require("agentic.theme")
local Treesitter = require("agentic.utils.treesitter")
local ZshParseGuard = require("agentic.utils.zsh_parse_guard")

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

--- Per-kind glyph shown on the collapsed tool-call heading in place of the
--- kind word. Keyed on the lowercased kind; unlisted kinds fall back to
--- DEFAULT_GLYPH. edit and write intentionally share identity (both arrive as
--- kind == "edit", distinguished only by diff content).
--- @type table<string, string>
local KIND_GLYPHS = {
    read = "󰈈",
    edit = "󰏫",
    execute = "󰆍",
    search = "󰍉",
    fetch = "󰖟",
    websearch = "󰖟",
    subagent = "󰚩",
}
local DEFAULT_GLYPH = "󰒓"

--- @param kind string
--- @return string
local function kind_glyph(kind)
    return KIND_GLYPHS[vim.trim(kind):lower()] or DEFAULT_GLYPH
end

--- Truncate `s` to at most `width` display columns, appending "…" (which
--- occupies the final column) when the string is cut. Returns `s` unchanged
--- when it already fits or `width` is not positive.
--- @param s string
--- @param width integer
--- @return string
local function truncate_display(s, width)
    if width <= 0 or vim.fn.strdisplaywidth(s) <= width then
        return s
    end
    local budget = width - 1
    local out = vim.fn.strcharpart(s, 0, budget)
    while #out > 0 and vim.fn.strdisplaywidth(out) > budget do
        out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
    end
    return out .. "…"
end

--- Build the collapsed tool-call heading: `` ### <glyph> `name` ``. The glyph
--- carries the kind identity (the kind word is dropped); `name` is the
--- informative content (filename / description / command) that
--- treesitter-context pins as a breadcrumb. `name` is backtick-wrapped so
--- markdown inline parsing (emphasis on `_`, stray `` ` ``) cannot corrupt the
--- heading. An empty `name` yields a glyph-only heading (`### <glyph>`) — used
--- before the argument has streamed in, and for execute calls with no model
--- description (the command already shows in the fence below). When `truncate`
--- is set, `name` is clamped to a single screen line: `wrap_width` (or 80 when
--- soft-wrapping) minus the `` ### <glyph> `` prefix and one cell for the
--- ellipsis.
--- @param kind string
--- @param name string
--- @param wrap_width integer
--- @param truncate boolean
--- @return string
local function collapsed_header(kind, name, wrap_width, truncate)
    local prefix = string.format("### %s", kind_glyph(kind))
    if name == "" then
        return prefix
    end
    if truncate then
        local budget = (wrap_width > 0 and wrap_width or 80)
            - vim.fn.strdisplaywidth(prefix .. " ")
        name = truncate_display(name, budget)
    end
    return string.format("%s `%s`", prefix, name)
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

--- Language label for the execute command fence — the exec shell the provider
--- runs commands in (`ExecShell.resolve`), matching `environment_info`.
--- Cosmetic only. The zsh parser is aliased to "bash", so highlighting is
--- identical regardless of the label, which is only visible at conceallevel=0;
--- "bash" on an unprovable (`nil`) resolve keeps the label from going blank.
--- @return string
local function shell_lang()
    return ExecShell.resolve() or "bash"
end

--- Fence info-string for a shell command. Normally the shell label, but the
--- chat buffer injects that label as the tree-sitter-zsh parser (zsh is aliased
--- to bash), which hangs the editor forever on the `${…/…[…)` shape (see
--- ZshParseGuard). Fall back to a non-injecting "text" label on that shape so
--- the command still renders — it loses syntax colouring, matching the
--- fail-open guards on the diff-highlight paths.
--- @param argument string Shell command text
--- @param lang string Shell label to use when the command is safe to inject
--- @return string
local function shell_fence_lang(argument, lang)
    if ZshParseGuard.contains_hang_trigger(argument) then
        return "text"
    end
    return lang
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

--- Memoized results of format_long_command. Each execute block is rendered at
--- least twice (initial tool_call + completed tool_call_update, more when
--- output streams across updates) with an immutable command, so without this
--- every render re-spawns the synchronous shfmt subprocess. Keyed on the
--- formatter setting *and* command text: the formatter can be reconfigured
--- mid-session, so a command cached under one formatter must not be reused
--- under another. Identical commands under the same formatter share a result
--- across separate tool calls.
--- ponytail: unbounded, one entry per distinct (formatter, command) rendered
--- this session; add an LRU cap if command variety ever bloats memory.
--- @type table<string, string>
local format_cache = {}

--- Format a shell command for display. First splits long single-line commands
--- at top-level operators (|, &&, ||, ;), then runs the external formatter
--- (shfmt) to clean up indentation of the result. The order matters: shfmt
--- preserves one-liners, so splitting must happen first to give it multi-line
--- input that it can then indent properly.
--- @param cmd string
--- @return string
local function format_long_command(cmd)
    local formatter = Config.tool_call_display
        and Config.tool_call_display.execute_formatter
    local key = tostring(formatter) .. "\0" .. cmd
    local cached = format_cache[key]
    if cached ~= nil then
        return cached
    end
    local split = split_at_operators(cmd)
    local formatted = try_external_formatter(split) or split
    format_cache[key] = formatted
    return formatted
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
--- @return integer|nil fold_anchor 0-indexed offset within lines of the first body line of a `*-fold`/`-difffold` fence — a line inside the fold (the fold spans `code_fence_content`, so the concealed fence delimiter is outside it). The writer applies fold state at this line via :foldopen/:foldclose. nil when the block is not foldable.
--- @return [integer, integer]|nil dim_range Body row range to dim with AgenticDimmedBlock, 0-indexed offsets within lines
--- @return boolean|nil fold_open Desired fold state when fold_anchor is set: true opens (applied edit diffs), false/nil closes (sidecar `*-fold` bodies, rejected edit diffs). The explicit open is required to defeat the foldexpr leak — see MessageWriter:_open_fold.
function M.prepare_block_lines(tool_call_block, wrap_width)
    local kind = tool_call_block.kind
    local argument = M.strip_kind_prefix(kind, tool_call_block.argument)

    -- This function wraps the body in a code fence, so a body that is already a
    -- single fenced block must be unwrapped first or it renders double-fenced
    -- (an outer fence widened by safe_fence around the inner one). The
    -- claude-agent-acp adapter normally strips its bridge-added ```console
    -- wrapper at the source, but a body can still arrive fenced — a stale
    -- adapter instance after a hot-reload, or another provider that pre-fences.
    -- Unwrapping here (idempotent) makes single-wrapping a property of the
    -- renderer rather than a promise each adapter must keep. Mutates in place so
    -- the ANSI/grep offset consumers below see the same body.
    if kind == "execute" then
        local body = tool_call_block.body
        if
            body
            and #body >= 2
            and body[1]:match("^`+%a*$")
            and body[#body]:match("^`+$")
        then
            tool_call_block.body = vim.list_slice(body, 2, #body - 1)
        end
    end

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
    if kind == "execute" then
        local cmd_lines =
            vim.split(format_long_command(argument), "\n", { plain = true })
        local fence = safe_fence(cmd_lines)
        -- Head shows the model's description; when absent it stays glyph-only
        -- rather than repeating the command (which renders in the fence below).
        local description = tool_call_block.description
        local head_name = (description and description ~= "")
                and vim.split(description, "\n", { plain = true })[1]
            or ""
        lines = {
            collapsed_header(kind, head_name, wrap_width, true),
            fence .. shell_fence_lang(argument, shell_lang()),
        }
        vim.list_extend(lines, cmd_lines)
        table.insert(lines, fence)
    elseif kind == "search" then
        local cmd_lines = vim.split(argument, "\n", { plain = true })
        local fence = safe_fence(cmd_lines)
        lines = {
            collapsed_header(kind, cmd_lines[1], wrap_width, true),
            fence .. shell_fence_lang(argument, "bash"),
        }
        vim.list_extend(lines, cmd_lines)
        table.insert(lines, fence)
    elseif kind == "fetch" then
        -- Fetch argument is "URL prompt" — show only the URL. The prompt
        -- is repeated in the body (model instructions to itself).
        local url = argument:match("^(%S+)")
        local name = url or (argument:gsub("\n", "\\n"))
        lines = { collapsed_header(kind, name, wrap_width, false) }
    elseif argument == "" then
        -- Argument hasn't streamed in yet (placeholder suppressed in adapter);
        -- the glyph-only head holds the layout until the next update.
        lines = { collapsed_header(kind, "", wrap_width, false) }
    else
        -- Sanitize argument to prevent embedded newlines — nvim_buf_set_lines
        -- rejects array items containing "\n".
        argument = argument:gsub("\n", "\\n")
        lines = { collapsed_header(kind, argument, wrap_width, false) }
    end

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}
    --- @type integer|nil
    local fold_anchor
    --- @type boolean|nil
    local fold_open
    --- @type [integer, integer]|nil
    local dim_range

    -- When a tool call fails, render the failure reason in place of
    -- kind-specific body/diff rendering. The summary a kind normally shows
    -- ("Read N lines", search results, a diff, fetch body) describes what
    -- the tool attempted — misleading when it never ran. `failure_reason`
    -- comes from `rawOutput` (unwrapped by extract_failure_reason), so this
    -- renders cleanly without the ``` fences that toAcpContentUpdate wraps
    -- around `content` on is_error.
    --
    -- For execute, the failure reason is the bash stdout/stderr of a
    -- non-zero exit — long, often informational, and painting it all red
    -- creates more noise than signal. Render with folding and no error
    -- tint (same shape as a successful execute body). Short denial
    -- reasons from other kinds (hook denials, permission errors) keep the
    -- red ERROR_BODY highlight.
    local failure_reason = tool_call_block.failure_reason

    if
        tool_call_block.status == "failed"
        and failure_reason
        and #failure_reason > 0
        -- Edit diffs handle their own failed case: the diff branch renders the
        -- diff (folded closed) with the reason appended below, rather than
        -- replacing the diff with the reason. Only non-diff kinds (execute,
        -- read, search, fetch) use this reason-only path.
        and not tool_call_block.diff
    then
        local fence = safe_fence(failure_reason)
        -- 0 means "never fold" (matches the success path).
        local exec_max_lines = kind == "execute"
                and Config.tool_call_display.execute_max_lines
            or 0
        local use_fold = exec_max_lines > 0 and #failure_reason > exec_max_lines
        table.insert(lines, fence .. (use_fold and "console-fold" or "console"))
        if use_fold then
            -- First body line (the fold spans code_fence_content, not the
            -- conceal_lines-hidden delimiters), inserted next.
            fold_anchor = #lines
        end
        for _, reason_line in ipairs(failure_reason) do
            table.insert(lines, reason_line)
            if kind ~= "execute" then
                --- @type agentic.ui.MessageWriter.HighlightRange
                local range = { type = "error", line_index = #lines - 1 }
                table.insert(highlight_ranges, range)
            end
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
            local use_fold = max_lines > 0 and count > max_lines
            local fence = safe_fence(body)
            table.insert(
                lines,
                fence .. (use_fold and "console-fold" or "console")
            )
            if use_fold then
                -- First body line (fold spans code_fence_content), next.
                fold_anchor = #lines
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

            table.insert(lines, fence)
        end
    elseif tool_call_block.diff then
        local diff_blocks, source_lines = ToolCallDiff.extract_diff_blocks({
            path = argument,
            old_text = tool_call_block.diff.old,
            new_text = tool_call_block.diff.new,
            replace_all = tool_call_block.diff.all,
        })

        -- Capture the matched blocks for diff_jump navigation. Re-extracting
        -- at gf-press time can fail if the file's loaded buffer was refreshed
        -- to post-edit content (e.g. after a tabedit reload), at which point
        -- the OLD-based matcher no longer finds anything.
        if #diff_blocks > 0 then
            tool_call_block.cached_diff_blocks = diff_blocks
        end

        -- `lang` (inferred from the path) is the fence label and the language
        -- for context-aware highlighting; it is NOT the injection language
        -- (see the `-difffold` note below). Strip any path-induced `-fold`
        -- suffix (a file named `foo.x-fold`) so the fence string can't become
        -- a pathological `foo-fold-difffold`.
        -- Contents inform the type only when the filename can't (extensionless
        -- files like zsh `#compdef` completions); the file's own head beats
        -- the diff's.
        local lang = Theme.get_language_from_path(
            argument,
            #source_lines > 0 and source_lines or tool_call_block.diff.new
        ):gsub("%-fold$", "")

        local fence_content = {}
        for _, block in ipairs(diff_blocks) do
            vim.list_extend(fence_content, block.old_lines)
            vim.list_extend(fence_content, block.new_lines)
        end
        local fence = safe_fence(fence_content)
        -- The `-difffold` marker makes the whole diff body foldable as ONE
        -- block (folds.scm matches `fold$`) while suppressing language
        -- injection (injections.scm excludes `difffold$`) — without it the
        -- injected language's folds.scm shatters the diff into per-structure
        -- sub-folds. Highlighting comes from block_col_hl extmarks instead.
        -- The diff is foldable; it renders open normally and closed only when
        -- the edit failed (e.g. a rejected permission). The fold state is set
        -- explicitly (fold_open) rather than left to the foldlevel default,
        -- because a fold created after a closed one inherits the closed state
        -- under foldmethod=expr — see MessageWriter:_open_fold.
        table.insert(lines, fence .. lang .. "-difffold")
        -- First body line (fold spans code_fence_content), inserted below.
        fold_anchor = #lines
        -- A created file's diff is the whole file, so collapse large ones
        -- closed; an edit shows only fragments and is never auto-collapsed.
        local is_create = not tool_call_block.diff.old
            or #tool_call_block.diff.old == 0
        local create_max = Config.tool_call_display
                and Config.tool_call_display.create_max_lines
            or 0
        local collapse = is_create
            and create_max > 0
            and #tool_call_block.diff.new > create_max
        fold_open = tool_call_block.status ~= "failed" and not collapse

        -- Context-aware syntax highlighting: the chat buffer's fence injection
        -- only sees the diff lines in isolation, so structurally-dependent
        -- captures (strings, comments, docstrings, language injections —
        -- including code fences embedded in markdown) come out wrong.
        -- Reparsing the snippet spliced back into the surrounding file
        -- reconstructs the correct captures. Falls back silently when no
        -- parser matches the path.
        --
        -- Reparse cost grows with the reconstructed file, so gate on its size.
        local context_max = Config.tool_call_display
                and Config.tool_call_display.diff_context_max_lines
            or 0
        local context_lines = math.max(#source_lines, #tool_call_block.diff.new)
        local use_context_highlights = context_max > 0
            and context_lines <= context_max
            and lang ~= ""

        --- Insert a diff line into `lines` and record its highlight range.
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
            --- @type agentic.ui.MessageWriter.HighlightRange
            local hl_range = {
                line_index = #lines,
                type = hl_type,
                old_line = old_line,
                new_line = new_line,
                block_col_hl = col_hl,
            }
            table.insert(lines, content)
            table.insert(highlight_ranges, hl_range)
        end

        -- No matching block and a non-empty old_text means the Edit's
        -- old_string isn't in the file. This happens with opencode when
        -- the diff data arrives after the edit has been applied.
        -- Render the diff directly from old/new arrays without file matching.
        if
            #diff_blocks == 0
            and tool_call_block.diff.old
            and #tool_call_block.diff.old > 0
        then
            --- @type agentic.ui.ToolCallDiff.DiffBlock
            local unmatched_block = {
                start_line = 1,
                end_line = #tool_call_block.diff.old,
                old_lines = tool_call_block.diff.old,
                new_lines = tool_call_block.diff.new or {},
                -- The old text was not found, so these coordinates index
                -- nothing — splicing at them would fabricate context.
                unmatched = true,
            }
            table.insert(diff_blocks, unmatched_block)
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
            if use_context_highlights and not block.unmatched then
                local splice_start = math.max(0, block.start_line - 1)
                local splice_end = block.end_line
                if not is_new_file then
                    old_map = Treesitter.highlight_map_in_context(
                        source_lines,
                        lang,
                        splice_start,
                        splice_end,
                        block.old_lines
                    )
                end
                new_map = Treesitter.highlight_map_in_context(
                    source_lines,
                    lang,
                    splice_start,
                    splice_end,
                    block.new_lines
                )
            end

            if is_new_file then
                for ni, new_line in ipairs(block.new_lines) do
                    local col_hl = new_map and new_map[ni - 1] or nil
                    insert_diff_line(new_line, "new", nil, new_line, col_hl)
                end
            else
                local filtered = ToolCallDiff.filter_unchanged_lines(
                    block.old_lines,
                    block.new_lines
                )

                -- Insert old lines (removed content)
                for _, pair in ipairs(filtered.pairs) do
                    if pair.old_line then
                        local col_hl = old_map
                            and old_map[pair.old_idx - 1]
                            or nil
                        insert_diff_line(
                            pair.old_line,
                            "old",
                            pair.old_line,
                            is_modification and pair.new_line or nil,
                            col_hl
                        )
                    end
                end

                -- Insert new lines (added content)
                for _, pair in ipairs(filtered.pairs) do
                    if pair.new_line then
                        -- Block-level is_modification doesn't imply per-pair
                        -- modification: filter_unchanged_lines can split a
                        -- same-line-count block into pure insertions and
                        -- pure deletions. Pure insertions have no old_line
                        -- — emit as "new" so the highlighter doesn't run
                        -- find_inline_change on nil.
                        local is_paired_mod = is_modification
                            and pair.old_line ~= nil
                        local hl_type = is_paired_mod and "new_modification"
                            or "new"
                        local col_hl = new_map
                            and new_map[pair.new_idx - 1]
                            or nil
                        insert_diff_line(
                            pair.new_line,
                            hl_type,
                            is_paired_mod and pair.old_line or nil,
                            pair.new_line,
                            col_hl
                        )
                    end
                end
            end
        end

        table.insert(lines, fence)

        -- A failed edit keeps the diff (open) and appends the reason beneath
        -- it, so the user sees both what was attempted and why it failed. The
        -- reason (rejection, hook denial, old_string-not-found) is short and
        -- non-execute, so it gets the red ERROR_BODY highlight; the console
        -- fence prevents markdown parsing of `--`/`*`.
        if
            tool_call_block.status == "failed"
            and failure_reason
            and #failure_reason > 0
        then
            local reason_fence = safe_fence(failure_reason)
            table.insert(lines, reason_fence .. "console")
            for _, reason_line in ipairs(failure_reason) do
                table.insert(lines, reason_line)
                --- @type agentic.ui.MessageWriter.HighlightRange
                local range = { type = "error", line_index = #lines - 1 }
                table.insert(highlight_ranges, range)
            end
            table.insert(lines, reason_fence)
        end
    elseif kind == "fetch" or kind == "WebSearch" or kind == "SubAgent" then
        if tool_call_block.body then
            -- Fetch/WebSearch/SubAgent body is informational text the agent
            -- wrote to itself. Always fold (rarely needed by users) and dim
            -- (visually de-emphasise as sidecar content).
            local wrapped =
                TextWrap.wrap_prose(tool_call_block.body, wrap_width)
            local fence = safe_fence(wrapped)
            local use_fold = #wrapped > 1
            table.insert(
                lines,
                fence .. (use_fold and "markdown-fold" or "markdown")
            )
            local body_start_idx = #lines
            if use_fold then
                -- First body line (fold spans code_fence_content).
                fold_anchor = body_start_idx
            end
            vim.list_extend(lines, wrapped)
            local body_end_idx = #lines - 1
            dim_range = { body_start_idx, body_end_idx }
            table.insert(lines, fence)
        end
    else
        if tool_call_block.body then
            --- @type string[]
            local body = tool_call_block.body

            -- Detect structured JSON results (meta/MCP tools) and pretty-print
            -- them into a *local* display_body so the fold threshold has
            -- something multi-line to key on and the JSON parser can inject.
            -- Gated `kind ~= "execute"`: a successful execute reaches this
            -- branch too, and reformatting its body would desync the ANSI/grep
            -- passes below that assume a 1:1 mapping to tool_call_block.body.
            -- Never mutate tool_call_block.body — MessageWriter merges each
            -- streamed update against the raw body, so it must stay canonical.
            local lang = "console"
            --- @type string[]
            local display_body = body
            if kind ~= "execute" then
                local ok, decoded =
                    pcall(vim.json.decode, table.concat(body, "\n"))
                if ok and type(decoded) == "table" then
                    local pretty = vim.json.encode(
                        decoded,
                        { indent = "  ", sort_keys = true }
                    )
                    display_body = vim.split(pretty, "\n")
                    lang = "json"
                end
            end

            local max_lines = kind == "execute"
                    and Config.tool_call_display.execute_max_lines
                or Config.tool_call_display.other_max_lines
            local count = #display_body
            local use_fold = max_lines > 0 and count > max_lines

            local fence = safe_fence(display_body)
            table.insert(
                lines,
                fence .. lang .. (use_fold and "-fold" or "")
            )
            if use_fold then
                -- First body line (fold spans code_fence_content), next.
                fold_anchor = #lines
            end
            vim.list_extend(lines, display_body)
            table.insert(lines, fence)
        end
    end

    -- Locate the execute body's line range within `lines`. Layout is:
    --   ..., fence..console, body, fence
    -- so step past the closing fence.
    local body_start_offset
    if kind == "execute" and tool_call_block.body then
        local body_count = #tool_call_block.body
        local i = #lines
        if lines[i] and lines[i]:match("^`+$") then
            i = i - 1
        end
        body_start_offset = i - body_count
    end

    -- Process ANSI escape codes in execute block body output
    --- @type agentic.utils.Ansi.Span[][]|nil
    local ansi_highlights
    if kind == "execute" and tool_call_block.body and body_start_offset then
        local body_count = #tool_call_block.body
        local result = Ansi.process_lines(tool_call_block.body)
        if result.has_ansi then
            for i = 1, body_count do
                lines[body_start_offset + i] = result.lines[i]
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
        and body_start_offset
        and is_grep_command(argument)
    then
        --- @type string[]
        local body = tool_call_block.body

        local grep_hl = extract_grep_line_highlights(body, body_start_offset)
        if #grep_hl > 0 then
            tool_call_block.search_matches = grep_hl
        end

        local term_hl = extract_search_term_highlights(
            body,
            body_start_offset,
            nil,
            argument
        )
        if #term_hl > 0 then
            if tool_call_block.search_matches then
                vim.list_extend(tool_call_block.search_matches, term_hl)
            else
                tool_call_block.search_matches = term_hl
            end
        end
    end

    table.insert(lines, "")

    return lines, highlight_ranges, ansi_highlights, fold_anchor, dim_range, fold_open
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
        -- The collapsed head is a single "### <glyph> `name`" line, so body
        -- content starts one row below it. Execute/search override this to
        -- skip their command fence (found below).
        local body_start = start_row + 1
        if kind == "execute" or kind == "search" then
            -- Find the closing fence to skip the command code fence. The
            -- fence width is dynamic (safe_fence bumps it past any backtick
            -- runs in the command), so match any backtick-only line.
            for i = start_row + 2, end_row - 1 do
                local l = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
                if l and l:match("^`+$") then
                    body_start = i + 1
                    break
                end
            end
        end

        -- Execute blocks with ANSI codes get per-character colour highlights
        if ansi_highlights then
            -- The generic body_start above stops at the *command* fence's
            -- closing ``` , landing on the ```console body-fence-open line.
            -- ANSI spans are indexed from the first body *content* line, so
            -- advance past the console fence (mirrors the search_ansi path
            -- below). Without this the colours render one row too high.
            local ansi_body_start = body_start
            for i = start_row + 2, end_row - 1 do
                local l =
                    vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
                if l and l:match("^`+console") then
                    ansi_body_start = i + 1
                    break
                end
            end
            Ansi.apply_highlights(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                ansi_body_start,
                ansi_highlights
            )
        else
            -- Apply Comment highlight for body lines outside code fences.
            -- Sidecar markdown bodies (fetch/WebSearch/SubAgent) are dimmed by
            -- a separate AgenticDimmedBlock extmark set in the writer. Other
            -- fences (zsh, console) keep their injected syntax highlights.
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
---
--- `col_hl` keys are byte offsets into the *unformatted* source line.
--- Callers that reformat lines (e.g. `format_tables_in_lines`) must drop
--- col_hl for any rewritten line — column positions don't survive padding
--- or wrapping. The bounds-check below is a final safety net for the case
--- where a reformat produces a shorter line.
--- @param bufnr integer
--- @param buffer_line integer 0-indexed buffer row
--- @param col_hl table<integer, string>
local function apply_block_col_highlights(bufnr, buffer_line, col_hl)
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        buffer_line,
        buffer_line + 1,
        false
    )[1]
    if not line then
        return
    end
    local line_len = #line

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
        if start_col < line_len then
            if end_col > line_len then
                end_col = line_len
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
        end
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
--- @param ordinal? string 2-cell sign stamped on every body row in place of the │ border (subagent ordinal); nil leaves the plain border. The ╭─/╰─ corner rows keep their signs
--- @return integer[] decoration_extmark_ids
function M.render_decorations(bufnr, start_row, end_row, ordinal)
    return ExtmarkBlock.render_block(bufnr, NS_DECORATIONS, {
        header_line = start_row,
        body_start = start_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
        ordinal = ordinal,
    })
end

--- Overwrite the border sign at `row` of an already-rendered block, reusing the
--- decoration extmark id. Backfills a subagent ordinal onto a block that
--- rendered before concurrent-subagent numbering activated.
--- @param bufnr integer
--- @param extmark_id integer
--- @param row integer 0-indexed buffer row
--- @param sign_text string 2-cell sign
function M.restamp_border(bufnr, extmark_id, row, sign_text)
    ExtmarkBlock.set_sign(
        bufnr,
        NS_DECORATIONS,
        extmark_id,
        row,
        sign_text,
        Theme.HL_GROUPS.CODE_BLOCK_FENCE
    )
end

--- Register a dim extmark spanning a body range. Lines are highlighted with
--- AgenticDimmedBlock to de-emphasise sidecar content (fetch/WebSearch/SubAgent).
--- Returns the extmark id so callers can track it for clearing alongside
--- other decoration extmarks.
--- @param bufnr integer
--- @param start_row integer Absolute buffer row (0-indexed)
--- @param end_row integer Absolute buffer row (0-indexed), inclusive
--- @return integer extmark_id
function M.set_dim_range(bufnr, start_row, end_row)
    return vim.api.nvim_buf_set_extmark(bufnr, NS_DECORATIONS, start_row, 0, {
        end_row = end_row + 1,
        end_col = 0,
        hl_group = "AgenticDimmedBlock",
        hl_eol = true,
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
