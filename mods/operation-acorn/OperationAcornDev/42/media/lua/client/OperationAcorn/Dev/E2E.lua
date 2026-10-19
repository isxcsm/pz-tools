-- Operation Acorn Dev: the E2E director (E2E-DEBUG.md). The story's scenes in their order, each a beat: setting one
-- puts the record (and the character) where the play stands just before that scene, through the mod's own functions,
-- so that the tester brings it on by playing (opening the terminal, starting the mission, walking into its circle).
-- The waits are shortened by the timers (each set to fire at the next look, on the game's own path), the distances by
-- the moves (to just outside a mission's circle, to the base). Single player, debug mode only: it changes the save.
if not isDebugEnabled() then return end
require "OperationAcorn/Dev/Dev"
require "OperationAcorn/Dev/Features"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Objects"
require "OperationAcorn/Trade/Gain"
local OA = OperationAcorn
local Dev = OA.Dev
local say = Dev.say
local E2E = {}
Dev.E2E = E2E

-- How far before its next look a timer is set: the looks come every ten game minutes, so it fires within half an hour.
E2E.LEAD = 0.25
-- Squares outside a mission's circle the character is put, and how far around that point a square is looked for.
E2E.OUTSIDE = 12
E2E.AROUND = 10

-- The team's calls in the order the play meets them (SCENES 3): everything before a beat's first call has been played.
-- The pairs of a choice (B3a/B3b, BS1/BS2) are played on their first and dropped on the other.
E2E.ORDER = { "S0", "S1", "s1_bedding", "B1", "S1F", "S2", "S2B", "s2_filter", "s2_correction", "B2", "S2F", "S3",
    "s3_meteor", "s3_fragment", "B3a", "B3b", "S4", "S4B", "s4_committee", "B4", "S4F", "S5", "B5", "S5F", "S6",
    "s6_list", "B6", "S6F", "S7", "s7_list", "B7", "S7F", "BS1", "BS2", "s8_handover", "B8", "S8F", "S8", "S9", "K1",
    "BR1", "K2", "BR2", "K3", "BR3", "K4" }
local OTHER_OF = { B3b = "B3a", BS2 = "BS1" }

-- A briefing played means its story mission is behind: the story and the key of its field monologues.
local STORY_OF = {
    B1 = { "evidence", "evidence" }, B2 = { "clinic", "clinic" }, B3a = { "observation", "observation_a", "a" },
    B4 = { "cooler", "cooler" }, B5 = { "gym", "gym" }, B6 = { "ward", "ward" }, B7 = { "cells", "cells" },
    BS1 = { "soil", "soil" }, B8 = { "handover", "handover" },
}

-- The beats. stage/milestones: the level the record is at; from: its first call (all before it played); fresh: a record
-- as new (trust 0, the terminal not answering it); first: "drop" the first supply comes down at once, "wait" it waits
-- (the join beats), "heli" the game's helicopter flies over first and the supply comes as it goes (E2E.HELI_SECONDS);
-- firstMode: how the world's first supply comes (Rules.firstPlan): "window" after the game's helicopter (by default),
-- "late" the mod came after it (a character joining a world after it too: the join beats), "none" a world without the
-- helicopter; offer: the story mission due is offered; fill: the base's delivery box is filled for a settlement; serum:
-- an upgrade serum to inject; handover: the handover is over; join: the world's tier when the record came into it
-- (CANON S19), "H" after the handover; keep: nothing is set. more: its things to see go on a second line.
E2E.BEATS = {
    { id = "01", fresh = true, first = "heli" },
    { id = "01L", fresh = true, first = "drop", firstMode = "late" },
    { id = "01N", fresh = true, first = "drop", firstMode = "none" },
    { id = "02", stage = 1, from = "S1", fill = true },
    { id = "03", stage = 1, from = "B1", offer = true },
    { id = "04", stage = 1, from = "S2", serum = true },
    { id = "05", stage = 2, from = "s2_filter", offer = true },
    { id = "06", stage = 3, from = "S3", offer = true },
    { id = "07", stage = 4, from = "S4", fill = true },
    { id = "08", stage = 4, from = "B4", offer = true },
    { id = "09", stage = 5, from = "S5", offer = true },
    { id = "10", stage = 5, milestones = 1, from = "S6", offer = true, fill = true },
    { id = "11", stage = 5, milestones = 2, from = "S7", offer = true, fill = true },
    { id = "11S", stage = 5, milestones = 2, from = "BS1", offer = true },
    { id = "12", stage = 5, milestones = 3, from = "s8_handover", offer = true, more = true },
    { id = "13", stage = 5, milestones = 4, from = "K1", offer = true, handover = true },
    { id = "J4", fresh = true, first = "wait", firstMode = "late", join = 4 },
    { id = "J5", fresh = true, first = "wait", firstMode = "late", join = 5 },
    { id = "J7", fresh = true, first = "wait", firstMode = "late", join = 7 },
    { id = "JH", fresh = true, first = "wait", firstMode = "late", join = "H" },
    { id = "X", keep = true },
}
E2E.BY_ID = {}
for i, b in ipairs(E2E.BEATS) do
    b.index = i
    E2E.BY_ID[b.id] = b
end

local function record()
    local r = Dev.record()
    if not r then error("no record yet", 3) end
    return r
end

local function indexOf(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return nil
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Setting a beat.

-- The titles and notices a setting passes through are not shown (the beat's own come after it): run fn with them
-- quiet, put back whatever happens.
local function quietly(fn, ...)
    local Sync = OA.Sync
    local title, notice = Sync.title, Sync.notice
    Sync.title = function() end
    Sync.notice = function() end
    local ok, err = pcall(fn, ...)
    Sync.title, Sync.notice = title, notice
    if not ok then error(err, 0) end
end

-- The record's story as new: its missions let go (what was placed stays in the world), the story, the calls and the
-- missions gone, trust and the levels at 0, no helicopter waited for. Research, the economy, the boxes and the
-- terminal's place stay. `fresh`: the terminal does not know the record yet (the first supply to come).
local function reset(r, fresh)
    OA.Missions.retire(r)
    r.story, r.comms, r.missions, r.say = nil, nil, nil, nil
    local t = OA.Store.section(r, "trade")
    t.trust, t.stage, t.milestones = 0, 0, 0
    -- the last settlement shown on the helicopter screen was an earlier beat's (02 is the first settlement)
    t.lastSettle = nil
    local heli = OA.Trade.heli(r)
    heli.call, heli.next, heli.landing = nil, nil, nil
    heli.drop = {}
    -- a box sealed before would be settled at the beat's first call (its pay and trust with it): it goes, its object
    -- with it when its square is loaded
    local Boxes, Objects = OA.Trade.Boxes, OA.Trade.Objects
    for _, box in ipairs(Boxes.sealed(r)) do
        local object = box.x and Objects.find(Objects.square(box.x, box.y, box.z or 0), Objects.DELIVERY_BOX, box.id)
        if object then Objects.remove(object) end
        Boxes.remove(r, box.id)
    end
    if fresh then
        heli.greeted = nil
        r.first = nil
    end
end

-- The record's place in the world's story (CANON S19) as the beat says, whatever the world's other records are: the
-- story section made again would take it from them.
local function joinAs(r, beat)
    local s = OA.Story.section(r)
    s.joined, s.handover, s.handoverShown = nil, false, nil
    r.comms = nil
    if not beat.join then return end
    local admin = beat.join == "H"
    local tier = admin and OA.StoryData.TRANSFER_TIER or beat.join
    s.joined = { tier = tier, handover = admin or nil }
    if admin then s.handover, s.handoverShown = true, true end
    OA.Comms.join(r, tier, admin)
end

-- The calls before the beat's first: played a day before (in the tab's record as they were; a short call coming next
-- is not held by its gap after the last), the other of a choice dropped; the story missions their briefings stand for
-- done, with their field monologues. Returns the stories done.
local function playBefore(r, from)
    local Data = OA.CommsData
    local s = OA.Comms.section(r)
    local upTo = indexOf(E2E.ORDER, from) or (#E2E.ORDER + 1)
    local stories = {}
    for i = 1, upTo - 1 do
        local id = E2E.ORDER[i]
        if OTHER_OF[id] then
            s.dropped[id] = true
            OA.Comms.changed()
        else
            local e = Data.BY_ID[id]
            OA.Comms.played(r, id, math.max(1, e and e.tier or 1), OA.hours() - 24)
            if STORY_OF[id] then stories[#stories + 1] = STORY_OF[id] end
        end
    end
    local st = OA.Story.section(r)
    local says = {}
    for _, entry in ipairs(stories) do
        st.done[entry[1]] = "done"
        if entry[3] then st.chosen[entry[1]] = entry[3] end
        says["say:" .. entry[2] .. ":"] = true
    end
    for _, e in ipairs(Data.ENTRIES) do
        if e.kind == "say" then
            local head = string.match(e.trigger, "^(say:[%w_]+:)")
            if head and says[head] then OA.Comms.played(r, e.id, e.tier, OA.hours() - 24) end
        end
    end
    return stories
end

-- The 2반 papers of the levels before the beat's: gone in crates (before the levels are entered, so that they are not
-- queued again) and, once they are, read at their own tier (the folder has them where the play would have put them).
local function papersBefore(r, stage, milestones)
    local Data = OA.StoryData
    local s = OA.Story.section(r)
    local defs = {}
    local before = milestones > 0 and Data.LAST_STAGE or stage - 1
    for st = 1, before do defs[#defs + 1] = { def = Data.STAGES[st], tier = st } end
    for k = 1, milestones - 1 do defs[#defs + 1] = { def = Data.MILESTONES[k], tier = Data.LAST_STAGE + k } end
    for _, d in ipairs(defs) do
        for _, entry in ipairs(d.def and d.def.supply or {}) do
            local doc = entry[2]
            s.sent[doc] = true
            s.sentTier[doc] = d.tier
        end
    end
    if s.sent.reply_fragment then s.fragmentSeen = true end
    return function()
        for doc, tier in pairs(s.sentTier) do
            OA.Story.markRead(r, doc)
            s.docStage[doc] = tier
        end
    end
end

-- The terminal knows the record: the first supply came, the team answered, the first contact is behind.
local function register(r)
    r.first = r.first or { mode = "window", day = 0, hour = 9 }
    r.first.done = true
    OA.Trade.heli(r).greeted = true
    OA.Story.section(r).firstContact = true
end

-- The box standing at the base (the one nearest the terminal) takes the active place again: a first supply set in
-- between made its crate's new box the active one. Returns it, or nil when none stands.
local function baseBox(r)
    local Boxes = OA.Trade.Boxes
    local active = Boxes.active(r)
    if active and active.state == "placed" then return active end
    local t = r.heli and r.heli.terminal
    local best, bestD
    for _, box in ipairs(Boxes.all(r)) do
        if box.state == "placed" and box.x then
            local d = t and ((box.x - t.x) * (box.x - t.x) + (box.y - t.y) * (box.y - t.y)) or 0
            if not bestD or d < bestD then best, bestD = box, d end
        end
    end
    if best then Boxes.data(r).active = best.id end
    return best
end

-- An open box at the base, put down by the terminal (as the player puts one: Things.placeBox) when none stands there.
-- Returns the box (nil when the base is not loaded), and whether it was put down now.
local function boxAtBase(r)
    local box = baseBox(r)
    if box then return box, false end
    local t = r.heli and r.heli.terminal
    local Objects, Boxes = OA.Trade.Objects, OA.Trade.Boxes
    local square = t and Objects.findClear(t.x + 2, t.y + 1, 8)
    if not square then say("box: no ground by the terminal") return nil end
    local player = getPlayer()
    box = Boxes.add(r, { state = "carried", x = square:getX(), y = square:getY(), z = 0, active = true })
    local item = player:getInventory():AddItem(Boxes.ITEM)
    item:getModData()[Objects.BOX] = box.id
    item:getModData()[Objects.OWNER] = r.id
    local ok, why = OA.Trade.Things.placeBox(player, r, square, item)
    if not ok then say("box: not put down", tostring(why)) return nil end
    say("box put down at", square:getX(), square:getY())
    return box, true
end

-- The level's trust (its start), and the story entering it as the trade part would make it.
local function raise(r, stage, milestones)
    local level = milestones > 0 and (OA.StoryData.LAST_STAGE + milestones) or stage
    if level > 0 then Dev.stage(level) end
    OA.Story.onStage(r)
end

-- n of each item in the base's delivery box, for a settlement (a box carried, or none, is said); what an earlier
-- beat put in is taken out first, so the settlement is the same whichever beats came before.
E2E.FILL = { { "Base.Sheet", 3 }, { "Base.Socks_Ankle", 2 }, { "Base.Battery", 2 } }
function E2E.fillBox()
    local r = record()
    local Objects = OA.Trade.Objects
    local box = OA.Trade.Boxes.active(r)
    if not (box and box.x) then say("fill: no box standing") return false end
    local object = Objects.find(Objects.square(box.x, box.y, box.z or 0), Objects.DELIVERY_BOX, box.id)
    local container = object and object:getContainer()
    if not container then say("fill: the box is not loaded") return false end
    container:removeAllItems()
    for _, entry in ipairs(E2E.FILL) do
        for _ = 1, entry[2] do container:AddItem(entry[1]) end
    end
    say("box filled at", box.x, box.y)
    return true
end

-- The square next to the base's terminal (its record's; a terminal object near the character else), powered for the
-- session; nil when the record has none.
local function baseSpot(r)
    local t = r.heli and r.heli.terminal
    if not t then return nil end
    local square = OA.Trade.Objects.square(t.x, t.y, t.z or 0)
    if square then Dev.powerAt(square) end
    local spot = square and OA.Trade.Objects.findClear(t.x + 1, t.y, 4)
    if spot then return spot:getX(), spot:getY(), spot:getZ() end
    return t.x + 1, t.y, t.z or 0
end

-- Puts the character next to the base's terminal. Returns whether there was one.
function E2E.toBase()
    local x, y, z = baseSpot(record())
    if not x then say("base: the record has no terminal") return false end
    getPlayer():teleportTo(x + 0.5, y + 0.5, z)
    say("at the base", x, y, z)
    return true
end

-- What waits for the base to load after a move there from afar: { r, fn, ticks }.
local arrival = nil

-- Whether the base is loaded: the terminal's object on its square and the box standing there on its own (a square
-- can be there before its objects, and the two may lie in different chunks).
local function baseLoaded(r)
    local Objects = OA.Trade.Objects
    local t = r.heli.terminal
    if not Objects.find(Objects.square(t.x, t.y, t.z or 0), Objects.TERMINAL) then return false end
    local box = baseBox(r)
    return not box or Objects.find(Objects.square(box.x, box.y, box.z or 0), Objects.DELIVERY_BOX, box.id) ~= nil
end

local function arrive()
    if not arrival then return end
    arrival.ticks = arrival.ticks + 1
    local loaded = baseLoaded(arrival.r)
    if loaded or arrival.ticks > 600 then
        Events.OnTick.Remove(arrive)
        local done = arrival
        arrival = nil
        if loaded then done.fn(true) else say("base: not loaded in time") end
    end
end

-- fn(late) once the base is loaded: at once when it is, else on the ticks after the move (late = true).
local function atBase(r, fn)
    local t = r.heli and r.heli.terminal
    if not t then return end
    if baseLoaded(r) then fn(false) return end
    if not arrival then Events.OnTick.Add(arrive) end
    arrival = { r = r, fn = fn, ticks = 0 }
end

-- Sets a beat (E2E.BEATS). opts.place = false keeps the character where it is (tests). Returns the beat.
function E2E.set(id, opts)
    local beat = E2E.BY_ID[id]
    if not beat then error("no beat " .. tostring(id), 2) end
    opts = opts or {}
    E2E.current = beat.id
    if beat.keep then say("e2e", beat.id, "(nothing set)") return beat end
    local r = record()
    local stage, milestones = beat.stage or 0, beat.milestones or 0
    quietly(function()
        reset(r, beat.fresh)
        joinAs(r, beat)
        local readPapers
        if not beat.fresh then
            register(r)
            baseBox(r)
            playBefore(r, beat.from)
            readPapers = papersBefore(r, stage, milestones)
        end
        raise(r, stage, milestones)
        if readPapers then readPapers() end
        -- the named stage's card was shown as the terminal was opened before the beat, unless the beat opens on the
        -- stage's own first call (its card comes with that open)
        if beat.from then
            local opening = string.match(OA.CommsData.BY_ID[beat.from].trigger, "^tier:")
            if not opening then OA.Story.section(r).cardStage = math.min(stage, OA.StoryData.LAST_STAGE) end
        end
        if beat.handover then
            local s = OA.Story.section(r)
            s.handover, s.handoverShown = true, true
            for _, doc in ipairs({ "handover_notice", "status_table" }) do
                OA.Story.markRead(r, doc)
                s.docStage[doc] = OA.StoryData.TRANSFER_TIER
            end
        end
        local missions = OA.Missions.state(r)
        -- the special request waits (the field terminal's offer would come between the beat's scenes)
        OA.Missions.special(r).nextAt = OA.hours() + 24 * 365
        if beat.offer then
            OA.Story.section(r).regularsSince = 1
            OA.Missions.start(r)
        elseif OA.Missions.opened(r) then
            -- no regular mission comes between either: the story's own scenes are the beat's
            missions.nextAt = OA.hours() + 24 * 365
        else
            -- the missions are not open yet: the scene that opens them (S1, at its end) brings the first at the next looks
            missions.nextAt = 0
        end
        if beat.fresh then
            -- the first supply's plan (FirstSupply.plan's), its day a year off: it comes by the move, not by itself
            r.first = { mode = beat.firstMode or "window", day = OA.day(OA.hours()) + 365, hour = 9,
                done = false }
        end
    end)
    if beat.serum then Dev.give("OperationAcorn.UpgradeSerumShared", 1) end
    if opts.place ~= false and not beat.fresh and E2E.toBase() then
        atBase(r, function(late)
            -- a box put down now may take the square the character stood on; a move before the base was loaded
            -- stood on the square next to the terminal, clear or not
            local _, new = boxAtBase(r)
            if new or late then E2E.toBase() end
            if beat.fill then E2E.fillBox() end
        end)
    end
    E2E.cancelHeli()
    if beat.first == "drop" and opts.place ~= false then E2E.firstSupply() end
    if beat.first == "heli" and opts.place ~= false then E2E.heliThenSupply() end
    for _, section in ipairs({ "trade", "story", "comms", "missions" }) do OA.Sync.changed(section, r.id) end
    say("e2e", beat.id, "set: stage", stage, "milestones", milestones)
    return beat
end

-- The beat after the one set last (the first when none was).
function E2E.next()
    local beat = E2E.current and E2E.BY_ID[E2E.current]
    local nextBeat = E2E.BEATS[beat and beat.index + 1 or 1]
    if not nextBeat then say("e2e: the last beat") return nil end
    return E2E.set(nextBeat.id)
end

-- The next stage or milestone, with the trust it takes coming in as a settlement's would (Trade.addTrust): its title,
-- the story's and the comms' events, as in play.
function E2E.stageUp()
    local r = record()
    local t = OA.Store.section(r, "trade")
    local Trust = OA.Trust
    local level = (t.stage or 1) + (t.milestones or 0)
    local need = level < Trust.STAGES and Trust.stageThreshold(level + 1) or Trust.milestoneThreshold(level + 1 - Trust.STAGES)
    local events = OA.Trade.addTrust(r, math.max(1, need - (t.trust or 0)), "settle")
    say("e2e: stage up to level", level + 1, "events", #events)
    return events
end
Dev.e2eStageUp = E2E.stageUp

-- The first supply down by the character now, with its title (FirstSupply.check's).
function E2E.firstSupply()
    local r = record()
    local ok = Dev.firstSupply()
    if ok then
        OA.Sync.title(r.id, { key = "IGUI_OA_Title_FirstSupply", sub = "IGUI_OA_Title_Marked", style = "unveil",
            fallback = "good" })
    end
    return ok
end

-- The world's first supply as it comes after the game's helicopter (FirstSupply: its window passed): the game's own
-- helicopter comes for the character now (the debug's testHelicopter: it hovers and draws the zombies as on its
-- day), goes after E2E.HELI_SECONDS of play (endHelicopter), and the supply comes down then. Setting another beat
-- calls it off.
E2E.HELI_SECONDS = 40
local heliTimer

function E2E.cancelHeli()
    if heliTimer then
        Events.OnTick.Remove(heliTimer)
        heliTimer = nil
        if endHelicopter then endHelicopter() end
    end
end

function E2E.heliThenSupply()
    E2E.cancelHeli()
    if not testHelicopter then return E2E.firstSupply() end
    testHelicopter()
    local due = getTimestampMs() + E2E.HELI_SECONDS * 1000
    say("e2e: the helicopter comes; the first supply as it goes, in", E2E.HELI_SECONDS, "s")
    heliTimer = function()
        if getTimestampMs() < due then return end
        Events.OnTick.Remove(heliTimer)
        heliTimer = nil
        endHelicopter()
        E2E.firstSupply()
    end
    Events.OnTick.Add(heliTimer)
end

-- A supply crate by the character now with what waits for the record's next one (the story's papers, the sample case,
-- the field call device, the last crate of the handover), as a drop with no settlement: the crate's own story (S6,
-- S7 at their tiers) comes as it is loaded. Returns whether a crate came.
function E2E.supplyNow()
    local r = record()
    local Trade = OA.Trade
    OA.Story.flushSupply(r)
    local cargo = Trade.takeDrop(r)
    for _, spec in ipairs(Trade.crateExtras(r, nil)) do cargo[#cargo + 1] = spec end
    if #cargo == 0 then say("supply: nothing waits for a crate") return false end
    local player = getPlayer()
    local entry = { owner = r.id, x = math.floor(player:getX()) + 2, y = math.floor(player:getY()),
        z = math.floor(player:getZ()), search = true, cargo = cargo, parachute = true }
    local done = Trade.Heli.setDown(entry)
    Trade.Heli.noise(entry.x, entry.y, entry.z)
    Trade.Heli.dropped(r, done, nil)
    say("supply crate with", #cargo, "items")
    return done
end

-- The helicopter: the pending call comes now (Dev.heliNow).
function E2E.heliNow()
    return Dev.heliNow()
end

-- 10 in the morning (the night lines and the dark are a beat of their own), always ahead. The world's age is the nights
-- the game counted and the hour (getWorldAgeHours), and the game counts a night as a tick takes its clock past 7 (and a
-- day past midnight): the clock set straight to 10 from the small hours lost a day, and from the afternoon went back.
-- So the clock is set just short of midnight (past 10) and of 7, and the game's own ticks go past them.
local morningStep

function E2E.morning()
    if morningStep then Events.OnTick.Remove(morningStep) end
    local time = getGameTime()
    local hour = time:getTimeOfDay()
    if hour >= 7 and hour < 10 then
        time:setTimeOfDay(10.0)
        say("time 10:00")
        return
    end
    local step = hour >= 10 and "midnight" or "seven"
    time:setTimeOfDay(step == "midnight" and 23.995 or 6.995)
    morningStep = function()
        local now = getGameTime():getTimeOfDay()
        if step == "midnight" then
            if now < 1 then
                step = "seven"
                getGameTime():setTimeOfDay(6.995)
            end
        elseif now > 7 and now < 8 then
            Events.OnTick.Remove(morningStep)
            morningStep = nil
            getGameTime():setTimeOfDay(10.0)
            say("time 10:00, the next morning")
        end
    end
    Events.OnTick.Add(morningStep)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- To just outside a mission's circle.

-- The mission whose circle to go to: the main one when it has a circle, else the special request's.
local function missionArea(r)
    for _, m in ipairs(OA.Missions.live(r)) do
        if m.area then return m end
    end
    return nil
end

local function zombieNear(x, y, d)
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if math.abs(z:getX() - x) <= d and math.abs(z:getY() - y) <= d then return true end
    end
    return false
end

-- An open square to stand on: outdoors, walkable, no building, no zombie within 5.
local function standable(square)
    if not square or not square:isFree(false) or not square:isOutside() or square:getBuilding() then return false end
    return not zombieNear(square:getX(), square:getY(), 5)
end

-- The square nearest (x, y) within AROUND that standable takes, or nil (also when the squares are not loaded).
local function standNear(x, y)
    local best, bestD
    for dy = -E2E.AROUND, E2E.AROUND do
        for dx = -E2E.AROUND, E2E.AROUND do
            local d = dx * dx + dy * dy
            if not bestD or d < bestD then
                local square = getCell():getGridSquare(x + dx, y + dy, 0)
                if standable(square) then best, bestD = square, d end
            end
        end
    end
    return best
end

-- Where outside the circle: from its middle toward the base (the terminal, else the character), OUTSIDE squares past
-- its edge; north when the base is inside the circle.
function E2E.outsidePoint(area, bx, by)
    local dx, dy = (bx or area.x) - area.x, (by or area.y) - area.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < area.r then dx, dy, len = 0, -1, 1 end
    local d = area.r + E2E.OUTSIDE
    return math.floor(area.x + dx / len * d + 0.5), math.floor(area.y + dy / len * d + 0.5)
end

local pending = nil  -- a move waiting for its squares: { x, y, ticks }

local function settle()
    if not pending then return end
    pending.ticks = pending.ticks + 1
    local square = standNear(pending.x, pending.y)
    if square or pending.ticks > 120 then
        Events.OnTick.Remove(settle)
        local done = pending
        pending = nil
        if square then
            getPlayer():teleportTo(square:getX() + 0.5, square:getY() + 0.5, 0)
            say("outside the circle at", square:getX(), square:getY())
        else
            say("outside the circle: no open square near", done.x, done.y, "(stayed at the point)")
        end
    end
end

-- Puts the character just outside the mission's circle, on open ground on the way from the base. Returns the point, or
-- nil when no mission has a circle (an offer: start it first).
function E2E.toMission()
    local r = record()
    local m = missionArea(r)
    if not m then say("mission: none with a circle (start it first)") return nil end
    local t = r.heli and r.heli.terminal
    local player = getPlayer()
    local x, y = E2E.outsidePoint(m.area, t and t.x or player:getX(), t and t.y or player:getY())
    local square = standNear(x, y)
    if square then
        player:teleportTo(square:getX() + 0.5, square:getY() + 0.5, 0)
        say("outside the circle at", square:getX(), square:getY())
        return square:getX(), square:getY()
    end
    -- not loaded yet: there first, the square picked once it is
    player:teleportTo(x + 0.5, y + 0.5, 0)
    if not pending then Events.OnTick.Add(settle) end
    pending = { x = x, y = y, ticks = 0 }
    return x, y
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The timers: each that runs now, with the hours left and how to set it to fire at the next looks.

-- { { id =, key = (IGUI_OADev_E2E_Timer_<key>), arg =, left = hours, soon = fn } } of the record's running timers.
function E2E.timers(r)
    r = r or record()
    local now = OA.hours()
    local lead = E2E.LEAD
    local list = {}
    local function add(id, left, soon, key, arg)
        list[#list + 1] = { id = id, key = key or id, arg = arg, left = left, soon = soon }
    end
    local Missions, Rewards, Data = OA.Missions, OA.Rewards, OA.StoryData
    for _, m in ipairs(Missions.live(r)) do
        local tag = m.special and "special" or "main"
        if (m.state == "open") and m.deadline then
            -- the deadline moved keeps the time the mission had (the day-left warning wants two days of it), and its
            -- day-left warning when that came already (a deadline the game moves warns again: it only moves later)
            local function moveTo(at)
                local warned = m.warned == m.deadline
                m.issued = at - (m.deadline - (m.issued or now))
                m.deadline = at
                if warned then m.warned = at end
            end
            add(tag .. "Deadline", m.deadline - now, function() moveTo(now + lead) end)
            if not m.special and m.deadline - (m.issued or now) >= Missions.WARN_SPAN and m.warned ~= m.deadline then
                add("dayLeft", m.deadline - now - Missions.WARN_HOURS, function()
                    moveTo(now + Missions.WARN_HOURS - lead)
                    m.warned = nil
                end)
            end
        end
        if m.state == "sealed" and m.sealedAt then
            local span = Rewards.hours(Data.SEALED_LOST_DAYS)
            add("sealed", m.sealedAt + span - now, function() m.sealedAt = now - span + lead end)
        end
        if m.swap and m.swap.stage == "waiting" then
            add("swap", Data.SWAP_WAIT_HOURS - (m.swap.waited or 0), function()
                m.swap.waited = math.max(0, Data.SWAP_WAIT_HOURS - lead)
            end)
        end
        if m.field and m.field.stage == "calling" and m.field.arrive then
            add("field", m.field.arrive - now, function() m.field.arrive = now + lead end)
        end
        if m.carry and m.carry.start then
            -- the warm grade's edge: the cooler is carried as long as it takes to reach it, less the lead
            local edge = (Rewards.COOLER_GOOD - Rewards.COOLER_START) / Rewards.COOLER_RATE
            local carried = now - m.carry.start
            if carried < edge then add("cooler", edge - carried, function() m.carry.start = now - edge + lead end) end
        end
    end
    local heli = r.heli
    if heli and heli.call and heli.call.arrive then
        add("heli", heli.call.arrive - now, function() heli.call.arrive = now + lead end)
    end
    if heli and heli.next and heli.next > now then
        add("heliNext", heli.next - now, function() heli.next = nil end)
    end
    local s = r.missions
    if s and not s.active and (s.nextAt or 0) > now and Missions.opened(r) then
        add("offer", s.nextAt - now, function() s.nextAt = now + lead end)
    end
    local sp = s and s.special
    if sp and not sp.mission and not sp.offer and (sp.nextAt or 0) > now and Missions.specialOpen(r) then
        add("specialOffer", sp.nextAt - now, function() sp.nextAt = now + lead end)
    end
    -- the calls timed by an earlier one (S2B half a day after S2, S4B the next day)
    local c = r.comms
    if c then
        for _, e in ipairs(OA.CommsData.ENTRIES) do
            if e.kind ~= "say" and not c.fired[e.id] and not c.played[e.id] and not c.dropped[e.id] then
                local after, h = string.match(e.trigger, "^after:(%w+):(%d+)$")
                if after and c.played[after] then
                    h = tonumber(h)
                    add("call_" .. e.id, c.played[after] + h - now, function() c.played[after] = now - h + lead; OA.Comms.changed() end,
                        "call", e.id)
                end
                local nextday = string.match(e.trigger, "^nextday:(%w+)$")
                if nextday and c.played[nextday] then
                    local left = OA.dayStart(OA.day(c.played[nextday]) + 1) - now
                    add("call_" .. e.id, left, function() c.played[nextday] = now - 24; OA.Comms.changed() end, "call", e.id)
                end
            end
        end
        -- a short call held only by the gap after the last call (s6_list after S6)
        local Comms, gap, last = OA.Comms, OA.Comms.SHORT_GAP, nil
        for id, at in pairs(c.played) do
            local e = OA.CommsData.BY_ID[id]
            if e and e.kind ~= "say" and (not last or at > last) then last = at end
        end
        for _, e in ipairs(OA.CommsData.ENTRIES) do
            if last and e.kind == "short" and not Comms.ready(r, e.id, now) and Comms.ready(r, e.id, last + gap) then
                add("short", last + gap - now, function()
                    for id, at in pairs(c.played) do
                        if at > now + lead - gap then c.played[id] = now + lead - gap end
                    end
                    Comms.changed()
                end, "call", e.id)
                break
            end
        end
    end
    local u = r.upgrades
    if u and u.adapt and u.adapt.endsAt and u.adapt.endsAt > now then
        add("adapt", u.adapt.endsAt - now, function() u.adapt.endsAt = now + lead end)
    end
    return list
end

-- Sets a timer (by its id in E2E.timers) to fire at the next looks. Returns whether it was running.
function E2E.timerSoon(id)
    local r = record()
    for _, t in ipairs(E2E.timers(r)) do
        if t.id == id then
            t.soon()
            for _, section in ipairs({ "trade", "comms", "missions", "upgrades" }) do OA.Sync.changed(section, r.id) end
            say("timer", id, "set to fire within", E2E.LEAD * 60, "game minutes")
            return true
        end
    end
    say("timer", id, "is not running")
    return false
end

-- The timers as lines for the console: "id  hours left".
function E2E.timerLines()
    local lines = {}
    for _, t in ipairs(E2E.timers()) do lines[#lines + 1] = t.id .. "  " .. string.format("%.1f", t.left) .. "h" end
    for _, line in ipairs(lines) do say(line) end
    return lines
end

-- pzdev's names.
Dev.e2e = E2E.set
Dev.e2eNext = E2E.next
Dev.toMission = E2E.toMission
Dev.timerLines = E2E.timerLines
Dev.timerSoon = E2E.timerSoon

return E2E
