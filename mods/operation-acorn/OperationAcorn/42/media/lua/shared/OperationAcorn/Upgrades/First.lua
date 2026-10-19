-- The first effect of six nodes (DESIGN-terminal 19, Data.FIRST_EFFECT): the first time a node works in the game, once
-- for good (u.firstEffect[id]), a line over the head (`기척 감지 1단계`) and a line of self-talk. Nothing checks per tick:
-- each node reports from the place where it already does its work (a mark shown, an outline drawn, a bag's weight
-- changed, a furniture lifted, a lock pried, a zombie thrown). A client place asks the server with First.report; a place
-- that runs where the world is decided calls First.grant itself.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Say"
require "OperationAcorn/Upgrades/Data"
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local First = {}
OA.Upgrades.First = First

-- Real milliseconds before a node asks again when the server has not noted it.
First.ASK_MS = 30000

-- The self-talk: two lines a node, in the order of Data.FIRST_EFFECT.
local PER_NODE = 2
local tags = {}
for n = 1, #Data.FIRST_EFFECT * PER_NODE do tags[n] = { node = Data.FIRST_EFFECT[math.ceil(n / PER_NODE)] } end
OA.Say.define("FirstEffect", { tags = tags })

-- The node has its first effect now: noted, the player told. True the first time only. `record` is the player's.
function First.grant(record, id)
    if not record then return false end
    local u = Rules.section(record)
    if not Rules.firstEffect(u, id) then return false end
    local node = Data.byId[id]
    -- a node with one rank has no stage to tell
    local key = (node and node.ranks == 1) and "IGUI_OA_Tree_FirstEffectSingle" or "IGUI_OA_Tree_FirstEffect"
    OA.Sync.notice(record.id, key, { id, Rules.rank(u, id) })
    OA.Sync.changed("upgrades", record.id, { kind = "first", node = id })
    OA.Say.tell(record.id, "FirstEffect", { node = id })
    return true
end

-- ---- the client's side ------------------------------------------------------------------------------------------

local done, asked = {}, {}

local function forget()
    done, asked = {}, {}
end
if Events and Events.OnGameStart then OA.on("OnGameStart", forget) end
if Events and Events.OnCreatePlayer then OA.on("OnCreatePlayer", forget) end

-- A node did its work for the local character: asks the server to note it, unless it is noted or was asked a moment ago.
-- Cheap to call from a place that runs often: once the node is noted it is a table read.
function First.report(id, character)
    if done[id] then return end
    local now = getTimestampMs()
    if asked[id] and now - asked[id] < First.ASK_MS then return end
    character = character or getPlayer()
    local record = character and OA.Client.record(character)
    if not record then return end
    local u = Rules.section(record)
    if u.firstEffect[id] then
        done[id] = true
        return
    end
    if Rules.rank(u, id) < 1 then return end
    asked[id] = now
    OA.Sync.send(character, "upgrades.first", { node = id })
end

return First
