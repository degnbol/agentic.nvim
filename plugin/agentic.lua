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
map(
    "n",
    "<Plug>(agentic-new-session-provider)",
    agentic("new_session_with_provider")
)
map("n", "<Plug>(agentic-switch-provider)", agentic("switch_provider"))
map("n", "<Plug>(agentic-restore-session)", agentic("restore_session"))
map("n", "<Plug>(agentic-stop)", agentic("stop_generation"))

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
    require("agentic").open({ mods = args.smods, auto_add_to_context = false })
end, {
    nargs = 0,
    desc = "Show the agentic chat; split and tab modifiers open a new window",
})

vim.api.nvim_create_user_command("AgenticResume", function(args)
    require("agentic").resume_query(args.args)
end, {
    nargs = 1,
    desc = "Resume agentic session by session_id prefix or exact title (case-insensitive)",
})
