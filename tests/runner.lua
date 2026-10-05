-- Test runner with error handling to prevent hanging
local M = {}

local function exit_with_error(msg)
    io.stderr:write("Error: " .. tostring(msg) .. "\n")
    vim.cmd("cquit 1")
end

local function exit_success()
    vim.cmd("qall!")
end

--- @param fn function
local function run_with_exit(fn)
    local ok, err = pcall(fn)
    if ok then
        exit_success()
    else
        exit_with_error(err)
    end
end

--- Stdout reporter that quits Neovim on finish, with exit code 1 when a case
--- failed or did not finish.
---
--- mini.test schedules every case, and the reporter's `finish`, up front. A
--- case's `vim.wait` pumps that queue, so the cases after it, and `finish`,
--- can run inside it. A stalled case would then exit with no mark and no
--- failure.
--- @return table reporter
local function strict_stdout_reporter()
    local MiniTest = require("mini.test")
    local stdout = MiniTest.gen_reporter.stdout({ quit_on_finish = false })
    local reporter = { start = stdout.start, update = stdout.update }
    reporter.finish = function()
        stdout.finish()
        local failed = false
        for _, case in ipairs(MiniTest.current.all_cases) do
            local state = case.exec and case.exec.state or ""
            if not state:match("^Pass") then
                failed = true
                if not state:match("^Fail") then
                    io.stderr:write(
                        "Unfinished case: "
                            .. table.concat(case.desc, " | ")
                            .. "\n"
                    )
                end
            end
        end
        vim.cmd(string.format("silent! %dcquit", failed and 1 or 0))
    end
    return reporter
end

--- Run a specific test file
--- @param file string
function M.run_file(file)
    if not file or file == "" then
        exit_with_error("No file specified")
    end

    if not vim.uv.fs_stat(file) then
        exit_with_error("File not found: " .. file)
    end

    run_with_exit(function()
        local MiniTest = require("mini.test")
        MiniTest.run_file(file, {
            execute = { reporter = strict_stdout_reporter() },
        })
    end)
end

return M
