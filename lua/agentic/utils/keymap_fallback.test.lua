local assert = require("tests.helpers.assert")

describe("KeymapFallback", function()
    --- @type table
    local KeymapFallback

    before_each(function()
        KeymapFallback = require("agentic.utils.keymap_fallback")
    end)

    describe("MARKER", function()
        it("is a non-empty string", function()
            assert.is_not_nil(KeymapFallback.MARKER)
            assert.truthy(#KeymapFallback.MARKER > 0)
        end)
    end)

    describe("get_existing_mapping", function()
        it("returns nil when no mapping exists", function()
            -- Use an obscure key unlikely to be mapped
            local result = KeymapFallback.get_existing_mapping(
                "n",
                "<Plug>(agentic-test-unmapped-xyz)"
            )

            assert.is_nil(result)
        end)

        it("returns mapping dict for existing mapping", function()
            -- Set up a test mapping
            vim.keymap.set(
                "n",
                "<Plug>(agentic-test-fallback)",
                function() end,
                {
                    desc = "test mapping",
                }
            )

            local result = KeymapFallback.get_existing_mapping(
                "n",
                "<Plug>(agentic-test-fallback)"
            )

            assert.is_not_nil(result)

            -- Cleanup
            vim.keymap.del("n", "<Plug>(agentic-test-fallback)")
        end)

        it("skips agentic mappings and returns nil", function()
            vim.keymap.set("n", "<Plug>(agentic-test-skip)", function() end, {
                desc = "some " .. KeymapFallback.MARKER .. " mapping",
            })

            local result = KeymapFallback.get_existing_mapping(
                "n",
                "<Plug>(agentic-test-skip)"
            )

            assert.is_nil(result)

            vim.keymap.del("n", "<Plug>(agentic-test-skip)")
        end)
    end)

    describe("execute_fallback", function()
        it("returns termcodes for default key when no mapping", function()
            local expected =
                vim.api.nvim_replace_termcodes("<CR>", true, true, true)
            local result = KeymapFallback.execute_fallback(nil, "<CR>")

            assert.equal(expected, result)
        end)

        it("calls lua callback for non-expr mapping", function()
            local called = false
            local result = KeymapFallback.execute_fallback({
                callback = function()
                    called = true
                end,
                expr = 0,
            }, "<CR>")

            -- Non-expr callback is scheduled, returns empty string
            assert.equal("", result)
            -- Callback is vim.schedule'd, not called synchronously
            assert.is_false(called)
        end)

        it("calls lua callback for expr mapping and returns result", function()
            local result = KeymapFallback.execute_fallback({
                callback = function()
                    return "custom_keys"
                end,
                expr = 1,
                replace_keycodes = 0,
            }, "<CR>")

            assert.equal("custom_keys", result)
        end)

        it(
            "applies replace_keycodes when expr callback returns string",
            function()
                local expected =
                    vim.api.nvim_replace_termcodes("<Tab>", true, true, true)

                local result = KeymapFallback.execute_fallback({
                    callback = function()
                        return "<Tab>"
                    end,
                    expr = 1,
                    replace_keycodes = 1,
                }, "<CR>")

                assert.equal(expected, result)
            end
        )

        it("returns default when expr callback returns non-string", function()
            local expected =
                vim.api.nvim_replace_termcodes("<CR>", true, true, true)

            local result = KeymapFallback.execute_fallback({
                callback = function()
                    return nil
                end,
                expr = 1,
            }, "<CR>")

            assert.equal(expected, result)
        end)

        it("returns termcodes for string RHS non-expr mapping", function()
            local expected =
                vim.api.nvim_replace_termcodes("abc", true, true, true)

            local result = KeymapFallback.execute_fallback({
                rhs = "abc",
                expr = 0,
            }, "<CR>")

            assert.equal(expected, result)
        end)

        it("evaluates string RHS for expr mapping", function()
            -- A simple vimscript expression that returns a string
            local result = KeymapFallback.execute_fallback({
                rhs = '"hello"',
                expr = 1,
            }, "<CR>")

            -- nvim_eval returns the string in internal format
            assert.equal("hello", result)
        end)

        it("returns default when string RHS expr evaluation fails", function()
            local expected =
                vim.api.nvim_replace_termcodes("<CR>", true, true, true)

            local result = KeymapFallback.execute_fallback({
                rhs = "nonexistent_variable_xyz",
                expr = 1,
            }, "<CR>")

            assert.equal(expected, result)
        end)

        it("returns default for mapping with empty RHS", function()
            local expected =
                vim.api.nvim_replace_termcodes("<Esc>", true, true, true)

            local result = KeymapFallback.execute_fallback({
                rhs = "",
                expr = 0,
            }, "<Esc>")

            assert.equal(expected, result)
        end)
    end)
end)
