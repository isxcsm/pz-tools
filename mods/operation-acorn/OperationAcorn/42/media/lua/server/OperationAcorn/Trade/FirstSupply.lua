-- The first supply (DESIGN 3): the vanilla helicopter's first flight is the research team's. When its window has passed
-- (or on the seventh day when there is none, or the next morning when the mod came late) a supply crate with the
-- terminal, its booklet, the harvest scalpel and the delivery box (an item, put down where the player wants) lies on
-- the clearest ground near the character. Lua polling version:
-- the plan is made from the vanilla schedule once, and every ten minutes the time is compared; nothing is checked after
-- the drop.
require "OperationAcorn/Server"
require "OperationAcorn/Trade/Heli"
local OA = OperationAcorn
local Store, Trade = OA.Store, OA.Trade
local Rules, Boxes, Objects, Heli = Trade.Rules, Trade.Boxes, Trade.Objects, Trade.Heli
local FirstSupply = {}
Trade.FirstSupply = FirstSupply

-- What the crate holds (DESIGN 9 '시작 꾸러미'): the terminal ready to set up, the booklet for a second one, the
-- scalpel; and the delivery box, added as it is made.
FirstSupply.CARGO = {
    { type = "OperationAcorn.CommTerminal", count = 1 },
    { type = "OperationAcorn.TerminalManual", count = 1 },
    { type = "OperationAcorn.HarvestScalpel", count = 1 },
}

-- What the game says about its helicopter and the time, for Rules.firstPlan.
function FirstSupply.facts()
    local time = getGameTime()
    local option = SandboxVars and tonumber(SandboxVars.Helicopter) or 2
    local ok, day, hour = pcall(function() return time:getHelicopterDay(), time:getHelicopterEndHour() end)
    return {
        option = option,
        nights = time:getNightsSurvived(),
        tod = time:getTimeOfDay(),
        heliDay = ok and day or nil,
        heliEnd = ok and hour or nil,
        rnd = OA.random,
    }
end

-- The plan of a record, made the first time it is looked at (a record exists once its character has said hello).
function FirstSupply.plan(record)
    if not record.first then
        record.first = Rules.firstPlan(FirstSupply.facts())
        OA.log("first supply for", record.id, record.first.mode, "night", record.first.day, "hour", record.first.hour)
    end
    return record.first
end

-- Puts the crate down near the character, the new active box in it. Returns true when it was done.
function FirstSupply.drop(record, character)
    local square = Objects.findClear(math.floor(character:getX()), math.floor(character:getY()), 30)
    if not square then return false end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local box = Boxes.add(record, { state = "carried", x = x, y = y, z = z, active = true })
    local cargo = {}
    for _, spec in ipairs(FirstSupply.CARGO) do cargo[#cargo + 1] = spec end
    cargo[#cargo + 1] = Boxes.itemSpec(record, box)
    local entry = { owner = record.id, x = x, y = y, z = z, search = true, cargo = cargo }
    if not Heli.setDown(entry) then
        Boxes.remove(record, box.id)
        return false
    end
    return true
end

-- Every ten minutes: the first supply of every record that waits for it.
function FirstSupply.check()
    local time = getGameTime()
    local nights, tod = time:getNightsSurvived(), time:getTimeOfDay()
    for _, record in pairs(Store.players()) do
        local plan = FirstSupply.plan(record)
        if not plan.done and Rules.firstDue(plan, nights, tod) then
            local character = Trade.characterOf(record)
            if character then
                local ok, done = pcall(FirstSupply.drop, record, character)
                if not ok then
                    OA.log("first supply failed:", tostring(done))
                elseif done then
                    plan.done = true
                    OA.Sync.title(record.id, { key = "IGUI_OA_Title_FirstSupply", sub = "IGUI_OA_Title_Marked",
                        style = "unveil", fallback = "good" })
                end
            end
        end
    end
end

return FirstSupply
