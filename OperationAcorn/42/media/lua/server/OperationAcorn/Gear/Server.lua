-- The server side of the kits: redeeming the handover voucher. Fitting a kit is a timed action (shared/.../Gear/
-- Actions.lua), which the game runs on the server as it does any other. The screen asks, the server decides.
require "OperationAcorn/Server"
require "OperationAcorn/Gear/Gear"
local OA = OperationAcorn
local Gear = OA.Gear
local Server = OA.Server
local GearServer = {}
Gear.Server = GearServer

-- Redeems the voucher a character names (by item id) for a kit of a kind. Returns true, or false and the reason.
function GearServer.redeem(character, args)
    if type(args.kind) ~= "string" then return false, "kind" end
    local voucher = Gear.findItem(character, args.item)
    return Gear.redeem(character, voucher, args.kind)
end

Server.on("gear.redeem", function(character, record, args)
    local ok, why = GearServer.redeem(character, args)
    if not ok then OA.Sync.notice(record.id, "IGUI_OA_Gear_Failed", { why }) end
end)

-- A client tells the id it gave a vehicle (Gear.vehicleId): the server keeps it if the vehicle has none.
Server.on("gear.tag", function(character, record, args)
    if type(args.tag) ~= "string" or #args.tag > 40 then return end
    local vehicle = Gear.findVehicle(args.vehicle)
    if vehicle then Gear.tagVehicle(vehicle, args.tag) end
end)

return GearServer
