-- Operation Acorn Dev: what the panel's pages do to each part of the mod (trade, economy, machines, gear, upgrades,
-- infection, missions, effects), as functions of OperationAcorn.Dev: the console and tools/pzdev.py call them too.
-- Each goes through the mod's own functions, so the record stays whole and the screens follow, prints a "[dev] ..."
-- line and returns something a check can test. Single player, debug mode only; they change the save.
if not isDebugEnabled() then return end
require "OperationAcorn/Dev/Dev"
local OA = OperationAcorn
local Dev = OA.Dev
local say = Dev.say

local function record()
    local r = Dev.record()
    if not r then error("no record yet", 3) end
    return r
end

local function trade(r)
    return OA.Store.section(r, "trade")
end

-- ---- items -------------------------------------------------------------------------------------------------------

-- n of an item (a full type) into the inventory. Returns how many came.
function Dev.give(fullType, n)
    local inv = getPlayer():getInventory()
    local made = 0
    for _ = 1, n or 1 do
        if inv:AddItem(fullType) then made = made + 1 end
    end
    say("given", fullType, made)
    return made
end

-- Several items of this mod at once: { "Name", ... } (one each).
function Dev.giveAll(names)
    local made = 0
    for _, name in ipairs(names) do made = made + Dev.give("OperationAcorn." .. name, 1) end
    return made
end

-- The team's welder as the shop delivers it (the vanilla torch with the team's mark, full, named).
function Dev.giveWelder()
    local item = OA.Trade.Objects.makeItem(OA.Shop.WELDER)
    if item then getPlayer():getInventory():AddItem(item) end
    say("given", "team welder", item and 1 or 0)
    return item
end

-- One of each field tool.
function Dev.giveFieldTools()
    local made = 0
    for _, t in ipairs(OA.Shop.FIELD_TOOLS) do made = made + Dev.give(OA.Shop.fieldType(t[1]), 1) end
    return made
end

-- ---- trade -------------------------------------------------------------------------------------------------------

function Dev.addCredits(n)
    local r = record()
    local t = trade(r)
    t.credits = (t.credits or 0) + n
    OA.Sync.changed("trade", r.id)
    say("credits", t.credits)
    return t.credits
end

-- The trust a stage (1..5) starts at, or a milestone (6 is the first) after the last stage.
function Dev.stage(level)
    local Trust = OA.Trust
    local amount = 0
    if level >= 1 and level <= Trust.STAGES then amount = Trust.stageThreshold(level)
    elseif level > Trust.STAGES then amount = Trust.milestoneThreshold(level - Trust.STAGES) end
    Dev.trust(amount)
    return amount
end

-- The trade state in a few numbers: credits, trust, stage, milestones; the helicopter's pending call (hours to its
-- arrival, or nil) and the hours until the next call may be made (0 when it may).
function Dev.tradeState()
    local r = Dev.record()
    if not r then return nil end
    local t = trade(r)
    local heli = OA.Trade.heli(r)
    local now = OA.hours()
    local arrive = heli.call and heli.call.arrive and (heli.call.arrive - now) or nil
    local wait = heli.next and math.max(0, heli.next - now) or 0
    return { credits = t.credits or 0, trust = t.trust or 0, stage = t.stage or 0, milestones = t.milestones or 0,
        arrive = arrive, wait = wait, first = r.first and r.first.done == true }
end

-- The helicopter of the pending call comes now: it settles, pays and drops. Returns whether there was a call.
function Dev.heliNow()
    local r = record()
    local heli = OA.Trade.heli(r)
    if not heli.call then say("helicopter: no call pending") return false end
    heli.call.arrive = OA.hours()
    OA.Trade.Heli.arrive(r)
    say("helicopter arrived")
    return true
end

-- The next call may be made at once.
function Dev.heliReady()
    local r = record()
    OA.Trade.heli(r).next = nil
    OA.Sync.changed("trade", r.id)
    say("helicopter: next call allowed now")
end

-- The first supply (a delivery box and the manual) put down near the character now; or, with `reset`, waiting again.
function Dev.firstSupply(reset)
    local r = record()
    local First = OA.Trade.FirstSupply
    if reset then
        r.first = nil
        First.plan(r)
        say("first supply waits again")
        return true
    end
    local plan = First.plan(r)
    local ok = First.drop(r, getPlayer())
    if ok then plan.done = true end
    say("first supply dropped", tostring(ok))
    return ok
end

-- A sealed supply crate on clear ground next to the character (by parachute when `parachute`). Returns its object.
function Dev.crateHere(parachute)
    local player = getPlayer()
    local sq = OA.Trade.Objects.findClear(math.floor(player:getX()) + 2, math.floor(player:getY()), 8)
    if not sq then say("crate: no clear ground near") return nil end
    local crate = OA.Trade.Things.makeCrate(sq, { { type = "Base.Battery", count = 2 },
        { type = "OperationAcorn.SampleBundle", count = 1 } }, parachute == true)
    say("crate at", sq:getX(), sq:getY())
    return crate
end

-- The terminal window opened at once: the terminal within reach (else a crude one put down beside the character),
-- counted as powered for the rest of the session so the window does not close for want of power. Returns the window.
local poweredAt = {}
function Dev.openTerminal()
    local player = getPlayer()
    local Objects, Things = OA.Trade.Objects, OA.Trade.Things
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local at
    for dy = -3, 3 do
        for dx = -3, 3 do
            local square = getCell():getGridSquare(px + dx, py + dy, pz)
            if not at and square and Objects.find(square, Objects.TERMINAL) then at = square end
        end
    end
    if not at then
        at = Objects.findClear(px + 1, py, 4)
        if not at or not Things.placeTerminal(player, at, "S", player:getInventory():AddItem("OperationAcorn.CommTerminal")) then
            say("terminal: no square near")
            return nil
        end
    end
    if not Dev.realPowered then
        Dev.realPowered = Objects.powered
        Objects.powered = function(square, object)
            if square and poweredAt[square:getX() .. "," .. square:getY() .. "," .. square:getZ()] then return true end
            return Dev.realPowered(square, object)
        end
    end
    poweredAt[at:getX() .. "," .. at:getY() .. "," .. at:getZ()] = true
    say("terminal opened at", at:getX(), at:getY())
    return OA.Terminal.open(player, at:getX(), at:getY(), at:getZ())
end

-- The shop's weekly counts start over.
function Dev.shopWeekReset()
    local r = record()
    OA.Shop.section(r).week = {}
    OA.Sync.changed("trade", r.id)
    say("shop weekly counts reset")
end

-- Credits below zero: the debt the shop and the settlement react to.
function Dev.debt()
    Dev.credits(-5000)
end

-- ---- economy -----------------------------------------------------------------------------------------------------

-- This week's request list drawn again.
function Dev.redrawRequests()
    local r = record()
    local codex = OA.Codex.section(r)
    codex.req = nil
    local list = OA.Requests.list(r)
    OA.Sync.changed("codex", r.id)
    say("requests redrawn", #list)
    return #list
end

-- The daily upkeep now: the market's day, the request lists, shredding, appraisal caches.
function Dev.daily()
    OA.Economy.daily()
    Dev.changed()
    say("daily upkeep run")
end

-- The market index of every category as one line ("A 1.00 B 0.85 ...").
function Dev.marketLine()
    local parts = {}
    for _, c in ipairs(OA.Categories.LETTERS) do
        parts[#parts + 1] = c .. " " .. string.format("%.2f", OA.Market.index(c) or 1)
    end
    return table.concat(parts, "  ")
end

-- A demand (mult above 1) or glut (below 1) event on a category for a week.
function Dev.marketEvent(category, mult)
    OA.Market.addEvent(category, mult, 7, mult > 1 and "IGUI_OA_Econ_Event_Demand" or "IGUI_OA_Econ_Event_Glut", "dev")
    Dev.changed()
    say("market event", category, mult)
end

-- The codex as if nothing was ever found, searched or killed (what it paid is forgotten too).
function Dev.resetCodex()
    local r = record()
    local c = OA.Codex.section(r)
    c.kinds, c.n, c.cat, c.buildings, c.nb, c.kills = {}, 0, {}, {}, 0, 0
    c.paid = { kinds = 0, cats = {}, buildings = 0, kills = 0 }
    OA.Sync.changed("codex", r.id)
    say("codex reset")
end

-- What the held item is worth now: credits, trust, category; nil without one.
function Dev.appraiseHeld()
    local item = getPlayer():getPrimaryHandItem()
    if not item then say("appraise: nothing held") return nil end
    local r = record()
    local v = OA.Value.appraise(OA.Value.info(item), OA.Value.context(r))
    say("appraise", item:getFullType(), "credits", v.credits, "trust", v.trust, "category", v.category)
    return v, item:getFullType()
end

-- Shredding as if nothing was ever shredded (its yield decay starts over).
function Dev.resetShred()
    local r = record()
    local s = OA.Shred.section(r)
    s.counts, s.first = {}, {}
    say("shred counts reset")
end

-- ---- machines ----------------------------------------------------------------------------------------------------

Dev.MACHINES = { "shredBench", "bulkShredder", "cutter", "woodSaw", "researchStorage", "researchCrate", "propaneRefiner",
    "oilRefiner", "rainStorage", "lure" }
Dev.PARTS = { "MotorOld", "MotorNormal", "MotorModern", "ShredBladeNormal", "CutBladeNormal", "SawBladeNormal",
    "FilterNormal", "SoundproofCover" }

-- What a machine is delivered as: a list of full types (its pieces), or the machine item itself.
function Dev.deliveryOf(kind)
    local fullType = OA.Machines.itemFullType(kind)
    return OA.Machines.deliveryItems(fullType) or { fullType }
end

-- A machine into the inventory as it is delivered (its pieces). Returns how many items.
function Dev.giveMachine(kind)
    local made = 0
    for _, fullType in ipairs(Dev.deliveryOf(kind)) do made = made + Dev.give(fullType, 1) end
    return made
end

-- The machines within `radius` squares of the character: { object, state } for each that is loaded.
function Dev.machinesNear(radius)
    local player = getPlayer()
    local px, py = player:getX(), player:getY()
    local found = {}
    for _, m in pairs(OA.Machines.list()) do
        if math.abs(m.x - px) <= radius and math.abs(m.y - py) <= radius then
            local sq = getCell():getGridSquare(m.x, m.y, m.z)
            local object = sq and OA.Machines.at(sq)
            local state = object and OA.Machines.state(object)
            if state then found[#found + 1] = { object = object, state = state } end
        end
    end
    return found
end

-- The machines near the character work on as if `hours` had passed (their clock is put back, then they update).
-- Returns how many were moved on.
function Dev.advanceMachines(hours, radius)
    local moved = 0
    local now = OA.hours()
    for _, m in ipairs(Dev.machinesNear(radius or 20)) do
        m.state.last = (m.state.last or now) - hours
        OA.Machines.update(m.object)
        moved = moved + 1
    end
    say("machines moved on", hours, "hours:", moved)
    return moved
end

-- One line a machine near the character: kind, on, powered, running, why not.
function Dev.machineLines(radius)
    local lines = {}
    for _, m in ipairs(Dev.machinesNear(radius or 20)) do
        local s = m.state
        lines[#lines + 1] = tostring(s.kind) .. "  on " .. tostring(s.on ~= false) .. "  power "
            .. tostring(OA.Machines.hasPower(m.object)) .. "  running " .. tostring(s.running == true)
            .. (s.reason and ("  " .. tostring(s.reason)) or "")
    end
    return lines
end

-- ---- upgrades ----------------------------------------------------------------------------------------------------

-- The adaptation of the serums taken ends now: the points come.
function Dev.endAdapt()
    local r = record()
    local u = OA.Upgrades.Rules.section(r)
    if not u.adapt then say("adapt: nothing adapting") return false end
    u.adapt.endsAt = OA.hours()
    local ok = OA.Upgrades.Adapt.finish(r)
    say("adapt finished", tostring(ok))
    return ok
end

-- Every tree's capstone opens, as if its meteorite fragment reached the research team (its memo comes too).
-- Returns how many opened now.
function Dev.unsealCapstones()
    local r = record()
    local opened = 0
    for _, tree in ipairs(OA.Upgrades.Data.TREES) do
        if OA.Upgrades.fragmentReceived(r, OA.Upgrades.Data.FRAGMENTS[tree]) then opened = opened + 1 end
    end
    say("capstones opened:", opened)
    return opened
end

-- Every node may tell its first effect again.
function Dev.resetFirstEffects()
    local r = record()
    OA.Upgrades.Rules.section(r).firstEffect = {}
    OA.Sync.changed("upgrades", r.id)
    say("first effects forgotten")
end

-- The adaptation as a line: hours left, or nil.
function Dev.adaptLeft()
    local r = Dev.record()
    local u = r and OA.Upgrades.Rules.section(r)
    local a = u and u.adapt
    return a and a.endsAt and math.max(0, a.endsAt - OA.hours()) or nil
end

-- ---- infection ---------------------------------------------------------------------------------------------------

-- A zombie bite on the left forearm, infected or not; the mod takes it as a new wound (untested).
function Dev.bite(infected)
    local player = getPlayer()
    local bd = player:getBodyDamage()
    local part = bd:getBodyPart(BodyPartType.ForeArm_L)
    part:SetBitten(true)
    part:SetInfected(infected == true)
    if infected then
        bd:setInfected(true)
        bd:setInfectionTime(getGameTime():getWorldAgeHours())
    end
    local r = record()
    OA.Infection.wounded(r, "bite", OA.hours())
    Dev.changed()
    say("bitten, infected", tostring(infected == true))
end

-- The body's infection moved on by `hours` (its start put back).
function Dev.infectionAhead(hours)
    local bd = getPlayer():getBodyDamage()
    if not bd:isInfected() then say("infection: not infected") return false end
    bd:setInfectionTime(bd:getInfectionTime() - hours)
    say("infection moved on", hours)
    return true
end

-- A test now: positive or negative by the body, as the test kit would tell it.
function Dev.test()
    local player = getPlayer()
    local r = record()
    local infected = OA.Upgrades.Serums.infected(player)
    local n = OA.Infection.tested(r, infected, OA.Upgrades.Serums.progress(player), OA.hours())
    Dev.changed()
    say("tested, infected", tostring(infected), "positives", n)
    return infected
end

-- The cure: the body healed of the infection, the mod's record cleared.
function Dev.cure()
    local player = getPlayer()
    OA.Upgrades.Serums.cureBody(player)
    OA.Infection.cured(record())
    Dev.changed()
    say("cured")
end

-- The infection as lines: the body's (infected, progress) and the record's (untested, known, drug, fee).
function Dev.infectionLines()
    local player = getPlayer()
    local r = Dev.record()
    local Serums = OA.Upgrades.Serums
    local lines = { "body infected " .. tostring(Serums.infected(player)) .. "  progress "
        .. string.format("%.2f", Serums.progress(player) or 0) }
    local s = r and OA.Infection.state(r, OA.hours())
    if s then
        lines[#lines + 1] = "untested " .. tostring(s.untested) .. "  known " .. tostring(s.infected)
            .. "  drug " .. (s.drug and (s.drug.kind .. " " .. string.format("%.0f", s.drug.hoursLeft) .. "h") or "-")
            .. "  fee " .. (s.fee and string.format("%.2f", s.fee) or "-")
    else
        lines[#lines + 1] = "record: nothing known"
    end
    return lines
end

-- ---- missions and story -------------------------------------------------------------------------------------------

-- The next mission now, if one is due at this stage. Returns it or nil.
function Dev.startMission()
    local m = OA.Missions.start(record())
    say("mission started", tostring(m and m.place))
    return m
end

-- The current mission ends: "done", "expired" or "lost". Returns whether there was one.
function Dev.finishMission(result)
    local m = Dev.mission()
    if not m then say("finish: no mission") return false end
    OA.Missions.finish(record(), m, result)
    say("mission", result)
    return true
end

-- A hallucination run on the screen now (the option may turn them off).
function Dev.hallucinate(long)
    if not OA.Hallucination then say("hallucination: not loaded") return false end
    OA.Hallucination.start(0, { long = long == true, dx = 1, dy = 0 })
    say("hallucination", long == true and "long" or "short")
    return true
end

-- ---- titles --------------------------------------------------------------------------------------------------------

-- More titles the mod shows, by kind: each the detail the mod's own code sends.
local TITLES = {
    debt = { key = "IGUI_OA_Title_Debt", sub = "IGUI_OA_Title_DebtSub", style = "notice", tone = "red", fallback = "bad" },
    paid = { key = "IGUI_OA_Title_Paid", style = "dust", fallback = "good" },
    cured = { key = "IGUI_OA_Title_Cured", sub = "IGUI_OA_Title_CuredSubDrugs", subArgs = { 12, 3 }, style = "pulse",
        tone = "green", fallback = "good" },
    positive = { key = "IGUI_OA_Title_TestPositive", style = "bleed", fallback = "bad" },
    negative = { key = "IGUI_OA_Title_TestNegative", sub = "IGUI_OA_Title_TestNegativeSub", style = "pulse",
        fallback = "good" },
    firstSupply = { key = "IGUI_OA_Title_FirstSupply", sub = "IGUI_OA_Title_Marked", style = "unveil", fallback = "good" },
    lost = { key = "IGUI_OA_Title_Lost", sub = "IGUI_OA_Title_LostSub_Find", style = "sink", fallback = "bad" },
    guide = { key = "IGUI_OA_Story_DocTitle_infection_guide", sub = "IGUI_OA_Title_GuideSub", style = "type", fallback = "good" },
}

-- Shows a title: the kinds of Dev.title, "stage" (a named stage's card, as the terminal shows it) and "milestone" (the
-- title of a level past the named stages), or one of TITLES.
function Dev.titleMore(kind)
    local r = record()
    local detail
    if kind == "stage" then detail = OA.Story.stageCard(2)
    elseif kind == "milestone" then detail = OA.Story.stageTitle(r, OA.StoryData.LAST_STAGE + 1)
    else detail = TITLES[kind] end
    if not detail then return Dev.title(kind) end
    say("title", kind)
    return OA.Titles.show(nil, detail)
end

return Dev
