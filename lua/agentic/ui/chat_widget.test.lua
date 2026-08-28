local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local Glyphs = require("agentic.glyphs")
local Logger = require("agentic.utils.logger")
local Renderer = require("agentic.ui.tool_call_renderer")

describe("agentic.ui.ChatWidget", function()
    --- @type agentic.ui.ChatWidget
    local ChatWidget

    ChatWidget = require("agentic.ui.chat_widget")

    --- Helper to populate a dynamic buffer with content
    --- @param widget agentic.ui.ChatWidget
    --- @param name string
    --- @param content string[]
    local function fill_buffer(widget, name, content)
        local bufnr = widget.buf_nrs[name]
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    end

    -- Tests that behave identically regardless of layout position
    for _, position in ipairs({ "right", "left", "bottom" }) do
        -- Bottom layout uses 2 to avoid touching the screen edge
        local padding = position == "bottom" and 2 or 1

        describe(string.format("(%s layout)", position), function()
            local tab_page_id
            local widget
            local original_position

            local original_lines

            before_each(function()
                original_lines = vim.o.lines
                -- Ensure enough vertical space for layout calculations
                vim.o.lines = 100

                original_position = Config.windows.position
                Config.windows.position = position

                vim.cmd("tabnew")
                tab_page_id = vim.api.nvim_get_current_tabpage()

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(
                    tab_page_id,
                    on_submit_spy --[[@as function]]
                )
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

                Config.windows.position = original_position
                vim.o.lines = original_lines
            end)

            it("creates widget with valid buffer IDs", function()
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.chat))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.input))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.code))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.files))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.todos))
            end)

            it(
                "show() creates chat and input windows only when buffers are empty",
                function()
                    assert.is_falsy(widget:is_open())

                    widget:show()

                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.chat)
                    )
                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.input)
                    )
                    assert.is_nil(widget.win_nrs.code)
                    assert.is_nil(widget.win_nrs.files)
                    assert.is_nil(widget.win_nrs.todos)
                end
            )

            it("hide() closes all windows and preserves buffers", function()
                widget:show()

                local chat_win = widget.win_nrs.chat
                local input_win = widget.win_nrs.input
                local chat_buf = widget.buf_nrs.chat
                local input_buf = widget.buf_nrs.input

                widget:hide()

                assert.is_false(vim.api.nvim_win_is_valid(chat_win))
                assert.is_false(vim.api.nvim_win_is_valid(input_win))
                assert.is_nil(widget.win_nrs.chat)
                assert.is_nil(widget.win_nrs.input)
                assert.is_falsy(widget:is_open())

                assert.equal(chat_buf, widget.buf_nrs.chat)
                assert.equal(input_buf, widget.buf_nrs.input)
                assert.is_true(vim.api.nvim_buf_is_valid(chat_buf))
                assert.is_true(vim.api.nvim_buf_is_valid(input_buf))
            end)

            it("show() is idempotent when called multiple times", function()
                widget:show()
                local first_chat_win = widget.win_nrs.chat

                widget:show()

                assert.equal(first_chat_win, widget.win_nrs.chat)
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            end)

            it("hide() is safe when called multiple times", function()
                widget:show()
                widget:hide()

                assert.has_no_errors(function()
                    widget:hide()
                end)
            end)

            it("show() after hide() creates new windows", function()
                widget:show()
                local first_chat_win = widget.win_nrs.chat
                widget:hide()

                widget:show()

                assert.are_not.equal(first_chat_win, widget.win_nrs.chat)
                assert.is_false(vim.api.nvim_win_is_valid(first_chat_win))
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            end)

            it("windows are created in correct tabpage", function()
                widget:show()

                assert.equal(
                    tab_page_id,
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.chat)
                )
                assert.equal(
                    tab_page_id,
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.input)
                )
            end)

            it("hide() stops insert mode", function()
                widget:show()
                vim.api.nvim_set_current_win(widget.win_nrs.input)
                vim.cmd("startinsert")

                widget:hide()

                assert.are_not.equal("i", vim.fn.mode())
            end)

            describe("dynamic window creation", function()
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
                }

                for _, tc in ipairs(test_cases) do
                    it(
                        string.format(
                            "creates %s window when buffer has content",
                            tc.name
                        ),
                        function()
                            fill_buffer(widget, tc.name, tc.content)
                            widget:show()

                            assert.is_true(
                                vim.api.nvim_win_is_valid(
                                    widget.win_nrs[tc.name]
                                )
                            )
                            assert.equal(
                                tab_page_id,
                                vim.api.nvim_win_get_tabpage(
                                    widget.win_nrs[tc.name]
                                )
                            )
                        end
                    )
                end
            end)

            it("hide() closes all dynamic windows when they exist", function()
                for _, name in ipairs({ "files", "code", "todos" }) do
                    fill_buffer(widget, name, { "content" })
                end

                widget:show()

                local files_win = widget.win_nrs.files
                local code_win = widget.win_nrs.code
                local todos_win = widget.win_nrs.todos

                widget:hide()

                assert.is_false(vim.api.nvim_win_is_valid(files_win))
                assert.is_false(vim.api.nvim_win_is_valid(code_win))
                assert.is_false(vim.api.nvim_win_is_valid(todos_win))
                assert.is_nil(widget.win_nrs.files)
                assert.is_nil(widget.win_nrs.code)
                assert.is_nil(widget.win_nrs.todos)
            end)

            it("caps window height at max_height", function()
                local lines = {}
                for i = 1, 23 do
                    lines[i] = "line" .. i
                end
                fill_buffer(widget, "code", lines)

                widget:show()

                local height = vim.api.nvim_win_get_height(widget.win_nrs.code)
                assert.equal(15, height)
            end)

            it(
                string.format("dynamic window uses %d line(s) padding", padding),
                function()
                    fill_buffer(widget, "code", { "line1", "line2", "line3" })

                    widget:show()

                    local height =
                        vim.api.nvim_win_get_height(widget.win_nrs.code)
                    assert.equal(3 + padding, height)
                end
            )

            it("resizes window when content changes", function()
                fill_buffer(widget, "code", { "line1", "line2", "line3" })

                widget:show()
                assert.equal(
                    3 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )

                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    3,
                    3,
                    false,
                    { "line4", "line5", "line6", "line7" }
                )

                widget:show({ focus_prompt = false })

                assert.equal(
                    7 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )
            end)

            it("shrinks window when content is removed", function()
                fill_buffer(
                    widget,
                    "code",
                    { "line1", "line2", "line3", "line4", "line5" }
                )

                widget:show()
                assert.equal(
                    5 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )

                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "line1", "line2" }
                )

                widget:show({ focus_prompt = false })

                assert.equal(
                    2 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )
            end)

            describe("show() re-renders dynamic windows", function()
                it("closes window when buffer becomes empty", function()
                    fill_buffer(widget, "code", { "line1" })

                    widget:show()
                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.code)
                    )

                    vim.api.nvim_buf_set_lines(
                        widget.buf_nrs.code,
                        0,
                        -1,
                        false,
                        {}
                    )

                    widget:show({ focus_prompt = false })

                    assert.is_nil(widget.win_nrs.code)
                end)

                it("creates window on show when content exists", function()
                    fill_buffer(widget, "code", { "line1" })

                    assert.has_no_errors(function()
                        widget:show({ focus_prompt = false })
                    end)

                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.code)
                    )
                end)
            end)
        end)
    end

    -- Right and left layouts behave identically, only split direction differs
    for _, side in ipairs({ "right", "left" }) do
        describe(string.format("(%s layout) specific", side), function()
            local widget
            local original_position

            before_each(function()
                original_position = Config.windows.position
                Config.windows.position = side

                vim.cmd("tabnew")

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(
                    vim.api.nvim_get_current_tabpage(),
                    on_submit_spy --[[@as function]]
                )
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

                Config.windows.position = original_position
            end)

            it("input splits below chat", function()
                widget:show()

                local chat_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.chat)
                local input_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.input)

                -- Input row should be greater than chat row (below)
                assert.is_true(input_pos[1] > chat_pos[1])
                -- Same column position
                assert.equal(chat_pos[2], input_pos[2])
            end)

            it("input has fixed height", function()
                widget:show()

                local input_height =
                    vim.api.nvim_win_get_height(widget.win_nrs.input)
                assert.equal(Config.windows.input.height, input_height)
            end)
        end)
    end

    describe("(bottom layout) specific", function()
        local widget
        local original_position

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "bottom"

            vim.cmd("tabnew")

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy --[[@as function]]
            )
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

            Config.windows.position = original_position
        end)

        it("input splits right of chat", function()
            widget:show()

            local chat_pos = vim.api.nvim_win_get_position(widget.win_nrs.chat)
            local input_pos =
                vim.api.nvim_win_get_position(widget.win_nrs.input)

            -- Same row (horizontal split)
            assert.equal(chat_pos[1], input_pos[1])
            -- Input column should be greater than chat column (to the right)
            assert.is_true(input_pos[2] > chat_pos[2])
        end)

        it(
            "input width is proportional to chat via stack_width_ratio",
            function()
                widget:show()

                local chat_width =
                    vim.api.nvim_win_get_width(widget.win_nrs.chat)
                local input_width =
                    vim.api.nvim_win_get_width(widget.win_nrs.input)
                local ratio = Config.windows.stack_width_ratio

                local expected = math.floor((chat_width + input_width) * ratio)

                -- Allow +-1 rounding tolerance
                assert.is_true(math.abs(input_width - expected) <= 1)
            end
        )
    end)

    describe("rotate_layout", function()
        local widget
        local original_position
        local show_stub
        local notify_stub

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "right"

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy --[[@as function]]
            )

            show_stub = spy.stub(widget, "show")
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            show_stub:revert()
            notify_stub:revert()

            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end

            Config.windows.position = original_position
        end)

        it("uses default layouts when none provided", function()
            Config.windows.position = "right"

            widget:rotate_layout()

            assert.equal("bottom", Config.windows.position)
        end)

        it("uses default layouts when empty array provided", function()
            Config.windows.position = "right"

            widget:rotate_layout({})

            assert.equal("bottom", Config.windows.position)
        end)

        it(
            "stays on same layout and warns when only one is provided",
            function()
                Config.windows.position = "bottom"

                widget:rotate_layout({ "bottom" })

                assert.equal("bottom", Config.windows.position)
                assert.spy(notify_stub).was.called(1)
                local msg = notify_stub.calls[1][1]
                assert.is_true(msg:find("Only one layout") ~= nil)
            end
        )

        it("rotates through all layouts in order", function()
            local layouts = { "right", "bottom", "left" }

            Config.windows.position = "right"
            widget:rotate_layout(layouts)
            assert.equal("bottom", Config.windows.position)

            widget:rotate_layout(layouts)
            assert.equal("left", Config.windows.position)

            widget:rotate_layout(layouts)
            assert.equal("right", Config.windows.position)
        end)

        it("falls back to first layout when current is not in list", function()
            Config.windows.position = "bottom"

            widget:rotate_layout({ "right", "left" })

            assert.equal("right", Config.windows.position)
        end)

        it("calls show with focus_prompt false", function()
            widget:rotate_layout()

            assert.spy(show_stub).was.called(1)
            local call_args = show_stub.calls[1]
            -- call_args[1] is self, call_args[2] is the opts table
            assert.equal(false, call_args[2].focus_prompt)
        end)
    end)

    describe(":wq / :x and :q behaviour", function()
        local widget
        local submit_spy
        local hide_spy

        before_each(function()
            vim.cmd("tabnew")
            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy --[[@as function]]
            )
            widget:show()
            submit_spy = spy.on(widget, "submit")
            hide_spy = spy.on(widget, "hide")
        end)

        after_each(function()
            submit_spy:revert()
            hide_spy:revert()
            pcall(function()
                widget:destroy()
            end)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        --- Type an ex-command through the interactive cmdline so the
        --- CmdlineLeave quit-guard fires (`vim.cmd` bypasses it).
        --- @param cmd string
        local function feed_cmdline(cmd)
            vim.api.nvim_feedkeys(
                vim.api.nvim_replace_termcodes(
                    ":" .. cmd .. "<CR>",
                    true,
                    false,
                    true
                ),
                "x",
                false
            )
        end

        it(":Wq submits and closes only the input window", function()
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false,
                { "hello" }
            )
            local chat_win = widget.win_nrs.chat
            local input_win = widget.win_nrs.input
            vim.api.nvim_set_current_win(input_win)
            vim.cmd("Wq")

            assert.spy(submit_spy).was.called(1)
            assert.spy(hide_spy).was.called(0)
            assert.is_false(vim.api.nvim_win_is_valid(input_win))
            assert.is_nil(widget.win_nrs.input)
            assert.is_true(vim.api.nvim_win_is_valid(chat_win))
        end)

        it(":Wq! submits and hides the whole widget", function()
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false,
                { "hello" }
            )
            vim.api.nvim_set_current_win(widget.win_nrs.input)
            vim.cmd("Wq!")

            assert.spy(submit_spy).was.called(1)
            assert.is_true(hide_spy.call_count >= 1)
        end)

        it(":X submits and closes only the input window", function()
            local chat_win = widget.win_nrs.chat
            local input_win = widget.win_nrs.input
            vim.api.nvim_set_current_win(input_win)
            vim.cmd("X")

            assert.spy(submit_spy).was.called(1)
            assert.spy(hide_spy).was.called(0)
            assert.is_false(vim.api.nvim_win_is_valid(input_win))
            assert.is_true(vim.api.nvim_win_is_valid(chat_win))
        end)

        it(":X! submits and hides the whole widget", function()
            vim.api.nvim_set_current_win(widget.win_nrs.input)
            vim.cmd("X!")

            assert.spy(submit_spy).was.called(1)
            assert.is_true(hide_spy.call_count >= 1)
        end)

        it(":q on an empty input closes only the input window", function()
            local chat_win = widget.win_nrs.chat
            local input_win = widget.win_nrs.input
            vim.api.nvim_set_current_win(input_win)

            feed_cmdline("q")
            vim.wait(200, function()
                return not vim.api.nvim_win_is_valid(input_win)
            end)

            assert.is_false(vim.api.nvim_win_is_valid(input_win))
            assert.is_nil(widget.win_nrs.input)
            assert.is_true(vim.api.nvim_win_is_valid(chat_win))
        end)

        it(":q abandoned with <C-c> closes nothing", function()
            local input_win = widget.win_nrs.input
            vim.api.nvim_set_current_win(input_win)

            -- <C-c> abandons the cmdline: CmdlineLeave fires with
            -- v:event.abort = true and no quit runs, so the guard must leave
            -- the (empty) input window open.
            vim.api.nvim_feedkeys(
                vim.api.nvim_replace_termcodes(":q<C-c>", true, false, true),
                "nx",
                false
            )
            vim.wait(50)

            assert.is_true(vim.api.nvim_win_is_valid(input_win))
            assert.is_not_nil(widget.win_nrs.input)
        end)

        it(":q on a non-empty input warns and closes nothing", function()
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.input,
                0,
                -1,
                false,
                { "draft" }
            )
            local chat_win = widget.win_nrs.chat
            local input_win = widget.win_nrs.input
            vim.api.nvim_set_current_win(input_win)

            feed_cmdline("q")

            assert.is_true(vim.api.nvim_win_is_valid(input_win))
            assert.is_true(vim.api.nvim_win_is_valid(chat_win))
        end)

        it(":q in the chat warns and closes nothing", function()
            local chat_win = widget.win_nrs.chat
            local input_win = widget.win_nrs.input
            vim.api.nvim_set_current_win(chat_win)

            feed_cmdline("q")

            assert.is_true(vim.api.nvim_win_is_valid(chat_win))
            assert.is_true(vim.api.nvim_win_is_valid(input_win))
            assert.spy(hide_spy).was.called(0)
        end)

        it(
            "an insert key in the chat reopens a closed input window",
            function()
                widget:close_input_window()
                assert.is_nil(widget.win_nrs.input)

                vim.api.nvim_set_current_win(widget.win_nrs.chat)
                widget:focus_input_for_insert()

                assert.is_true(
                    vim.api.nvim_win_is_valid(widget.win_nrs.input)
                )
            end
        )
    end)

    describe("prompt navigation", function()
        local MessageWriter = require("agentic.ui.message_writer")
        local widget
        local writer

        before_each(function()
            vim.cmd("tabnew")
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                spy.new(function() end) --[[@as function]]
            )
            widget:show()
            vim.api.nvim_set_current_win(widget.win_nrs.chat)
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

        local function press(keys)
            vim.api.nvim_feedkeys(keys, "x", false)
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
                glyph = Glyphs.NOTICE.RENAME,
                title = "New Name",
            })

            local rows = marker_rows()
            assert.equal(2, #rows)

            vim.api.nvim_win_set_cursor(0, { rows[1] + 1, 0 })
            press("]]")
            assert.equal(rows[2], cursor_row())
        end)

        it("clear() removes user-action markers", function()
            writer:write_user_prompt("A prompt")
            assert.equal(1, #marker_rows())

            widget:clear()

            assert.same({}, marker_rows())
        end)

        it("clear() removes region rails", function()
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
        local submit_spy
        local debug_spy
        local original_send_register

        before_each(function()
            vim.cmd("tabnew")
            submit_spy = spy.new(function() end)
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                submit_spy --[[@as function]]
            )
            widget:show()
            vim.api.nvim_set_current_win(widget.win_nrs.input)
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
                vim.api.nvim_win_set_cursor(widget.win_nrs.input, { 1, 0 })

                widget:_send_line()

                assert.spy(submit_spy).was.called(1)
                assert.equal("alpha", submit_spy.calls[1][1])
                assert.same({ "beta", "gamma" }, input_lines())
            end)

            it("no-op on empty buffer", function()
                set_input({ "" })
                vim.api.nvim_win_set_cursor(widget.win_nrs.input, { 1, 0 })

                widget:_send_line()

                assert.spy(submit_spy).was.called(0)
            end)

            it("no-op on whitespace-only line", function()
                set_input({ "   \t ", "beta" })
                vim.api.nvim_win_set_cursor(widget.win_nrs.input, { 1, 0 })

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
            it("no-arg path still sends whole buffer and clears it", function()
                set_input({ "line1", "line2" })

                widget:submit()

                assert.spy(submit_spy).was.called(1)
                assert.equal("line1\nline2", submit_spy.calls[1][1])
                assert.same({ "" }, input_lines())
            end)
        end)

        describe("send_register", function()
            it("writes sent text when configured (linewise)", function()
                Config.settings.send_register = "a"
                vim.fn.setreg("a", "")
                set_input({ "alpha", "beta" })
                vim.api.nvim_win_set_cursor(widget.win_nrs.input, { 1, 0 })

                widget:_send_line()

                assert.equal("alpha\n", vim.fn.getreg("a"))
                assert.equal("V", vim.fn.getregtype("a"))
            end)

            it("leaves register untouched when nil", function()
                vim.fn.setreg("a", "preserved")
                set_input({ "alpha" })
                vim.api.nvim_win_set_cursor(widget.win_nrs.input, { 1, 0 })

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
        local submit_spy

        before_each(function()
            vim.cmd("tabnew")
            submit_spy = spy.new(function() end)
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                submit_spy --[[@as function]]
            )
            widget:show()
            vim.api.nvim_set_current_win(widget.win_nrs.input)
            -- Default to generating so queue keymaps defer rather than send.
            widget.on_query_generating = function()
                return true
            end
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
            vim.api.nvim_buf_set_lines(widget.buf_nrs.input, 0, -1, false, lines)
        end

        local function input_lines()
            return vim.api.nvim_buf_get_lines(widget.buf_nrs.input, 0, -1, false)
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

        it("tags the cursor line while generating, does not send", function()
            set_input({ "one", "two", "three" })
            vim.api.nvim_win_set_cursor(widget.win_nrs.input, { 1, 0 })

            widget:_queue_line()

            assert.same({ { 0, 0 } }, tags())
            assert.spy(submit_spy).was.called(0)
            assert.same({ "one", "two", "three" }, input_lines())
        end)

        it("sends immediately when idle (no turn to defer to)", function()
            widget.on_query_generating = function()
                return false
            end
            set_input({ "one", "two" })
            vim.api.nvim_win_set_cursor(widget.win_nrs.input, { 1, 0 })

            widget:_queue_line()

            assert.spy(submit_spy).was.called(1)
            assert.equal("one", submit_spy.calls[1][1])
            assert.equal(0, #tags())
            assert.same({ "two" }, input_lines())
        end)

        it("re-queueing an overlapping range replaces, never stacks", function()
            set_input({ "one", "two", "three", "four" })
            widget:_queue_line_range(1, 1)
            widget:_queue_line_range(0, 2)

            assert.same({ { 0, 2 } }, tags())
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
            vim.api.nvim_win_set_cursor(widget.win_nrs.input, { 2, 0 })

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

        it("drain returns regions in buffer order and deletes them", function()
            set_input({ "one", "two", "three" })
            -- Queue bottom then top: buffer order must still be top-to-bottom.
            widget:_queue_line_range(2, 2)
            widget:_queue_line_range(0, 0)

            local text = widget:drain_queued_regions()

            assert.equal("one\n\nthree", text)
            assert.equal(0, #tags())
            assert.same({ "two" }, input_lines())
        end)

        it("drain returns nil when nothing is queued", function()
            set_input({ "one" })
            assert.is_nil(widget:drain_queued_regions())
        end)

        it("clamps a count past buffer end (no crash)", function()
            set_input({ "one", "two" })
            vim.api.nvim_win_set_cursor(widget.win_nrs.input, { 1, 0 })
            -- Drive via a real mapping so vim.v.count1 reflects the typed count.
            vim.keymap.set("n", "<Plug>(agentic-test-queue)", function()
                widget:_queue_line()
            end, { buffer = widget.buf_nrs.input })
            vim.api.nvim_feedkeys(
                "9" .. vim.api.nvim_replace_termcodes(
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
