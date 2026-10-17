-- A thing pointed out to a character for a while, the way the game's tutorial does it: an object in the world gets the
-- game's outline (Spotlight.object), an item's line in the loot window blinks (Spotlight.lootLine). Each goes by itself:
--   * an outline when its time is up, the character has walked further than its reach from it (or is gone), the
--     object is no longer in the world (taken up, destroyed), or the character has touched it (the world menu opened
--     over its square);
--   * a line when its time is up, or another has taken the loot window's blink.
-- Nothing runs while nothing is pointed out; while something is, one function of OnTick compares the clock, and looks
-- at the rest every CHECK_MS.
PZUIKit = PZUIKit or {}
local Spotlight = {}
PZUIKit.Spotlight = Spotlight

-- How long a thing stays pointed out, by default, and how often the rest is looked at, in milliseconds.
Spotlight.MS = 20000
Spotlight.CHECK_MS = 250
-- The outline's colour by default: white.
Spotlight.COLOR = { 1, 1, 1, 1 }

-- The outlines, by the player's number: object -> { untilMs, x, y, reach, square }.
local outlines = {}
-- The loot lines, by the player's number: { untilMs, type, pane }.
local lines = {}
-- The tick handler, once added, stays (`hooked`: one taken off inside its event makes the game skip the next one that
-- tick) and returns at once while nothing is pointed out (`watching`).
local watching, hooked = false, false
local checkedAt = 0

local function unlight(playerNum, object)
    object:setOutlineHighlight(playerNum, false)
    outlines[playerNum][object] = nil
end

local function gone(object)
    return object:getSquare() == nil or object:getObjectIndex() < 0
end

local function far(player, spot)
    return spot.reach ~= nil and (math.abs(player:getX() - spot.x) > spot.reach or math.abs(player:getY() - spot.y) > spot.reach)
end

local watch
local function start()
    if watching then return end
    watching = true
    checkedAt = 0
    if not hooked then
        hooked = true
        Events.OnTick.Add(watch)
    end
end

-- Ends what has had its time (each tick: a clock compared), and, every CHECK_MS, what has lost its reason.
watch = function()
    if not watching then return end
    local now = getTimestampMs()
    local full = now - checkedAt >= Spotlight.CHECK_MS
    if full then checkedAt = now end
    local any = false
    -- (what ends is gathered first, and ended after: a table is not changed while it is gone through)
    local ending
    for playerNum, spots in pairs(outlines) do
        local player = full and getSpecificPlayer(playerNum)
        for object, spot in pairs(spots) do
            if now >= spot.untilMs or (full and (not player or far(player, spot) or gone(object))) then
                ending = ending or {}
                ending[#ending + 1] = { playerNum, object }
            else
                any = true
            end
        end
    end
    for _, each in ipairs(ending or {}) do unlight(each[1], each[2]) end
    local over
    for playerNum, line in pairs(lines) do
        if line.pane.highlightItem ~= line.type or now >= line.untilMs then
            over = over or {}
            over[#over + 1] = playerNum
        else
            any = true
        end
    end
    for _, playerNum in ipairs(over or {}) do
        local line = lines[playerNum]
        if line.pane.highlightItem == line.type then line.pane.highlightItem = nil end
        lines[playerNum] = nil
    end
    if not any then watching = false end
end

-- Outlines an object for the character with this player number. opts (all optional): color { r, g, b[, a] }, ms (how
-- long), reach (in squares: the outline goes once the character is further than this from the object, on x or y).
function Spotlight.object(playerNum, object, opts)
    opts = opts or {}
    local color = opts.color or Spotlight.COLOR
    object:setOutlineHighlightCol(playerNum, color[1], color[2], color[3], color[4] or 1)
    object:setOutlineHighlight(playerNum, true)
    local square = object:getSquare()
    outlines[playerNum] = outlines[playerNum] or {}
    outlines[playerNum][object] = { untilMs = getTimestampMs() + (opts.ms or Spotlight.MS), reach = opts.reach,
        x = square:getX(), y = square:getY(), square = square }
    start()
end

-- Ends an object's outline before its time (nothing when it has none from here).
function Spotlight.stop(playerNum, object)
    local spots = outlines[playerNum]
    if spots and spots[object] then unlight(playerNum, object) end
end

-- Whether an object is outlined from here for the character.
function Spotlight.isLit(playerNum, object)
    local spots = outlines[playerNum]
    return spots ~= nil and spots[object] ~= nil
end

-- Blinks the line of the items of this type (an item's getType) in the character's loot window, for ms (optional).
function Spotlight.lootLine(playerNum, itemType, ms)
    local page = getPlayerLoot(playerNum)
    local pane = page and page.inventoryPane
    if not pane then return end
    pane.highlightItem = itemType
    lines[playerNum] = { untilMs = getTimestampMs() + (ms or Spotlight.MS), type = itemType, pane = pane }
    start()
end

-- The character touched an outlined object: the world menu opened over its square.
local function onMenu(playerNum, _, worldobjects, test)
    if test then return end
    local spots = outlines[playerNum]
    if not spots then return end
    local touched = {}
    for object, spot in pairs(spots) do
        for _, clicked in ipairs(worldobjects) do
            if clicked:getSquare() == spot.square then
                touched[#touched + 1] = object
                break
            end
        end
    end
    for _, object in ipairs(touched) do unlight(playerNum, object) end
end
Spotlight.onMenu = onMenu

Events.OnFillWorldObjectContextMenu.Add(onMenu)

return Spotlight
