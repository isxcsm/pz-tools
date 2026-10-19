-- The trade part's notices as titles: its own and the economy's, not the ones other parts show themselves.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Presentation"
local OA = OperationAcorn

test("a notice another part shows itself is not shown twice", function()
    local shown = {}
    local data = { OA_Id = "p1" }
    -- (without the API's text a title is said by the character)
    local character = { getModData = function() return data end, getPlayerNum = function() return 0 end,
        Say = function(_, text) shown[#shown + 1] = text end }
    HaloTextHelper = nil
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return character end
    local id = OA.Client.id(character)
    OA.Sync.deliver("notice", id, { key = "IGUI_OA_Trade_Notice_Sealed", args = { "3" } })
    eq(#shown, 1, "the trade's own notice")
    -- a sealed box is a title (here, without the API's text, said: the title, then its line)
    eq(string.sub(shown[1], 1, #"IGUI_OA_Title_Sealed"), "IGUI_OA_Title_Sealed", shown[1])
    for _, key in ipairs({ "IGUI_OA_Gear_Fitted_storage", "IGUI_OA_Gear_Failed", "IGUI_OA_Machine_PartWorn",
                           "IGUI_OA_Story_SwapFail", "IGUI_OA_Tree_CureExpired" }) do
        OA.Sync.deliver("notice", id, { key = key, args = { "far" } })
    end
    eq(#shown, 1, "the gear, machine, story and research notices are their parts' own")
end)
