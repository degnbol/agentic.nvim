-- <Plug> mappings for agentic.nvim
-- Users map their preferred keys to these; e.g. vim.keymap.set("n", "<leader>ii", "<Plug>(agentic-toggle)")

local function agentic(fn)
    return function()
        require("agentic")[fn]()
    end
end

local map = vim.keymap.set

-- Toggle / open / close
map("n", "<Plug>(agentic-toggle)", agentic("toggle"))
map("n", "<Plug>(agentic-toggle-tab)", agentic("toggle_tab"))
map("n", "<Plug>(agentic-open)", agentic("open"))
map("n", "<Plug>(agentic-close)", agentic("close"))

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

-- Layout
map("n", "<Plug>(agentic-rotate-layout)", agentic("rotate_layout"))

vim.api.nvim_create_user_command("AgenticResume", function(args)
    require("agentic").resume_query(args.args)
end, {
    nargs = 1,
    desc = "Resume agentic session by session_id prefix or exact title (case-insensitive)",
})
