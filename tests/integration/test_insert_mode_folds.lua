local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Chat folds written during insert mode", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.cmd("Agentic")
        child.flush()
        child.lua([[
_G.s = require("agentic.session_registry").current()
_G.chat = _G.s.widget.buf_nrs.agent
]])
    end)

    after_each(function()
        child.stop()
    end)

    --- Let scheduled work in the child run.
    local function settle()
        child.flush()
        vim.uv.sleep(50)
        child.flush()
    end

    --- Open a scratch window and enter insert mode in it.
    local function start_insert_elsewhere()
        child.cmd("new")
        child.type_keys("i")
        assert.equal("i", child.api.nvim_get_mode().mode)
    end

    --- Write a notice whose three-line fold body the writer closes.
    --- @param session string Child global holding the session
    local function write_folded_notice(session)
        child.lua(([[
%s.message_writer:write_notice({
    glyph = "*",
    title = "notice",
    fold_body = { "one", "two", "three" },
})
]]):format(session))
        settle()
    end

    --- 1-indexed rows of a chat buffer's fold anchors.
    --- @param chat string|nil Child global holding the buffer; `_G.chat` when nil
    --- @return integer[] rows
    local function anchor_rows(chat)
        return child.lua_get(([[
vim.tbl_map(function(mark)
    return mark[2] + 1
end, vim.api.nvim_buf_get_extmarks(
    %s,
    vim.api.nvim_create_namespace("agentic_fold_anchors"),
    0,
    -1,
    {}
))
]]):format(chat or "_G.chat"))
    end

    --- `foldclosed(row)` in every window showing a chat buffer.
    --- @param row integer 1-indexed
    --- @param chat string|nil Child global holding the buffer; `_G.chat` when nil
    --- @return integer[] closed
    local function foldclosed_per_window(row, chat)
        return child.lua_get(([[
vim.tbl_map(function(winid)
    return vim.api.nvim_win_call(winid, function()
        return vim.fn.foldclosed(%d)
    end)
end, vim.fn.win_findbuf(%s))
]]):format(row, chat or "_G.chat"))
    end

    for _, exit_key in ipairs({ "<Esc>", "<C-c>" }) do
        it("closes a notice's fold after leaving with " .. exit_key, function()
            start_insert_elsewhere()
            write_folded_notice("_G.s")
            local row = anchor_rows()[1]
            assert.same({ -1 }, foldclosed_per_window(row))

            child.type_keys(exit_key)
            settle()

            assert.same({ row }, foldclosed_per_window(row))
        end)
    end

    it("gives a fold to rows written with no fold op", function()
        start_insert_elsewhere()
        child.lua([[
_G.s.message_writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
        "```text-fold", "one", "two", "three", "```",
    })
end)
]])
        settle()
        local row = child.lua_get("vim.api.nvim_buf_line_count(_G.chat) - 3")

        child.type_keys("<Esc>")
        settle()

        local chat_win = child.lua_get("vim.fn.win_findbuf(_G.chat)[1]")
        local function in_chat(expr)
            return child.lua_get(
                ("vim.api.nvim_win_call(%d, function() return %s end)"):format(
                    chat_win,
                    expr
                )
            )
        end
        assert.is_true(in_chat(("vim.fn.foldlevel(%d)"):format(row)) > 0)
        assert.equal(-1, in_chat(("vim.fn.foldclosed(%d)"):format(row)))

        child.lua(
            ("vim.api.nvim_win_call(%d, function() vim.cmd('%dfoldclose') end)"):format(
                chat_win,
                row
            )
        )
        assert.equal(row, in_chat(("vim.fn.foldclosed(%d)"):format(row)))
    end)

    it("keeps a closed fold closed and a fold opened by hand open", function()
        write_folded_notice("_G.s")
        write_folded_notice("_G.s")
        local rows = anchor_rows()
        child.lua(
            ("vim.api.nvim_win_call(vim.fn.win_findbuf(_G.chat)[1], function() vim.cmd('%dfoldopen') end)"):format(
                rows[2]
            )
        )
        assert.same({ rows[1] }, foldclosed_per_window(rows[1]))
        assert.same({ -1 }, foldclosed_per_window(rows[2]))

        start_insert_elsewhere()
        child.lua([[
_G.s.message_writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "more" })
end)
]])
        settle()
        child.type_keys("<Esc>")
        settle()

        assert.same({ rows[1] }, foldclosed_per_window(rows[1]))
        assert.same({ -1 }, foldclosed_per_window(rows[2]))
    end)

    it("rebuilds the folds in every window showing the chat", function()
        child.cmd("tabnew")
        child.cmd("buffer " .. child.lua_get("_G.chat"))
        settle()
        start_insert_elsewhere()
        write_folded_notice("_G.s")
        local row = anchor_rows()[1]

        child.type_keys("<Esc>")
        settle()

        assert.same({ row, row }, foldclosed_per_window(row))
    end)

    it("gives a window shown during insert mode the closed folds", function()
        write_folded_notice("_G.s")
        local row = anchor_rows()[1]
        start_insert_elsewhere()
        child.lua([[
vim.cmd("tabnew")
vim.cmd("buffer " .. _G.chat)
vim.cmd("tabprevious")
]])
        settle()
        assert.equal("i", child.api.nvim_get_mode().mode)

        child.type_keys("<Esc>")
        settle()

        assert.same({ row, row }, foldclosed_per_window(row))
    end)

    it("applies a flush queued in insert mode after the rebuild", function()
        start_insert_elsewhere()
        -- The write and the exit land before the flush the write schedules.
        child.lua([[
_G.s.message_writer:write_notice({
    glyph = "*",
    title = "notice",
    fold_body = { "one", "two", "three" },
})
vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
]])
        settle()

        local row = anchor_rows()[1]
        assert.same({ row }, foldclosed_per_window(row))
    end)

    it("rebuilds only the windows of the session written to", function()
        child.lua("_G.s1 = _G.s; _G.chat1 = _G.chat")
        child.cmd("tabnew")
        child.new_session()
        child.lua([[
_G.s2 = require("agentic.session_registry").current()
_G.chat2 = _G.s2.widget.buf_nrs.agent
_G.rebuilt = {}
local BufHelpers = require("agentic.utils.buf_helpers")
local recompute = BufHelpers.recompute_folds
BufHelpers.recompute_folds = function(winid)
    table.insert(_G.rebuilt, winid)
    recompute(winid)
end
]])
        assert.is_true(child.lua_get("_G.chat1 ~= _G.chat2"))

        start_insert_elsewhere()
        write_folded_notice("_G.s2")
        child.type_keys("<Esc>")
        settle()

        assert.same(
            child.lua_get("vim.fn.win_findbuf(_G.chat2)"),
            child.lua_get("_G.rebuilt")
        )
    end)

    it("rebuilds each session written to", function()
        child.lua("_G.s1 = _G.s; _G.chat1 = _G.chat")
        child.cmd("tabnew")
        child.new_session()
        child.lua([[
_G.s2 = require("agentic.session_registry").current()
_G.chat2 = _G.s2.widget.buf_nrs.agent
]])

        start_insert_elsewhere()
        write_folded_notice("_G.s1")
        write_folded_notice("_G.s2")
        child.type_keys("<Esc>")
        settle()

        for _, chat in ipairs({ "_G.chat1", "_G.chat2" }) do
            local row = anchor_rows(chat)[1]
            assert.same({ row }, foldclosed_per_window(row, chat))
        end
    end)
end)
