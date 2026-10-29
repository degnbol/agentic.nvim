local JsonDisplay = require("agentic.utils.json_display")
local assert = require("tests.helpers.assert")

--- @param value any
--- @return string[]
local function pretty(value)
    return vim.split(
        vim.json.encode(value, { indent = "  ", sort_keys = true }),
        "\n"
    )
end

describe("agentic.utils.JsonDisplay", function()
    describe("lines", function()
        it(
            "shows a flat object as a key | value table sorted by key",
            function()
                local rows, lang = JsonDisplay.lines('{"b":"x","a":1.5}')
                assert.equal("markdown", lang)
                assert.same({
                    "| key | value |",
                    "| --- | ----- |",
                    "| a   | 1.5   |",
                    "| b   | x     |",
                }, rows)
            end
        )

        it("writes strings bare and other scalars as JSON", function()
            local rows = JsonDisplay.lines('{"a":true,"b":null,"c":"","d":3}')
            assert.same({
                "| key | value |",
                "| --- | ----- |",
                "| a   | true  |",
                "| b   | null  |",
                "| c   |       |",
                "| d   | 3     |",
            }, rows)
        end)

        it("shows an empty key as an empty key cell", function()
            local rows = JsonDisplay.lines('{"":"v"}')
            assert.equal("|     | v     |", rows[3])
        end)

        it("shows an array of flat objects one row per object", function()
            local rows, lang = JsonDisplay.lines(
                '[{"status":"done","content":"write the tests","id":"1"},'
                    .. '{"id":"2","content":"ship","status":"open"}]'
            )
            assert.equal("markdown", lang)
            assert.same({
                "| id  | status | content         |",
                "| --- | ------ | --------------- |",
                "| 1   | done   | write the tests |",
                "| 2   | open   | ship            |",
            }, rows)
        end)

        it("keeps key order among equally wide columns", function()
            local rows = JsonDisplay.lines('[{"a":"x","b":"y","c":"z"}]')
            assert.equal("| a   | b   | c   |", rows[1])
        end)

        it("escapes a pipe in a key and a value", function()
            local rows = JsonDisplay.lines('{"a|b":"c|d"}')
            assert.equal("| a\\|b | c\\|d  |", rows[3])
        end)

        it("decodes multi-line pretty source the same", function()
            local compact = JsonDisplay.lines('{"a":1,"b":"x"}')
            local spread = JsonDisplay.lines('{\n  "a": 1,\n  "b": "x"\n}')
            assert.same(compact, spread)
        end)

        it("falls back to pretty JSON for non-tabular values", function()
            local sources = {
                '{"a":{"b":1}}',
                "{}",
                "[]",
                "[1,2]",
                '[{"a":1},{"b":1}]',
                '{"a":"x\\ny"}',
                '{"a":"x\\ry"}',
                '{"a\\u0001":1}',
            }
            for _, source in ipairs(sources) do
                local rows, lang = JsonDisplay.lines(source)
                assert.equal("json", lang)
                assert.same(pretty(vim.json.decode(source)), rows)
            end
        end)

        it("returns nil for no object or array, or no JSON encoding", function()
            for _, source in ipairs({ "[1e999]", '"x"', "3", "{nope" }) do
                assert.is_nil(JsonDisplay.lines(source))
            end
        end)
    end)
end)
