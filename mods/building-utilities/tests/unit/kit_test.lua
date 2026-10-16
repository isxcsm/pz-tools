-- The shared UI kit (PZUIKit) as this mod's windows lean on it: a fading window wraps an element added while it fades
-- (only then is the tree gone through again), an element is followed once, and one text cache that fills starts over
-- alone.
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

local Element = {}
Element.__index = Element
function Element:isVisible() return true end
function Element:drawRect(x, y, w, h, a) self.drawn = a end
function Element:addChild(child)
    self.children[#self.children + 1] = child
    child.parent = self
end

local function element(parent)
    local el = setmetatable({ parent = parent, children = {} }, Element)
    if parent then parent:addChild(el) end
    return el
end

test("an element added to a window while it fades is wrapped at the next step, and not before", function()
    local UI = load()
    local window = element(nil)
    local child = element(window)
    UI.fadeIn(window, 100)
    UI.liveFrame()
    now = 1050
    UI.liveFrame()
    local late = element(window)
    late:drawRect(0, 0, 1, 1, 0.8)
    eq(late.drawn, 0.8, "not wrapped until the window steps")
    now = 1060
    UI.liveFrame()
    late:drawRect(0, 0, 1, 1, 0.8)
    truthy(late.drawn < 0.8 and late.drawn > 0, "wrapped: drawn through the fade")
    child:drawRect(0, 0, 1, 1, 0.8)
    truthy(child.drawn < 0.8 and child.drawn > 0, "the first child still is")
    now = 1100
    UI.liveFrame()
    late:drawRect(0, 0, 1, 1, 0.8)
    eq(late.drawn, 0.8, "drawn as ever once whole")
    local own = false
    for key in pairs(window) do if key == "addChild" then own = true end end
    eq(own, false, "the hook is gone with the wrappers")
end)

test("an element is followed once for a frame function, however often it is asked", function()
    local UI = load()
    local window = element(nil)
    local el = element(window)
    local frames = 0
    local function frame() frames = frames + 1; return now < 1100 and now or nil end
    for _ = 1, 5 do UI.live(el, frame) end
    UI.liveFrame()
    eq(frames, 1)
    now = 1200
    UI.liveFrame()
    eq(frames, 2)
    UI.liveFrame()
    eq(frames, 2, "let go once it returns nil")
    UI.live(el, frame)
    UI.liveFrame()
    eq(frames, 3, "and followed again when asked again")
end)

test("the text caches fill and start over each on its own", function()
    local UI = load()
    getTextManager = function()
        return { MeasureStringX = function(_, _, text) return #text * 7 end, getFontHeight = function() return 16 end }
    end
    local lines = UI.wrapMemo("hello there world", 40)
    eq(UI.wrapMemo("hello there world", 40), lines, "kept")
    for i = 1, 4100 do UI.textWidth("text " .. i) end
    eq(UI.wrapMemo("hello there world", 40), lines, "the widths filled and started over: the wraps kept")
end)
