-- The container a mission's item lies in, lit: what is looked at and when, the outline's colour, the loot window's name
-- paint, and that the work stops with the mission. The game's objects are fakes that record what they are told.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
local OA = OperationAcorn

local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end

local function item(mission, name)
    local data = { OA_Mission = mission }
    return { hasModData = function() return mission ~= nil end, getModData = function() return data end,
        getName = function() return name or "Thing" end }
end

local function container(items, parent)
    return { getItems = function() return list(items) end, getParent = function() return parent end,
        getContentsWeight = function() return #items end }
end

-- A piece of furniture with containers; `calls` records its outline.
local function furniture(containers)
    local o = { calls = {}, on = false, colour = nil }
    o.getContainerCount = function() return #containers end
    o.getContainerByIndex = function(_, k) return containers[k + 1] end
    o.setOutlineHighlight = function(_, n, on) o.on = on; o.calls[#o.calls + 1] = on end
    o.setOutlineHighlightCol = function(_, n, r, g, b, a) o.colour = { r, g, b } end
    return o
end

local function square(objects, floor, sees)
    return { isCouldSee = function() return sees ~= false end, getObjects = function() return list(objects) end,
        getWorldObjects = function() return list(floor or {}) end }
end

local state
local function setup(mission, where)
    state = { squares = {}, looked = 0, handlers = {} }
    local m = mission
    m.items = m.items or {}
    local record = OA.Store.ensure("p1", "P")
    record.missions = { active = m }
    local player = { x = where and where.x or 100.5, y = where and where.y or 100.5, z = 0, dead = false }
    player.getX = function() return player.x end
    player.getY = function() return player.y end
    player.getZ = function() return player.z end
    player.getPlayerNum = function() return 0 end
    player.isDead = function() return player.dead end
    player.getModData = function() return { OA_Id = "p1" } end
    state.player = player
    state.record = record
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return player end
    getCell = function()
        return { getGridSquare = function(_, x, y, z)
            state.looked = state.looked + 1
            return state.squares[x .. "," .. y .. "," .. z]
        end }
    end
    state.page = { inventoryPane = { inventory = nil }, isVisible = function() return true end }
    getPlayerLoot = function() return state.page end
    instanceof = function(o, cls) return o.isCase == true end
    Events.OnTick = { Add = function(fn) state.handlers[fn] = true end, Remove = function(fn) state.handlers[fn] = nil end }
    return m, record
end

local drawn, H
local function load()
    ISInventoryPane = { drawText = function(self, str, x, y, r, g, b, a, font) drawn[#drawn + 1] = { str, r, g, b } end,
        renderdetails = function(self)
            self:drawText("Pliers", 0, 0, 1, 1, 1, 1)
            self:drawText("Filter Case", 0, 1, 1, 1, 1, 1)
            self:drawText("0.5", 0, 2, 0.7, 0.7, 0.7, 1)
        end }
    drawn = {}
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Story/Highlight")
    require = real
    if not ok then error(err, 0) end
    H = OA.StoryHighlight
    return H
end

local function regular(extra)
    local m = { id = "M1-1", kind = "regular", state = "open", level = 1, area = { x = 1, y = 1, r = 60 }, items = {} }
    m.items[1] = { key = "A", type = "OperationAcorn.MissionFilterCase", mode = "container", placed = true,
        at = { x = 100, y = 100, z = 0 } }
    for k, v in pairs(extra or {}) do m[k] = v end
    return m
end

-- A frame: the work is started or stopped by the record, as the game's events would, and runs when it is on.
local function tick()
    H.update()
    for fn in pairs(state.handlers) do fn() end
end

test("a container that holds the mission item is outlined teal when the character is near, on its floor and sees it", function()
    local m = setup(regular())
    local desk = furniture({ container({ item("M1-1") }) })
    state.squares["100,100,0"] = square({ desk })
    load()
    tick()
    eq(desk.on, true)
    near(desk.colour[1], 0.30, 1e-9)
    near(desk.colour[2], 0.90, 1e-9)
    near(desk.colour[3], 0.85, 1e-9)
    truthy(H.lit[0][desk], "told to the search ledger, which leaves it alone")
end)

test("a story mission is outlined sky blue", function()
    setup(regular({ kind = "story" }))
    local desk = furniture({ container({ item("M1-1") }) })
    state.squares["100,100,0"] = square({ desk })
    load()
    tick()
    near(desk.colour[1], 0.55, 1e-9)
    near(desk.colour[3], 1.0, 1e-9)
end)

test("nothing is looked at while the piece is far, on another floor, or out of sight", function()
    setup(regular(), { x = 120.5, y = 100.5 })
    local desk = furniture({ container({ item("M1-1") }) })
    state.squares["100,100,0"] = square({ desk })
    load()
    tick()
    eq(state.looked, 0, "twenty squares away: only the distance was measured")
    eq(desk.on, false)
    state.player.x = 100.5
    state.player.z = 1
    tick()
    eq(state.looked, 0, "another floor")
    state.player.z = 0
    state.squares["100,100,0"] = square({ desk }, nil, false)
    tick()
    eq(state.looked, 1, "near: the square is looked at")
    eq(desk.on, false, "behind a wall: not outlined")
end)

test("the outline goes when the item is taken out of the container, or the character walks off", function()
    setup(regular())
    local things = { item("M1-1") }
    local desk = furniture({ container(things) })
    state.squares["100,100,0"] = square({ desk })
    load()
    tick()
    eq(desk.on, true)
    table.remove(things, 1)
    tick()
    eq(desk.on, false, "no mission item in it")
    eq(H.lit[0], nil)
    table.insert(things, item("M1-1"))
    tick()
    eq(desk.on, true)
    state.player.x = 130.5
    tick()
    eq(desk.on, false, "out of range")
end)

test("another container, another mission's item and a piece not placed yet are not lit", function()
    local m = setup(regular())
    m.items[2] = { key = "B", placed = false, at = { x = 101, y = 100, z = 0 } }
    local other = furniture({ container({ item("M9-9") }) })
    local empty = furniture({ container({}) })
    state.squares["100,100,0"] = square({ other, empty })
    state.squares["101,100,0"] = square({ empty })
    load()
    tick()
    eq(other.on, false)
    eq(empty.on, false)
end)

test("the key to a locked room is plain and is not lit", function()
    local m = setup(regular())
    m.items[2] = { key = "KEY", placed = true, plain = true, at = { x = 101, y = 100, z = 0 } }
    state.squares["100,100,0"] = square({})
    state.squares["101,100,0"] = square({ furniture({ container({ item("M1-1#KEY") }) }) })
    load()
    tick()
    eq(state.looked, 1, "only the mission's piece's square")
end)

test("a piece lying on the floor is lit, a case only while the item is in it", function()
    local m = setup(regular())
    m.items = { { key = "CASE", placed = true, inside = "SampleCan", at = { x = 100, y = 100, z = 0 } },
        { key = "A", placed = true, at = { x = 100, y = 100, z = 0 } } }
    local inner = item("M1-1#A")
    local caseItem = item("M1-1#CASE")
    caseItem.isCase = true
    local things = { inner }
    caseItem.getInventory = function() return container(things) end
    local world = furniture({})
    world.getItem = function() return caseItem end
    state.squares["100,100,0"] = square({}, { world })
    load()
    tick()
    eq(world.on, true, "the case with the item in it")
    table.remove(things, 1)
    tick()
    eq(world.on, false, "the item taken out of the case")
end)

test("the container the loot window has open is left to the game, and lit again when it closes", function()
    setup(regular())
    local desk = furniture({ container({ item("M1-1") }) })
    state.squares["100,100,0"] = square({ desk })
    load()
    state.page.inventoryPane.inventory = container({ item("M1-1") }, desk)
    tick()
    eq(#desk.calls, 0, "the game colours the container it shows")
    state.page.inventoryPane.inventory = nil
    tick()
    eq(desk.on, true)
end)

test("a lit container is lit again each look, in case the game or the ledger turned it off", function()
    setup(regular())
    local desk = furniture({ container({ item("M1-1") }) })
    state.squares["100,100,0"] = square({ desk })
    load()
    tick()
    desk.on = false
    desk.colour = nil
    tick()
    eq(desk.on, true)
    truthy(desk.colour)
end)

test("the work runs while a mission is open and stops, taking the outlines back, when it is not", function()
    local m, record = setup(regular())
    local desk = furniture({ container({ item("M1-1") }) })
    state.squares["100,100,0"] = square({ desk })
    load()
    H.update()
    local count = 0
    for _ in pairs(state.handlers) do count = count + 1 end
    eq(count, 1)
    tick()
    eq(desk.on, true)
    record.missions.active.state = "sealed"
    H.update()
    count = 0
    for _ in pairs(state.handlers) do count = count + 1 end
    eq(count, 0, "no tick without an open mission")
    eq(desk.on, false, "the outline is taken back")
    eq(H.lit[0], nil)
end)

test("an offered mission, or none, has nothing to light", function()
    setup(regular({ state = "offer" }))
    load()
    H.update()
    local count = 0
    for _ in pairs(state.handlers) do count = count + 1 end
    eq(count, 0)
    state.record.missions.active = nil
    H.update()
    eq(state.looked, 0)
end)

test("the loot window paints the mission item's name and nothing else", function()
    setup(regular())
    local desk = furniture({ container({ item("M1-1", "Filter Case"), item(nil, "Pliers") }) })
    state.squares["100,100,0"] = square({ desk })
    load()
    local pane = state.page.inventoryPane
    pane.inventory = container({ item("M1-1", "Filter Case"), item(nil, "Pliers") }, furniture({}))
    pane.drawText = nil
    setmetatable(pane, { __index = ISInventoryPane })
    pane.renderdetails = ISInventoryPane.renderdetails
    tick()
    eq(type(pane.oaTint), "table")
    pane:renderdetails()
    eq(drawn[1][1], "Pliers")
    eq(drawn[1][2], 1, "an ordinary name keeps its colour")
    eq(drawn[2][1], "Filter Case")
    near(drawn[2][2], 0.30, 1e-9)
    near(drawn[2][4], 0.85, 1e-9)
    eq(drawn[3][2], 0.7, "the weight column is not touched")
    eq(rawget(pane, "drawText"), nil, "taken off after the frame")
end)

test("a pane with no mission item draws as the game does", function()
    setup(regular())
    state.squares["100,100,0"] = square({})
    load()
    local pane = state.page.inventoryPane
    pane.inventory = container({ item(nil, "Pliers") }, furniture({}))
    pane.renderdetails = ISInventoryPane.renderdetails
    setmetatable(pane, { __index = ISInventoryPane })
    tick()
    eq(pane.oaTint, nil)
    pane:renderdetails()
    eq(#drawn, 3)
    eq(drawn[2][2], 1)
end)

test("the special request's container is lit beside the main mission's, each in its colour", function()
    local m = setup(regular())
    local sp = regular({ id = "M1-2", kind = "special" })
    sp.items[1].at = { x = 102, y = 100, z = 0 }
    state.record.missions.special = { mission = sp }
    local main = furniture({ container({ item("M1-1") }) })
    local other = furniture({ container({ item("M1-2") }) })
    state.squares["100,100,0"] = square({ main })
    state.squares["102,100,0"] = square({ other })
    load()
    tick()
    eq(main.on, true)
    eq(other.on, true)
    near(other.colour[1], 0.30, 1e-9)
    truthy(H.lit[0][main] and H.lit[0][other], "both told to the search ledger")
    sp.state = "sealed"
    tick()
    eq(main.on, true)
    eq(other.on, false, "a sealed request is not lit")
end)

test("the loot window paints the special request's item name too", function()
    setup(regular())
    local sp = regular({ id = "M1-2", kind = "special" })
    state.record.missions.special = { mission = sp }
    state.squares["100,100,0"] = square({})
    load()
    local pane = state.page.inventoryPane
    pane.inventory = container({ item("M1-2", "Filter Case"), item(nil, "Pliers") }, furniture({}))
    pane.renderdetails = ISInventoryPane.renderdetails
    setmetatable(pane, { __index = ISInventoryPane })
    tick()
    eq(type(pane.oaTint), "table")
    pane:renderdetails()
    eq(drawn[2][1], "Filter Case")
    near(drawn[2][2], 0.30, 1e-9)
end)

test("the container is walked once for what it holds, not at every look", function()
    local m = setup(regular())
    local items = { item("M1-1"), item(nil), item(nil) }
    local reads = 0     -- items read from the container (its size is no read)
    local box = container(items)
    box.getItems = function()
        local l = list(items)
        local get = l.get
        l.get = function(...) reads = reads + 1 return get(...) end
        return l
    end
    local desk = furniture({ box })
    state.squares["100,100,0"] = square({ desk })
    state.page.inventoryPane.inventory = box
    load()
    for _ = 1, 5 do tick() end
    eq(reads, 3, "five looks (the outline and the names both ask): the three items read once")
    eq(desk.on, true)
    items[#items + 1] = item("M1-1#B")
    for _ = 1, 3 do tick() end
    eq(reads, 3 + 4, "an item came: read again, once")
end)

test("with the API's timers the look is a timer, not a handler of OnTick, and goes with the mission", function()
    local m = setup(regular())
    local desk = furniture({ container({ item("M1-1") }) })
    state.squares["100,100,0"] = square({ desk })
    local timers, cancelled = {}, 0
    PZToolsAPI = { version = 1, client = function() return "h" end, timers = {
        every = function(handle, spec, fn)
            timers[#timers + 1] = { spec = spec, fn = fn }
            return #timers
        end,
        cancel = function(handle, id) cancelled = cancelled + 1 timers[id].gone = true return true end,
    } }
    load()
    H.update()
    local handlers = 0
    for _ in pairs(state.handlers) do handlers = handlers + 1 end
    eq(handlers, 0, "nothing wakes each frame")
    eq(timers[1].spec.ms, OA.StoryView.EVERY_MS)
    eq(timers[2].spec.once, true, "the first look at the next frame")
    eq(desk.on, false, "not looked at yet")
    timers[2].fn()
    eq(desk.on, true)
    desk.on = false
    timers[1].fn()
    eq(desk.on, true, "and at each period")
    local count = #timers
    H.update()
    eq(#timers, count, "updated again with the mission still open: the same timer")
    state.record.missions.active = nil
    H.update()
    eq(cancelled, 1, "the mission over: the timer cancelled")
    eq(desk.on, false, "and the outline taken back")
    PZToolsAPI = nil
end)
