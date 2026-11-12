--- Unified diff text, as `diff -u` and `git diff` write it.
--- @class agentic.utils.UnifiedDiff
local M = {}

--- One hunk of a unified diff.
--- @class agentic.utils.UnifiedDiff.Hunk
--- @field old_lines string[] Context and removed lines, without their prefix
--- @field new_lines string[] Context and added lines, without their prefix

--- The hunks of a unified diff, in order. A hunk's line counts decide where
--- it ends, so a removed line that starts with `--` is not read as a header.
--- @param text string
--- @return agentic.utils.UnifiedDiff.Hunk[] hunks
function M.hunks(text)
    local hunks = {} --- @type agentic.utils.UnifiedDiff.Hunk[]
    local hunk --- @type agentic.utils.UnifiedDiff.Hunk|nil
    local old_left, new_left = 0, 0
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        local prefix, rest = line:sub(1, 1), line:sub(2)
        -- An empty line is a context line whose space was trimmed.
        local is_body = prefix == " "
            or prefix == ""
            or prefix == "-"
            or prefix == "+"
        if hunk and (old_left > 0 or new_left > 0) and is_body then
            if prefix ~= "+" then
                table.insert(hunk.old_lines, rest)
                old_left = old_left - 1
            end
            if prefix ~= "-" then
                table.insert(hunk.new_lines, rest)
                new_left = new_left - 1
            end
        elseif prefix ~= "\\" then
            local old_count, new_count =
                line:match("^@@ %-%d+,?(%d*) %+%d+,?(%d*) @@")
            if old_count then
                hunk = { old_lines = {}, new_lines = {} }
                table.insert(hunks, hunk)
                -- A range without a count spans one line.
                old_left = tonumber(old_count) or 1
                new_left = tonumber(new_count) or 1
            end
        end
    end
    return hunks
end

return M
