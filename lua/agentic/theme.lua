--- @class agentic.Theme
local Theme = {}

-- All programmatic highlighting in the chat buffer uses extmarks (NS_STATUS,
-- NS_DECORATIONS, NS_DIFF_HIGHLIGHTS, ...) rather than vim syntax rules:
-- treesitter clears `vim.bo.syntax` on `vim.treesitter.start()` and the chat
-- must render with or without a user re-enabling it. Highlight group
-- definitions below are set via `nvim_set_hl`, which works regardless.
Theme.HL_GROUPS = {
    DIFF_DELETE = "AgenticDiffDelete",
    DIFF_ADD = "AgenticDiffAdd",
    DIFF_DELETE_WORD = "AgenticDiffDeleteWord",
    DIFF_ADD_WORD = "AgenticDiffAddWord",
    STATUS_PENDING = "AgenticStatusPending",
    STATUS_COMPLETED = "AgenticStatusCompleted",
    STATUS_FAILED = "AgenticStatusFailed",
    CODE_BLOCK_FENCE = "AgenticCodeBlockFence",

    TOOL_KIND = "AgenticToolKind",
    TOOL_ARGUMENT = "AgenticToolArgument",
    DIMMED_BLOCK = "AgenticDimmedBlock",
    SEARCH_MATCH = "AgenticSearchMatch",
    GREP_PATH = "AgenticGrepPath",
    GREP_LINE_NR = "AgenticGrepLineNr",
    GREP_SEPARATOR = "AgenticGrepSeparator",
    SLASH_COMMAND_PREFIX = "AgenticSlashCommandPrefix",
    SLASH_COMMAND = "AgenticSlashCommand",
    MENTION_PREFIX = "AgenticMentionPrefix",
    MENTION = "AgenticMention",
    ERROR_HEADING = "AgenticErrorHeading",
    ERROR_BODY = "AgenticErrorBody",
    PICKER_DATE = "AgenticPickerDate",
    PICKER_DELIM = "AgenticPickerDelim",
    UNAPPROVED_COMMAND = "AgenticUnapprovedCommand",
    TURN_USAGE = "AgenticTurnUsage",
}

local status_hl = {
    pending = Theme.HL_GROUPS.STATUS_PENDING,
    in_progress = Theme.HL_GROUPS.STATUS_PENDING,
    completed = Theme.HL_GROUPS.STATUS_COMPLETED,
    failed = Theme.HL_GROUPS.STATUS_FAILED,
}

function Theme.setup()
    -- stylua: ignore start
    local highlights = {
        -- Diff highlights
        { Theme.HL_GROUPS.DIFF_DELETE, { link = "DiffDelete" } },
        { Theme.HL_GROUPS.DIFF_ADD, { link = "DiffAdd" } },
        { Theme.HL_GROUPS.DIFF_DELETE_WORD, { link = "DiffText" } },
        { Theme.HL_GROUPS.DIFF_ADD_WORD, { link = "DiffText" } },

        -- Status highlights
        { Theme.HL_GROUPS.STATUS_PENDING, { link = "DiagnosticVirtualTextHint" } },
        { Theme.HL_GROUPS.STATUS_COMPLETED, { link = "DiagnosticVirtualTextOk" } },
        { Theme.HL_GROUPS.STATUS_FAILED, { link = "DiagnosticVirtualTextError" } },
        { Theme.HL_GROUPS.CODE_BLOCK_FENCE, { link = "NonText" } },

        -- Tool call header highlights
        { Theme.HL_GROUPS.TOOL_KIND, { link = "Function" } },
        { Theme.HL_GROUPS.TOOL_ARGUMENT, { link = "String" } },

        -- Sidecar body dim (fetch/WebSearch/SubAgent output)
        { Theme.HL_GROUPS.DIMMED_BLOCK, { link = "Comment" } },

        -- Search match highlight
        { Theme.HL_GROUPS.SEARCH_MATCH, { link = "Search" } },

        -- Grep output component highlights
        { Theme.HL_GROUPS.GREP_PATH, { link = "@string.special.path" } },
        { Theme.HL_GROUPS.GREP_LINE_NR, { link = "LineNr" } },
        { Theme.HL_GROUPS.GREP_SEPARATOR, { link = "Delimiter" } },

        -- Input buffer highlights
        { Theme.HL_GROUPS.SLASH_COMMAND_PREFIX, { link = "@punctuation.special" } },
        { Theme.HL_GROUPS.SLASH_COMMAND, { link = "@function.call" } },
        { Theme.HL_GROUPS.MENTION_PREFIX, { link = "@punctuation.special" } },
        { Theme.HL_GROUPS.MENTION, { link = "@string.special.path" } },

        -- Error highlights
        { Theme.HL_GROUPS.ERROR_HEADING, { link = "DiagnosticError" } },
        { Theme.HL_GROUPS.ERROR_BODY, { link = "DiagnosticVirtualTextError" } },

        -- Picker highlights (session restore quickfix)
        { Theme.HL_GROUPS.PICKER_DATE, { link = "Comment" } },
        { Theme.HL_GROUPS.PICKER_DELIM, { link = "Delimiter" } },

        -- Unapproved parts of an execute permission prompt
        { Theme.HL_GROUPS.UNAPPROVED_COMMAND, { link = "DiagnosticVirtualTextWarn" } },

        -- Per-turn token-usage footer
        { Theme.HL_GROUPS.TURN_USAGE, { link = "Comment" } },
    }
    -- stylua: ignore end

    for _, hl in ipairs(highlights) do
        hl[2].default = true
        vim.api.nvim_set_hl(0, hl[1], hl[2])
    end
end

--- Treesitter injection name for a path's markdown code fence, via neovim's
--- own filetype engine. `vim.filetype.match` returns the filetype (`sh`);
--- `get_lang` converts it to the parser/injection name (`bash`) the fence
--- needs. Returns "" for unrecognised files (e.g. extensionless).
--- @param file_path string
--- @param contents string[]|nil Body lines, used as a fallback when the
---        filename alone doesn't resolve a type (e.g. extensionless files
---        whose type is content-defined, like zsh `#compdef` completions).
---        Filename/extension still wins; contents only fills the gap.
--- @return string language
function Theme.get_language_from_path(file_path, contents)
    local ft = vim.filetype.match({ filename = file_path, contents = contents })
    return ft and vim.treesitter.language.get_lang(ft) or ""
end

--- @param status string
--- @return string hl_group
function Theme.get_status_hl_group(status)
    return status_hl[status] or "Comment"
end

return Theme
