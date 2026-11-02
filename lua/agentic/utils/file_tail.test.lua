local assert = require("tests.helpers.assert")

describe("FileTail", function()
    local Child = require("tests.helpers.child")
    local child = Child.new()

    before_each(function()
        child.launch()
        child.lua([[
            local FileTail = require("agentic.utils.file_tail")
            _G.path = vim.fs.joinpath(vim.fn.tempname(), "task.output")
            vim.fn.mkdir(vim.fs.dirname(_G.path), "p")
            vim.fn.writefile({}, _G.path)
            _G.reports = {}
            _G.tail = assert(FileTail:new(_G.path, 2, function(rows)
                table.insert(_G.reports, rows)
            end))
            _G.initial = _G.reports
            _G.reports = {}
        ]])
    end)

    after_each(function()
        child.stop()
    end)

    --- Append to the file every 50 ms, for up to 2 s, until the child has
    --- reported. Repeated, since on macOS the watch goes live after `start`
    --- returns and misses a write made before then.
    --- @return integer n_reports
    local function append_until_reported()
        for _ = 1, 40 do
            child.lua([[vim.fn.writefile({ "line" }, _G.path, "a")]])
            vim.uv.sleep(50)
            local n_reports = child.lua_get("#_G.reports")
            if n_reports > 0 then
                return n_reports
            end
        end
        return 0
    end

    it("reports the current rows before returning", function()
        assert.same({ {} }, child.lua_get("_G.initial"))
    end)

    it("reports nothing for a removed file", function()
        assert.is_true(append_until_reported() > 0)
        vim.uv.sleep(300)
        child.lua([[
            _G.reports = {}
            _G.notified = 0
            require("agentic.utils.logger").notify = function()
                _G.notified = _G.notified + 1
            end
            os.remove(_G.path)
        ]])
        vim.uv.sleep(400)

        assert.same({}, child.lua_get("_G.reports"))
        assert.equal(0, child.lua_get("_G.notified"))
    end)

    it("reports the last lines once per burst", function()
        assert.is_true(append_until_reported() > 0)
        vim.uv.sleep(300)
        child.lua([[
            _G.reports = {}
            vim.fn.writefile({ "a" }, _G.path, "a")
            vim.fn.writefile({ "b" }, _G.path, "a")
            vim.fn.writefile({ "c" }, _G.path, "a")
        ]])
        vim.uv.sleep(400)

        assert.same({ { "b", "c" } }, child.lua_get("_G.reports"))
    end)

    it("does not report rows that did not change", function()
        assert.is_true(append_until_reported() > 0)
        vim.uv.sleep(300)
        child.lua([[
            _G.reports = {}
            vim.fn.writefile(vim.fn.readfile(_G.path), _G.path)
        ]])
        vim.uv.sleep(400)

        assert.same({}, child.lua_get("_G.reports"))
    end)

    it("reports nothing after stop, and stops twice", function()
        assert.is_true(append_until_reported() > 0)
        vim.uv.sleep(300)
        child.lua([[
            _G.reports = {}
            vim.fn.writefile({ "late" }, _G.path, "a")
            _G.tail:stop()
            _G.tail:stop()
        ]])
        vim.uv.sleep(400)

        assert.same({}, child.lua_get("_G.reports"))
    end)
end)
