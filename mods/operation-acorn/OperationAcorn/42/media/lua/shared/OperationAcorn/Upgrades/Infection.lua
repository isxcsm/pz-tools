-- Infection and what the terminal and the economy make of it (DESIGN 10, DESIGN-terminal 17): whether a zombie wound has
-- been tested for, whether the player knows they are infected, the delay drug that holds the infection back, and the
-- delivery fee that goes with it. The state lives in the player's record, in the section `infection`, so that the
-- server settles the fee from it and the screens read it:
--   untested  true from a zombie wound (or an infection found) until a test
--   known     true from a positive test until the cure; only then is the progress shown
--   progress  0 to 1, the infection's progress as last seen (read only while known)
--   drug      { kind = "long" | "short", till = the world age hour it ends, age = the hours the infection is held at
--             (nil: nothing to hold, the body was not infected when it was taken) }
-- and what the presentation (DESIGN-terminal 17.6) remembers:
--   since     the world age hour the wound or the infection was first noticed, until a negative test or the cure
--   doses     the delay drugs taken since then (the cure's stamp tells how many it took)
--   positives the positive tests ever made (the first one is told differently, and brings the handling notice)
--   told      { delay = true } what was said once and never again
-- The rules here are pure (a record and a clock); the body is touched by Serums.lua and by the client's watch
-- (Upgrades/Hooks.lua), which use the wound detection at the end of this file.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Say"
local OA = OperationAcorn
local Infection = {}
OA.Infection = Infection

-- The share of a delivery's credits withheld while the fee applies.
Infection.FEE = 0.3
-- How long each drug holds the infection, in hours.
Infection.DRUG_HOURS = { long = 7 * 24, short = 24 }
-- The wounds a zombie makes.
Infection.WOUNDS = { bite = true, scratch = true, cut = true }
-- An infection cured within this many days is a short one, at this many or more a long one (the cure's lines and
-- certificate follow its length).
Infection.SHORT_DAYS, Infection.LONG_DAYS = 14, 60

-- The self-talk (DESIGN-terminal 18; keys IGUI_OA_Say_<bundle>_<n>). Cured: lines 1 for a short infection, 2 for a long
-- one, the rest either. TestPositive: lines 1-2 the first positive test ever, 3-4 the ones after. DrugLost rests a day.
-- None of the lines says anything about a wound: what the player may know is only what the tests and the body show.
OA.Say.define("CureStart", {})
OA.Say.define("Cured", { tags = { [1] = { length = "short" }, [2] = { length = "long" } } })
OA.Say.define("TestPositive", { tags = { [1] = { first = true }, [2] = { first = true }, [3] = { first = false },
    [4] = { first = false } } })
OA.Say.define("TestNegative", {})
OA.Say.define("DrugLost", { cooldown = 24 })
OA.Say.define("Reversal", {})
OA.Say.define("DelayFirst", {})

function Infection.section(record)
    return OA.Store.section(record, "infection")
end

-- ---- reading the state --------------------------------------------------------------------------------------------

-- The drug that lasts at `now`: its kind and the hours it has left, or nil.
function Infection.drug(inf, now)
    local d = inf and inf.drug
    if d and d.till > now then return d.kind, d.till - now end
    return nil
end

-- The age (hours) the infection is held at by a drug that lasts at `now`, or nil.
function Infection.holdAge(record, now)
    local d = record.infection and record.infection.drug
    if d and d.age and d.till > now then return d.age end
    return nil
end

-- The delivery fee's rate for a record: Infection.FEE while a zombie wound is untested or the infection is known, else 0.
function Infection.feeRate(record)
    local inf = record and record.infection
    if inf and (inf.known or inf.untested) then return Infection.FEE end
    return 0
end

-- The fee on `credits`: the credits withheld (whole, never negative) and the rate.
function Infection.fee(record, credits)
    local rate = Infection.feeRate(record)
    if rate <= 0 or (credits or 0) <= 0 then return 0, rate end
    return OA.round(credits * rate), rate
end

-- How a cured infection is told: whole days since it was first noticed (at least 1), the delay drugs taken since, and
-- its length, "short", "normal" or "long". Read before Infection.cured clears it.
function Infection.summary(record, now)
    local inf = record and record.infection
    local since = inf and inf.since
    local days = since and math.max(1, math.floor((now - since) / 24 + 0.5)) or 1
    local length = "normal"
    if days < Infection.SHORT_DAYS then length = "short" elseif days >= Infection.LONG_DAYS then length = "long" end
    return days, (inf and inf.doses) or 0, length
end

-- What the terminal shows of the infection, or nil when there is nothing to show:
--   infected  the player knows they are infected (a positive test)
--   untested  a zombie wound that has not been tested for (never with infected)
--   progress  0 to 1, only after a positive test
--   drug      nil, or { kind = "long" | "short", hoursLeft }
--   fee       the delivery fee's rate while it applies, else nil
function Infection.state(record, now)
    local inf = record and record.infection
    if not inf then return nil end
    local kind, left = Infection.drug(inf, now or OA.hours())
    local known = inf.known == true
    local untested = inf.untested == true and not known
    if not (known or untested or kind) then return nil end
    return {
        infected = known,
        untested = untested,
        progress = known and (inf.progress or 0) or nil,
        drug = kind and { kind = kind, hoursLeft = left } or nil,
        fee = (known or untested) and Infection.FEE or nil,
    }
end

-- The level (1 to 4) the moodle of a drug shows for the hours it has left: a day or less, up to 3, 5 or 7 days.
function Infection.drugLevel(hoursLeft)
    if hoursLeft > 120 then return 4 end
    if hoursLeft > 72 then return 3 end
    if hoursLeft > 24 then return 2 end
    return 1
end

-- ---- changing it (where the world is decided) ---------------------------------------------------------------------

-- A delay drug taken at `now`, replacing the one before it (the time left does not add up). `age` is how old the
-- infection was (hours) when taken, nil when the body was not infected. A drug that holds the infection keeps its age,
-- so replacing it does not let the age drift. Returns the new drug, nil for a kind that does not exist.
function Infection.dose(record, kind, now, age)
    local hours = Infection.DRUG_HOURS[kind]
    if not hours then return nil end
    local inf = Infection.section(record)
    local old = inf.drug
    if old and old.till > now and old.age then age = old.age end
    inf.drug = { kind = kind, till = now + hours, age = age }
    if inf.since then inf.doses = (inf.doses or 0) + 1 end
    return inf.drug
end

-- A new wound from a zombie (kind: "bite", "scratch" or "cut"): it is untested from now on and the drug ends, whether
-- or not the body is infected (the player must not learn it by the drug going). Returns the kind of the drug that ended.
function Infection.wounded(record, kind, now)
    local inf = Infection.section(record)
    if not inf.known then inf.untested = true end
    inf.since = inf.since or now
    local lost = Infection.drug(inf, now)
    inf.drug = nil
    return lost
end

-- A test: positive (the progress as it is) or negative. Either way the wound is tested for. A negative one forgets
-- when the wound came; a positive one counts. Returns how many positive tests there have been (0 for a negative one).
function Infection.tested(record, infected, progress, now)
    local inf = Infection.section(record)
    inf.untested = nil
    if infected then
        inf.known = true
        inf.progress = OA.clamp(progress or inf.progress or 0, 0, 1)
        inf.since = inf.since or now or OA.hours()
        inf.positives = (inf.positives or 0) + 1
        return inf.positives
    end
    inf.known = nil
    inf.progress = nil
    inf.since, inf.doses = nil, nil
    return 0
end

-- A reversal: the progress goes back to nothing, and so does the age a drug holds the infection at.
function Infection.reversed(record)
    local inf = Infection.section(record)
    if inf.known then inf.progress = 0 end
    if inf.drug and inf.drug.age then inf.drug.age = 0 end
end

-- The cure: nothing is left to test, know or hold, and no fee is taken. (An older save's note that a settlement would
-- say the fee was lifted goes too.)
function Infection.cured(record)
    local inf = Infection.section(record)
    inf.known, inf.untested, inf.progress, inf.drug = nil, nil, nil, nil
    inf.since, inf.doses, inf.released = nil, nil, nil
end

-- The percent a progress shows as, a whole number (rounded, so 0.29 is 29 and not 28).
local function percent(p)
    return math.floor((p or 0) * 100 + 0.5)
end

-- Whether the client has something to tell the server about the body (once a minute): an infection not yet in the
-- record, a known one gone, a drug taken before the infection (it holds nothing), the progress moved a percent.
function Infection.wantsSeen(record, infected, progress, now)
    local inf = record.infection
    if not infected then return inf ~= nil and inf.known == true end
    if not inf or not (inf.known or inf.untested) then return true end
    local d = inf.drug
    if d and d.age == nil and d.till > now then return true end
    return inf.known == true and progress ~= nil and percent(progress) ~= percent(inf.progress)
end

-- What the client saw of the body: `infected` (the real infection), `progress` (0 to 1). An infection the record does
-- not know of is untested, a known one that is gone is dropped, and a drug taken before the infection ends (it holds
-- no age). Returns whether the record changed.
function Infection.seen(record, infected, progress, now)
    local inf = Infection.section(record)
    local changed = false
    if infected then
        if not inf.known and not inf.untested then
            inf.untested = true
            inf.since = inf.since or now
            changed = true
        end
        local d = inf.drug
        if d and d.age == nil and d.till > now then
            inf.drug = nil
            changed = true
        end
        if inf.known and progress and percent(progress) ~= percent(inf.progress) then
            inf.progress = OA.clamp(progress, 0, 1)
            changed = true
        end
    elseif inf.known then
        inf.known, inf.progress = nil, nil
        inf.since, inf.doses = nil, nil
        changed = true
    end
    return changed
end

-- ---- finding a new zombie wound ----------------------------------------------------------------------------------
-- The game has no event for a zombie's wound, so the body is compared with how it was a moment ago, but only while a
-- zombie is attacking: the player's own count of updates since a zombie attacked (getTimeSinceZombieAttack, set to 0
-- on every update of a zombie in its attack) is the gate, one cheap call. Outside it nothing else is read. While it is
-- open, every part's wound flags and times are read each update; a wound that is new since the update before (a flag
-- that went on, or a time that was set afresh) counts when getAttackedBy() is a zombie within two tiles.

-- Updates after the last zombie attack during which wounds are looked for.
Infection.GATE = 30
-- A zombie further than this (tiles) from the character did not make the wound.
Infection.NEAR = 2
-- A wound time that moved by less than this is the time running out, not a new wound (it falls 0.004 at most an update).
Infection.TIME_EPS = 0.05

-- The wound flags and times of the body parts (a Java list) as numbers, into `into` (made if nil): for part i from 0,
-- six numbers from 6 * i + 1: bitten, scratched, cut (1 or 0), then their times (0 while the flag is off).
function Infection.snapshot(parts, into)
    into = into or {}
    for i = 0, parts:size() - 1 do
        local part = parts:get(i)
        local k = i * 6
        if part:bitten() then
            into[k + 1], into[k + 4] = 1, part:getBiteTime()
        else
            into[k + 1], into[k + 4] = 0, 0
        end
        if part:scratched() then
            into[k + 2], into[k + 5] = 1, part:getScratchTime()
        else
            into[k + 2], into[k + 5] = 0, 0
        end
        if part:isCut() then
            into[k + 3], into[k + 6] = 1, part:getCutTime()
        else
            into[k + 3], into[k + 6] = 0, 0
        end
    end
    return into
end

-- Whether a wound of one kind is new: its flag went on, or it was on and its time is set afresh.
local function isNew(before, after, flag, time)
    if after[flag] == 0 then return false end
    if before[flag] == 0 then return true end
    local was, now = before[time], after[time]
    return now > was or was - now > Infection.TIME_EPS
end

-- The kind of the worst new wound between two snapshots of `count` parts ("bite", then "cut", then "scratch"), or nil.
function Infection.fresh(before, after, count)
    local found = nil
    for i = 0, count - 1 do
        local k = i * 6
        if isNew(before, after, k + 1, k + 4) then return "bite" end
        if isNew(before, after, k + 3, k + 6) then
            found = "cut"
        elseif not found and isNew(before, after, k + 2, k + 5) then
            found = "scratch"
        end
    end
    return found
end

-- Whether the character's last attacker is a zombie within Infection.NEAR tiles.
function Infection.byZombie(character)
    local by = character:getAttackedBy()
    if not by or not instanceof(by, "IsoZombie") then return false end
    return by:DistTo(character) <= Infection.NEAR
end

local watch = { open = false }

-- Forgets what the watch saw (a new character, a new game).
function Infection.resetWatch()
    watch = { open = false }
end

-- Whether the watch is looking at the body now (a zombie attacked a moment ago).
function Infection.watching()
    return watch.open
end

-- Call every update of the local character. Returns the kind of a new zombie wound ("bite", "scratch" or "cut") the
-- moment it shows, else nil.
function Infection.watch(character)
    if character:getTimeSinceZombieAttack() > Infection.GATE then
        watch.open = false
        return nil
    end
    local body = character:getBodyDamage()
    if watch.body ~= body then
        watch.body = body
        watch.parts = body:getBodyParts()
        watch.count = watch.parts:size()
        watch.open = false
    end
    local after = Infection.snapshot(watch.parts, watch.spare)
    local kind = nil
    if watch.open then
        kind = Infection.fresh(watch.last, after, watch.count)
        if kind and not Infection.byZombie(character) then kind = nil end
    end
    watch.spare, watch.last = watch.last, after
    watch.open = true
    return kind
end

return Infection
