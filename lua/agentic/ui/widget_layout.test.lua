local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local WidgetLayout = require("agentic.ui.widget_layout")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

describe("WidgetLayout", function()
    local notify_stub
    --- The panel buffers of the test, filled by `panel_buf`.
    --- @type agentic.ui.ChatWidget.BufNrs
    local buf_nrs

    before_each(function()
        notify_stub = spy.stub(Logger, "notify")
        buf_nrs = {}
    end)

    after_each(function()
        notify_stub:revert()
    end)

    --- A new scratch buffer, recorded as the `panel` buffer in `buf_nrs`.
    --- @param panel agentic.ui.ChatWidget.PanelNames
    --- @param lines string[]|nil Content; empty when nil
    --- @return integer bufnr
    local function panel_buf(panel, lines)
        local bufnr = vim.api.nvim_create_buf(false, true)
        if lines then
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        end
        buf_nrs[panel] = bufnr
        return bufnr
    end

    --- @param bufnr integer
    --- @param opts vim.api.keyset.win_config|nil
    --- @return integer winid
    local function split(bufnr, opts)
        return vim.api.nvim_open_win(
            bufnr,
            false,
            vim.tbl_extend("force", { split = "right", win = -1 }, opts or {})
        )
    end

    --- Show a new listed buffer in `winid`, as `:enew` there would.
    --- @param winid integer
    local function show_other_buffer(winid)
        vim.api.nvim_win_set_buf(winid, vim.api.nvim_create_buf(true, false))
    end

    --- The names of the windows in the current tabpage, top to bottom:
    --- the panel name from `win_nrs`, or "home".
    --- @param win_nrs agentic.ui.ChatWidget.WinNrs
    --- @param home integer
    --- @return string[]
    local function column(win_nrs, home)
        local names = { [home] = "home" }
        for name, winid in pairs(win_nrs) do
            names[winid] = name
        end
        local winids = vim.api.nvim_tabpage_list_wins(0)
        table.sort(winids, function(a, b)
            return vim.api.nvim_win_get_position(a)[1]
                < vim.api.nvim_win_get_position(b)[1]
        end)
        return vim.tbl_map(function(winid)
            return names[winid] or "other"
        end, winids)
    end

    describe("panel_win", function()
        it("is the slot's window while it shows the panel buffer", function()
            local winid = split(panel_buf("code"))
            local win_nrs = { code = winid }

            assert.equal(
                winid,
                WidgetLayout.panel_win(win_nrs, buf_nrs, "code")
            )
            assert.is_nil(WidgetLayout.panel_win(win_nrs, buf_nrs, "input"))
            -- Another session's code buffer.
            assert.is_nil(
                WidgetLayout.panel_win(
                    win_nrs,
                    { code = vim.api.nvim_create_buf(false, true) },
                    "code"
                )
            )

            vim.api.nvim_win_close(winid, true)
        end)

        it(
            "is nil while the slot shows another buffer, and back after :b",
            function()
                local code = panel_buf("code")
                local winid = split(code)
                local win_nrs = { code = winid }

                show_other_buffer(winid)
                assert.is_nil(WidgetLayout.panel_win(win_nrs, buf_nrs, "code"))
                assert.same({ code = winid }, win_nrs)

                vim.api.nvim_win_call(winid, function()
                    vim.cmd.buffer(code)
                end)
                assert.equal(
                    winid,
                    WidgetLayout.panel_win(win_nrs, buf_nrs, "code")
                )

                vim.api.nvim_win_close(winid, true)
            end
        )

        it("is nil for a closed window", function()
            panel_buf("code")
            assert.is_nil(
                WidgetLayout.panel_win({ code = 99999 }, buf_nrs, "code")
            )
        end)
    end)

    describe("close", function()
        it("closes every panel window and empties the slots", function()
            local code = split(panel_buf("code"))
            local input = split(panel_buf("input"), { split = "below" })

            local win_nrs = { code = code, input = input }
            WidgetLayout.close(win_nrs, buf_nrs)

            assert.is_false(vim.api.nvim_win_is_valid(code))
            assert.is_false(vim.api.nvim_win_is_valid(input))
            assert.same({}, win_nrs)
        end)

        it("leaves a slot showing another buffer open", function()
            local winid = split(panel_buf("code"))
            show_other_buffer(winid)

            local win_nrs = { code = winid }
            WidgetLayout.close(win_nrs, buf_nrs)

            assert.is_true(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.code)
            vim.api.nvim_win_close(winid, true)
        end)

        it("empties a slot holding a closed window", function()
            local win_nrs = { code = 99999 }
            WidgetLayout.close(win_nrs, buf_nrs)
            assert.is_nil(win_nrs.code)
        end)
    end)

    describe("close_panel", function()
        it("closes the panel window and empties its slot", function()
            local winid = split(panel_buf("code"))

            local win_nrs = { code = winid }
            WidgetLayout.close_panel(win_nrs, buf_nrs, "code")

            assert.is_false(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.code)
        end)

        it("leaves a slot showing another buffer open", function()
            local winid = split(panel_buf("code"))
            show_other_buffer(winid)

            local win_nrs = { code = winid }
            WidgetLayout.close_panel(win_nrs, buf_nrs, "code")

            assert.is_true(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.code)
            vim.api.nvim_win_close(winid, true)
        end)
    end)

    describe("split_target", function()
        local stack = { "todos", "code", "files", "diagnostics", "activity", "input" }

        it("is below home when no panel is open", function()
            assert.same(
                { win = 1000, split = "below" },
                WidgetLayout.split_target(stack, {}, "files", 1000)
            )
        end)

        it("is above the nearest open panel after it", function()
            assert.same(
                { win = 3, split = "above" },
                WidgetLayout.split_target(
                    stack,
                    { todos = 1, activity = 3, input = 4 },
                    "files",
                    1000
                )
            )
        end)

        it("is below the nearest open panel before it", function()
            assert.same(
                { win = 2, split = "below" },
                WidgetLayout.split_target(
                    stack,
                    { todos = 1, code = 2 },
                    "input",
                    1000
                )
            )
        end)
    end)

    describe("validate_stack", function()
        local original_stack

        before_each(function()
            original_stack = Config.windows.stack
        end)

        after_each(function()
            Config.windows.stack = original_stack
        end)

        it("keeps a reordering of every panel", function()
            local stack =
                { "input", "activity", "diagnostics", "files", "code", "todos" }
            Config.windows.stack = stack

            WidgetLayout.validate_stack()

            assert.equal(stack, Config.windows.stack)
            assert.equal(0, notify_stub.call_count)
        end)

        for name, stack in pairs({
            missing = { "todos", "code", "files", "diagnostics", "activity" },
            duplicate = {
                "todos",
                "code",
                "files",
                "files",
                "diagnostics",
                "activity",
                "input",
            },
            unknown = {
                "todos",
                "code",
                "files",
                "diagnostics",
                "activity",
                "prompt",
            },
            ["not a list"] = "input",
        }) do
            it("replaces a stack with a " .. name .. " entry", function()
                Config.windows.stack = stack

                WidgetLayout.validate_stack()

                assert.same(
                    { "todos", "code", "files", "diagnostics", "activity", "input" },
                    Config.windows.stack
                )
                assert.equal(1, notify_stub.call_count)
            end)
        end
    end)

    describe("open_panel", function()
        --- @type integer
        local home

        before_each(function()
            vim.cmd("tabnew")
            home = vim.api.nvim_get_current_win()
        end)

        after_each(function()
            vim.cmd("tabonly")
            vim.cmd("silent! only")
        end)

        it("stacks panels below home in the configured order", function()
            for _, panel in ipairs({ "todos", "code", "files", "diagnostics", "activity" }) do
                panel_buf(panel, { "row" })
            end
            panel_buf("input")
            local win_nrs = {}

            for _, panel in ipairs({ "input", "files", "todos", "activity", "code", "diagnostics" }) do
                WidgetLayout.open_panel(win_nrs, buf_nrs, home, panel)
            end

            assert.same({
                "home",
                "todos",
                "code",
                "files",
                "diagnostics",
                "activity",
                "input",
            }, column(win_nrs, home))
        end)

        it("opens the activity panel with the input closed", function()
            panel_buf("activity", { "a.lua" })
            local win_nrs = {}

            local winid =
                WidgetLayout.open_panel(win_nrs, buf_nrs, home, "activity")

            assert.equal(winid, win_nrs.activity)
            assert.same({ "home", "activity" }, column(win_nrs, home))
            assert.equal("yes:1", vim.wo[winid].signcolumn)
        end)

        it("returns the open window instead of a second one", function()
            panel_buf("code", { "x" })
            local win_nrs = {}
            local first = WidgetLayout.open_panel(win_nrs, buf_nrs, home, "code")

            assert.equal(
                first,
                WidgetLayout.open_panel(win_nrs, buf_nrs, home, "code")
            )
            assert.equal(2, #vim.api.nvim_tabpage_list_wins(0))
        end)

        it("notifies and returns nil when a float is home", function()
            panel_buf("code", { "x" })
            local float = vim.api.nvim_open_win(
                vim.api.nvim_create_buf(false, true),
                false,
                { relative = "editor", row = 1, col = 1, width = 10, height = 3 }
            )

            assert.is_nil(WidgetLayout.open_panel({}, buf_nrs, float, "code"))
            assert.equal(1, notify_stub.call_count)
        end)

        it("leaves winfixbuf off", function()
            panel_buf("input")
            local winid = WidgetLayout.open_panel({}, buf_nrs, home, "input") --[[@as integer]]

            assert.is_false(vim.wo[winid].winfixbuf)
        end)

        it("leaves 'fillchars' global when its eob is blank", function()
            local original = vim.go.fillchars
            vim.go.fillchars = "eob: "
            panel_buf("code", { "x" })
            local winid = WidgetLayout.open_panel({}, buf_nrs, home, "code") --[[@as integer]]

            local local_fillchars = vim.api.nvim_get_option_value(
                "fillchars",
                { win = winid, scope = "local" }
            )

            vim.go.fillchars = original
            assert.equal("", local_fillchars)
        end)

        it("gives another buffer in a slot the global options", function()
            -- In the window the panels split off, whose values they copy.
            vim.o.number = true
            panel_buf("code", { "code" })
            local winid = WidgetLayout.open_panel({}, buf_nrs, home, "code") --[[@as integer]]
            assert.is_false(vim.wo[winid].number)

            local file = vim.fn.tempname()
            vim.fn.writefile({ "text" }, file)
            vim.api.nvim_win_call(winid, function()
                vim.cmd.edit(file)
            end)

            assert.is_true(vim.wo[winid].number)
            assert.equal(
                vim.go.fillchars,
                vim.api.nvim_get_option_value("fillchars", { win = winid })
            )
            vim.o.number = false
        end)
    end)

    describe("sync_panel", function()
        --- @type integer
        local home

        before_each(function()
            vim.cmd("tabnew")
            home = vim.api.nvim_get_current_win()
        end)

        after_each(function()
            vim.cmd("tabonly")
            vim.cmd("silent! only")
        end)

        it("opens a filled panel, fits it, and closes it empty", function()
            local code = panel_buf("code", { "one" })
            local win_nrs = {}

            WidgetLayout.sync_panel(win_nrs, buf_nrs, home, "code")
            local winid = win_nrs.code --[[@as integer]]
            assert.equal(2, vim.api.nvim_win_get_height(winid))

            vim.api.nvim_buf_set_lines(code, 0, -1, false, { "a", "b", "c" })
            WidgetLayout.sync_panel(win_nrs, buf_nrs, home, "code")
            assert.equal(winid, win_nrs.code)
            assert.equal(4, vim.api.nvim_win_get_height(winid))

            vim.api.nvim_buf_set_lines(code, 0, -1, false, {})
            WidgetLayout.sync_panel(win_nrs, buf_nrs, home, "code")
            assert.is_nil(win_nrs.code)
            assert.is_false(vim.api.nvim_win_is_valid(winid))
        end)
    end)

    describe("open_buf", function()
        --- @type integer
        local bufnr

        before_each(function()
            vim.cmd("tabnew")
            bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            vim.cmd("tabonly")
            vim.cmd("silent! only")
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("edit shows the buffer in the given window and focuses it", function()
            local other = vim.api.nvim_get_current_win()
            vim.cmd("split")

            local winid = WidgetLayout.open_buf(bufnr, "edit", other)

            assert.equal(other, winid)
            assert.equal(bufnr, vim.api.nvim_win_get_buf(other))
            assert.equal(other, vim.api.nvim_get_current_win())
        end)

        it("edit with no window splits", function()
            local n_wins = #vim.api.nvim_tabpage_list_wins(0)

            local winid = WidgetLayout.open_buf(bufnr, "edit", nil)

            assert.equal(n_wins + 1, #vim.api.nvim_tabpage_list_wins(0))
            assert.equal(bufnr, vim.api.nvim_win_get_buf(winid))
        end)

        it("split opens a window above the current one", function()
            local before = vim.api.nvim_get_current_win()

            local winid = WidgetLayout.open_buf(bufnr, "split", nil)

            assert.equal(bufnr, vim.api.nvim_win_get_buf(winid))
            assert.equal("col", vim.fn.winlayout()[1])
            assert.is_true(vim.api.nvim_win_is_valid(before))
        end)

        it("vsplit opens a window beside the current one", function()
            local winid = WidgetLayout.open_buf(bufnr, "vsplit", nil)

            assert.equal(bufnr, vim.api.nvim_win_get_buf(winid))
            assert.equal("row", vim.fn.winlayout()[1])
        end)

        it("tab opens a last tabpage and enters it", function()
            vim.cmd("1tabnew")

            local winid = WidgetLayout.open_buf(bufnr, "tab", nil)

            local tabs = vim.api.nvim_list_tabpages()
            assert.equal(tabs[#tabs], vim.api.nvim_get_current_tabpage())
            assert.equal(winid, vim.api.nvim_get_current_win())
            assert.equal(bufnr, vim.api.nvim_win_get_buf(winid))
        end)
    end)
end)
