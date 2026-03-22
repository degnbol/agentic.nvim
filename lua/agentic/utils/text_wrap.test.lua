local TextWrap = require("agentic.utils.text_wrap")
local assert = require("tests.helpers.assert")

describe("agentic.utils.TextWrap", function()
    describe("wrap_prose", function()
        it("leaves short lines unchanged", function()
            local lines = { "hello world" }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.same({ "hello world" }, result)
        end)

        it("wraps long prose lines at word boundaries", function()
            local line =
                "the quick brown fox jumps over the lazy dog and keeps running"
            local result = TextWrap.wrap_prose({ line }, 30)
            for _, l in ipairs(result) do
                assert.is_true(#l <= 30, "line too long: " .. l)
            end
            -- Recombined text should match original
            local joined = table.concat(result, " "):gsub("%s+", " ")
            assert.equal(line, joined)
        end)

        it("preserves blank lines", function()
            local lines = { "first paragraph", "", "second paragraph" }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.same(lines, result)
        end)

        it("does not wrap fenced code blocks", function()
            local lines = {
                "some prose",
                "```lua",
                "local very_long_variable_name = some_very_long_function_call(argument_one, argument_two, argument_three)",
                "```",
                "more prose",
            }
            local result = TextWrap.wrap_prose(lines, 40)
            -- Code line must be untouched
            assert.equal(
                "local very_long_variable_name = some_very_long_function_call(argument_one, argument_two, argument_three)",
                result[3]
            )
            -- Fence markers preserved
            assert.equal("```lua", result[2])
            assert.equal("```", result[4])
        end)

        it("preserves list marker indentation on continuation", function()
            local lines = {
                "- this is a very long list item that should wrap at some point around here",
            }
            local result = TextWrap.wrap_prose(lines, 40)
            assert.is_true(#result > 1)
            -- Continuation lines should be indented to align with list text
            for i = 2, #result do
                assert.is_true(
                    result[i]:match("^  ") ~= nil,
                    "continuation should be indented: " .. result[i]
                )
            end
        end)

        it("handles multiple code blocks", function()
            local lines = {
                "intro text that is fairly short",
                "```",
                "code block one with a really long line that should not be wrapped at all ever",
                "```",
                "middle prose",
                "```python",
                "another_long_code_line = True",
                "```",
                "ending prose",
            }
            local result = TextWrap.wrap_prose(lines, 30)
            -- Find the code lines and verify they're untouched
            local found_code1 = false
            local found_code2 = false
            for _, l in ipairs(result) do
                if
                    l
                    == "code block one with a really long line that should not be wrapped at all ever"
                then
                    found_code1 = true
                end
                if l == "another_long_code_line = True" then
                    found_code2 = true
                end
            end
            assert.is_true(found_code1, "first code block should be preserved")
            assert.is_true(found_code2, "second code block should be preserved")
        end)

        it("handles zero width gracefully", function()
            local lines = { "hello world" }
            local result = TextWrap.wrap_prose(lines, 0)
            assert.same(lines, result)
        end)

        it("handles single long word exceeding width", function()
            local lines = { "supercalifragilisticexpialidocious" }
            local result = TextWrap.wrap_prose(lines, 10)
            -- Single word cannot be broken, so it stays as one line
            assert.equal(1, #result)
            assert.equal("supercalifragilisticexpialidocious", result[1])
        end)

        it("formats markdown tables with aligned columns", function()
            local lines = {
                "| Name | Value |",
                "|---|---|",
                "| short | x |",
                "| longer name | longer value |",
            }
            local result = TextWrap.wrap_prose(lines, 40)
            assert.same({
                "| Name        | Value        |",
                "| ----------- | ------------ |",
                "| short       | x            |",
                "| longer name | longer value |",
            }, result)
        end)

        it("does not wrap table lines", function()
            local lines = {
                "| Column A | Column B | Column C | Column D | Column E |",
                "|---|---|---|---|---|",
                "| val1 | val2 | val3 | val4 | val5 |",
            }
            local result = TextWrap.wrap_prose(lines, 20)
            -- Table lines must not be word-wrapped even if wider than target
            assert.equal(3, #result)
            for _, l in ipairs(result) do
                assert.is_true(
                    l:match("^|") ~= nil,
                    "should be a table row: " .. l
                )
            end
        end)

        it("preserves table alignment markers", function()
            local lines = {
                "| Left | Centre | Right |",
                "|:---|:---:|---:|",
                "| a | b | c |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            -- Separator row should preserve alignment colons
            assert.equal("| :--- | :----: | ----: |", result[2])
        end)

        it("formats tables surrounded by prose", function()
            local lines = {
                "Here is a table:",
                "",
                "| A | B |",
                "|---|---|",
                "| 1 | 2 |",
                "",
                "And more prose after the table.",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.equal("Here is a table:", result[1])
            assert.equal("", result[2])
            assert.is_true(result[3]:match("^| A") ~= nil)
            assert.equal("", result[6])
            assert.equal("And more prose after the table.", result[7])
        end)

        it("handles table with missing trailing pipe", function()
            local lines = {
                "| A | B",
                "|---|---",
                "| 1 | 2",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            -- Should still format as a table
            assert.equal(3, #result)
            for _, l in ipairs(result) do
                assert.is_true(l:match("^|") ~= nil)
                assert.is_true(
                    l:match("|$") ~= nil,
                    "should have trailing pipe: " .. l
                )
            end
        end)

        it("handles table with uneven column counts", function()
            local lines = {
                "| A | B | C |",
                "|---|---|---|",
                "| 1 | 2 |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            -- Row with fewer columns should be padded
            assert.equal(3, #result)
            -- All rows should have same structure
            assert.is_true(result[3]:match("| 1") ~= nil)
        end)
    end)

    describe("wrap_single_line", function()
        it("wraps a long prose line", function()
            local line = "the quick brown fox jumps over the lazy dog"
            local result = TextWrap.wrap_single_line(line, 20)
            assert.is_true(#result > 1)
            for _, l in ipairs(result) do
                assert.is_true(#l <= 20, "line too long: " .. l)
            end
        end)

        it("leaves short lines unchanged", function()
            local result = TextWrap.wrap_single_line("hello", 80)
            assert.same({ "hello" }, result)
        end)

        it("skips blank lines", function()
            local result = TextWrap.wrap_single_line("", 20)
            assert.same({ "" }, result)
        end)

        it("skips code fence lines", function()
            local result = TextWrap.wrap_single_line(
                "```bash this is a very long fence line that exceeds the width",
                20
            )
            assert.equal(1, #result)
        end)

        it("skips table rows", function()
            local result = TextWrap.wrap_single_line(
                "| column one content | column two content | column three |",
                20
            )
            assert.equal(1, #result)
        end)

        it("returns original when width is 0", function()
            local result = TextWrap.wrap_single_line("hello world", 0)
            assert.same({ "hello world" }, result)
        end)
    end)
end)
