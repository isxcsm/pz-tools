-- The story part's tab in the communication terminal, missions, with two screens: the mission (what is asked, where
-- about, until when, what it pays; the choice buttons of a choice mission; the map) and the folder of documents (the
-- ones read, the radio copies, the latest manifests). Both only read the record; what they change goes to the server
-- as a command.
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISRichTextPanel"
require "ISUI/ISScrollingListBox"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Story/Viewer"
pcall(require, "OperationAcorn/Trade/Terminal") -- the trade part registers the terminal; its tabs are optional here
local OA = OperationAcorn
local Data, Places, Missions, Story, Docs = OA.StoryData, OA.Places, OA.Missions, OA.Story, OA.StoryDocs
local Tabs = {}
OA.StoryTabs = Tabs

local PAD = 10

-- Panels made, refreshed when the record changes (a listener cannot be removed, so only the latest few are kept).
local panels = {}

local function character()
    return getPlayer()
end

local function record()
    local c = character()
    return c and OA.Client.record(c) or nil
end


-- ---------------------------------------------------------------------------------------------------------------
-- The mission tab.

-- Keys of a mission's title and brief by kind (the missions' own, which their titles use too).
function Tabs.keys(info)
    return Missions.keys(info)
end

local function daysText(hours)
    if hours >= 24 then return getText("IGUI_OA_Story_UI_Days", string.format("%.1f", hours / 24)) end
    return getText("IGUI_OA_Story_UI_Hours", math.max(1, math.ceil(hours)))
end

-- The mission text as rich text lines.
local function missionLines(info)
    local lines = {}
    local function add(text) lines[#lines + 1] = text end
    if not info.id then
        add(" <H2> " .. getText("IGUI_OA_Story_UI_NoMission") .. " <LINE> <LINE> <TEXT> ")
        if info.nextIn and info.nextIn > 0 then
            add(getText("IGUI_OA_Story_UI_NextIn", daysText(info.nextIn)) .. " <LINE> ")
        end
    else
        local titleKey, briefKey = Tabs.keys(info)
        local place = info.place and getText("IGUI_OA_Story_Place_" .. info.place) or ""
        add(" <H2> " .. getText(titleKey) .. " <LINE> <LINE> <TEXT> ")
        add(getText(briefKey, place, Story.number(record() or {})) .. " <LINE> <LINE> ")
        if info.item and info.state ~= "offer" then
            add(getText("IGUI_OA_Story_UI_Item", getItemNameFromFullType(Data.fullType(info.item)),
                getText("Tooltip_OA_Story_" .. info.item)) .. " <LINE> <LINE> ")
        end
        if info.state == "offer" then
            add(getText("IGUI_OA_Story_UI_Offer") .. " <LINE> ")
        elseif info.state == "sealed" then
            add(getText("IGUI_OA_Story_UI_Sealed") .. " <LINE> ")
        elseif info.state == "calling" then
            add(getText("IGUI_OA_Story_UI_Calling") .. " <LINE> ")
        else
            add(getText("IGUI_OA_Story_UI_Left", daysText(math.max(0, info.left or 0))) .. " <LINE> ")
        end
        if info.swap then add(getText("IGUI_OA_Story_UI_Swap_" .. info.swap) .. " <LINE> ") end
        if info.field then add(getText("IGUI_OA_Story_UI_Field_" .. info.field) .. " <LINE> ") end
        if info.cooler and info.cooler.started then
            add(getText("IGUI_OA_Story_UI_Cooler", string.format("%.1f", info.cooler.temp)) .. " <LINE> ")
        end
        if info.compare then add(getText("IGUI_OA_Story_UI_Compare", tostring(info.compare)) .. " <LINE> ") end
        if info.stakeNo then add(getText("IGUI_OA_Story_UI_Stake", tostring(info.stakeNo)) .. " <LINE> ") end
        if info.area and info.anchor then
            local point = Places.bearing(info.anchor.x, info.anchor.y, info.area.x, info.area.y)
            if point then add(getText("IGUI_OA_Story_UI_Bearing_" .. point) .. " <LINE> ") end
        end
        if info.credits then
            add(getText("IGUI_OA_Story_UI_Reward", tostring(info.credits), tostring(info.trust or 0)) .. " <LINE> ")
        end
    end
    local r = info.results
    if r then
        add(" <LINE> " .. getText("IGUI_OA_Story_UI_Results", tostring(r.done or 0), tostring(r.expired or 0), tostring(r.lost or 0)))
    end
    return table.concat(lines, "")
end

ISOAMissionPanel = ISPanel:derive("ISOAMissionPanel")

function ISOAMissionPanel:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.buttons = {}
    return o
end

function ISOAMissionPanel:createChildren()
    self.rich = ISRichTextPanel:new(PAD, PAD, self.width - PAD * 2, self.height - PAD * 3 - 28)
    self.rich:initialise()
    self.rich.autosetheight = false
    self.rich.clip = true
    self.rich.background = false
    self.rich:addScrollBars()
    self.rich.anchorRight = true
    self.rich.anchorBottom = true
    self:addChild(self.rich)
    self.map = ISButton:new(PAD, self.height - PAD - 26, 140, 26, getText("IGUI_OA_Story_UI_ShowMap"), self, ISOAMissionPanel.onMap)
    self.map:initialise()
    self.map:instantiate()
    self.map.anchorTop = false
    self.map.anchorBottom = true
    self:addChild(self.map)
end

function ISOAMissionPanel:onMap()
    local r = record()
    local info = r and Missions.describe(r) or {}
    if info.area and ISWorldMap and ISWorldMap.ShowWorldMap then
        ISWorldMap.ShowWorldMap(character():getPlayerNum(), info.area.x, info.area.y, 16)
    end
end

function ISOAMissionPanel:onChoose(button)
    OA.Sync.send(character(), "story_choose", { option = button.internal })
end

function ISOAMissionPanel:refresh()
    local r = record()
    local info = {}
    if r and r.missions then info = Missions.describe(r) end
    self.rich.text = missionLines(info)
    self.rich:paginate()
    self.map:setEnable(info.area ~= nil and info.state ~= "sealed")
    for _, b in ipairs(self.buttons) do self:removeChild(b) end
    self.buttons = {}
    if info.options then
        local x = PAD + 150
        for _, option in ipairs({ "a", "b" }) do
            if info.options[option] then
                local label = getText("IGUI_OA_Story_Option_" .. tostring(info.title) .. "_" .. option)
                local b = ISButton:new(x, self.height - PAD - 26, 170, 26, label, self, ISOAMissionPanel.onChoose)
                b.internal = option
                b:initialise()
                b:instantiate()
                b.anchorTop = false
                b.anchorBottom = true
                self:addChild(b)
                self.buttons[#self.buttons + 1] = b
                x = x + 178
            end
        end
    end
end

function Tabs.missionTab(x, y, width, height)
    local panel = ISOAMissionPanel:new(x or 0, y or 0, width or 520, height or 300)
    panel:initialise()
    panel:instantiate()
    panel:refresh()
    panels[#panels + 1] = panel
    while #panels > 6 do table.remove(panels, 1) end
    return panel
end

-- ---------------------------------------------------------------------------------------------------------------
-- The document folder.

ISOADocsPanel = ISPanel:derive("ISOADocsPanel")

function ISOADocsPanel:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    return o
end

function ISOADocsPanel:createChildren()
    self.list = ISScrollingListBox:new(PAD, PAD, self.width - PAD * 2, self.height - PAD * 3 - 28)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = getTextManager():getFontHeight(UIFont.Small) + 8
    self.list.selected = 0
    self.list.joypadParent = self
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list.anchorRight = true
    self.list.anchorBottom = true
    self.list.onmousedblclick = ISOADocsPanel.onOpen
    self.list.target = self
    self:addChild(self.list)
    self.open = ISButton:new(PAD, self.height - PAD - 26, 140, 26, getText("IGUI_OA_Story_UI_Open"), self, ISOADocsPanel.onOpen)
    self.open:initialise()
    self.open:instantiate()
    self.open.anchorTop = false
    self.open.anchorBottom = true
    self:addChild(self.open)
end

-- The entries: documents read (a stable order), the radio copies (newest first), then the latest manifests (newest
-- first).
function Tabs.entries(r)
    local list = {}
    if not r then return list end
    for _, doc in ipairs(Story.readDocuments(r)) do
        list[#list + 1] = { id = doc.id, variant = doc.variant, noRecord = true }
    end
    local copies = Story.radioCopies(r)
    for i = #copies, 1, -1 do
        local copy = copies[i]
        list[#list + 1] = { text = Story.copyText(r, copy), title = Story.copyTitle(copy) }
    end
    local manifests = Story.section(r).manifests
    for i = #manifests, 1, -1 do
        local mf = manifests[i]
        list[#list + 1] = { text = mf.text, title = getText("IGUI_OA_Story_UI_ManifestTitle", tostring(mf.serial)) }
    end
    return list
end

function ISOADocsPanel:refresh()
    local r = record()
    self.entries = Tabs.entries(r)
    self.list:clear()
    for _, entry in ipairs(self.entries) do
        local title = entry.title or getText(Docs.titleKey(entry.id))
        self.list:addItem(title, entry)
    end
    self.open:setEnable(#self.entries > 0)
end

function ISOADocsPanel:onOpen()
    local row = self.list.items[self.list.selected]
    if not row then return end
    OA.StoryViewer.open(character(), { row.item })
end

function Tabs.docsTab(x, y, width, height)
    local panel = ISOADocsPanel:new(x or 0, y or 0, width or 520, height or 300)
    panel:initialise()
    panel:instantiate()
    panel:refresh()
    panels[#panels + 1] = panel
    while #panels > 6 do table.remove(panels, 1) end
    return panel
end

local function refreshAll()
    for _, panel in ipairs(panels) do
        if panel.javaObject then pcall(panel.refresh, panel) end
    end
end

OA.Sync.listen("missions", refreshAll)
OA.Sync.listen("story", refreshAll)
OA.Sync.listen("all", refreshAll)

-- ---------------------------------------------------------------------------------------------------------------
-- The missions tab: the two screens under a row of sub-tabs (DESIGN-terminal 6.4).

ISOAMissionsTab = ISPanel:derive("ISOAMissionsTab")

Tabs.SUBS = { "missions", "docs" }

function ISOAMissionsTab:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = false
    o.sub = "missions"
    return o
end

function ISOAMissionsTab:createChildren()
    self.subTabs = OASubTabs:new(0, 0, self.width, self.window.palette, self, ISOAMissionsTab.onSub)
    self.subTabs:initialise()
    self.subTabs.anchorRight = true
    self:addChild(self.subTabs)
    local y = self.subTabs.height + 6
    self.views = {
        missions = Tabs.missionTab(0, y, self.width, self.height - y),
        docs = Tabs.docsTab(0, y, self.width, self.height - y),
    }
    for _, view in pairs(self.views) do
        view.anchorRight = true
        view.anchorBottom = true
        self:addChild(view)
    end
    self:showSub("missions")
end

function ISOAMissionsTab:showSub(id)
    self.sub = id
    for vid, view in pairs(self.views) do view:setVisible(vid == id) end
    self:refresh()
end

function ISOAMissionsTab.onSub(self, id)
    if id ~= self.sub then self:showSub(id) end
end

function ISOAMissionsTab:refresh()
    local items = {}
    for _, id in ipairs(Tabs.SUBS) do items[#items + 1] = { id = id, label = getText("IGUI_OA_Story_Sub_" .. id) } end
    self.subTabs:setItems(items, self.sub)
    local view = self.views[self.sub]
    if view then view:refresh() end
end

local function onGameStart()
    if not (OA.Terminal and OA.Terminal.addTab) then return end
    local ok, err = pcall(OA.Terminal.addTab, "missions", function(x, y, w, h, window)
        return ISOAMissionsTab:new(x, y, w, h, window)
    end)
    if not ok then OA.log("missions tab failed:", tostring(err)) end
end
Events.OnGameStart.Add(onGameStart)

return Tabs
