-- P3: 돌파 질주 (breakthrough sprint) and 옮기기 속도 (transfer speed).
-- Setup: a single-player world, the mod on; a few zombies standing in a line ahead (debug spawn), room to sprint.
-- Changes the record (the ranks).
-- Prints "[p3dash]" lines; sprint into a zombie: it falls and the endurance bar drops by about 5 percent each.
RUN("p3_lib.lua")
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Dash = OA.Upgrades.Dash
local Carry = OA.Upgrades.Carry
local say = P3T.say("p3dash")
local record, player, u = P3T.record()

P3T.points(u, "survival", 24)
P3T.points(u, "load", 24)
for _, id in ipairs({ "brush", "brush", "walk", "walk", "walk", "moveSpeed", "moveSpeed", "moveSpeed" }) do
    local ok, why = Rules.buy(u, id, { fragments = 0 })
    if not ok then say("could not buy", id, why) end
end
-- the capstone needs a fragment and 12 points: take the rank directly for the test
u.ranks.dash = 1
P3T.changed(record)
OA.Upgrades.Hooks.refresh()
say("dash cost per zombie at fitness " .. player:getPerkLevel(Perks.Fitness), Dash.cost(player, u))
P3T.check(say, "the pulse is on for the dash", OA.Upgrades.Pulse.enabled())
say("sprint now into a zombie; the check is by eye and the endurance bar")

-- carry timing
local plank = P3T.give("Base.Plank")
local log = P3T.give("Base.Log")
say("transfer time factor of a plank", Carry.timeFactor(player, plank), "of a log", Carry.timeFactor(player, log),
    "(the node alone gives", Rules.transferTime(u), ")")
local action = ISInventoryTransferAction:new(player, log, player:getInventory(), player:getInventory())
say("a transfer action's max time (with the node)", action.maxTime)
u.ranks.moveSpeed = 0
local plain = ISInventoryTransferAction:new(player, log, player:getInventory(), player:getInventory())
say("the same without the node", plain.maxTime)
P3T.check(say, "the node makes it quicker", action.maxTime < plain.maxTime)
u.ranks.moveSpeed = 3
