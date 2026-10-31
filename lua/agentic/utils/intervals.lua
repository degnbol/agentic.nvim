--- Closed intervals on the number line.
--- @class agentic.utils.Intervals
local Intervals = {}

--- @class agentic.Interval
--- @field [1] number Start
--- @field [2] number End, at or after start

--- The union of intervals.
--- @param intervals agentic.Interval[]
--- @return agentic.Interval[] union Disjoint and ascending; overlapping or touching intervals joined
function Intervals.union(intervals)
    local sorted = vim.deepcopy(intervals)
    table.sort(sorted, function(a, b)
        return a[1] < b[1]
    end)
    --- @type agentic.Interval[]
    local union = {}
    for _, interval in ipairs(sorted) do
        local last = union[#union]
        if last and interval[1] <= last[2] then
            last[2] = math.max(last[2], interval[2])
        else
            table.insert(union, interval)
        end
    end
    return union
end

--- Length of the union of intervals inside `[from, to]`.
--- @param intervals agentic.Interval[]
--- @param from number
--- @param to number
--- @return number
function Intervals.covered(intervals, from, to)
    local length = 0
    for _, interval in ipairs(Intervals.union(intervals)) do
        length = length
            + math.max(
                0,
                math.min(interval[2], to) - math.max(interval[1], from)
            )
    end
    return length
end

return Intervals
