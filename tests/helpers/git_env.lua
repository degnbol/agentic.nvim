local M = {}

--- Unsets every GIT_* environment variable for the duration of a test,
--- returning a function that restores the saved values. An ambient GIT_DIR
--- makes git ignore the `cwd` and operate on whatever it points at: a fixture
--- `git init` then reinitialises that repo instead, and for a submodule (whose
--- gitdir does not end in `.git`) with no work-tree on the command line git
--- sets core.bare=true, contradicting the submodule's core.worktree and
--- corrupting the real config. Scrubbing the env makes the fixture hermetic.
--- @return fun() restore
function M.scrub()
    local saved = {}
    for name, value in pairs(vim.fn.environ()) do
        if name:match("^GIT_") then
            saved[name] = value
            vim.uv.os_unsetenv(name)
        end
    end
    return function()
        for name, value in pairs(saved) do
            vim.uv.os_setenv(name, value)
        end
    end
end

return M
