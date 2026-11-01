--- @class agentic.EnvironmentInfo
local M = {}

--- The `<environment_info>` block: platform, shell, editor, date, project
--- root, and for a directory in a git repository its branch, changed files
--- and recent commits. The project root is the git root of `cwd`, else `cwd`.
--- @param cwd string Directory the agent works in
--- @param shell string|nil Shell the agent runs commands in; nil omits the Shell line
--- @return string block
function M.build(cwd, shell)
    local uname = vim.uv.os_uname()
    local neovim_version = tostring(vim.version())
    local today = os.date("%Y-%m-%d")

    local res = string.format(
        "- Platform: %s-%s-%s",
        uname.sysname,
        uname.release,
        uname.machine
    )
    if shell then
        res = res .. "\n- Shell: " .. shell
    end
    res = res
        .. string.format(
            "\n- Editor: Neovim %s\n- Current date: %s",
            neovim_version,
            today
        )

    local git_root = vim.fs.root(cwd, ".git")
    if git_root then
        res = res .. "\n- This is a Git repository."
    end

    if git_root and vim.fn.executable("git") == 1 then
        -- Started together so the wait is the slowest command, not the sum.
        local branch_job = vim.system(
            { "git", "rev-parse", "--abbrev-ref", "HEAD" },
            { text = true, cwd = git_root }
        )
        local changed_job = vim.system(
            { "git", "status", "--porcelain" },
            { text = true, cwd = git_root }
        )
        local commits_job = vim.system({
            "git",
            "log",
            "-3",
            "--oneline",
            "--format=%h (%ar) %an: %s",
        }, { text = true, cwd = git_root })

        local branch = branch_job:wait()
        if branch.code == 0 and vim.trim(branch.stdout) ~= "" then
            res = res
                .. string.format(
                    "\n- Current branch: %s",
                    vim.trim(branch.stdout)
                )
        end

        local changed = changed_job:wait()
        local files =
            vim.split(changed.stdout or "", "\n", { trimempty = true })
        if changed.code == 0 and #files > 0 then
            res = res .. "\n- Changed files:"
            for _, file in ipairs(files) do
                res = res .. "\n  - " .. file
            end
        end

        local commits = commits_job:wait()
        local commit_lines =
            vim.split(commits.stdout or "", "\n", { trimempty = true })
        if commits.code == 0 and #commit_lines > 0 then
            res = res .. "\n- Recent commits:"
            for _, commit in ipairs(commit_lines) do
                res = res .. "\n  - " .. commit
            end
        end
    end

    res = res .. string.format("\n- Project root: %s", git_root or cwd)

    return "<environment_info>\n" .. res .. "\n</environment_info>"
end

return M
