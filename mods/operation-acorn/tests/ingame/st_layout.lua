-- The running mission's building as the stage reads it: its rooms (name, box, z, doors counted, edge) and the roles.
local OA = OperationAcorn
local m = OA.Missions.active(OA.Dev.record())
local layout = OA.StageGame.layout(m.site)
for i, r in ipairs(layout.rooms) do
    ST.say("LROOM", i, r.name, r.x, r.y, r.x2, r.y2, "z", r.z, "doors", r.doors, "edge", tostring(r.edge), "area", r.area)
end
for i, d in ipairs(layout.doors) do ST.say("LDOOR", i, d.x, d.y, "north", tostring(d.north), "obj", tostring(d.object ~= nil)) end
local roles = m.stage and m.stage.roles or {}
for k, v in pairs(roles) do ST.say("ROLE", k, v) end
