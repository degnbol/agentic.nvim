local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Partial-send", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
            vim.cmd("Agentic")
            local session = require("agentic.session_registry").current()
            _G._sent_prompts = {}
            session.widget.on_submit_input = function(prompt)
                table.insert(_G._sent_prompts, prompt)
                return true
            end
            _G._widget = session.widget
            _G._widget:input_win()
        ]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    local function set_input(lines)
        child.lua(
            string.format(
                [[vim.api.nvim_buf_set_lines(_G._widget.buf_nrs.input, 0, -1, false, %s)]],
                vim.inspect(lines)
            )
        )
    end

    local function input_lines()
        return child.lua_get(
            [[vim.api.nvim_buf_get_lines(_G._widget.buf_nrs.input, 0, -1, false)]]
        )
    end

    local function sent_prompts()
        return child.lua_get([[_G._sent_prompts]])
    end

    local function focus_input_normal()
        child.lua([[
            vim.api.nvim_set_current_win(_G._widget.win_nrs.input)
            vim.cmd("stopinsert")
        ]])
    end

    local function feed(keys)
        child.lua(string.format(
            [[
            local keys = vim.api.nvim_replace_termcodes(%q, true, false, true)
            vim.api.nvim_feedkeys(keys, "mx", false)
        ]],
            keys
        ))
        vim.uv.sleep(20)
        child.flush()
    end

    it("<CR><CR> sends current line and removes it", function()
        set_input({ "alpha", "beta", "gamma" })
        focus_input_normal()
        child.lua(
            [[vim.api.nvim_win_set_cursor(_G._widget.win_nrs.input, {1, 0})]]
        )
        feed("<CR><CR>")
        child.flush()

        assert.same({ "alpha" }, sent_prompts())
        assert.same({ "beta", "gamma" }, input_lines())
    end)

    it("count prefix sends N lines", function()
        set_input({ "alpha", "beta", "gamma", "delta" })
        focus_input_normal()
        child.lua(
            [[vim.api.nvim_win_set_cursor(_G._widget.win_nrs.input, {2, 0})]]
        )
        feed("3<CR><CR>")
        child.flush()

        assert.same({ "beta\ngamma\ndelta" }, sent_prompts())
        assert.same({ "alpha" }, input_lines())
    end)

    it("<CR>{motion} sends motion range linewise", function()
        set_input({ "alpha", "beta", "gamma", "delta" })
        focus_input_normal()
        child.lua(
            [[vim.api.nvim_win_set_cursor(_G._widget.win_nrs.input, {2, 0})]]
        )
        feed("<CR>j")

        assert.same({ "beta\ngamma" }, sent_prompts())
        assert.same({ "alpha", "delta" }, input_lines())
    end)

    it("visual <CR> sends selection", function()
        set_input({ "alpha", "beta", "gamma", "delta" })
        focus_input_normal()
        child.lua(
            [[vim.api.nvim_win_set_cursor(_G._widget.win_nrs.input, {2, 0})]]
        )
        feed("Vj<CR>")
        child.flush()

        assert.same({ "beta\ngamma" }, sent_prompts())
        assert.same({ "alpha", "delta" }, input_lines())
    end)

    it(":w still sends whole buffer", function()
        set_input({ "alpha", "beta" })
        focus_input_normal()
        child.lua([[vim.cmd("write")]])
        child.flush()

        assert.same({ "alpha\nbeta" }, sent_prompts())
        assert.same({ "" }, input_lines())
    end)

    it("insert-mode <CR> inserts a newline", function()
        set_input({ "" })
        focus_input_normal()
        child.lua(
            [[vim.api.nvim_win_set_cursor(_G._widget.win_nrs.input, {1, 0})]]
        )
        feed("ihello<CR>world")
        child.flush()

        assert.same({}, sent_prompts())
        assert.same({ "hello", "world" }, input_lines())
    end)

    it("empty buffer <CR><CR> is a no-op", function()
        set_input({ "" })
        focus_input_normal()
        feed("<CR><CR>")
        child.flush()

        assert.same({}, sent_prompts())
    end)

    it("<CR>{motion} on a second tab dispatches to its own widget", function()
        -- Regression for the operatorfunc singleton race: two widgets on
        -- different tabpages must each see their own send dispatch, not
        -- stomp a shared module-level reference.
        child.lua([[
            vim.cmd("tabnew")
            require("agentic").new_session({ auto_add_to_context = false })
        ]])
        child.flush()
        child.lua([[
            local session_2 =
                require("agentic.session_registry").current()
            _G._sent_prompts_2 = {}
            session_2.widget.on_submit_input = function(prompt)
                table.insert(_G._sent_prompts_2, prompt)
                return true
            end
            _G._widget_2 = session_2.widget
            vim.api.nvim_buf_set_lines(
                _G._widget_2.buf_nrs.input,
                0, -1, false, { "two-alpha", "two-beta", "two-gamma" }
            )
            vim.api.nvim_set_current_win(_G._widget_2:input_win())
            vim.cmd("stopinsert")
            vim.api.nvim_win_set_cursor(_G._widget_2.win_nrs.input, {1, 0})
        ]])
        set_input({ "one-alpha", "one-beta", "one-gamma" })

        feed("<CR>j")
        child.flush()

        assert.same(
            { "two-alpha\ntwo-beta" },
            child.lua_get([[_G._sent_prompts_2]])
        )
        assert.same(
            { "two-gamma" },
            child.lua_get(
                [[vim.api.nvim_buf_get_lines(_G._widget_2.buf_nrs.input, 0, -1, false)]]
            )
        )
        assert.same({}, sent_prompts())
        assert.same({ "one-alpha", "one-beta", "one-gamma" }, input_lines())
    end)
end)

describe("Context panels across a /command head", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
            vim.cmd("Agentic")
            local session = require("agentic.session_registry").current()
            session.session_id = "sid"
            session.agent.state = "ready"
            session._persist_history = function() end
            _G._dispatched = {}
            session._dispatch_turn = function(_, prompt)
                table.insert(_G._dispatched, prompt)
            end
            _G._session = session
            _G._file = vim.fn.tempname()
            vim.fn.writefile({ "x" }, _G._file)
            session.file_list:add(_G._file)
        ]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    local function submit(text)
        child.lua(string.format(
            [[
            local widget = _G._session.widget
            vim.api.nvim_buf_set_lines(widget.buf_nrs.input, 0, -1, false, { %q })
            widget:submit()
        ]],
            text
        ))
        child.flush()
    end

    local function files_window_open()
        return child.lua_get([[
            (function()
                local winid = _G._session.widget.win_nrs.files
                return winid ~= nil and vim.api.nvim_win_is_valid(winid)
            end)()
        ]])
    end

    it("keeps attached files until the next prose prompt", function()
        -- Not a local command, so it dispatches a turn without the context.
        submit("/compact")

        assert.equal(1, child.lua_get([[#_G._dispatched]]))
        local listed = child.lua_get([[
            table.concat(vim.api.nvim_buf_get_lines(
                _G._session.widget.buf_nrs.files, 0, -1, false), "\n")
        ]])
        assert.truthy(
            listed:find(vim.fs.basename(child.lua_get([[_G._file]])), 1, true)
        )
        assert.is_true(files_window_open())

        submit("go on")

        assert.equal(2, child.lua_get([[#_G._dispatched]]))
        assert.truthy(
            child
                .lua_get([[vim.inspect(_G._dispatched[2])]])
                :find(child.lua_get([[_G._file]]), 1, true)
        )
        assert.is_true(child.lua_get([[_G._session.file_list:is_empty()]]))
        assert.is_false(files_window_open())
    end)
end)
