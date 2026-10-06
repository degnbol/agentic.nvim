local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("agentic.Bootstrap", function()
    local child = Child.new()

    after_each(function()
        child.stop()
    end)

    --- @return boolean exists whether the `AgenticCleanup` group has autocmds
    local function cleanup_autocmds_exist()
        return child.lua_get([[vim.fn.exists("#AgenticCleanup") == 1]])
    end

    --- @return string lang of the parser on the current tab's chat buffer
    local function chat_lang()
        return child.lua_get([[vim.treesitter.get_parser(
            require("agentic.session_registry")
                .bound_session(vim.api.nvim_get_current_tabpage()).widget.buf_nrs.chat
        ):lang()]])
    end

    describe("without setup()", function()
        before_each(function()
            child.launch()
        end)

        it("defines the highlight groups at startup", function()
            assert.is_false(
                child.lua_get(
                    [[vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = "AgenticPickerDate" }))]]
                )
            )
        end)

        it("open() gives a chat parsed as the agentic language", function()
            child.lua([[ require("agentic").open() ]])
            child.flush()

            assert.equal("agentic", chat_lang())
        end)

        it(
            ":AgenticResume gives a chat parsed as the agentic language",
            function()
                child.lua([[
                    require("agentic.session_restore").resolve_query = function(_, callback)
                        callback("sid-x", vim.fn.getcwd())
                    end
                    require("agentic.session_manager").load_acp_session = function() end
                ]])
                child.cmd("AgenticResume sid")
                child.flush()

                assert.equal("agentic", chat_lang())
            end
        )
    end)

    describe("setup()", function()
        before_each(function()
            child.setup()
        end)

        it(
            "neither registers the language nor creates the autocmds",
            function()
                assert.equal(
                    "AgenticChat",
                    child.lua_get(
                        [[vim.treesitter.language.get_lang("AgenticChat")]]
                    )
                )
                assert.is_false(cleanup_autocmds_exist())
            end
        )
    end)

    it("applies image_paste from a setup() before the first session", function()
        child.launch()
        child.lua([[
            _G.original_paste = vim.paste
            require("agentic").setup({ image_paste = { enabled = false } })
            require("agentic").open()
        ]])
        child.flush()

        assert.is_true(child.lua_get([[vim.paste == _G.original_paste]]))
    end)

    describe("ensure()", function()
        before_each(function()
            child.setup()
            child.lua([[ require("agentic.bootstrap").ensure() ]])
        end)

        it("wraps paste once", function()
            child.lua([[
                _G.wrapped_paste = vim.paste
                require("agentic.bootstrap").ensure()
            ]])

            assert.is_true(cleanup_autocmds_exist())
            assert.is_true(child.lua_get([[vim.paste == _G.wrapped_paste]]))
        end)

        it("sets fcs_choice to reload when FileChangedShell fires", function()
            child.v.fcs_choice = ""
            child.api.nvim_exec_autocmds("FileChangedShell", {
                group = "AgenticCleanup",
                pattern = "*",
            })

            assert.equal("reload", child.v.fcs_choice)
        end)
    end)
end)
