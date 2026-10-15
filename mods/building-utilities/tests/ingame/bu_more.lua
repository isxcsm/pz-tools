-- The rest of the hand checks, at the test panel (bu_setup.lua): a box taken up and put down keeps its tier (the
-- game's move tool); the window's name, search and view options and the producers' order at the ends; a device's
-- timer by the time of day; a line taken away gives back the sandbox's share; the relays a tier allows; a pipe's
-- colour and name (a long name cut on a whole letter); a box taken apart; the first box found in a container; a title
-- once; the manual (its mark, printing, a click, a chapter left half way, the batteries' chapter with a rack).
-- "[bumore]" lines, each "ok" or "BAD"; "done" at the end, some seconds later (the manual prints in real time). What
-- the character had read, seen and found, the panel's tier and what was put down are put back.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Changes, Costs, Links, Units, Water, Manual = BU.Store, BU.Panels, BU.Changes, BU.Costs, BU.Links,
    BU.Units, BU.Water, BU.Manual
local PanelWindow = BU.PanelWindow
local player = getPlayer()
local inventory = player:getInventory()
local bad = 0
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bumore] " .. table.concat(parts, " "))
end
local function check(label, got, want)
    local ok = got == want
    if not ok then bad = bad + 1 end
    say(ok and "ok" or "BAD", label, got, "want", want)
end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local tierWas = panel.tier or 1

-- Whether a string is Korean letters (U+AC00) only, whole: one place of a Kahlua string each.
local function wholeLetters(s)
    for i = 1, #s do
        if string.byte(s, i) ~= 0xAC00 then return false end
    end
    return true
end
-- A Korean letter (U+AC00), so many times, without a literal in the file.
local function hangul(count) return string.rep(string.char(0xAC00), count) end

local function yardSquare(test)
    return BUT.square(panel.x, panel.y, 0, 4, 16, function(s)
        return s:isOutside() and s:isFree(false) and not Panels.buildingAt(s:getX(), s:getY(), 0) and test(s)
    end)
end

-- 1. Taken up with the game's move tool and put down: the item of its tier, the box of that tier again.
local function carryChecks()
    local yard = yardSquare(function(s) return Panels.canInstall(s) == true end)
    if not yard then say("BAD no yard square"); bad = bad + 1; return end
    local box = Changes.install(yard, "S", { tier = 3 })
    local object = Panels.object(box)
    local props = ISMoveableSpriteProps.new(object:getSprite())
    check("carry: the tool knows it", props.buKind, "panel")
    local before = inventory:getCountTypeRecurse(BU.PANEL_ITEMS[3])
    props.object = object
    local okUp, failure = pcall(props.pickUpMoveable, props, player, yard, true)
    if not okUp then say("BAD carry: pick up failed", failure); bad = bad + 1 end
    check("carry: the box gone", Store.get(box.id), nil)
    check("carry: a tier 3 item", inventory:getCountTypeRecurse(BU.PANEL_ITEMS[3]) - before, 1)
    local item = inventory:getFirstTypeRecurse(BU.PANEL_ITEMS[3])
    check("carry: its tier", item and Panels.itemTier(item), 3)
    if not item then return end
    local world = item:getWorldSprite()
    local placer = ISMoveableSpriteProps.new(getSprite(world))
    local okDown, failed = pcall(placer.placeMoveable, placer, player, yard, world)
    if not okDown then say("BAD carry: put down failed", failed); bad = bad + 1 end
    local again = Store.panelAt(yard:getX(), yard:getY(), 0)
    check("carry: put down again", again ~= nil, true)
    check("carry: the item used", inventory:getCountTypeRecurse(BU.PANEL_ITEMS[3]) - before, 0)
    if again then
        check("carry: its tier kept", again.tier, 3)
        Changes.remove(again)
    end
end

-- 2. The window: the name (a long one cut on a whole letter), the search, the view options, the producers' ends.
local function windowChecks()
    if PanelWindow.isOpen(panel.id) then PanelWindow.get(panel.id):close() end
    local window = PanelWindow.open(player, panel)
    local nameWas = panel.name
    Changes.rename(panel, hangul(20))
    check("rename: a long name cut on a whole letter", wholeLetters(panel.name or ""), true)
    say("rename: kept", #(panel.name or ""), "letters")
    window:refresh()
    check("rename: the title shows it", tostring(PanelWindow.boxTitle(panel)):find(panel.name, 1, true) ~= nil, true)
    Changes.rename(panel, nameWas)
    -- The search: a device's own name finds it and leaves out the rest.
    window.tabs:activateView(window.tabs.viewList[1].name)
    window:refresh()
    local name
    for _, item in ipairs(window.lists.power.items) do
        if item.item.kind == "device" and not name then name = item.item.name or item.text end
    end
    if name and name ~= "" then
        window.search:setText(name)
        window:onSearch()
        local devices, others = 0, 0
        for _, item in ipairs(window.lists.power.items) do
            if item.item.kind == "device" then
                if tostring(item.item.name or item.text):lower():find(name:lower(), 1, true) then devices = devices + 1
                else others = others + 1 end
            end
        end
        check("search: finds it", devices > 0, true)
        check("search: leaves out the rest", others, 0)
        window.search:setText("")
        window:onSearch()
    else
        say("no device row to search for")
    end
    -- The view options: unwired hidden, only those drawing, by load.
    local function count(test)
        local n = 0
        for _, item in ipairs(window.lists.power.items) do if test(item.item) then n = n + 1 end end
        return n
    end
    local unwired = count(function(row) return row.kind == "producer" and row.unwired end)
    window:onHideUnwired()
    check("hide unwired: none listed", count(function(row) return row.kind == "producer" and row.unwired end), 0)
    window:onHideUnwired()
    check("hide unwired off: back", count(function(row) return row.kind == "producer" and row.unwired end), unwired)
    window:onActiveOnly()
    check("drawing only: none off listed", count(function(row)
        return row.kind == "device" and row.device and (row.device.power or 0) <= 0
    end), 0)
    window:onActiveOnly()
    window:onByLoad()
    local last, sorted = nil, true
    for _, item in ipairs(window.lists.power.items) do
        local row = item.item
        if row.kind == "room" or row.kind == "floor" then last = nil
        elseif row.kind == "device" and row.device then
            local power = row.device.power or 0
            if last and power > last + 1e-9 then sorted = false end
            last = power
        end
    end
    check("by load: each room's devices from the most", sorted, true)
    window:onByLoad()
    -- The producers' order: up at the first and down at the last do nothing.
    local list = panel.power.producers
    if #list >= 2 then
        local first, lastOne = list[1], list[#list]
        Changes.moveProducer(panel, "power", 1, -1)
        Changes.moveProducer(panel, "power", #list, 1)
        check("order: the ends stay", list[1] == first and list[#list] == lastOne, true)
        Changes.moveProducer(panel, "power", 1, 1)
        check("order: down one", list[2], first)
        Changes.moveProducer(panel, "power", 2, -1)
        check("order: back", list[1], first)
    else
        say("fewer than two producers: order not checked")
    end
    window:close()
end

-- 3. A device's timer at tier 3: off or on by the time of day, always on again below the tier.
local function timerChecks()
    BU.Dev.setTier(panel, 3)
    local device
    for _, each in ipairs(Panels.devices(panel, "power")) do
        if each.inside and not device then device = each end
    end
    if not device then say("BAD no device inside"); bad = bad + 1; return end
    local key = device.key
    Changes.setSchedule(panel, key, "night")
    check("timer night: off by day, on by night", panel.power.timed[key] == true, not BU.scheduleOn("night"))
    Changes.setSchedule(panel, key, "day")
    check("timer day: the other way", panel.power.timed[key] == true, not BU.scheduleOn("day"))
    local timedOff = panel.power.timed[key] == true and key or nil
    if not timedOff then Changes.setSchedule(panel, key, "night") end
    BU.Dev.setTier(panel, 2)
    Changes.applyTimers(panel)
    check("below the timers' tier: on", panel.power.timed[key], nil)
    BU.Dev.setTier(panel, 3)
    Changes.setSchedule(panel, key, "always")
    check("always: on", panel.power.timed[key], nil)
end

-- 4. A line taken away gives back the sandbox's share of what it took.
local function refundChecks()
    local sq = yardSquare(function(s) return not s:getGenerator() and Store.producerOwner(s:getX(), s:getY(), 0) == nil end)
    if not sq then say("BAD no square for a line"); bad = bad + 1; return end
    local generator = IsoGenerator.new(instanceItem("Base.Generator"), getCell(), sq)
    Changes.connectProducer(panel, "power", sq:getX(), sq:getY(), 0, { [Costs.WIRE] = 4 })
    local before = inventory:getCountTypeRecurse(Costs.WIRE)
    local action = ISBUDisconnect:new(player, "producer", panel, "power", sq:getX(), sq:getY(), 0)
    check("refund: the action completes", action:complete(), true)
    check("refund: the sandbox's share", inventory:getCountTypeRecurse(Costs.WIRE) - before, Costs.refundCount(4))
    say("refund percent", BU.refundPercent())
    generator:remove()
end

-- 5. The relays a tier allows: as many as it has, then none more.
local function relayChecks()
    BU.Dev.setTier(panel, 2)
    local limit, junctions = BU.relayLimit(2), {}
    for _ = 1, limit + 1 do
        if Links.state(panel).relays >= limit then break end
        local sq = yardSquare(function(s) return Units.canInstall("junction", s) and Links.placeOn(panel, "power", s:getX(), s:getY(), 0, true) ~= nil end)
        if not sq then break end
        local junction = Changes.installUnit("junction", sq, BU.Relays.SPRITES.junction)
        Changes.connectUnit(junction, panel, {})
        junctions[#junctions + 1] = junction
    end
    check("relays: as many as the tier allows", Links.state(panel).relays, limit)
    local sq = yardSquare(function(s) return Units.canInstall("junction", s) end)
    local place, reason = Links.placeOn(panel, "power", sq:getX(), sq:getY(), 0, true)
    check("relays: one more refused", place == nil and reason, "relays")
    for _, junction in ipairs(junctions) do Changes.removeUnit(junction) end
end

-- 6. A pipe's colour and name, the long name cut on a whole letter; a room put on it and back.
local function pipeChecks()
    local id = Changes.addPipe(panel)
    if not id then say("no pipe colour free"); return end
    Changes.renamePipe(panel, id, hangul(15))
    local pipe = Water.pipe(panel, id)
    check("pipe name cut on a whole letter", wholeLetters(pipe.name or ""), true)
    check("pipe name shown", Water.pipeName(panel, id), pipe.name)
    local room = Panels.zoneRooms(panel)[1]
    local key = room and room.key
    if key then
        Changes.setRoomPipe(panel, key, id)
        check("room on the pipe", panel.water.roomPipe[key], id)
        Changes.setRoomPipe(panel, key, Water.FIRST)
        check("room back on the first", panel.water.roomPipe[key], nil)
    end
    Changes.removePipe(panel, id)
    check("pipe taken away", Water.pipe(panel, id), nil)
end

-- 7. A box taken apart: its boards, wire and parts; the item gone.
local function takeApartChecks()
    for _, tool in ipairs({ "Base.Screwdriver", "Base.Pliers" }) do
        if inventory:getCountTypeRecurse(tool) == 0 then inventory:AddItem(tool) end
    end
    local item = inventory:AddItem(BU.PANEL_ITEMS[3])
    local boards = inventory:getCountTypeRecurse(Costs.BOARD)
    local action = ISBUTakeApartBox:new(player, item)
    check("take apart: completes", action:complete(), true)
    check("take apart: the item gone", inventory:contains(item), false)
    check("take apart: the boards of a tier 3 box", inventory:getCountTypeRecurse(Costs.BOARD) - boards, Costs.boardsIn(3))
end

-- 8. The first box found in a container: said once, its line lit; not again.
local function findChecks()
    local data = player:getModData()
    local foundWas = data[BU.Finds.FOUND]
    data[BU.Finds.FOUND] = nil
    local owner = { hasModData = function() return true end, getModData = function() return { buBox = true } end }
    local container = { getVehiclePart = function() return nil end, getParent = function() return owner end,
        containsType = function(_, kind) return kind == "BuildingUtilities.BreakerBox" end }
    local function page() return { player = player:getPlayerNum(), inventoryPane = {}, backpacks = { { inventory = container } } } end
    local first = page()
    BU.Finds.onRefresh(first, "buttonsAdded")
    check("find: marked found", data[BU.Finds.FOUND], true)
    check("find: its line lit", first.inventoryPane.highlightItem, "BreakerBox")
    local second = page()
    BU.Finds.onRefresh(second, "buttonsAdded")
    check("find: not again", second.inventoryPane.highlightItem, nil)
    data[BU.Finds.FOUND] = foundWas
end

-- 9. A title once for each character.
local function titleChecks()
    local data = player:getModData()
    local seen = data[BU.Titles.SEEN] or {}
    data[BU.Titles.SEEN] = seen
    local was = seen.tier4
    seen.tier4 = nil
    local shown = BU.Titles.show(player, "tier", 4)
    say("title: the API's text there", shown)
    if shown then check("title: not twice", BU.Titles.show(player, "tier", 4), false) end
    seen.tier4 = was
end

-- 10. The manual, for a character who has read nothing: its mark, printing, a click to the end, a chapter left half
-- way, the batteries' chapter once a rack is wired.
local readWas = player:getModData()[Manual.READ]
local function manualStart()
    BU.Dev.setTier(panel, 1)
    player:getModData()[Manual.READ] = nil
    if PanelWindow.isOpen(panel.id) then PanelWindow.get(panel.id):close() end
    local window = PanelWindow.open(player, panel)
    local manual = window.manual
    local dot
    for _, entry in ipairs(window.tabs.viewList) do if entry.view == manual then dot = entry.dot end end
    check("manual: the tab marked", dot, true)
    window.tabs:activateView(getText("IGUI_BU_Tab_" .. BU.PanelUi.MANUAL))
    window:refresh()
    check("manual: the first chapter open", manual.key, Manual.chapters(panel, player)[1])
    return window, manual
end

local steps, wait = {}, 0
local window, manual
steps[#steps + 1] = function()
    for _, run in ipairs({ carryChecks, windowChecks, timerChecks, refundChecks, relayChecks, pipeChecks,
            takeApartChecks, findChecks, titleChecks }) do
        local ok, failure = pcall(run)
        if not ok then say("BAD failed:", failure); bad = bad + 1 end
    end
    window, manual = manualStart()
    return 60
end
steps[#steps + 1] = function()
    local run = manual.body.run
    check("manual: printing after a second", run ~= nil and not run.done and (manual.body.n or 0) > 0, true)
    manual.body:onMouseDown(5, 5)
    return 20
end
steps[#steps + 1] = function()
    check("manual: a click brings it to its end", Manual.state(player, manual.key), true)
    local second = Manual.chapters(panel, player)[2]
    manual:show(second)
    return 60
end
steps[#steps + 1] = function()
    local key = manual.key
    manual:show(Manual.chapters(panel, player)[3])
    local state = Manual.state(player, key)
    check("manual: left half way, kept", type(state) == "table" and (tonumber(state.t) or 0) > 0, true)
    -- A rack wired: the batteries' chapter.
    local had = false
    for _, key in ipairs(Manual.chapters(panel, player)) do if key == "battery" then had = true end end
    local rack
    if not had then
        local sq = BUT.square(panel.x, panel.y, panel.z, 1, 10, function(s) return Units.canInstall("rack", s) end)
        if sq then
            rack = Changes.installUnit("rack", sq, Units.spriteFor("rack", sq, player))
            Changes.connectUnit(rack, panel, {})
        end
    end
    local has = false
    for _, key in ipairs(Manual.chapters(panel, player)) do if key == "battery" then has = true end end
    check("manual: the batteries' chapter with a rack", has, true)
    if rack then Changes.removeUnit(rack) end
    -- Opened again: which chapter.
    local open = manual.key
    window:close()
    window = PanelWindow.open(player, panel)
    window.tabs:activateView(getText("IGUI_BU_Tab_" .. BU.PanelUi.MANUAL))
    window:refresh()
    say("manual: open before", open, "opened again on", window.manual.key)
    window:close()
    player:getModData()[Manual.READ] = readWas
    BU.Dev.setTier(panel, tierWas)
    say("done:", bad, "BAD")
end

local step = 0
local function onTick()
    if wait > 0 then wait = wait - 1; return end
    step = step + 1
    local ok, result = pcall(steps[step])
    if not ok then say("BAD step", step, result); bad = bad + 1 end
    if not ok or step >= #steps then
        Events.OnTick.Remove(onTick)
        if not ok then
            player:getModData()[Manual.READ] = readWas
            BU.Dev.setTier(panel, tierWas)
            say("done:", bad, "BAD")
        end
        return
    end
    wait = tonumber(result) or 0
end
Events.OnTick.Add(onTick)
