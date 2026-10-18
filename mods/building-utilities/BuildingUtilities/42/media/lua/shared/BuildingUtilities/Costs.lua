-- What laying a line costs: tools kept, wire or pipe by length, and for some an electronics part or a skill. Only
-- new lines cost; switching a device at the box is free. Taken away, a line gives back a share of what it took.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local Costs = {}
BU.Costs = Costs

Costs.WIRE, Costs.PIPE, Costs.PART, Costs.SHEET = "Base.ElectricWire", "Base.Pipe", "Base.ElectronicsScrap", "Base.SmallSheetMetal"
-- The control board, this mod's own item: one in every box, and more for each tier it was upgraded to.
Costs.BOARD = "BuildingUtilities.ControlBoard"
local TOOL_TAGS = { screwdriver = "SCREWDRIVER", pipewrench = "PIPE_WRENCH", pliers = "PLIERS" }

-- A water line's pipe is any that carries water and is found or made: plastic pipe, a fired clay pipe segment (a
-- kiln's), iron pipe; taken in that order. Not lead pipe (it poisons the water), a broken iron pipe or a rubber hose.
-- An item of a cost names its group by its first type.
Costs.PIPES = { "Base.Pipe", "Base.ClayPipeSegment", "Base.MetalPipe" }
local GROUPS = { [Costs.PIPE] = Costs.PIPES }
local GROUP_NAMES = { [Costs.PIPE] = "IGUI_BU_Item_Pipe" }

-- Not one in the character's hands or worn on them (an iron pipe kept as a weapon).
local function loose(item, character) return not (character:isEquipped(item) or character:isAttachedItem(item)) end

-- How many of an item, or of its group, the character has loose.
local function have(character, itemType)
    local inventory, total = character:getInventory(), 0
    for _, each in ipairs(GROUPS[itemType] or { itemType }) do
        total = total + inventory:getCountTypeEvalArgRecurse(each, loose, character)
    end
    return total
end

-- A cost: { tools = { "screwdriver", ... }, items = { { type, count }, ... }, skill = level of Electricity or nil }.

-- The pieces of wire or pipe a line so many squares long takes: at least one.
function Costs.pieces(steps) return math.max(1, math.ceil(math.max(0, steps or 0) / BU.tilesPerPiece())) end
local pieces = Costs.pieces

local function lineCost(utility, steps)
    if utility == "water" then return { tools = { "pipewrench" }, items = { { Costs.PIPE, pieces(steps) } } } end
    return { tools = { "screwdriver" }, items = { { Costs.WIRE, pieces(steps) } } }
end

-- A device or a unit inside the box's building: no line to lay, the tool of its utility to wire it in or out.
function Costs.tool(utility)
    return { tools = { utility == "water" and "pipewrench" or "screwdriver" }, items = {} }
end

-- A generator or a water container to a box, the line as long as the producer is from the building.
function Costs.producer(utility, steps) return lineCost(utility, steps) end

-- A device outside the building; a powered one needs a part to wire it in.
function Costs.outside(utility, steps)
    local cost = lineCost(utility, steps)
    if utility == "power" then table.insert(cost.items, { Costs.PART, 1 }) end
    return cost
end

-- A box to the next tier: control boards (BOARDS), and some wire and parts.
Costs.BOARDS = { [2] = 1, [3] = 2, [4] = 4 }
local UPGRADES = {
    [2] = { tools = { "screwdriver" }, items = { { Costs.BOARD, 1 }, { Costs.WIRE, 3 }, { Costs.PART, 3 } }, skill = 4 },
    [3] = { tools = { "screwdriver" }, items = { { Costs.BOARD, 2 }, { Costs.WIRE, 5 }, { Costs.PART, 5 },
        { Costs.SHEET, 1 } }, skill = 6 },
    [4] = { tools = { "screwdriver" }, items = { { Costs.BOARD, 4 }, { Costs.WIRE, 8 }, { Costs.PART, 8 },
        { Costs.SHEET, 2 } }, skill = 8 },
}
function Costs.upgrade(tier) return UPGRADES[tier] end

-- The control boards in a box of a tier: its own, and those its upgrades took (1, 2, 4, 8).
function Costs.boardsIn(tier)
    local boards = 1
    for each = 2, math.max(1, tier or 1) do boards = boards + (Costs.BOARDS[each] or 0) end
    return boards
end

-- Taking a box apart, as an item: a screwdriver and pliers. It gives its control boards (boardsIn) and so much wire
-- and parts (TAKE_APART).
Costs.TAKE_APART = { { Costs.WIRE, 2 }, { Costs.PART, 2 } }
function Costs.takeApart() return { tools = { "screwdriver", "pliers" }, items = {} } end

-- Opening a box to learn how it is made: a screwdriver.
function Costs.reverseEngineer() return { tools = { "screwdriver" }, items = {} } end

-- A new pipe put in at the box (BU.Water): a pipe wrench and two pipes.
function Costs.addPipe() return { tools = { "pipewrench" }, items = { { Costs.PIPE, 2 } } } end
function Costs.removePipe() return { tools = { "pipewrench" }, items = {} } end

-- Costs together, as one: each tool once, the items summed by type, the highest skill.
function Costs.sum(costs)
    local result, tools, items = { tools = {}, items = {} }, {}, {}
    for _, cost in ipairs(costs) do
        for _, tool in ipairs(cost.tools) do
            if not tools[tool] then tools[tool] = true; result.tools[#result.tools + 1] = tool end
        end
        for _, item in ipairs(cost.items) do
            if not items[item[1]] then
                items[item[1]] = { item[1], 0 }
                result.items[#result.items + 1] = items[item[1]]
            end
            items[item[1]][2] = items[item[1]][2] + item[2]
        end
        if cost.skill and (result.skill or 0) < cost.skill then result.skill = cost.skill end
    end
    return result
end

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

-- What a character has of the tools and items, looked through the inventory once and kept for a short while, for the
-- UI that asks of many costs together (a menu's options, a window's buttons): { character, at, tools = { [tool] =
-- whether }, counts = { [item type or group] = how many } }, each filled as it is first asked. Costs.affords and
-- Costs.describe take it as their last argument; without one they look through the inventory, as an action must
-- (what it checks as it is made and completes is not from a snapshot).
local SNAPSHOT_MS = 250
local snapshots = {}

function Costs.snapshot(character, fresh)
    local now = getTimestampMs()
    local number = character:getPlayerNum()
    local kept = snapshots[number]
    if kept and kept.character == character and not fresh and now >= kept.at and now - kept.at < SNAPSHOT_MS then return kept end
    kept = { character = character, at = now, tools = {}, counts = {} }
    snapshots[number] = kept
    return kept
end

local function toolOf(character, tool, snapshot)
    if not snapshot then return hasTool(character:getInventory(), tool) end
    local has = snapshot.tools[tool]
    if has == nil then
        has = hasTool(character:getInventory(), tool)
        snapshot.tools[tool] = has
    end
    return has
end

local function countOf(character, itemType, snapshot)
    if not snapshot then return have(character, itemType) end
    local count = snapshot.counts[itemType]
    if count == nil then
        count = have(character, itemType)
        snapshot.counts[itemType] = count
    end
    return count
end

-- Whether the character has what the cost asks. Always true without costs (sandbox), but for the skill of an upgrade.
function Costs.affords(character, cost, snapshot)
    if not cost then return false end
    if cost.skill and character:getPerkLevel(Perks.Electricity) < cost.skill then return false end
    if not BU.costsEnabled() then return true end
    for _, tool in ipairs(cost.tools) do
        if not toolOf(character, tool, snapshot) then return false end
    end
    for _, item in ipairs(cost.items) do
        if countOf(character, item[1], snapshot) < item[2] then return false end
    end
    return true
end

-- Takes the items of the cost (of a group, the first type the character has); returns what was taken, { [type] =
-- count }.
function Costs.take(character, cost)
    local paid = {}
    if not BU.costsEnabled() then return paid end
    local inventory = character:getInventory()
    for _, item in ipairs(cost.items) do
        for _ = 1, item[2] do
            local found, foundType
            for _, each in ipairs(GROUPS[item[1]] or { item[1] }) do
                found = inventory:getFirstTypeEvalArgRecurse(each, loose, character)
                if found then foundType = each; break end
            end
            if not found then break end
            local container = found:getContainer()
            container:DoRemoveItem(found)
            sendRemoveItemFromContainer(container, found)
            paid[foundType] = (paid[foundType] or 0) + 1
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
-- tooltip, which takes no tags, a mark before what is missing. snapshot: Costs.snapshot, when the caller has one.
function Costs.describe(character, cost, plain, snapshot)
    if not cost then return "" end
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
        for _, tool in ipairs(cost.tools) do line(toolOf(character, tool, snapshot), getText("IGUI_BU_Tool_" .. tool)) end
        for _, item in ipairs(cost.items) do
            local count = countOf(character, item[1], snapshot)
            local name = GROUP_NAMES[item[1]] and getText(GROUP_NAMES[item[1]]) or getItemNameFromFullType(item[1])
            line(count >= item[2], getText("IGUI_BU_NeedItem", name, item[2], count))
        end
    end
    return table.concat(lines, plain and "\n" or " <LINE> ")
end

return Costs
