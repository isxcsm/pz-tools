-- Overload, on the server: a box whose power network draws more than its limit (Panels.limit; charging its bank
-- aside) drains its breaker's gauge, faster the more it is over, and trips it as the gauge empties; under the limit,
-- and while tripped, the gauge fills again. One that sheds turns off devices that are not essential as the gauge runs
-- low, if that is enough, and on again once it is nearly full and there is room. Server.lua checks each box every
-- minute, over the hours since the last, and as its network changes (no time: only what is over at once).
require "BuildingUtilities/Changes"
local BU = BuildingUtilities
local Panels, Networks, Changes, Energy = BU.Panels, BU.Networks, BU.Changes, BU.Energy
local Overload = {}
BU.Overload = Overload

-- Whether a set has anything in it. (Kahlua has no next.)
local function any(set)
    for _ in pairs(set) do return true end
    return false
end

-- The room last tried, by panel: restoring is tried again once it is another.
local restoreTried = {}

function Overload.check(panel, hours)
    hours = hours or 0
    local shed = panel.power.shed
    if not Panels.sheds(panel) and any(shed) then
        local keys = {}
        for key in pairs(shed) do keys[#keys + 1] = key end
        Changes.restore(panel, keys)
    end
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
    -- The load counts what the line loses; a device takes that much more of it.
    local factor = math.max(state.loadFactor or 1, 1e-6)
    local load = math.max(0, state.load - Energy.charging(panel) * factor)
    local limit = Panels.limit(panel)
    if load <= limit + 1e-6 then
        if gauge < 1 then Changes.setBreaker(panel, cooled) end
        if any(shed) and math.min(1, cooled) >= Panels.BREAKER_RESTORE_AT then
            local room = (limit - load) / factor
            local tried = restoreTried[panel.id]
            if tried == nil or math.abs(tried - room) > 1e-6 then
                restoreTried[panel.id] = room
                local keys = Panels.restorePlan(panel, room)
                if #keys > 0 then Changes.restore(panel, keys) end
            end
        end
        return
    end
    local ratio = limit > 0 and load / limit or math.huge
    if ratio >= Panels.BREAKER_INSTANT then
        gauge = 0
    else
        gauge = gauge - Panels.breakerDrain(ratio) * hours
    end
    if gauge <= Panels.BREAKER_SHED_AT and gauge > 0 and Panels.sheds(panel) then
        local keys, powers = Panels.shedPlan(panel, (load - limit) / factor)
        if keys then Changes.shed(panel, keys, powers) end
    end
    Changes.setBreaker(panel, gauge)
    if gauge <= 0 then Changes.trip(panel) end
end

return Overload
