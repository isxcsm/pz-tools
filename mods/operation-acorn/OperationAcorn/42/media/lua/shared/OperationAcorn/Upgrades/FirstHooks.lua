-- The first effect of 가구 운반 (First.lua): a piece of furniture lifted. The game's pickup action is wrapped, not
-- replaced; its complete runs where the world is decided, so the first effect is granted there at once. The record's id
-- is put on the action when it is made (as the serum action does: the server has no say in the character's mod data).
require "Moveables/ISMoveablesAction"
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Upgrades/First"
local OA = OperationAcorn

-- The game's functions below are left as they are while the mod is off (OA.off).
if OA.off then return end

local originalNew = ISMoveablesAction.new

function ISMoveablesAction:new(character, square, mode, ...)
    local o = originalNew(self, character, square, mode, ...)
    if o and mode == "pickup" and character then o.oaId = OA.Store.idOf(character) end
    return o
end

local originalComplete = ISMoveablesAction.complete

function ISMoveablesAction:complete(...)
    local done = originalComplete(self, ...)
    if self.mode == "pickup" and self.character then
        local id = self.oaId or OA.Store.idOf(self.character)
        local record = id and OA.Store.player(id)
        if record then OA.try("first effect: furniture", OA.Upgrades.First.grant, record, "furniture") end
    end
    return done
end
