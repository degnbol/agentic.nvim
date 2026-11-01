local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local EnvironmentInfo = require("agentic.environment_info")
local GitEnv = require("tests.helpers.git_env")
local MiniTest = require("mini.test")

--- @return string dir A new empty directory, symlinks resolved
local function make_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return vim.uv.fs_realpath(dir) --[[@as string]]
end

local function skip_without_git()
    if vim.fn.executable("git") ~= 1 then
        MiniTest.skip("git is not on $PATH")
    end
end

describe("agentic.EnvironmentInfo", function()
    describe("build", function()
        --- @type string
        local repo
        --- @type string
        local outside
        --- @type string
        local process_cwd
        --- @type fun()
        local restore_git_env

        before_each(function()
            restore_git_env = GitEnv.scrub()
            process_cwd = vim.uv.cwd() --[[@as string]]
            outside = make_dir()
            repo = make_dir()
        end)

        after_each(function()
            vim.uv.chdir(process_cwd)
            vim.fs.rm(repo, { recursive = true, force = true })
            vim.fs.rm(outside, { recursive = true, force = true })
            restore_git_env()
        end)

        --- Make `repo` a git repository on branch `trunk` with one commit.
        local function init_repo()
            for _, cmd in ipairs({
                { "git", "init", "-b", "trunk" },
                {
                    "git",
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "--allow-empty",
                    "-m",
                    "x",
                },
            }) do
                local result = vim.system(cmd, { cwd = repo, text = true })
                    :wait()
                assert.equal(0, result.code)
            end
        end

        it("takes the git root of cwd, not of the process cwd", function()
            skip_without_git()
            init_repo()
            vim.fn.mkdir(repo .. "/sub", "p")
            vim.uv.chdir(outside)

            local block = EnvironmentInfo.build(repo .. "/sub", nil)

            assert.truthy(block:find("\n- This is a Git repository.", 1, true))
            assert.truthy(block:find("\n- Current branch: trunk", 1, true))
            assert.truthy(block:find("\n- Recent commits:", 1, true))
            assert.truthy(
                block:find("\n- Project root: " .. repo .. "\n", 1, true)
            )
        end)

        it("takes cwd as the project root outside a repository", function()
            local block = EnvironmentInfo.build(outside, nil)

            assert.truthy(
                block:find("\n- Project root: " .. outside .. "\n", 1, true)
            )
            assert.is_nil(block:find("Git repository", 1, true))
            assert.is_nil(block:find("Current branch", 1, true))
        end)

        it("without git, still takes the git root as project root", function()
            skip_without_git()
            init_repo()
            local executable_stub = spy.stub(vim.fn, "executable")
            executable_stub:invokes(function(name)
                return name == "git" and 0 or 1
            end)

            local block = EnvironmentInfo.build(repo, nil)
            executable_stub:revert()

            assert.truthy(block:find("\n- This is a Git repository.", 1, true))
            assert.truthy(
                block:find("\n- Project root: " .. repo .. "\n", 1, true)
            )
            assert.is_nil(block:find("Current branch", 1, true))
            assert.is_nil(block:find("Changed files", 1, true))
            assert.is_nil(block:find("Recent commits", 1, true))
        end)

        it("names the agent's shell", function()
            local block = EnvironmentInfo.build(outside, "zsh")
            assert.truthy(block:find("\n- Shell: zsh\n", 1, true))
        end)

        it("leaves out the Shell line for an unknown shell", function()
            local block = EnvironmentInfo.build(outside, nil)
            assert.is_nil(block:find("Shell:", 1, true))
        end)
    end)
end)
