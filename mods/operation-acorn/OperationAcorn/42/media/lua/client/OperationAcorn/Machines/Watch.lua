-- A machine's work as the player watches it. While a loot window shows a container of a working machine, the jobs it
-- is on (one a lane of its motor) show on those things' rows (the game's job bar, as an action shows on the item it
-- works), and the machine is asked to work the moment a job is due or something new is put in: things go as their bars
-- fill, not every ten minutes. The work is the time since it last worked either way, so a watched machine makes no more than an
-- unwatched one. Nothing is kept on the items: the bar is set while the row is drawn and taken off after.
require "ISUI/ISInventoryPane"
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/Ask"
local OA = OperationAcorn
local Machines = OA.Machines

local CHECK_MS = 500    -- how often a watched machine's progress is read

-- anchor -> { jobs (Machines.progress), stop (why it is not working on what is in it), count,
--   due = { check, idle, ask = real ms each was last due (OA.due) } }
local watched = setmetatable({}, { __mode = "k" })

local function look(pane, anchor, state)
    local now = getTimestampMs()
    local w = watched[anchor]
    if not w then
        w = { due = {} }
        watched[anchor] = w
    end
    if not OA.due(w.due, "check", now, CHECK_MS) then return w end
    w.jobs = Machines.progress(anchor)
    local inC = Machines.container(anchor, "in")
    local count = inC and inC:getItems():size() or 0
    local due, idle
    if w.jobs then
        for _, job in ipairs(w.jobs) do
            if job.share >= 1 then due = true end
        end
    else
        -- idle with something in it: asked when what is in it changed, else seldom (no power, the output full ...)
        idle = state.on ~= false and count > 0
    end
    local changed = count ~= w.count
    w.count = count
    w.stop = not w.jobs and count > 0 and Machines.stopText(anchor) or nil
    if Machines.Ask.wanted(w.due, now, due, idle, changed) then
        local player = getSpecificPlayer(pane.player or 0)
        if player then OA.Sync.send(player, "machineWork", { machine = state.id }) end
    end
    return w
end

-- the rows' own job, kept while the bars are drawn (reused: this runs every frame)
local saved, savedType, savedDelta = {}, {}, {}

local original = ISInventoryPane.renderdetails
function ISInventoryPane:renderdetails(doDragged, ...)
    local container = self.inventory
    local parent = container and container:getParent()
    local anchor = parent and Machines.isMachineObject(parent) and Machines.anchorOf(parent)
    local state = anchor and Machines.state(anchor)
    if not state or not Machines.Data.processes(state.kind) then return original(self, doDragged, ...) end
    local w = look(self, anchor, state)
    local shown = 0
    if w.jobs then
        local text = getText("IGUI_OA_Machine_Job_" .. state.kind)
        for _, job in ipairs(w.jobs) do
            local item = job.item
            if item:getContainer() == container then
                shown = shown + 1
                saved[shown], savedType[shown], savedDelta[shown] = item, item:getJobType(), item:getJobDelta()
                item:setJobType(text)
                item:setJobDelta(math.max(0.01, math.min(1, job.share)))
            end
        end
    end
    -- not working on what is in it: the reason on the first row, where a job's name goes (the game writes a row's job
    -- whenever it has one; so small a share draws no bar)
    if shown == 0 and w.stop and self.itemslist and self.itemslist[1] then
        local item = self.itemslist[1].items[1]
        if item then
            shown = 1
            saved[1], savedType[1], savedDelta[1] = item, item:getJobType(), item:getJobDelta()
            item:setJobType(w.stop)
            item:setJobDelta(0.001)
        end
    end
    if shown == 0 then return original(self, doDragged, ...) end
    local ok, err = pcall(original, self, doDragged, ...)
    for i = 1, shown do
        saved[i]:setJobDelta(savedDelta[i])
        saved[i]:setJobType(savedType[i])
        saved[i] = nil
    end
    if not ok then error(err, 0) end
end
