--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Recovery = require("agentic.session_recovery")

describe("agentic.session_recovery", function()
    describe("auto-continue after a usage limit", function()
        --- @type TestSpy
        local submit_spy

        --- @param queued string[]|nil
        --- @return agentic.SessionManager
        local function session_with(queued)
            submit_spy = spy.new(function() end)
            return {
                session_id = "s1",
                _destroyed = false,
                _retry_attempt = 1,
                _queued_prompts = queued,
                _handle_input_submit = submit_spy,
            } --[[@as agentic.SessionManager]]
        end

        it("sends what the user queued during the pause", function()
            local session = session_with({ "message one", "message two" })

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(1)
            assert.equal("message one\n\nmessage two", submit_spy.calls[1][2])
        end)

        it("sends 'continue' when nothing was queued", function()
            local session = session_with(nil)

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(1)
            assert.equal("continue", submit_spy.calls[1][2])
        end)

        it("clears the queue so a later fire does not resend", function()
            local session = session_with({ "message one" })

            Recovery._fire_auto_continue(session)
            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(2)
            assert.equal("continue", submit_spy.calls[2][2])
        end)

        it("sends nothing for a destroyed session", function()
            local session = session_with({ "message one" })
            session._destroyed = true

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(0)
        end)
    end)
end)
