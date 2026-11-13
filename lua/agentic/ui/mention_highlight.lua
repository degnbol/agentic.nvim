local FileSystem = require("agentic.utils.file_system")
local Mention = require("agentic.utils.mention")
local SessionRegistry = require("agentic.session_registry")
local Theme = require("agentic.theme")

--- Highlights `@path` mentions in session chat and input buffers. The `@` is
--- always highlighted; the path only when it names an existing file or
--- directory, resolved against the session cwd as the agent does.
--- @class agentic.ui.MentionHighlight
local MentionHighlight = {}

local NS = vim.api.nvim_create_namespace("agentic_mention_highlight")

--- Below treesitter, so code colours inside fences win and the underline
--- combines with them.
local PRIORITY = vim.hl.priorities.treesitter - 1

local FILETYPES = { AgenticChat = true, AgenticInput = true }

--- @param bufnr integer
--- @param row integer 0-based
--- @param col integer
--- @param end_col integer
--- @param hl_group string
local function highlight(bufnr, row, col, end_col, hl_group)
    vim.api.nvim_buf_set_extmark(bufnr, NS, row, col, {
        end_col = end_col,
        hl_group = hl_group,
        ephemeral = true,
        priority = PRIORITY,
    })
end

--- Register the decoration provider. It acts on AgenticChat and AgenticInput
--- buffers of a session, except a subagent message input, where `@path`
--- stays text. Registering again replaces it.
function MentionHighlight.register()
    vim.api.nvim_set_decoration_provider(NS, {
        on_win = function(_, _, bufnr)
            return FILETYPES[vim.bo[bufnr].filetype] == true
                and vim.b[bufnr].agentic_window ~= "message"
                and SessionRegistry.owner_of_buf(bufnr) ~= nil
        end,
        on_range = function(_, _, bufnr, begin_row, _, end_row, end_col)
            local owner = SessionRegistry.owner_of_buf(bufnr)
            if not owner then
                return
            end
            local last_row = end_col > 0 and end_row or end_row - 1
            local lines = vim.api.nvim_buf_get_lines(
                bufnr,
                begin_row,
                last_row + 1,
                false
            )
            for i, line in ipairs(lines) do
                local row = begin_row + i - 1
                for _, span in ipairs(Mention.spans(line)) do
                    local path_col = span.at_col + 1
                    highlight(
                        bufnr,
                        row,
                        span.at_col,
                        path_col,
                        Theme.HL_GROUPS.MENTION_PREFIX
                    )
                    local abs_path = FileSystem.resolve(span.path, owner:cwd())
                    -- Uncached: each redraw stats only the drawn mentions.
                    if vim.uv.fs_stat(abs_path) then
                        highlight(
                            bufnr,
                            row,
                            path_col,
                            path_col + #span.path,
                            Theme.HL_GROUPS.MENTION
                        )
                    end
                end
            end
        end,
    })
end

return MentionHighlight
