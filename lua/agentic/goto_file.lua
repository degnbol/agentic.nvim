local SessionRegistry = require("agentic.session_registry")
local SkillPath = require("agentic.utils.skill_path")

--- Resolves file names that gf cannot find in an Agentic buffer.
--- @class agentic.GotoFile
local GotoFile = {}

--- 'includeexpr' value that calls `resolve`.
GotoFile.EXPR = "v:lua.require'agentic.goto_file'.resolve(v:fname)"

--- SKILL.md of skill `name` for a `/name`, searched in the roots of the
--- session that owns the current buffer. Returns `fname` unchanged when it is
--- not `/name`, the buffer has no session with a started ACP session, or no
--- such skill exists, so gf reports its own E447.
--- @param fname string Name under the cursor (`v:fname`)
--- @return string path
function GotoFile.resolve(fname)
    local name = fname:match("^/([%w_.-]+)$")
    if not name then
        return fname
    end
    local session =
        SessionRegistry.owner_of_buf(vim.api.nvim_get_current_buf())
    if not session or not session.session_id then
        return fname
    end
    return SkillPath.find(name, session.agent:session_roots(session.session_id))
        or fname
end

return GotoFile
