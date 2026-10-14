-- The shared UI kit's fading of a window in and out (PZUIKit UI.fadeIn, UI.fadeOut) and thinning it while the character
-- works behind it (UI.fadeTo, UI.aside): what it and its children draw is
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
    truthy(math.abs(window.drawn - 0.352) < 1e-6, "fading, eased: 1 - smoothstep(0.6)")
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
    truthy(math.abs(window.uiFading.ms - 21.6) < 1e-6, "the share it had shown (eased: smoothstep(0.3))")
    now = 1060
    UI.liveFrame()
    eq(window.removed, true)
end)

test("what goes past an element's draws (an icon, a text at pixels) takes the window's fade once, through the class", function()
    local UI = load()
    function Element:drawTextureScaledAspect(texture, x, y, w, h, a) self.icon = a end
    local window = element(nil)
    local child = element(window)
    UI.fadeIn(window, 100)
    now = 1050
    UI.liveFrame()
    eq(UI.faded(child, 0.8), 0.4, "half way")
    UI.iconPx(child, "tex", 0, 0, 32, 32, 0.8)
    eq(child.icon, 0.4, "the class's draw, faded once")
    UI.textAtPx(child, "x", 0, 0, { 1, 1, 1 }, nil, 0.8)
    eq(child.text, 0.4, "a text at pixels, faded once")
    now = 1100
    UI.liveFrame()
    eq(UI.faded(child, 0.8), 0.8, "whole again")
    Element.drawTextureScaledAspect = nil
end)

test("a game text box in a fading window has its text colour faded, and whole again at the end", function()
    local UI = load()
    ColorInfo = { new = function(r, g, b, a)
        local c = { r = r, g = g, b = b, a = a }
        function c:set(r2, g2, b2, a2) self.r, self.g, self.b, self.a = r2, g2, b2, a2; return self end
        return c
    end }
    local window = element(nil)
    local box = element(window)
    box.Type = "ISTextEntryBox"
    box.javaObject = { setTextColor = function(_, c) box.textAlpha = c.a end }
    UI.fadeIn(window, 100)
    now = 1050
    UI.liveFrame()
    eq(box.textAlpha, 0.5, "half way")
    now = 1100
    UI.liveFrame()
    eq(box.textAlpha, 1, "whole again")
end)

test("a window thinned (UI.fadeTo) stays so, taking clicks, until it is brought back whole", function()
    local UI = load()
    local window = element(nil)
    local child = element(window)
    UI.fadeTo(window, 0.2, 100)
    truthy(math.abs(window.uiFading.ms - 80) < 1e-6, "the share of the full change it goes")
    now = 1080
    UI.liveFrame()
    UI.liveFrame()
    eq(window.uiFading, nil, "settled")
    child:drawRect(0, 0, 1, 1, 0.5)
    eq(child.drawn, 0.1, "drawn thin, held")
    child:onMouseDown()
    eq(child.clicks, 1, "it takes clicks")
    UI.fadeTo(window, 1, 100)
    now = 1160
    UI.liveFrame()
    child:drawRect(0, 0, 1, 1, 0.5)
    eq(child.drawn, 0.5, "whole again")
    local own = false
    for key in pairs(child) do if key == "drawRect" then own = true end end
    eq(own, false, "its wrappers gone")
end)

test("a window closed while thinned goes from how thin it was", function()
    local UI = load()
    local window = element(nil)
    UI.fadeTo(window, 0.2, 100)
    now = 1080
    UI.liveFrame()
    UI.liveFrame()
    UI.fadeOut(window, nil, 100)
    truthy(math.abs(window.uiFading.ms - 20) < 1e-6, "its share of the fade-out")
    eq(window.uiFading.from, 0.2)
end)

test("a window steps aside while the action it queued is on, not while held, and is whole after it", function()
    local UI = load()
    local queued = {}
    ISTimedActionQueue = { hasAction = function(a) return queued[a] == true end }
    local window = element(nil)
    local action = {}
    UI.aside(window, action)
    eq(window.uiAside, nil, "an action not queued: nothing")
    queued[action] = true
    UI.aside(window, action)
    eq(window.uiFading.to, UI.ASIDE, "thinning")
    UI.stepAside(window, true)
    eq(window.uiFading.to, 1, "held: whole meanwhile")
    UI.stepAside(window)
    eq(window.uiFading.to, UI.ASIDE, "aside again")
    queued[action] = nil
    UI.stepAside(window)
    eq(window.uiFading.to, 1, "the action done: whole")
    eq(window.uiBusy, nil)
end)
