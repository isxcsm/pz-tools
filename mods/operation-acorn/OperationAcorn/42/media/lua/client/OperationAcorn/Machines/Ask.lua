-- When a machine whose bin or window is on show is asked to work now (not at its next ten-minute step): the one rule the
-- loot window's watch (Watch.lua) and the machine window (Window.lua) share. The work done is the time since the machine
-- last worked either way, so asking more or less often moves no output, only how soon the bars fill.
require "OperationAcorn/Core"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Ask = {}
OA.Machines.Ask = Ask

Ask.ASK_MS = 400        -- the least time between two asks to work (the answer comes on the next tick)
Ask.IDLE_ASK_MS = 3000  -- an idle machine is asked again this seldom while nothing changes in it

-- Whether to ask now. `last` is the caller's table of the real time (ms) each key was last due (OA.due). `due`: a job
-- is due; `idle`: the machine is on with something in it and no job (it is asked now and then, for no power, a full
-- output ...), and at once when `changed` (what is in it changed).
function Ask.wanted(last, now, due, idle, changed)
    if not due and idle then due = OA.due(last, "idle", now, Ask.IDLE_ASK_MS) or changed == true end
    return due and OA.due(last, "ask", now, Ask.ASK_MS) or false
end

return Ask
