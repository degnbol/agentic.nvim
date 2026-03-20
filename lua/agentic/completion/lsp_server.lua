local Config = require("agentic.config")
local States = require("agentic.states")
local Logger = require("agentic.utils.logger")

--- In-process LSP server providing completion for the AgenticInput buffer.
--- Declares `/` and `@` as trigger characters so any LSP-aware completion
--- framework (blink.cmp, nvim-cmp, built-in) picks them up automatically.
--- @class agentic.completion.LspServer
local M = {}

--- LSP CompletionItemKind values (from LSP spec)
local CompletionItemKind = {
    Text = 1,
    Function = 3,
    Field = 5,
    File = 17,
    Keyword = 14,
}

--- Build slash command completion items from the stored commands.
--- @param bufnr integer
--- @param line_text string
--- @param cursor_col integer 0-indexed column
--- @param cursor_line integer 0-indexed line
--- @return table[]
local function get_slash_completions(bufnr, line_text, cursor_col, cursor_line)
    -- Only complete on first line, must start with `/`, no spaces
    if cursor_line ~= 0 then
        return {}
    end

    if not line_text:match("^/[^%s]*$") then
        return {}
    end

    -- Read from specific buffer, not vim.b[0], to be robust in LSP context
    local commands = States.getSlashCommandsForBuffer(bufnr)
    if #commands == 0 then
        return {}
    end

    --- @type table[]
    local items = {}
    for _, cmd in ipairs(commands) do
        table.insert(items, {
            label = "/" .. cmd.word,
            kind = CompletionItemKind.Function,
            detail = cmd.menu,
            filterText = "/" .. cmd.word,
            textEdit = {
                range = {
                    start = { line = 0, character = 0 },
                    ["end"] = { line = 0, character = cursor_col },
                },
                newText = "/" .. cmd.word,
            },
        })
    end

    return items
end

--- Build file completion items from the FilePicker cache.
--- @param bufnr integer
--- @param line_text string
--- @param cursor_col integer 0-indexed column
--- @param cursor_line integer 0-indexed line
--- @return table[]
local function get_file_completions(bufnr, line_text, cursor_col, cursor_line)
    if not Config.file_picker.enabled then
        return {}
    end

    local before_cursor = line_text:sub(1, cursor_col)

    -- Find @ preceded by whitespace or at line start, no spaces after
    local at_match = before_cursor:match("^@[^%s]*$")
        or before_cursor:match("[%s]@[^%s]*$")

    if not at_match then
        return {}
    end

    -- Find the @ position (0-indexed column)
    local at_byte_pos = before_cursor:reverse():find("@")
    local at_col = cursor_col - at_byte_pos

    local FilePicker = require("agentic.ui.file_picker")
    local files = FilePicker.get_files(bufnr)
    if not files or #files == 0 then
        return {}
    end

    --- @type table[]
    local items = {}
    for _, file in ipairs(files) do
        local path = file.path
        table.insert(items, {
            label = path,
            kind = CompletionItemKind.File,
            filterText = "@" .. path,
            textEdit = {
                range = {
                    start = { line = cursor_line, character = at_col },
                    ["end"] = { line = cursor_line, character = cursor_col },
                },
                newText = "@" .. path .. " ",
            },
        })
    end

    return items
end

--- Create the LSP protocol handler for an input buffer.
--- @return table
function M._make_handlers()
    return {
        --- @param method string
        --- @param params table
        --- @param callback fun(err: any, result: any)
        request = function(method, params, callback)
            if method == "initialize" then
                callback(nil, {
                    capabilities = {
                        completionProvider = {
                            triggerCharacters = { "/", "@" },
                            resolveProvider = false,
                        },
                    },
                })
            elseif method == "textDocument/completion" then
                local bufnr = vim.api.nvim_get_current_buf()
                local line = params.position.line
                local col = params.position.character
                local lines =
                    vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)

                if #lines == 0 then
                    callback(nil, { isIncomplete = false, items = {} })
                    return
                end

                local line_text = lines[1]
                local trigger = params.context
                    and params.context.triggerCharacter

                local items = {}

                if trigger == "/" or line_text:match("^/") then
                    items = get_slash_completions(bufnr, line_text, col, line)
                end

                if
                    #items == 0
                    and (trigger == "@" or line_text:sub(1, col):find("@"))
                then
                    items = get_file_completions(bufnr, line_text, col, line)
                end

                callback(nil, { isIncomplete = false, items = items })
            elseif method == "shutdown" then
                callback(nil, nil)
            end
        end,

        notify = function() end,
        is_closing = function()
            return false
        end,
        terminate = function() end,
    }
end

--- Attach the in-process completion LSP to the given input buffer.
--- @param bufnr integer
function M.attach(bufnr)
    Logger.debug("[LspServer] Attaching to buffer:", bufnr)

    vim.lsp.start({
        name = "agentic_input",
        cmd = function()
            ---@diagnostic disable-next-line: return-type-mismatch
            return M._make_handlers()
        end,
        root_dir = vim.fn.getcwd(),
    }, {
        bufnr = bufnr,
    })
end

return M
