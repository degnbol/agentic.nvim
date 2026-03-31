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
    Keyword = 14,
    File = 17,
    Folder = 19,
}

--- Build slash command completion items from the stored commands.
--- @param bufnr integer
--- @param line_text string
--- @param cursor_col integer 0-indexed column
--- @param cursor_line integer 0-indexed line
--- @return table[]
local function get_slash_completions(bufnr, line_text, cursor_col, cursor_line)
    local before_cursor = line_text:sub(1, cursor_col)

    -- Find `/` at line start or preceded by whitespace, no spaces after
    local slash_match = before_cursor:match("^/[^%s]*$")
        or before_cursor:match("[%s]/[^%s]*$")

    if not slash_match then
        return {}
    end

    -- Find the `/` position (0-indexed column)
    local slash_byte_pos = before_cursor:reverse():find("/")
    local slash_col = cursor_col - slash_byte_pos

    -- Read from specific buffer, not vim.b[0], to be robust in LSP context
    local commands = States.getSlashCommandsForBuffer(bufnr)
    if #commands == 0 then
        return {}
    end

    --- @type table[]
    local items = {}
    for _, cmd in ipairs(commands) do
        table.insert(items, {
            label = cmd.word,
            kind = CompletionItemKind.Keyword,
            detail = cmd.menu,
            filterText = cmd.word,
            score_offset = 5,
            textEdit = {
                range = {
                    start = { line = cursor_line, character = slash_col },
                    ["end"] = { line = cursor_line, character = cursor_col },
                },
                newText = "/" .. cmd.word,
            },
        })
    end

    return items
end

--- Build slash command items matched by bare word (no `/` prefix).
--- Lets users type "py" and see "pymol" in the menu, inserting "/pymol".
--- @param bufnr integer
--- @param line_text string
--- @param cursor_col integer 0-indexed column
--- @param cursor_line integer 0-indexed line
--- @return table[]
local function get_slash_word_completions(
    bufnr,
    line_text,
    cursor_col,
    cursor_line
)
    local before_cursor = line_text:sub(1, cursor_col)

    -- Extract the current word: contiguous non-whitespace at end, no `/` or `@`
    local word = before_cursor:match("[%s]([^%s/@]+)$")
        or before_cursor:match("^([^%s/@]+)$")

    if not word or #word < 2 then
        return {}
    end

    local word_col = cursor_col - #word

    local commands = States.getSlashCommandsForBuffer(bufnr)
    if #commands == 0 then
        return {}
    end

    --- @type table[]
    local items = {}
    for _, cmd in ipairs(commands) do
        table.insert(items, {
            label = cmd.word,
            kind = CompletionItemKind.Keyword,
            detail = cmd.menu,
            filterText = cmd.word,
            textEdit = {
                range = {
                    start = { line = cursor_line, character = word_col },
                    ["end"] = { line = cursor_line, character = cursor_col },
                },
                newText = cmd.word,
            },
        })
    end

    return items
end

--- Entries to hide from @ directory listings.
local DIR_EXCLUDE = {
    [".git"] = true,
    [".DS_Store"] = true,
}

--- Sort key: non-dot before dot, dirs before files, then alphabetical.
--- @param name string
--- @param is_dir boolean
--- @return string
local function file_sort_key(name, is_dir)
    local dot = name:sub(1, 1) == "." and "1" or "0"
    local kind = is_dir and "0" or "1"
    return dot .. kind .. name:lower()
end

--- Build file completion items by listing one directory level at a time.
--- Typing `@` lists cwd; picking a directory inserts `@dir/` which re-triggers
--- via the `/` trigger character, listing the next level.
---
--- This deliberately reimplements directory listing (~30 lines) rather than
--- delegating to blink.cmp's path source, so the plugin stays framework-agnostic
--- (works with blink.cmp, nvim-cmp, or built-in completion via standard LSP).
--- @param _bufnr integer
--- @param line_text string
--- @param cursor_col integer 0-indexed column
--- @param cursor_line integer 0-indexed line
--- @return table[]
local function get_file_completions(_bufnr, line_text, cursor_col, cursor_line)
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

    -- Extract path typed after @, split into directory prefix and partial name
    local typed = before_cursor:sub(at_col + 2) -- skip past @
    local dir_prefix = typed:match("^(.*/)") or ""
    local scan_dir = dir_prefix == "" and "." or dir_prefix

    -- List one directory level
    local handle = vim.uv.fs_scandir(scan_dir)
    if not handle then
        return {}
    end

    --- @type table[]
    local items = {}
    while true do
        local name, entry_type = vim.uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if DIR_EXCLUDE[name] then
            -- skip
        else
            -- Resolve symlinks to determine if directory
            local is_dir = entry_type == "directory"
            if entry_type == "link" then
                local stat = vim.uv.fs_stat(scan_dir .. "/" .. name)
                is_dir = stat and stat.type == "directory" or false
            end

            local full_path = dir_prefix .. name
            local suffix = is_dir and "/" or ""

            table.insert(items, {
                label = name .. suffix,
                kind = is_dir and CompletionItemKind.Folder
                    or CompletionItemKind.File,
                filterText = full_path .. suffix,
                sortText = file_sort_key(name, is_dir),
                score_offset = 5,
                textEdit = {
                    range = {
                        start = { line = cursor_line, character = at_col },
                        ["end"] = { line = cursor_line, character = cursor_col },
                    },
                    newText = "@" .. full_path .. suffix,
                },
            })
        end
    end

    table.sort(items, function(a, b)
        return a.sortText < b.sortText
    end)

    return items
end

--- Minimum word length for buffer word completions.
local MIN_WORD_LEN = 4

--- Extract unique words from the chat buffer for completion.
--- @param bufnr integer input buffer number
--- @param line_text string current input line
--- @param cursor_col integer 0-indexed column
--- @param cursor_line integer 0-indexed line
--- @return table[]
local function get_buffer_word_completions(
    bufnr,
    line_text,
    cursor_col,
    cursor_line
)
    local before_cursor = line_text:sub(1, cursor_col)

    -- Extract current word prefix (letters, digits, underscores, hyphens)
    local prefix = before_cursor:match("[%w_%-]+$")
    if not prefix or #prefix < 2 then
        return {}
    end

    local prefix_col = cursor_col - #prefix

    local chat_bufnr = States.getChatBufnr(bufnr)
    if not chat_bufnr or not vim.api.nvim_buf_is_valid(chat_bufnr) then
        return {}
    end

    local chat_lines = vim.api.nvim_buf_get_lines(chat_bufnr, 0, -1, false)
    local seen = {}
    --- @type table[]
    local items = {}

    for _, chat_line in ipairs(chat_lines) do
        for word in chat_line:gmatch("[%w_%-]+") do
            if #word >= MIN_WORD_LEN and not seen[word] then
                seen[word] = true
                table.insert(items, {
                    label = word,
                    kind = CompletionItemKind.Text,
                    filterText = word,
                    textEdit = {
                        range = {
                            start = {
                                line = cursor_line,
                                character = prefix_col,
                            },
                            ["end"] = {
                                line = cursor_line,
                                character = cursor_col,
                            },
                        },
                        newText = word,
                    },
                })
            end
        end
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

                local before_cursor = line_text:sub(1, col)

                if trigger == "/" or before_cursor:find("/") then
                    items = get_slash_completions(bufnr, line_text, col, line)
                end

                if
                    #items == 0
                    and (trigger == "@" or before_cursor:find("@"))
                then
                    items = get_file_completions(bufnr, line_text, col, line)
                end

                -- Always append bare word items so blink.cmp can filter
                -- them client-side (handler only runs on trigger chars)
                local word_items =
                    get_slash_word_completions(bufnr, line_text, col, line)
                vim.list_extend(items, word_items)

                local buf_items =
                    get_buffer_word_completions(bufnr, line_text, col, line)
                vim.list_extend(items, buf_items)

                callback(nil, { isIncomplete = true, items = items })
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
