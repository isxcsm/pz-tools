-- Opens the terminal's support screen on the mission group (the longest card names), for a look at the cards: the
-- terminal open already (else opened), its boot skipped.
local OA = OperationAcorn
local window = OATerminalWindow.instances[getPlayer():getPlayerNum()] or OA.Dev.openTerminal()
if window.bootSkip then pcall(window.bootSkip, window) end
local heli = window:view("heli")
if heli and heli.board then heli:bootDone() end
window:activate("support")
local view = window:view("support")
print("SUPPORT view=" .. tostring(view ~= nil))
if view then
    view.group = "mission"
    if view.refresh then view:refresh() end
end
