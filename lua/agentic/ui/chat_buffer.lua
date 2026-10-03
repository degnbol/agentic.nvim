--- Rendering setup for chat-style buffers, the ones a MessageWriter writes
--- tool-call blocks and prose into.

local Config = require("agentic.config")
local Theme = require("agentic.theme")

-- Tone down markdown heading highlights in the chat window only. The markdown
-- highlighter captures `@markup.heading.N` over the whole heading line (the
-- only capture covering the `##`/`###` marker) and `@text.titleN` over just
-- the text after the marker — and `@text.titleN` wins on the overlap. So dim
-- the marker (→ AgenticHeading) while leaving the heading text neutral
-- (→ Normal). The tool-call name is a markdown_inline code span (`@markup.raw`)
-- that wins over both and keeps its own colour. Levels 2 and 3 are the writer's
-- structural levels (see the `rendering` skill § "Heading levels"); the `#`
-- session header is left at the colourscheme's heading-1 colour. Scoping this to
-- the chat window (rather than nvim_set_hl globally) leaves real markdown
-- buffers untouched.
local CHAT_WINHIGHLIGHT = table.concat({
    "@markup.heading.2.agentic:" .. Theme.HL_GROUPS.HEADING,
    "@markup.heading.3.agentic:" .. Theme.HL_GROUPS.HEADING,
    "@text.title2.agentic:Normal",
    "@text.title3.agentic:Normal",
}, ",")

--- @class agentic.ui.ChatBuffer
local ChatBuffer = {}

--- Window-local options a chat-style buffer renders with (folds, conceal,
--- signcolumn), for any window showing one.
--- @return table<string, any>
function ChatBuffer.win_opts()
    return {
        wrap = false,
        scrolloff = 4,
        signcolumn = "yes:1",
        foldmethod = "expr",
        foldexpr = 'v:lua.require("agentic.ui.folds").foldexpr()',
        foldenable = true,
        -- Set foldlevel high so nothing auto-closes: `*-fold` blocks default
        -- open and the writer closes them imperatively via :foldclose. This
        -- must be set explicitly — a new window inherits window-local foldlevel
        -- from the window it splits off, NOT the global default, so opening
        -- Agentic from a window with a low foldlevel would otherwise collapse
        -- every block.
        foldlevel = 99,
        -- Same inheritance hazard as foldlevel: `agentic.ui.folds` drops
        -- one-line bodies on the assumption vim could not close them anyway,
        -- which only holds at 1.
        foldminlines = 1,
        foldcolumn = "0",
        conceallevel = 2,
        concealcursor = "n",
        foldtext = 'v:lua.require("agentic.ui.folds").foldtext()',
        winhighlight = CHAT_WINHIGHLIGHT,
    }
end

--- Start the chat parser and image attach on a buffer. Unloading a buffer
--- (`:e`, `:bunload`) detaches both, so call again after each reload.
--- @param bufnr integer
function ChatBuffer.start(bufnr)
    -- Chat parses as the private `agentic` language so its folds query is
    -- isolated from real markdown buffers (see init.lua). Fall back to markdown
    -- if the agentic language could not be registered.
    if not pcall(vim.treesitter.start, bufnr, "agentic") then
        pcall(vim.treesitter.start, bufnr, "markdown")
    end

    -- Render LaTeX math as images via snacks.image. The chat is a scratch buffer
    -- (no BufReadPre) opened at startup before any file is read, so snacks' own
    -- BufReadPre-triggered doc-attach autocmd never fires for it. Attach
    -- explicitly. Guarded so agentic.nvim runs standalone without snacks; a no-op
    -- when image rendering is disabled (doc.attach self-gates on config.enabled).
    local has_image, image = pcall(require, "snacks.image")
    if has_image then
        image.doc.attach(bufnr)
    end
end

--- `start` the buffer, and give every window it enters the chat window
--- options, merged with `Config.windows[<panel>].win_opts`. Set with local
--- scope, so a window that later shows another buffer does not keep them;
--- `winfix*` is left to the widget layout, which sizes its own windows.
---
--- Call before creating the buffer's MessageWriter: its BufWinEnter applies
--- pending folds, which needs `foldmethod=expr` in place.
--- @param bufnr integer
function ChatBuffer.setup(bufnr)
    ChatBuffer.start(bufnr)

    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function()
            local winid = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_buf(winid) ~= bufnr then
                return
            end
            local window_config = Config.windows[vim.b[bufnr].agentic_window]
                or {}
            local opts = vim.tbl_extend(
                "force",
                ChatBuffer.win_opts(),
                window_config.win_opts or {}
            )
            for name, value in pairs(opts) do
                if not name:match("^winfix") then
                    vim.api.nvim_set_option_value(
                        name,
                        value,
                        { win = winid, scope = "local" }
                    )
                end
            end
        end,
    })
end

return ChatBuffer
