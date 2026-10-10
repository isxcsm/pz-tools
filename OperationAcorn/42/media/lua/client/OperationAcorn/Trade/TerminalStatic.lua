-- The crude terminal's static: specks and streaks laid very faintly over the window's body, behind the tabs, scrolling
-- down and flickering between two tiles (tools/static_art.py): the screen of a set with a weak signal. A panel of its
-- own, behind the strip and the views, followed each frame (Trade/UI live): with PZ Optimization only it is drawn
-- afresh while the views' drawings are reused. It takes no clicks. The window's own weak-signal spells fade it with the
-- rest (they are drawn over the children).
require "ISUI/ISPanel"
require "OperationAcorn/Trade/UI"
local UI = OperationAcorn.Trade.UI

OATerminalStatic = ISPanel:derive("OATerminalStatic")

OATerminalStatic.TILES = { "media/textures/OA_Static_1.png", "media/textures/OA_Static_2.png" }
-- The tiles' side (pixels), how faint the static is (its tint's alpha), how fast it scrolls (pixels a second) and how
-- often the two tiles swap (ms).
OATerminalStatic.TILE = 256
OATerminalStatic.ALPHA, OATerminalStatic.SPEED, OATerminalStatic.SWAP_MS = 0.2, 40, 90

-- In the window's pixels (a plain game panel, not one of our scaled ones).
function OATerminalStatic:new(x, y, width, height, window)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.background = false
    o.window = window
    o.tiles = { getTexture(OATerminalStatic.TILES[1]), getTexture(OATerminalStatic.TILES[2]) }
    return o
end

function OATerminalStatic:createChildren()
    self.javaObject:setConsumeMouseEvents(false)
end

-- What it shows at `now` (ms): the tile and how far it has scrolled, written for prerender; the look for Trade/UI live.
-- Counted from the first frame (Kahlua's % goes wrong on numbers as large as the clock's).
function OATerminalStatic.frame(self, now)
    local S = OATerminalStatic
    self.from = self.from or now
    local t = now - self.from
    local swap = math.floor(t / S.SWAP_MS)
    local offset = math.floor(t * S.SPEED / 1000) % S.TILE
    self.tileIndex, self.offset = swap % 2 + 1, offset
    return swap * S.TILE + offset
end

function OATerminalStatic:prerender()
    local tex = self.tiles[self.tileIndex or 1]
    if not tex then return end
    local S = OATerminalStatic
    local c = self.window.palette.text
    self:setStencilRect(0, 0, self.width, self.height)
    local y = (self.offset or 0) - S.TILE
    self:drawTextureTiled(tex, 0, y, self.width, self.height + S.TILE, c[1], c[2], c[3], S.ALPHA)
    self:clearStencilRect()
end

-- The static for a window, put behind what the window holds (call it before the strip and the views are added) and
-- followed each frame while it shows.
function OATerminalStatic.attach(window, top, bottom)
    local panel = OATerminalStatic:new(0, top, window.width, window.height - top - bottom, window)
    panel:initialise()
    panel:instantiate()
    panel:setAnchorRight(true)
    panel:setAnchorBottom(true)
    window:addChild(panel)
    UI.live(panel, OATerminalStatic.frame)
    return panel
end

return OATerminalStatic
