-- The easter eggs (NUMBERS 13, LORE 'Easter egg lines'): five things a record does once and is paid for with a
-- permanent effect that stacks with the upgrades and does not depend on their steps.
--   1. a Furbert squirrel delivered: 100,000 credits once and +5 points of the conversion rate (credits only)
--   2. 100 acorns delivered in all (counted across settlements): +50 box capacity
--   3. a dead squirrel delivered: serums cost 0.9 of their price
--   4. a Spiffo toy or costume delivered: +5 points of the shop discount (where a discount applies)
--   5. Branscomb's walkie-talkie, turned on and carried, as the game clock reaches 07:30: helicopter arrival 0.8 of
--      the hours (he always wrote the time of a call as 0730)
-- The delivered ones (1 to 4) are looked for when a crate is settled (Eggs.settle, called by Trade/Settle with the
-- sealed entries); the radio once a day at 07:30 (Eggs.radioLook, from the server's minute event). The record's "eggs"
-- section keeps furbert, squirrel, spiffo and radio (true once given), acorns (the count delivered) and acornsDone;
-- furbertCall is true when the Furbert came before the handover (the team's short call about it, Story/Egg).
-- What the effects change is asked here by the formulas (the accessors below, through Trust.rewards and the shop): the
-- section is not read anywhere else.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
local OA = OperationAcorn
local Eggs = {}
OA.Eggs = Eggs

-- The numbers.
Eggs.CREDITS = 100000           -- the Furbert's one-time pay, on top of its appraisal
Eggs.CONVERSION = 0.05          -- added to the conversion rate (a share: 0.05 is 5 points)
Eggs.ACORN_GOAL = 100           -- acorns delivered in all
Eggs.CAPACITY = 50              -- added to the box capacity
Eggs.SERUM_SCALE = 0.9          -- what a serum's price is multiplied by (the per-tree and the shared one)
Eggs.DISCOUNT = 0.05            -- added to the shop discount (a share)
Eggs.ARRIVAL_SCALE = 0.8        -- what both ends of the helicopter's arrival hours are multiplied by

-- The items. The radio is the one the last crate encloses (Story/Data NOTE_ITEMS last_b); it carries RADIO_MARK in its
-- modData, so that another walkie-talkie of the same type does not count.
Eggs.ITEMS = {
    ["Base.FurbertSquirrel"] = "furbert",
    ["Base.Acorn"] = "acorns",
    ["Base.DeadSquirrel"] = "squirrel",
    ["Base.Spiffo"] = "spiffo",
    ["Base.SpiffoBig"] = "spiffo",
    ["Base.SpiffoSuit"] = "spiffo",
    ["Base.SpiffoTail"] = "spiffo",
}
Eggs.RADIO_TYPE = "Base.WalkieTalkie5"
Eggs.RADIO_MARK = "OA_Branscomb"

-- The radio's hour: the game minute of the day the radio is looked for at (07:30), and the cue sounded then
-- (Sounds.lua).
Eggs.RADIO_MINUTE = 7 * 60 + 30
Eggs.RADIO_CUE = "oa.egg.radio"

-- The texts. The receipt's remarks (E1 before the handover, E1k after it, E2 to E4) and the titles; the title of an
-- egg and the line under it (the effect).
Eggs.NOTES = {
    furbert = "IGUI_OA_Trade_Egg_1",
    furbertAfter = "IGUI_OA_Trade_Egg_1k",
    acorns = "IGUI_OA_Trade_Egg_2",
    squirrel = "IGUI_OA_Trade_Egg_3",
    spiffo = "IGUI_OA_Trade_Egg_4",
}
Eggs.TITLES = {
    furbert = { key = "IGUI_OA_Title_Egg_1", sub = "IGUI_OA_Title_Egg_1Sub", style = "discovery" },
    acorns = { key = "IGUI_OA_Title_Egg_2", sub = "IGUI_OA_Title_Egg_2Sub", style = "stamp" },
    squirrel = { key = "IGUI_OA_Title_Egg_3", sub = "IGUI_OA_Title_Egg_3Sub", style = "discovery" },
    spiffo = { key = "IGUI_OA_Title_Egg_4", sub = "IGUI_OA_Title_Egg_4Sub", style = "discovery" },
    radio = { key = "IGUI_OA_Title_Egg_5", sub = "IGUI_OA_Title_Egg_5Sub", style = "discovery" },
}

-- The record's section (made empty the first time).
function Eggs.section(record)
    return OA.Store.section(record, "eggs")
end

-- Whether a record has had an egg's reward ("furbert", "squirrel", "spiffo", "radio"; "acorns" when the hundred are in).
function Eggs.has(record, egg)
    if not record then return false end
    local s = record.eggs
    if not s then return false end
    if egg == "acorns" then return s.acornsDone == true end
    return s[egg] == true
end

-- The effects, for the formulas. Each gives the neutral value (nothing added, or 1 for a factor) before its egg.
function Eggs.conversionBonus(record) return Eggs.has(record, "furbert") and Eggs.CONVERSION or 0 end
function Eggs.capacityBonus(record) return Eggs.has(record, "acorns") and Eggs.CAPACITY or 0 end
function Eggs.serumScale(record) return Eggs.has(record, "squirrel") and Eggs.SERUM_SCALE or 1 end
function Eggs.discountBonus(record) return Eggs.has(record, "spiffo") and Eggs.DISCOUNT or 0 end
function Eggs.arrivalScale(record) return Eggs.has(record, "radio") and Eggs.ARRIVAL_SCALE or 1 end

-- Whether the Furbert came before the handover, so that the team's call about it is due (Story/Egg).
function Eggs.furbertCall(record)
    return record ~= nil and record.eggs ~= nil and record.eggs.furbertCall == true
end

-- All the effects that go into the rewards table (Trust.rewards): { rate, box, discount (added), arrive (factor) }.
function Eggs.bonuses(record)
    return { rate = Eggs.conversionBonus(record), box = Eggs.capacityBonus(record),
        discount = Eggs.discountBonus(record), arrive = Eggs.arrivalScale(record) }
end

-- The rewards table is worked out again when an effect changes (it is cached by the levels' revision, Trust.rewards).
local function refresh(record)
    local t = OA.Store.section(record, "trade")
    t.levelsRev = (t.levelsRev or 0) + 1
    OA.Sync.changed("trade", record.id)
end

local function title(record, egg)
    local def = Eggs.TITLES[egg]
    OA.Sync.title(record.id, { key = def.key, sub = def.sub, style = def.style })
end

-- A delivered egg's title waits for its flight's drop title (Heli.dropped): the settlement is made as the helicopter comes,
-- and the eggs read as part of what the drop paid, not before it. Kept in the section (`held`) until then.
local function hold(record, egg)
    local s = Eggs.section(record)
    s.held = s.held or {}
    s.held[#s.held + 1] = egg
end

-- The held titles shown, after the drop's own (Heli.dropped).
function Eggs.release(record)
    local s = record and record.eggs
    local held = s and s.held
    if not held then return end
    s.held = nil
    for _, egg in ipairs(held) do title(record, egg) end
end

-- Whether the record has been handed over to the management (its remarks are theirs then).
local function handedOver(record)
    return OA.Story ~= nil and OA.Story.handedOver ~= nil and OA.Story.handedOver(record)
end

-- A settlement's sealed entries ({ info = { fullType }, count }) looked at for the delivered eggs. Gives the first
-- time of each its reward and its title, and counts the acorns. Returns { credits (the Furbert's pay, to add to this
-- settlement's), notes (the receipt remarks' keys, in order) }. The Furbert, squirrel and Spiffo remarks come with
-- the reward (the first time only); the acorns' with every settlement that has acorns.
function Eggs.settle(record, entries)
    local seen = {}
    for _, entry in ipairs(entries or {}) do
        local egg = entry.info and Eggs.ITEMS[entry.info.fullType]
        if egg then seen[egg] = (seen[egg] or 0) + (entry.count or 1) end
    end
    local out = { credits = 0, notes = {} }
    if not (seen.furbert or seen.acorns or seen.squirrel or seen.spiffo) then return out end
    local s = Eggs.section(record)
    local changed = false
    if seen.furbert and not s.furbert then
        s.furbert = true
        changed = true
        local after = handedOver(record)
        if not after then s.furbertCall = true end
        out.credits = Eggs.CREDITS
        out.notes[#out.notes + 1] = after and Eggs.NOTES.furbertAfter or Eggs.NOTES.furbert
        hold(record, "furbert")
    end
    if seen.acorns then
        s.acorns = (s.acorns or 0) + seen.acorns
        out.notes[#out.notes + 1] = Eggs.NOTES.acorns
        if s.acorns >= Eggs.ACORN_GOAL and not s.acornsDone then
            s.acornsDone = true
            changed = true
            hold(record, "acorns")
        end
    end
    for _, egg in ipairs({ "squirrel", "spiffo" }) do
        if seen[egg] and not s[egg] then
            s[egg] = true
            changed = true
            out.notes[#out.notes + 1] = Eggs.NOTES[egg]
            hold(record, egg)
        end
    end
    if changed then refresh(record) end
    return out
end

-- Whether the game clock is at 07:30 now. The whole of the per-minute work: one clock read and a compare.
function Eggs.radioTime()
    return math.floor(getGameTime():getTimeOfDay() * 60 + 0.5) == Eggs.RADIO_MINUTE
end

-- Branscomb's walkie-talkie turned on in what the character carries (hands and bags), or nil. A typed lookup, made
-- only at 07:30.
function Eggs.findRadio(character)
    -- oa-scan: ok (once a day, at 07:30 only, by the typed lookup; not per minute)
    local list = character:getInventory():getAllTypeRecurse(Eggs.RADIO_TYPE)
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if item:hasModData() and item:getModData()[Eggs.RADIO_MARK] then
            local device = item:getDeviceData()
            if device and device:getIsTurnedOn() then return item end
        end
    end
    return nil
end

-- A record's character at the minute: at 07:30, with the radio on, the tone sounds once and the reward comes. Returns
-- whether it did. (The caller has checked Eggs.radioTime; nothing is searched for a record that has had it.)
function Eggs.radioLook(record, character)
    if not record or not character or Eggs.section(record).radio then return false end
    if not Eggs.findRadio(character) then return false end
    Eggs.section(record).radio = true
    OA.Sync.sound(record.id, Eggs.RADIO_CUE)
    title(record, "radio")
    refresh(record)
    return true
end

return Eggs
