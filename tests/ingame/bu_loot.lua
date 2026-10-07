-- Solar panels as loot (BU.Loot): the chance by room and container, the fill hook installed (a room of the check's own
-- made certain, filled through the game's OnFillContainer event), nothing added with the option at 0, Solar panels off
-- or Power off, or in a container without room; then a test crate filled as a tool store's storeroom crate BULOOT_N
-- times (default 4000) at the world's option, the panels counted against the chance. Needs no scene; leaves the
-- options as it found them. "[buloot]" lines, each check "ok" or "BAD".
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Loot = BU.Loot
local say = BUT.say("buloot")
if not Loot then say("BAD no BU.Loot: server/BuildingUtilities/Loot.lua is not loaded"); return end
local bad = 0
local function check(what, got, want)
    if got ~= want then bad = bad + 1 end
    say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want))
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

local page = SandboxVars.BuildingUtilities
local saved = { SolarPanelLoot = page.SolarPanelLoot, EnableSolar = page.EnableSolar, EnablePower = page.EnablePower }
local TEST_ROOM = "buloottest"
local options = getSandboxOptions()
local modifier = ItemPickerJava.getLootModifier(Loot.ITEM)
local thinning = options:getCurrentLootMultiplier()
say("world option", tostring(saved.SolarPanelLoot), "loot modifier (Other)", BUT.f(modifier), "thinning",
    BUT.f(thinning))

-- The panels a container holds.
local function panels(container)
    local items, count = container:getItems(), 0
    for i = 0, items:size() - 1 do
        if items:get(i):getFullType() == Loot.ITEM then count = count + 1 end
    end
    return count
end
-- Fills a fresh container of this type as one of this room, through the game's event, times times; the panels found.
local function fills(room, kind, times, capacity)
    local container = ItemContainer.new(kind, nil, nil)
    if capacity then container:setCapacity(capacity) end
    local found = 0
    for _ = 1, times do
        container:removeAllItems()
        triggerEvent("OnFillContainer", room, kind, container)
        found = found + panels(container)
    end
    return found
end

page.EnableSolar, page.EnablePower, page.SolarPanelLoot = true, true, 1

-- The chance: the room's weight, a percent per container, times the option and the game's own loot settings.
local base = modifier * thinning
local function percent(weight) return math.min(1, weight / 100 * base) end
check("chance: tool storeroom crate", near(Loot.chance("toolstorestorage", "crate"), percent(2)), true)
check("chance: tool storeroom (alias) shelf", near(Loot.chance("toolstorage", "metal_shelves"), percent(2)), true)
check("chance: warehouse carton", near(Loot.chance("warehouse", "cardboardbox"), percent(0.2)), true)
check("chance: small box", Loot.chance("toolstorestorage", "smallbox"), 0)
check("chance: fridge", Loot.chance("toolstorestorage", "fridge"), 0)
check("chance: kitchen crate", Loot.chance("kitchen", "crate"), 0)
check("chance: no room", Loot.chance(nil, "crate"), 0)
page.SolarPanelLoot = 2
check("chance: option 2", near(Loot.chance("toolstorestorage", "crate"), percent(4)), true)
page.SolarPanelLoot = 1

-- The hook: a room of its own that always gets one, filled through the event.
Loot.ROOMS[TEST_ROOM] = 1000000
local certain = Loot.chance(TEST_ROOM, "crate") == 1
say("test room certain", tostring(certain), "(false only while the game's Other loot is None)")
check("hook: one fill", fills(TEST_ROOM, "crate", 1), certain and 1 or 0)
check("hook: twenty fills", fills(TEST_ROOM, "crate", 20), certain and 20 or 0)
check("hook: no room for it (capacity 5)", fills(TEST_ROOM, "crate", 20, 5), 0)
check("hook: small box", fills(TEST_ROOM, "smallbox", 20), 0)

-- Off: none, whatever the room.
page.SolarPanelLoot = 0
check("option 0: chance", Loot.chance(TEST_ROOM, "crate"), 0)
check("option 0: fills", fills(TEST_ROOM, "crate", 200), 0)
page.SolarPanelLoot = 1
page.EnableSolar = false
check("solar off: chance", Loot.chance(TEST_ROOM, "crate"), 0)
check("solar off: fills", fills(TEST_ROOM, "crate", 200), 0)
page.EnableSolar = true
page.EnablePower = false
check("power off: chance", Loot.chance(TEST_ROOM, "crate"), 0)
check("power off: fills", fills(TEST_ROOM, "crate", 200), 0)
page.EnablePower = true
Loot.ROOMS[TEST_ROOM] = nil

-- The rate at the world's option: a tool store's storeroom crate filled many times.
page.SolarPanelLoot = saved.SolarPanelLoot
local n = BULOOT_N or 4000
local chance = Loot.chance("toolstorestorage", "crate")
local found = fills("toolstorestorage", "crate", n)
local expected = chance * n
local spread = math.sqrt(math.max(expected * (1 - chance), 1))
say("rate: tool storeroom crate", found, "panels in", n, "fills, expected", BUT.f(expected), "(chance",
    BUT.f(chance * 100), "percent)")
check("rate within four spreads", math.abs(found - expected) <= 4 * spread, true)

for name, value in pairs(saved) do page[name] = value end
say("done:", bad, "BAD; option back at", tostring(page.SolarPanelLoot))
