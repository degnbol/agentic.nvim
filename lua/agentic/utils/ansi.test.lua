local assert = require("tests.helpers.assert")

describe("agentic.utils.Ansi", function()
    --- @type agentic.utils.Ansi
    local Ansi

    before_each(function()
        Ansi = require("agentic.utils.ansi")
    end)

    describe("process_lines", function()
        it("returns clean lines when no ANSI codes present", function()
            local result = Ansi.process_lines({ "hello", "world" })
            assert.same({ "hello", "world" }, result.lines)
            assert.is_false(result.has_ansi)
            assert.same({}, result.highlights[1])
            assert.same({}, result.highlights[2])
        end)

        it("strips basic SGR codes and produces highlights", function()
            local result = Ansi.process_lines({ "\27[32mgreen\27[0m" })
            assert.equal("green", result.lines[1])
            assert.is_true(result.has_ansi)
            assert.equal(1, #result.highlights[1])

            local span = result.highlights[1][1]
            assert.equal(0, span[1]) -- col_start
            assert.equal(5, span[2]) -- col_end
            -- hl_group is a string starting with AgenticAnsi_
            assert.truthy(span[3]:find("^AgenticAnsi_"))
        end)

        it("handles multiple colours on one line", function()
            local result =
                Ansi.process_lines({ "\27[31mred\27[34mblue\27[0m" })
            assert.equal("redblue", result.lines[1])
            assert.is_true(result.has_ansi)
            assert.equal(2, #result.highlights[1])

            -- First span: "red" at cols 0–3
            assert.equal(0, result.highlights[1][1][1])
            assert.equal(3, result.highlights[1][1][2])

            -- Second span: "blue" at cols 3–7
            assert.equal(3, result.highlights[1][2][1])
            assert.equal(7, result.highlights[1][2][2])
        end)

        it("carries SGR state across lines", function()
            local result = Ansi.process_lines({
                "\27[1;33mwarning",
                "continued\27[0m",
            })
            assert.equal("warning", result.lines[1])
            assert.equal("continued", result.lines[2])
            assert.is_true(result.has_ansi)

            -- Both lines should have highlights (state carries from line 1)
            assert.equal(1, #result.highlights[1])
            assert.equal(1, #result.highlights[2])
        end)

        it("handles reset code", function()
            local result = Ansi.process_lines({ "\27[31mred\27[0mnormal" })
            assert.equal("rednormal", result.lines[1])
            -- "red" gets a highlight, "normal" does not
            assert.equal(1, #result.highlights[1])
            assert.equal(0, result.highlights[1][1][1])
            assert.equal(3, result.highlights[1][1][2])
        end)

        it("handles bright colours (90–97)", function()
            local result = Ansi.process_lines({ "\27[92mbright green\27[0m" })
            assert.equal("bright green", result.lines[1])
            assert.is_true(result.has_ansi)
            assert.equal(1, #result.highlights[1])
        end)

        it("handles 256-colour mode", function()
            local result =
                Ansi.process_lines({ "\27[38;5;208morange\27[0m" })
            assert.equal("orange", result.lines[1])
            assert.is_true(result.has_ansi)
            assert.equal(1, #result.highlights[1])
        end)

        it("handles true colour (24-bit RGB)", function()
            local result =
                Ansi.process_lines({ "\27[38;2;255;128;0mcustom\27[0m" })
            assert.equal("custom", result.lines[1])
            assert.is_true(result.has_ansi)
            assert.equal(1, #result.highlights[1])
        end)

        it("strips non-SGR CSI sequences", function()
            -- CSI H = cursor position, CSI J = erase display
            local result =
                Ansi.process_lines({ "\27[2Jhello\27[1;1Hworld" })
            assert.equal("helloworld", result.lines[1])
            assert.is_false(result.has_ansi)
        end)

        it("handles bold and italic attributes", function()
            local result =
                Ansi.process_lines({ "\27[1;3mbold italic\27[0m" })
            assert.equal("bold italic", result.lines[1])
            assert.is_true(result.has_ansi)
            assert.equal(1, #result.highlights[1])
            -- The hl_group should contain B and I markers
            local hl = result.highlights[1][1][3]
            assert.truthy(hl:find("B"))
            assert.truthy(hl:find("I"))
        end)

        it("handles empty input", function()
            local result = Ansi.process_lines({})
            assert.same({}, result.lines)
            assert.is_false(result.has_ansi)
        end)

        it("handles line with only escape codes", function()
            local result = Ansi.process_lines({ "\27[0m\27[32m\27[0m" })
            assert.equal("", result.lines[1])
            assert.is_false(result.has_ansi)
        end)

        it("handles text before first escape", function()
            local result = Ansi.process_lines({ "prefix\27[31mred\27[0m" })
            assert.equal("prefixred", result.lines[1])
            -- "prefix" has no highlight, "red" has one
            assert.equal(1, #result.highlights[1])
            assert.equal(6, result.highlights[1][1][1]) -- starts after "prefix"
            assert.equal(9, result.highlights[1][1][2])
        end)

        it("handles background colours", function()
            local result =
                Ansi.process_lines({ "\27[41mred bg\27[0m" })
            assert.equal("red bg", result.lines[1])
            assert.is_true(result.has_ansi)
            assert.equal(1, #result.highlights[1])
        end)

        it("handles combined fg + bg", function()
            local result =
                Ansi.process_lines({ "\27[31;42mred on green\27[0m" })
            assert.equal("red on green", result.lines[1])
            assert.is_true(result.has_ansi)
            local hl = result.highlights[1][1][3]
            -- Should contain both fg and bg markers
            assert.truthy(hl:find("^AgenticAnsi_f"))
            assert.truthy(hl:find("b"))
        end)
    end)
end)
