local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local WidgetLayout = require("agentic.ui.widget_layout")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

describe("WidgetLayout", function()
    local original_position
    local notify_stub
    --- The panel buffers of the test, filled by `panel_buf`.
    --- @type agentic.ui.ChatWidget.BufNrs
    local buf_nrs

    before_each(function()
        original_position = Config.windows.position
        notify_stub = spy.stub(Logger, "notify")
        buf_nrs = {}
    end)

    after_each(function()
        notify_stub:revert()
        Config.windows.position = original_position
    end)

    describe("calculate_width", function()
        --- @type integer
        local cols
        local default_width_pct =
            tonumber(string.sub(Config.windows.width, 1, -2))

        before_each(function()
            cols = vim.o.columns
        end)

        it("should handle percentage strings", function()
            local width = WidgetLayout.calculate_width(Config.windows.width)
            assert.are.equal(math.floor(cols * default_width_pct / 100), width)
        end)

        it("should handle decimal values", function()
            local width = WidgetLayout.calculate_width(0.3)
            assert.are.equal(math.floor(cols * 0.3), width)
        end)

        it("should handle absolute numbers", function()
            local width = WidgetLayout.calculate_width(80)
            assert.are.equal(80, width)
        end)

        it("should default for invalid values", function()
            local width = WidgetLayout.calculate_width("invalid")
            assert.are.equal(math.floor(cols * default_width_pct / 100), width)
            assert.equal(1, notify_stub.call_count)
        end)

        it("should return at least 1", function()
            local width = WidgetLayout.calculate_width(0.01)
            assert.are.equal(math.max(1, math.floor(cols * 0.01)), width)
        end)
    end)

    describe("calculate_height", function()
        --- @type integer
        local lines
        local default_height_pct =
            tonumber(string.sub(Config.windows.height, 1, -2))

        before_each(function()
            lines = vim.o.lines
        end)

        it("should handle percentage strings", function()
            local height = WidgetLayout.calculate_height(Config.windows.height)
            assert.are.equal(
                math.floor(lines * default_height_pct / 100),
                height
            )
        end)

        it("should handle decimal values", function()
            local height = WidgetLayout.calculate_height(0.4)
            assert.are.equal(math.floor(lines * 0.4), height)
        end)

        it("should handle absolute numbers", function()
            local height = WidgetLayout.calculate_height(25)
            assert.are.equal(25, height)
        end)

        it("should default for invalid values", function()
            local height = WidgetLayout.calculate_height("invalid")
            assert.are.equal(
                math.floor(lines * default_height_pct / 100),
                height
            )
            assert.equal(1, notify_stub.call_count)
        end)

        it("should return at least 1", function()
            local height = WidgetLayout.calculate_height(0.01)
            assert.are.equal(math.max(1, math.floor(lines * 0.01)), height)
        end)
    end)

    --- A new scratch buffer, recorded as the `panel` buffer in `buf_nrs`.
    --- @param panel agentic.ui.ChatWidget.PanelNames
    --- @return integer bufnr
    local function panel_buf(panel)
        local bufnr = vim.api.nvim_create_buf(false, true)
        buf_nrs[panel] = bufnr
        return bufnr
    end

    --- Fill `buf_nrs` with a buffer for each panel the layout opens.
    --- @return agentic.ui.ChatWidget.BufNrs buf_nrs
    local function panel_bufs()
        for _, panel in ipairs({
            "chat",
            "input",
            "code",
            "files",
            "diagnostics",
            "todos",
        }) do
            panel_buf(panel)
        end
        return buf_nrs
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

    describe("panel_win", function()
        it("is the slot's window while it shows the panel buffer", function()
            local winid = split(panel_buf("chat"))
            local win_nrs = { chat = winid }

            assert.equal(
                winid,
                WidgetLayout.panel_win(win_nrs, buf_nrs, "chat")
            )
            assert.is_nil(WidgetLayout.panel_win(win_nrs, buf_nrs, "input"))
            -- Another session's chat buffer.
            assert.is_nil(
                WidgetLayout.panel_win(
                    win_nrs,
                    { chat = vim.api.nvim_create_buf(false, true) },
                    "chat"
                )
            )

            vim.api.nvim_win_close(winid, true)
        end)

        it(
            "is nil while the slot shows another buffer, and back after :b",
            function()
                local chat = panel_buf("chat")
                local winid = split(chat)
                local win_nrs = { chat = winid }

                show_other_buffer(winid)
                assert.is_nil(WidgetLayout.panel_win(win_nrs, buf_nrs, "chat"))
                assert.same({ chat = winid }, win_nrs)

                vim.api.nvim_win_call(winid, function()
                    vim.cmd.buffer(chat)
                end)
                assert.equal(
                    winid,
                    WidgetLayout.panel_win(win_nrs, buf_nrs, "chat")
                )

                vim.api.nvim_win_close(winid, true)
            end
        )

        it("is nil for a closed window", function()
            panel_buf("chat")
            assert.is_nil(
                WidgetLayout.panel_win({ chat = 99999 }, buf_nrs, "chat")
            )
        end)
    end)

    describe("close", function()
        it("should close all panel windows", function()
            local winid = split(panel_buf("chat"))

            local win_nrs = { chat = winid }
            WidgetLayout.close(win_nrs, buf_nrs)

            assert.is_false(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.chat)
        end)

        it("leaves a slot showing another buffer open", function()
            local winid = split(panel_buf("chat"))
            show_other_buffer(winid)

            local win_nrs = { chat = winid }
            WidgetLayout.close(win_nrs, buf_nrs)

            assert.is_true(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.chat)
            vim.api.nvim_win_close(winid, true)
        end)

        it("should handle invalid windows gracefully", function()
            local win_nrs = { chat = 99999 }
            WidgetLayout.close(win_nrs, buf_nrs)
            assert.is_nil(win_nrs.chat)
        end)

        it("should clear all entries from win_nrs table", function()
            local winid1 = split(panel_buf("chat"))
            local winid2 =
                split(panel_buf("input"), { split = "below", win = winid1 })

            local win_nrs = { chat = winid1, input = winid2 }
            WidgetLayout.close(win_nrs, buf_nrs)

            assert.is_nil(win_nrs.chat)
            assert.is_nil(win_nrs.input)
        end)
    end)

    describe("close_optional_window", function()
        it("should close valid window", function()
            local winid = split(panel_buf("code"))

            local win_nrs = { code = winid }
            WidgetLayout.close_optional_window(win_nrs, buf_nrs, "code")

            assert.is_false(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.code)
        end)

        it("leaves a slot showing another buffer open", function()
            local winid = split(panel_buf("code"))
            show_other_buffer(winid)

            local win_nrs = { code = winid }
            WidgetLayout.close_optional_window(win_nrs, buf_nrs, "code")

            assert.is_true(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.code)
            vim.api.nvim_win_close(winid, true)
        end)

        it("should handle invalid windows gracefully", function()
            local win_nrs = { code = 99999 }
            WidgetLayout.close_optional_window(win_nrs, buf_nrs, "code")
            assert.is_nil(win_nrs.code)
        end)

        it("should handle nil windows", function()
            local win_nrs = { code = nil }
            WidgetLayout.close_optional_window(win_nrs, buf_nrs, "code")
            assert.is_nil(win_nrs.code)
        end)

        it("should restore chat height in bottom layout", function()
            Config.windows.position = "bottom"

            local chat_winid =
                split(panel_buf("chat"), { split = "below", height = 20 })
            local code_winid = split(
                panel_buf("code"),
                { split = "below", win = chat_winid, height = 5 }
            )

            local before_height = vim.api.nvim_win_get_height(chat_winid)

            local win_nrs = { chat = chat_winid, code = code_winid }
            WidgetLayout.close_optional_window(win_nrs, buf_nrs, "code")

            assert.equal(before_height, vim.api.nvim_win_get_height(chat_winid))

            pcall(vim.api.nvim_win_close, chat_winid, true)
        end)
    end)

    describe("open", function()
        it("should not error with invalid tabpage", function()
            assert.has_no_errors(function()
                WidgetLayout.open({
                    tab_page_id = 99999,
                    buf_nrs = {},
                    win_nrs = {},
                })
            end)
            assert.equal(1, notify_stub.call_count)
        end)

        it("should not error with nil tabpage", function()
            assert.has_no_errors(function()
                WidgetLayout.open({
                    ---@diagnostic disable-next-line: assign-type-mismatch
                    tab_page_id = nil,
                    buf_nrs = {},
                    win_nrs = {},
                })
            end)
            assert.equal(1, notify_stub.call_count)
        end)

        it("should fall back to right for invalid position", function()
            ---@diagnostic disable-next-line: assign-type-mismatch
            Config.windows.position = "invalid"

            vim.cmd("tabnew")
            local tab_page_id = vim.api.nvim_get_current_tabpage()

            local win_nrs = {}

            assert.has_no_errors(function()
                WidgetLayout.open({
                    tab_page_id = tab_page_id,
                    buf_nrs = panel_bufs(),
                    win_nrs = win_nrs,
                })
            end)

            -- Should have created windows via "right" fallback
            assert.is_not_nil(win_nrs.chat)
            assert.is_not_nil(win_nrs.input)
            -- Should have notified about invalid position
            assert.equal(1, notify_stub.call_count)

            WidgetLayout.close(win_nrs, buf_nrs)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("leaves winfixbuf off", function()
            vim.cmd("tabnew")
            local win_nrs = {}
            WidgetLayout.open({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                buf_nrs = panel_bufs(),
                win_nrs = win_nrs,
            })

            assert.is_false(vim.wo[win_nrs.chat].winfixbuf)
            assert.is_false(vim.wo[win_nrs.input].winfixbuf)

            WidgetLayout.close(win_nrs, buf_nrs)
            pcall(vim.cmd.tabclose)
        end)

        it("leaves 'fillchars' global when its eob is blank", function()
            vim.cmd("tabnew")
            local original = vim.go.fillchars
            vim.go.fillchars = "eob: "
            local win_nrs = {}
            WidgetLayout.open({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                buf_nrs = panel_bufs(),
                win_nrs = win_nrs,
            })

            local local_fillchars = vim.api.nvim_get_option_value(
                "fillchars",
                { win = win_nrs.chat, scope = "local" }
            )

            vim.go.fillchars = original
            WidgetLayout.close(win_nrs, buf_nrs)
            pcall(vim.cmd.tabclose)
            assert.equal("", local_fillchars)
        end)

        it("gives another buffer in a slot the global options", function()
            vim.cmd("tabnew")
            -- In the window the panels split off, whose values they copy.
            vim.o.number = true
            local win_nrs = {}
            WidgetLayout.open({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                buf_nrs = panel_bufs(),
                win_nrs = win_nrs,
            })
            local chat_win = win_nrs.chat --[[@as integer]]
            assert.is_false(vim.wo[chat_win].number)

            -- `:edit` takes over an empty unnamed buffer instead of leaving it.
            vim.api.nvim_buf_set_lines(buf_nrs.chat, 0, -1, false, { "chat" })
            local file = vim.fn.tempname()
            vim.fn.writefile({ "text" }, file)
            vim.api.nvim_win_call(chat_win, function()
                vim.cmd.edit(file)
            end)

            assert.is_true(vim.wo[chat_win].number)
            assert.equal(
                vim.go.fillchars,
                vim.api.nvim_get_option_value("fillchars", { win = chat_win })
            )

            WidgetLayout.close(win_nrs, buf_nrs)
            pcall(vim.cmd.tabclose)
        end)

        it("opens a new window for a slot showing another buffer", function()
            vim.cmd("tabnew")
            local win_nrs = {}
            --- @type agentic.ui.WidgetLayout.Params
            local params = {
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                buf_nrs = panel_bufs(),
                win_nrs = win_nrs,
            }
            WidgetLayout.open(params)
            local taken = win_nrs.chat --[[@as integer]]
            show_other_buffer(taken)

            WidgetLayout.open(params)

            assert.are_not.equal(taken, win_nrs.chat)
            assert.equal(
                params.buf_nrs.chat,
                vim.api.nvim_win_get_buf(win_nrs.chat)
            )
            assert.is_true(vim.api.nvim_win_is_valid(taken))

            WidgetLayout.close(win_nrs, buf_nrs)
            pcall(vim.cmd.tabclose)
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
