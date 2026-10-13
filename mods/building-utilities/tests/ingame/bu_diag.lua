-- Where the save stands: the store's version and what it keeps, the player's square.
local BU = BuildingUtilities
local data = ModData.getOrCreate("BuildingUtilities")
local n = 0
for _ in pairs(data.panels or {}) do n = n + 1 end
local p = getPlayer()
print("[budiag] version", tostring(data.version), "panels", n, "units", data.units and #BU.Store.unitList() or "-", "api", tostring(BU.api() ~= nil),
    "at", p:getX(), p:getY(), p:getZ(), "hour", getGameTime():getTimeOfDay())
for _, panel in ipairs(BU.Store.list()) do print("[budiag] panel", panel.id, panel.x, panel.y, panel.z, "tier", panel.tier) end
