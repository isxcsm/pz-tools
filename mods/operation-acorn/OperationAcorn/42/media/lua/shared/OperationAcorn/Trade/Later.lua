-- Things that happen a few real seconds from now (a crate's parachute turning into a landed crate, the helicopter's
-- passes). One OnTick handler, added the first time and kept (one taken off inside its event makes the game skip the
-- next one that tick): on an idle tick it returns at once.
-- The queue is in memory; what must survive a save is kept in the record by the caller.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Later = {}
OA.Trade = OA.Trade or {}
OA.Trade.Later = Later

local queue = {}
local hooked = false

local function tick()
    if queue[1] == nil then return end
    local now = getTimestampMs()
    local due
    for i = #queue, 1, -1 do
        if now >= queue[i].at then
            due = due or {}
            table.insert(due, 1, table.remove(queue, i))
        end
    end
    if not due then return end
    for _, task in ipairs(due) do
        local ok, err = pcall(task.fn)
        if not ok then OA.log("later task failed:", tostring(err)) end
    end
end

-- Runs fn after `seconds` of real time.
function Later.after(seconds, fn)
    queue[#queue + 1] = { at = getTimestampMs() + seconds * 1000, fn = fn }
    if not hooked then
        hooked = true
        Events.OnTick.Add(tick)
    end
end

function Later.pending()
    return #queue
end

return Later
