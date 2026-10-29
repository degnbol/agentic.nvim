local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.FileList", function()
    local FileList = require("agentic.ui.file_list")
    local FileSystem = require("agentic.utils.file_system")

    --- @type integer
    local bufnr
    --- @type agentic.ui.FileList
    local file_list
    --- @type TestSpy
    local on_change_spy
    --- @type TestStub
    local fs_stat_stub

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        on_change_spy = spy.new(function() end)

        fs_stat_stub = spy.stub(vim.uv, "fs_stat")
        fs_stat_stub:returns({ type = "file" })

        file_list = FileList:new(bufnr, on_change_spy --[[@as function]])
    end)

    after_each(function()
        fs_stat_stub:revert()

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("add", function()
        it("adds valid file", function()
            local test_file = "/path/to/test.lua"

            local success = file_list:add(test_file)

            assert.is_true(success)
            assert.same({ test_file }, file_list:take())
            assert.stub(fs_stat_stub).was.called_with(test_file)
        end)

        it("does not add non-existent file", function()
            fs_stat_stub:returns(nil)

            local success = file_list:add("/non/existent/file.lua")

            assert.is_false(success)
            assert.is_true(file_list:is_empty())
            assert.spy(on_change_spy).was.called(0)
        end)

        it("does not add directory", function()
            fs_stat_stub:returns({ type = "directory" })

            local success = file_list:add("/path/to/directory")

            assert.is_false(success)
            assert.is_true(file_list:is_empty())
            assert.spy(on_change_spy).was.called(0)
        end)

        it(
            "returns true for a file already listed, without adding it",
            function()
                local test_file = "/path/to/test.lua"

                file_list:add(test_file)

                assert.is_true(file_list:add(test_file))
                assert.equal(1, file_list:count())
                assert.spy(on_change_spy).was.called(1)
            end
        )

        it("adds multiple distinct files in order", function()
            file_list:add("/path/to/file1.lua")
            file_list:add("/path/to/file2.lua")

            assert.same(
                { "/path/to/file1.lua", "/path/to/file2.lua" },
                file_list:take()
            )
        end)
    end)

    it("renders one row per file", function()
        local file1 = "/path/to/alpha.lua"
        local file2 = "/path/to/beta.lua"

        file_list:add(file1)
        file_list:add(file2)

        assert.same({
            "-   " .. FileSystem.to_smart_path(file1),
            "-   " .. FileSystem.to_smart_path(file2),
        }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)
end)
