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

        it("never wraps inside an inline code span", function()
            local line =
                "run the `git commit -m msg` command and then push it upstream"
            local result = TextWrap.wrap_prose({ line }, 30)
            -- The whole span stays on one output line.
            local has_span = false
            for _, l in ipairs(result) do
                if l:match("`git commit %-m msg`") then
                    has_span = true
                end
            end
            assert.is_true(has_span, "code span was broken up")
        end)

        it("keeps an oversized code span whole rather than splitting it", function()
            local line = "prefix `one two three four five six seven` suffix"
            local result = TextWrap.wrap_prose({ line }, 20)
            local joined = table.concat(result, " "):gsub("%s+", " ")
            assert.equal(line, joined)
            local has_span = false
            for _, l in ipairs(result) do
                if l:match("`one two three four five six seven`") then
                    has_span = true
                end
            end
            assert.is_true(has_span, "oversized span was broken up")
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

        --- Strip concealed markdown delimiters to compute visual width,
        --- mirroring cell_visual_width logic.
        local function visual_width(s)
            s = s:gsub("`([^`]+)`", "%1")
            s = s:gsub("%*%*%*(.-)%*%*%*", "%1")
            s = s:gsub("%*%*(.-)%*%*", "%1")
            s = s:gsub("%*(.-)%*", "%1")
            s = s:gsub("~~(.-)~~", "%1")
            return #s
        end

        it("accounts for concealed backticks in table column widths", function()
            local lines = {
                "| Name | Type |",
                "|---|---|",
                "| `foo` | string |",
                "| longname | `int` |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.equal(4, #result)
            local vw1 = visual_width(result[1])
            for i = 2, #result do
                assert.equal(vw1, visual_width(result[i]))
            end
            -- Rows with backticks have more bytes than rows without
            assert.is_true(#result[3] > #result[1])
        end)

        it(
            "accounts for concealed bold markers in table column widths",
            function()
                local lines = {
                    "| Name | Type |",
                    "|---|---|",
                    "| **foo** | string |",
                    "| longname | **int** |",
                }
                local result = TextWrap.wrap_prose(lines, 80)
                assert.equal(4, #result)
                local vw1 = visual_width(result[1])
                for i = 2, #result do
                    assert.equal(vw1, visual_width(result[i]))
                end
                -- Rows with bold markers have more bytes than rows without
                assert.is_true(#result[3] > #result[1])
            end
        )

        it(
            "accounts for concealed italic markers in table column widths",
            function()
                local lines = {
                    "| Name | Type |",
                    "|---|---|",
                    "| *foo* | string |",
                    "| longname | *int* |",
                }
                local result = TextWrap.wrap_prose(lines, 80)
                assert.equal(4, #result)
                local vw1 = visual_width(result[1])
                for i = 2, #result do
                    assert.equal(vw1, visual_width(result[i]))
                end
            end
        )

        it(
            "accounts for concealed strikethrough markers in table column widths",
            function()
                local lines = {
                    "| Name | Status |",
                    "|---|---|",
                    "| ~~removed~~ | old |",
                    "| longername | current |",
                }
                local result = TextWrap.wrap_prose(lines, 80)
                assert.equal(4, #result)
                local vw1 = visual_width(result[1])
                for i = 2, #result do
                    assert.equal(vw1, visual_width(result[i]))
                end
            end
        )

        it("handles mixed concealed markers in table cells", function()
            local lines = {
                "| Name | Type | Note |",
                "|---|---|---|",
                "| **`foo`** | *string* | ~~old~~ |",
                "| plain | plain | plain |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.equal(4, #result)
            local vw1 = visual_width(result[1])
            for i = 2, #result do
                assert.equal(vw1, visual_width(result[i]))
            end
        end)

        it("preserves escaped pipe characters in table cells", function()
            local lines = {
                "| Command | Description |",
                "|---|---|",
                "| echo foo \\| grep bar | filter output |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.equal(3, #result)
            -- Escaped pipe must stay inside the cell, not split it
            assert.is_true(
                result[3]:match("echo foo \\| grep bar") ~= nil,
                "escaped pipe lost: " .. result[3]
            )
            -- Should still have exactly 2 data columns
            -- Count unescaped pipes (leading + separator + trailing = 3)
            local pipe_count = 0
            local i = 1
            while i <= #result[3] do
                if
                    result[3]:sub(i, i) == "\\"
                    and result[3]:sub(i + 1, i + 1) == "|"
                then
                    i = i + 2
                elseif result[3]:sub(i, i) == "|" then
                    pipe_count = pipe_count + 1
                    i = i + 1
                else
                    i = i + 1
                end
            end
            assert.equal(3, pipe_count)
        end)

        it(
            "treats double backslash before pipe as literal backslash + delimiter",
            function()
                local lines = {
                    "| A | B | C |",
                    "|---|---|---|",
                    "| foo\\\\ | bar | baz |",
                }
                local result = TextWrap.wrap_prose(lines, 80)
                assert.equal(3, #result)
                -- foo\\ is a literal backslash — pipe after it is a real delimiter
                -- so we should still have 3 data columns
                assert.is_true(result[3]:match("foo\\\\") ~= nil)
                assert.is_true(result[3]:match("bar") ~= nil)
                assert.is_true(result[3]:match("baz") ~= nil)
            end
        )

        it("preserves empty cells in table rows", function()
            local lines = {
                "|       | birth | pers | death |",
                "| ----- | ----- | ---- | ----- |",
                "| 3 A25 | 0.30  | 1.19 | 1.49  |",
                "| 2 A42 | 2.32  | 2.50 | 4.82  |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            -- Header must keep the empty first cell — 4 columns, not 3
            assert.equal("|       | birth | pers | death |", result[1])
            assert.equal(4, #result)
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

        it("never wraps inside an inline math span", function()
            local line =
                "the identity $x + y = z + w$ holds for all reals here yes"
            local result = TextWrap.wrap_prose({ line }, 30)
            local has_span = false
            for _, l in ipairs(result) do
                if l:match("%$x %+ y = z %+ w%$") then
                    has_span = true
                end
            end
            assert.is_true(has_span, "math span was broken up")
        end)

        it("wraps before an oversized inline math span", function()
            local line = "prefix $a + b + c + d + e + f + g$ suffix"
            local result = TextWrap.wrap_prose({ line }, 20)
            local joined = table.concat(result, " "):gsub("%s+", " ")
            assert.equal(line, joined)
            local has_span = false
            for _, l in ipairs(result) do
                if l:match("^%$a %+ b %+ c %+ d %+ e %+ f %+ g%$") then
                    has_span = true
                end
            end
            assert.is_true(has_span, "span should start a fresh line")
        end)

        it("treats an unclosed dollar as literal and wraps normally", function()
            local line =
                "the cost is $5 for the first widget and rises steeply after that"
            local result = TextWrap.wrap_prose({ line }, 30)
            for _, l in ipairs(result) do
                assert.is_true(#l <= 30, "line too long: " .. l)
            end
            local joined = table.concat(result, " "):gsub("%s+", " ")
            assert.equal(line, joined)
        end)

        it("keeps a single-line display-math span atomic", function()
            local line = "before $$x = \\sum_i a_i b_i$$ after the equation ok"
            local result = TextWrap.wrap_prose({ line }, 25)
            local has_span = false
            for _, l in ipairs(result) do
                if l:match("%$%$x = \\sum_i a_i b_i%$%$") then
                    has_span = true
                end
            end
            assert.is_true(has_span, "display-math span was broken up")
        end)

        it("leaves a bare currency amount shorter than width untouched", function()
            local lines = { "it costs $5 total" }
            assert.same(lines, TextWrap.wrap_prose(lines, 80))
        end)

        it("passes multi-line display-math blocks through untouched", function()
            local lines = {
                "Consider the sum:",
                "$$",
                "\\sum_{i=1}^{n} a_i b_i = a_1 b_1 + a_2 b_2 + \\cdots + a_n b_n",
                "$$",
                "which converges.",
            }
            local result = TextWrap.wrap_prose(lines, 30)
            assert.same(lines, result)
        end)

        it("does not let a $$ line inside a code fence enter math mode", function()
            local lines = {
                "```",
                "$$",
                "this is code not math and it is quite long so would wrap as prose",
                "```",
                "after the fence this prose line is long enough that it must wrap",
            }
            local result = TextWrap.wrap_prose(lines, 30)
            assert.equal("```", result[1])
            assert.equal("$$", result[2])
            assert.equal(
                "this is code not math and it is quite long so would wrap as prose",
                result[3]
            )
            assert.equal("```", result[4])
            -- Prose after the closed fence must still wrap.
            assert.is_true(#result > 5)
        end)

        it("never wraps headings", function()
            local heading =
                "## the quick brown fox jumps over the lazy dog and keeps running"
            assert.same({ heading }, TextWrap.wrap_prose({ heading }, 30))
            -- 7+ hashes is not a heading and may wrap like prose
            local non_heading =
                "####### not a heading but still long enough to wrap around"
            assert.is_true(#TextWrap.wrap_prose({ non_heading }, 30) > 1)
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

    describe("wrap_single_line_with_offsets", function()
        it("maps sub-line columns back through an inline math span", function()
            local line = "start $a + b$ and then more trailing text to wrap here"
            local sub_lines, offsets =
                TextWrap.wrap_single_line_with_offsets(line, 20)
            assert.is_true(#sub_lines > 1)
            -- The math span stays whole on one sub-line.
            local has_span = false
            for _, l in ipairs(sub_lines) do
                if l:match("%$a %+ b%$") then
                    has_span = true
                end
            end
            assert.is_true(has_span, "math span was broken across sub-lines")
            -- Each offset must map its sub-line content (after the added
            -- continuation indent) back to the matching bytes in the original.
            for i, l in ipairs(sub_lines) do
                local content = l:sub(offsets[i].indent_len + 1)
                local orig = line:sub(
                    offsets[i].orig_start + 1,
                    offsets[i].orig_start + #content
                )
                assert.equal(content, orig)
            end
        end)
    end)

    describe("format_tables_in_lines", function()
        it("formats a table among prose lines", function()
            local result = TextWrap.format_tables_in_lines({
                "Some text before",
                "| a | bb |",
                "| --- | --- |",
                "| longer | x |",
                "After the table",
            })
            assert.same({
                "Some text before",
                "| a      | bb  |",
                "| ------ | --- |",
                "| longer | x   |",
                "After the table",
            }, result)
        end)

        it("formats two separate tables independently", function()
            local result = TextWrap.format_tables_in_lines({
                "| a | b |",
                "| --- | --- |",
                "| short | x |",
                "divider line",
                "| col1 | col2 | col3 |",
                "| --- | --- | --- |",
                "| val | val | val |",
            })
            assert.equal(7, #result)
            -- First table: "short" is widest at 5, min-width 3 applies to col 2
            assert.equal("| a     | b   |", result[1])
            -- Second table: all columns same width
            assert.equal("| col1 | col2 | col3 |", result[5])
        end)

        it("passes through lines without tables unchanged", function()
            local input = { "hello", "world", "" }
            local result = TextWrap.format_tables_in_lines(input)
            assert.same(input, result)
        end)
    end)
end)
