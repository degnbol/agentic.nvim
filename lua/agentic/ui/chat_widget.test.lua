local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Deferred = require("tests.helpers.deferred")
local MiniTest = require("mini.test")
local Config = require("agentic.config")
local Glyphs = require("agentic.glyphs")
local Logger = require("agentic.utils.logger")
local Renderer = require("agentic.ui.tool_call_renderer")

describe("agentic.ui.ChatWidget", function()
    --- @type agentic.ui.ChatWidget
    local ChatWidget

    ChatWidget = require("agentic.ui.chat_widget")
    local last_owner_id = 1000

    --- A widget with a fresh owner id.
    --- @param on_submit function
    --- @return agentic.ui.ChatWidget
    local function new_widget(on_submit)
        last_owner_id = last_owner_id + 1
        return ChatWidget:new(last_owner_id, on_submit)
    end

    --- Helper to populate a dynamic buffer with content
    --- @param widget agentic.ui.ChatWidget
    --- @param name string
    --- @param content string[]
    local function fill_buffer(widget, name, content)
        local bufnr = widget.buf_nrs[name]
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    end

    --- Show the widget's chat in the current window, making it home.
    --- @param widget agentic.ui.ChatWidget
    --- @return integer home
    local function show(widget)
        local winid = vim.api.nvim_get_current_win()
        widget:show_in(winid)
        return winid
    end

    --- Capture `vim.schedule` for the rest of the case.
    --- @return tests.helpers.Deferred
    local function capture_deferred()
        local deferred = Deferred.capture()
        MiniTest.finally(deferred.revert)
        return deferred
    end

    --- @param keys string
    local function press(keys)
        vim.api.nvim_feedkeys(keys, "x", false)
    end

    --- @param winid integer
    --- @return integer row
    local function row_of(winid)
        return vim.api.nvim_win_get_position(winid)[1]
    end

    --- @param winid integer
    --- @return integer col
    local function col_of(winid)
        return vim.api.nvim_win_get_position(winid)[2]
    end

    describe("panels", function()
        local tab_page_id
        local widget
        local original_lines

        before_each(function()
            original_lines = vim.o.lines
            -- Ensure enough vertical space for layout calculations
            vim.o.lines = 100

            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()

            local on_submit_spy = spy.new(function() end)
            widget = new_widget(on_submit_spy --[[@as function]])
        end)

        after_each(function()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end
            pcall(function()
                vim.cmd("tabclose")
            end)

            vim.o.lines = original_lines
        end)

        it("creates widget with valid buffer IDs", function()
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.chat))
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.input))
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.code))
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.files))
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.todos))
        end)

        it("show_in makes the window home and opens no panel", function()
            assert.is_nil(widget:home_win())

            local home = show(widget)

            assert.equal(home, widget:home_win())
            assert.equal(widget.buf_nrs.chat, vim.api.nvim_win_get_buf(home))
            assert.is_nil(widget.win_nrs.input)
            assert.is_nil(widget.win_nrs.code)
            assert.is_nil(widget.win_nrs.files)
            assert.is_nil(widget.win_nrs.todos)
            assert.equal(1, #vim.api.nvim_tabpage_list_wins(tab_page_id))
        end)

        it("a window the chat enters becomes home", function()
            fill_buffer(widget, "code", { "line1" })
            local winid = vim.api.nvim_get_current_win()

            vim.cmd("buffer " .. widget.buf_nrs.chat)

            assert.equal(winid, widget:home_win())
            assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.code))
        end)

        it("show_in deletes the blank unnamed buffer it replaces", function()
            local blank = vim.api.nvim_get_current_buf()
            assert.is_true(vim.api.nvim_buf_get_name(blank) == "")

            show(widget)

            assert.is_false(vim.api.nvim_buf_is_valid(blank))
        end)

        it("show_in keeps a replaced buffer that has a name", function()
            vim.cmd.edit(vim.fn.tempname())
            local named = vim.api.nvim_get_current_buf()

            show(widget)

            assert.is_true(vim.api.nvim_buf_is_valid(named))
        end)

        it("show_in a float shows the chat without making it home", function()
            fill_buffer(widget, "code", { "line1" })
            local float = vim.api.nvim_open_win(
                vim.api.nvim_create_buf(false, true),
                true,
                { relative = "editor", row = 1, col = 1, width = 20, height = 5 }
            )

            widget:show_in(float)

            assert.equal(widget.buf_nrs.chat, vim.api.nvim_win_get_buf(float))
            assert.is_nil(widget:home_win())
            assert.is_nil(widget.win_nrs.code)
            vim.api.nvim_win_close(float, true)
        end)

        it("show_in another window moves the panels there", function()
            fill_buffer(widget, "code", { "line1" })
            local first = show(widget)
            local first_code = widget.win_nrs.code
            vim.cmd("vsplit")
            local second = vim.api.nvim_get_current_win()

            widget:show_in(second)

            assert.equal(second, widget:home_win())
            assert.is_false(vim.api.nvim_win_is_valid(first_code))
            assert.equal(col_of(second), col_of(widget.win_nrs.code))
            assert.is_true(col_of(first) ~= col_of(second))
        end)

        describe("content panels", function()
            local test_cases = {
                {
                    name = "code",
                    content = { "local foo = 'bar'", "print(foo)" },
                },
                {
                    name = "files",
                    content = { "file1.lua", "file2.lua" },
                },
                {
                    name = "todos",
                    content = { "todo1", "todo2" },
                },
                {
                    name = "diagnostics",
                    content = { "diag1" },
                },
            }

            for _, tc in ipairs(test_cases) do
                it(
                    string.format(
                        "opens the %s panel below home when its buffer has content",
                        tc.name
                    ),
                    function()
                        fill_buffer(widget, tc.name, tc.content)
                        local home = show(widget)

                        local winid = widget.win_nrs[tc.name]
                        assert.is_true(vim.api.nvim_win_is_valid(winid))
                        assert.equal(
                            tab_page_id,
                            vim.api.nvim_win_get_tabpage(winid)
                        )
                        assert.is_true(row_of(winid) > row_of(home))
                        assert.equal(col_of(home), col_of(winid))
                    end
                )
            end
        end)

        it("stacks the panels in Config.windows.stack order", function()
            for _, name in ipairs({ "files", "code", "todos" }) do
                fill_buffer(widget, name, { "content" })
            end
            local home = show(widget)
            local input = widget:input_win()
            assert.is_not_nil(input)
            local activity_opened = false
            widget:toggle_activity_window(function()
                activity_opened = true
            end)
            assert.is_true(activity_opened)

            local rows = { row_of(home) }
            for _, name in ipairs(Config.windows.stack) do
                local winid = widget.win_nrs[name]
                if winid then
                    table.insert(rows, row_of(winid))
                    assert.equal(col_of(home), col_of(winid))
                end
            end
            -- home, todos, code, files, activity, input
            assert.equal(6, #rows)
            for i = 2, #rows do
                assert.is_true(rows[i] > rows[i - 1])
            end
        end)

        it("leaves todos closed while todos.display is off", function()
            local original = Config.windows.todos.display
            Config.windows.todos.display = false
            MiniTest.finally(function()
                Config.windows.todos.display = original
            end)
            fill_buffer(widget, "todos", { "todo1" })

            show(widget)

            assert.is_nil(widget.win_nrs.todos)
        end)

        it("sync_panels is a no-op without a home", function()
            fill_buffer(widget, "code", { "line1" })
            local wins_before = #vim.api.nvim_tabpage_list_wins(tab_page_id)

            widget:sync_panels()

            assert.is_nil(widget:home_win())
            assert.is_nil(widget.win_nrs.code)
            assert.equal(
                wins_before,
                #vim.api.nvim_tabpage_list_wins(tab_page_id)
            )
        end)

        it("close_panels closes every panel and keeps the buffers", function()
            for _, name in ipairs({ "files", "code", "todos" }) do
                fill_buffer(widget, name, { "content" })
            end
            local home = show(widget)
            widget:input_win()

            local wins = {}
            for _, name in ipairs({ "files", "code", "todos", "input" }) do
                wins[name] = widget.win_nrs[name]
                assert.is_true(vim.api.nvim_win_is_valid(wins[name]))
            end

            widget:close_panels()

            for name, winid in pairs(wins) do
                assert.is_false(vim.api.nvim_win_is_valid(winid))
                assert.is_nil(widget.win_nrs[name])
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs[name]))
            end
            -- The chat stays in its window.
            assert.equal(home, widget:home_win())
        end)

        it("close_panels is safe when called multiple times", function()
            show(widget)
            widget:close_panels()

            assert.has_no_errors(function()
                widget:close_panels()
            end)
        end)

        it("close_panels stops insert mode", function()
            show(widget)
            vim.api.nvim_set_current_win(widget:input_win())
            vim.cmd("startinsert")

            widget:close_panels()

            assert.are_not.equal("i", vim.fn.mode())
        end)

        it("close_panel closes only that panel", function()
            fill_buffer(widget, "code", { "line1" })
            fill_buffer(widget, "files", { "file1" })
            show(widget)
            local code_win = widget.win_nrs.code

            widget:close_panel("code")

            assert.is_false(vim.api.nvim_win_is_valid(code_win))
            assert.is_nil(widget.win_nrs.code)
            assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.files))
        end)

        it("caps panel height at max_height", function()
            local lines = {}
            for i = 1, 23 do
                lines[i] = "line" .. i
            end
            fill_buffer(widget, "code", lines)

            show(widget)

            local height = vim.api.nvim_win_get_height(widget.win_nrs.code)
            assert.equal(Config.windows.code.max_height, height)
        end)

        it("fits a panel to its lines plus 1 line padding", function()
            fill_buffer(widget, "code", { "line1", "line2", "line3" })

            show(widget)

            assert.equal(4, vim.api.nvim_win_get_height(widget.win_nrs.code))
        end)

        it("sync_panels grows a panel when content is added", function()
            fill_buffer(widget, "code", { "line1", "line2", "line3" })
            show(widget)

            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.code,
                3,
                3,
                false,
                { "line4", "line5", "line6", "line7" }
            )
            widget:sync_panels()

            assert.equal(8, vim.api.nvim_win_get_height(widget.win_nrs.code))
        end)

        it("sync_panels shrinks a panel when content is removed", function()
            fill_buffer(
                widget,
                "code",
                { "line1", "line2", "line3", "line4", "line5" }
            )
            show(widget)
            assert.equal(6, vim.api.nvim_win_get_height(widget.win_nrs.code))

            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.code,
                0,
                -1,
                false,
                { "line1", "line2" }
            )
            widget:sync_panels()

            assert.equal(3, vim.api.nvim_win_get_height(widget.win_nrs.code))
        end)

        it("sync_panels closes a panel whose buffer became empty", function()
            fill_buffer(widget, "code", { "line1" })
            show(widget)
            local code_win = widget.win_nrs.code

            vim.api.nvim_buf_set_lines(widget.buf_nrs.code, 0, -1, false, {})
            widget:sync_panels()

            assert.is_nil(widget.win_nrs.code)
            assert.is_false(vim.api.nvim_win_is_valid(code_win))
        end)

        it("sync_panels opens a panel whose buffer got content", function()
            show(widget)
            assert.is_nil(widget.win_nrs.code)

            fill_buffer(widget, "code", { "line1" })
            widget:sync_panels()

            assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.code))
        end)

        describe("home", function()
            it(
                "showing another buffer in the home closes its panels",
                function()
                    fill_buffer(widget, "code", { "line1" })
                    local home = show(widget)
                    local code_win = widget.win_nrs.code
                    local deferred = capture_deferred()

                    vim.api.nvim_set_current_win(home)
                    vim.cmd("enew")
                    deferred.drain()

                    assert.is_nil(widget:home_win())
                    assert.is_false(vim.api.nvim_win_is_valid(code_win))
                    assert.is_nil(widget.win_nrs.code)
                    -- A panel needs a home again before it opens.
                    widget:sync_panels()
                    assert.is_nil(widget.win_nrs.code)
                end
            )

            it("closing the home closes its panels", function()
                fill_buffer(widget, "code", { "line1" })
                vim.cmd("vsplit")
                local home = show(widget)
                local code_win = widget.win_nrs.code
                local deferred = capture_deferred()

                vim.api.nvim_win_close(home, true)
                deferred.drain()

                assert.is_nil(widget:home_win())
                assert.is_false(vim.api.nvim_win_is_valid(code_win))
                assert.is_nil(widget.win_nrs.code)
            end)

            it(":q on the home closes its panels with it", function()
                fill_buffer(widget, "code", { "line1" })
                vim.cmd("vsplit")
                local other = vim.fn.win_getid(vim.fn.winnr("l"))
                local home = show(widget)
                local code_win = widget.win_nrs.code
                local input_win = widget:input_win()
                local deferred = capture_deferred()

                vim.api.nvim_set_current_win(home)
                vim.cmd("quit")
                deferred.drain()

                assert.is_false(vim.api.nvim_win_is_valid(home))
                assert.is_false(vim.api.nvim_win_is_valid(code_win))
                assert.is_false(vim.api.nvim_win_is_valid(input_win))
                assert.is_true(vim.api.nvim_win_is_valid(other))
                assert.is_nil(widget:home_win())
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.chat))
            end)

            it("a refused :q on the home brings its panels back", function()
                fill_buffer(widget, "code", { "line1" })
                fill_buffer(widget, "activity", { "a.lua" })
                local home = show(widget)
                widget:input_win()
                widget:toggle_activity_window()
                local deferred = capture_deferred()

                vim.api.nvim_set_current_win(home)
                -- QuitPre without the quit, as when vim refuses it.
                vim.api.nvim_exec_autocmds(
                    "QuitPre",
                    { buffer = widget.buf_nrs.chat }
                )
                assert.is_nil(widget.win_nrs.code)
                assert.is_nil(widget.win_nrs.input)
                assert.is_nil(widget.win_nrs.activity)
                deferred.drain()

                assert.equal(home, widget:home_win())
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.code))
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.input))
                assert.is_true(
                    vim.api.nvim_win_is_valid(widget.win_nrs.activity)
                )
            end)

            it("a refused :q leaves a closed input closed", function()
                fill_buffer(widget, "code", { "line1" })
                local home = show(widget)
                local deferred = capture_deferred()

                vim.api.nvim_set_current_win(home)
                vim.api.nvim_exec_autocmds(
                    "QuitPre",
                    { buffer = widget.buf_nrs.chat }
                )
                deferred.drain()

                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.code))
                assert.is_nil(widget.win_nrs.input)
            end)
        end)

        describe("activity panel", function()
            it("moves the panels to a chat window in the current tab", function()
                fill_buffer(widget, "code", { "line1" })
                fill_buffer(widget, "activity", { "a.lua" })
                local first = show(widget)
                vim.cmd("tabnew")
                MiniTest.finally(function()
                    pcall(vim.cmd.tabclose)
                end)
                local second = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(second, widget.buf_nrs.chat)
                assert.equal(first, widget:home_win())

                widget:toggle_activity_window()

                assert.equal(second, widget:home_win())
                local tab = vim.api.nvim_get_current_tabpage()
                for _, panel in ipairs({ "code", "activity" }) do
                    assert.equal(
                        tab,
                        vim.api.nvim_win_get_tabpage(widget.win_nrs[panel])
                    )
                end
            end)

            it("notifies and opens nothing without a home", function()
                local notify_stub = spy.stub(Logger, "notify")
                MiniTest.finally(function()
                    notify_stub:revert()
                end)
                local on_open = spy.new(function() end)

                widget:toggle_activity_window(on_open --[[@as function]])

                assert.spy(on_open).was.called(0)
                assert.is_false(widget:is_activity_window_open())
                assert.spy(notify_stub).was.called(1)
                assert.equal(
                    "Show the chat to open the file activity panel.",
                    notify_stub.calls[1][1]
                )
            end)

            it("opens below home with the input closed", function()
                local home = show(widget)
                local open_during_on_open

                widget:toggle_activity_window(function()
                    open_during_on_open = widget:is_activity_window_open()
                end)

                assert.is_false(open_during_on_open)
                assert.is_true(widget:is_activity_window_open())
                assert.is_nil(widget.win_nrs.input)
                local winid = widget.win_nrs.activity
                assert.is_true(row_of(winid) > row_of(home))
                assert.equal(col_of(home), col_of(winid))
            end)

            it("toggles closed and runs on_close", function()
                show(widget)
                local on_close = spy.new(function() end)
                widget:toggle_activity_window(nil, on_close --[[@as function]])
                local winid = widget.win_nrs.activity

                widget:toggle_activity_window(nil, on_close --[[@as function]])

                assert.spy(on_close).was.called(1)
                assert.is_false(vim.api.nvim_win_is_valid(winid))
                assert.is_false(widget:is_activity_window_open())
            end)

            it("resize_activity_window fits the panel to its rows", function()
                fill_buffer(widget, "activity", { "a", "b" })
                show(widget)
                widget:toggle_activity_window()
                assert.equal(
                    3,
                    vim.api.nvim_win_get_height(widget.win_nrs.activity)
                )

                fill_buffer(widget, "activity", { "a", "b", "c", "d", "e" })
                widget:resize_activity_window()

                assert.equal(
                    6,
                    vim.api.nvim_win_get_height(widget.win_nrs.activity)
                )
            end)

            it("resize_activity_window is a no-op while closed", function()
                show(widget)

                assert.has_no_errors(function()
                    widget:resize_activity_window()
                end)
                assert.is_false(widget:is_activity_window_open())
            end)
        end)
    end)

    describe("input", function()
        local widget
        local home

        before_each(function()
            vim.cmd("tabnew")
            widget = new_widget(spy.new(function() end) --[[@as function]])
            home = show(widget)
        end)

        after_each(function()
            pcall(function()
                widget:destroy()
            end)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("an insert key in the chat opens the input below home", function()
            vim.api.nvim_set_current_win(home)

            press("i")

            local input = widget.win_nrs.input
            assert.is_true(vim.api.nvim_win_is_valid(input))
            assert.equal(input, vim.api.nvim_get_current_win())
            assert.equal(widget.buf_nrs.input, vim.api.nvim_win_get_buf(input))
            assert.is_true(row_of(input) > row_of(home))
            assert.equal(col_of(home), col_of(input))
            assert.equal(
                Config.windows.input.height,
                vim.api.nvim_win_get_height(input)
            )
        end)

        it("an insert key in a panel focuses the input", function()
            fill_buffer(widget, "code", { "line1" })
            widget:sync_panels()
            vim.api.nvim_set_current_win(widget.win_nrs.code)

            press("i")

            local input = widget.win_nrs.input
            assert.is_true(vim.api.nvim_win_is_valid(input))
            assert.equal(input, vim.api.nvim_get_current_win())
            assert.is_true(row_of(input) > row_of(widget.win_nrs.code))
        end)

        it("an insert key reuses the input window already shown", function()
            local input = widget:input_win()
            vim.api.nvim_set_current_win(home)

            press("A")

            assert.equal(input, vim.api.nvim_get_current_win())
            assert.equal(1, #vim.fn.win_findbuf(widget.buf_nrs.input))
        end)

        for _, key in ipairs({ "p", "P" }) do
            it(key .. " in the chat pastes into the input", function()
                vim.fn.setreg('"', "pasted", "c")
                vim.api.nvim_set_current_win(home)

                press(key)

                assert.equal(
                    widget.buf_nrs.input,
                    vim.api.nvim_get_current_buf()
                )
                assert.same(
                    { "pasted" },
                    vim.api.nvim_buf_get_lines(
                        widget.buf_nrs.input,
                        0,
                        -1,
                        false
                    )
                )
            end)
        end

        it(
            "input_win opens below the current window without a home in the tab",
            function()
                local home_tab = vim.api.nvim_get_current_tabpage()
                vim.cmd("tabnew")
                MiniTest.finally(function()
                    pcall(vim.cmd.tabclose)
                    pcall(vim.api.nvim_set_current_tabpage, home_tab)
                end)
                local current = vim.api.nvim_get_current_win()

                local input = widget:input_win()

                assert.equal(
                    vim.api.nvim_get_current_tabpage(),
                    vim.api.nvim_win_get_tabpage(input)
                )
                assert.is_true(row_of(input) > row_of(current))
                -- Not a panel: the home's column stays as it was.
                assert.is_nil(widget.win_nrs.input)
                assert.equal(1, #vim.api.nvim_tabpage_list_wins(home_tab))
            end
        )

        it(":q in the input closes only its window", function()
            local input = widget:input_win()
            vim.api.nvim_set_current_win(input)

            vim.cmd("quit")

            assert.is_false(vim.api.nvim_win_is_valid(input))
            assert.is_nil(widget.win_nrs.input)
            assert.equal(home, widget:home_win())
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.input))
        end)
    end)

    describe("multi-tabpage isolation", function()
        local widget_a
        local widget_b
        local tab_a
        local tab_b

        before_each(function()
            vim.cmd("tabnew")
            tab_a = vim.api.nvim_get_current_tabpage()
            widget_a = new_widget(spy.new(function() end) --[[@as function]])
            fill_buffer(widget_a, "code", { "a" })
            show(widget_a)

            vim.cmd("tabnew")
            tab_b = vim.api.nvim_get_current_tabpage()
            widget_b = new_widget(spy.new(function() end) --[[@as function]])
            fill_buffer(widget_b, "files", { "b" })
            show(widget_b)
        end)

        after_each(function()
            for _, widget in ipairs({ widget_a, widget_b }) do
                pcall(function()
                    widget:destroy()
                end)
            end
            for _, tab in ipairs({ tab_a, tab_b }) do
                if vim.api.nvim_tabpage_is_valid(tab) then
                    vim.api.nvim_set_current_tabpage(tab)
                    pcall(vim.cmd.tabclose)
                end
            end
        end)

        it("opens each widget's panels in its own tabpage", function()
            assert.equal(
                tab_a,
                vim.api.nvim_win_get_tabpage(widget_a:home_win())
            )
            assert.equal(
                tab_a,
                vim.api.nvim_win_get_tabpage(widget_a.win_nrs.code)
            )
            assert.is_nil(widget_a.win_nrs.files)

            assert.equal(
                tab_b,
                vim.api.nvim_win_get_tabpage(widget_b:home_win())
            )
            assert.equal(
                tab_b,
                vim.api.nvim_win_get_tabpage(widget_b.win_nrs.files)
            )
            assert.is_nil(widget_b.win_nrs.code)
        end)

        it("closing one widget's panels and tab leaves the other", function()
            widget_b:close_panels()
            assert.is_true(vim.api.nvim_win_is_valid(widget_a.win_nrs.code))

            pcall(function()
                widget_b:destroy()
            end)
            vim.api.nvim_set_current_tabpage(tab_b)
            vim.cmd("tabclose")

            assert.is_true(vim.api.nvim_win_is_valid(widget_a.win_nrs.code))
            assert.equal(
                widget_a.buf_nrs.chat,
                vim.api.nvim_win_get_buf(widget_a:home_win())
            )
        end)

        it("an insert key opens the input in its widget's tabpage", function()
            vim.api.nvim_set_current_tabpage(tab_a)
            vim.api.nvim_set_current_win(widget_a:home_win())

            press("i")

            assert.equal(
                tab_a,
                vim.api.nvim_win_get_tabpage(widget_a.win_nrs.input)
            )
            assert.is_nil(widget_b.win_nrs.input)
        end)
    end)

    describe(":w and the modified flag", function()
        local widget
        local submit_spy
        --- @type boolean
        local dispatched

        before_each(function()
            vim.cmd("tabnew")
            dispatched = true
            widget = new_widget(function()
                return dispatched
            end)
            show(widget)
            submit_spy = spy.on(widget, "submit")
        end)

        after_each(function()
            submit_spy:revert()
            pcall(function()
                widget:destroy()
            end)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it(":w in the input submits", function()
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false,
                { "hello" }
            )
            vim.api.nvim_set_current_win(widget:input_win())

            vim.cmd("write")

            assert.spy(submit_spy).was.called(1)
            assert.is_false(vim.bo[widget.buf_nrs.input].modified)
        end)

        it("the input stays modified while a submit is deferred", function()
            dispatched = false
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false,
                { "held" }
            )

            widget:submit()

            assert.is_true(vim.bo[widget.buf_nrs.input].modified)
        end)
    end)

    describe("prompt navigation", function()
        local MessageWriter = require("agentic.ui.message_writer")
        local widget
        local writer

        before_each(function()
            vim.cmd("tabnew")
            widget = new_widget(spy.new(function() end) --[[@as function]])
            show(widget)
            writer = MessageWriter:new(widget.buf_nrs.chat)
        end)

        after_each(function()
            pcall(function()
                widget:destroy()
            end)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        --- 0-indexed rows carrying a user-action marker.
        local function marker_rows()
            local marks = vim.api.nvim_buf_get_extmarks(
                widget.buf_nrs.chat,
                MessageWriter.NS_USER_ACTIONS,
                0,
                -1,
                {}
            )
            return vim.tbl_map(function(m)
                return m[2]
            end, marks)
        end

        --- @return integer cursor_row 0-indexed
        local function cursor_row()
            return vim.api.nvim_win_get_cursor(0)[1] - 1
        end

        it("[[ and ]] land on markers and skip agent ## headings", function()
            writer:write_user_prompt("First prompt")
            writer:write_message({
                sessionUpdate = "agent_message_chunk",
                content = { type = "text", text = "## Not a prompt\nbody" },
            })
            writer:write_user_prompt("Second prompt")

            local rows = marker_rows()
            assert.equal(2, #rows)
            local first, second = rows[1], rows[2]

            -- From the bottom, [[ walks back through both prompts, never the
            -- agent-authored ## line.
            vim.api.nvim_win_set_cursor(
                0,
                { vim.api.nvim_buf_line_count(widget.buf_nrs.chat), 0 }
            )
            press("[[")
            assert.equal(second, cursor_row())
            press("[[")
            assert.equal(first, cursor_row())

            press("]]")
            assert.equal(second, cursor_row())
        end)

        it("]] stops on a command notice between prompts", function()
            writer:write_user_prompt("First prompt")
            writer:write_notice({
                glyph = Glyphs.COMMAND.rename,
                title = "New Name",
            })

            local rows = marker_rows()
            assert.equal(2, #rows)

            vim.api.nvim_win_set_cursor(0, { rows[1] + 1, 0 })
            press("]]")
            assert.equal(rows[2], cursor_row())
        end)

        it("reset() removes user-action markers", function()
            writer:write_user_prompt("A prompt")
            assert.equal(1, #marker_rows())

            widget:clear()
            writer:reset()

            assert.same({}, marker_rows())
        end)

        it("reset() removes region rails", function()
            local function decoration_marks()
                return vim.api.nvim_buf_get_extmarks(
                    widget.buf_nrs.chat,
                    Renderer.NS_DECORATIONS,
                    0,
                    -1,
                    {}
                )
            end

            writer:write_user_prompt("A prompt\nwith a body")
            assert.is_true(#decoration_marks() > 0)

            widget:clear()
            writer:reset()

            assert.same({}, decoration_marks())
        end)

        it("clear() preserves the input buffer draft", function()
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false,
                { "unsent draft" }
            )

            widget:clear()

            assert.same(
                { "unsent draft" },
                vim.api.nvim_buf_get_lines(widget.buf_nrs.input, 0, -1, false)
            )
        end)
    end)

    describe("partial_send", function()
        local widget
        local input_win
        local submit_spy
        local debug_spy
        local original_send_register

        before_each(function()
            vim.cmd("tabnew")
            submit_spy = spy.new(function()
                return true
            end)
            widget = new_widget(submit_spy --[[@as function]])
            show(widget)
            input_win = widget:input_win() --[[@as integer]]
            vim.api.nvim_set_current_win(input_win)
            debug_spy = spy.on(Logger, "debug")
            original_send_register = Config.settings.send_register
            Config.settings.send_register = nil
        end)

        after_each(function()
            Config.settings.send_register = original_send_register
            debug_spy:revert()
            pcall(function()
                widget:destroy()
            end)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        local function set_input(lines)
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false,
                lines
            )
        end

        local function input_lines()
            return vim.api.nvim_buf_get_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false
            )
        end

        describe("_send_line", function()
            it("sends current line and removes it from buffer", function()
                set_input({ "alpha", "beta", "gamma" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                widget:_send_line()

                assert.spy(submit_spy).was.called(1)
                assert.equal("alpha", submit_spy.calls[1][1])
                assert.same({ "beta", "gamma" }, input_lines())
            end)

            it("no-op on empty buffer", function()
                set_input({ "" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                widget:_send_line()

                assert.spy(submit_spy).was.called(0)
            end)

            it("no-op on whitespace-only line", function()
                set_input({ "   \t ", "beta" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                widget:_send_line()

                assert.spy(submit_spy).was.called(0)
                assert.same({ "   \t ", "beta" }, input_lines())
            end)
        end)

        describe("_send_operator", function()
            it("linewise: sends line range and removes from buffer", function()
                set_input({ "alpha", "beta", "gamma", "delta" })
                vim.api.nvim_buf_set_mark(widget.buf_nrs.input, "[", 2, 0, {})
                vim.api.nvim_buf_set_mark(widget.buf_nrs.input, "]", 3, 0, {})

                widget:_send_operator("line")

                assert.spy(submit_spy).was.called(1)
                assert.equal("beta\ngamma", submit_spy.calls[1][1])
                assert.same({ "alpha", "delta" }, input_lines())
            end)

            it("charwise: sends substring and splices it out", function()
                set_input({ "hello world" })
                -- Select "world" (chars 6..10 inclusive, 0-indexed cols)
                vim.api.nvim_buf_set_mark(widget.buf_nrs.input, "[", 1, 6, {})
                vim.api.nvim_buf_set_mark(widget.buf_nrs.input, "]", 1, 10, {})

                widget:_send_operator("char")

                assert.spy(submit_spy).was.called(1)
                assert.equal("world", submit_spy.calls[1][1])
                assert.same({ "hello " }, input_lines())
            end)

            it("block: no-op with debug log", function()
                set_input({ "alpha", "beta" })

                widget:_send_operator("block")

                assert.spy(submit_spy).was.called(0)
                assert.is_true(debug_spy.call_count >= 1)
            end)
        end)

        describe("submit regression", function()
            local ns = vim.api.nvim_create_namespace("agentic_queued_region")

            it("no-arg path still sends whole buffer and clears it", function()
                set_input({ "line1", "line2" })

                widget:submit()

                assert.spy(submit_spy).was.called(1)
                assert.equal("line1\nline2", submit_spy.calls[1][1])
                assert.same({ "" }, input_lines())
            end)

            it("tags and keeps the text when the session defers", function()
                Config.settings.send_register = "a"
                vim.fn.setreg("a", "untouched")
                set_input({ "line1", "line2" })
                submit_spy = spy.new(function()
                    return false
                end)
                widget.on_submit_input = submit_spy

                widget:submit()

                assert.spy(submit_spy).was.called(1)
                assert.same({ "line1", "line2" }, input_lines())
                -- One tag over the whole submitted range.
                local marks = vim.api.nvim_buf_get_extmarks(
                    widget.buf_nrs.input,
                    ns,
                    0,
                    -1,
                    { details = true }
                )
                assert.equal(1, #marks)
                assert.equal(0, marks[1][2])
                assert.equal(1, marks[1][4].end_row)
                -- Nothing was sent, so the register is not written.
                assert.equal("untouched", vim.fn.getreg("a"))
                -- Unsent text is unsaved text.
                assert.is_true(vim.bo[widget.buf_nrs.input].modified)
            end)

            it("dispatches the first block and tags the rest", function()
                set_input({ "/compact", "then continue" })

                widget:submit()

                assert.spy(submit_spy).was.called(1)
                assert.equal("/compact", submit_spy.calls[1][1])
                -- The remainder stays visible and editable, tagged for the
                -- drain that runs at the command's turn end.
                assert.same({ "then continue" }, input_lines())
                local marks = vim.api.nvim_buf_get_extmarks(
                    widget.buf_nrs.input,
                    ns,
                    0,
                    -1,
                    { details = true }
                )
                assert.equal(1, #marks)
                assert.same({ 0, 0 }, { marks[1][2], marks[1][4].end_row })
            end)

            it("tags the deferred head above the untouched rest", function()
                set_input({ "/compact", "then continue" })
                widget.on_submit_input = spy.new(function()
                    return false
                end)

                widget:submit()

                assert.same({ "/compact", "then continue" }, input_lines())
                local marks = vim.api.nvim_buf_get_extmarks(
                    widget.buf_nrs.input,
                    ns,
                    0,
                    -1,
                    { details = true }
                )
                assert.equal(2, #marks)
                assert.same({ 0, 0 }, { marks[1][2], marks[1][4].end_row })
                assert.same({ 1, 1 }, { marks[2][2], marks[2][4].end_row })
            end)

            it("passes force through from the write commands", function()
                set_input({ "line1" })

                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)
                vim.api.nvim_exec_autocmds("BufWriteCmd", {
                    buffer = widget.buf_nrs.input,
                })
                schedule_stub:revert()

                assert.spy(submit_spy).was.called(1)
                assert.is_true(submit_spy.calls[1][2].force)
            end)

            it("moves the cursor to the chat when configured", function()
                local original = Config.settings.move_cursor_to_chat_on_submit
                Config.settings.move_cursor_to_chat_on_submit = true
                MiniTest.finally(function()
                    Config.settings.move_cursor_to_chat_on_submit = original
                end)
                local deferred = capture_deferred()
                set_input({ "line1" })

                widget:submit()
                deferred.drain()

                assert.equal(widget:home_win(), vim.api.nvim_get_current_win())
            end)
        end)

        describe("send_register", function()
            it("writes sent text when configured (linewise)", function()
                Config.settings.send_register = "a"
                vim.fn.setreg("a", "")
                set_input({ "alpha", "beta" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                widget:_send_line()

                assert.equal("alpha\n", vim.fn.getreg("a"))
                assert.equal("V", vim.fn.getregtype("a"))
            end)

            it("leaves register untouched when nil", function()
                vim.fn.setreg("a", "preserved")
                set_input({ "alpha" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                widget:_send_line()

                assert.equal("preserved", vim.fn.getreg("a"))
            end)

            it("uses charwise regtype for char delete_range", function()
                Config.settings.send_register = "a"
                vim.fn.setreg("a", "")
                set_input({ "hello world" })
                vim.api.nvim_buf_set_mark(widget.buf_nrs.input, "[", 1, 6, {})
                vim.api.nvim_buf_set_mark(widget.buf_nrs.input, "]", 1, 10, {})

                widget:_send_operator("char")

                assert.equal("world", vim.fn.getreg("a"))
                assert.equal("v", vim.fn.getregtype("a"))
            end)
        end)
    end)

    describe("queue", function()
        local ns = vim.api.nvim_create_namespace("agentic_queued_region")
        local widget
        local input_win
        local submit_spy

        before_each(function()
            vim.cmd("tabnew")
            submit_spy = spy.new(function()
                return true
            end)
            widget = new_widget(submit_spy --[[@as function]])
            show(widget)
            input_win = widget:input_win() --[[@as integer]]
            vim.api.nvim_set_current_win(input_win)
        end)

        after_each(function()
            pcall(function()
                widget:destroy()
            end)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        local function set_input(lines)
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false,
                lines
            )
        end

        local function input_lines()
            return vim.api.nvim_buf_get_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false
            )
        end

        --- Tagged regions as `{ start_row, end_row }` pairs in buffer order.
        local function tags()
            local marks = vim.api.nvim_buf_get_extmarks(
                widget.buf_nrs.input,
                ns,
                0,
                -1,
                { details = true }
            )
            return vim.tbl_map(function(m)
                return { m[2], m[4].end_row }
            end, marks)
        end

        it("tags the cursor line and never sends, even when idle", function()
            set_input({ "one", "two", "three" })
            vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

            widget:_queue_line()

            assert.same({ { 0, 0 } }, tags())
            assert.spy(submit_spy).was.called(0)
            assert.same({ "one", "two", "three" }, input_lines())
        end)

        it("re-queueing an overlapping range replaces, never stacks", function()
            set_input({ "one", "two", "three", "four" })
            widget:_queue_line_range(1, 1)
            widget:_queue_line_range(0, 2)

            assert.same({ { 0, 2 } }, tags())
        end)

        -- Sending the line above a region must not drop it to draft: the
        -- delete abuts the region, which is indistinguishable from an edit
        -- inside it unless the dispatch says so.
        it("keeps a region tagged when the line above it is sent", function()
            set_input({ "send me", "queued task" })
            widget:_queue_line_range(1, 1)
            vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

            widget:_send_line()

            assert.same({ "queued task" }, input_lines())
            assert.same({ { 0, 0 } }, tags())
        end)

        it("editing inside a region drops its tag", function()
            set_input({ "one", "two", "three" })
            widget:_queue_line_range(0, 1)
            assert.equal(1, #tags())

            vim.api.nvim_buf_set_text(widget.buf_nrs.input, 0, 3, 0, 3, { "X" })

            assert.equal(0, #tags())
        end)

        it("editing outside a region leaves its tag", function()
            set_input({ "one", "two", "three" })
            widget:_queue_line_range(0, 0)

            vim.api.nvim_buf_set_text(widget.buf_nrs.input, 2, 0, 2, 0, { "X" })

            assert.equal(1, #tags())
        end)

        it("entering insert inside a region drops its tag", function()
            set_input({ "one", "two", "three" })
            widget:_queue_line_range(1, 1)
            vim.api.nvim_win_set_cursor(input_win, { 2, 0 })

            vim.api.nvim_exec_autocmds(
                "InsertEnter",
                { buffer = widget.buf_nrs.input }
            )

            assert.equal(0, #tags())
        end)

        it("cancel_queue clears every tag, leaving text in place", function()
            set_input({ "one", "two", "three" })
            widget:_queue_line_range(0, 0)
            widget:_queue_line_range(2, 2)
            assert.equal(2, #tags())

            widget:cancel_queue()

            assert.equal(0, #tags())
            assert.same({ "one", "two", "three" }, input_lines())
        end)

        it("reads the topmost region's first block, consuming none", function()
            set_input({ "one", "two", "three" })
            -- Queue bottom then top: buffer order must still be top-to-bottom.
            widget:_queue_line_range(2, 2)
            widget:_queue_line_range(0, 0)

            assert.equal("one", widget:next_queued_block().text)
            -- A caller that decides not to dispatch leaves them visible.
            assert.equal(2, #tags())
            assert.same({ "one", "two", "three" }, input_lines())
        end)

        it("splits a region into one block per command line", function()
            set_input({ "/compact", "then continue", "with X" })
            widget:_queue_line_range(0, 2)

            assert.equal(2, widget:queued_block_count())
            assert.equal("/compact", widget:next_queued_block().text)
        end)

        it("consuming a region's only block takes the region", function()
            set_input({ "one", "two", "three" })
            widget:_queue_line_range(2, 2)
            widget:_queue_line_range(0, 0)

            widget:consume_queued_block()

            assert.same({ { 1, 1 } }, tags())
            assert.same({ "two", "three" }, input_lines())
        end)

        -- Consuming a region's last block must delete its mark: a collapsed
        -- zero-width mark would read the untagged draft line below it as the
        -- next queued block and send it.
        it("never reads the draft line below a consumed region", function()
            set_input({ "queued", "draft" })
            widget:_queue_line_range(0, 0)

            widget:consume_queued_block()

            assert.same({}, tags())
            assert.is_nil(widget:next_queued_block())
            assert.same({ "draft" }, input_lines())
        end)

        it("consuming one block of a region leaves the rest tagged", function()
            set_input({ "/compact", "then continue", "draft" })
            widget:_queue_line_range(0, 1)

            widget:consume_queued_block()

            assert.same({ { 0, 0 } }, tags())
            assert.same({ "then continue", "draft" }, input_lines())
            assert.equal("then continue", widget:next_queued_block().text)
        end)

        it("reads nil when nothing is queued", function()
            set_input({ "one" })
            assert.is_nil(widget:next_queued_block())
            assert.equal(0, widget:queued_block_count())
        end)

        it("clamps a count past buffer end (no crash)", function()
            set_input({ "one", "two" })
            vim.api.nvim_win_set_cursor(input_win, { 1, 0 })
            -- Drive via a real mapping so vim.v.count1 reflects the typed count.
            vim.keymap.set("n", "<Plug>(agentic-test-queue)", function()
                widget:_queue_line()
            end, { buffer = widget.buf_nrs.input })
            vim.api.nvim_feedkeys(
                "9"
                    .. vim.api.nvim_replace_termcodes(
                        "<Plug>(agentic-test-queue)",
                        true,
                        true,
                        true
                    ),
                "x",
                false
            )

            -- Clamped to the last line (row 1), not row 8.
            assert.same({ { 0, 1 } }, tags())
        end)
    end)
end)
