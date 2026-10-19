-- Without the extension API (or with another version of it) the mod is off for the game (OA.off): it hooks nothing,
-- and this says why, once a game, when the game starts (DESIGN 2). The game's own dialog: the mod's UI is not there.
require "ISUI/ISModalDialog"
require "OperationAcorn/Core"
local OA = OperationAcorn

local function tell()
    local _, why = OA.api()
    local text = getText(why == "version" and "IGUI_OA_NoApi_Version" or "IGUI_OA_NoApi_Missing")
    local w, h = ISModalDialog.CalcSize(0, 0, text)
    local core = getCore()
    local modal = ISModalDialog:new((core:getScreenWidth() - w) / 2, (core:getScreenHeight() - h) / 2, w, h, text, false,
        nil, nil, 0)
    modal:initialise()
    modal:addToUIManager()
    if getJoypadData(0) then setJoypadFocus(0, modal) end
end

-- (not OA.on: that registers nothing while the mod is off)
if OA.off then Events.OnGameStart.Add(tell) end
