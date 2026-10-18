-- Every door of the active mission's building (and one square round it, the ground floor and the one above): its two
-- sides' rooms, whether it is locked (by key), its key id and the one the game asks of it (checkKeyId), and the
-- building's key id. Prints [d] lines.
local m = OperationAcorn.Missions.active(OperationAcorn.Dev.record())
local s = m.site
local c = getCell()
for z = 0, 1 do for x = s.x1 - 1, s.x2 + 1 do for y = s.y1 - 1, s.y2 + 1 do
  local sq = c:getGridSquare(x, y, z)
  local objs = sq and sq:getObjects()
  for i = 0, (objs and objs:size() or 0) - 1 do
    local o = objs:get(i)
    if instanceof(o, "IsoDoor") then
      local other = o:getNorth() and c:getGridSquare(x, y - 1, z) or c:getGridSquare(x - 1, y, z)
      local r1 = sq:getRoom() and sq:getRoom():getName() or "-"
      local r2 = other and other:getRoom() and other:getRoom():getName() or "-"
      print("[d]", x, y, z, o:getNorth() and "N" or "W", r1, r2, "locked", o:isLocked(), o:isLockedByKey(), "key", o:getKeyId(), o:checkKeyId())
    end
  end
end end end
local b = getWorld():getMetaGrid():getBuildingAtRelax(s.x, s.y)
print("[d] building key", b and b:getKeyId())
