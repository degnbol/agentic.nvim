-- Helper to create isolated child Neovim instances with plugin loaded

local MiniTest = require("mini.test")

--- @class tests.helpers.Child : MiniTest.child
--- @field launch fun() Restart child, put the plugin on the runtimepath with the ACP transport and health mocked, and source its `plugin/` file as startup does
--- @field setup fun() `launch`, then run agentic.setup()
--- @field flush fun() Flush pending scheduled callbacks in child neovim and wait a bit to ensure they are processed
--- @field new_session fun() Start another session with nothing added to its context, show its chat, then `flush`

--- @class tests.helpers.ChildModule
local M = {}

--- Create a new child Neovim instance with the plugin pre-loaded
--- @return tests.helpers.Child child Child Neovim instance with setup() method
function M.new()
    local child = MiniTest.new_child_neovim() --[[@as tests.helpers.Child]]
    local root_dir = vim.fn.getcwd()

    function child.launch()
        child.restart({ "-u", "NONE" })
        child.lua("vim.opt.rtp:prepend(...)", { root_dir })

        child.lua([[
            local ACPTransportMock = require("tests.mocks.acp_transport_mock")
            package.loaded["agentic.acp.acp_transport"] = ACPTransportMock
        ]])

        child.lua([[
            local ACPHealthMock = require("tests.mocks.acp_health_mock")
            package.loaded["agentic.acp.acp_health"] = ACPHealthMock
        ]])

        -- `-u NONE` skips loading plugins.
        child.cmd("runtime plugin/agentic.lua")
    end

    function child.setup()
        child.launch()
        child.lua([[
            require("agentic").setup()
        ]])
    end

    function child.flush()
        child.lua([[
          vim.cmd("redraw")
        ]])

        child.api.nvim_eval("1")
    end

    function child.new_session()
        child.lua(
            [[require("agentic").new_session({ auto_add_to_context = false })]]
        )
        child.flush()
    end

    return child
end

return M
