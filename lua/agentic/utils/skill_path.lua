local FileSystem = require("agentic.utils.file_system")

--- Locate the `SKILL.md` a loaded skill came from, by probing the directory
--- layouts skills are installed under. Provider-neutral and stateless: a caller
--- that already knows the path (claude-agent-acp reports one on
--- `_meta.claudeCode.skillPath`) should prefer it and use this as the fallback.
--- @class agentic.utils.SkillPath
local SkillPath = {}

--- Skill container directories, relative to a root. Probed in this order.
local CONTAINERS = { ".claude/skills", ".agents/skills" }

--- Directories a skill may be installed under, in the order a skill name
--- resolves against them: `cwd`, then each ancestor of `cwd` nearest first,
--- then `extra_dirs` in the order given, then `$HOME`. Nearest-first matches
--- Claude Code's project-over-user precedence, so where the same name exists at
--- several levels the one nearest `cwd` wins.
---
--- Deduplicated on canonical path, since one directory is commonly reachable
--- under several spellings (a symlinked config directory, a repository reached
--- both directly and through a symlink). Each survivor keeps the spelling it
--- was given, which is the one worth displaying.
--- @param cwd string
--- @param extra_dirs string[] Roots to consider after the ancestor chain
--- @return string[] roots
function SkillPath.roots(cwd, extra_dirs)
    local candidates = { cwd }
    for dir in vim.fs.parents(cwd) do
        table.insert(candidates, dir)
    end
    vim.list_extend(candidates, extra_dirs)
    table.insert(candidates, vim.uv.os_homedir())

    --- @type string[]
    local roots = {}
    local seen = {}
    for _, dir in ipairs(candidates) do
        local key = FileSystem.canonical_path(dir)
        if not seen[key] then
            seen[key] = true
            table.insert(roots, dir)
        end
    end

    return roots
end

--- First existing `SKILL.md` for `skill_name` across `roots`. A
--- `<prefix>:<name>` name is directory-scoped: `<prefix>` is a directory
--- relative to the root, holding the container the skill sits in.
--- @param skill_name string
--- @param roots string[]
--- @return string|nil path Absolute, verified to exist at call time
function SkillPath.find(skill_name, roots)
    local prefix, name = skill_name:match("^(.-):(.*)$")
    name = name or skill_name
    -- "" is truthy in Lua, so an empty name would otherwise probe every root
    -- for `<container>//SKILL.md`.
    if name == "" then
        return nil
    end

    for _, root in ipairs(roots) do
        local base = (prefix and prefix ~= "") and vim.fs.joinpath(root, prefix)
            or root
        for _, container in ipairs(CONTAINERS) do
            local candidate = vim.fs.joinpath(base, container, name, "SKILL.md")
            if FileSystem.is_file(candidate) then
                return candidate
            end
        end
    end

    return nil
end

return SkillPath
