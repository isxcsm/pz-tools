-- A machine's work as the player watches it. While a loot window shows a container of a working machine, the job it is
-- on shows on that thing's row (the game's job bar, as an action shows on the item it works), and the machine is asked
-- to work the moment the job is due or something new is put in: things go one by one as their bars fill, not every
-- ten minutes. The work is the time since it last worked either way, so a watched machine makes no more than an
-- unwatched one. Nothing is kept on the items: the bar is set while the row is drawn and taken off after.
require "ISUI/ISInventoryPane"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines

local CHECK_MS = 100    -- how often a watched machine's progress is read
local ASK_MS = 400      -- the least time between two asks to work (the answer comes on the next tick)
local IDLE_ASK_MS = 3000 -- an idle machine is asked again this seldom while nothing changes in it

-- anchor -> { item, share, count, due = { check, idle, ask = real ms each was last due (OA.due) } }
local watched = setmetatable({}, { __mode = "k" })

local function look(pane, anchor, state)
    local now = getTimestampMs()
    local w = watched[anchor]
    if not w then
        w = { due = {} }
        watched[anchor] = w
    end
    if not OA.due(w.due, "check", now, CHECK_MS) then return w end
    w.item, w.share = Machines.progress(anchor)
    local inC = Machines.container(anchor, "in")
    local count = inC and inC:getItems():size() or 0
    local due
    if w.share then
        due = w.share >= 1
    elseif state.on ~= false and count > 0 then
        -- idle with something in it: ask when what is in it changed, else seldom (no power, the output full...)
        due = OA.due(w.due, "idle", now, IDLE_ASK_MS) or count ~= w.count
    end
    w.count = count
    if due and OA.due(w.due, "ask", now, ASK_MS) then
        local player = getSpecificPlayer(pane.player or 0)
        if player then OA.Sync.send(player, "machineWork", { machine = state.id }) end
    end
    return w
end

local original = ISInventoryPane.renderdetails
function ISInventoryPane:renderdetails(doDragged)
    local container = self.inventory
    local parent = container and container:getParent()
    local anchor = parent and Machines.isMachineObject(parent) and Machines.anchorOf(parent)
    local state = anchor and Machines.state(anchor)
    if not state or not Machines.Data.processes(state.kind) then return original(self, doDragged) end
    local w = look(self, anchor, state)
    local item = w.share and w.item
    if not item or item:getContainer() ~= container then return original(self, doDragged) end
    local oldType, oldDelta = item:getJobType(), item:getJobDelta()
    item:setJobType(getText("IGUI_OA_Machine_Job_" .. state.kind))
    item:setJobDelta(math.max(0.01, math.min(1, w.share)))
    local ok, err = pcall(original, self, doDragged)
    item:setJobDelta(oldDelta)
    item:setJobType(oldType)
    if not ok then error(err, 0) end
end
