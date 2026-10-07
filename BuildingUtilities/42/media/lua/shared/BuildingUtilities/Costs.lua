-- What laying a line costs: tools kept, wire or pipe by length, and for some an electronics part or a skill. Only
-- new lines cost; switching a device at the box is free. Taken away, a line gives back a share of what it took.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local Costs = {}
BU.Costs = Costs

Costs.WIRE, Costs.PIPE, Costs.PART, Costs.SHEET = "Base.ElectricWire", "Base.Pipe", "Base.ElectronicsScrap", "Base.SmallSheetMetal"
local TOOL_TAGS = { screwdriver = "SCREWDRIVER", pipewrench = "PIPE_WRENCH" }

-- A cost: { tools = { "screwdriver", ... }, items = { { type, count }, ... }, skill = level of Electricity or nil }.

-- The pieces of wire or pipe a line so many squares long takes: at least one.
function Costs.pieces(steps) return math.max(1, math.ceil(math.max(0, steps or 0) / BU.tilesPerPiece())) end
local pieces = Costs.pieces

local function lineCost(utility, steps)
    if utility == "water" then return { tools = { "pipewrench" }, items = { { Costs.PIPE, pieces(steps) } } } end
    return { tools = { "screwdriver" }, items = { { Costs.WIRE, pieces(steps) } } }
end

-- A generator or a water container to a box, the line as long as the producer is from the building.
function Costs.producer(utility, steps) return lineCost(utility, steps) end

-- A device outside the building; a powered one needs a part to wire it in.
function Costs.outside(utility, steps)
    local cost = lineCost(utility, steps)
    if utility == "power" then table.insert(cost.items, { Costs.PART, 1 }) end
    return cost
end

-- A sub-panel to its main panel: power and water lines between the two buildings.
function Costs.link(steps)
    return { tools = { "screwdriver", "pipewrench" }, items = { { Costs.WIRE, pieces(steps) }, { Costs.PIPE, pieces(steps) } },
        skill = 3 }
end

-- A box to the next tier.
local UPGRADES = {
    [2] = { tools = { "screwdriver" }, items = { { Costs.WIRE, 5 }, { Costs.PART, 5 } }, skill = 4 },
    [3] = { tools = { "screwdriver" }, items = { { Costs.WIRE, 10 }, { Costs.PART, 10 }, { Costs.SHEET, 2 } }, skill = 6 },
}
function Costs.upgrade(tier) return UPGRADES[tier] end

-- How many of an item a cost takes.
function Costs.count(cost, itemType)
    for _, item in ipairs(cost.items) do
        if item[1] == itemType then return item[2] end
    end
    return 0
end

local function notBroken(item) return not item:isBroken() end

local function hasTool(inventory, tool)
    local tag = ItemTag[TOOL_TAGS[tool]]
    return tag ~= nil and inventory:getFirstTagEvalRecurse(tag, notBroken) ~= nil
end

-- Whether the character has what the cost asks. Always true without costs (sandbox), but for the skill of an upgrade.
function Costs.affords(character, cost)
    if not cost then return false end
    if cost.skill and character:getPerkLevel(Perks.Electricity) < cost.skill then return false end
    if not BU.costsEnabled() then return true end
    local inventory = character:getInventory()
    for _, tool in ipairs(cost.tools) do
        if not hasTool(inventory, tool) then return false end
    end
    for _, item in ipairs(cost.items) do
        if inventory:getCountTypeRecurse(item[1]) < item[2] then return false end
    end
    return true
end

-- Takes the items of the cost; returns what was taken, { [type] = count }.
function Costs.take(character, cost)
    local paid = {}
    if not BU.costsEnabled() then return paid end
    local inventory = character:getInventory()
    for _, item in ipairs(cost.items) do
        for _ = 1, item[2] do
            local found = inventory:getFirstTypeRecurse(item[1])
            if not found then break end
            local container = found:getContainer()
            container:DoRemoveItem(found)
            sendRemoveItemFromContainer(container, found)
            paid[item[1]] = (paid[item[1]] or 0) + 1
        end
    end
    return paid
end

-- The sandbox's share of a count, rounded: half of one piece gives it back.
function Costs.refundCount(count) return math.floor(count * BU.refundPercent() / 100 + 0.5) end

-- Gives back the sandbox's share of what a line took.
function Costs.refund(character, paid)
    if type(paid) ~= "table" then return end
    local inventory = character:getInventory()
    for itemType, count in pairs(paid) do
        for _ = 1, Costs.refundCount(count) do
            local item = inventory:AddItem(itemType)
            if item then sendAddItemToContainer(inventory, item) end
        end
    end
end

-- The cost as tooltip lines: each need, green when the character has it, red when not. Plain: for a button's
-- tooltip, which takes no tags, a mark before what is missing.
function Costs.describe(character, cost, plain)
    if not cost then return "" end
    local inventory = character:getInventory()
    local lines = {}
    local function line(ok, text)
        if plain then lines[#lines + 1] = (ok and "  " or "! ") .. text
        else lines[#lines + 1] = (ok and " <RGB:0.5,1,0.5> " or " <RGB:1,0.4,0.4> ") .. text end
    end
    if cost.skill then
        local level = character:getPerkLevel(Perks.Electricity)
        line(level >= cost.skill, getText("IGUI_BU_NeedSkill", cost.skill, level))
    end
    if BU.costsEnabled() then
        for _, tool in ipairs(cost.tools) do line(hasTool(inventory, tool), getText("IGUI_BU_Tool_" .. tool)) end
        for _, item in ipairs(cost.items) do
            local have = inventory:getCountTypeRecurse(item[1])
            line(have >= item[2], getText("IGUI_BU_NeedItem", getItemNameFromFullType(item[1]), item[2], have))
        end
    end
    return table.concat(lines, plain and "\n" or " <LINE> ")
end

return Costs
