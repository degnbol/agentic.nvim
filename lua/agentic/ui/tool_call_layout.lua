local AcpKind = require("agentic.utils.acp_kind")
local Ansi = require("agentic.utils.ansi")
local CanonicalToolCall = require("agentic.acp.canonical_tool_call")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local GrepHighlights = require("agentic.utils.grep_highlights")
local GrepOutput = require("agentic.utils.grep_output")
local GrepRegex = require("agentic.utils.grep_regex")
local JsonDisplay = require("agentic.utils.json_display")
local MarkdownGuard = require("agentic.utils.markdown_guard")
local PermissionRules = require("agentic.utils.permission_rules")
local ShellFormat = require("agentic.utils.shell_format")
local TextWrap = require("agentic.utils.text_wrap")
local ToolCallDiff = require("agentic.ui.tool_call_diff")
local Treesitter = require("agentic.utils.treesitter")
local ZshParseGuard = require("agentic.utils.zsh_parse_guard")

--- The rows of a tool call block and the ranges, spans and fold placed on
--- them, computed without a buffer.
--- @class agentic.ui.ToolCallLayout
local M = {}

--- The fold state a foldable block takes at render.
--- @alias agentic.ui.FoldState "open"|"closed"

--- @class agentic.ui.ToolCallLayout.HighlightRange
--- @field type "comment"|"error"|"old"|"new"|"new_modification"|"table_row_end" Type of highlight to apply
--- @field line_index integer 0-based row index
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)
--- @field block_col_hl? table<integer, string> Byte-col → language-qualified capture name from context-aware treesitter parse

--- A run of rows in a block, with everything that points into them.
--- @class agentic.ui.ToolCallLayout.Section
--- @field rows string[]
--- @field lang? string Fence language; nil leaves the rows unfenced, "" fences with an empty language
--- @field fold? agentic.ui.FoldState Fold state; adds `-fold` to the info string
--- @field difffold? boolean Info-string marker is `-difffold` instead of `-fold`: foldable, never injected
--- @field dim? boolean Dim the rows with AgenticDimmedBlock
--- @field highlights? agentic.ui.ToolCallLayout.HighlightRange[] `line_index` 0-based within `rows`
--- @field ansi? agentic.utils.Ansi.Span[][] Spans per row of `rows`
--- @field matches? agentic.utils.GrepHighlights.Match[] `line_index` 0-based within `rows`

--- The rows of one tool call block and everything placed on them.
--- All indices are 0-based offsets from the header row.
--- @class agentic.ui.ToolCallLayout.Layout
--- @field lines string[] Header first; the last row is the footer, "" until the status is written
--- @field highlights agentic.ui.ToolCallLayout.HighlightRange[]
--- @field ansi { first: integer, spans: agentic.utils.Ansi.Span[][] }[] Spans for the rows from each `first`
--- @field matches agentic.utils.GrepHighlights.Match[]
--- @field fold? { anchor: integer, state: agentic.ui.FoldState } `anchor` is the first row inside the fold
--- @field dim? [integer, integer] First and last dimmed row
--- @field diff_blocks? agentic.ui.ToolCallDiff.DiffBlock[] Matched hunks, nil when none matched

--- A call as the section builders read it.
--- @class agentic.ui.ToolCallLayout.Call
--- @field block agentic.ui.MessageWriter.ToolCallBlock
--- @field kind string `AcpKind.normalise(block.kind)`
--- @field argument string `block.argument` without the kind prefix
--- @field wrap_width integer 0 = soft wrap
--- @field failure? string[] `failure_reason` of a failed call; nil when not failed or empty
--- @field head_line? integer Line appended to a path head as `path:N`
--- @field diff? { hunks: agentic.ui.ToolCallDiff.DiffBlock[], source_lines: string[], is_create: boolean }

--- @alias agentic.ui.ToolCallLayout.Builder fun(call: agentic.ui.ToolCallLayout.Call): agentic.ui.ToolCallLayout.Section[]

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

--- Strip redundant kind prefix from an argument string.
--- The header already shows the kind, so "Read filename.txt" → "filename.txt".
---
--- Only a title the bridge wrote is stripped, so only a kind the bridge
--- assigned qualifies (`AcpKind.PROTOCOL_KINDS`). Against a head an adapter
--- built itself the strip can only misfire — a `Monitor` whose description
--- opens "Monitor the CI run" would render as "the CI run".
--- @param kind string ACP tool kind
--- @param argument string|nil
--- @return string
local function strip_kind_prefix(kind, argument)
    if not argument or argument == "" then
        return ""
    end
    if not AcpKind.PROTOCOL_KINDS[AcpKind.normalise(kind)] then
        return argument
    end
    local display = display_kind(kind)
    if argument:sub(1, #display + 1):lower() == display:lower() .. " " then
        return argument:sub(#display + 2)
    end
    return argument
end

--- Kinds whose heading name is a path, URL, command, identifier or expression
--- rather than prose. They take the code-span guard unconditionally: a column
--- of file heads that switched on whether one filename happened to contain an
--- emphasised path component would read as arbitrary, the guard being invisible
--- (`conceallevel=2` hides the delimiters) yet carrying the name's colour. The
--- file-mutating half has to match `SessionManager`'s own list of them, or the
--- same path renders guarded under `read` and bare under `delete`.
---
--- Prose kinds — an `execute` description, a `switch_mode` label, a `SubAgent`
--- line, a `Skill` name, a `SlashCommand` line (bare, like the user's own
--- `/command` prompt), and the generic title bucket — guard only the words
--- that hold a markdown-special character. That bucket cannot be typed either
--- way: an adapter's fallback yields `rawInput.command` or `update.title`
--- under one kind (see `ClaudeAgentACPAdapter:__build_tool_call_update`), so a
--- bare command still reaches a prose-typed head.
--- @type table<string, boolean>
local CODE_KINDS = {
    read = true,
    edit = true,
    create = true,
    write = true,
    delete = true,
    move = true,
    fetch = true,
    search = true,
    mcp = true,
    taskcontrol = true,
    cron = true,
}

--- Build the collapsed tool-call heading: `` ### name ``. The kind identity
--- lives in the sign column, so the heading text is only the informative
--- content (filename / description / command) that treesitter-context pins as a
--- breadcrumb. A `CODE_KINDS` name is wrapped whole in a code span. A prose
--- name has each word guarded that holds a markdown-special character.
---
--- An empty `name` yields a bare `###` — used before the argument has streamed
--- in, for execute calls with no model description, and for search calls with
--- no pattern (the command already shows in the fence below). That is
--- byte-identical to the section-close boundary `write_message_chunk` emits,
--- and has to stay so: both are fence-less and uncaptured by
--- `queries/agentic/context.scm`, so the enclosing `## prompt` keeps the
--- breadcrumb either way.
---
--- When `truncate` is set, `name` is clamped to `wrap_width` (or 80 when
--- soft-wrapping) minus everything the rendered line spends on the frame, and
--- one cell for the ellipsis. That is a single screen line only while
--- `wrap_width` fits the window — `min_wrap_width` can hold it above the width
--- of a narrow chat window.
--- @param kind string normalised kind
--- @param name string
--- @param wrap_width integer
--- @param truncate boolean
--- @return string
local function collapsed_header(kind, name, wrap_width, truncate)
    if name == "" then
        return "###"
    end
    local width = truncate and (wrap_width > 0 and wrap_width or 80) - #"### "
        or math.huge
    return "### "
        .. (
            CODE_KINDS[kind] and MarkdownGuard.whole_within(name, width)
            or MarkdownGuard.words_within(name, width)
        )
end

--- @type table<agentic.ui.MessageWriter.SubagentMode, string>
local SUBAGENT_MODE_TEXT = {
    background = "Background",
    blocking = "Blocking",
}

--- Display text of a subagent's execution mode: `Background` or `Blocking`,
--- with a trailing `?` while the mode is only predicted.
--- @param subagent agentic.ui.MessageWriter.SubagentInfo
--- @return string
local function subagent_mode_text(subagent)
    return SUBAGENT_MODE_TEXT[subagent.mode]
        .. (subagent.confirmed and "" or "?")
end

--- Heading text of a subagent: `<mode text> <agent type> · <label>`, without
--- the type while it is unknown, with the label `Agent` when it has none, and
--- `Agent` alone when nothing is known.
--- @param subagent agentic.ui.MessageWriter.SubagentInfo|nil
--- @return string
function M.subagent_heading(subagent)
    if not subagent then
        return "Agent"
    end
    return string.format(
        "%s %s%s",
        subagent_mode_text(subagent),
        subagent.agent_type and (subagent.agent_type .. " · ") or "",
        subagent.label or "Agent"
    )
end

--- Fence info-string for a shell command. Normally the shell label, but the
--- chat buffer injects that label as the tree-sitter-zsh parser (zsh is aliased
--- to bash), which hangs the editor forever on the `${…/…[…)` shape (see
--- ZshParseGuard). Fall back to a non-injecting "text" label on that shape so
--- the command still renders, without syntax colouring.
--- @param argument string Shell command text
--- @param lang string Shell label to use when the command is safe to inject
--- @return string
local function shell_fence_lang(argument, lang)
    if ZshParseGuard.contains_hang_trigger(argument) then
        return "text"
    end
    return lang
end

--- First single- or double-quoted string in a command, unquoted, skipping
--- empty ones, unmatched quotes (`don't`) and a value attached to an option by
--- `=` (`--include="*.lua"`).
--- @param argument string|nil
--- @return string|nil
local function first_quoted_string(argument)
    local pos = 1
    while argument do
        local open, quote = argument:match("()([\"'])", pos)
        if not open then
            return nil
        end
        local close = argument:find(quote, open + 1, true)
        if not close then
            pos = open + 1
        elseif close > open + 1 and argument:sub(open - 1, open - 1) ~= "=" then
            return argument:sub(open + 1, close - 1)
        else
            pos = close + 1
        end
    end
    return nil
end

--- Flags of a search-block title, read as the space-separated words before
--- its first quoted word. In the Claude Grep title ` -P` means multiline.
--- @param argument string
--- @return { ignore_case: boolean, multiline: boolean }
local function search_title_flags(argument)
    local flags = { ignore_case = false, multiline = false }
    for word in argument:gmatch("%S+") do
        if word:find("^[\"']") then
            break
        end
        flags.ignore_case = flags.ignore_case or word == "-i"
        flags.multiline = flags.multiline or word == "-P"
    end
    return flags
end

--- Place sections in order, fence each one that has a `lang` with
--- `TextWrap.safe_fence(section.rows)`, shift every index by the section's
--- first content row (after the opening fence; also the fold anchor), and
--- append the footer row. At most one section may fold.
--- @param sections agentic.ui.ToolCallLayout.Section[]
--- @return agentic.ui.ToolCallLayout.Layout
local function assemble(sections)
    --- @type agentic.ui.ToolCallLayout.Layout
    local layout = { lines = {}, highlights = {}, ansi = {}, matches = {} }
    local lines = layout.lines
    for _, section in ipairs(sections) do
        local fence = section.lang and TextWrap.safe_fence(section.rows)
        if fence then
            local marker = section.difffold and "-difffold"
                or section.fold and "-fold"
                or ""
            table.insert(lines, fence .. section.lang .. marker)
        end
        local first = #lines
        vim.list_extend(lines, section.rows)
        for _, range in ipairs(section.highlights or {}) do
            table.insert(
                layout.highlights,
                vim.tbl_extend(
                    "force",
                    range,
                    { line_index = first + range.line_index }
                )
            )
        end
        for _, match in ipairs(section.matches or {}) do
            table.insert(
                layout.matches,
                vim.tbl_extend(
                    "force",
                    match,
                    { line_index = first + match.line_index }
                )
            )
        end
        if section.ansi then
            table.insert(layout.ansi, { first = first, spans = section.ansi })
        end
        if section.fold then
            if layout.fold then
                error("a tool call block holds at most one fold")
            end
            layout.fold = { anchor = first, state = section.fold }
        end
        if section.dim and #section.rows > 0 then
            layout.dim = { first, first + #section.rows - 1 }
        end
        if fence then
            table.insert(lines, fence)
        end
    end
    table.insert(lines, "")
    return layout
end

--- Unfenced rows highlighted as Comment.
--- @param rows string[]
--- @return agentic.ui.ToolCallLayout.Section
local function comment_rows(rows)
    --- @type agentic.ui.ToolCallLayout.HighlightRange[]
    local highlights = {}
    for i = 1, #rows do
        table.insert(highlights, { type = "comment", line_index = i - 1 })
    end
    --- @type agentic.ui.ToolCallLayout.Section
    local section = { rows = rows, highlights = highlights }
    return section
end

--- A failure reason under a `console` fence, each row as `error`.
--- @param reason string[]
--- @return agentic.ui.ToolCallLayout.Section
local function reason_section(reason)
    --- @type agentic.ui.ToolCallLayout.HighlightRange[]
    local highlights = {}
    for i = 1, #reason do
        table.insert(highlights, { type = "error", line_index = i - 1 })
    end
    --- @type agentic.ui.ToolCallLayout.Section
    local section = { rows = reason, lang = "console", highlights = highlights }
    return section
end

--- Tool output under a `console` fence: ANSI escapes turned into spans,
--- folded past `max_lines` (0 = never).
--- @param rows string[] raw output rows
--- @param max_lines integer
--- @return agentic.ui.ToolCallLayout.Section
local function output_section(rows, max_lines)
    local ansi = Ansi.process_lines(rows)
    --- @type agentic.ui.ToolCallLayout.Section
    local section = {
        rows = ansi.has_ansi and ansi.lines or rows,
        lang = "console",
        ansi = ansi.has_ansi and ansi.highlights or nil,
    }
    if max_lines > 0 and #rows > max_lines then
        section.fold = "closed"
    end
    return section
end

--- Text the agent wrote, as dimmed markdown wrapped to the chat width,
--- folded closed when more than one row.
--- @param rows string[]
--- @param wrap_width integer 0 = soft wrap
--- @return agentic.ui.ToolCallLayout.Section
local function prose_section(rows, wrap_width)
    local wrapped, table_row_ends = TextWrap.wrap_prose(rows, wrap_width)
    --- @type agentic.ui.ToolCallLayout.HighlightRange[]
    local highlights = {}
    for _, i in ipairs(table_row_ends) do
        highlights[#highlights + 1] =
            { type = "table_row_end", line_index = i - 1 }
    end
    --- @type agentic.ui.ToolCallLayout.Section
    local section = {
        rows = wrapped,
        lang = "markdown",
        dim = true,
        highlights = highlights,
        -- A one-row body gets no fold (`Folds.levels`), so closing it raises E490.
        fold = #wrapped > 1 and "closed" or nil,
    }
    return section
end

--- @type agentic.ui.ToolCallLayout.Builder
local function default_head(call)
    local name = call.argument:gsub("\n", "\\n")
    if name ~= "" and call.head_line then
        name = name .. ":" .. call.head_line
    end
    return {
        {
            rows = { collapsed_header(call.kind, name, call.wrap_width, false) },
        },
    }
end

--- Fold state of an execute block's one fold over its command and output
--- rows: nil when they total one row (no fold forms), closed when the call
--- did not fail and its command is read-only, or when the output passes
--- `execute_max_lines` (0 = never by length), else open.
--- @param call agentic.ui.ToolCallLayout.Call
--- @param cmd_rows string[]
--- @return agentic.ui.FoldState|nil
local function execute_fold_state(call, cmd_rows)
    local output = call.failure or call.block.body or {}
    if #cmd_rows + #output <= 1 then
        return nil
    end
    local max_lines = Config.tool_call_display.execute_max_lines
    if
        call.block.status ~= "failed"
            and PermissionRules.is_read_only(call.argument)
        or max_lines > 0 and #output > max_lines
    then
        return "closed"
    end
    return "open"
end

--- @type table<string, agentic.ui.ToolCallLayout.Builder>
local HEADS = {
    execute = function(call)
        local block = call.block
        local cmd_rows = vim.split(
            ShellFormat.format(
                call.argument,
                Config.tool_call_display.execute_formatter
            ),
            "\n",
            { plain = true }
        )
        -- Head shows the model's description; when absent it stays bare rather
        -- than repeating the command (which renders in the fence below).
        local description = block.description
        local head_name = (description and description ~= "")
                and vim.split(description, "\n", { plain = true })[1]
            or ""
        return {
            {
                rows = {
                    collapsed_header(
                        call.kind,
                        head_name,
                        call.wrap_width,
                        true
                    ),
                },
            },
            -- The shell label is cosmetic: the zsh parser is aliased to
            -- "bash", so highlighting is identical either way and the label
            -- only shows at conceallevel=0. "bash" keeps it from going blank
            -- on an unknown shell. The fold spans the command and the output
            -- fence after it (folds.scm).
            {
                rows = cmd_rows,
                lang = shell_fence_lang(call.argument, block.shell or "bash"),
                fold = execute_fold_state(call, cmd_rows),
            },
        }
    end,

    search = function(call)
        return {
            {
                rows = {
                    collapsed_header(
                        call.kind,
                        call.block.search_pattern or "",
                        call.wrap_width,
                        true
                    ),
                },
            },
            {
                rows = vim.split(call.argument, "\n", { plain = true }),
                lang = shell_fence_lang(call.argument, "bash"),
            },
        }
    end,

    -- Fetch argument is "URL prompt" — show only the URL. The prompt is
    -- repeated in the body (model instructions to itself).
    fetch = function(call)
        local name = call.argument:match("^(%S+)")
            or call.argument:gsub("\n", "\\n")
        return {
            {
                rows = {
                    collapsed_header(call.kind, name, call.wrap_width, false),
                },
            },
        }
    end,

    -- opencode and mistral-vibe mint `SubAgent` blocks without `subagent`.
    -- With it, the argument is the name of the agent's transcript buffer, on
    -- a row of its own so `gf` on it opens the transcript.
    subagent = function(call)
        local subagent = call.block.subagent
        if not subagent then
            return default_head(call)
        end
        --- @type agentic.ui.ToolCallLayout.Section[]
        local sections = {
            {
                rows = {
                    collapsed_header(
                        call.kind,
                        M.subagent_heading(subagent),
                        call.wrap_width,
                        false
                    ),
                },
            },
        }
        if call.argument ~= "" then
            table.insert(
                sections,
                comment_rows({ (call.argument:gsub("\n", "\\n")) })
            )
        end
        return sections
    end,

    -- The name alone says neither which of several same-named skills was
    -- loaded nor where to read it.
    skill = function(call)
        local sections = default_head(call)
        local skill_path = call.block.skill_path
        if skill_path then
            table.insert(
                sections,
                comment_rows({ FileSystem.to_smart_path(skill_path) })
            )
        end
        return sections
    end,
}

--- The body of a call no kind-specific builder covers: a JSON body through
--- `JsonDisplay`, other text raw under `console`, folded past
--- `other_max_lines`. Rows are not wrapped, so table columns stay aligned.
--- @type agentic.ui.ToolCallLayout.Builder
local function generic_body(call)
    local body = call.block.body
    if not body then
        return {}
    end
    local rows, lang = JsonDisplay.lines(table.concat(body, "\n"))
    --- @type agentic.ui.ToolCallLayout.Section
    local section = { rows = rows or body, lang = lang or "console" }
    local max_lines = Config.tool_call_display.other_max_lines
    if max_lines > 0 and #section.rows > max_lines then
        section.fold = "closed"
    end
    return { section }
end

--- Fetch, WebSearch and SubAgent bodies are informational text the agent
--- wrote to itself: folded when multi-line, dimmed as sidecar content.
--- @type agentic.ui.ToolCallLayout.Builder
local function sidecar_body(call)
    local body = call.block.body
    if not body then
        return {}
    end
    return { prose_section(body, call.wrap_width) }
end

--- @type table<string, agentic.ui.ToolCallLayout.Builder>
local BODIES = {
    -- The content read is not shown, only its extent.
    read = function(call)
        local line_count = call.block.body and #call.block.body or 0
        if line_count == 0 then
            return {}
        end
        local range = call.block.read_range
        local line_info = string.format(
            "Read %d lines",
            range and range.limit or line_count
        )
        if range then
            line_info = line_info
                .. " "
                .. CanonicalToolCall.format_read_range(range)
        end
        return { comment_rows({ line_info }) }
    end,

    -- The `console` fence keeps markdown from parsing `--` and `*`.
    search = function(call)
        local body = call.block.body
        if not body then
            return {}
        end
        local section =
            output_section(body, Config.tool_call_display.search_max_lines)
        local flags = search_title_flags(call.argument)
        local pattern = call.block.search_pattern
            or first_quoted_string(call.argument)
        -- Claude's Grep tool and opencode's grep run ripgrep.
        local translation = pattern
            and not flags.multiline
            and GrepRegex.translate({ pattern }, { "rust" }, nil)
        local matches = GrepHighlights.terms(
            section.rows,
            translation or nil,
            flags.ignore_case,
            GrepOutput.SEARCH_PREFIXES,
            {}
        )
        section.matches = vim.list_extend(
            matches,
            GrepHighlights.prefixes(section.rows, false)
        )
        return { section }
    end,

    -- A failed execute shows its reason as output: the bash stdout/stderr of
    -- a non-zero exit is long and often informational, so it takes the
    -- output's colours rather than the red of a short denial. The command's
    -- fold covers the output (`execute_fold_state`).
    execute = function(call)
        local rows = call.failure or call.block.body
        if not rows then
            return {}
        end
        local section = output_section(rows, 0)
        section.matches =
            GrepHighlights.for_command(section.rows, call.argument)
        return { section }
    end,

    fetch = sidecar_body,
    websearch = sidecar_body,
    subagent = sidecar_body,

    -- A mode switch's body is the agent's instructions to itself.
    switch_mode = function(call)
        local body = call.block.body
        if not body then
            return {}
        end
        return { prose_section(body, call.wrap_width) }
    end,

    -- The todo window shows the rendered todos, so the raw request folds away.
    todowrite = function(call)
        local sections = generic_body(call)
        local section = sections[1]
        if section then
            -- A one-row body gets no fold (`Folds.levels`), so closing it raises E490.
            section.fold = #section.rows > 1 and "closed" or nil
        end
        return sections
    end,
}

--- Diff rows of one hunk, removed rows before added ones, with the highlight
--- range of each.
--- @param hunk agentic.ui.ToolCallDiff.DiffBlock
--- @param source_lines string[] the file the hunk was matched in
--- @param context_lang string|nil language to reparse each side in its file context with; nil skips that
--- @return string[] rows
--- @return agentic.ui.ToolCallLayout.HighlightRange[] highlights `line_index` 0-based within `rows`
local function hunk_rows(hunk, source_lines, context_lang)
    --- @type string[]
    local rows = {}
    --- @type agentic.ui.ToolCallLayout.HighlightRange[]
    local highlights = {}

    --- Append a diff row and its highlight range.
    --- @param content string
    --- @param hl_type "old"|"new"|"new_modification"
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
        table.insert(highlights, {
            line_index = #rows,
            type = hl_type,
            old_line = old_line,
            new_line = new_line,
            block_col_hl = col_hl,
        })
        table.insert(rows, content)
    end

    local old_count = #hunk.old_lines
    local new_count = #hunk.new_lines
    local is_new_file = old_count == 0
    local is_modification = old_count == new_count and old_count > 0

    -- The same splice range works for both old and new: splicing
    -- old_lines back at the matched location reconstructs the pre-edit
    -- file state; splicing new_lines gives the post-edit state.
    local old_map, new_map
    if context_lang and not hunk.unmatched then
        local splice_start = math.max(0, hunk.start_line - 1)
        local splice_end = hunk.end_line
        if not is_new_file then
            old_map = Treesitter.highlight_map_in_context(
                source_lines,
                context_lang,
                splice_start,
                splice_end,
                hunk.old_lines
            )
        end
        new_map = Treesitter.highlight_map_in_context(
            source_lines,
            context_lang,
            splice_start,
            splice_end,
            hunk.new_lines
        )
    end

    if is_new_file then
        for ni, new_line in ipairs(hunk.new_lines) do
            local col_hl = new_map and new_map[ni - 1] or nil
            insert_diff_line(new_line, "new", nil, new_line, col_hl)
        end
    else
        local filtered =
            ToolCallDiff.filter_unchanged_lines(hunk.old_lines, hunk.new_lines)

        for _, pair in ipairs(filtered.pairs) do
            if pair.old_line then
                local col_hl = old_map and old_map[pair.old_idx - 1] or nil
                insert_diff_line(
                    pair.old_line,
                    "old",
                    pair.old_line,
                    is_modification and pair.new_line or nil,
                    col_hl
                )
            end
        end

        for _, pair in ipairs(filtered.pairs) do
            if pair.new_line then
                -- Block-level is_modification doesn't imply per-pair
                -- modification: filter_unchanged_lines can split a
                -- same-line-count block into pure insertions and pure
                -- deletions. Pure insertions have no old_line — emit as
                -- "new" so `DiffHighlighter.find_inline_change` never gets
                -- a nil old line.
                local is_paired_mod = is_modification and pair.old_line ~= nil
                local col_hl = new_map and new_map[pair.new_idx - 1] or nil
                insert_diff_line(
                    pair.new_line,
                    is_paired_mod and "new_modification" or "new",
                    is_paired_mod and pair.old_line or nil,
                    pair.new_line,
                    col_hl
                )
            end
        end
    end
    return rows, highlights
end

--- The diff of a file-mutating call, as ONE foldable section, then the
--- failure reason when the call failed.
--- @type agentic.ui.ToolCallLayout.Builder
local function diff_body(call)
    local block = call.block
    local diff = block.diff
    local call_diff = call.diff
    --- @cast diff -nil
    --- @cast call_diff -nil
    local source_lines = call_diff.source_lines
    local hunks = vim.list_extend({}, call_diff.hunks)

    -- No matching block and a non-empty old_text means the Edit's old_string
    -- isn't in the file. This happens with opencode when the diff data arrives
    -- after the edit has been applied. Render the diff directly from the
    -- old/new arrays without file matching.
    if #hunks == 0 and diff.old and #diff.old > 0 then
        table.insert(hunks, {
            start_line = 1,
            end_line = #diff.old,
            old_lines = diff.old,
            new_lines = diff.new or {},
            -- The old text was not found, so these coordinates index
            -- nothing — splicing at them would fabricate context.
            unmatched = true,
        })
    end

    -- `lang` (inferred from the path) is the fence label and the language for
    -- context-aware highlighting; it is NOT the injection language (see
    -- `difffold`). Strip any path-induced `-fold` suffix (a file named
    -- `foo.x-fold`) so the fence string can't become a pathological
    -- `foo-fold-difffold`. Contents inform the type only when the filename
    -- can't (extensionless files like zsh `#compdef` completions); the file's
    -- own head beats the diff's.
    local lang = Treesitter.language_for_path(
        call.argument,
        #source_lines > 0 and source_lines or diff.new
    )
        :gsub("%-fold$", "")

    -- Context-aware syntax highlighting: the chat buffer's fence injection
    -- only sees the diff lines in isolation, so structurally-dependent
    -- captures (strings, comments, docstrings, language injections —
    -- including code fences embedded in markdown) come out wrong.
    -- Reparsing the snippet spliced back into the surrounding file
    -- reconstructs the correct captures. Falls back silently when no
    -- parser matches the path.
    --
    -- Reparse cost grows with the reconstructed file, so gate on its size.
    -- This bounds one parse, not the render: the map is rebuilt per block
    -- per side, so a multi-block diff still costs 2 × #hunks
    -- reconstructions of a file up to the threshold.
    local context_max = Config.tool_call_display.diff_context_max_lines or 0
    local use_context_highlights = context_max > 0
        and math.max(#source_lines, #diff.new) <= context_max
        and lang ~= ""

    --- @type string[]
    local rows = {}
    --- @type agentic.ui.ToolCallLayout.HighlightRange[]
    local highlights = {}
    for _, hunk in ipairs(hunks) do
        local hunk_lines, hunk_highlights = hunk_rows(
            hunk,
            source_lines,
            use_context_highlights and lang or nil
        )
        for _, range in ipairs(hunk_highlights) do
            range.line_index = range.line_index + #rows
            table.insert(highlights, range)
        end
        vim.list_extend(rows, hunk_lines)
    end

    -- A created file's diff is the whole file, so a large one is closed. An
    -- edit shows only fragments and stays open unless it failed.
    local create_max = Config.tool_call_display.create_max_lines or 0
    local collapse = call_diff.is_create
        and create_max > 0
        and #diff.new > create_max
    local open = block.status ~= "failed" and not collapse

    -- `difffold` folds the diff as ONE block (folds.scm matches `fold$`)
    -- while suppressing language injection (injections.scm excludes
    -- `difffold$`): block_col_hl extmarks already colour the diff at priority
    -- 200, so injecting the base language would only buy a second parse.
    --- @type agentic.ui.ToolCallLayout.Section[]
    local sections = {
        {
            rows = rows,
            lang = lang,
            difffold = true,
            -- A body of one row or none gets no fold (`Folds.levels`).
            fold = #rows > 1 and (open and "open" or "closed") or nil,
            highlights = highlights,
        },
    }
    -- A failed edit keeps the diff, folded closed, with the reason beneath
    -- it, so the user sees both what was attempted and why it failed.
    if call.failure then
        table.insert(sections, reason_section(call.failure))
    end
    return sections
end

--- Lay out a tool call block. Does not modify `block` and writes no buffer.
--- @param block agentic.ui.MessageWriter.ToolCallBlock
--- @param wrap_width integer chat window text width; 0 = soft wrap
--- @return agentic.ui.ToolCallLayout.Layout
function M.build(block, wrap_width)
    local failure = block.failure_reason
    --- @type agentic.ui.ToolCallLayout.Call
    local call = {
        block = block,
        kind = AcpKind.normalise(block.kind),
        argument = strip_kind_prefix(block.kind, block.argument),
        wrap_width = wrap_width,
        failure = block.status == "failed"
                and failure
                and #failure > 0
                and failure
            or nil,
    }

    -- The first line the call touches, appended to the path head as `path:N`
    -- — the shape `gF`, `CTRL-W gF` and file:line plugins parse, which makes
    -- the head a jump target. One line, never a range: a `path:N-M` head
    -- fails the anchored patterns those plugins match with (fileline.nvim uses
    -- `^([^:]+):([0-9:]+)$`), and only `gF`, which scans digits and stops at
    -- the `-`, tolerates it.
    if call.kind == "read" and block.read_range then
        call.head_line = block.read_range.offset
    end

    if block.diff then
        local hunks, source_lines = ToolCallDiff.extract_diff_blocks({
            path = call.argument,
            old_text = block.diff.old,
            new_text = block.diff.new,
            replace_all = block.diff.all,
        })
        -- Both clauses are load-bearing: Write sends no old_string even when
        -- overwriting an existing file (empty diff.old alone would call a
        -- fragment diff a creation), and an unresolved path yields no source
        -- content even though old_string does anchor a fragment.
        local is_create = #source_lines == 0
            and (not block.diff.old or #block.diff.old == 0)
        call.diff = {
            hunks = hunks,
            source_lines = source_lines,
            is_create = is_create,
        }
        -- `start_line` is a coordinate in the matched (pre-edit) source, but
        -- for the *first* hunk pre- and post-edit agree: nothing above it
        -- moved. Later hunks do shift — the second reason the head names one
        -- line only. A creation's diff is the whole file: line 1 is where
        -- every file starts, so the suffix would carry no information.
        if #hunks > 0 and not is_create then
            call.head_line = hunks[1].start_line
        end
    end

    local sections = (HEADS[call.kind] or default_head)(call)
    --- @type agentic.ui.ToolCallLayout.Section[]
    local body
    if block.diff then
        body = diff_body(call)
    elseif call.failure and call.kind ~= "execute" then
        -- The summary a kind normally shows ("Read N lines", search results)
        -- describes what the tool attempted — misleading when it never ran.
        body = { reason_section(call.failure) }
    else
        body = (BODIES[call.kind] or generic_body)(call)
    end
    vim.list_extend(sections, body)

    local layout = assemble(sections)
    -- Captured for diff_jump navigation: re-extracting at gf-press time can
    -- fail once the file's loaded buffer holds post-edit content, where the
    -- old-text matcher finds nothing.
    if call.diff and #call.diff.hunks > 0 then
        layout.diff_blocks = call.diff.hunks
    end
    return layout
end

return M
