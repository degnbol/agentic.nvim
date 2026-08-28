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

        it("falls back to contents for content-defined extensionless files", function()
            assert.equal(
                Theme.get_language_from_path("_brew", { "#compdef brew", "local x" }),
                "zsh"
            )
        end)

        it("still returns empty when contents are omitted", function()
            assert.equal(Theme.get_language_from_path("_brew"), "")
        end)

        it("prefers extension over a misleading content line", function()
            assert.equal(
                Theme.get_language_from_path("foo.lua", { "#compdef x" }),
                "lua"
            )
        end)
    end)

    describe("setup", function()
        --- Definitions are `default = true`, so a group that already exists
        --- wins over a fresh setup — the same reason a colorscheme's
        --- `:highlight clear` is what lets the redefinition through.
        --- @param name string
        local function clear(name)
            vim.cmd.highlight({ args = { "clear", name } })
        end

        --- @param name string
        --- @return string|nil
        local function link_of(name)
            return vim.api.nvim_get_hl(0, { name = name }).link
        end

        -- `Prompt` is not one of neovim's own groups, so every case has to say
        -- whether the colorscheme under test defines it.
        before_each(function()
            clear("Prompt")
            clear(Theme.HL_GROUPS.GLYPH_USER)
            clear(Theme.HL_GROUPS.GLYPH_OFF)
        end)

        it("redefines its groups after a colorscheme wipes them", function()
            Theme.setup()
            vim.cmd.colorscheme("default")

            assert.equal("Normal", link_of(Theme.HL_GROUPS.GLYPH_AGENT))
        end)

        it("points the user glyph at Prompt where it is defined", function()
            vim.api.nvim_set_hl(0, "Prompt", { fg = "#f05af2" })

            Theme.setup()

            assert.equal("Prompt", link_of(Theme.HL_GROUPS.GLYPH_USER))
        end)

        it("falls back to Normal where Prompt is undefined", function()
            Theme.setup()

            assert.equal("Normal", link_of(Theme.HL_GROUPS.GLYPH_USER))
        end)

        it("strikes the off-glyph in the user glyph's foreground", function()
            vim.api.nvim_set_hl(0, "Prompt", { fg = "#abcdef" })

            Theme.setup()

            local off =
                vim.api.nvim_get_hl(0, { name = Theme.HL_GROUPS.GLYPH_OFF })
            assert.equal(tonumber("abcdef", 16), off.fg)
            assert.is_true(off.strikethrough)
        end)

        it(
            "trades the strikethrough for a colour the source cannot give",
            function()
                -- A colorscheme leaving Normal to the terminal resolves to no
                -- foreground, and an attribute-only group would fall through to
                -- SignColumn — dimmer than the glyph this one pairs with.
                vim.api.nvim_set_hl(0, "Normal", {})

                Theme.setup()

                assert.equal(
                    Theme.HL_GROUPS.GLYPH_USER,
                    link_of(Theme.HL_GROUPS.GLYPH_OFF)
                )
            end
        )
    end)
end)
