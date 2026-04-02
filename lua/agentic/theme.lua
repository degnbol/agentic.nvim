local FileSystem = require("agentic.utils.file_system")

--- @alias agentic.Theme.SpinnerState "generating" | "thinking" | "searching" | "busy"

--- @class agentic.Theme
local Theme = {}

Theme.HL_GROUPS = {
    DIFF_DELETE = "AgenticDiffDelete",
    DIFF_ADD = "AgenticDiffAdd",
    DIFF_DELETE_WORD = "AgenticDiffDeleteWord",
    DIFF_ADD_WORD = "AgenticDiffAddWord",
    STATUS_PENDING = "AgenticStatusPending",
    STATUS_COMPLETED = "AgenticStatusCompleted",
    STATUS_FAILED = "AgenticStatusFailed",
    CODE_BLOCK_FENCE = "AgenticCodeBlockFence",
    SPINNER_GENERATING = "AgenticSpinnerGenerating",
    SPINNER_THINKING = "AgenticSpinnerThinking",
    SPINNER_SEARCHING = "AgenticSpinnerSearching",
    SPINNER_BUSY = "AgenticSpinnerBusy",

    TOOL_KIND = "AgenticToolKind",
    TOOL_ARGUMENT = "AgenticToolArgument",
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
}

--- A lang map of extension to language identifier for markdown code fences
--- Keep only possible unknown mappings
local lang_map = {
    py = "python",
    rb = "ruby",
    rs = "rust",
    kt = "kotlin",
    htm = "html",
    yml = "yaml",
    jl = "julia",
    sh = "bash",
    typescriptreact = "tsx",
    javascriptreact = "jsx",
    markdown = "md",
}

local status_hl = {
    pending = Theme.HL_GROUPS.STATUS_PENDING,
    in_progress = Theme.HL_GROUPS.STATUS_PENDING,
    completed = Theme.HL_GROUPS.STATUS_COMPLETED,
    failed = Theme.HL_GROUPS.STATUS_FAILED,
}

local spinner_hl = {
    generating = Theme.HL_GROUPS.SPINNER_GENERATING,
    thinking = Theme.HL_GROUPS.SPINNER_THINKING,
    searching = Theme.HL_GROUPS.SPINNER_SEARCHING,
    busy = Theme.HL_GROUPS.SPINNER_BUSY,
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

        -- Spinner highlights
        { Theme.HL_GROUPS.SPINNER_GENERATING, { link = "DiagnosticWarn" } },
        { Theme.HL_GROUPS.SPINNER_THINKING, { link = "Special" } },
        { Theme.HL_GROUPS.SPINNER_SEARCHING, { link = "DiagnosticInfo" } },
        { Theme.HL_GROUPS.SPINNER_BUSY, { link = "Comment" } },
    }
    -- stylua: ignore end

    for _, hl in ipairs(highlights) do
        hl[2].default = true
        vim.api.nvim_set_hl(0, hl[1], hl[2])
    end
end

---Get language identifier from file path for markdown code fences
--- @param file_path string
--- @return string language
function Theme.get_language_from_path(file_path)
    local ext = FileSystem.get_file_extension(file_path)
    if not ext or ext == "" then
        return ""
    end

    return lang_map[ext] or ext
end

--- @param status string
--- @return string hl_group
function Theme.get_status_hl_group(status)
    return status_hl[status] or "Comment"
end

--- @param state agentic.Theme.SpinnerState
--- @return string hl_group
function Theme.get_spinner_hl_group(state)
    return spinner_hl[state] or Theme.HL_GROUPS.SPINNER_GENERATING
end

return Theme
