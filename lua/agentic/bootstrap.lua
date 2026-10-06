local AgentInstance = require("agentic.acp.agent_instance")
local Config = require("agentic.config")
local SessionRegistry = require("agentic.session_registry")
local Logger = require("agentic.utils.logger")

--- Process-wide initialization: treesitter languages, global autocmds,
--- image paste, signal handlers.
--- @class agentic.Bootstrap
local Bootstrap = {}

local done = false

--- Register the treesitter languages of the `AgenticChat` and `AgenticInput`
--- filetypes, and zsh for `bash` when no bash parser exists.
local function register_languages()
    -- The chat buffer parses as a private `agentic` language (a clone of the
    -- bundled markdown parser) so its folds query — queries/agentic/folds.scm,
    -- which folds the writer's `*-fold` fences — is isolated from real markdown
    -- buffers. `agentic.ui.folds` resolves the parser via
    -- get_parser(bufnr, nil), which infers the language from the filetype, so
    -- the AgenticChat→agentic registration is what makes folding work. Without
    -- it the chat would fall back to no parser and never fold.
    local md_parser =
        vim.api.nvim_get_runtime_file("parser/markdown.so", false)[1]
    local agentic_ok = md_parser ~= nil
        and pcall(vim.treesitter.language.add, "agentic", {
            path = md_parser,
            symbol_name = "markdown",
        })
    if agentic_ok then
        vim.treesitter.language.register("agentic", "AgenticChat")
    else
        -- markdown.so missing or unloadable: degrade to plain markdown
        -- highlighting with no custom tool-call folds. ChatBuffer.start falls back
        -- to starting the markdown parser to match this registration.
        Logger.debug(
            "agentic treesitter language unavailable, falling back to markdown"
        )
        vim.treesitter.language.register("markdown", "AgenticChat")
    end

    -- The input buffer is plain markdown (chat_widget starts the markdown
    -- parser on it). Declare that mapping so anything resolving a buffer's
    -- language by filetype — vim.treesitter.foldexpr, and the nvim config's
    -- prose-abbrev FileType autocmd — sees markdown without the parser having
    -- started yet.
    vim.treesitter.language.register("markdown", "AgenticInput")

    -- zsh parser for bash is registered globally in nvim config (treesitter.lua).
    -- Fallback here in case agentic.nvim is used standalone without the config.
    if not pcall(vim.treesitter.language.inspect, "bash") then
        vim.treesitter.language.register("zsh", "bash")
    end
end

--- (Re)create the `AgenticCleanup` augroup with its autocmds.
local function create_global_autocmds()
    local group = vim.api.nvim_create_augroup("AgenticCleanup", {
        clear = true,
    })

    -- Force-reload buffers when files change on disk (e.g., agent edits files directly).
    -- Suppresses the "file changed" prompt so modified buffers reload silently,
    -- matching Cursor/Zed behavior where agent changes always win.
    vim.api.nvim_create_autocmd("FileChangedShell", {
        group = group,
        pattern = "*",
        callback = function()
            vim.v.fcs_choice = "reload"
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            AgentInstance:cleanup_all()
        end,
        desc = "Cleanup Agentic processes on exit",
    })

    -- A session outlives its tab, as a buffer outlives its windows; only the
    -- binding goes. `<amatch>` is the closed tab's number, not its handle, so
    -- find the bindings whose tab is gone instead.
    vim.api.nvim_create_autocmd("TabClosed", {
        group = group,
        callback = function()
            for tab in pairs(SessionRegistry.tab_bindings) do
                if not vim.api.nvim_tabpage_is_valid(tab) then
                    SessionRegistry.tab_bindings[tab] = nil
                end
            end
        end,
        desc = "Unbind Agentic sessions from closed tabs",
    })
end

--- Wrap `vim.paste` so an image pasted in a session's buffer is added to
--- that session's file list.
local function wrap_paste()
    local function get_current_session()
        return SessionRegistry.owner_of_buf(vim.api.nvim_get_current_buf())
    end

    local Clipboard = require("agentic.ui.clipboard")

    Clipboard.setup({
        is_cursor_in_widget = function()
            return get_current_session() ~= nil
        end,
        on_paste = function(file_path)
            local session = get_current_session()

            if not session then
                return false
            end

            return session.file_list:add(file_path) or false
        end,
    })
end

--- Stop all agent processes on SIGTERM and SIGINT.
local function trap_signals()
    -- Setup signal handlers for graceful shutdown
    local sigterm_handler = vim.uv.new_signal()
    if sigterm_handler then
        vim.uv.signal_start(sigterm_handler, "sigterm", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end

    -- SIGINT handler (Ctrl-C) - note: may not trigger in raw terminal mode
    local sigint_handler = vim.uv.new_signal()
    if sigint_handler then
        vim.uv.signal_start(sigint_handler, "sigint", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end
end

--- Run the initialization. Only the first call has an effect, so
--- `Config.image_paste` is read only then.
function Bootstrap.ensure()
    if done then
        return
    end
    done = true

    register_languages()
    create_global_autocmds()
    if Config.image_paste.enabled then
        wrap_paste()
    end
    trap_signals()
end

return Bootstrap
