local assert = require("tests.helpers.assert")
local OptionParse = require("agentic.utils.option_parse")

describe("OptionParse.option_value", function()
    --- @type table<string, agentic.OptionKind>
    local kinds = {
        ["-X"] = "taker",
        ["--method"] = "taker",
        ["-i"] = "boolean",
        ["--include"] = "boolean",
    }

    it("reads the value after = in --name=v", function()
        assert.same(
            { id = "method", values = { "GET" } },
            OptionParse.option_value("--method=GET", nil, kinds)
        )
    end)

    it("reads the next word for a hinted long taker", function()
        assert.same(
            { id = "method", values = { "GET" } },
            OptionParse.option_value("--method", "GET", kinds)
        )
    end)

    it("reads nothing for an unhinted or boolean long option", function()
        assert.is_nil(OptionParse.option_value("--meth", "GET", kinds))
        assert.is_nil(OptionParse.option_value("--include", "GET", kinds))
    end)

    it("skips hinted booleans in a cluster", function()
        assert.same(
            { id = "X", values = { "GET" } },
            OptionParse.option_value("-iX", "GET", kinds)
        )
        assert.same(
            { id = "X", values = { "GET" } },
            OptionParse.option_value("-iXGET", nil, kinds)
        )
    end)

    it("reads -X=GET as both =GET and GET", function()
        assert.same(
            { id = "X", values = { "=GET", "GET" } },
            OptionParse.option_value("-X=GET", nil, kinds)
        )
    end)

    it("reads nothing for a taker that is the last word", function()
        assert.is_nil(OptionParse.option_value("-X", nil, kinds))
        assert.is_nil(OptionParse.option_value("--method", nil, kinds))
    end)

    it("reads nothing when an unhinted letter comes first", function()
        assert.is_nil(OptionParse.option_value("-qX", "GET", kinds))
    end)

    it("reads nothing for a cluster of booleans", function()
        assert.is_nil(OptionParse.option_value("-ii", "GET", kinds))
    end)
end)
