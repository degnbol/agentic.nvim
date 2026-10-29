local AcpKind = require("agentic.utils.acp_kind")
local Ansi = require("agentic.utils.ansi")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local Glyphs = require("agentic.glyphs")
local Theme = require("agentic.theme")

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

--- The glyph carrying an ACP kind's identity, stamped as the sign on the
--- block's opening row (see `render_decorations`).
--- @param kind string
--- @return string
local function kind_glyph(kind)
    return Glyphs.KIND[AcpKind.normalise(kind)] or Glyphs.KIND_DEFAULT
end

-- ---------------------------------------------------------------------------
-- Highlight application
-- ---------------------------------------------------------------------------

--- Place a layout's highlights, ANSI spans and match spans on the block at
--- `start_row`. Match spans take priority over ANSI spans, so search and
--- grep output looks the same with or without ANSI colours.
--- @param bufnr integer
--- @param start_row integer 0-indexed header row
--- @param layout agentic.ui.ToolCallLayout.Layout
function M.apply_block_highlights(bufnr, start_row, layout)
    M.apply_diff_highlights(bufnr, start_row, layout.highlights)

    for _, entry in ipairs(layout.ansi) do
        Ansi.apply_highlights(
            bufnr,
            NS_DIFF_HIGHLIGHTS,
            start_row + entry.first,
            entry.spans,
            150
        )
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    for _, match in ipairs(layout.matches) do
        local row = start_row + match.line_index
        if row < line_count then
            local line_len = #(
                vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
            )
            if match.col_start <= line_len then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_DIFF_HIGHLIGHTS,
                    row,
                    match.col_start,
                    {
                        end_col = math.min(match.col_end, line_len),
                        hl_group = match.hl_group or "AgenticSearchMatch",
                        priority = 200,
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
--- @param highlight_ranges agentic.ui.ToolCallLayout.HighlightRange[]
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
---
--- The icon is optional: `status_icons` is user-configurable and need not cover
--- every `agentic.acp.ToolCallStatus`, so an absent or empty one drops the glyph
--- column rather than padding it with a second space.
--- @param bufnr integer
--- @param footer_line integer 0-indexed footer line number
--- @param status string Status value (pending, completed, etc.)
--- @param note string|nil Text after the status, set off by " · "
function M.apply_status_footer(bufnr, footer_line, status, note)
    if not vim.api.nvim_buf_is_valid(bufnr) or not status or status == "" then
        return
    end

    local icon = (Config.status_icons or {})[status]
    local status_text = string.format(" %s ", status)
    if icon and icon ~= "" then
        status_text = string.format(" %s %s ", icon, status)
    end
    local note_text = note and ("· " .. note .. " ") or ""

    local current = vim.api.nvim_buf_get_lines(
        bufnr,
        footer_line,
        footer_line + 1,
        false
    )[1] or ""

    -- A mark over the replaced text would stretch over the whole new line.
    vim.api.nvim_buf_clear_namespace(
        bufnr,
        NS_STATUS,
        footer_line,
        footer_line + 1
    )
    vim.api.nvim_buf_set_text(
        bufnr,
        footer_line,
        0,
        footer_line,
        #current,
        { status_text .. note_text }
    )

    vim.api.nvim_buf_set_extmark(bufnr, NS_STATUS, footer_line, 0, {
        end_col = #status_text,
        hl_group = Theme.get_status_hl_group(status),
    })
    if note then
        vim.api.nvim_buf_set_extmark(
            bufnr,
            NS_STATUS,
            footer_line,
            #status_text,
            {
                end_col = #status_text + #note_text,
                hl_group = Theme.HL_GROUPS.FOOTER_NOTE,
            }
        )
    end
end

-- ---------------------------------------------------------------------------
-- Region signs
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

--- Stamp a tool call block's region signs: the kind glyph on its header row,
--- the `│`/`╰─` rail below. The glyph gets its own highlight — the rail's
--- CODE_BLOCK_FENCE (→ NonText) would dim the identity along with the frame.
--- @param bufnr integer
--- @param start_row integer
--- @param end_row integer
--- @param kind string ACP tool kind, supplying the header row's identity glyph
--- @return integer[] decoration_extmark_ids
function M.render_decorations(bufnr, start_row, end_row, kind)
    return ExtmarkBlock.render_block(bufnr, NS_DECORATIONS, {
        header_line = start_row,
        header_sign = kind_glyph(kind) .. " ",
        header_hl_group = Theme.HL_GROUPS.GLYPH_AGENT,
        body_start = start_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

--- Overwrite the border sign at `row` of an already-rendered region, reusing the
--- decoration extmark id so the row does not end up carrying two signs.
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
