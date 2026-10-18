-- The order of the team's calls (SCENES.md 3): what has fired, what waits, what is played, what is dropped, and the
-- record the comms tab lists. Pure: the record's `comms` section holds ids, the hours things happened and the tier each
-- was played at; the text is in the translations (Story/CommsData). The story and the missions tell this what happened
-- (Comms.fire, Comms.enterTier); the terminal asks what to play next (Comms.next) and says what it played
-- (Comms.played); the field's code says a monologue (Comms.say).
--
-- The rules: an entry plays once it has fired and the entry it waits for has been played or dropped. A terminal entry
-- that has not fired by the time its tier is passed is dropped, and dropped entries wait for nothing and hold nothing
-- up. A story mission's entries are never dropped, nor a branch's (Story/Branches: a side thread that comes on a
-- condition of its own and waits only for its own entries). Entries play in the order of CommsData.ENTRIES.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/CommsData"
local OA = OperationAcorn
local Data = OA.CommsData
local Comms = {}
OA.Comms = Comms

-- The record's comms section: fired = id -> hours, played = id -> hours, dropped = id -> true, log = { { id, tier } }
-- in the order played (the tab's record), afterSays = the after-handover monologues said, tier = the tier last entered,
-- era = "admin" for a record that came into the world after the handover (Comms.join).
function Comms.section(record)
    local s = OA.Store.section(record, "comms")
    s.fired = s.fired or {}
    s.played = s.played or {}
    s.dropped = s.dropped or {}
    s.log = s.log or {}
    s.afterSays = s.afterSays or 0
    s.tier = s.tier or 0
    return s
end

local function done(s, id)
    return s.played[id] ~= nil or s.dropped[id] == true
end

-- Whether an entry has been played or dropped.
function Comms.done(record, id)
    return done(Comms.section(record), id)
end

-- Whether nobody answers on the team's side (SCENES S4): after the day the line went dead (S4) until the next call
-- (S4B). The trade goes on by itself then: a call is taken as an automatic one.
function Comms.silent(record)
    local s = Comms.section(record)
    return s.played.S4 ~= nil and not done(s, "S4B")
end

-- Fires every entry whose trigger is `trigger` (a string as CommsData names them). Returns the ids fired.
function Comms.fire(record, trigger, now)
    local s = Comms.section(record)
    local fired = {}
    for _, e in ipairs(Data.ENTRIES) do
        if e.kind ~= "say" and e.trigger == trigger and (e.era == nil or e.era == s.era) and not s.fired[e.id] and not done(s, e.id) then
            s.fired[e.id] = now or OA.hours()
            fired[#fired + 1] = e.id
        end
    end
    return fired
end

-- The entries timed by an earlier one: "after:<id>:<hours>" and "nextday:<id>". `day` turns hours into a game day.
function Comms.update(record, now, day)
    local s = Comms.section(record)
    now = now or OA.hours()
    day = day or OA.day
    local fired = {}
    for _, e in ipairs(Data.ENTRIES) do
        if not s.fired[e.id] and not done(s, e.id) then
            local ref, hours = string.match(e.trigger, "^after:(%w+):(%d+)$")
            local due = false
            if ref and s.played[ref] then
                due = now >= s.played[ref] + tonumber(hours)
            else
                ref = string.match(e.trigger, "^nextday:(%w+)$")
                if ref and s.played[ref] then due = day(now) > day(s.played[ref]) end
            end
            if due then
                s.fired[e.id] = now
                fired[#fired + 1] = e.id
            end
        end
    end
    return fired
end

-- A tier entered (and every one between the last and this): the entries of the passed tiers that never fired are
-- dropped, then the tier's own fire.
function Comms.enterTier(record, tier, now)
    local s = Comms.section(record)
    local fired = {}
    for t = s.tier + 1, tier do
        for _, e in ipairs(Data.ENTRIES) do
            if e.kind ~= "say" and not e.mission and not e.keep and not e.branch and e.tier < t and not s.fired[e.id]
                and not done(s, e.id) then
                s.dropped[e.id] = true
            end
        end
        for _, id in ipairs(Comms.fire(record, "tier:" .. t, now)) do fired[#fired + 1] = id end
    end
    if tier > s.tier then s.tier = tier end
    return fired
end

-- A record that comes into a world where another character has gone further (CANON S19): the team's one-time events
-- (an entry's `world`) the world has passed are dropped, and after the handover every entry of the team's tiers is,
-- and the record takes the entries of the after-handover era (`era`) in their place. `tier` is the furthest tier a
-- character of the world has reached, `admin` whether the handover has happened there.
function Comms.join(record, tier, admin)
    local s = Comms.section(record)
    for _, e in ipairs(Data.ENTRIES) do
        if e.kind ~= "say" and not e.branch and not s.fired[e.id] and not done(s, e.id) then
            local passed = e.world ~= nil and e.world <= tier
            if admin and e.era == nil and e.tier <= Data.TEAM_LAST_TIER then passed = true end
            if passed then s.dropped[e.id] = true end
        end
    end
    if admin then s.era = "admin" end
end

-- An entry no longer wanted (a branch's call whose matter is settled before it was played): dropped, unless played.
function Comms.drop(record, id)
    local s = Comms.section(record)
    if done(s, id) or not Data.BY_ID[id] then return false end
    s.dropped[id] = true
    return true
end

-- A short call is a word at the team's regular hour (LORE 6 '짧은 교신'), not a line after a scene: it comes no sooner
-- than this many game hours after the last call played.
Comms.SHORT_GAP = 2

-- When the last call (not a monologue) was played, or nil.
local function lastCall(s)
    local last
    for id, at in pairs(s.played) do
        local e = Data.BY_ID[id]
        if e and e.kind ~= "say" and (not last or at > last) then last = at end
    end
    return last
end

-- Whether an entry may play now (`now` in hours, the game's by default): fired, not played, what it waits for done,
-- and a short call SHORT_GAP after the last call.
function Comms.ready(record, id, now)
    local s = Comms.section(record)
    local e = Data.BY_ID[id]
    if not e or not s.fired[id] or done(s, id) then return false end
    if e.waits ~= nil and not done(s, e.waits) then return false end
    if e.kind == "short" then
        local last = lastCall(s)
        if last and (now or OA.hours()) < last + Comms.SHORT_GAP then return false end
    end
    return true
end

-- The next entry to play at `place`: "terminal" (scenes and short calls) or "field" (the calls on the spot), `now` as
-- Comms.ready's. nil when there is none.
function Comms.next(record, place, now)
    for _, e in ipairs(Data.ENTRIES) do
        local here = (place == "field") == (e.kind == "field")
        if here and e.kind ~= "say" and Comms.ready(record, e.id, now) then return e end
    end
    return nil
end

-- How many terminal entries are ready (the comms tab's dot, the terminal's blinking light).
function Comms.waiting(record)
    local n = 0
    for _, e in ipairs(Data.ENTRIES) do
        if e.kind ~= "say" and e.kind ~= "field" and Comms.ready(record, e.id) then n = n + 1 end
    end
    return n
end

local function addLog(s, id, tier)
    s.log[#s.log + 1] = { id = id, tier = tier }
end

-- An entry was played (or skipped: it counts the same) at `tier`. It goes into the record.
function Comms.played(record, id, tier, now)
    local s = Comms.section(record)
    if s.played[id] then return false end
    s.played[id] = now or OA.hours()
    addLog(s, id, tier or s.tier)
    return true
end

-- A field monologue's id for a story mission's event ("say:<story id>:<event>"), said once: it goes into the record.
-- Returns the id when it is to be said, or nil.
function Comms.say(record, storyId, event, tier, now)
    local s = Comms.section(record)
    local trigger = "say:" .. storyId .. ":" .. event
    for _, e in ipairs(Data.ENTRIES) do
        if e.kind == "say" and e.trigger == trigger then
            if s.played[e.id] then return nil end
            s.played[e.id] = now or OA.hours()
            addLog(s, e.id, tier or s.tier)
            return e.id
        end
    end
    return nil
end

-- The monologue of an after-handover story mission's circle: the next of CommsData.AFTER_SAYS, nil once all are said.
function Comms.afterSay(record, tier, now)
    local s = Comms.section(record)
    local id = Data.AFTER_SAYS[s.afterSays + 1]
    if not id then return nil end
    s.afterSays = s.afterSays + 1
    s.played[id] = now or OA.hours()
    addLog(s, id, tier or s.tier)
    return id
end

return Comms
