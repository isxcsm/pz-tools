-- The reading window: a document, or the several that an item holds (the front and the back of a form), with their
-- titles. Reading a document tells the server (it is kept in the terminal's folder by id) and shows the text the
-- translation files hold for it. Opened from an item's menu and from the folder in the terminal.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISRichTextPanel"
require "ISUI/ISButton"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Story/Docs"
local OA = OperationAcorn
local Docs = OA.StoryDocs
local Viewer = {}
OA.StoryViewer = Viewer

local PAD = 12
local BUTTON_H = 26

ISOAViewer = ISCollapsableWindow:derive("ISOAViewer")

function ISOAViewer:new(x, y, width, height, character)
    local o = ISCollapsableWindow.new(self, x, y, width, height)
    o.character = character
    o.docs = {}
    o.index = 1
    o.resizable = true
    o.backgroundColor = { r = 0.08, g = 0.08, b = 0.07, a = 0.95 }
    return o
end

function ISOAViewer:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    self.rich = ISRichTextPanel:new(PAD, th + PAD, self.width - PAD * 2, self.height - th - PAD * 3 - BUTTON_H)
    self.rich:initialise()
    self.rich.autosetheight = false
    self.rich.clip = true
    self.rich.background = false
    -- a document is read: the body one size up from the panels' small text, the title above it
    self.rich.defaultFont = UIFont.Medium
    self.rich:addScrollBars()
    self.rich.anchorRight = true
    self.rich.anchorBottom = true
    self:addChild(self.rich)
    local w = 90
    self.prev = ISButton:new(PAD, self.height - PAD - BUTTON_H, w, BUTTON_H, getText("IGUI_OA_Story_UI_Prev"), self, ISOAViewer.onPrev)
    self.prev:initialise()
    self.prev:instantiate()
    self.prev.anchorTop = false
    self.prev.anchorBottom = true
    self:addChild(self.prev)
    self.next = ISButton:new(PAD + w + 8, self.height - PAD - BUTTON_H, w, BUTTON_H, getText("IGUI_OA_Story_UI_Next"), self, ISOAViewer.onNext)
    self.next:initialise()
    self.next:instantiate()
    self.next.anchorTop = false
    self.next.anchorBottom = true
    self:addChild(self.next)
end

-- The reading text: a title line, a rule, the body with its line ends turned into the panel's line commands.
local function formatText(title, body)
    local text = " <H1> <RGB:1,1,1> " .. title .. " <LINE> <LINE> <TEXT> <RGB:0.88,0.88,0.82> "
    local lines = {}
    -- A translation may carry its line ends as the two characters \n (the file reader keeps them).
    body = string.gsub(body, "\\n", "\n")
    for line in string.gmatch(body .. "\n", "(.-)\n") do lines[#lines + 1] = line end
    return text .. table.concat(lines, " <LINE> ")
end

function ISOAViewer:show(i)
    local entry = self.docs[i]
    if not entry then return end
    self.index = i
    local record = OA.Client.record(self.character)
    local title, body
    if entry.text then
        -- A text kept as it was (a manifest of the folder).
        title, body = entry.title or "", entry.text
    else
        title = getText(Docs.titleKey(entry.id))
        body = record and Docs.body(record, entry.id, entry.variant, entry.extra) or ""
        if entry.stake then body = Docs.stakeBody(entry.stake, entry.date) end
    end
    self.rich.text = formatText(title, body)
    self.rich:paginate()
    self.rich:setYScroll(0)
    self:setTitle(#self.docs > 1 and (title .. "  (" .. i .. "/" .. #self.docs .. ")") or title)
    self.prev:setEnable(i > 1)
    self.next:setEnable(i < #self.docs)
    self.prev:setVisible(#self.docs > 1)
    self.next:setVisible(#self.docs > 1)
    if not entry.noRecord and not entry.text then
        OA.Sync.send(self.character, "story_read", { doc = entry.id, variant = entry.variant })
    end
end

function ISOAViewer:onPrev() self:show(self.index - 1) end
function ISOAViewer:onNext() self:show(self.index + 1) end

function ISOAViewer:close()
    self:removeFromUIManager()
    Viewer.instance = nil
end

-- Opens the window on a list of { id =, variant =, extra = }; `noRecord` entries (a document already in the folder
-- being looked at again) are not told to the server.
function Viewer.open(character, docs)
    if not docs or #docs == 0 then return end
    if Viewer.instance then Viewer.instance:close() end
    local core = getCore()
    local w = math.min(520, core:getScreenWidth() - 40)
    local h = math.min(560, core:getScreenHeight() - 80)
    local ui = ISOAViewer:new((core:getScreenWidth() - w) / 2, (core:getScreenHeight() - h) / 2, w, h, character)
    ui:initialise()
    ui:addToUIManager()
    ui.docs = docs
    ui:show(1)
    Viewer.instance = ui
end

return Viewer
