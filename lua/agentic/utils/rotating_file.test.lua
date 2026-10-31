local assert = require("tests.helpers.assert")

describe("agentic.utils.RotatingFile", function()
    local RotatingFile = require("agentic.utils.rotating_file")
    local max_bytes = 10

    --- @type string
    local path
    --- @type string
    local backup

    --- @param p string
    --- @return string|nil content
    local function read(p)
        local file = io.open(p, "r")
        if not file then
            return nil
        end
        local content = file:read("*a")
        file:close()
        return content
    end

    before_each(function()
        path = vim.fn.tempname()
        backup = path .. ".1"
    end)

    after_each(function()
        os.remove(path)
        vim.fs.rm(backup, { recursive = true, force = true })
    end)

    it("appends below the cap without rotating", function()
        assert.is_true(RotatingFile.append(path, "abc", max_bytes))
        assert.is_true(RotatingFile.append(path, "def", max_bytes))
        assert.equal("abcdef", read(path))
        assert.is_nil(read(backup))
    end)

    it(
        "rotates once the cap is reached, keeping the crossing append",
        function()
            assert.is_true(RotatingFile.append(path, "abcde", max_bytes))
            assert.is_true(RotatingFile.append(path, "fghij", max_bytes))
            assert.is_nil(read(path))
            assert.equal("abcdefghij", read(backup))

            assert.is_true(RotatingFile.append(path, "k", max_bytes))
            assert.equal("k", read(path))
            assert.equal("abcdefghij", read(backup))
        end
    )

    it("replaces an earlier backup on the next rotation", function()
        assert.is_true(RotatingFile.append(path, "0123456789", max_bytes))
        assert.is_true(RotatingFile.append(path, "abcdefghij", max_bytes))
        assert.equal("abcdefghij", read(backup))
    end)

    it(
        "returns an error when the file cannot be moved to the backup",
        function()
            vim.fn.mkdir(backup .. "/occupied", "p")
            local ok, err = RotatingFile.append(path, "0123456789", max_bytes)
            assert.is_false(ok)
            assert.equal("string", type(err))
        end
    )

    it("returns an error for a path in a missing directory", function()
        local ok, err = RotatingFile.append(
            vim.fn.tempname() .. "/missing/file.log",
            "abc",
            max_bytes
        )
        assert.is_false(ok)
        assert.equal("string", type(err))
    end)
end)
