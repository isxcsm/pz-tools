-- The terminal's story tabs (DESIGN-terminal 1.1, 6):
--   임무: the mission screen (the mission card and the special request's slot, Story/TabMission). Its dot is amber for
--     a mission not looked at yet.
--   교신: a row of two sub-tabs (Trade/TabGroup): the team's calls played and kept (Story/TabComms) and the documents
--     the team sent and the player found (Story/TabFolder). Its dot is amber for a call waiting to play and for
--     anything new among the documents; the window opens on it, at the calls, while a call waits.
-- The screens only read the record; what they change goes to the server as a command.
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/TabGroup"
require "OperationAcorn/Story/Comms"
require "OperationAcorn/Story/Folder"
require "OperationAcorn/Story/Maps"
require "OperationAcorn/Story/TabMission"
require "OperationAcorn/Story/TabFolder"
require "OperationAcorn/Story/TabComms"
local OA = OperationAcorn
local Folder, Comms = OA.StoryFolder, OA.Comms
local Tabs = {}
OA.StoryTabs = Tabs

-- Used from the other tabs -----------------------------------------------------------------------------------------

-- The comms tab opened on one of its screens ("calls", "docs"): the screen's view.
local function openComms(window, sub)
    window:activate("comms")
    local group = window:view("comms")
    return group and group.open and group:open(sub) or nil
end

-- Opens the terminal window's documents on the one with this key ("r:117", "d:guide_id").
function Tabs.openDocument(window, key)
    local view = openComms(window, "docs")
    if view and view.showKey then
        view:showKey(key)
        window:refresh()
    end
end

-- Opens the calls (a briefing to hear).
function Tabs.openCalls(window)
    openComms(window, "calls")
end

-- 'Show on the map': the world map fitted to the character and the mission's area (Story/Maps); `which` "special" for
-- the special request's.
function Tabs.showOnMap(character, which)
    OA.StoryMaps.show(character, which)
end

-- The tabs ---------------------------------------------------------------------------------------------------------

OA.Terminal.addTab("missions", function(x, y, w, h, window)
    return OATabMission:new(x, y, w, h, window)
end, {
    mark = Folder.missionMark,
    seen = Folder.seen,
})

Tabs.COMMS = {
    subs = {
        { id = "calls", make = function(x, y, w, h, window) return OATabComms:new(x, y, w, h, window) end },
        { id = "docs", make = function(x, y, w, h, window) return OATabFolder:new(x, y, w, h, window) end },
    },
    label = function(id) return getText(id == "docs" and "IGUI_OA_Story_Sub_docs" or "IGUI_OA_Terminal_Sub_calls") end,
    -- a call waiting while the documents are on show, anything new among the documents
    items = function(group, record, item)
        if item.id == "calls" and group.sub ~= "calls" and Comms.waiting(record) > 0 then item.dot = "new" end
        if item.id == "docs" and Folder.unreadCount(record) > 0 then item.dot = "new" end
    end,
    first = function(_, record) return Comms.waiting(record) > 0 and "calls" or nil end,
}

OA.Terminal.addTab("comms", OATabGroup.factory("comms", Tabs.COMMS), {
    mark = function(record)
        if Comms.waiting(record) > 0 or Folder.unreadCount(record) > 0 then return "new" end
        return nil
    end,
    opens = function(record) return Comms.waiting(record) > 0 end,
})

return Tabs
