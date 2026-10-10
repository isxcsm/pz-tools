-- Trust coming in, from wherever it comes: a settlement and a mission's pay both go through Trade.addTrust, so that
-- a new stage or milestone is dealt with once, the same way. The economy's OA.Trust.add adds the trust, the shared
-- serums (to trade.sharedSerums, which the next crate carries) and the market's stage event, and tells which stages and
-- milestones were passed; this tells the player (a title for the last of them) and lets the story part know.
require "OperationAcorn/Core"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Rules"
local OA = OperationAcorn
local Trade = OA.Trade

-- Adds `amount` of trust to a record (server side). `source` names where it came from, for the log ("settle",
-- "mission"). Returns the events, a list of { kind = "stage" or "milestone", n = number }, already dealt with:
--   - the title of the stage or milestone reached, with the shop's new items under it (once for
--     the whole change);
--   - the story part's onStage (it catches up on every stage and milestone the record has passed; it is idempotent).
-- A caller must not do these again for the events it gets back.
function Trade.addTrust(record, amount, source)
    if not amount or amount <= 0 then return {} end
    local events
    if OA.Trust and OA.Trust.add then
        events = Trade.Rules.stageEvents(OA.Trust.add(record, amount))
    else
        local account = Trade.account(record)
        account.trust = account.trust + amount
        events = {}
    end
    if #events > 0 then
        OA.log("trust from", tostring(source), "passed", #events, "stage or milestone events for", tostring(record.number))
        -- one title for the whole change: the last level reached (milestone k is level 5 + k)
        local last = events[#events]
        local level = last.kind == "milestone" and 5 + last.n or last.n
        OA.Sync.title(record.id, { key = "IGUI_OA_Title_Stage", args = { level }, sub = "IGUI_OA_Title_NewItems",
            style = "stamp", fallback = "good" })
        if OA.Story and OA.Story.onStage then
            local ok, err = pcall(OA.Story.onStage, record)
            if not ok then OA.log("story onStage failed:", tostring(err)) end
        end
    end
    return events
end
