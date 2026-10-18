-- The reading window: a document, or the several that an item holds (the front and the back of a form), with their
-- titles. Reading a document tells the server (it is kept in the terminal's folder by id) and shows the text the
-- translation files hold for it. Opened from an item's menu; the terminal's folder reads inside its own window.
require "ISUI/ISCollapsableWindow"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Markup"
require "PZUIKit/Typing"
require "OperationAcorn/Trade/UI"
require "PZUIKit/RichText"
require "PZUIKit/Button"
local OA = OperationAcorn
local Docs = OA.StoryDocs
local UI = OA.Trade.UI
local Viewer = {}
OA.StoryViewer = Viewer

-- Sizes in design units: the window is the game's, in pixels, so they are made pixels with the terminal's scale
-- (Trade/UI.lua) as the window is made; the text and the buttons in it are ours, in design units and our faces.
local PAD = 12
local BUTTON_H = 26
local BUTTON_W = 90
local WIDTH, HEIGHT = 520, 560

ISOAViewer = ISCollapsableWindow:derive("ISOAViewer")

function ISOAViewer:new(x, y, width, height, character)
    local o = ISCollapsableWindow.new(self, x, y, width, height)
    o.character = character
    o.docs = {}
    o.index = 1
    o.resizable = true
    o.era = UI.era
    o.backgroundColor = { r = 0.08, g = 0.08, b = 0.07, a = 1 }  -- a paper: nothing behind it shows through
    return o
end

function ISOAViewer:createChildren()
    ISCollapsableWindow.createChildren(self)
    -- the window's pixels as design units for our parts
    local th, w, h = UI.dp(self:titleBarHeight()), UI.dp(self.width), UI.dp(self.height)
    self.rich = PZUIRichText:new(PAD, th + PAD, w - PAD * 2, h - th - PAD * 3 - BUTTON_H)
    self.rich:initialise()
    self.rich.background = false
    self.rich.marginLeft, self.rich.marginTop, self.rich.marginRight, self.rich.marginBottom = 20, 10, 10, 10
    -- a document is read: the body one size up from the panels' small text, the title above it
    self.rich.defaultFont = UIFont.Medium
    self.rich:setAnchorRight(true)
    self.rich:setAnchorBottom(true)
    self:addChild(self.rich)
    local p = UI.palette("field")
    self.prev = PZUIButton:new(PAD, h - PAD - BUTTON_H, BUTTON_W, BUTTON_H, getText("IGUI_OA_Story_UI_Prev"), p, self,
        ISOAViewer.onPrev)
    self.next = PZUIButton:new(PAD + BUTTON_W + 8, h - PAD - BUTTON_H, BUTTON_W, BUTTON_H, getText("IGUI_OA_Story_UI_Next"),
        p, self, ISOAViewer.onNext)
    for _, b in ipairs({ self.prev, self.next }) do
        b:initialise()
        b:instantiate()
        b:setAnchorTop(false)
        b:setAnchorBottom(true)
        self:addChild(b)
    end
end

-- The game's bars, as high as our Small face, the title drawn in it (UI.windowTitle).
function ISOAViewer:titleBarHeight() return UI.titleBarHeight() end
function ISOAViewer:resizeWidgetHeight() return UI.resizeWidgetHeight() end

local WHITE = { 1, 1, 1 }

function ISOAViewer:prerender()
    local title = self.title
    self.title = nil
    ISCollapsableWindow.prerender(self)
    self.title = title
    UI.windowTitle(self, title, WHITE)
end

-- Another window worked the scale or the faces out again: this one was laid out in the old ones.
function ISOAViewer:update()
    ISCollapsableWindow.update(self)
    if self.era ~= UI.era then self:close() end
end

-- The body's colour where its text has none of its own; heads and dim lines take the field palette's.
local BODY = { 0.88, 0.88, 0.82 }

-- The reading text: a title line, a rule, the body as the folder shows a document (Typing.rich): its colours, its
-- line ends, and its own marks (Typing.marks: heads, bullets, dim lines, the sign-off).
local function formatText(title, body)
    -- A translation may carry its line ends as the two characters \n (the file reader keeps them).
    body = string.gsub(body, "\\n", "\n")
    local marked, styles = PZUIKit.Typing.marks(body, { fields = true })
    -- a text the markup reader refuses is shown as its plain characters
    local read = OA.Markup.parse(marked) or { plain = OA.Markup.strip(marked), runs = {} }
    local p = UI.palette("field")
    return " <H1> <RGB:1,1,1> " .. title .. " <LINE> <LINE>"
        .. PZUIKit.Typing.rich(read, BODY, styles, { head = p.head, dim = p.dim })
end

function ISOAViewer:show(i)
    local entry = self.docs[i]
    if not entry then return end
    self.index = i
    local record = OA.Client.record(self.character)
    local title = getText(Docs.titleKey(entry.id))
    local body
    if entry.stake then
        body = Docs.stakeBody(entry.stake, entry.date)
    else
        body = record and Docs.body(record, entry.id, entry.variant, entry.extra, entry.no) or ""
    end
    self.rich.text = formatText(title, body)
    self.rich:paginate()
    self.rich:setYScroll(0)
    self:setTitle(#self.docs > 1 and (title .. "  (" .. i .. "/" .. #self.docs .. ")") or title)
    self.prev:setEnable(i > 1)
    self.next:setEnable(i < #self.docs)
    self.prev:setVisible(#self.docs > 1)
    self.next:setVisible(#self.docs > 1)
    if not entry.noRecord then
        OA.Sync.send(self.character, "story_read", { doc = entry.id, variant = entry.variant, extra = entry.extra,
            no = entry.no })
    end
end

function ISOAViewer:onPrev() self:show(self.index - 1) end
function ISOAViewer:onNext() self:show(self.index + 1) end

function ISOAViewer:close()
    UI.fadeOut(self)
    Viewer.instance = nil
end

-- Opens the window on a list of { id =, variant =, extra =, no = }; `noRecord` entries (a survey stake, which is not a paper of
-- the folder) are not told to the server. It opens in front of the terminal's window when that is open.
function Viewer.open(character, docs)
    if not docs or #docs == 0 then return end
    if Viewer.instance then Viewer.instance:close() end
    local core = getCore()
    UI.refreshScale()
    local w = math.min(UI.px(WIDTH), core:getScreenWidth() - 40, math.floor(core:getScreenWidth() * 0.9))
    local h = math.min(UI.px(HEIGHT), core:getScreenHeight() - 80, math.floor(core:getScreenHeight() * 0.9))
    local ui = ISOAViewer:new((core:getScreenWidth() - w) / 2, (core:getScreenHeight() - h) / 2, w, h, character)
    ui:initialise()
    ui:addToUIManager()
    ui:bringToTop()
    UI.fadeIn(ui)
    ui.docs = docs
    ui:show(1)
    Viewer.instance = ui
end

return Viewer
