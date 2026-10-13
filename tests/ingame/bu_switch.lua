-- The box's main switch, at the test panel: switched off and on by its lever in the window (the setLever command, at
-- once), with the network, the status line, the look, the log and the window's row read each
-- time; a change of units, the breaker's reset and two game minutes of the server's rules leave it off,
-- with no producer running and no outage counted; a minute after it is on, the producer that carried the power
-- before carries it again; a trip and the switch together. Then the generators' rows for a faked network state
-- (running, standby, out of service, cannot run, not seen) and whether the bank's hand-over counts each as one that
-- could take over. Then, with a generator put down and wired and a solar panel if the box has none (the box at tier 1,
-- the solar output faked and no bank), a minute a step: the low fuel told once
-- across off and on; "Switch to solar" (offered, greyed when not ready, the generator on standby after it); a
-- generator switched on by hand while the box is off carries after it is on, though the source could; the source,
-- carrying as the box went off and falling short while it is off, gives way to the generator on standby.
-- "[buswitch]" lines, each "ok" or "BAD"; about fourteen game minutes in all, ending with "done". The panel's breaker,
-- switch, quiet cut and tier are put back as they were, and what was put down is taken away. Needs the test panel
-- (bu_setup.lua).
local BU = BuildingUtilities
local Store, Networks, Changes, Panels, PanelLook, PanelWindow, Energy, Solar = BU.Store, BU.Networks, BU.Changes,
    BU.Panels, BU.PanelLook, BU.PanelWindow, BU.Energy, BU.Solar
local function say(...) print("[buswitch]", ...) end
local function check(what, got, want) say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want)) end

local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("BAD no test panel: run bu_setup.lua"); return end
local player = getPlayer()
local grid = getWorld():isHydroPowerOn()
local was = { tripped = panel.tripped, switchedOff = panel.switchedOff, tier = panel.tier }
-- The generator scene runs the box at tier 1, whose capacity the test panel's devices may pass: overload is off for it,
-- so a trip does not stop the generator under the checks.
local page = SandboxVars.BuildingUtilities
local overloadWas = page and page.OverloadEnabled
say("grid", grid, "tier", panel.tier, "generators", #panel.power.producers, "source", Energy.hasSource(panel))

local function state() return Networks.state(panel, "power") end
local function enabled()
    local now = state()
    return now and now.enabled
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
    return shown and PanelLook.SPRITES[shown.variant][look][shown.facing]
end
local function dark() return panel.stats and panel.stats.dark end
-- The status line's text as it should read: with the grid alive the grid's, else this one.
local function checkStatus(what, key)
    check(what .. ": status", PanelWindow.status(panel, "power").text, getText(grid and "IGUI_BU_St_Grid" or key))
end
-- What carries the power now, by a key: the source's name, a generator's square, or "none".
local function carrier()
    local producer = state() and state().producer
    return producer and (producer.source or (producer.x .. "," .. producer.y .. "," .. producer.z)) or "none"
end

-- The notices told from here on, by key (the client's BU.onNotice, which a game alone calls at once).
local told = {}
local onNotice = BU.onNotice
function BU.onNotice(panelId, key, args)
    if panelId == panel.id then told[key] = (told[key] or 0) + 1 end
    if onNotice then onNotice(panelId, key, args) end
end
local function toldOf(key) return told[key] or 0 end

-- The lever thrown from the window: down (off true) or up.
local function throw(off)
    if Panels.leverUp(panel) == off then Changes.setLever(panel, not off) end
end

-- The window's rows, filled from the network now: the first of a kind, and its tooltip.
local window = PanelWindow.open(player, panel)
local function rowOf(kind)
    window:fill("power", state())
    for _, item in ipairs(window.lists.power.items) do
        if item.item.kind == kind then return item.item, item.tooltip end
    end
    return nil
end

-- From a box with its breaker up and its switch on.
if panel.tripped then Changes.resetBreaker(panel) end
if panel.switchedOff then Changes.setSwitchedOff(panel, false) end
check("start: enabled", enabled(), true)
local before = carrier()
say("carried by", before)

-- Off.
throw(true)
check("off: switchedOff", panel.switchedOff, true)
check("off: network enabled", enabled(), false)
checkStatus("off", "IGUI_BU_St_Off")
if not grid then check("off: reason", PanelWindow.status(panel, "power").reason, getText("IGUI_BU_Why_SwitchedOff")) end
check("off: look", PanelLook.wanted(panel), "off")
check("off: box sprite", sprite(), spriteFor("off"))
check("off: log", lastLog(), "IGUI_BU_Notice_SwitchedOff")
local offNotices = toldOf("IGUI_BU_Notice_SwitchedOff")
throw(true)
check("off: pulling it down again does nothing", toldOf("IGUI_BU_Notice_SwitchedOff"), offNotices)
check("off: lever down", Panels.leverUp(panel), false)

-- What could switch it on again leaves it off.
Changes.unitsChanged(panel)
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
        producer(2, { running = false, fuel = 5, condition = 90 }),
        producer(3, { running = false, outOfService = true, fuel = 5, condition = 90 }),
        producer(4, { running = false, fuel = 0, condition = 90 }),
        producer(5, { running = false, fuel = 5, condition = 0 }),
        producer(6, {}),
    }
    local fake = { supplied = true, enabled = true, load = 0.2, producer = { x = at[1].x, y = at[1].y, z = at[1].z },
        producers = list }
    local wants = { "running", "standby", "out", "cannot", "cannot", nil }
    for i = 1, 6 do
        local got = PanelWindow.generatorState(fake, at[i])
        check("generator " .. i .. " state", got, wants[i])
        check("generator " .. i .. " text", PanelWindow.generatorStateText(got),
            wants[i] and PanelWindow.generatorStateText(wants[i]) or "-")
    end
    -- The rows the window makes of them, word for word: the panel's producers stand in for the fake ones while it fills
    -- (no generator stands on those squares, so fuel is the state's number).
    local saved = panel.power.producers
    panel.power.producers = {}
    for i = 1, 6 do panel.power.producers[i] = { x = at[i].x, y = at[i].y, z = at[i].z, paid = {} } end
    local ok, failure = pcall(function() window:fill("power", fake) end)
    panel.power.producers = saved
    if not ok then say("BAD fill failed", failure) end
    for _, item in ipairs(window.lists.power.items) do
        local each = item.item
        if each.kind == "producer" then
            local seen = list[each.index]
            local want = getText("IGUI_BU_GeneratorRow", each.index, Panels.where(panel, at[each.index].x, at[each.index].y),
                PanelWindow.generatorStateText(wants[each.index]), seen.fuel and string.format("%.1f", seen.fuel) or "-",
                seen.condition and string.format("%.0f%%", seen.condition) or "-")
            check("row " .. each.index .. " text", each.text, want)
            check("row " .. each.index .. " out of service", each.out, wants[each.index] == "out")
            check("row " .. each.index .. " tooltip", item.tooltip, getText("IGUI_BU_GeneratorTip"))
        end
    end
    -- The bank hands over only to those that could take over: not out of service, with fuel, not broken.
    local function counts(i) return Energy.rules(panel, { load = 0.2, producers = { list[i] } }).generators end
    check("hand-over counts the running one", counts(1), true)
    check("hand-over counts the one on standby", counts(2), true)
    check("hand-over does not count the one out of service", counts(3), false)
    check("hand-over does not count the one without fuel", counts(4), false)
    check("hand-over does not count the broken one", counts(5), false)
    -- One not seen loaded counts as before (fuel and condition unknown), if its square is loaded now.
    check("hand-over counts the one not seen, on a loaded square", counts(6), true)
    window:refresh()
end

-- A trip and the lever: tripped, the lever is down; pushed up, the breaker is reset and the power is on. Reset
-- elsewhere (the dev page) while the lever is pulled down, the power stays off until it is pushed up.
local function tripChecks()
    Changes.trip(panel)
    check("tripped: lever down", Panels.leverUp(panel), false)
    throw(true)
    check("tripped: pulling it down does not switch it off", panel.switchedOff == true, false)
    check("tripped: enabled", enabled(), false)
    check("tripped: look", PanelLook.wanted(panel), "tripped")
    checkStatus("tripped", "IGUI_BU_St_Tripped")
    throw(false)
    check("lever up: tripped", panel.tripped, false)
    check("lever up: enabled", enabled(), true)
    throw(true)
    Changes.trip(panel)
    Changes.resetBreaker(panel)
    check("reset while switched off: tripped", panel.tripped, false)
    check("reset while switched off: enabled", enabled(), false)
    check("reset while switched off: look", PanelLook.wanted(panel), "off")
    check("reset while switched off: box sprite", sprite(), spriteFor("off"))
    checkStatus("reset while switched off", "IGUI_BU_St_Off")
    throw(false)
    check("switched on after the reset: enabled", enabled(), true)
end

-- The generator scene: a fuelled generator on a free square outside near the player, wired last; a solar panel wired
-- when the box has no source. The solar output is faked (Energy.output), and the bank too (none).
local outputOf = Energy.output
local function fakeOutput(output) Energy.output = function() return output, 1, 0 end end
local generator, gKey, solar
local function freeSquare()
    local p = player:getSquare()
    for r = 2, 20 do
        for dx = -r, r do
            for dy = -r, r do
                local q = getCell():getGridSquare(p:getX() + dx, p:getY() + dy, 0)
                if q and q:isOutside() and q:getObjects():size() == 1 and q:isFree(false) and not q:getGenerator()
                    and q:getMovingObjects():size() == 0 and Store.producerOwner(q:getX(), q:getY(), 0) == nil then
                    return q
                end
            end
        end
    end
    return nil
end
local function generatorState()
    local x, y, z = generator:getSquare():getX(), generator:getSquare():getY(), generator:getSquare():getZ()
    return PanelWindow.generatorState(state(), { x = x, y = y, z = z })
end
local function sourceAvailable()
    local source = Energy.sourceState(state())
    return source and source.available
end

local function finish()
    Energy.output, Energy.bank = outputOf, bankOf
    BU.onNotice = onNotice
    if generator then
        local square = generator:getSquare()
        Changes.disconnectProducer(panel, "power", square:getX(), square:getY(), square:getZ())
        generator:setActivated(false)
        generator:remove()
    end
    if solar then Changes.removeUnit(solar) end
    panel.tripped, panel.switchedOff, panel.tier = was.tripped, was.switchedOff, was.tier
    if page then page.OverloadEnabled = overloadWas end
    Networks.applyEnabled(panel)
    BU.Sync.changed(panel.id)
    say("put back: tripped", panel.tripped, "switchedOff", panel.switchedOff, "tier", panel.tier,
        "enabled", enabled())
    say("done")
end

-- One step a game minute (the server's minute runs first in each).
local steps = {}

-- 1: the server's first minute with the switch off.
steps[#steps + 1] = function() end

-- 2: two minutes off: nothing runs, no outage counted; then on.
steps[#steps + 1] = function()
    check("two minutes later: enabled", enabled(), false)
    check("two minutes later: switchedOff", panel.switchedOff, true)
    check("two minutes later: box sprite", sprite(), spriteFor("off"))
    check("two minutes later: nothing carries it", carrier(), "none")
    local running = 0
    for _, producer in ipairs(state() and state().producers or {}) do
        if producer.running then running = running + 1 end
    end
    check("two minutes later: producers running", running, 0)
    check("two minutes later: no outage counted (dark minutes)", dark(), nil)
    check("two minutes later: no power-out notice", toldOf("IGUI_BU_Notice_PowerLost"), 0)
    throw(false)
    check("on: switchedOff", panel.switchedOff, nil)
    check("on: network enabled", enabled(), true)
    check("on: log", lastLog(), "IGUI_BU_Notice_SwitchedOn")
    check("on: lever up", Panels.leverUp(panel), true)
end

-- 3: the same carries it again; the trip; the faked rows. Then the generator scene is set up.
steps[#steps + 1] = function()
    if before == "none" then say("skipped: carried by the same (nothing carried the power before)")
    else check("a minute after on: carried by the same", carrier(), before) end
    check("a minute after on: look as its power", sprite(), spriteFor(PanelLook.wanted(panel)))
    tripChecks()
    generatorChecks()
    local square = freeSquare()
    if not square then say("BAD no free square outside for the generator"); return "stop" end
    panel.tier = 1
    if page then page.OverloadEnabled = false end
    Energy.bank = function() return nil end
    fakeOutput(0)
    generator = IsoGenerator.new(instanceItem("Base.Generator"), getCell(), square)
    generator:setFuel(generator:getMaxFuel())
    generator:setCondition(100)
    if not Energy.hasSource(panel) then
        local q = freeSquare()
        if q and BU.Units.canInstall("solar", q) then
            solar = Changes.installUnit("solar", q, Solar.SPRITES.W)
            Changes.connectUnit(solar, panel, {})
        end
    end
    if not Energy.hasSource(panel) then say("BAD no source: no free square for a solar panel"); return "stop" end
    gKey = square:getX() .. "," .. square:getY() .. "," .. square:getZ()
    Changes.connectProducer(panel, "power", square:getX(), square:getY(), square:getZ(), {})
    -- Switched on by hand: it carries the load, as the one switched on last.
    generator:setActivated(true)
    say("generator at", gKey)
end

-- 4: the generator carries; the solar side can now (faked), not switched to at tier 1; its fuel set to last 3 hours.
steps[#steps + 1] = function()
    check("generator scene: carried by the generator", carrier(), gKey)
    fakeOutput(10)
    local perHour = state() and state().fuelPerHour or 0
    if perHour > 0 then generator:setFuel(perHour * 3) else say("BAD no fuelPerHour") end
    told = {}
end

-- 5: the low fuel told once; off.
steps[#steps + 1] = function()
    check("low fuel told", toldOf("IGUI_BU_Notice_LowFuel"), 1)
    check("the source is available, the generator still carries", tostring(sourceAvailable()) .. " " .. carrier(), "true " .. gKey)
    throw(true)
end

-- 6: off: the generator stopped, on standby; on.
steps[#steps + 1] = function()
    check("off: nothing carries it", carrier(), "none")
    check("off: the generator on standby", generatorState(), "standby")
    check("off: no outage counted", dark(), nil)
    throw(false)
end

-- 7: the generator carries again, no news told; "Switch to solar": greyed while not ready, then used.
steps[#steps + 1] = function()
    check("on: the generator carries again", carrier(), gKey)
    check("on: low fuel not told again", toldOf("IGUI_BU_Notice_LowFuel"), 1)
    check("on: no power-out or took-over notice", toldOf("IGUI_BU_Notice_PowerLost") + toldOf("IGUI_BU_Notice_Switched"), 0)
    fakeOutput(0)
    local offered, ready, rules = Energy.sourceOffer(panel, state())
    check("not ready: offered", offered, true)
    check("not ready: ready", ready, false)
    local source = rowOf("source")
    check("not ready: the row offers it", source and source.useSource, true)
    check("not ready: greyed", source and source.useSourceReady, false)
    check("not ready: why", source and source.useSourceReason, rules and Energy.notReadyText(rules))
    fakeOutput(10)
    offered, ready = Energy.sourceOffer(panel, state())
    check("ready: offered and ready", tostring(offered) .. " " .. tostring(ready), "true true")
    source = rowOf("source")
    check("ready: the row's button", source and source.useSourceReady, true)
    BU.Sync.send(player, "useSource", { panel = panel.id })
end

-- 8: the solar side carries, the generator on standby (not out of service). Off, and the generator switched on by hand.
steps[#steps + 1] = function()
    check("switched to solar: carried by", carrier(), Energy.SOURCE)
    check("switched to solar: the generator", generatorState(), "standby")
    check("switched to solar: no longer offered", (Energy.sourceOffer(panel, state())), false)
    throw(true)
    generator:setActivated(true)
end

-- 9: off: the generator back off, the source still available; on.
steps[#steps + 1] = function()
    check("by hand while off: nothing carries it", carrier(), "none")
    check("by hand while off: the generator not running", generator:isActivated(), false)
    check("by hand while off: the source available", sourceAvailable(), true)
    throw(false)
end

-- 10: the generator switched on by hand carries, not the source. Back to solar.
steps[#steps + 1] = function()
    check("on: the generator switched on by hand carries", carrier(), gKey)
    BU.Sync.send(player, "useSource", { panel = panel.id })
end

-- 11: the solar side carries; off, and night falls (faked).
steps[#steps + 1] = function()
    check("back to solar: carried by", carrier(), Energy.SOURCE)
    throw(true)
    fakeOutput(0)
end

-- 12: off, the source no longer available (told while off); on.
steps[#steps + 1] = function()
    check("night while off: the source available", sourceAvailable(), false)
    throw(false)
end

-- 13: the generator on standby carries, not the source.
steps[#steps + 1] = function()
    check("on at night: carried by the generator on standby", carrier(), gKey)
    return "stop"
end

local step = 0
local function onMinute()
    step = step + 1
    local ok, result = pcall(steps[step])
    if not ok then say("BAD step", step, "failed:", result) end
    if not ok or result == "stop" or step >= #steps then
        Events.EveryOneMinute.Remove(onMinute)
        finish()
    end
end
Events.EveryOneMinute.Add(onMinute)
say("waiting: a step each game minute,", #steps, "steps")
