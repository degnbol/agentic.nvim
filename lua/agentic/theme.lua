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

    HEADING = "AgenticHeading",
    GLYPH_USER = "AgenticGlyphUser",
    GLYPH_AGENT = "AgenticGlyphAgent",
    GLYPH_OFF = "AgenticGlyphOff",
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
    QUEUED_REGION = "AgenticQueuedRegion",
    ACTIVITY_CREATE = "AgenticActivityCreate",
    ACTIVITY_EDIT = "AgenticActivityEdit",
    ACTIVITY_DELETE = "AgenticActivityDelete",
    ACTIVITY_READ = "AgenticActivityRead",
    ACTIVITY_UNSEEN = "AgenticActivityUnseen",
}

local status_hl = {
    pending = Theme.HL_GROUPS.STATUS_PENDING,
    in_progress = Theme.HL_GROUPS.STATUS_PENDING,
    completed = Theme.HL_GROUPS.STATUS_COMPLETED,
    failed = Theme.HL_GROUPS.STATUS_FAILED,
}

--- Group the user-side identity glyphs follow: `Prompt` where the colorscheme
--- defines it, `Normal` otherwise. `Prompt` is not one of neovim's own groups,
--- and a link to an undefined group resolves to nothing — the sign would drop
--- through to SignColumn, dimmer than the row it announces.
--- @return string
local function user_glyph_source()
    local prompt = vim.api.nvim_get_hl(0, { name = "Prompt" })
    return vim.tbl_isempty(prompt) and "Normal" or "Prompt"
end

--- Definition for the struck-through glyph group: the user glyph's foreground
--- struck through, or a plain link to the un-struck group when `source` has no
--- foreground to strike.
--- @param source string Group the user glyphs take their colour from
--- @return vim.api.keyset.highlight
local function glyph_off_hl(source)
    local fg = vim.api.nvim_get_hl(0, { name = source, link = false }).fg
    if not fg then
        return { link = Theme.HL_GROUPS.GLYPH_USER }
    end
    return { fg = fg, strikethrough = true }
end

--- What this module last wrote to each group, as `nvim_get_hl` reads it back.
--- A group still matching its entry is one nobody has touched since; anything
--- else belongs to the colorscheme or the user.
--- @type table<string, table>
local applied = {}

--- Define a highlight group, unless somebody else already owns it.
---
--- `default = true` cannot express that, for two reasons. It is a no-op on a
--- group that already exists, and nothing guarantees one was cleared first:
--- `:colorscheme` only sources `colors/{name}` (`:help :colorscheme`), and
--- running `:highlight clear` is a convention of the scheme file that a
--- generated or minimal scheme may skip. Where nothing clears, the first
--- setup's definitions stand for the rest of the session — a group resolved
--- before the colorscheme loaded keeps that first answer, pointing at `Normal`
--- because `Prompt` did not exist yet, or striking through a foreground the
--- scheme has since replaced. Recording each write instead lets a later setup
--- re-derive its own groups while still yielding to everyone else's.
---
--- Writing no `default` flag is what keeps that record comparable: nvim reports
--- the flag back as part of a group's definition and `:colorscheme` strips it
--- from every group it leaves standing, so a recorded flag would go missing
--- underneath us and read as somebody else's definition.
--- @param name string
--- @param definition vim.api.keyset.highlight
local function set_hl(name, definition)
    local current = vim.api.nvim_get_hl(0, { name = name })
    if not vim.tbl_isempty(current) and not vim.deep_equal(current, applied[name]) then
        return
    end
    vim.api.nvim_set_hl(0, name, definition)
    applied[name] = vim.api.nvim_get_hl(0, { name = name })
end

function Theme.setup()
    local user_glyph = user_glyph_source()

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

        -- Chat section heading markers (`##` prompt, `###` tool call). Linked
        -- from the chat window's winhighlight (`@markup.heading.N.agentic`),
        -- which the markdown highlighter captures over the `##`/`###` marker
        -- only — the heading text is remapped to Normal there, and the
        -- tool-call name keeps its markdown_inline `@markup.raw` colour. So
        -- being a heading (a treesitter-context anchor) is decoupled from
        -- looking important. Retarget this group to restyle the markers.
        { Theme.HL_GROUPS.HEADING, { link = "@punctuation.special" } },

        -- Identity glyphs in the sign column, split by whose row they open:
        -- the user's `❯` prompt and command notices, the agent's tool calls.
        -- An omitted `sign_hl_group` falls through to SignColumn, which is
        -- dimmer than the text the glyph announces — hence an explicit group
        -- rather than no group at all.
        { Theme.HL_GROUPS.GLYPH_USER, { link = user_glyph } },
        { Theme.HL_GROUPS.GLYPH_AGENT, { link = "Normal" } },

        -- The same user glyph for a command that undid its own effect
        -- (`/trust` with no argument). Not a link: nvim_set_hl ignores every
        -- other field when `link` is set, so the strikethrough needs a
        -- resolved colour, an attribute-only group having no foreground of its
        -- own to strike (it falls through to SignColumn, dimmer than the glyph
        -- it pairs with). A colorscheme that leaves the source group to the
        -- terminal resolves to no foreground at all, and nothing can be
        -- inherited then, so that case trades the strikethrough away rather
        -- than the colour.
        { Theme.HL_GROUPS.GLYPH_OFF, glyph_off_hl(user_glyph) },

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

        -- Input-buffer regions queued for dispatch at the next turn Stop.
        -- Full-width (hl_eol) diff-style background, so DiffChange fits.
        { Theme.HL_GROUPS.QUEUED_REGION, { link = "DiffChange" } },

        -- File activity panel: the op-class marker on each row, and the dot
        -- marking rows changed since the panel was last open. Linked to the
        -- foreground-only Added/Changed/Removed rather than the Diff*
        -- background groups — these highlight a one-character marker, not a
        -- diff line.
        { Theme.HL_GROUPS.ACTIVITY_CREATE, { link = "Added" } },
        { Theme.HL_GROUPS.ACTIVITY_EDIT, { link = "Changed" } },
        { Theme.HL_GROUPS.ACTIVITY_DELETE, { link = "Removed" } },
        { Theme.HL_GROUPS.ACTIVITY_READ, { link = "Comment" } },
        { Theme.HL_GROUPS.ACTIVITY_UNSEEN, { link = "DiagnosticHint" } },
    }
    -- stylua: ignore end

    for _, hl in ipairs(highlights) do
        set_hl(hl[1], hl[2])
    end

    -- A colorscheme that clears drops the groups defined here, leaving the
    -- extmarks that name them unhighlighted until the next restart; one that
    -- does not clear leaves them resolved against the colours of the scheme
    -- before it. Redefining covers both — see `set_hl` for why `default = true`
    -- cannot. `clear = true` keeps this to one autocmd across repeat calls.
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("agentic_theme", { clear = true }),
        callback = Theme.setup,
    })
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
