-- Generates the plan index in TODO.md from the headers of `notes/*.md`.
-- Usage, from the repo root: `nvim --clean -l scripts/plan_index.lua [--check]`.
-- Without `--check` it rewrites TODO.md; with it, it exits 1 when TODO.md is
-- out of date.

local M = {}

local BEGIN = "<!-- BEGIN plan-index -->"
local END = "<!-- END plan-index -->"

--- Missing `Priority:`, sorted after P3.
local NO_PRIORITY = 4

--- Heading and filename prefixes of each group of single notes. A group with
--- `by_priority` sorts by priority before filename.
local SINGLE_GROUPS = {
    { heading = "Bugs", kinds = { "BUG", "FIX" }, by_priority = true },
    {
        heading = "Plans",
        kinds = { "FEAT", "REFACTOR", "PERF", "TRACK" },
        by_priority = true,
    },
    { heading = "Ideas and audits", kinds = { "IDEA", "AUDIT" } },
}

--- Lowercased H1 labels left out of a title, as `Plan` in `# Plan: title`.
local TITLE_LABELS =
    { plan = true, bug = true, idea = true, feature = true, audit = true }

--- @class agentic.PlanIndex.Note
--- @field name string filename
--- @field kind string filename prefix, e.g. `FEAT`
--- @field title string
--- @field status? string
--- @field priority integer 1 to 3, or 4 when missing
--- @field depends string[] filenames

--- Parses the header of one note: the lines before its first `## ` heading.
--- @param name string filename
--- @param lines string[] note text
--- @return agentic.PlanIndex.Note|nil note
--- @return string|nil err
function M.parse(name, lines)
    local kind = name:match("^(%u+)%-")
    local known = false
    for _, group in ipairs(SINGLE_GROUPS) do
        known = known or vim.list_contains(group.kinds, kind)
    end
    if not known then
        return nil, "unknown prefix"
    end

    --- @type agentic.PlanIndex.Note
    local note = {
        name = name,
        kind = kind,
        title = "",
        priority = NO_PRIORITY,
        depends = {},
    }
    for _, line in ipairs(lines) do
        if vim.startswith(line, "## ") then
            break
        end
        local h1 = line:match("^# (.*)")
        local status = line:match("^Status:(.*)")
        local priority = line:match("^Priority:(.*)")
        local depends = line:match("^Depends:(.*)")
        if h1 and note.title == "" then
            local label, rest = h1:match("^(%a+):%s+(.*)")
            note.title =
                vim.trim(TITLE_LABELS[label and label:lower()] and rest or h1)
        elseif status then
            status = vim.trim(status)
            note.status = status ~= "" and status or nil
        elseif priority then
            local level = vim.trim(priority):match("^P([123])$")
            if not level then
                return nil, "bad Priority: " .. vim.trim(priority)
            end
            note.priority = tonumber(level) --[[@as integer]]
        elseif depends then
            note.depends = vim.list.unique(
                vim.split(vim.trim(depends), "%s*,%s*", { trimempty = true })
            )
        end
    end
    if note.title == "" then
        return nil, "no H1 title"
    end
    return note
end

--- @param a agentic.PlanIndex.Note
--- @param b agentic.PlanIndex.Note
--- @return boolean
local function by_priority(a, b)
    if a.priority ~= b.priority then
        return a.priority < b.priority
    end
    return a.name < b.name
end

--- Splits notes into the weakly connected components of their `Depends:`
--- graph, each topologically sorted (dependencies first, ties by priority
--- then filename). Dependencies on names not in `notes` are ignored.
--- @param notes agentic.PlanIndex.Note[]
--- @return agentic.PlanIndex.Note[][]|nil components ordered by their smallest filename
--- @return string|nil err names the notes on a cycle and their dependants
function M.components(notes)
    --- @type table<string, agentic.PlanIndex.Note>
    local by_name = {}
    for _, note in ipairs(notes) do
        by_name[note.name] = note
    end

    --- @type table<string, string[]>
    local deps = {}
    --- @type table<string, string[]>
    local dependants = {}
    for _, note in ipairs(notes) do
        deps[note.name] = vim.tbl_filter(function(dep)
            return by_name[dep] ~= nil
        end, note.depends)
        dependants[note.name] = dependants[note.name] or {}
        for _, dep in ipairs(deps[note.name]) do
            dependants[dep] = dependants[dep] or {}
            table.insert(dependants[dep], note.name)
        end
    end

    -- Kahn's algorithm over all notes at once, always taking the best ready
    -- note. A component's notes are only made ready by each other, so their
    -- order here is the order Kahn's algorithm gives the component alone.
    --- @type table<string, integer>
    local n_waiting = {}
    local ready = {}
    for _, note in ipairs(notes) do
        n_waiting[note.name] = #deps[note.name]
        if n_waiting[note.name] == 0 then
            table.insert(ready, note)
        end
    end
    --- @type agentic.PlanIndex.Note[]
    local sorted = {}
    while #ready > 0 do
        table.sort(ready, by_priority)
        local note = table.remove(ready, 1)
        table.insert(sorted, note)
        for _, dependant in ipairs(dependants[note.name]) do
            n_waiting[dependant] = n_waiting[dependant] - 1
            if n_waiting[dependant] == 0 then
                table.insert(ready, by_name[dependant])
            end
        end
    end
    if #sorted < #notes then
        local unsorted = vim.tbl_filter(function(name)
            return n_waiting[name] > 0
        end, vim.tbl_keys(n_waiting))
        table.sort(unsorted)
        return nil,
            "cycle in Depends, among these notes and their dependants: "
                .. table.concat(unsorted, ", ")
    end

    -- Each note's component is named by its smallest filename.
    local names = vim.tbl_keys(by_name)
    table.sort(names)
    --- @type table<string, string>
    local root = {}
    for _, name in ipairs(names) do
        local stack = { name }
        while #stack > 0 do
            local member = table.remove(stack)
            if not root[member] then
                root[member] = name
                vim.list_extend(stack, deps[member])
                vim.list_extend(stack, dependants[member])
            end
        end
    end

    --- @type agentic.PlanIndex.Note[][]
    local components = {}
    --- @type table<string, agentic.PlanIndex.Note[]>
    local by_root = {}
    for _, name in ipairs(names) do
        if root[name] == name then
            by_root[name] = {}
            table.insert(components, by_root[name])
        end
    end
    for _, note in ipairs(sorted) do
        table.insert(by_root[root[note.name]], note)
    end
    return components
end

--- Formats one note as `P2 [FILE](notes/FILE): title — status`, without the
--- priority or status when the note has none.
--- @param note agentic.PlanIndex.Note
--- @return string item
local function format_item(note)
    local priority = note.priority == NO_PRIORITY and ""
        or ("P%d "):format(note.priority)
    local status = note.status and " — " .. note.status or ""
    return ("%s[%s](notes/%s): %s%s"):format(
        priority,
        note.name,
        note.name,
        note.title,
        status
    )
end

--- Formats a track: a bold label, the titles of the notes nothing in the
--- track depends on, over a numbered list whose items name the items they
--- come after.
--- @param track agentic.PlanIndex.Note[] topologically sorted
--- @return string[] lines
local function format_track(track)
    --- @type table<string, integer>
    local position = {}
    --- @type table<string, boolean>
    local depended_on = {}
    for i, note in ipairs(track) do
        position[note.name] = i
        for _, dep in ipairs(note.depends) do
            depended_on[dep] = true
        end
    end

    local sinks = vim.tbl_filter(function(note)
        return not depended_on[note.name]
    end, track)
    local titles = vim.tbl_map(function(note)
        return note.title
    end, sinks)
    local lines = { ("**%s**"):format(table.concat(titles, "; ")) }

    for i, note in ipairs(track) do
        local after = {}
        for _, dep in ipairs(note.depends) do
            if position[dep] then
                table.insert(after, position[dep])
            end
        end
        table.sort(after)
        local suffix = #after > 0
                and (" (after %s)"):format(table.concat(after, ", "))
            or ""
        table.insert(lines, ("%d. %s%s"):format(i, format_item(note), suffix))
    end
    return lines
end

--- Renders the plan index: tracks (components of two or more notes), then
--- the single notes grouped by kind.
--- @param components agentic.PlanIndex.Note[][] each topologically sorted
--- @return string[] lines with a blank line at both ends
function M.render(components)
    --- @type { label: string, best: integer, lines: string[] }[]
    local tracks = {}
    --- @type agentic.PlanIndex.Note[]
    local singles = {}
    for _, component in ipairs(components) do
        if #component == 1 then
            table.insert(singles, component[1])
        else
            local lines = format_track(component)
            local best = NO_PRIORITY
            for _, note in ipairs(component) do
                best = math.min(best, note.priority)
            end
            table.insert(
                tracks,
                { label = lines[1], best = best, lines = lines }
            )
        end
    end
    table.sort(tracks, function(a, b)
        if a.best ~= b.best then
            return a.best < b.best
        end
        return a.label < b.label
    end)

    --- @type { heading: string, lines: string[] }[]
    local groups = { { heading = "Tracks", lines = {} } }
    for i, track in ipairs(tracks) do
        if i > 1 then
            table.insert(groups[1].lines, "")
        end
        vim.list_extend(groups[1].lines, track.lines)
    end
    for _, group in ipairs(SINGLE_GROUPS) do
        local members = vim.tbl_filter(function(note)
            return vim.list_contains(group.kinds, note.kind)
        end, singles)
        table.sort(members, group.by_priority and by_priority or function(a, b)
            return a.name < b.name
        end)
        table.insert(groups, {
            heading = group.heading,
            lines = vim.tbl_map(function(note)
                return "- " .. format_item(note)
            end, members),
        })
    end

    local lines = {}
    for _, group in ipairs(groups) do
        if #group.lines > 0 then
            vim.list_extend(lines, { "", "### " .. group.heading, "" })
            vim.list_extend(lines, group.lines)
        end
    end
    table.insert(lines, "")
    return lines
end

--- Replaces the lines between the plan-index markers.
--- @param todo_lines string[]
--- @param region string[] new lines between the markers
--- @return string[]|nil lines
--- @return string|nil err
function M.splice(todo_lines, region)
    local i_begin = vim.fn.index(todo_lines, BEGIN) + 1
    local i_end = vim.fn.index(todo_lines, END) + 1
    if i_begin == 0 or i_end == 0 then
        return nil, ("needs the lines %s and %s"):format(BEGIN, END)
    end
    if i_end < i_begin then
        return nil, END .. " comes before " .. BEGIN
    end
    local lines = vim.list_slice(todo_lines, 1, i_begin)
    vim.list_extend(lines, region)
    return vim.list_extend(lines, todo_lines, i_end)
end

--- Regenerates TODO.md in the current directory, or with `check` only
--- compares it.
--- @param check boolean
--- @return string|nil err
local function main(check)
    --- @type agentic.PlanIndex.Note[]
    local notes = {}
    for name, type in vim.fs.dir("notes") do
        if type == "file" and vim.endswith(name, ".md") then
            local path = "notes/" .. name
            local note, err = M.parse(name, vim.fn.readfile(path))
            if not note then
                return path .. ": " .. err
            end
            table.insert(notes, note)
        end
    end

    local components, err = M.components(notes)
    if not components then
        return err
    end
    local todo = vim.fn.readfile("TODO.md")
    local lines, splice_err = M.splice(todo, M.render(components))
    if not lines then
        return "TODO.md: " .. splice_err
    end

    if not check then
        vim.fn.writefile(lines, "TODO.md")
    elseif not vim.deep_equal(todo, lines) then
        return "TODO.md: plan index is out of date; run `make plan-index`"
    end
end

if arg and arg[0] and arg[0]:match("plan_index%.lua$") then
    local err = main(arg[1] == "--check")
    if err then
        io.stderr:write(err .. "\n")
        os.exit(1)
    end
end

return M
