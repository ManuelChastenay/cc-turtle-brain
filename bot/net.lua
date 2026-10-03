--[[ <Claude>
  Rednet protocol between the fleet brain (fleet.lua, on a computer) and
  turtles running worker.lua. Messages are tables with a `type`:
    brain -> turtle  hello                     reply: status
                     plan { job, steps }       reply: accepted, then progress..., result
                                               (or at once: result with ok = false if busy/invalid)
                     ack { job }               the brain has the result: the turtle forgets it
                     stop                      the running plan stops where it is, reply: result
    turtle -> brain  status { label, state, pos, job, result }   job = id of the running plan;
                                               result = last result message, until acknowledged
                     progress { job, step, text }
                     result { job, ok, summary | error, failed, completed, state, pos }
  A rebooted worker resumes its job (same id), so a turtle that went silent
  can come back; the brain waits for it (bot/fleet.lua).
    turtle -> turtle makeway { from }          sent to a turtle blocking the way; if idle,
                                               it steps off the line (busy ones ignore it)
  Steps travel as plain data ({ skill = name, ...args }) and are checked
  again on the turtle. Any computer can send rednet messages: fine on a
  single-player server, not a security boundary.
]]
local M = { PROTOCOL = "ccbrain" }

-- <Claude> Opens rednet on every attached modem. Returns false if there is none.
function M.open()
  local any = false
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.hasType(side, "modem") then
      rednet.open(side)
      any = true
    end
  end
  return any
end

function M.send(id, msg)
  rednet.send(id, msg, M.PROTOCOL)
end

return M
