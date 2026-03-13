local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("FileSystem", function()
    --- @type agentic.utils.FileSystem
    local FileSystem

    before_each(function()
        -- Force fresh module load to avoid stale stubs from other test files
        package.loaded["agentic.utils.file_system"] = nil
        FileSystem = require("agentic.utils.file_system")
    end)

    describe("IMAGE_MIMES", function()
        it("maps common image extensions to MIME types", function()
            assert.equal("image/png", FileSystem.IMAGE_MIMES.png)
            assert.equal("image/jpeg", FileSystem.IMAGE_MIMES.jpg)
            assert.equal("image/jpeg", FileSystem.IMAGE_MIMES.jpeg)
            assert.equal("image/gif", FileSystem.IMAGE_MIMES.gif)
            assert.equal("image/webp", FileSystem.IMAGE_MIMES.webp)
            assert.equal("image/svg+xml", FileSystem.IMAGE_MIMES.svg)
        end)

        it("does not contain non-image types", function()
            assert.is_nil(FileSystem.IMAGE_MIMES.mp3)
            assert.is_nil(FileSystem.IMAGE_MIMES.lua)
            assert.is_nil(FileSystem.IMAGE_MIMES.txt)
        end)
    end)

    describe("AUDIO_MIMES", function()
        it("maps common audio extensions to MIME types", function()
            assert.equal("audio/mpeg", FileSystem.AUDIO_MIMES.mp3)
            assert.equal("audio/wav", FileSystem.AUDIO_MIMES.wav)
            assert.equal("audio/ogg", FileSystem.AUDIO_MIMES.ogg)
            assert.equal("audio/flac", FileSystem.AUDIO_MIMES.flac)
            assert.equal("audio/opus", FileSystem.AUDIO_MIMES.opus)
        end)

        it("does not contain non-audio types", function()
            assert.is_nil(FileSystem.AUDIO_MIMES.png)
            assert.is_nil(FileSystem.AUDIO_MIMES.lua)
        end)
    end)

    describe("get_file_extension", function()
        it("returns lowercase extension", function()
            assert.equal("lua", FileSystem.get_file_extension("init.lua"))
        end)

        it("handles uppercase extensions", function()
            assert.equal("png", FileSystem.get_file_extension("photo.PNG"))
        end)

        it("handles paths with directories", function()
            assert.equal(
                "rs",
                FileSystem.get_file_extension("/home/user/project/main.rs")
            )
        end)

        it("returns empty string for no extension", function()
            assert.equal("", FileSystem.get_file_extension("Makefile"))
        end)

        it("handles double extensions (returns last)", function()
            assert.equal("gz", FileSystem.get_file_extension("data.tar.gz"))
        end)
    end)

    describe("base_name", function()
        it("returns filename from path", function()
            assert.equal(
                "init.lua",
                FileSystem.base_name("/home/user/init.lua")
            )
        end)

        it("returns filename from relative path", function()
            assert.equal(
                "test.lua",
                FileSystem.base_name("lua/agentic/test.lua")
            )
        end)

        it("returns name itself when no directory", function()
            assert.equal("file.txt", FileSystem.base_name("file.txt"))
        end)
    end)

    describe("to_relative_path", function()
        it("converts absolute path to relative", function()
            local cwd = vim.fn.getcwd()
            local abs_path = cwd .. "/lua/agentic/init.lua"
            assert.equal(
                "lua/agentic/init.lua",
                FileSystem.to_relative_path(abs_path)
            )
        end)

        it("returns path unchanged if already relative", function()
            assert.equal(
                "lua/agentic/init.lua",
                FileSystem.to_relative_path("lua/agentic/init.lua")
            )
        end)
    end)

    describe("to_absolute_path", function()
        it("converts relative path to absolute", function()
            local result = FileSystem.to_absolute_path("init.lua")
            -- Absolute paths start with /
            assert.equal("/", result:sub(1, 1))
        end)

        it("keeps absolute path unchanged", function()
            local result = FileSystem.to_absolute_path("/tmp/test.lua")
            assert.equal("/tmp/test.lua", result)
        end)
    end)

    describe("to_smart_path", function()
        it("returns relative path for files in cwd", function()
            local cwd = vim.fn.getcwd()
            local result = FileSystem.to_smart_path(cwd .. "/lua/init.lua")
            assert.equal("lua/init.lua", result)
        end)

        it("uses ~ for home directory paths outside cwd", function()
            local home = vim.env.HOME
            local result =
                FileSystem.to_smart_path(home .. "/some/other/file.lua")
            -- Should start with ~ when outside cwd
            local starts_with_tilde = result:sub(1, 1) == "~"
            local is_relative = result:sub(1, 1) ~= "/"
            assert.is_true(starts_with_tilde or is_relative)
        end)
    end)

    describe("read_from_buffer_or_disk", function()
        it("reads from disk when no buffer exists", function()
            local tmp = os.tmpname()
            local f = io.open(tmp, "w")
            assert.is_not_nil(f)
            ---@cast f -nil
            f:write("line one\nline two\n")
            f:close()

            local lines, err = FileSystem.read_from_buffer_or_disk(tmp)

            assert.is_nil(err)
            assert.is_not_nil(lines)
            ---@cast lines -nil
            assert.equal("line one", lines[1])
            assert.equal("line two", lines[2])

            os.remove(tmp)
        end)

        it("returns error for non-existent file", function()
            local lines, err = FileSystem.read_from_buffer_or_disk(
                "/tmp/nonexistent_agentic_test_file_xyz"
            )

            assert.is_nil(lines)
            assert.is_not_nil(err)
        end)

        it("returns error for directory path", function()
            -- Use a subdirectory that won't be loaded as a neovim buffer
            local dir = os.tmpname()
            os.remove(dir)
            vim.fn.mkdir(dir, "p")

            local lines, err = FileSystem.read_from_buffer_or_disk(dir)

            assert.is_nil(lines)
            assert.is_not_nil(err)
            ---@cast err -nil
            assert.truthy(err:find("directory"))

            vim.fn.delete(dir, "rf")
        end)

        it("normalises CRLF to LF", function()
            local tmp = os.tmpname()
            local f = io.open(tmp, "wb")
            assert.is_not_nil(f)
            ---@cast f -nil
            f:write("line one\r\nline two\r\n")
            f:close()

            local lines, err = FileSystem.read_from_buffer_or_disk(tmp)

            assert.is_nil(err)
            assert.is_not_nil(lines)
            ---@cast lines -nil
            assert.equal("line one", lines[1])
            assert.equal("line two", lines[2])

            os.remove(tmp)
        end)
    end)

    describe("save_to_disk", function()
        it("writes content to file", function()
            local tmp = os.tmpname()

            local ok, err = FileSystem.save_to_disk(tmp, "hello world")

            assert.is_true(ok)
            assert.is_nil(err)

            local f = io.open(tmp, "r")
            assert.is_not_nil(f)
            ---@cast f -nil
            local content = f:read("*a")
            f:close()
            assert.equal("hello world", content)

            os.remove(tmp)
        end)

        it("returns error for invalid path", function()
            local ok, err =
                FileSystem.save_to_disk("/nonexistent_dir_xyz/file.txt", "test")

            assert.is_false(ok)
            assert.is_not_nil(err)
        end)
    end)

    describe("mkdirp", function()
        it("creates nested directories", function()
            local base = "/tmp/agentic_test_mkdirp_" .. os.time()
            local path = base .. "/nested/deep"

            local ok, err = FileSystem.mkdirp(path)

            assert.is_true(ok)
            assert.is_nil(err)

            local stat = vim.uv.fs_stat(path)
            assert.is_not_nil(stat)
            ---@cast stat -nil
            assert.equal("directory", stat.type)

            -- Cleanup
            vim.fn.delete(base, "rf")
        end)

        it("succeeds when directory already exists", function()
            local ok, err = FileSystem.mkdirp("/tmp")

            assert.is_true(ok)
            assert.is_nil(err)
        end)
    end)

    describe("read_file_base64", function()
        it("returns base64 encoded content", function()
            local tmp = os.tmpname()
            local f = io.open(tmp, "wb")
            assert.is_not_nil(f)
            ---@cast f -nil
            f:write("hello")
            f:close()

            local result = FileSystem.read_file_base64(tmp)

            assert.equal(vim.base64.encode("hello"), result)

            os.remove(tmp)
        end)

        it("returns empty string for non-existent file", function()
            local notify_stub =
                spy.stub(require("agentic.utils.logger"), "notify")

            local result =
                FileSystem.read_file_base64("/tmp/nonexistent_agentic_xyz")

            assert.equal("", result)

            notify_stub:revert()
        end)
    end)
end)
