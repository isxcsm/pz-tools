-- The box's manual: the instruction plate the maker put inside its door, read in the window's manual tab
-- (client/BuildingUtilities/PanelManual.lua). Its chapters come as the box can do more: the basic ones (connecting,
-- the breaker, maintenance) from the start, a tier's when the box is raised to it, the batteries' once a rack is wired
-- to it, water's once a water machine is. A chapter a character has read stays theirs to read at any box. What a
-- character has read is in their mod data: a chapter's key -> true (read to its end) or { t = the seconds printed
-- of a first reading left half way }. Some chapters teach recipes besides the magazines: learned at a box that offers
-- the chapter (Manual.RECIPES).
require "BuildingUtilities/Core"
require "BuildingUtilities/Store"
require "BuildingUtilities/Units"
local BU = BuildingUtilities
local Store, Units = BU.Store, BU.Units
local Manual = {}
BU.Manual = Manual

Manual.READ = "buManual"
Manual.CHAPTERS = { "connect", "breaker", "care", "tier2", "tier3", "tier4", "battery", "water" }
local TIER_OF = { tier2 = 2, tier3 = 3, tier4 = 4 }

-- What a character has read of a chapter: true, { t }, or nil.
function Manual.state(character, key)
    local read = character and character:getModData()[Manual.READ]
    return read and read[key] or nil
end

-- Keeps what a character has read of a chapter: done, or how far its first reading got (seconds printed). A chapter
-- read to its end stays so.
function Manual.keep(character, key, done, clock)
    local data = character:getModData()
    local read = data[Manual.READ] or {}
    if read[key] ~= true then read[key] = done and true or { t = clock or 0 } end
    data[Manual.READ] = read
end

-- Whether a box has a water machine or a rack wired to it.
local function hasUnits(panel, utility, kind)
    for _, unit in ipairs(Store.unitList(kind, panel.id)) do
        if kind or Units.definition(unit.kind).utility == utility then return true end
    end
    return false
end

-- Whether the box offers a chapter now.
local function offered(panel, key)
    local tier = TIER_OF[key]
    if tier then return (panel.tier or 1) >= tier end
    if key == "battery" then return BU.enabled("rack") and hasUnits(panel, "power", "rack") end
    if key == "water" then return BU.enabled("water") and hasUnits(panel, "water", nil) end
    return true
end

-- The chapters a character can read at a box, in their order: what the box offers, and what they have read before.
function Manual.chapters(panel, character)
    local list = {}
    for _, key in ipairs(Manual.CHAPTERS) do
        if offered(panel, key) or Manual.state(character, key) ~= nil then list[#list + 1] = key end
    end
    return list
end

-- Whether a chapter is new to a character: never read to its end.
function Manual.isNew(character, key) return Manual.state(character, key) ~= true end

-- Whether any chapter at the box is new to the character (the tab's mark).
function Manual.anyNew(panel, character)
    for _, key in ipairs(Manual.chapters(panel, character)) do
        if Manual.isNew(character, key) then return true end
    end
    return false
end

-- A chapter's title.
function Manual.title(key) return getText("IGUI_BU_Manual_" .. key) end

-- The recipes a chapter teaches, each { recipe, item (what it makes, for its name) }.
Manual.RECIPES = { water = { { recipe = "MakeWaterFilter", item = "BuildingUtilities.WaterFilter" } } }

-- The recipes a box lets its reader learn from a chapter now: the chapter's while the box offers it, else none.
function Manual.teaches(panel, key)
    return Manual.RECIPES[key] ~= nil and offered(panel, key) and Manual.RECIPES[key] or {}
end

-- A chapter's text (the document's marks: "## " heads, bullets); a tier's carries its rated load and its relays.
function Manual.text(key)
    local tier = TIER_OF[key]
    if tier then
        return getText("IGUI_BU_Manual_" .. key .. "Text", string.format("%.2f", BU.capacity(tier)),
            tostring(BU.relayLimit(tier)))
    end
    return getText("IGUI_BU_Manual_" .. key .. "Text")
end

return Manual
