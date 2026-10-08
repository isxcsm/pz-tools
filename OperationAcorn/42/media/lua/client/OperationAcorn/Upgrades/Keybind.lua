-- A key for the research plan, in the game's mod options (B42 PZAPI.ModOptions): unbound by default, so it never
-- takes a key another mod or vanilla uses; the player picks one.
require "OperationAcorn/Core"
require "OperationAcorn/Client"
local OA = OperationAcorn

local options = OA.Client.options()
if not options then return end
local planKey = options:addKeyBind("openPlan", getText("IGUI_OA_Tree_OptionsPlanKey"), 0)

local function onKeyPressed(key)
    if key == nil or key == 0 or key ~= planKey:getValue() then return end
    local player = getPlayer()
    if not player or player:isDead() or not OA.Upgrades or not OA.Upgrades.open then return end
    OA.Upgrades.open(player:getPlayerNum())
end

Events.OnKeyPressed.Add(onKeyPressed)
