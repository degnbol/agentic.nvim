local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.ContextList", function()
    local ContextList = require("agentic.ui.context_list")

    --- Each item is the list of rows it renders to.
    --- @class agentic.ui.ContextList.TestList : agentic.ui.ContextList
    local RowsList = setmetatable({}, { __index = ContextList })
    RowsList.__index = RowsList

    --- @protected
    --- @param item string[]
    --- @return string[]
    function RowsList:__rows(item)
        return item
    end

    --- @param rows string[]
    function RowsList:add(rows)
        table.insert(self.__items, rows)
        self:render()
    end

    --- @type integer
    local bufnr
    --- @type agentic.ui.ContextList.TestList
    local list
    --- @type TestSpy
    local on_change_spy

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        on_change_spy = spy.new(function() end)
        list = RowsList:new(bufnr, on_change_spy --[[@as function]])
    end)

    after_each(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @return string[]
    local function buf_lines()
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    it("counts its items", function()
        assert.is_true(list:is_empty())
        assert.equal(0, list:count())

        list:add({ "a" })
        list:add({ "b", "c" })

        assert.is_false(list:is_empty())
        assert.equal(2, list:count())
    end)

    it("renders every item's rows in order", function()
        list:add({ "a" })
        list:add({ "b", "c" })

        assert.same({ "a", "b", "c" }, buf_lines())
        assert.spy(on_change_spy).was.called(2)
    end)

    it("takes the items in order and empties the list in one render", function()
        list:add({ "a" })
        list:add({ "b" })
        on_change_spy:reset()

        assert.same({ { "a" }, { "b" } }, list:take())
        assert.is_true(list:is_empty())
        assert.same({ "" }, buf_lines())
        assert.spy(on_change_spy).was.called(1)
    end)

    it("clears the items and the buffer", function()
        list:add({ "a" })

        list:clear()

        assert.is_true(list:is_empty())
        assert.same({ "" }, buf_lines())
        assert.spy(on_change_spy).was.called(2)
    end)

    describe("remove_rows", function()
        before_each(function()
            list:add({ "a" })
            list:add({ "b1", "b2", "b3" })
            list:add({ "c" })
            on_change_spy:reset()
        end)

        it("removes the item on a single row", function()
            list:remove_rows(1, 1)

            assert.same({ "b1", "b2", "b3", "c" }, buf_lines())
            assert.spy(on_change_spy).was.called(1)
        end)

        it("removes a multi-row item hit on any of its rows", function()
            for row = 2, 4 do
                list:clear()
                list:add({ "a" })
                list:add({ "b1", "b2", "b3" })
                list:add({ "c" })

                list:remove_rows(row, row)

                assert.same({ "a", "c" }, buf_lines())
            end
        end)

        it("removes every item in a reversed range", function()
            list:remove_rows(5, 4)

            assert.same({ "a" }, buf_lines())
        end)

        it("ignores rows past the end", function()
            list:remove_rows(5, 9)

            assert.same({ "a", "b1", "b2", "b3" }, buf_lines())
        end)

        it("does not render when no item has a row in range", function()
            list:remove_rows(6, 9)

            assert.equal(3, list:count())
            assert.spy(on_change_spy).was.called(0)
        end)

        it("removes by the rows last written after a failed write", function()
            local with_modifiable_stub = spy.stub(
                require("agentic.utils.buf_helpers"),
                "with_modifiable"
            )
            with_modifiable_stub:returns(false)
            list:remove_rows(1, 1)
            with_modifiable_stub:revert()

            list:remove_rows(5, 5)

            assert.same({ "b1", "b2", "b3" }, buf_lines())
        end)
    end)

    describe("d", function()
        --- @type integer
        local winid

        before_each(function()
            winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 40,
                height = 10,
                row = 0,
                col = 0,
            })
            list:add({ "a" })
            list:add({ "b1", "b2", "b3" })
            list:add({ "c" })
        end)

        after_each(function()
            if vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_close(winid, true)
            end
        end)

        it("removes the item under the cursor in normal mode", function()
            vim.api.nvim_win_set_cursor(winid, { 3, 0 })

            vim.api.nvim_feedkeys("d", "x", false)

            assert.same({ "a", "c" }, buf_lines())
        end)

        it("removes the items under a visual selection", function()
            vim.api.nvim_win_set_cursor(winid, { 5, 0 })

            vim.api.nvim_feedkeys("Vkd", "x", false)

            assert.same({ "a" }, buf_lines())
            assert.equal("n", vim.api.nvim_get_mode().mode)
        end)
    end)

    it("does not call on_change when the buffer is invalid", function()
        vim.api.nvim_buf_delete(bufnr, { force = true })

        list:add({ "a" })

        assert.spy(on_change_spy).was.called(0)
    end)
end)
