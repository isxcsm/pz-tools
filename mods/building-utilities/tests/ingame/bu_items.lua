-- The furniture items of the box and the units, against the game's tiles: each look of a kind names the kind's item
-- (CustomItem, from the tile files: a box's look its tier's item), and an item made in the game weighs what its script
-- says (the game takes a furniture item's weight from its tile's CustomItem; a value the tile files never named reads as
-- another mod's item). "[buitems]" lines, each "ok" or "BAD", "done" at the end.
local BU = BuildingUtilities
local bad, looks = 0, 0
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[buitems] " .. table.concat(parts, " "))
end
local function check(what, got, want)
    if got ~= want then
        bad = bad + 1
        say("BAD", what, tostring(got), "want", tostring(want))
    end
end

local function looksNamed(names, item)
    for _, name in ipairs(names) do
        local sprite = getSprite(name)
        if sprite then
            looks = looks + 1
            check(name, sprite:getProperties():get("CustomItem"), item)
        end
    end
end
for _, kind in ipairs(BU.Units.KINDS) do
    local definition = BU.Units.definition(kind)
    if definition.item then looksNamed(definition.sprites or {}, definition.item) end
end
for tier, item in ipairs(BU.PANEL_ITEMS) do
    for _, outdoor in ipairs({ false, true }) do
        for _, look in pairs(BU.PanelLook.SPRITES[BU.PanelLook.variant(tier, outdoor)]) do looksNamed(look, item) end
    end
end
say("looks", looks)

-- the scripts' weights (Weight in scripts/BuildingUtilities.txt)
local WEIGHTS = { FireSprinkler = 1.5, Sprinkler = 2.0, BoosterPump = 18.0, BreakerBox = 7.0, BreakerBox2 = 15.0,
    BreakerBox3 = 19.0, BreakerBox4 = 34.0 }
for name, want in pairs(WEIGHTS) do
    local item = instanceItem("BuildingUtilities." .. name)
    check(name .. " weight", item and math.floor(item:getActualWeight() * 10 + 0.5) / 10, want)
end
say(bad == 0 and "done, all ok" or ("done, " .. bad .. " BAD"))
