-- A box's window on a modest house for the tests and the bench that take the window up (window_test.lua,
-- tests/bench/window_bench.lua): five rooms, thirteen devices on the power and the water tabs, a few units wired to a
-- box of tier 4. The game's UI classes are stood in for by widgets that keep their place and do nothing else; the
-- mod's own code, the shared UI kit and the window's data are the real ones, the API's answers stubbed. Loaded by
--   local Scene = loadstring(readfile("tests/unit/window_scene.lua"), "window_scene.lua")()
-- (not a test of its own: the harness runs only *_test.lua). Scene.open() gives the window and its box; the Java
-- side's calls are counted in TEST.javaCalls (getText, text widths).
local Scene = {}
local BU

-- Names an element has that are fields (nil), though they read like methods.
local FIELD = { closeButton = true, pinButton = true, collapseButton = true, infoButton = true, resizeWidget = true,
    resizeWidget2 = true, closeBox = true }
-- The first words of the game's method names (setX, getY, isZ, addChild ...): any other name an element does not have
-- is a field, nil.
local METHOD = { set = true, get = true, is = true, has = true, add = true, remove = true, draw = true, bring = true,
    resize = true, close = true, clear = true, can = true, hide = true, show = true, un = true, on = true, update = true,
    reset = true, move = true, scroll = true, make = true, stop = true, start = true, activate = true, enable = true,
    disable = true, select = true, highlight = true, mouse = true, focus = true, ensure = true, ["do"] = true }

-- The game's elements: a place and a size, children, a list's items; every other method does nothing.
local function widgets()
    local noop = function() end
    local Element
    local function derive(base, name)
        local class = {}
        class.__index = class
        class.derive = function(self, derivedName) return derive(self, derivedName) end
        setmetatable(class, { __index = function(_, key)
            local v = base and base[key]
            if v == nil and type(key) == "string" and key:find("^[a-z]+%u") and METHOD[key:match("^[a-z]+")] and not FIELD[key] then
                return noop
            end
            return v
        end })
        if name then _G[name] = class end
        return class
    end
    Element = derive(nil)
    function Element.new(self, x, y, w, h)
        return setmetatable({ x = x or 0, y = y or 0, width = w or 0, height = h or 0, children = {}, items = {},
            count = 0, scroll = 0 }, self)
    end
    function Element:getX() return self.x end
    function Element:getY() return self.y end
    function Element:getWidth() return self.width end
    function Element:getHeight() return self.height end
    function Element:setX(x) self.x = x end
    function Element:setY(y) self.y = y end
    function Element:setWidth(w) self.width = w end
    function Element:setHeight(h) self.height = h end
    function Element:addChild(child) self.children[#self.children + 1] = child; child.parent = self end
    function Element:setVisible(v) self.visible = v end
    function Element:getIsVisible() return self.visible ~= false end
    function Element:isVisible() return self.visible ~= false end
    function Element:isMouseOver() return false end
    function Element:getYScroll() return self.scroll end
    function Element:setYScroll(y) self.scroll = y end
    function Element:getScrollHeight() return self.scrollHeight or 0 end
    function Element:setScrollHeight(h) self.scrollHeight = h end
    function Element:update() end
    function Element:prerender() end
    function Element:render() end
    function Element:initialise() self:createChildren() end
    function Element:instantiate() end
    function Element:createChildren() end
    function Element:getText() return self.text or "" end
    function Element:setText(t) self.text = t end
    function Element:addItem(name, item, tooltip)
        local i = { text = name, item = item, tooltip = tooltip, itemindex = self.count + 1, height = self.itemheight or 22 }
        self.items[#self.items + 1] = i
        self.count = self.count + 1
        self:setScrollHeight(self:getScrollHeight() + i.height)
        return i
    end
    function Element:clear() self.items, self.count, self.scrollHeight = {}, 0, 0 end
    ISUIElement = Element
    ISPanel = derive(Element, "ISPanel")
    ISButton = derive(Element, "ISButton")
    ISScrollingListBox = derive(Element, "ISScrollingListBox")
    ISCollapsableWindow = derive(Element, "ISCollapsableWindow")
    function ISCollapsableWindow:setTitle(t) self.title = t end
    ISTextEntryBox = derive(Element, "ISTextEntryBox")
    function ISTextEntryBox.new(self, text, x, y, w, h)
        local o = Element.new(self, x, y, w, h)
        o.text = text
        return o
    end
    ISBaseTimedAction = derive(Element, "ISBaseTimedAction")
    function ISBaseTimedAction.new(self) return setmetatable({}, self) end
end

-- The game's functions the window and the kit call.
local function game()
    UIFont = setmetatable({}, { __index = function(_, k) return k end })
    Texture = { getWhite = function() return {} end }
    getTexture = function() return { getWidth = function() return 16 end, getHeight = function() return 16 end } end
    local counts = { measure = 0, getText = 0 }
    TEST.javaCalls = counts
    getTextManager = function()
        return { getFontHeight = function() return 16 end,
            MeasureStringX = function(_, _, text) counts.measure = counts.measure + 1; return #text * 7 end,
            MeasureStringY = function() return 16 end }
    end
    getCore = function()
        return { getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end,
            getOptionFontSize = function() return 2 end, getOptionUIRenderOffscreen = function() return false end }
    end
    getPlayerData = function() return nil end
    Translator = { getMoveableDisplayName = function(o) return o.name end }
    getItemNameFromFullType = function() return "Generator" end
    getSpecificPlayer = function() return TEST.player end
    -- the texts the game gives are a call into Java: counted
    local plain = getText
    getText = function(...) counts.getText = counts.getText + 1; return plain(...) end
    getNumActivePlayers = function() return 1 end
    getClimateManager = function()
        return { getTemperature = function() return 5 end, getDayLightStrength = function() return 0.6 end,
            getAirTemperatureForSquare = function() return 5 end, getSnowStrength = function() return 0 end,
            getPrecipitationIntensity = function() return 0 end, isSnowing = function() return false end,
            getSeason = function() return { getDawn = function() return 6 end, getDusk = function() return 20 end } end }
    end
    -- the character: beside the box, with what a cost asks for in the pack (the inventory's scans are counted)
    TEST.scans = 0
    TEST.player = { getX = function() return 305 end, getY = function() return 302 end, getZ = function() return 0 end,
        isDead = function() return false end, getPlayerNum = function() return 0 end,
        getInventory = function()
            return { getItems = function() return TEST_javaList({}) end,
                containsTypeRecurse = function() return false end,
                getFirstTagEvalRecurse = function() TEST.scans = TEST.scans + 1; return {} end,
                getCountTypeEvalArgRecurse = function() TEST.scans = TEST.scans + 1; return 10 end,
                getCountTypeRecurse = function() return 0 end,
                getAllEvalRecurse = function() return TEST_javaList({}) end }
        end,
        getModData = function() return {} end, getPerkLevel = function() return 10 end }
    -- the game's clock, a millisecond a call (the tests move it on; a slice of no time ends with the item it is in)
    TEST.now = 2000000000
    getTimestampMs = function()
        TEST.now = TEST.now + 1
        return TEST.now
    end
    ItemTag = setmetatable({}, { __index = function(_, k) return k end })
    Perks = { Electricity = "Electricity" }
end

-- A house of five rooms; devices in them, on the API's lists and on the squares.
local function house()
    local api = TEST.api
    local key = "300,300,0"
    local rooms = {}
    local names = { "kitchen", "livingroom", "bedroom", "bathroom", "garage" }
    for i, name in ipairs(names) do
        rooms[#rooms + 1] = { id = "r" .. i, name = name, level = 0, rects = { { x = 300 + (i - 1) * 4, y = 300, w = 4, h = 6 } } }
    end
    api.buildingsByKey[key] = {
        building = { key = key, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = 300, minY = 300, maxX = 319, maxY = 305,
            room = "kitchen", roomId = "r1" },
        rooms = rooms, attached = {}, attachedObjects = { power = {}, water = {} },
        objects = { power = {}, water = {} },
    }
    for x = 300, 319 do
        for y = 300, 305 do api.squares[x .. "," .. y .. ",0"] = key end
    end
    api.table.buildings.name = function(object) return object.name end
    local function place(utility, room, x, y, sprite, power)
        local entry = { x = x, y = y, z = 0, sprite = sprite, roomId = "r" .. room, power = power, type = "IsoObject" }
        local list = api.buildingsByKey[key].objects[utility]
        list[#list + 1] = entry
        local square = TEST.squares[x .. "," .. y .. ",0"]
        if not square then
            square = { objects = {}, room = names[room] }
            TEST.squares[x .. "," .. y .. ",0"] = square
        end
        -- a square holds a floor and the device
        square.objects[#square.objects + 1] = { name = "floor", hasSpriteGrid = function() return false end,
            getSprite = function() return { getName = function() return "floors_01" end } end,
            getSquare = function() return nil end, getObjectName = function() return "IsoObject" end }
        local object = { name = sprite, hasSpriteGrid = function() return false end,
            getSprite = function() return { getName = function() return sprite end } end,
            getObjectName = function() return "IsoObject" end,
            getModData = function() return {} end, hasModData = function() return false end }
        object.getSquare = function() return { getX = function() return x end, getY = function() return y end,
            getZ = function() return 0 end } end
        square.objects[#square.objects + 1] = object
    end
    local sprites = { "appliances_refrigeration_01_0", "lighting_indoor_01_0", "appliances_television_01_0",
        "appliances_cooking_01_0", "lighting_indoor_01_8", "appliances_laundry_01_0" }
    for i = 1, 8 do
        place("power", 1 + BU.remainder(i, 5), 300 + i, 301, sprites[1 + BU.remainder(i, #sprites)] .. i, 0.02 * i)
    end
    for i = 1, 5 do place("water", 1 + BU.remainder(i, 5), 300 + i, 303, "fixtures_sinks_01_" .. i, nil) end
    return key
end

local function sprite(kind) return BU.Units.definition(kind).sprites[1] end

-- The box with a generator, two solar panels, a rack with batteries, a pump and a sprinkler, each on its line (the
-- lines written into the save, as the scale bench does).
local function wired(Store, x, y)
    local panel = Store.newPanel(x, y, 0, BU.panelSprite("S"))
    panel.tier = 3
    local data = Store.data()
    local function lay(ref, utility, lx, ly)
        local wx, wy = math.max(300, math.min(319, lx)), math.max(300, math.min(305, ly))
        data.lines[ref] = { ref = ref, panel = panel.id, utility = utility, wall = BU.placeKey(wx, wy, 0),
            length = math.max(math.abs(lx - wx), math.abs(ly - wy)), paid = {}, x = lx, y = ly, z = 0, seq = data.nextLine }
        data.nextLine = data.nextLine + 1
    end
    panel.power.producers = { { x = 322, y = 300, z = 0 } }
    lay(BU.Links.producerRef(322, 300, 0), "power", 322, 300)
    local function unit(kind, dx, dy, prepare)
        local made = Store.newUnit(kind, 320 + dx, 300 + dy, 0, sprite(kind))
        if prepare then prepare(made) end
        made.panel = panel.id
        lay(BU.Links.unitRef(made), BU.Units.utility(made), 320 + dx, 300 + dy)
        return made
    end
    for s = 0, 1 do unit("solar", 2, s) end
    unit("rack", 3, 1, function(rack)
        rack.batteries = {}
        for b = 1, 4 do rack.batteries[b] = { id = b, type = "Base.CarBattery1", charge = 0.6, condition = 90 } end
    end)
    unit("pump", 2, 4, function(pump) pump.fluid = "TaintedWater" end)
    unit("sprinkler", 3, 5)
    Store.unitsChanged()
    return panel
end

-- Opens the window on the house; returns it with its box. Every network is supplied by its generator, the load a
-- house's. The clock is TEST.now, moved on a millisecond by every look at it.
function Scene.open()
    ISMoveableSpriteProps = {
        new = function() return {} end,
        canPickUpMoveable = function() end, pickUpMoveable = function() end, canPlaceMoveable = function() end,
        placeMoveable = function() end, canRotateMoveable = function() end, getInfoPanelDescription = function() end,
    }
    TEST.gameFile("Moveables/ISMoveableSpriteProps")
    widgets()
    game()
    local real = require
    require = function(name)
        if name:find("^ISUI/") or name:find("^TimedActions/") or name:find("^Moveables/") or name:find("^Vehicles/") then
            return true
        end
        return real(name)
    end
    require "BuildingUtilities/Changes"
    BU = BuildingUtilities
    house()
    TEST.api.table.networks.state = function()
        return { load = 0.3, supplied = true, enabled = true, producers = {}, hoursLeft = 20, amount = 400,
            capacity = 800, fuelPerHour = 0.2 }
    end
    local panel = wired(BU.Store, 301, 302)
    require "BuildingUtilities/RackWindow"
    require "BuildingUtilities/Titles"
    require "BuildingUtilities/PanelWindow"
    require "BuildingUtilities/PanelZones"
    require "BuildingUtilities/PanelStatus"
    require "BuildingUtilities/PanelWater"
    require "BuildingUtilities/PanelSources"
    -- the manual's text is typeset by the kit (the window's other parts are what is taken up here)
    ISBUManual.show = function(self, key) self.key = key end
    local window = BU.PanelWindow.open(TEST.player, panel)
    return window, panel
end

return Scene
