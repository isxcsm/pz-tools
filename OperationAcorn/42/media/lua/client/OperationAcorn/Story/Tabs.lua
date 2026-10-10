-- The terminal's missions tab (DESIGN-terminal 6): under a row of two sub-tabs, the mission screen (the mission card
-- and the special request's slot, Story/TabMission) and the document folder (Story/TabFolder). The tab's dot is
-- amber for a mission not looked at yet and for anything new in the folder (Story/Folder); the folder sub-tab carries
-- the number of what is new. Both screens only read the record; what they change goes to the server as a command.
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Story/Folder"
require "OperationAcorn/Story/Maps"
require "OperationAcorn/Story/TabMission"
require "OperationAcorn/Story/TabFolder"
local OA = OperationAcorn
local Folder = OA.StoryFolder
local Tabs = {}
OA.StoryTabs = Tabs

OATabMissions = OATab:derive("OATabMissions")

OATabMissions.SUBS = { "missions", "docs" }
-- The row of sub-tabs, and where the screens start under it (the card's top is 30 under the tab's: 22 + 8).
OATabMissions.GAP = 8

local SUB_VIEWS = {
    missions = function(x, y, w, h, window) return OATabMission:new(x, y, w, h, window) end,
    docs = function(x, y, w, h, window) return OATabFolder:new(x, y, w, h, window) end,
}

function OATabMissions:createChildren()
    self.sub = "missions"
    self.subTabs = OASubTabs:new(0, 0, self.width, self:palette(), self, OATabMissions.onSub)
    self.subTabs:initialise()
    self.subTabs.anchorRight = true
    self:addChild(self.subTabs)
    self.subViews = {}
    self:showSub("missions")
    self:refresh()
end

function OATabMissions:subView(id)
    local view = self.subViews[id]
    if view then return view end
    local y = self.subTabs.height + OATabMissions.GAP
    view = SUB_VIEWS[id](0, y, self.width, self.height - y, self.window)
    view:initialise()
    view:instantiate()
    view.anchorRight = true
    view.anchorBottom = true
    self:addChild(view)
    self.subViews[id] = view
    return view
end

function OATabMissions:showSub(id)
    for sid, view in pairs(self.subViews) do view:setVisible(sid == id) end
    self.sub = id
    self:subView(id):setVisible(true)
end

-- A sub-tab clicked: the window redraws (the dots follow what is on show).
function OATabMissions.onSub(self, id)
    if id == self.sub then return end
    self:showSub(id)
    self.window:refresh()
end

-- Opens the folder at a document by its folder key (the status tab's card, the special request's link).
function OATabMissions:showDocument(key)
    self:showSub("docs")
    self.subViews.docs:showKey(key)
    self.window:refresh()
end

function OATabMissions:refresh()
    local record = self:record()
    if not record then return end
    local unread = Folder.unreadCount(record)
    self.subTabs:setItems({
        { id = "missions", label = getText("IGUI_OA_Story_Sub_missions"), dot = (self.sub ~= "missions" and Folder.freshMission(record)) and "new" or nil },
        { id = "docs", label = getText("IGUI_OA_Story_Sub_docs"), badge = unread > 0 and getText("IGUI_OA_Story_UI_NewCount", unread) or nil },
    }, self.sub)
    local view = self.subViews[self.sub]
    if view then view:refresh() end
end

-- What the missions screen says of the missions so far, in the row of the sub-tabs, to the right.
function OATabMissions:prerender()
    local view = self.subViews and self.subViews.missions
    if self.sub == "missions" and view and view.drawResults then view:drawResults(self, self.width, 3) end
end

-- Used from the other tabs -----------------------------------------------------------------------------------------

-- Opens the terminal window's folder on the document with this key ("c:s2", "r:117", "d:guide_id").
function Tabs.openDocument(window, key)
    window:activate("missions")
    local view = window:view("missions")
    if view and view.showDocument then view:showDocument(key) end
end

-- 'Show on the map': the world map fitted to the character and the mission's area (Story/Maps).
function Tabs.showOnMap(character)
    OA.StoryMaps.show(character)
end

OA.Terminal.addTab("missions", function(x, y, w, h, window)
    return OATabMissions:new(x, y, w, h, window)
end, {
    mark = Folder.mark,
    seen = function(record, window) return Folder.seen(record, window and window:subOn("missions")) end,
})

return Tabs
