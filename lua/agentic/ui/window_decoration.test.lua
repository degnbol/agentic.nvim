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

        -- Reset has_line_plugin cache (module-level local, cleared by re-require)
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
        -- Ensure winbar starts empty so set_winbar doesn't skip (lualine guard)
        vim.wo[winid].winbar = ""
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

    describe("render_header with % in context", function()
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

        it(
            "does not error when context contains percent signs (E539)",
            function()
                local tab_page_id = vim.api.nvim_win_get_tabpage(winid)
                WindowDecoration.set_headers_state(tab_page_id, {
                    chat = { title = "Chat" },
                })

                -- Context with "42%" — the exact pattern from usage_update.
                -- Without escaping, this triggers E539 because "% " is an
                -- invalid statusline format specifier.
                assert.has_no_errors(function()
                    WindowDecoration.render_header(
                        bufnr,
                        "chat",
                        "Mode: chat · 42%"
                    )
                end)

                local winbar = vim.wo[winid].winbar
                assert.is_not_nil(winbar)
                -- In the statusline format string, literal % is escaped as %%
                assert.is_true(winbar:find("42%%%%") ~= nil)
            end
        )

        it("renders plain text without percent signs normally", function()
            local tab_page_id = vim.api.nvim_win_get_tabpage(winid)
            WindowDecoration.set_headers_state(tab_page_id, {
                chat = { title = "Chat" },
            })

            assert.has_no_errors(function()
                WindowDecoration.render_header(bufnr, "chat", "Mode: plan")
            end)

            local winbar = vim.wo[winid].winbar
            assert.is_true(winbar:find("Mode: plan") ~= nil)
        end)
    end)
end)
