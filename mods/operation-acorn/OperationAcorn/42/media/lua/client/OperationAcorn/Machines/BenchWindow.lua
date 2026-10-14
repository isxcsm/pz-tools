-- The hand bench's window (분해대): the machine window's frame (Window.lua: the title bar, the fade, closing when the
-- character walks away) around what is done there by hand. What the character carries that can be shredded, a row a
-- kind: a click on a row picks all of it or none, [-] and [+] one less or one more; what the chosen take and give; and
-- [분해 시작], which walks to the bench and queues an action an item (ISOAMachineShred). While it works the rows are
-- locked, the count goes down as each item goes, and [멈추기] clears the queue; what is left stays chosen, to go on.
-- The bags are looked through when the window opens, when the work ends, and when the inventory's signature (its count
-- and weight, OA.signature) changed: not while the window only shows.
require "OperationAcorn/Client"
require "OperationAcorn/Economy/Shred"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/Actions"
require "OperationAcorn/Machines/Window"
require "OperationAcorn/Machines/BenchModel"
require "OperationAcorn/Machines/WindowLayout"
local OA = OperationAcorn
local Machines = OA.Machines
local Bench, Layout = Machines.BenchModel, Machines.WindowLayout

OABenchWindow = OAMachineWindow:derive("OABenchWindow")

-- The character's record (the first-shred marks and the yield's count); nil before the save has one.
function OABenchWindow:record()
    return OA.Client.record(self.character)
end

-- Looks through the bags for what can be shredded (the chosen counts of the kinds still there are kept).
function OABenchWindow:scan()
    self.sig = OA.signature(self.character:getInventory())
    -- oa-scan: ok (the window opened, the work ended or the inventory changed: once)
    local entries = Machines.benchCandidates(self.character, Bench.LIMIT)
    self.kinds = Bench.group(entries, self.kinds)
end

-- What the chosen take and give, worked out when the choice or the things change (not each read).
function OABenchWindow:estimate()
    local chosen = Bench.chosen(self.kinds)
    local weight = 0
    for _, entry in ipairs(chosen) do weight = weight + (entry.data.weight or 0) end
    local est = { count = #chosen, weight = weight, minutes = Machines.benchMinutesFor(chosen), bundles = 0, bonus = 0 }
    local record = self:record()
    if record then est.bundles, est.bonus = Machines.benchEstimate(record, chosen) end
    self.est = est
end

-- The kinds never shredded, from the record.
function OABenchWindow:firsts()
    local record = self:record()
    local first = {}
    if not record then return first end
    local done = OA.Shred.section(record).first
    for _, kind in ipairs(self.kinds) do
        if kind.baseType and not done[kind.baseType] then first[kind.baseType] = true end
    end
    return first
end

-- The choice or the things changed: the estimate and the marks again, then the layout.
function OABenchWindow:changed()
    self:estimate()
    self.first = self:firsts()
    self:refresh(true)
end

-- The work is over (done, or the queue cleared) once its last action has left the queue.
function OABenchWindow:checkWork()
    local work = self.work
    if work and not ISTimedActionQueue.hasAction(work.last) then
        self.work = nil
        self:scan()
        self:changed()
    end
end

function OABenchWindow:refresh(force)
    if not self.kinds then
        self:scan()
        self:estimate()
        self.first = self:firsts()
        force = true
    end
    self:checkWork()
    -- something came into the bags or left them (not while the work takes things out: that is counted as it goes)
    if not self.work and OA.signature(self.character:getInventory()) ~= self.sig then
        self:scan()
        self:estimate()
        self.first = self:firsts()
    end
    local state = Machines.state(self.object)
    local model = Bench.build({ id = state and state.id, kinds = self.kinds, top = self.top, first = self.first,
        firstBonus = OA.Shred.FIRST_BONUS * (OA.option("BonusMultiplier") or 1.0), estimate = self.est,
        work = self.work and { done = self.work.done, total = self.work.total } or nil })
    self.top = model.list.top
    self.model = model
    self:present(model, force, Layout.bench)
end

-- The mouse wheel over the list moves it a row a step.
function OABenchWindow:onWheel(del, x, y)
    local area = self.body.list and self.body.list.benchList
    if not area or x < area.x or x >= area.x + area.w or y < area.y or y >= area.y + area.h then return false end
    local top = Bench.clampTop((self.top or 1) + (del > 0 and 1 or -1), #self.kinds)
    if top ~= self.top then
        self.top = top
        self:refresh()
    end
    return true
end

function OABenchWindow:onHit(hit)
    local id = hit.id
    if self.work then
        if id == "stop" then ISTimedActionQueue.clear(self.character) end
        return
    end
    local kind = hit.index and self.kinds[hit.index]
    if id == "row" and kind then
        kind.chosen = kind.chosen < #kind.entries and #kind.entries or 0
    elseif id == "less" and kind then
        kind.chosen = math.max(0, kind.chosen - 1)
    elseif id == "more" and kind then
        kind.chosen = math.min(#kind.entries, kind.chosen + 1)
    elseif id == "all" or id == "none" then
        for _, k in ipairs(self.kinds) do k.chosen = id == "all" and #k.entries or 0 end
    elseif id == "start" then
        return self:start()
    else
        return
    end
    self:changed()
end

-- One item is shredded: it leaves its kind (and the choice), and the count goes on.
function OABenchWindow:onShredDone(action)
    local work = self.work
    if not work or work.actions[action] == nil then return end
    work.done = work.done + 1
    local kind = work.actions[action]
    for i, entry in ipairs(kind.entries) do
        if entry.item == action.item then
            table.remove(kind.entries, i)
            kind.chosen = math.max(0, kind.chosen - 1)
            break
        end
    end
    self:changed()
end

-- [분해 시작]: walks to the bench, then an action an item chosen; what was moved, put on or marked a favourite since
-- the bags were looked through is left out.
function OABenchWindow:start()
    local square = Machines.nearSquare(self.object, self.character)
    if not square then return end
    local list = {}
    for _, kind in ipairs(self.kinds) do
        for i = 1, math.min(kind.chosen, #kind.entries) do
            local item = kind.entries[i].item
            if OA.inInventory(item, self.character) and not item:isEquipped() and not item:isFavorite() then
                list[#list + 1] = { kind = kind, entry = kind.entries[i] }
            end
        end
    end
    if #list == 0 or not luautils.walkAdj(self.character, square, true) then return end
    local work = { done = 0, total = #list, actions = {} }
    local window = self
    local function done(action) window:onShredDone(action) end
    for _, it in ipairs(list) do
        local action = ISOAMachineShred:new(self.character, self.machineId, square:getX(), square:getY(), square:getZ(),
            it.entry)
        action.onDone = done
        work.actions[action] = it.kind
        work.last = action
        ISTimedActionQueue.add(action)
    end
    self.work = work
    self:refresh(true)
end

-- Closing the window leaves the work queued (the actions go on; no window counts them).
function OABenchWindow:close()
    self.work = nil
    OAMachineWindow.close(self)
end

return OABenchWindow
