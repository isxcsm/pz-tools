-- The shared UI kit's fading of a window in and out (PZUIKit UI.fadeIn, UI.fadeOut): what it and its children draw is
-- scaled by the fade while it lasts and drawn as ever after; going, it takes no clicks, does nothing each frame and is
-- taken away at the end.
require "OperationAcorn/Core"

local now

local function load()
    local panel = {}
    panel.derive = function(self)
        local d = setmetatable({}, { __index = self })
        d.__index = d
        return d
    end
    ISPanel = panel
    UIFont = UIFont or setmetatable({}, { __index = function(_, k) return k end })
    now = 1000
    getTimestampMs = function() return now end
    Events = Events or {}
    Events.OnPreUIDraw = Events.OnPreUIDraw or { Add = function() end }
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "PZUIKit/UI")
    require = real
    if not ok then error(err, 0) end
    return PZUIKit.UI
end

-- An element class whose drawRect keeps the alpha it was given, its clicks counted.
local Element = {}
Element.__index = Element
function Element:isVisible() return self.visible ~= false end
function Element:setVisible(v) self.visible = v end
function Element:removeFromUIManager() self.removed = true end
function Element:drawRect(x, y, w, h, a) self.drawn = a end
function Element:drawText(text, x, y, r, g, b, a) self.text = a end
function Element:onMouseDown() self.clicks = (self.clicks or 0) + 1 end
function Element:update() self.updates = (self.updates or 0) + 1 end

local function element(parent)
    local el = setmetatable({ parent = parent, children = {} }, Element)
    if parent then parent.children[#parent.children + 1] = el end
    return el
end

test("a window fading in draws, with its children, more and more, then as ever", function()
    local UI = load()
    local window = element(nil)
    local child = element(window)
    UI.fadeIn(window, 100)
    UI.liveFrame()
    child:drawRect(0, 0, 1, 1, 0.8)
    eq(child.drawn, 0, "at the start nothing shows")
    now = 1050
    UI.liveFrame()
    window:drawRect(0, 0, 1, 1, 1)
    child:drawText("x", 0, 0, 1, 1, 1, 0.8)
    eq(window.drawn, 0.5, "half way")
    eq(child.text, 0.4, "a child's text too")
    now = 1100
    UI.liveFrame()
    local own = false
    for key in pairs(child) do if key == "drawRect" then own = true end end
    eq(own, false, "the wrappers are gone (the game's rawget reads through to the class)")
    child:drawRect(0, 0, 1, 1, 0.8)
    eq(child.drawn, 0.8, "drawn as ever")
end)

test("a window fading out takes no clicks, stills its elements and is taken away at the end", function()
    local UI = load()
    local window = element(nil)
    local child = element(window)
    UI.fadeOut(window, nil, 100)
    UI.liveFrame()
    child:onMouseDown()
    child:update()
    eq(child.clicks, nil, "no clicks")
    eq(child.updates, nil, "no update")
    now = 1060
    UI.liveFrame()
    window:drawRect(0, 0, 1, 1, 1)
    truthy(math.abs(window.drawn - 0.4) < 1e-6, "fading")
    eq(window.removed, nil)
    now = 1100
    UI.liveFrame()
    eq(window.removed, true, "taken away")
    eq(window.visible, false)
    UI.fadeOut(window)
    eq(window.uiFading, nil, "once gone, nothing again")
end)

test("a window closed while it fades in goes from where it was", function()
    local UI = load()
    local window = element(nil)
    UI.fadeIn(window, 100)
    now = 1030
    UI.liveFrame()
    UI.fadeOut(window, nil, 100)
    eq(window.uiFading.ms, 30, "the share it had shown")
    now = 1060
    UI.liveFrame()
    eq(window.removed, true)
end)
