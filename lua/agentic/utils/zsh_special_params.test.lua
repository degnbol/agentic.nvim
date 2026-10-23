local MiniTest = require("mini.test")
local assert = require("tests.helpers.assert")
local ZshSpecialParams = require("agentic.utils.zsh_special_params")

describe("zsh_special_params", function()
    it("covers every special parameter of the installed zsh", function()
        if vim.fn.executable("zsh") == 0 then
            if vim.env.CI then
                error("zsh is not on $PATH; the drift test needs it under CI")
            end
            MiniTest.skip("zsh is not on $PATH")
        end
        local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
        local result = vim.system({ dir .. "/zsh_special_params.lua.sh" })
            :wait()
        if result.code ~= 0 then
            error("zsh_special_params.lua.sh failed: " .. result.stderr)
        end
        local generated = loadstring(result.stdout)()
        local missing = {}
        for name in pairs(generated) do
            if not ZshSpecialParams[name] then
                table.insert(missing, name)
            end
        end
        table.sort(missing)
        assert.same({}, missing)
    end)
end)
