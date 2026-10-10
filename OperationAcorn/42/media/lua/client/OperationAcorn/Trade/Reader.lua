-- A small reading window: the supply manifest that came in a crate, and the last page of the terminal manual.
require "ISUI/ISCollapsableWindow"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Trade/RichText"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text

OAReaderWindow = ISCollapsableWindow:derive("OAReaderWindow")
local WHITE = { 1, 1, 1 }
OAReaderWindow.instances = {}
-- The default size in design units: the window is the game's, in pixels, so these are times the terminal's scale
-- (Trade/UI.lua), within 90% of the screen.
OAReaderWindow.WIDTH, OAReaderWindow.HEIGHT = 460, 420

function OAReaderWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top, bottom = self:titleBarHeight(), self:resizeWidgetHeight()
    -- our rich text, in design units (the window is in pixels)
    self.body = UI.rich(self, 0, UI.dp(top), UI.dp(self.width), UI.dp(self.height - top - bottom))
    self.body:setAnchorRight(true)
    self.body:setAnchorBottom(true)
    UI.setRich(self.body, self.richText)
end

-- The game's bars, as high as our Small face, the title drawn in it (UI.windowTitle).
function OAReaderWindow:titleBarHeight() return UI.titleBarHeight() end
function OAReaderWindow:resizeWidgetHeight() return UI.resizeWidgetHeight() end

function OAReaderWindow:prerender()
    local title = self.title
    self.title = nil
    ISCollapsableWindow.prerender(self)
    self.title = title
    UI.windowTitle(self, title, WHITE)
end

-- Another window worked the scale or the faces out again: this one was laid out in the old ones.
function OAReaderWindow:update()
    ISCollapsableWindow.update(self)
    if self.era ~= UI.era then self:close() end
end

function OAReaderWindow:close()
    OAReaderWindow.instances[self.playerNum] = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

function OAReaderWindow:new(character, title, richText)
    UI.refreshScale()
    local core = getCore()
    local width = math.min(UI.px(OAReaderWindow.WIDTH), math.floor(core:getScreenWidth() * 0.9))
    local height = math.min(UI.px(OAReaderWindow.HEIGHT), math.floor(core:getScreenHeight() * 0.9))
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = { r = 0.02, g = 0.02, b = 0.03, a = 0.93 }
    o.title = title
    o.richText = richText
    o.playerNum = character:getPlayerNum()
    o.era = UI.era
    o:setResizable(true)
    return o
end

local Reader = {}
Trade.Reader = Reader

-- Opens the window with rich text (the window closes the one the player had open).
function Reader.open(character, title, richText)
    local previous = OAReaderWindow.instances[character:getPlayerNum()]
    if previous then previous:close() end
    local window = OAReaderWindow:new(character, title, richText)
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    OAReaderWindow.instances[character:getPlayerNum()] = window
    return window
end

-- The supply manifest item: the receipt it carries (kept in the item's modData by the helicopter), written out.
function Reader.manifest(character, item)
    local receipt = item:getModData().OA_Receipt
    local lines
    if receipt then
        lines = Text.receipt(receipt)
    else
        lines = { { kind = "line", text = getText("IGUI_OA_Trade_Manifest_Blank") } }
    end
    Reader.open(character, getText("IGUI_OA_Trade_Manifest_Title"), UI.richLines(lines))
end

-- The last page of the terminal manual: the survivor's collection point number written by hand over the trace of an
-- erased one (LORE: start, clue 1).
function Reader.lastPage(character)
    local record = OA.Client.record(character)
    local number = record and record.number or 0
    local text = " <H2> <RGB:1,1,1> " .. getText("IGUI_OA_Trade_Manual_LastPage") .. " <LINE> <TEXT> <RGB:0.85,0.85,0.7> "
        .. getText("IGUI_OA_Trade_Manual_Erased") .. " <LINE> "
        .. getText("IGUI_OA_Trade_Manual_Number", string.format("%04d", number)) .. " <LINE> "
    Reader.open(character, getText("IGUI_OA_Trade_Manual_Title"), text)
end

return Reader
