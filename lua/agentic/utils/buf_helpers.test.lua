local assert = require("tests.helpers.assert")

describe("BufHelpers", function()
    --- @type agentic.utils.BufHelpers
    local BufHelpers

    before_each(function()
        BufHelpers = require("agentic.utils.buf_helpers")
    end)

    describe("with_modifiable", function()
        it("should allow writing to non-modifiable buffer", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            vim.bo[bufnr].modifiable = false

            local ok, err = pcall(function()
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "should fail" }
                )
            end)
            assert.is_false(ok)
            assert.is_not_nil(err)

            BufHelpers.with_modifiable(bufnr, function(buf)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
            end)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal(1, #lines)
            assert.are.equal("hello world", lines[1])

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should handle nested with_modifiable calls", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            vim.bo[bufnr].modifiable = false

            BufHelpers.with_modifiable(bufnr, function(buf)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first line" })

                BufHelpers.with_modifiable(buf, function(inner_buf)
                    vim.api.nvim_buf_set_lines(
                        inner_buf,
                        -1,
                        -1,
                        false,
                        { "second line" }
                    )
                end)

                vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "third line" })
            end)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal(3, #lines)
            assert.are.equal("first line", lines[1])
            assert.are.equal("second line", lines[2])
            assert.are.equal("third line", lines[3])

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("is_buffer_empty", function()
        it("should return true for buffer with single empty line", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

            assert.is_true(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return true for single line with only whitespace", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "  \t  " })

            assert.is_true(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return true for multiple lines all whitespace", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "   ", "\t", "", "  \t  " }
            )

            assert.is_true(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return false for buffer with text", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

            assert.is_false(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return false for multiple lines with text", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "   ", "", "text", "  " }
            )

            assert.is_false(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)
end)
