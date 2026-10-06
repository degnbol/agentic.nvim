-- Highlight groups, <Plug> mappings and commands for agentic.nvim
-- Users map their preferred keys to these; e.g. vim.keymap.set("n", "<leader>io", "<Plug>(agentic-open)")

require("agentic.theme").setup()

local function agentic(fn)
    return function()
        require("agentic")[fn]()
    end
end

local map = vim.keymap.set

map("n", "<Plug>(agentic-open)", agentic("open"))

-- Session management
map("n", "<Plug>(agentic-new-session)", agentic("new_session"))

-- Context: add file / selection / diagnostics
map("n", "<Plug>(agentic-add-file)", agentic("add_file"))
map("x", "<Plug>(agentic-add-selection)", agentic("add_selection"))
map(
    "n",
    "<Plug>(agentic-add-diagnostics)",
    agentic("add_current_line_diagnostics")
)
map(
    "n",
    "<Plug>(agentic-add-buffer-diagnostics)",
    agentic("add_buffer_diagnostics")
)

-- Send operator: use as motion (g@) in normal mode, direct call in visual
map("n", "<Plug>(agentic-send)", function()
    vim.o.operatorfunc = "v:lua.require'agentic'.send_operatorfunc"
    vim.api.nvim_feedkeys("g@", "n", false)
end)
map("n", "<Plug>(agentic-send-line)", function()
    vim.o.operatorfunc = "v:lua.require'agentic'.send_operatorfunc"
    vim.api.nvim_feedkeys("g@_", "n", false)
end)
map("x", "<Plug>(agentic-send)", agentic("add_selection"))

vim.api.nvim_create_user_command("Agentic", function(args)
    require("agentic").open({
        mods = args.smods,
        auto_add_to_context = false,
        query = args.args ~= "" and args.args or nil,
    })
end, {
    nargs = "?",
    desc = "Show the agentic chat, or resume the session a session_id prefix or exact title matches; split and tab modifiers open a new window",
})
