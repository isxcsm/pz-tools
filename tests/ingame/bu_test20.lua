-- Batch 3 of the plan (DESIGN 12): the water groups and their floor trees, draw and fill through the API, freezing,
-- lamps on outer walls, the plan's room outlines and the range's speed. "[bu20]" lines. Leaves the panel's water as
-- it found it, and the window open with the plan shown.
local BU = BuildingUtilities
local Store, Networks, Water, Changes, PanelWindow = BU.Store, BU.Networks, BU.Water, BU.Changes, BU.PanelWindow
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu20] " .. table.concat(parts, " "))
end
local function litres(value) return value and string.format("%.1f", value) or "-" end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local api = BU.api()
say("api", api ~= nil, "draw", api and api.networks.draw ~= nil, "aboveOnly", Water.aboveOnly(), "freeze", Water.freezeEnabled())
if not api then return end

local function layout(label)
    local nets, floors = Water.layout(panel)
    for _, net in ipairs(nets) do
        local state = api.networks.state(net.id)
        say(label, net.id, "parent", tostring(net.parent), "producers", #net.producers, "rooms", #net.rooms,
            "defined", state ~= nil, "held", state and litres(state.amount), "of", state and litres(state.capacity))
    end
    local state = Networks.state(panel, "water")
    say(label, "panel supplied", state and state.supplied, "held", state and litres(state.amount), "of", state and litres(state.capacity))
    for id, each in pairs(state and state.groups or {}) do say(label, "group", id, litres(each.amount), "of", litres(each.capacity)) end
    return nets, floors
end
local nets = layout("start")

-- A second group with the first tank in it, then gone again: the tank goes back to the first group.
local group = Changes.addWaterGroup(panel, "Garden")
say("added group", group and group.id, "groups", #Water.groups(panel))
if group and panel.water.producers[1] then
    Changes.setProducerGroup(panel, 1, group.id)
    layout("grouped")
    Changes.removeWaterGroup(panel, group.id)
    say("removed: tank 1 group", Water.producerGroup(panel.water.producers[1]), "groups", #Water.groups(panel))
elseif group then
    Changes.removeWaterGroup(panel, group.id)
end
nets = layout("after")

-- Fill then draw the same on the first group's lowest network: what it holds comes back.
local lowest = Water.lowestId(panel, Water.FIRST)
local before = api.networks.state(lowest)
local okFill, filled = pcall(api.networks.fill, BU.handle(), lowest, 5, "Water")
local okDraw, drawn, mix = pcall(api.networks.draw, BU.handle(), lowest, okFill and filled or 0)
local after = api.networks.state(lowest)
local parts = {}
for fluid, amount in pairs(okDraw and mix or {}) do parts[#parts + 1] = fluid .. "=" .. litres(amount) end
say("fill", okFill, litres(okFill and filled or nil), okFill and "" or tostring(filled))
say("draw", okDraw, litres(okDraw and drawn or nil), table.concat(parts, ","), okDraw and "" or tostring(drawn))
say("held before", before and litres(before.amount), "after", after and litres(after.amount))

-- Frozen pipes stop the water; thawed, it flows again.
Changes.setFrozen(panel, true)
local frozen = api.networks.state(lowest)
Changes.setFrozen(panel, false)
local thawed = api.networks.state(lowest)
say("frozen enabled", frozen and frozen.enabled, "thawed enabled", thawed and thawed.enabled)

-- Lamps and the like on the building's outer walls: listed as its own, standing outside its rooms.
local building = BU.Panels.building(panel)
local key = building and building.key
local objects = key and api.buildings.objects(key, "power") or {}
local outside = 0
for _, object in ipairs(objects) do
    local square = getCell():getGridSquare(object.x, object.y, object.z)
    if square and not square:getRoom() and object.type ~= "IsoLightSwitch" then
        outside = outside + 1
        say("on an outer wall", object.sprite, object.x, object.y, object.z, "room", object.room)
    end
end
say("building objects", #objects, "on outer walls", outside)

-- The plan: rooms by their outlines; the range shown and hidden, timed.
PanelWindow.planShown = true
PanelWindow.open(getPlayer(), panel)
local window = PanelWindow.get(panel.id)
window:setPlanShown(true)
window:refresh()
local plan = window.plan
say("plan cells", #plan.cells, "walls", #plan.walls, "floors", #(plan.levels or {}), "range button shown", window.rangeButton:getIsVisible())
local started = getTimestampMs()
window:onRange()
local shown = getTimestampMs() - started
started = getTimestampMs()
window:onRange()
say("range on ms", shown, "off ms", getTimestampMs() - started, "shown now", tostring(window.rangeShown))
say("done")
