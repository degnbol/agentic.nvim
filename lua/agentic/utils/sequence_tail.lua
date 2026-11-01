--- Where one keyed sequence continues past another that holds its start.
--- @class agentic.utils.SequenceTail
local M = {}

--- One row of a keyed sequence.
--- @class agentic.utils.SequenceTail.Entry
--- @field key? string Rows with equal keys are the same row; nil for a row that never matches
--- @field starts boolean Whether a tail may start at this row

--- Indices of the keyed entries, and their keys as one integer id per line.
--- @param entries agentic.utils.SequenceTail.Entry[]
--- @param ids { by_key: table<string, integer>, n: integer } Key to id, extended with new keys; `n` counts the ids
--- @return integer[] indices
--- @return string lines
local function keyed_lines(entries, ids)
    local indices, lines = {}, {}
    for i, entry in ipairs(entries) do
        if entry.key then
            if not ids.by_key[entry.key] then
                ids.n = ids.n + 1
                ids.by_key[entry.key] = ids.n
            end
            indices[#indices + 1] = i
            lines[#lines + 1] = ids.by_key[entry.key] .. "\n"
        end
    end
    return indices, table.concat(lines)
end

--- The last pair of lines the longest common subsequence of `a` and `b`
--- matches.
--- @param a string Newline-terminated lines
--- @param b string Newline-terminated lines
--- @param n_a integer Line count of `a`
--- @param n_b integer Line count of `b`
--- @return integer|nil line_a 1-based, nil when nothing matches
--- @return integer|nil line_b
local function last_match(a, b, n_a, n_b)
    -- `minimal`: the default may return a longer edit script.
    local hunks =
        vim.text.diff(a, b, { result_type = "indices", algorithm = "minimal" }) --[[@as integer[][] ]]
    -- Lines after the last hunk match pairwise up to both ends.
    local after_a, after_b = 1, 1
    local last_a, last_b
    for _, hunk in ipairs(hunks) do
        local start_a, count_a, start_b, count_b = unpack(hunk)
        -- An empty side's start is the line before the hunk.
        local first_a = count_a == 0 and start_a + 1 or start_a
        local first_b = count_b == 0 and start_b + 1 or start_b
        if first_a > after_a then
            last_a, last_b = first_a - 1, first_b - 1
        end
        after_a, after_b = first_a + count_a, first_b + count_b
    end
    if after_a <= n_a and after_b <= n_b then
        return n_a, n_b
    end
    return last_a, last_b
end

--- Index of the first entry of `replay` that `file` does not hold.
---
--- An entry of `replay` is new when its key has occurred more often in
--- `replay` up to it than in all of `file`. The two keyed sequences are matched
--- by their longest common subsequence, and the tail starts at the first new
--- entry after the last match that starts a tail; when `file` ends at that
--- match, an unkeyed entry after it starts one too.
--- With no match, a `replay` whose first keyed entry does not start one has its
--- tail at the first entry after it that does.
--- @param file agentic.utils.SequenceTail.Entry[]
--- @param replay agentic.utils.SequenceTail.Entry[]
--- @return integer|nil start `#replay + 1` when there is no tail; nil when both sides have keys and none match
function M.tail_start(file, replay)
    local ids = { by_key = {}, n = 0 }
    local file_indices, file_lines = keyed_lines(file, ids)
    local replay_indices, replay_lines = keyed_lines(replay, ids)

    local line_file, line_replay =
        last_match(file_lines, replay_lines, #file_indices, #replay_indices)
    local after_file = line_file and file_indices[line_file] or 0
    local after_replay = line_replay and replay_indices[line_replay] or 0

    local file_counts = {}
    for _, entry in ipairs(file) do
        if entry.key then
            file_counts[entry.key] = (file_counts[entry.key] or 0) + 1
        end
    end
    local replay_counts = {}
    --- @param entry agentic.utils.SequenceTail.Entry
    local function is_new(entry)
        replay_counts[entry.key] = (replay_counts[entry.key] or 0) + 1
        return replay_counts[entry.key] > (file_counts[entry.key] or 0)
    end

    if not line_file and #file_indices > 0 and #replay_indices > 0 then
        local first = replay_indices[1]
        if replay[first].starts then
            return nil
        end
        after_replay = first
    end

    local cut_off = after_file == #file
    for i, entry in ipairs(replay) do
        local new = entry.key ~= nil and is_new(entry)
        if
            i > after_replay
            and (new and entry.starts or cut_off and not entry.key)
        then
            return i
        end
    end
    return #replay + 1
end

return M
