-- The communication terminal's tabs, as a registry other parts add to. The window itself is the client's
-- (client/OperationAcorn/Trade/TerminalWindow.lua); the tabs are listed here so that any part can call addTab from
-- its own files, before or after the window exists.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Terminal = OA.Terminal or {}
OA.Terminal = Terminal

local tabs = {}

-- Adds a tab to the terminal window. `id` names it (a second tab with the same id replaces the first), `titleKey` is
-- the translation key of its label, `factory(x, y, width, height, window)` returns the tab's view (a panel; it may
-- have `refresh(view)` for when the record changes, and `infoText`), and `visible(record, character)` (optional)
-- says whether the tab shows now. A tab added later goes after the ones before it.
function Terminal.addTab(id, titleKey, factory, visible)
    local entry = { id = id, titleKey = titleKey, factory = factory, visible = visible }
    for i, tab in ipairs(tabs) do
        if tab.id == id then
            tabs[i] = entry
            return entry
        end
    end
    tabs[#tabs + 1] = entry
    return entry
end

-- The tabs to show for a record, in order.
function Terminal.tabs(record, character)
    local list = {}
    for _, tab in ipairs(tabs) do
        local ok, shown = true, true
        if tab.visible then ok, shown = pcall(tab.visible, record, character) end
        if ok and shown then list[#list + 1] = tab end
    end
    return list
end

-- Forgets every tab (tests).
function Terminal.clear()
    tabs = {}
end

return Terminal
