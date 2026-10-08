-- The server side of the upgrades: the research approval (a plan of ranks, paid in points and meteor fragments), the
-- reset of a tree, and the bite shield's rest. The screen asks, the server decides and saves, then tells what
-- changed. Alone, the game is its own server and the same code runs at once.
require "OperationAcorn/Server"
require "OperationAcorn/Upgrades/Api"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Server = OA.Server
local UpgradesServer = {}
OA.Upgrades.Server = UpgradesServer

-- A plan longer than this is not read (the board has no end, but nobody approves this many at once).
UpgradesServer.MAX_STEPS = 500

-- The fragments a character carries (in any bag).
function UpgradesServer.fragments(character)
    return character:getInventory():getCountTypeRecurse(Data.FRAGMENT)
end

local function takeFragments(character, count)
    local inventory = character:getInventory()
    for _ = 1, count do
        local item = inventory:getFirstTypeRecurse(Data.FRAGMENT)
        if not item then return false end
        local container = item:getContainer()
        container:DoRemoveItem(item)
        if sendRemoveItemFromContainer then sendRemoveItemFromContainer(container, item) end
    end
    return true
end

-- A plan from a command's arguments: a list of { id, choice } with only strings in it.
function UpgradesServer.readSteps(raw)
    local steps = {}
    if type(raw) ~= "table" then return steps end
    for i = 1, math.min(#raw, UpgradesServer.MAX_STEPS) do
        local s = raw[i]
        if type(s) == "table" and type(s.id) == "string" then
            steps[#steps + 1] = { id = s.id, choice = type(s.choice) == "string" and s.choice or nil }
        end
    end
    return steps
end

-- Approves a plan for a record: all or nothing. Returns true, or false with the reason.
function UpgradesServer.approve(character, record, rawSteps)
    local u = Rules.section(record)
    local steps = UpgradesServer.readSteps(rawSteps)
    if #steps == 0 then return false, "empty" end
    local ok, result, used = Rules.approve(u, steps, { fragments = UpgradesServer.fragments(character) })
    if not ok then return false, result end
    if used > 0 and not takeFragments(character, used) then return false, "fragment" end
    Rules.assign(u, result)
    OA.Sync.changed("upgrades", record.id, { kind = "approve" })
    OA.Sync.notice(record.id, "IGUI_OA_Tree_Approved", { #steps })
    return true
end

-- Resets a tree for a record: the credits come out of the trade section.
function UpgradesServer.reset(record, tree)
    local u = Rules.section(record)
    local trade = OA.Store.section(record, "trade")
    local credits = trade.credits or 0
    local ok, result = Rules.reset(u, tree, credits)
    if not ok then return false, result end
    trade.credits = credits - result
    OA.Sync.changed("upgrades", record.id, { kind = "reset", tree = tree })
    OA.Sync.changed("trade", record.id, { kind = "credits" })
    OA.Sync.notice(record.id, "IGUI_OA_Tree_ResetDone", { tree, result })
    return true
end

Server.on("upgrades.approve", function(character, record, args)
    local ok, why = UpgradesServer.approve(character, record, args.steps)
    if not ok then OA.Sync.notice(record.id, "IGUI_OA_Tree_ApproveFailed", { tostring(why) }) end
end)

Server.on("upgrades.reset", function(character, record, args)
    if type(args.tree) ~= "string" then return end
    local ok, why = UpgradesServer.reset(record, args.tree)
    if not ok then OA.Sync.notice(record.id, "IGUI_OA_Tree_ResetFailed", { tostring(why) }) end
end)

-- The polling bite shield saved a bite (the client undid the infection): the shield rests from now on.
Server.on("upgrades.bite", function(character, record, args)
    local u = Rules.section(record)
    local now = OA.hours()
    if not Rules.biteReady(u, now) then return end
    u.biteAt = now
    OA.Sync.changed("upgrades", record.id, { kind = "bite" })
    OA.Sync.notice(record.id, "IGUI_OA_Tree_BiteSaved", { math.floor(Rules.biteHours(u) / 24 + 0.5) })
end)

return UpgradesServer
