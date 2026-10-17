-- What the mod adds to loot (BU.Loot), in the running game: each item of its kind of loot (PZExtAPI.loot) and its
-- modifier the mod's option as the game reads it (ItemPickerJava.getLootModifier), at 0 while its feature is off;
-- its items in the game's lists; then the game's own roll of a technical room's list (GeneratorRoom) BULOOT_N times
-- (default 2000) at a high option, its boxes counted against the chance, the boxes' container owner marked and the
-- filters' media spent (the items' ItemConfig). Needs no scene; puts the options back as it found them.
-- "[buloot]" lines, each check "ok" or "BAD".
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Loot = BU.Loot
local say = BUT.say("buloot")
if not Loot then say("BAD no BU.Loot: server/BuildingUtilities/Loot.lua is not loaded"); return end
local api = PZExtAPI
if not (api and api.loot) then say("BAD no PZExtAPI.loot"); return end
local bad = 0
local function check(what, got, want)
    if got ~= want then bad = bad + 1 end
    say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want))
end
local function near(a, b) return math.abs(a - b) < 1e-4 end

-- The game's own options (what the hooks read), set and put back.
local options = getSandboxOptions()
local saved = {}
local function set(name, value)
    local option = options:getOptionByName("BuildingUtilities." .. name)
    if saved[name] == nil then saved[name] = option:getValue() end
    option:setValue(value)
end

-- Each item: of its kind, by the kind's option.
for _, kind in ipairs(Loot.KINDS) do
    for item in pairs(kind.items) do
        check("kind of " .. item, api.loot.kindOf(item), "BuildingUtilities:" .. kind.id)
        check("game's kind of " .. item, getScriptManager():FindItem(item):getLootType(), "BuildingUtilities:" .. kind.id)
    end
end
set("WaterLoot", 1.5)
check("modifier: filter at WaterLoot 1.5", near(ItemPickerJava.getLootModifier("BuildingUtilities.WaterFilter"), 1.5), true)
set("WaterLoot", 0)
check("modifier: filter at WaterLoot 0", ItemPickerJava.getLootModifier("BuildingUtilities.WaterFilter"), 0)
set("WaterLoot", 0.6)
set("EnableFilters", false)
check("filters off: filter", ItemPickerJava.getLootModifier("BuildingUtilities.WaterFilter"), 0)
check("filters off: vol. 2 still (boosters)", ItemPickerJava.getLootModifier("BuildingUtilities.WaterSystemsMag2") > 0, true)
set("EnableBoosters", false)
set("EnableFireSprinklers", false)
check("filters, boosters, fire sprinklers off: vol. 2", ItemPickerJava.getLootModifier("BuildingUtilities.WaterSystemsMag2"), 0)
set("EnableFilters", true); set("EnableBoosters", true); set("EnableFireSprinklers", true)
set("EnablePower", false)
check("power off: solar panel", ItemPickerJava.getLootModifier("BuildingUtilities.SolarPanel"), 0)
check("power off: box (water on)", near(ItemPickerJava.getLootModifier("BuildingUtilities.BreakerBox"), options:getOptionByName("BuildingUtilities.BreakerBoxLoot"):getValue()), true)
set("EnablePower", true)
check("game's kinds untouched: generator", ItemPickerJava.getLootModifier("Base.Generator") > 0, true)

-- In the game's lists.
local room = ProceduralDistributions.list.GeneratorRoom.items
local weights = {}
for i = 1, #room - 1, 2 do weights[room[i]] = room[i + 1] end
check("technical room list: box", weights["BuildingUtilities.BreakerBox"], 2)
check("technical room list: board", weights["BuildingUtilities.ControlBoard"], 4)

-- The game's roll: a technical room's list into a container held by an object, many times.
local picker = ItemPickerJava.getItemContainer("technical", "other", "GeneratorRoom", false)
if not picker then say("BAD no picker for the technical room's list") else
    set("BreakerBoxLoot", 4)
    set("WaterLoot", 4)
    local player = getPlayer()
    local square = player:getCurrentSquare()
    local holder = IsoObject.new(getCell(), square, "carpentry_01_16")
    local container = ItemContainer.new("crate", square, holder)
    container:setCapacity(1000)
    local n, boxes, withBox, marked, filters, used = BULOOT_N or 2000, 0, 0, 0, 0, 0
    local started = getTimestampMs()
    for _ = 1, n do
        container:removeAllItems()
        holder:getModData()[BU.BOX_MARK] = nil
        ItemPickerJava.rollItem(picker, container, true, player, nil)
        local items = container:getItems()
        local hadBox = false
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            local fullType = item:getFullType()
            if fullType == "BuildingUtilities.BreakerBox" then boxes = boxes + 1; hadBox = true end
            if fullType == "BuildingUtilities.WaterFilter" then
                filters = filters + 1
                local kept = BU.Units.keptOnItem(item)
                local hours = BU.WaterUnits.FILTER_HOURS
                if kept and kept.media >= 0.1 * hours - 1e-6 and kept.media <= 0.5 * hours + 1e-6 then used = used + 1 end
            end
        end
        if hadBox then withBox = withBox + 1 end
        if hadBox and holder:getModData()[BU.BOX_MARK] then marked = marked + 1 end
    end
    local took = getTimestampMs() - started
    -- 4 rolls at weight 2 x 100 x 4 in 10000 (and the zombies' share, small): about 30 percent of rolls of the list.
    local each = 1 - (1 - 2 * 100 * 4 / 10000) ^ 4
    say("rolled", n, "times in", took, "ms:", boxes, "boxes (about", math.floor(each * n), "or more),", filters, "filters")
    check("boxes about as often as their weight says", boxes >= each * n * 0.8 and boxes <= n, true)
    check("every roll with a box marks its container's owner", marked > 0 and marked == withBox, true)
    check("filters come", filters > 0, true)
    check("every filter used", used, filters)
end

for name, value in pairs(saved) do options:getOptionByName("BuildingUtilities." .. name):setValue(value) end
say("done:", bad, "BAD")
