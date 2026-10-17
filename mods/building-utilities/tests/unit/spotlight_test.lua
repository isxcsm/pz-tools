-- The UI kit's spotlight (PZUIKit.Spotlight) as the first find of a box points one out: an outline that goes by its
-- time, by the character walking off, by the object leaving the world, or by the world menu opened over its square;
-- a loot line that blinks for a while unless another takes the blink; and nothing running once all is over.
local now, ticks, events, reads

local function load()
    now, reads = 0, 0
    getTimestampMs = function()
        reads = reads + 1
        return now
    end
    ticks, events = {}, {}
    Events = setmetatable({}, { __index = function(t, name)
        local e = {
            Add = function(fn)
                if name == "OnTick" then ticks[fn] = true else events[name] = fn end
            end,
            Remove = function(fn) if name == "OnTick" then ticks[fn] = nil end end,
        }
        rawset(t, name, e)
        return e
    end })
    require "PZUIKit/Spotlight"
    return PZUIKit.Spotlight
end

local function tick()
    local list = {}
    for fn in pairs(ticks) do list[#list + 1] = fn end
    for _, fn in ipairs(list) do fn() end
end

-- The tick handlers that do something on a tick (read the clock): a handler stays once added, idle when nothing is
-- pointed out; never more than one.
local function ticking()
    local n, working = 0, 0
    for fn in pairs(ticks) do
        n = n + 1
        local before = reads
        fn()
        if reads > before then working = working + 1 end
    end
    assert(n <= 1, "one tick handler at most")
    return working
end

local function square(x, y) return { getX = function() return x end, getY = function() return y end } end

-- An object on a square: lit tells whether its outline is on; `index` -1 once it has left the world.
local function object(sq)
    local o = { lit = false, index = 0 }
    o.getSquare = function() return sq end
    o.getObjectIndex = function() return o.index end
    o.setOutlineHighlightCol = function(_, _, r) o.r = r end
    o.setOutlineHighlight = function(_, _, on) o.lit = on end
    return o
end

local function player(x, y)
    local p = { x = x, y = y }
    p.getX = function() return p.x end
    p.getY = function() return p.y end
    getSpecificPlayer = function() return p end
    return p
end

test("an outline goes by its time, and the watch with it", function()
    local Spotlight = load()
    player(0, 0)
    local box = object(square(1, 1))
    Spotlight.object(0, box, { ms = 1000 })
    truthy(box.lit)
    eq(ticking(), 1)
    now = 999
    tick()
    truthy(box.lit, "still lit before its time")
    now = 1000
    tick()
    eq(box.lit, false)
    eq(ticking(), 0, "nothing runs once nothing is pointed out")
end)

test("an outline goes once the character walks past its reach, or the object leaves the world", function()
    local Spotlight = load()
    local p = player(0, 0)
    local box = object(square(1, 1))
    Spotlight.object(0, box, { reach = 8 })
    p.x = 10
    now = 100
    tick()
    truthy(box.lit, "between full looks only the clock is compared")
    now = Spotlight.CHECK_MS
    tick()
    eq(box.lit, false, "9 squares off on x (10 against 1) is past 8")
    p.x = 0
    local other = object(square(2, 2))
    Spotlight.object(0, other)
    other.index = -1
    now = now + Spotlight.CHECK_MS
    tick()
    eq(other.lit, false, "taken up")
    eq(Spotlight.isLit(0, other), false)
end)

test("an outline goes when the world menu opens over its square, not over another", function()
    local Spotlight = load()
    player(0, 0)
    local at = square(1, 1)
    local box = object(at)
    Spotlight.object(0, box)
    local fill = events.OnFillWorldObjectContextMenu
    fill(0, {}, { object(square(3, 3)) }, false)
    truthy(box.lit, "another square")
    fill(0, {}, { object(at) }, true)
    truthy(box.lit, "the controller's test pass is no touch")
    fill(1, {}, { object(at) }, false)
    truthy(box.lit, "another player's menu")
    fill(0, {}, { object(at) }, false)
    eq(box.lit, false)
end)

test("a loot line blinks for its time, and is left alone once another takes the blink", function()
    local Spotlight = load()
    local pane = {}
    getPlayerLoot = function() return { inventoryPane = pane } end
    Spotlight.lootLine(0, "BreakerBox", 1000)
    eq(pane.highlightItem, "BreakerBox")
    now = 1000
    tick()
    eq(pane.highlightItem, nil)
    eq(ticking(), 0)
    Spotlight.lootLine(0, "BreakerBox", 1000)
    pane.highlightItem = "Generator"
    tick()
    eq(pane.highlightItem, "Generator", "another's blink is not taken away")
    eq(ticking(), 0)
end)
