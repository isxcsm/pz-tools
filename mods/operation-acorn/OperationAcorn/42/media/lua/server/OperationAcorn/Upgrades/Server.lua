-- The server side of the upgrades: the research approval (a plan of ranks, paid in points), the reset of a tree and its
-- credits, what the client saw and the record may agree to (a dose adapted to, a node's first work, the bite shield's
-- save, a zombie's wound, the body's state). A capstone opened by its meteorite fragment is the settlement's (Story).
-- The screen asks, the server decides and saves, then tells what changed. Alone, the game is its own server and the
-- same code runs at once.
require "OperationAcorn/Server"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Infection"
require "OperationAcorn/Upgrades/Adapt"
require "OperationAcorn/Upgrades/First"
require "OperationAcorn/Story/Survey"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Infection = OA.Infection
local Adapt = OA.Upgrades.Adapt
local First = OA.Upgrades.First
local Server = OA.Server
local UpgradesServer = {}
OA.Upgrades.Server = UpgradesServer

-- A plan longer than this is not read (the board has no end, but nobody approves this many at once).
UpgradesServer.MAX_STEPS = 500

-- A plan from a command's arguments: a list of { id } with only strings in it.
function UpgradesServer.readSteps(raw)
    local steps = {}
    if type(raw) ~= "table" then return steps end
    for i = 1, math.min(#raw, UpgradesServer.MAX_STEPS) do
        local s = raw[i]
        if type(s) == "table" and type(s.id) == "string" then
            steps[#steps + 1] = { id = s.id }
        end
    end
    return steps
end

-- Approves a plan for a record: all or nothing. Returns true, or false with the reason.
function UpgradesServer.approve(character, record, rawSteps)
    local u = Rules.section(record)
    local steps = UpgradesServer.readSteps(rawSteps)
    if #steps == 0 then return false, "empty" end
    local ok, result = Rules.approve(u, steps)
    if not ok then return false, result end
    local wasOpen, capstones, taken = Rules.boardOpen(u), Rules.capstones(u), Adapt.capstones(u)
    Rules.assign(u, result)
    -- (no notice of its own: the tab shows the plan taken; only a capstone or the board opening gets a title)
    OA.Sync.changed("upgrades", record.id, { kind = "approve" })
    UpgradesServer.titles(record.id, u, steps, wasOpen, capstones)
    -- the follow-up memo of each tree whose capstone this plan took
    Adapt.approved(record, taken)
    OA.StoryBranches.look(record, "approved")
    return true
end

-- The title of an applied plan that took a capstone: the second board's when that opened it (the last capstone), else
-- the capstone's (Upgrades.capstoneTitle: the last one in the plan). One title for one plan; a quiet one that fades in
-- and crumbles away (the API's "dust" style, Titles.show falls back where it has none).
function UpgradesServer.titles(id, u, steps, wasOpen, capstones)
    if not wasOpen and Rules.boardOpen(u) then
        OA.Sync.title(id, OA.Upgrades.boardTitle())
        return
    end
    if Rules.capstones(u) <= capstones then return end
    local taken
    for _, step in ipairs(steps) do
        local node = Data.byId[step.id]
        if node and node.capstone then taken = node end
    end
    if not taken then return end
    OA.Sync.title(id, OA.Upgrades.capstoneTitle(taken))
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

-- The client saw the adaptation after a dose is over (its end passed): the points come if the record agrees.
Server.on("upgrades.adapt", function(character, record, args)
    Adapt.finish(record, OA.hours())
end)

-- A node did its work in the game for the first time (the client saw it): noted if the record agrees.
Server.on("upgrades.first", function(character, record, args)
    if type(args.node) == "string" then First.grant(record, args.node) end
end)

-- The polling bite shield saved a bite (the client undid the infection): the shield rests from now on.
Server.on("upgrades.bite", function(character, record, args)
    local u = Rules.section(record)
    local now = OA.hours()
    if not Rules.biteReady(u, now) then return end
    u.biteAt = now
    OA.Sync.changed("upgrades", record.id, { kind = "bite" })
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_BiteSaved", sub = "IGUI_OA_Title_BiteSavedSub",
        subArgs = { math.floor(Rules.biteHours(u) / 24 + 0.5) }, style = "pulse" })
end)

-- A new wound from a zombie (the watch found it): the wound is untested from now, and a delay drug ends, whether or
-- not the body is infected. The drug going is told (red text over the head, and a line at most once a day); the wound
-- itself is not: the player learns of an infection only from a test and the body.
Server.on("infection.wound", function(character, record, args)
    local kind = args.kind
    if not Infection.WOUNDS[kind] then return end
    local lost = Infection.wounded(record, kind, OA.hours())
    OA.Sync.changed("infection", record.id, { kind = "wound" })
    if lost then
        OA.Sync.notice(record.id, "IGUI_OA_Tree_DrugLost", { kind })
        OA.Say.tell(record.id, "DrugLost")
    end
end)

-- What the body shows once a minute, when the record lacks it: an infection found, a known one gone, the progress.
Server.on("infection.seen", function(character, record, args)
    local progress = tonumber(args.progress)
    if Infection.seen(record, args.infected == true, progress, OA.hours()) then
        OA.Sync.changed("infection", record.id, { kind = "seen" })
    end
end)

return UpgradesServer
