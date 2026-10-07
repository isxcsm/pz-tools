-- The box's main switch, at the test panel: switched off and on by its timed action (valid, then complete, as when the
-- player's walk ends at the box), with the network, the status line, the look, the log and the window's row read each
-- time; quiet hours, a change of units, the breaker's reset and two game minutes of the server's rules leave it off;
-- a trip and the switch together. Then the generators' rows for a faked network state (running, standby, out of
-- service, cannot run, not seen) and whether the charge controller counts each as one that could take over.
-- "[buswitch]" lines, each "ok" or "BAD"; the rest prints a game minute or two later, ending with "done". The panel's
-- breaker, switch and quiet cut are put back as they were. Needs the test panel (bu_setup.lua).
local BU = BuildingUtilities
local Store, Networks, Changes, Panels, PanelLook, PanelWindow, Energy = BU.Store, BU.Networks, BU.Changes, BU.Panels,
    BU.PanelLook, BU.PanelWindow, BU.Energy
local function say(...) print("[buswitch]", ...) end
local function check(what, got, want) say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want)) end

local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("BAD no test panel: run bu_setup.lua"); return end
local player = getPlayer()
local grid = getWorld():isHydroPowerOn()
local was = { tripped = panel.tripped, switchedOff = panel.switchedOff, quietCut = panel.quietCut }
say("grid", grid, "tier", panel.tier, "generators", #panel.power.producers, "source", Energy.hasSource(panel))

local function enabled()
    local state = Networks.state(panel, "power")
    return state and state.enabled
end
local function lastLog()
    local log = panel.log or {}
    return log[#log] and log[#log].key
end
local function sprite()
    local object = Panels.object(panel)
    return object and object:getSprite():getName()
end
local function spriteFor(look)
    local object = Panels.object(panel)
    local shown = object and PanelLook.of(object)
    return shown and PanelLook.SPRITES[look][shown.facing]
end
-- The status line's text as it should read: with the grid alive the grid's, else this one.
local function checkStatus(what, key)
    local status = PanelWindow.status(panel, "power")
    check(what .. ": status", status.text, getText(grid and "IGUI_BU_St_Grid" or key))
end

-- The action as the player's walk ends at the box.
local function throw(off)
    local action = ISBUMainSwitch:new(player, panel, off)
    if not action:isValid() then say("BAD the action is not valid, off", off); return end
    action:complete()
end

-- The window's main switch row, filled from the network now.
local window = PanelWindow.open(player, panel)
local function switchRow()
    window:fill("power", Networks.state(panel, "power"))
    for _, item in ipairs(window.lists.power.items) do
        if item.item.kind == "mainSwitch" then return item.item, item.tooltip end
    end
    return nil
end

-- From a box with its breaker up, its switch on and no quiet cut.
if panel.tripped then Changes.resetBreaker(panel) end
if panel.switchedOff then Changes.setSwitchedOff(panel, false) end
if panel.quietCut then Changes.setQuietCut(panel, false) end
check("start: enabled", enabled(), true)

-- Off.
throw(true)
check("off: switchedOff", panel.switchedOff, true)
check("off: network enabled", enabled(), false)
checkStatus("off", "IGUI_BU_St_Off")
if not grid then check("off: reason", PanelWindow.status(panel, "power").reason, getText("IGUI_BU_Why_SwitchedOff")) end
check("off: look", PanelLook.wanted(panel), "off")
check("off: box sprite", sprite(), spriteFor("off"))
check("off: log", lastLog(), "IGUI_BU_Notice_SwitchedOff")
check("off: switching off again is not valid", ISBUMainSwitch:new(player, panel, true):isValid(), false)
local row, tooltip = switchRow()
check("off: row state", row and row.state, "off")
check("off: row text", row and row.text, getText("IGUI_BU_MainSwitchOff"))
check("off: row tooltip", tooltip, getText("IGUI_BU_MainSwitchTip"))

-- What could switch it on again leaves it off.
Changes.setQuietCut(panel, true)
Changes.setQuietCut(panel, false)
check("quiet cut on and off: enabled", enabled(), false)
panel.quietCut = true
Changes.unitsChanged(panel)
panel.quietCut = nil
Networks.applyEnabled(panel)
check("units changed: enabled", enabled(), false)
Changes.resetBreaker(panel)
check("breaker reset: enabled", enabled(), false)
check("breaker reset: still switched off", panel.switchedOff, true)

-- The generators' rows and the controller's count, for a faked state: producers on loaded squares beside the player.
local function generatorChecks()
    local square = player:getSquare()
    local at = {}
    for i = 1, 6 do at[i] = { x = square:getX() + i, y = square:getY(), z = square:getZ() } end
    local function producer(i, fields)
        local result = { x = at[i].x, y = at[i].y, z = at[i].z }
        for name, value in pairs(fields) do result[name] = value end
        return result
    end
    local list = {
        producer(1, { running = true, fuel = 5, condition = 90 }),
        producer(2, { running = false, standby = true, fuel = 5, condition = 90 }),
        producer(3, { running = false, fuel = 5, condition = 90 }),
        producer(4, { running = false, fuel = 0, condition = 90 }),
        producer(5, { running = false, standby = true, fuel = 5, condition = 0 }),
        producer(6, {}),
    }
    local fake = { supplied = true, enabled = true, load = 0.2, loadFactor = 1, producer = { x = at[1].x, y = at[1].y, z = at[1].z },
        producers = list }
    local wants = { "running", "standby", "out", "cannot", "cannot", nil }
    for i = 1, 6 do
        local state = PanelWindow.generatorState(fake, at[i])
        check("generator " .. i .. " state", state, wants[i])
        check("generator " .. i .. " text", PanelWindow.generatorStateText(state),
            wants[i] and PanelWindow.generatorStateText(wants[i]) or "-")
    end
    -- The rows the window makes of them: the panel's producers stand in for the fake ones while it fills.
    local saved = panel.power.producers
    panel.power.producers = {}
    for i = 1, 6 do panel.power.producers[i] = { x = at[i].x, y = at[i].y, z = at[i].z, paid = {} } end
    local ok, failure = pcall(function() window:fill("power", fake) end)
    panel.power.producers = saved
    if not ok then say("BAD fill failed", failure) end
    for _, item in ipairs(window.lists.power.items) do
        local row = item.item
        if row.kind == "producer" then
            say("row", row.index, row.text, "inUse", row.inUse, "out", row.out)
            check("row " .. row.index .. " says it", row.text:find(PanelWindow.generatorStateText(wants[row.index]), 1, true) ~= nil, true)
            check("row " .. row.index .. " out of service", row.out, wants[row.index] == "out")
            check("row " .. row.index .. " tooltip", item.tooltip, getText("IGUI_BU_GeneratorTip"))
        end
    end
    -- The charge controller counts only those that could take over: running or on standby, with fuel, not broken.
    local function counts(i) return Energy.rules(panel, { load = 0.2, loadFactor = 1, producers = { list[i] } }).generators end
    check("controller counts the running one", counts(1), true)
    check("controller counts the one on standby", counts(2), true)
    check("controller does not count the one out of service", counts(3), false)
    check("controller does not count the one without fuel", counts(4), false)
    check("controller does not count the broken one on standby", counts(5), false)
    check("controller does not count the one not seen", counts(6), false)
    window:refresh()
end

-- A trip and the switch together; then everything put back.
local function tripChecks()
    Changes.trip(panel)
    throw(true)
    check("tripped, switched off: tripped", panel.tripped, true)
    check("tripped, switched off: enabled", enabled(), false)
    check("tripped, switched off: look", PanelLook.wanted(panel), "tripped")
    checkStatus("tripped, switched off", "IGUI_BU_St_Tripped")
    throw(false)
    check("switched on while tripped: still tripped", panel.tripped, true)
    check("switched on while tripped: enabled", enabled(), false)
    checkStatus("switched on while tripped", "IGUI_BU_St_Tripped")
    throw(true)
    Changes.resetBreaker(panel)
    check("reset while switched off: tripped", panel.tripped, false)
    check("reset while switched off: enabled", enabled(), false)
    check("reset while switched off: look", PanelLook.wanted(panel), "off")
    check("reset while switched off: box sprite", sprite(), spriteFor("off"))
    checkStatus("reset while switched off", "IGUI_BU_St_Off")
    throw(false)
    check("switched on after the reset: enabled", enabled(), true)
end

local function finish()
    panel.tripped, panel.switchedOff, panel.quietCut = was.tripped, was.switchedOff, was.quietCut
    Networks.applyEnabled(panel)
    BU.Sync.changed(panel.id)
    say("put back: tripped", panel.tripped, "switchedOff", panel.switchedOff, "quietCut", panel.quietCut, "enabled", enabled())
    say("done")
end

-- Two game minutes of the server's rules (the source, quiet hours, the controller) with the switch off; then on.
local minutes = 0
local function onMinute()
    minutes = minutes + 1
    if minutes < 2 then return end
    Events.EveryOneMinute.Remove(onMinute)
    check("two minutes later: enabled", enabled(), false)
    check("two minutes later: switchedOff", panel.switchedOff, true)
    check("two minutes later: box sprite", sprite(), spriteFor("off"))
    throw(false)
    check("on: switchedOff", panel.switchedOff, nil)
    check("on: network enabled", enabled(), true)
    check("on: look as its power", sprite(), spriteFor(PanelLook.wanted(panel)))
    check("on: log", lastLog(), "IGUI_BU_Notice_SwitchedOn")
    local onRow = switchRow()
    check("on: row state", onRow and onRow.state, "on")
    check("on: row text", onRow and onRow.text, getText("IGUI_BU_MainSwitchOn"))
    tripChecks()
    generatorChecks()
    finish()
end
Events.EveryOneMinute.Add(onMinute)
say("waiting two game minutes with the switch off")
