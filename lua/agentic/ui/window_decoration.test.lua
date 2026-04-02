--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")

describe("agentic.ui.WindowDecoration", function()
    --- @type agentic.ui.WindowDecoration
    local WindowDecoration

    --- @type number
    local bufnr
    --- @type number
    local winid

    local original_headers

    before_each(function()
        original_headers = Config.headers
        Config.headers = nil --- @diagnostic disable-line: inject-field

        package.loaded["agentic.ui.window_decoration"] = nil
        WindowDecoration = require("agentic.ui.window_decoration")

        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 20,
            row = 0,
            col = 0,
        })
    end)

    after_each(function()
        Config.headers = original_headers
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("render_header", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("sets buffer name from header title", function()
            local tab_page_id = vim.api.nvim_win_get_tabpage(winid)
            WindowDecoration.set_headers_state(tab_page_id, {
                chat = { title = "󰻞 Agentic Chat" },
            })

            WindowDecoration.render_header(bufnr, "chat")

            local name = vim.api.nvim_buf_get_name(bufnr)
            assert.is_true(name:find("Agentic Chat") ~= nil)
        end)

        it("sets winbar to full header text", function()
            local tab_page_id = vim.api.nvim_win_get_tabpage(winid)
            WindowDecoration.set_headers_state(tab_page_id, {
                chat = { title = "Chat" },
            })

            WindowDecoration.render_header(bufnr, "chat", "Mode: plan")

            assert.equal("Chat | Mode: plan", vim.wo[winid].winbar)
        end)

        it("does not set winbar when Config.winbar is false", function()
            local original_winbar = Config.winbar
            Config.winbar = false

            local tab_page_id = vim.api.nvim_win_get_tabpage(winid)
            WindowDecoration.set_headers_state(tab_page_id, {
                chat = { title = "Chat" },
            })

            WindowDecoration.render_header(bufnr, "chat", "Mode: plan")

            assert.equal("", vim.wo[winid].winbar)

            Config.winbar = original_winbar
        end)
    end)
end)
