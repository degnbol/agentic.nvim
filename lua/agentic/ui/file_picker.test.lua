local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local FilePicker = require("agentic.ui.file_picker")

--- Computes the differences between two tables
--- @param left table
--- @param right table
--- @return string[] only_in_left Items only in left table
--- @return string[] only_in_right Items only in right table
local function table_diff(left, right)
    local left_set = {}
    for _, v in ipairs(left) do
        left_set[v] = true
    end

    local right_set = {}
    for _, v in ipairs(right) do
        right_set[v] = true
    end

    local only_in_left = {}
    for _, v in ipairs(left) do
        if not right_set[v] then
            table.insert(only_in_left, v)
        end
    end

    local only_in_right = {}
    for _, v in ipairs(right) do
        if not left_set[v] then
            table.insert(only_in_right, v)
        end
    end

    return only_in_left, only_in_right
end

--- Creates an empty file at `path`, making parent directories as needed.
--- @param path string
local function touch(path)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file, err = io.open(path, "w")
    if not file then
        error(err)
    end
    file:close()
end

describe("FilePicker:scan_files", function()
    --- @type TestStub|nil
    local system_stub
    local original_cmd_rg
    local original_cmd_fd
    local original_cmd_git

    --- @type agentic.ui.FilePicker
    local picker

    before_each(function()
        original_cmd_rg = FilePicker.CMD_RG[1]
        original_cmd_fd = FilePicker.CMD_FD[1]
        original_cmd_git = FilePicker.CMD_GIT[1]
        picker = FilePicker:new(vim.api.nvim_create_buf(false, true)) --[[@as agentic.ui.FilePicker]]
    end)

    after_each(function()
        if system_stub then
            system_stub:revert()
            system_stub = nil
        end
        FilePicker.CMD_RG[1] = original_cmd_rg
        FilePicker.CMD_FD[1] = original_cmd_fd
        FilePicker.CMD_GIT[1] = original_cmd_git
    end)

    describe("mocked commands", function()
        it("should stop at first successful command", function()
            -- Make all commands available by setting them to executables that exist
            FilePicker.CMD_RG[1] = "echo"
            FilePicker.CMD_FD[1] = "echo"
            FilePicker.CMD_GIT[1] = "echo"

            system_stub = spy.stub(vim.fn, "system")
            system_stub:invokes(function(_cmd)
                -- First call returns empty (simulates failure)
                -- Second call returns files (simulates success)
                if system_stub.call_count == 1 then
                    return ""
                else
                    return "file1.lua\nfile2.lua\nfile3.lua\n"
                end
            end)

            local files = picker:scan_files()

            -- Should have called system exactly 2 times (first fails, second succeeds)
            assert.equal(2, system_stub.call_count)
            assert.equal(3, #files)
        end)
    end)

    -- All three backends (rg, fd, git) must surface the same file set. Drive
    -- them against a controlled git fixture, not the live repo tree: `git
    -- ls-files` reads the index (so it lists tracked-but-deleted files) while
    -- rg/fd walk the disk, so they diverge whenever cwd holds an index/disk
    -- mismatch (a tracked-but-deleted file, a staged-add since removed, …). A
    -- fresh `git init` + `git add` over a known set makes all three agree.
    describe("real commands", function()
        local fixture
        local original_cwd

        before_each(function()
            original_cwd = vim.fn.getcwd()
            fixture = vim.fn.tempname()
            vim.fn.mkdir(fixture, "p")
            for _, path in ipairs({
                "README.md",
                "init.lua",
                "lua/agentic/file_picker.lua",
                "docs/guide.md",
            }) do
                touch(fixture .. "/" .. path)
            end
            vim.fn.chdir(fixture)
            vim.system({ "git", "init" }, { cwd = fixture }):wait()
            vim.system({ "git", "add", "-A" }, { cwd = fixture }):wait()
        end)

        after_each(function()
            vim.fn.chdir(original_cwd)
            vim.fs.rm(fixture, { recursive = true })
        end)

        it("returns the same file set for all backends", function()
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            local files_rg = picker:scan_files()

            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = original_cmd_fd
            local files_fd = picker:scan_files()

            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = original_cmd_git
            local files_git = picker:scan_files()

            assert.is_true(#files_rg > 0)
            assert.is_true(#files_fd > 0)
            assert.is_true(#files_git > 0)

            local path_of = function(f)
                return f.path
            end
            local words_rg = vim.tbl_map(path_of, files_rg)
            local words_fd = vim.tbl_map(path_of, files_fd)
            local words_git = vim.tbl_map(path_of, files_git)

            local rg_only, fd_only = table_diff(words_rg, words_fd)
            assert.are.same(rg_only, fd_only)

            local fd_only2, git_only = table_diff(words_fd, words_git)
            assert.are.same(fd_only2, git_only)

            assert.are.equal(#files_rg, #files_fd)
            assert.are.equal(#files_fd, #files_git)
        end)
    end)

    -- The glob fallback runs only when rg, fd, and git are all unavailable, so
    -- it cannot delegate gitignore filtering to any tool — it relies on the
    -- GLOB_EXCLUDE_PATTERNS denylist. Drive it against a controlled fixture
    -- directory (not the live repo tree) so the assertion depends only on the
    -- denylist, never on whatever gitignored artifacts happen to sit in cwd.
    describe("glob fallback", function()
        local fixture
        local original_cwd

        before_each(function()
            original_cwd = vim.fn.getcwd()
            fixture = vim.fn.tempname()
            vim.fn.mkdir(fixture, "p")
            -- No working scan command, so scan_files() takes the glob path.
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            vim.fn.chdir(fixture)
        end)

        after_each(function()
            vim.fn.chdir(original_cwd)
            vim.fs.rm(fixture, { recursive = true })
        end)

        it("lists project files and excludes junk directories", function()
            local keep = {
                "README.md",
                "init.lua",
                "lua/agentic/file_picker.lua",
                ".editorconfig", -- root dotfile
                ".github/workflows/ci.yml", -- file inside a non-junk dot dir
            }
            local junk = {
                ".git/config",
                ".ruff_cache/CACHEDIR.TAG",
                ".mypy_cache/0/x.json",
                ".pytest_cache/v/cache",
                "node_modules/pkg/index.js",
                "__pycache__/mod.cpython-311.pyc",
                "build/out.o",
                "dist/bundle.js",
            }
            for _, path in ipairs(keep) do
                touch(fixture .. "/" .. path)
            end
            for _, path in ipairs(junk) do
                touch(fixture .. "/" .. path)
            end

            local listed = vim.tbl_map(function(f)
                return f.path
            end, picker:scan_files())

            table.sort(listed)
            table.sort(keep)
            assert.are.same(keep, listed)
        end)
    end)
end)
