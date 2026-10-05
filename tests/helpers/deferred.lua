-- Run `vim.schedule` callbacks on demand instead of through the event loop.
--
-- mini.test queues every case on the event loop up front, so a `vim.wait` in
-- one case can run the cases after it, and the reporter's final quit, inside
-- it.
--
-- A drain runs no other event-loop work between callbacks (redraw,
-- WinScrolled, timers); a test that needs one triggers it itself.

local spy = require("tests.helpers.spy")

--- @class tests.helpers.Deferred
--- @field drain fun() Run the captured callbacks in order, and the ones they schedule, until none is left. Errors after MAX_ROUNDS rounds.
--- @field revert fun() Restore `vim.schedule`

local M = {}

--- Bound on drain rounds, so a callback that always reschedules itself fails
--- the test instead of hanging it.
local MAX_ROUNDS = 1000

--- Replace `vim.schedule` with a stub that queues its callbacks.
--- @return tests.helpers.Deferred deferred
function M.capture()
    local queue = {}
    local stub = spy.stub(vim, "schedule")
    stub:invokes(function(fn)
        table.insert(queue, fn)
    end)

    --- @type tests.helpers.Deferred
    local deferred = {
        drain = function()
            for _ = 1, MAX_ROUNDS do
                if #queue == 0 then
                    return
                end
                local batch = queue
                queue = {}
                for _, fn in ipairs(batch) do
                    fn()
                end
            end
            error(
                "scheduled callbacks still queued after "
                    .. MAX_ROUNDS
                    .. " rounds"
            )
        end,
        revert = function()
            stub:revert()
        end,
    }
    return deferred
end

return M
