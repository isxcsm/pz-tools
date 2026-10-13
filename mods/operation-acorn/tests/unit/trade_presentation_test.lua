-- The trade part's notices over the character: its own and the economy's, not the ones other parts show themselves.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Presentation"
local OA = OperationAcorn

test("a notice another part shows itself is not shown twice", function()
    local shown = {}
    local data = { OA_Id = "p1" }
    local character = { getModData = function() return data end }
    HaloTextHelper = {
        addText = function(_, text) shown[#shown + 1] = text end,
        addBadText = function(_, text) shown[#shown + 1] = text end,
    }
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return character end
    local id = OA.Client.id(character)
    OA.Sync.deliver("notice", id, { key = "IGUI_OA_Trade_Notice_Sealed", args = { "3" } })
    eq(#shown, 1, "the trade's own notice")
    for _, key in ipairs({ "IGUI_OA_Gear_Fitted_trunk", "IGUI_OA_Gear_Failed", "IGUI_OA_Machine_PartWorn",
                           "IGUI_OA_Story_SwapFail", "IGUI_OA_Tree_CureExpired" }) do
        OA.Sync.deliver("notice", id, { key = key, args = { "far" } })
    end
    eq(#shown, 1, "the gear, machine, story and research notices are their parts' own")
end)
