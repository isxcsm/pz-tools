-- Doses taken apart adapt each on its own time (Rules.startAdapt), as the player meets it: the research cleared (every
-- tree closed), a scout serum used and made almost done (as if taken half an hour ago), then a load serum. At the scout
-- dose's end the game's minute asks the server (client Adapting.minute) and its point comes and the tree opens, while
-- the load dose goes on and the moodle follows it. Then the take's sounds: a scout node applied in the tab sounds its
-- burst as it starts and the columns' light as that starts (OA_Research_Take, OA_Research_Glow: sounds the game
-- knows, played). LISTEN_MARK: prints the sounds' real times, for a recording of the game's output.
-- Changes the save (the research). Prints [adaptstagger] lines.
local OA = OperationAcorn
local t = STEPS("adaptstagger")
local Rules, Data, Serums = OA.Upgrades.Rules, OA.Upgrades.Data, OA.Upgrades.Serums
local Window = OA.Upgrades.Window
local Sound = PZUIKit.Sound
local player = getPlayer()
-- (a ghost or invisible character makes no sound, the debug save's default)
local wasInvisible, wasGhost = player:isInvisible(), player:isGhostMode()
player:setInvisible(false)
player:setGhostMode(false)

local u = OA.Dev.clearResearch()
local record = OA.Dev.record()
local id = record.id
local function use(item)
    local serum = player:getInventory():AddItem("OperationAcorn." .. item)
    return serum and Serums.use(player, serum, id)
end

-- the scout dose, its end half a game minute away
t.check("the scout serum used", use(Data.SERUM_ITEM.scout))
local scout = u.adapt and u.adapt.doses[1]
local by = Data.ADAPT_HOURS - 0.5 / 60
scout.from, scout.endsAt = scout.from - by, scout.endsAt - by
local scoutEnds = scout.endsAt
t.check("the load serum used after it", use(Data.SERUM_ITEM.load))
t.check("two doses, each its own end", #u.adapt.doses == 2 and u.adapt.doses[2].endsAt > scoutEnds + 0.4,
    string.format("%.3f / %.3f", scoutEnds, u.adapt.doses[2].endsAt))
t.check("both trees closed meanwhile", not Rules.treeOpen(u, "scout") and not Rules.treeOpen(u, "load"))
OA.Sync.changed("upgrades", id)

-- the take's sounds, as the tab asks for them
local played = {}
local realHeld = Sound.uiHeld
Sound.uiHeld = function(cue, ...)
    local held = realHeld(cue, ...)
    played[#played + 1] = { cue = cue, at = getTimestampMs(), held = held }
    if LISTEN_MARK then print("[listen] " .. cue .. " " .. getTimestampMs()) end
    return held
end

local view
t.run({
    -- (a game minute is some 4 s in this save: the scout dose's end comes within it)
    { 9000, function()
        t.say("hours past the scout dose's end", string.format("%.4f", OA.hours() - scoutEnds))
        t.check("the scout point came at its own end", Rules.ownPool(u, "scout") == 1, Rules.ownPool(u, "scout"))
        t.check("and its tree opened then", Rules.treeOpen(u, "scout"))
        t.check("the load dose goes on", Rules.adapting(u, "load") == 1 and not Rules.treeOpen(u, "load"))
        t.check("the moodle follows the load dose", Rules.adaptLevel(u, OA.hours()) == 4, Rules.adaptLevel(u, OA.hours()))
        local info = getPlayerInfoPanel(0)
        if info:getIsVisible() and info.panel:getActiveView() == Window.view(0) then OA.Upgrades.open(0) end
        view = OA.Upgrades.open(0)
        view:onMode({ internal = "trees" })
    end },
    { 1500, function()
        t.check("the tab: load adapting, its bar part way", view.adaptShares and (view.adaptShares.load or 0) > 0
            and (view.adaptShares.load or 1) < 0.2, view.adaptShares and view.adaptShares.load)
        t.check("no scout dose left adapting", Rules.adapting(u, "scout") == 0)
        for _, name in ipairs({ "OA_Research_Take", "OA_Research_Glow" }) do
            t.check(name .. " known to the game", GameSounds.isKnownSound(name))
        end
        -- the first scout node the point can take
        for _, n in ipairs(Data.treeNodes("scout")) do
            if #view.steps == 0 then view:plan(n.id) end
        end
        t.check("a scout node selected", #view.steps == 1, #view.steps)
    end },
    { 1000, function()
        view:approve()
    end },
    { 300, function()
        t.check("the take plays", view.take ~= nil)
        view.takeSeen = view.take and { start = view.take.start, glowFrom = view.take.glowFrom, ends = view.take.ends }
    end },
    { 3500, function()
        local seen = view.takeSeen or {}
        local lines = {}
        for i, p in ipairs(played) do
            lines[i] = p.cue .. " at " .. (seen.start and (p.at - seen.start) or "?") .. " ms" .. (p.held and "" or " (not played)")
        end
        t.say("sounds", table.concat(lines, ", "), "| glow from", seen.glowFrom, "ms, take", seen.ends, "ms")
        t.check("the burst as it starts", played[1] and played[1].cue == "oa.research.take" and played[1].held ~= nil
            and seen.start and math.abs(played[1].at - seen.start) < 50)
        t.check("the columns' light as it starts", played[2] and played[2].cue == "oa.research.glow"
            and played[2].held ~= nil and seen.start and math.abs(played[2].at - seen.start - seen.glowFrom) < 60)
        t.check("nothing more", #played == 2, #played)
        Sound.uiHeld = realHeld
        player:setInvisible(wasInvisible)
        player:setGhostMode(wasGhost)
    end },
})
