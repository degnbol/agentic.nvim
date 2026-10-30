--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
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
        vim.b[bufnr].agentic_session_id = 7
        vim.b[bufnr].agentic_window = "agent"
        winid = vim.api.nvim_open_win(bufnr, true, { split = "right", win = 0 })
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

    describe("buffer_name", function()
        it("keeps a `/` in the title out of the name's tail", function()
            local name = WindowDecoration.buffer_name(bufnr, "fix a/b")
            assert.equal("agentic://7/agent/fix a-b", name)
            assert.equal("fix a-b", vim.fn.fnamemodify(name, ":t"))
        end)

        it("keeps a title apart from a panel's name", function()
            assert.equal(
                "agentic://7/agent",
                WindowDecoration.buffer_name(bufnr)
            )
            assert.equal(
                "agentic://7/agent/input",
                WindowDecoration.buffer_name(bufnr, "input")
            )
        end)
    end)

    describe("headers", function()
        it("default to the panel's icon and title", function()
            local header = WindowDecoration.get_header(bufnr)
            assert.equal("󰚩", header.icon)
            assert.equal("Agentic Chat", header.title)
        end)

        it("render a header never set as its default", function()
            WindowDecoration.render_header(bufnr)
            assert.equal("󰚩 Agentic Chat", vim.wo[winid].winbar)
        end)

        it("render icon, title, state and context in every showing window", function()
            local second = vim.api.nvim_open_win(bufnr, false, {
                split = "below",
                win = winid,
            })

            WindowDecoration.set_header(bufnr, {
                icon = "I",
                title = "Chat",
                idle = true,
                context = "12k",
            })

            assert.equal("I Chat 󰂞 · 12k", vim.wo[winid].winbar)
            assert.equal("I Chat 󰂞 · 12k", vim.wo[second].winbar)
            vim.api.nvim_win_close(second, true)
        end)

        it("render without a state or context", function()
            WindowDecoration.set_header(bufnr, { icon = "I", title = "Chat" })
            assert.equal("I Chat", vim.wo[winid].winbar)
        end)

        it("take a Config.headers table icon", function()
            Config.headers = { agent = { icon = "X" } } --- @diagnostic disable-line: inject-field
            WindowDecoration.set_header(bufnr, { icon = "I", title = "Chat" })
            assert.equal("X Chat", vim.wo[winid].winbar)
        end)

        it("set the winbar with local scope", function()
            WindowDecoration.set_header(bufnr, { title = "Chat" })

            local other = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_win_set_buf(winid, other)

            assert.equal("", vim.wo[winid].winbar)
            vim.api.nvim_buf_delete(other, { force = true })
        end)

        it("announce the buffer with AgenticHeadersChanged", function()
            local seen
            local id = vim.api.nvim_create_autocmd("User", {
                pattern = "AgenticHeadersChanged",
                callback = function(ev)
                    seen = ev.data.buf
                end,
            })

            WindowDecoration.set_header(bufnr, { title = "Chat" })

            vim.api.nvim_del_autocmd(id)
            assert.equal(bufnr, seen)
            assert.equal("Chat", vim.b[bufnr].agentic_header.title)
        end)

        it("do not set a winbar when Config.winbar is false", function()
            local original_winbar = Config.winbar
            Config.winbar = false

            WindowDecoration.set_header(bufnr, { title = "Chat" })

            assert.equal("", vim.wo[winid].winbar)
            Config.winbar = original_winbar
        end)
    end)

    describe("header_state", function()
        it("is nil without a state", function()
            assert.is_nil(WindowDecoration.header_state({ title = "" }))
        end)

        it("is each fact alone", function()
            assert.equal(
                "permission",
                WindowDecoration.header_state({ title = "", waiting = true })
            )
            assert.equal(
                "running",
                WindowDecoration.header_state({ title = "", running = true })
            )
            assert.equal(
                "idle",
                WindowDecoration.header_state({ title = "", idle = true })
            )
        end)

        it("prefers permission, then running, then idle", function()
            assert.equal(
                "permission",
                WindowDecoration.header_state({
                    title = "",
                    waiting = true,
                    running = true,
                    idle = true,
                })
            )
            assert.equal(
                "running",
                WindowDecoration.header_state({
                    title = "",
                    running = true,
                    idle = true,
                })
            )
        end)
    end)
end)
