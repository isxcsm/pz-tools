-- The tier rework's checks that the batch checks leave out, at the test panel (bu_setup.lua): the window at each tier
-- and each of its tabs; a device outside hung on a room's wall and below a relay (listed and switched with them); a
-- relay taken up and its branch hung on again; where a box may go; the manual's chapters, the titles, the schematic,
-- the upgrade costs and the item icons. "[burw]" lines, each check "ok" or "BAD"; info lines without. Leaves the
-- panel at the tier it found and takes away what it put down.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Changes, Links, Units, Ui = BU.Store, BU.Panels, BU.Changes, BU.Links, BU.Units, BU.PanelUi
local player = getPlayer()
local bad = 0
local function say(...) print("[burw] " .. table.concat((function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    return parts
end)(...), " ")) end
local function check(label, got, want)
    local ok = got == want
    if not ok then bad = bad + 1 end
    say(ok and "ok" or "BAD", label, got, "want", want)
end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local tierWas = panel.tier or 1

-- The window at each tier: its tabs, each opened and filled without an error.
local PanelWindow = BU.PanelWindow
for tier = 1, 4 do
    BU.Dev.setTier(panel, tier)
    if PanelWindow.isOpen(panel.id) then PanelWindow.get(panel.id):close() end
    local okOpen, window = pcall(PanelWindow.open, player, panel)
    check("tier " .. tier .. ": window opens", okOpen and window ~= nil, true)
    if okOpen and window then
        local names = {}
        for _, entry in ipairs(window.tabs.viewList) do names[#names + 1] = entry.name end
        say("tier", tier, "tabs", table.concat(names, ","))
        check("tier " .. tier .. ": log tab", window.lists[Ui.LOG] ~= nil, tier >= BU.LOG_TIER)
        for _, name in ipairs(names) do
            window.tabs:activateView(name)
            local ok, err = pcall(function()
                window:refresh()
                window:prerender()
            end)
            check("tier " .. tier .. " tab " .. name, ok and "fine" or tostring(err), "fine")
        end
        window.tabs:activateView(names[1])
    end
end
BU.Dev.setTier(panel, 2)

-- A device outside: the radio on the patio (or any outside device the box lists), hung on the nearest wall.
local outside
for _, device in ipairs(Panels.devices(panel, "power")) do
    if not device.inside and device.state ~= "other" then outside = device end
end
say("outside device", outside and outside.key or "none")
local junction
if outside then
    local ref = Links.deviceRef(outside.key)
    local wasLine = Links.get(ref) ~= nil
    if not wasLine then Changes.includeOutside(panel, "power", outside, {}) end
    local hangs = Links.hangsOn(panel, ref)
    say("hangs on", hangs, "room", hangs and Panels.roomById and "" or "")
    local listed
    for _, device in ipairs(Panels.devices(panel, "power")) do
        if device.key == outside.key then listed = device end
    end
    local group = listed and Ui.groupOf(listed)
    check("outside device: listed under its wall's room", group, hangs)
    Changes.setRoomInside(panel, "power", hangs, false)
    check("its room off: it is off", panel.power.excluded[outside.key], true)
    Changes.setRoomInside(panel, "power", hangs, true)
    check("its room on: it is on", panel.power.excluded[outside.key], nil)

    -- A junction between it and the building: the device hung below the junction.
    local ex, ey = outside.entry.x, outside.entry.y
    local sq = BUT.square(ex, ey, 0, 1, 4, function(s) return Units.canInstall("junction", s) end)
    if sq then
        junction = Changes.installUnit("junction", sq, BU.Relays.SPRITES.junction)
        Changes.connectUnit(junction, panel, {})
        local junctionRef = Links.unitRef(junction)
        local place = Links.placeOn(panel, "power", ex, ey, 0, nil, nil)
        say("junction at", junction.x, junction.y, "live", Links.live(panel, junctionRef), "device would hang", place and place.from, place and place.via)
        Changes.rehang(ref, panel, { via = junctionRef, length = Links.length(ex, ey, 0, junction.x, junction.y, 0) }, {})
        listed = nil
        for _, device in ipairs(Panels.devices(panel, "power")) do
            if device.key == outside.key then listed = device end
        end
        check("below the junction: listed under it", listed and Ui.groupOf(listed), junctionRef)
        Changes.setRoomInside(panel, "power", junctionRef, false)
        check("the junction's group off: it is off", panel.power.excluded[outside.key], true)
        Changes.setRoomInside(panel, "power", junctionRef, true)
        -- The junction taken up: the device's line is cut, its branch listed; hung on the wall again.
        local deadBefore = #Links.deadHeads(panel)
        Changes.removeUnit(junction)
        junction = nil
        check("junction gone: a dead branch more", #Links.deadHeads(panel), deadBefore + 1)
        check("its line the dead head", Links.cutHead(ref) and Links.cutHead(ref).ref, ref)
        say("why", Links.reasonText(panel, ref))
        local again = Links.placeOn(panel, "power", ex, ey, 0)
        if again then Changes.rehang(ref, panel, again, {}) end
        check("hung on the wall again: as before", #Links.deadHeads(panel), deadBefore)
    else
        say("no square for a junction near the device")
    end
    if not wasLine then Changes.excludeOutside(panel, "power", outside) end
end
if junction then Changes.removeUnit(junction) end

-- Where a box may go: in this building's zone no; outside yes (an outdoor box).
local cell = getCell()
local inZone = cell:getGridSquare(panel.x, panel.y, panel.z)
local taken = select(2, Panels.canInstall(inZone))
check("a second box in the zone", taken == "wholeTaken" or taken == "roomTaken", true)
local yard = BUT.square(panel.x, panel.y, 0, 3, 12, function(s) return s:isOutside() and not Panels.buildingAt(s:getX(), s:getY(), 0) end)
check("a box in the yard", yard and Panels.canInstall(yard) == true, true)

-- The manual, the titles, the schematic, the costs, the icons.
local chapters = BU.Manual.chapters(panel, player)
say("manual chapters at tier 2", table.concat(chapters, ","))
say("titles seen", (function()
    local seen = player:getModData()[BU.Titles and BU.Titles.SEEN or "buTitles"] or {}
    local list = {}
    for key in pairs(seen) do list[#list + 1] = key end
    return table.concat(list, ",")
end)())
local okScheme, scheme = pcall(BU.Water.schematic, panel, BU.Networks.waterLayout(panel), BU.Networks.waterState)
check("schematic made", okScheme and type(scheme) == "table", true)
if okScheme and scheme then say("schematic pipes", #scheme.pipes, "levels", scheme.low, scheme.high, "machines", #scheme.machines) end
for tier = 2, 4 do
    local cost = BU.Costs.upgrade(tier)
    local parts = {}
    for _, item in ipairs(cost and cost.items or {}) do parts[#parts + 1] = item[1] .. "x" .. item[2] end
    say("upgrade to", tier, "skill", cost and cost.skill, table.concat(parts, " "))
end
for _, kind in ipairs({ "BreakerBox", "BreakerBox4", "ControlBoard", "SolarPanel", "JunctionBox", "YardHydrant" }) do
    local item = instanceItem("BuildingUtilities." .. kind)
    local tex = item and item:getTex()
    say("icon", kind, tex and tex:getName() or "none")
end
for _, at in ipairs(Panels.unwiredProducers(panel, "power")) do
    say("unwired producer", at.x, at.y, at.unit and at.unit.kind or at.sprite, at.unit and "" or BU.displayName(at.x, at.y, at.z, at.sprite))
end

BU.Dev.setTier(panel, tierWas)
say("done:", bad, "BAD")
