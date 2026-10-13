-- Overload, on the server: a box whose power network draws more than its limit (Panels.limit) drains its breaker's
-- gauge, faster the more it is over, and trips it as the gauge empties; under the limit, and while tripped, the gauge
-- fills again. Server.lua checks each box every minute, over the hours since the last, and as its network changes (no
-- time: only what is over at once).
require "BuildingUtilities/Changes"
local BU = BuildingUtilities
local Panels, Networks, Changes = BU.Panels, BU.Networks, BU.Changes
local Overload = {}
BU.Overload = Overload

function Overload.check(panel, hours)
    hours = hours or 0
    local gauge = Panels.breaker(panel)
    if not BU.overloadEnabled() then
        if gauge < 1 then Changes.setBreaker(panel, 1) end
        return
    end
    local cooled = gauge + hours / Panels.BREAKER_FILL_HOURS
    local state = Networks.state(panel, "power")
    if panel.tripped or not (state and state.supplied and state.load) then
        if gauge < 1 then Changes.setBreaker(panel, cooled) end
        return
    end
    local load = math.max(0, state.load)
    local limit = Panels.limit(panel)
    if load <= limit + 1e-6 then
        if gauge < 1 then Changes.setBreaker(panel, cooled) end
        return
    end
    local ratio = limit > 0 and load / limit or math.huge
    if ratio >= Panels.BREAKER_INSTANT then
        gauge = 0
    else
        gauge = gauge - Panels.breakerDrain(ratio) * hours
    end
    Changes.setBreaker(panel, gauge)
    if gauge <= 0 then Changes.trip(panel) end
end

return Overload
