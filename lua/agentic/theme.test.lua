local assert = require("tests.helpers.assert")

describe("agentic.Theme", function()
    --- @type agentic.Theme
    local Theme

    before_each(function()
        Theme = require("agentic.theme")
    end)

    describe("get_language_from_path", function()
        it("maps a known extension to its parser name", function()
            assert.equal(Theme.get_language_from_path("foo.py"), "python")
        end)

        it("passes through extensions whose name is the parser name", function()
            assert.equal(Theme.get_language_from_path("foo.lua"), "lua")
            assert.equal(Theme.get_language_from_path("foo.md"), "markdown")
        end)

        it("detects special filenames with no extension", function()
            assert.equal(Theme.get_language_from_path("justfile"), "just")
        end)

        it("returns empty string for an unrecognised file", function()
            assert.equal(Theme.get_language_from_path("script_no_ext"), "")
        end)

        -- A filetype whose parser name differs from it (sh -> bash) resolves
        -- only via a registered filetype<->parser mapping, which nvim-treesitter
        -- installs but bare Neovim does not. Register it here to prove the
        -- function honours registrations rather than a hand-rolled table.
        it("honours a registered filetype-to-parser mapping", function()
            vim.treesitter.language.register("bash", "sh")
            assert.equal(Theme.get_language_from_path("foo.sh"), "bash")
        end)
    end)
end)
