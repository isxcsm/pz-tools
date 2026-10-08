-- The game-facing parts with fake game objects: Value.info, the pickup hook, kills, the daily step, the building watch.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Economy/Codex"
require "OperationAcorn/Economy/Buildings"
local OA = OperationAcorn

-- Fake Java: lists and the game's globals the adapters use.
local function list(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end, items = t }
end

local classes
function instanceof(object, class)
    return object ~= nil and object.classes ~= nil and object.classes[class] == true
end
ItemType = { MOVEABLE = "moveable" }

local function script(fullType, weight, display, moveable)
    return {
        getFullName = function() return fullType end,
        getActualWeight = function() return weight end,
        getDisplayCategory = function() return display end,
        isItemType = function(_, t) return moveable and t == "moveable" or false end,
    }
end

-- A fake inventory item. `o` overrides: weight, display, moveable, food ("fresh"|"stale"|"rotten"), uses (0..1 of a
-- drainable), condition, max, fluid, contents (a list of items), data (modData).
local function item(fullType, o)
    o = o or {}
    local it = { classes = {}, data = o.data, fullType = fullType }
    local weight = o.weight or 1.0
    it.getFullType = function() return fullType end
    it.getScriptItem = function() return script(fullType, o.scriptWeight or weight, o.display or "Junk", o.moveable) end
    it.isFluidContainer = function() return o.fluid or false end
    it.getActualWeight = function() return o.fluid and weight + 5 or weight end
    it.getDisplayCategory = function() return o.display or "Junk" end
    it.getCategory = function() return "Normal" end
    it.isItemType = function(_, t) return o.moveable and t == "moveable" or false end
    it.getConditionMax = function() return o.max or 10 end
    it.getCondition = function() return o.condition or (o.max or 10) end
    it.hasModData = function() return it.data ~= nil end
    it.getModData = function() it.data = it.data or {}; return it.data end
    it.getWorldItem = function() return o.world end
    if o.food then
        it.classes.Food = true
        it.isRotten = function() return o.food == "rotten" end
        it.isFresh = function() return o.food == "fresh" end
    end
    if o.uses then
        it.classes.DrainableComboItem = true
        it.getCurrentUsesFloat = function() return o.uses end
    end
    if o.contents then
        it.classes.InventoryContainer = true
        it.getInventory = function() return { getItems = function() return list(o.contents) end } end
    end
    return it
end

test("Value.info reads a plain item", function()
    local info = OA.Value.info(item("Base.Hammer", { weight = 1.2, display = "Tool" }))
    eq(info.fullType, "Base.Hammer"); eq(info.baseType, "Hammer")
    near(info.weight, 1.2, 1e-9)
    eq(info.displayCategory, "Tool")
    eq(info.moveable, false)
    near(info.condition, 1.0, 1e-9)
    eq(info.bought, nil); eq(info.cell, nil); eq(info.own, nil); eq(info.cash, nil)
end)

test("Value.info reads condition, drainables, food, containers and furniture", function()
    near(OA.Value.info(item("Base.Axe", { condition = 5 })).condition, 0.5, 1e-9)
    near(OA.Value.info(item("Base.Battery", { uses = 0.25 })).condition, 0.25, 1e-9)
    eq(OA.Value.info(item("Base.Apple", { food = "fresh" })).food, "fresh")
    eq(OA.Value.info(item("Base.Apple", { food = "stale" })).food, "stale")
    eq(OA.Value.info(item("Base.Apple", { food = "rotten" })).food, "rotten")
    eq(OA.Value.info(item("Base.Apple", { food = "fresh" })).condition, nil, "food has no condition")
    eq(OA.Value.info(item("Base.Satchel", { contents = {} })).filled, false)
    eq(OA.Value.info(item("Base.Satchel", { contents = { item("Base.Hammer") } })).filled, true)
    eq(OA.Value.info(item("Base.Sofa", { moveable = true })).moveable, true)
end)

test("Value.info counts a drink's container empty", function()
    local info = OA.Value.info(item("Base.WaterBottle", { weight = 0.1, fluid = true, scriptWeight = 0.1 }))
    near(info.weight, 0.1, 1e-9)
end)

test("Value.info reads cash, the mod's goods and the tags a shop or a pickup leaves", function()
    eq(OA.Value.info(item("Base.Money")).cash, 1)
    eq(OA.Value.info(item("Base.MoneyBundle")).cash, 100)
    eq(OA.Value.info(item("OperationAcorn.SampleBundle")).own, "SampleBundle")
    local info = OA.Value.info(item("Base.Hammer", { data = { OA_Bought = true, OA_Cell = "3,4" } }))
    eq(info.bought, true); eq(info.cell, "3,4")
    OA.Story = { missionExpired = function(id) return id == "old" end }
    eq(OA.Value.info(item("OperationAcorn.Note", { data = { OA_Mission = "m1" } })).own, "MissionItem")
    eq(OA.Value.info(item("OperationAcorn.Note", { data = { OA_Mission = "old" } })).own, "ExpiredMission")
end)

test("Value.infoFromScript", function()
    local info = OA.Value.infoFromScript(script("Base.Hat_BaseballCapTINT", 0.3, "Clothing", false))
    eq(info.baseType, "Hat_BaseballCap")
    eq(info.displayCategory, "Clothing")
    near(info.weight, 0.3, 1e-9)
    eq(OA.Value.infoFromScript(script("Base.Money", 0.01, "Junk", false)).cash, 1)
    eq(OA.Value.infoFromScript(script("Base.Sofa", 20, "Furniture", true)).moveable, true)
end)

test("a cell key is the 256-square cell", function()
    eq(OA.Value.cellKey(0, 0), "0,0")
    eq(OA.Value.cellKey(255.9, 256), "0,1")
    eq(OA.Value.cellKey(10500, 9800), "41,38")
end)

-- The economy's server file, with fake game events.
local function boot()
    require "OperationAcorn/Economy"
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
end

-- A container the fake transfer moves items between: items by list, `mine` when it is in the character's inventory.
local function container(kind, o)
    o = o or {}
    local c = { items = {} }
    c.getType = function() return kind end
    c.isInCharacterInventory = function() return o.mine or false end
    c.getSquare = function() return o.square end
    return c
end

local function square(x, y)
    return { getX = function() return x end, getY = function() return y end }
end

local function character(id)
    local data = { OA_Id = id }
    return { getModData = function() return data end, getInventory = function() return nil end }
end

test("a pickup from the world tags the cell and enters the codex", function()
    ISTransferAction = { transferItem = function(self, ch, it, src, dest, sq) return it end }
    boot()
    OA.Economy.start()
    local record = OA.Store.ensure("p", "P")
    local ch = character("p")
    local hammer = item("Base.Hammer", { display = "Tool" })
    local world = container("wardrobe", { square = square(1300, 600) })
    local pack = container("inventory", { mine = true })
    local result = ISTransferAction:transferItem(ch, hammer, world, pack, nil)
    eq(result, hammer, "the original's result comes back")
    eq(hammer.data.OA_Cell, "5,2")
    truthy(record.codex.kinds.Hammer)
    near(record.trade.bonus, 20)
end)

test("a pickup keeps the first cell an item was tagged with", function()
    ISTransferAction = { transferItem = function(self, ch, it) return it end }
    boot()
    OA.Economy.start()
    OA.Store.ensure("p", "P")
    local ch = character("p")
    local hammer = item("Base.Hammer", { data = { OA_Cell = "0,0" } })
    ISTransferAction:transferItem(ch, hammer, container("floor", { square = square(1300, 600) }),
        container("inventory", { mine = true }), nil)
    eq(hammer.data.OA_Cell, "0,0")
end)

test("moving things inside the pack, or onto the ground, is no pickup", function()
    ISTransferAction = { transferItem = function(self, ch, it) return it end }
    boot()
    OA.Economy.start()
    OA.Store.ensure("p", "P")
    local ch = character("p")
    local a = item("Base.Hammer")
    ISTransferAction:transferItem(ch, a, container("inventory", { mine = true }), container("bag", { mine = true }), nil)
    eq(a.data, nil)
    local b = item("Base.Hammer")
    ISTransferAction:transferItem(ch, b, container("inventory", { mine = true }),
        container("floor", { square = square(5, 5) }), nil)
    eq(b.data, nil)
    local c = item("Base.Hammer")
    ISTransferAction:transferItem(ch, c, container("TradeUI"), container("inventory", { mine = true }), nil)
    eq(c.data, nil)
    eq(OA.Store.player("p").codex, nil)
end)

test("a bag taken from the world tags what is in it too, and the codex counts it", function()
    ISTransferAction = { transferItem = function(self, ch, it) return it end }
    boot()
    OA.Economy.start()
    local record = OA.Store.ensure("p", "P")
    local ch = character("p")
    local inner = item("Base.Pencil", { display = "Junk" })
    local bag = item("Base.Satchel", { display = "Bag", contents = { inner } })
    ISTransferAction:transferItem(ch, bag, container("shelves", { square = square(300, 300) }),
        container("inventory", { mine = true }), nil)
    eq(bag.data.OA_Cell, "1,1")
    eq(inner.data.OA_Cell, "1,1")
    truthy(record.codex.kinds.Satchel and record.codex.kinds.Pencil)
end)

test("a failing bookkeeping step never breaks the game's transfer", function()
    local moved = false
    ISTransferAction = { transferItem = function(self, ch, it) moved = true; return it end }
    boot()
    OA.Economy.start()
    local ch = character("p")      -- no record: nothing to credit, and a broken item below
    local broken = { getFullType = function() error("boom") end, getWorldItem = function() return nil end }
    local result = ISTransferAction:transferItem(ch, broken, container("shelves", { square = square(1, 1) }),
        container("inventory", { mine = true }), nil)
    truthy(moved)
    eq(result, broken)
end)

test("a kill by a player counts for that player", function()
    boot()
    local record = OA.Store.ensure("k", "K")
    local killer = character("k")
    killer.classes = { IsoPlayer = true }
    for i = 1, 100 do
        TEST.fire("OnZombieDead", { getAttackedBy = function() return killer end })
    end
    eq(record.codex.kills, 100)
    near(record.trade.bonus, 2000)
    TEST.fire("OnZombieDead", { getAttackedBy = function() return nil end })
    TEST.fire("OnZombieDead", { getAttackedBy = function() return { classes = {} } end })
    eq(record.codex.kills, 100, "a death with no player behind it counts for none")
end)

test("the daily step moves the market and draws the week's lists", function()
    boot()
    OA.randomFloat = function() return 0 end
    local record = OA.Store.ensure("d", "D")
    OA.Requests.install({ version = 1, types = { "Base.A", "Base.B", "Base.C", "Base.D", "Base.E", "Base.F", "Base.G" },
        score = { 2, 2, 2, 2, 2, 2, 2 }, kinds = {}, total = {}, n = 7 })
    TEST.hours = 24 * 7 + 1
    TEST.fire("EveryDays")
    eq(OA.Market.state().day, OA.day())
    eq(record.codex.req.week, 1)
    eq(#record.codex.req.items, 6)
end)

test("the ten minute look over the pack finds kinds a pickup missed", function()
    boot()
    local record = OA.Store.ensure("t", "T")
    local crafted = item("Base.Rope", { display = "Tool" })
    local inBag = item("Base.Pencil")
    local bag = item("Base.Satchel", { display = "Bag", contents = { inBag } })
    local ch = character("t")
    ch.getInventory = function() return { getItems = function() return list({ crafted, bag }) end } end
    getOnlinePlayers = function() return list({ ch }) end
    isServer = function() return true end
    TEST.fire("EveryTenMinutes")
    truthy(record.codex.kinds.Rope and record.codex.kinds.Satchel and record.codex.kinds.Pencil)
    eq(record.codex.n, 3)
    TEST.fire("EveryTenMinutes")
    eq(record.codex.n, 3, "nothing new the second time")
end)

-- A fake building for the watch: rooms of squares with container objects.
local function box(explored)
    local c = {}
    c.isExplored = function() return explored end
    c.set = function(v) explored = v end
    return c
end

local function fakeObject(containers, thumpable)
    return {
        classes = { IsoThumpable = thumpable or nil },
        getContainerCount = function() return #containers end,
        getContainerByIndex = function(_, i) return containers[i + 1] end,
    }
end

local function fakeBuilding(roomsOfSquares, loaded)
    local isoRooms, defs = {}, {}
    for _, squares in ipairs(roomsOfSquares) do
        local iso = { getSquares = function() return list(squares) end }
        table.insert(isoRooms, iso)
        table.insert(defs, { getIsoRoom = function() return iso end })
    end
    local def = {
        getRooms = function() return list(defs) end, isFullyStreamedIn = function() return loaded ~= false end,
        getX = function() return 700 end, getY = function() return 800 end,
    }
    local building = { getDef = function() return def end }
    local rooms = {}
    for i = 1, #roomsOfSquares do rooms[i] = { getBuilding = function() return building end } end
    return rooms
end

local function sq(objects)
    return { getObjects = function() return list(objects) end }
end

local function walker(room)
    local at = { room = room }
    return {
        getPlayerNum = function() return 0 end,
        getModData = function() return { OA_Id = "w" } end,
        getCurrentSquare = function()
            return { getRoom = function() return at.room end, getX = function() return 10 end,
                getY = function() return 10 end, getZ = function() return 0 end }
        end,
        move = function(_, r) at.room = r end,
    }
end

test("the building watch counts containers once and asks each if it was opened", function()
    OA.Buildings.reset()
    local a, b, c = box(false), box(false), box(false)
    local rooms = fakeBuilding({ { sq({ fakeObject({ a }) }), sq({ fakeObject({ b, c }) }) } })
    local w = walker(rooms[1])
    local key, searched, total, complete = OA.Buildings.tick(w)
    eq(key, "v:700,800"); eq(searched, 0); eq(total, 3); eq(complete, true)
    a.set(true); b.set(true)
    key, searched, total = OA.Buildings.tick(w)
    eq(searched, 2); eq(total, 3)
    c.set(true)
    key, searched, total = OA.Buildings.tick(w)
    eq(searched, 3)
    w:move(nil)
    eq(OA.Buildings.tick(w), nil, "outside")
end)

test("containers the player built are not counted", function()
    OA.Buildings.reset()
    local a, mine = box(false), box(false)
    local rooms = fakeBuilding({ { sq({ fakeObject({ a }), fakeObject({ mine }, true) }) } })
    local _, _, total = OA.Buildings.tick(walker(rooms[1]))
    eq(total, 1)
end)

test("a building with a square not loaded is not complete", function()
    OA.Buildings.reset()
    local rooms = fakeBuilding({ { sq({ fakeObject({ box(true) }) }) } }, false)
    local _, searched, total, complete = OA.Buildings.tick(walker(rooms[1]))
    eq(complete, false)
    eq(searched, 1)
end)

test("all containers searched pays the building once, from the minute check", function()
    boot()
    OA.Buildings.reset()
    local record = OA.Store.ensure("w", "W")
    local boxes = { box(true), box(true), box(false) }
    local rooms = fakeBuilding({ { sq({ fakeObject({ boxes[1], boxes[2] }) }), sq({ fakeObject({ boxes[3] }) }) } })
    local w = walker(rooms[1])
    isServer = function() return false end
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return w end
    w.isDead = function() return false end
    w.getModData = function() return { OA_Id = "w" } end
    TEST.fire("EveryOneMinute")
    eq(record.codex and record.codex.nb or 0, 0)
    local searched, total = OA.Codex.buildingProgress(record, "v:700,800")
    eq(searched, 2); eq(total, 3)
    boxes[3].set(true)
    TEST.fire("EveryOneMinute")
    eq(record.codex.nb, 1)
    near(record.trade.bonus, 130, 1e-9, "100 + 10 per container x 3")
    TEST.fire("EveryOneMinute")
    eq(record.codex.nb, 1, "only once")
    searched, total = OA.Codex.buildingProgress(record, "v:700,800")
    eq(searched, 3); eq(total, 3)
end)

test("a building that was not fully loaded does not pay", function()
    boot()
    OA.Buildings.reset()
    local record = OA.Store.ensure("w", "W")
    local rooms = fakeBuilding({ { sq({ fakeObject({ box(true) }) }) } }, false)
    local w = walker(rooms[1])
    w.isDead = function() return false end
    w.getModData = function() return { OA_Id = "w" } end
    isServer = function() return false end
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return w end
    TEST.fire("EveryOneMinute")
    eq(record.codex and record.codex.nb or 0, 0)
end)

test("the API, when there, names the building and lists its rooms", function()
    OA.Buildings.reset()
    local a, b = box(true), box(false)
    local squares = {
        ["10,10,0"] = sq({ fakeObject({ a }) }), ["11,10,0"] = sq({ fakeObject({ b }) }),
        ["10,10,1"] = sq({}),
    }
    getCell = function()
        return { getGridSquare = function(_, x, y, z) return squares[x .. "," .. y .. "," .. z] end }
    end
    PZToolsAPI = {
        version = 1,
        client = function() return {} end,
        buildings = {
            at = function(x, y, z) return { key = "10,10,0", playerBuilt = false } end,
            rooms = function(key)
                return { { id = 1, name = "kitchen", level = 0, rects = { { x = 10, y = 10, w = 2, h = 1 } } },
                    { id = 2, name = "bedroom", level = 1, rects = { { x = 10, y = 10, w = 1, h = 1 } } } }
            end,
        },
    }
    local w = walker({})
    local key, searched, total, complete = OA.Buildings.tick(w)
    eq(key, "10,10,0"); eq(total, 2); eq(searched, 1); eq(complete, true)
    squares["11,10,0"] = nil
    OA.Buildings.reset()
    key, searched, total, complete = OA.Buildings.tick(w)
    eq(complete, false, "a square that is not loaded")
    PZToolsAPI.buildings.at = function() return { key = "10,10,0", playerBuilt = true } end
    OA.Buildings.reset()
    eq(OA.Buildings.tick(w), nil, "a player-built building is never counted")
    PZToolsAPI = nil
end)
