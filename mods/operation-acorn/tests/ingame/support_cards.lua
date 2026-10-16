-- Opens the terminal's support screen on the mission group (the longest card names), for a look at the cards: the
-- terminal open already (else opened), its boot skipped.
local OA = OperationAcorn
local window = OATerminalWindow.instances[getPlayer():getPlayerNum()] or OA.Dev.openTerminal()
if window.bootSkip then pcall(window.bootSkip, window) end
local function find(el, kind, depth)
    if not el or depth > 8 then return nil end
    if el.Type == kind then return el end
    for _, child in pairs(el.children or {}) do
        local found = find(child, kind, depth + 1)
        if found then return found end
    end
    return nil
end
local status = find(window, "OATabStatus", 0)
print("SUPPORT status=" .. tostring(status ~= nil))
if status then
    if status.bootDone then status:bootDone() end
    status:showSub("upgrades")
    local view = find(status, "OATabUpgrades", 0)
    print("SUPPORT view=" .. tostring(view ~= nil))
    if view then
        view.group = "mission"
        if view.refresh then view:refresh() end
    end
end
