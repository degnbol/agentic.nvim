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

    --- @param content string
    --- @return string path A new temporary file holding `content`
    local function write_temp(content)
        local path = vim.fn.tempname()
        local f = io.open(path, "w")
        assert.is_not_nil(f)
        ---@cast f -nil
        f:write(content)
        f:close()
        return path
    end

    --- @param name string
    --- @param lines string[]
    --- @return integer bufnr A loaded, unmodified buffer named `name`
    local function loaded_buffer(name, lines)
        local bufnr = vim.api.nvim_create_buf(false, false)
        vim.api.nvim_buf_set_name(bufnr, name)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modified = false
        return bufnr
    end

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

    describe("read_appended", function()
        --- @type string
        local tmp

        before_each(function()
            tmp = os.tmpname()
        end)

        after_each(function()
            os.remove(tmp)
        end)

        --- @param text string
        --- @param mode string|nil
        local function write(text, mode)
            local f = io.open(tmp, mode or "ab")
            assert.is_not_nil(f)
            ---@cast f -nil
            f:write(text)
            f:close()
        end

        it("returns whole lines and the offset just past them", function()
            write("one\ntwo\n")

            local lines, offset, err = FileSystem.read_appended(tmp, 0)

            assert.is_nil(err)
            assert.same({ "one", "two" }, lines)
            assert.equal(8, offset)
        end)

        it("leaves a trailing partial line for the next call", function()
            write("one\npart")

            local lines, offset = FileSystem.read_appended(tmp, 0)
            assert.same({ "one" }, lines)
            assert.equal(4, offset)

            write("ial\n")
            local more, next_offset = FileSystem.read_appended(tmp, offset)
            assert.same({ "partial" }, more)
            assert.equal(12, next_offset)
        end)

        it("returns nothing when no complete line has arrived", function()
            write("partial")

            local lines, offset = FileSystem.read_appended(tmp, 0)

            assert.same({}, lines)
            assert.equal(0, offset)
        end)

        it("returns nothing when the file has not grown", function()
            write("one\n")
            local _, offset = FileSystem.read_appended(tmp, 0)

            local lines, next_offset = FileSystem.read_appended(tmp, offset)

            assert.same({}, lines)
            assert.equal(offset, next_offset)
        end)

        it("restarts from the beginning when the file shrank", function()
            write("first\nsecond\n")
            local _, offset = FileSystem.read_appended(tmp, 0)

            write("fresh\n", "wb")

            local lines, next_offset = FileSystem.read_appended(tmp, offset)

            assert.same({ "fresh" }, lines)
            assert.equal(6, next_offset)
        end)

        it("keeps the offset when the file cannot be opened", function()
            local lines, offset, err =
                FileSystem.read_appended("/tmp/agentic_absent_transcript", 42)

            assert.is_nil(lines)
            assert.equal(42, offset)
            assert.is_not_nil(err)
        end)

        it("does not rewrite CRLF, which would shift the offset", function()
            write("one\r\ntwo\r\n")

            local lines, offset = FileSystem.read_appended(tmp, 0)

            assert.same({ "one\r", "two\r" }, lines)
            assert.equal(10, offset)
        end)
    end)

    describe("read_last_lines", function()
        --- @type string
        local tmp

        before_each(function()
            tmp = os.tmpname()
        end)

        after_each(function()
            os.remove(tmp)
        end)

        --- @param text string
        local function write(text)
            local f = io.open(tmp, "wb")
            assert.is_not_nil(f)
            ---@cast f -nil
            f:write(text)
            f:close()
        end

        it("returns every line of a short file", function()
            write("one\ntwo\n")

            local lines, err = FileSystem.read_last_lines(tmp, 10)

            assert.is_nil(err)
            assert.same({ "one", "two" }, lines)
        end)

        it("keeps only the last lines", function()
            write("one\ntwo\nthree\n")

            assert.same({ "two", "three" }, FileSystem.read_last_lines(tmp, 2))
        end)

        it("includes a last line without a newline", function()
            write("one\npartial")

            assert.same(
                { "one", "partial" },
                FileSystem.read_last_lines(tmp, 5)
            )
        end)

        it("returns nothing for an empty file", function()
            write("")

            assert.same({}, FileSystem.read_last_lines(tmp, 5))
        end)

        it("drops the partial first line of a read past 64 KiB", function()
            local long = string.rep("x", 70 * 1024)
            write(long .. "\nlast\n")

            assert.same({ "last" }, FileSystem.read_last_lines(tmp, 5))
        end)

        it("returns the error for a missing file", function()
            local lines, err =
                FileSystem.read_last_lines("/tmp/agentic_absent_output", 5)

            assert.is_nil(lines)
            assert.is_not_nil(err)
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

        it(
            "does not read a buffer whose name only contains the path",
            function()
                local path = write_temp("on disk\n")
                local bak = loaded_buffer(path .. ".bak", { "backup" })

                local lines = FileSystem.read_from_buffer_or_disk(path)

                assert.same({ "on disk", "" }, lines)
                vim.api.nvim_buf_delete(bak, { force = true })
                os.remove(path)
            end
        )
    end)

    describe("reload_buffer", function()
        it("puts the file's lines in its loaded buffer", function()
            local path = write_temp("new one\nnew two")
            local bufnr = loaded_buffer(path, { "old" })
            vim.bo[bufnr].modifiable = false
            vim.bo[bufnr].modified = true

            FileSystem.reload_buffer(path)

            assert.same(
                { "new one", "new two" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
            assert.is_false(vim.bo[bufnr].modifiable)
            assert.is_false(vim.bo[bufnr].modified)
            vim.api.nvim_buf_delete(bufnr, { force = true })
            os.remove(path)
        end)

        it(
            "does not touch a buffer whose name only contains the path",
            function()
                local path = write_temp("new")
                local bak = loaded_buffer(path .. ".bak", { "backup" })

                FileSystem.reload_buffer(path)

                assert.same(
                    { "backup" },
                    vim.api.nvim_buf_get_lines(bak, 0, -1, false)
                )
                vim.api.nvim_buf_delete(bak, { force = true })
                os.remove(path)
            end
        )

        it("finds the buffer through a symlinked directory", function()
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir .. "/real", "p")
            vim.uv.fs_symlink(dir .. "/real", dir .. "/link")
            vim.uv.fs_rename(write_temp("new"), dir .. "/real/f")
            local bufnr = loaded_buffer(dir .. "/link/f", { "old" })

            FileSystem.reload_buffer(dir .. "/link/f")

            assert.same(
                { "new" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
            vim.api.nvim_buf_delete(bufnr, { force = true })
            vim.fn.delete(dir, "rf")
        end)

        it("finds a buffer named before its directory existed", function()
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir .. "/real", "p")
            vim.uv.fs_symlink(dir .. "/real", dir .. "/link")
            local path = dir .. "/link/new/f"
            local bufnr = loaded_buffer(path, { "old" })
            vim.fn.mkdir(dir .. "/link/new", "p")
            vim.uv.fs_rename(write_temp("new"), path)

            FileSystem.reload_buffer(path)

            assert.same(
                { "new" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
            vim.api.nvim_buf_delete(bufnr, { force = true })
            vim.fn.delete(dir, "rf")
        end)

        it("finds a buffer named after a symlink to the file", function()
            local target = write_temp("new")
            local link = vim.fn.tempname()
            vim.uv.fs_symlink(target, link)
            local bufnr = loaded_buffer(link, { "old" })

            FileSystem.reload_buffer(target)

            assert.same(
                { "new" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
            vim.api.nvim_buf_delete(bufnr, { force = true })
            os.remove(link)
            os.remove(target)
        end)

        it("does nothing without a loaded buffer", function()
            local path = write_temp("new")
            FileSystem.reload_buffer(path)
            os.remove(path)
        end)
    end)

    describe("write_file", function()
        it("writes the file and reloads its loaded buffer", function()
            local path = write_temp("old")
            local bufnr = loaded_buffer(path, { "old" })
            local callback = spy.new(function() end)

            FileSystem.write_file(
                path,
                "new",
                callback --[[@as fun(error: string|nil)]]
            )

            assert.same(
                { "new" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
            assert.equal(1, callback.call_count)
            assert.is_nil(callback.calls[1][1])
            vim.api.nvim_buf_delete(bufnr, { force = true })
            os.remove(path)
        end)
    end)

    describe("read_json", function()
        it("decodes the file", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ '{"a": [1, 2],', '"b": "x"}' }, path)

            assert.same(
                { { a = { 1, 2 }, b = "x" } },
                { FileSystem.read_json(path) }
            )
        end)

        it("returns an error for a missing file", function()
            local value, err = FileSystem.read_json(vim.fn.tempname())

            assert.is_nil(value)
            assert.is_not_nil(err)
        end)

        it("returns an error naming the file for invalid JSON", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ "not json {{{" }, path)

            local value, err = FileSystem.read_json(path)

            assert.is_nil(value)
            assert.truthy((err or ""):find(path, 1, true))
        end)
    end)

    describe("mtime", function()
        it("is 0 for a missing file", function()
            assert.equal(0, FileSystem.mtime(vim.fn.tempname()))
        end)

        it("is the modification time of an existing file", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ "x" }, path)
            vim.uv.fs_utime(path, 1000, 1000)

            assert.equal(1000, FileSystem.mtime(path))
        end)
    end)

    describe("read_json_if_present", function()
        local Logger = require("agentic.utils.logger")
        local notify

        before_each(function()
            notify = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify:revert()
        end)

        it("is nil without a warning for a missing file", function()
            assert.is_nil(FileSystem.read_json_if_present(vim.fn.tempname()))
            assert.equal(0, notify.call_count)
        end)

        it("is nil and warns for invalid JSON", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ "not json {{{" }, path)

            assert.is_nil(FileSystem.read_json_if_present(path))
            assert.equal(1, notify.call_count)
        end)

        it("decodes the file", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ '{"a": 1}' }, path)

            assert.same({ a = 1 }, FileSystem.read_json_if_present(path))
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

    describe("write_atomic", function()
        it("writes the content, creating the parent directory", function()
            local path = vim.fs.joinpath(vim.fn.tempname(), "sub", "file.json")

            assert.same({ true }, { FileSystem.write_atomic(path, "hello") })
            assert.same({ "hello" }, vim.fn.readfile(path))
        end)

        it("replaces an existing file", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ "old" }, path)

            FileSystem.write_atomic(path, "new")

            assert.same({ "new" }, vim.fn.readfile(path))
        end)
    end)

    describe("watch", function()
        local Child = require("tests.helpers.child")
        local child = Child.new()

        before_each(function()
            child.launch()
            child.lua([[
                local FileSystem = require("agentic.utils.file_system")
                local dir = vim.fn.tempname()
                _G.path = vim.fs.joinpath(dir, "file.json")
                _G.sibling = vim.fs.joinpath(dir, "other.json")
                _G.changes = 0
                _G.handle = assert(FileSystem.watch(_G.path, function(err)
                    assert(not err, err)
                    _G.changes = _G.changes + 1
                end))
            ]])
        end)

        after_each(function()
            child.stop()
        end)

        --- Replace the watched file every 50 ms, for up to 2 s, until the
        --- child sees a change. Repeated, since on macOS the watch goes live
        --- after `watch` returns and misses a write made before then.
        --- @return integer changes 0 if none were seen within 2 s
        local function replace_until_seen()
            for _ = 1, 40 do
                child.lua([[
                    require("agentic.utils.file_system").write_atomic(_G.path, "x")
                ]])
                vim.uv.sleep(50)
                local changes = child.lua_get("_G.changes")
                if changes > 0 then
                    return changes
                end
            end
            return 0
        end

        it("calls back when the file is replaced", function()
            assert.is_true(replace_until_seen() > 0)
        end)

        it("ignores a sibling file", function()
            -- Only a live watch can show that the sibling is filtered out.
            assert.is_true(replace_until_seen() > 0)
            vim.uv.sleep(500)
            child.lua("_G.changes = 0")

            child.lua([[
                require("agentic.utils.file_system").write_atomic(_G.sibling, "x")
            ]])
            vim.uv.sleep(500)

            assert.equal(0, child.lua_get("_G.changes"))
        end)
    end)

    describe("mkdirp", function()
        it("creates nested directories", function()
            local base = vim.fn.tempname()
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

    describe("canonical_path", function()
        --- @type TestStub
        local realpath_stub
        --- Directories the fake filesystem resolves, mapped to their target.
        --- @type table<string, string>
        local links

        before_each(function()
            links = {}
            realpath_stub = spy.stub(vim.uv, "fs_realpath")
            realpath_stub:invokes(function(path)
                return links[path]
            end)
        end)

        after_each(function()
            realpath_stub:revert()
        end)

        it("resolves a symlinked directory prefix", function()
            links["/link/dir"] = "/real/dir"

            assert.equal(
                "/real/dir/file.lua",
                FileSystem.canonical_path("/link/dir/file.lua")
            )
        end)

        it("collapses both spellings of one file to one path", function()
            links["/tmp"] = "/private/tmp"
            links["/private/tmp"] = "/private/tmp"

            assert.equal(
                FileSystem.canonical_path("/private/tmp/a/b.lua"),
                FileSystem.canonical_path("/tmp/a/b.lua")
            )
        end)

        it("resolves a file that does not exist yet", function()
            -- Every created file looks like this at the moment it is recorded:
            -- realpath fails on the leaf, succeeds on its parent.
            links["/real/dir"] = "/real/dir"

            assert.equal(
                "/real/dir/brand/new.lua",
                FileSystem.canonical_path("/real/dir/brand/new.lua")
            )
        end)

        it("falls back to the normalised path when nothing resolves", function()
            assert.equal(
                "/nowhere/at/all.lua",
                FileSystem.canonical_path("/nowhere/at/all.lua")
            )
        end)

        it("returns an absolute path for a relative input", function()
            links[vim.uv.cwd()] = vim.uv.cwd()

            assert.equal(
                vim.fs.joinpath(vim.uv.cwd(), "sub/file.lua"),
                FileSystem.canonical_path("sub/file.lua")
            )
        end)
    end)
end)
