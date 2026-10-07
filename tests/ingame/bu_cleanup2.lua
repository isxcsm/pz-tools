-- Takes the test's remaining boxes down one at a time, each from beside it, and reports what came back.
local BU = BuildingUtilities
local player = getPlayer()
local inventory = player:getInventory()
ISTimedActionQueue.clear(player)
local function count(t) return inventory:getCountTypeRecurse(t) end
local function counts()
    return "wire " .. count("Base.ElectricWire") .. " pipe " .. count("Base.Pipe") .. " part " .. count("Base.ElectronicsScrap")
        .. " sheet " .. count("Base.SmallSheetMetal") .. " boxes " .. count(BU.PANEL_ITEM)
end
print("[bu2c] before", counts(), "panels", #BU.Store.list())
SandboxVars.BuildingUtilities.RefundPercent = 50
local waiting, limit = nil, 0
local function nextPanel()
    -- A sub-panel first: its parent's refund then does not include its link.
    local list = BU.Store.list()
    for _, panel in ipairs(list) do if panel.parent then return panel end end
    return list[1]
end
local function start()
    local panel = nextPanel()
    if not panel then return false end
    local x, y, z = panel.x, panel.y, panel.z
    for dx = -1, 1 do for dy = -1, 1 do
        local q = getCell():getGridSquare(x + dx, y + dy, z)
        if (dx ~= 0 or dy ~= 0) and q and q:isFree(false) and not q:isBlockedTo(getCell():getGridSquare(x, y, z)) then
            player:teleportTo(x + dx + 0.5, y + dy + 0.5, z)
            break
        end
    end end
    BU.ContextMenu.queueAt(player, x, y, z, ISBURemovePanel:new(player, panel))
    waiting, limit = panel.id, 1500
    return true
end
local function tick()
    if waiting then
        limit = limit - 1
        if BU.Store.get(waiting) and limit > 0 then return end
        print("[bu2c] removed", waiting, BU.Store.get(waiting) == nil, counts())
        waiting = nil
    end
    if not start() then
        Events.OnTick.Remove(tick)
        print("[bu2c] done", counts(), "panels", #BU.Store.list())
    end
end
Events.OnTick.Add(tick)
