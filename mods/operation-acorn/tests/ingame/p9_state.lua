-- P9: things in the middle across a save and load (E2E.md 5): an adaptation running, a call on the spot playing, a title
-- on screen. Part 1 (P9_PART unset or 1) starts them and notes what to expect in the record (saved with the game); then
-- `pzdev reload` (the game saves, goes to the main menu and continues). Part 2 (P9_PART = 2) checks: the adaptation is
-- still running with the same end, the call that was cut off plays again from its start (it was never kept as played),
-- and nothing failed in between (the console is for the caller to read). Part 3 (P9_PART = 3) is after fast-forwarding
-- past the adaptation's end: the point came once, the call was kept once.
-- Setup: single player, a record past the first hello. CHANGES THE RECORD (an adaptation, the S8F call): throwaway save.
-- Lines are tagged "[p9state]".
RUN("p4_lib.lua")
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local say = P4T.say("p9state")
local function check(...) return P4T.check(say, ...) end
local record = P4T.record()
if not record then say("no record yet: wait for the first hello"); return end
local u = Rules.section(record)
local comms = OA.Comms.section(record)
local part = P9_PART or 1

if part == 1 then
    OA.Upgrades.Adapt.start(record, "scout", OA.hours())
    comms.fired.S8F, comms.played.S8F, comms.dropped.S8F = OA.hours(), nil, nil
    OA.FieldCall.check()
    OA.Dev.title("capstone", "scout")
    record.p9 = { endsAt = u.adapt.endsAt, points = Rules.ownPool(u, "scout") }
    OA.Sync.changed("upgrades", record.id)
    say("started: adaptation to", string.format("%.3f", u.adapt.endsAt), "the S8F call, a title; now pzdev reload")
elseif part == 2 then
    local p9 = record.p9 or {}
    check("the adaptation is still running", u.adapt ~= nil and u.adapt.endsAt == p9.endsAt,
        u.adapt and string.format("%.3f", u.adapt.endsAt))
    check("its moodle shows", Rules.adaptLevel(u, OA.hours()) > 0, Rules.adaptLevel(u, OA.hours()))
    check("the cut-off call was not kept as played", comms.played.S8F == nil)
    check("it is the next call on the spot", OA.Comms.next(record, "field") ~= nil and OA.Comms.next(record, "field").id == "S8F")
elseif part == 3 then
    local p9 = record.p9 or {}
    check("the adaptation is over", u.adapt == nil, OA.hours() - (p9.endsAt or 0))
    check("its point came once", Rules.ownPool(u, "scout") == (p9.points or 0) + 1, Rules.ownPool(u, "scout"))
    check("the call was kept once", comms.played.S8F ~= nil)
    local n = 0
    for _, l in ipairs(comms.log) do if l.id == "S8F" then n = n + 1 end end
    check("one S8F in the comms record", n == 1, n)
end
