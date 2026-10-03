--- @diagnostic disable: invisible, missing-fields
local assert = require("tests.helpers.assert")
local SessionRegistry = require("agentic.session_registry")

describe("agentic.ui.PermissionFloat", function()
    --- @type agentic.ui.PermissionFloat
    local PermissionFloat
    --- @type agentic.ui.MessageWriter
    local MessageWriter

    before_each(function()
        PermissionFloat = require("agentic.ui.permission_float")
        MessageWriter = require("agentic.ui.message_writer")
    end)

    describe("_anchor_position", function()
        it("NW: (row_offset, col_offset)", function()
            local row, col =
                PermissionFloat._anchor_position("NW", 200, 100, 2, 3)
            assert.equal(2, row)
            assert.equal(3, col)
        end)

        it("NE: (row_offset, win_w + col_offset)", function()
            local row, col =
                PermissionFloat._anchor_position("NE", 200, 100, 1, -1)
            assert.equal(1, row)
            assert.equal(199, col)
        end)

        it("SW: (win_h + row_offset, col_offset)", function()
            local row, col =
                PermissionFloat._anchor_position("SW", 200, 100, -1, 4)
            assert.equal(99, row)
            assert.equal(4, col)
        end)

        it("SE: (win_h + row_offset, win_w + col_offset)", function()
            local row, col =
                PermissionFloat._anchor_position("SE", 200, 100, -2, -3)
            assert.equal(98, row)
            assert.equal(197, col)
        end)
    end)

    describe("lifecycle", function()
        --- @type integer
        local chat_bufnr
        --- @type integer|nil
        local chat_winid
        --- @type integer
        local tab_page_id
        --- @type agentic.ui.MessageWriter
        local writer
        --- @type agentic.ui.PermissionFloat
        local float

        --- @return agentic.acp.PermissionOption[]
        local function make_options()
            return {
                {
                    optionId = "allow-once",
                    name = "Allow once",
                    kind = "allow_once",
                },
                {
                    optionId = "reject-once",
                    name = "Reject once",
                    kind = "reject_once",
                },
            }
        end

        before_each(function()
            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()

            chat_bufnr = vim.api.nvim_create_buf(false, true)
            chat_winid = vim.api.nvim_open_win(chat_bufnr, true, {
                relative = "editor",
                width = 80,
                height = 40,
                row = 0,
                col = 0,
            })

            writer = MessageWriter:new(chat_bufnr)
            local owner_id = 4242
            SessionRegistry.bind(tab_page_id, { id = owner_id })
            float = PermissionFloat:new(writer, { chat = chat_bufnr }, owner_id)
        end)

        after_each(function()
            pcall(function()
                float:close()
            end)
            SessionRegistry.tab_bindings[tab_page_id] = nil
            if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
                vim.api.nvim_win_close(chat_winid, true)
            end
            if chat_bufnr and vim.api.nvim_buf_is_valid(chat_bufnr) then
                vim.api.nvim_buf_delete(chat_bufnr, { force = true })
            end
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("open() creates a non-focusable float window and buffer", function()
            local mapping = float:open(make_options())

            assert.is_not_nil(mapping)
            local winid = float._winid --[[@as integer]]
            local bufnr = float._bufnr --[[@as integer]]
            assert.is_not_nil(winid)
            assert.is_true(vim.api.nvim_win_is_valid(winid))
            assert.is_not_nil(bufnr)
            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))

            local cfg = vim.api.nvim_win_get_config(winid)
            assert.equal("win", cfg.relative)
            assert.is_false(cfg.focusable)
        end)

        it("open() maps each option's kind key to its id", function()
            assert.same({
                ["<localLeader>y"] = "allow-once",
                ["<localLeader>n"] = "reject-once",
                ["<localLeader>x"] = "__reject_all__",
            }, float:open(make_options()))
        end)

        it("open() labels each option with its key", function()
            float:open(make_options())
            local first = vim.api.nvim_buf_get_lines(float._bufnr, 0, 1, false)[1]
            local label = vim.fn.keytrans(vim.keycode("<localLeader>y"))
            assert.equal(1, first:find(label .. ".", 1, true))
        end)

        it(
            "open() gives an option whose kind key is taken a positional key",
            function()
                local options = make_options()
                table.insert(options, 2, {
                    optionId = "allow-once-2",
                    name = "Allow once too",
                    kind = "allow_once",
                })

                local mapping = float:open(options)

                assert.equal("allow-once", mapping["<localLeader>y"])
                assert.equal("allow-once-2", mapping["<localLeader>2"])
            end
        )

        it("is visible in the current tab only while there", function()
            float:open(make_options())
            assert.is_true(float:is_visible_in_current_tab())

            vim.cmd("tabnew")
            assert.is_false(float:is_visible_in_current_tab())
            vim.cmd("tabclose")
        end)

        it("with no window showing the chat, is not shown", function()
            vim.api.nvim_win_close(chat_winid --[[@as integer]], true)

            local mapping = float:open(make_options())

            assert.equal("allow-once", mapping["<localLeader>y"])
            assert.is_false(float:is_shown())
        end)

        it("place() shows the float once the chat is shown", function()
            vim.api.nvim_win_close(chat_winid --[[@as integer]], true)
            float:open(make_options())
            vim.api.nvim_win_set_buf(0, chat_bufnr)

            float:place()

            local cfg = vim.api.nvim_win_get_config(float._winid)
            assert.equal("win", cfg.relative)
            assert.equal(vim.api.nvim_get_current_win(), cfg.win)
        end)

        it("anchors to the chat in the current tab first", function()
            vim.cmd("tabnew")
            local current_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(current_win, chat_bufnr)

            float:open(make_options())

            assert.equal(
                current_win,
                vim.api.nvim_win_get_config(float._winid).win
            )
            float:close()
            vim.cmd("tabclose")
        end)

        it("anchors to the chat in any tab", function()
            SessionRegistry.tab_bindings[tab_page_id] = nil
            vim.cmd("tabnew")

            float:open(make_options())

            assert.equal(chat_winid, vim.api.nvim_win_get_config(float._winid).win)
            float:close()
            vim.cmd("tabclose")
        end)

        it("place() reopens a float its user closed", function()
            float:open(make_options())
            vim.api.nvim_win_close(float._winid, true)

            float:place()

            assert.is_true(vim.api.nvim_win_is_valid(float._winid))
        end)

        it("place() leaves a float already in place alone", function()
            float:open(make_options())
            local winid = float._winid

            float:place()

            assert.equal(winid, float._winid)
        end)

        it("close() closes window and defers buffer deletion", function()
            float:open(make_options())
            --- @type integer
            local opened_winid = float._winid
            --- @type integer
            local opened_bufnr = float._bufnr

            float:close()

            assert.is_nil(float._winid)
            assert.is_nil(float._bufnr)
            assert.is_false(vim.api.nvim_win_is_valid(opened_winid))

            -- Buffer deletion runs on the next event-loop tick
            assert.is_true(vim.api.nvim_buf_is_valid(opened_bufnr))
            vim.wait(50, function()
                return not vim.api.nvim_buf_is_valid(opened_bufnr)
            end)
            assert.is_false(vim.api.nvim_buf_is_valid(opened_bufnr))
        end)

        it("close() is idempotent", function()
            float:open(make_options())
            float:close()
            -- Second close must not error
            assert.has_no_errors(function()
                float:close()
            end)
        end)

        it("place() hides the float once its chat window closes", function()
            float:open(make_options())

            vim.api.nvim_win_close(chat_winid --[[@as integer]], true)
            float:place()

            assert.is_false(float:is_shown())
        end)

        it("reopen replaces the previous float", function()
            float:open(make_options())
            --- @type integer
            local first_winid = float._winid

            float:open(make_options())
            --- @type integer
            local second_winid = float._winid

            assert.is_false(vim.api.nvim_win_is_valid(first_winid))
            assert.is_true(vim.api.nvim_win_is_valid(second_winid))
            assert.are_not.equal(first_winid, second_winid)
        end)
    end)
end)
