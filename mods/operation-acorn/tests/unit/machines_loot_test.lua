-- How the loot window lights a machine (client/Machines/LootReach): the chosen bin's machine whole, filled and outlined
-- in the chosen colour, the machine under the mouse outlined in the hover colour, as the game lights a container's
-- object; set again only when that changes or when the game has switched one of its squares, and never left lit after
-- the mouse goes. The game's page is a stand-in that does what the game's does to single objects (it lights and
-- outlines the chosen container's object each update, outlines the hovered one, and switches objects off).
require "OperationAcorn/Core"
local OA = OperationAcorn

local function colour(name, r, g, b)
    return { name = name, getR = function() return r end, getG = function() return g end, getB = function() return b end }
end
local CHOSEN, HOVER = colour("chosen", 1, 0.5, 0), colour("hover", 0.2, 0.6, 1)
-- the game's container outline option
local outlineOption = true

-- An object of a square: what is set on it for player 0 (the outline's colour by the colour's red).
local function object(name)
    local o = { name = name, lit = false, outline = false, colour = nil, outlineR = nil, sets = 0 }
    function o:setHighlighted(_, on) self.lit = on; self.sets = self.sets + 1 end
    function o:setOutlineHighlight(_, on) self.outline = on end
    function o:setOutlineHlAttached() end
    function o:setOutlineHighlightCol(_, r) self.outlineR = r end
    function o:setHighlightColor(_, c) self.colour = c end
    return o
end

-- Whether the object is outlined in the colour.
local function outlinedIn(o, c) return o.outline and o.outlineR == c.getR() end

local function load()
    outlineOption = true
    local page = {}
    -- the game's own, as far as these objects go
    function page.OnObjectHighlighted() end
    function page:getContainerParent(container) return container and container.parent or nil end
    function page:updateContainerHighlight()
        local parent = self:getContainerParent(self.inventory)
        local old = self:getContainerParent(self.coloredInv)
        if old and old ~= parent then old:setHighlighted(self.player, false); old:setOutlineHighlight(self.player, false) end
        if parent and not self.isCollapsed then
            parent:setHighlighted(self.player, true)
            parent:setOutlineHighlight(self.player, true)
            parent:setOutlineHighlightCol(self.player, CHOSEN.getR())
            parent:setHighlightColor(self.player, CHOSEN)
            self.coloredInv = self.inventory
        end
    end
    function page:onMouseOverButton(button)
        self.mouseOverButton = button
        local o = self:getContainerParent(button.inventory)
        if o then
            o:setOutlineHighlight(self.player, true)
            o:setOutlineHighlightCol(self.player, HOVER.getR())
        end
    end
    function page:onMouseOutButton()
        self.mouseOverButton = nil
    end
    function page:stopHighlightContainer(o)
        o:setHighlighted(self.player, false)
        o:setOutlineHighlight(self.player, false)
    end
    ISInventoryPage = page
    Events = Events or {}
    Events.OnRefreshInventoryWindowContainers = { Add = function() end }
    getCore = function()
        return { getObjectHighlitedColor = function() return CHOSEN end,
            getWorldItemHighlightColor = function() return HOVER end,
            getOptionDoContainerOutline = function() return outlineOption end }
    end
    -- four machines: A and B of two squares (bins on A's both), C a cabinet of two halves (a container on each
    -- square: Data everyTile), D of one square (the research crate)
    local a1, a2, b1, b2, c1, c2, d1 = object("a1"), object("a2"), object("b1"), object("b2"), object("c1"), object("c2"), object("d1")
    local machineOf = { [a1] = "A", [a2] = "A", [b1] = "B", [b2] = "B", [c1] = "C", [c2] = "C", [d1] = "D" }
    local squares = { A = { a1, a2 }, B = { b1, b2 }, C = { c1, c2 }, D = { d1 } }
    local kinds = { A = "refiner", B = "saw", C = "cabinet", D = "crate" }
    OA.Machines = OA.Machines or {}
    OA.Machines.isMachineObject = function(o) return machineOf[o] ~= nil end
    OA.Machines.anchorOf = function(o) local m = machineOf[o]; return squares[m][1], { machine = m, kind = kinds[m] } end
    OA.Machines.Data = { KINDS = { refiner = {}, saw = {}, cabinet = { everyTile = true }, crate = {} } }
    OA.Machines.partsOf = function(state)
        local list = {}
        for i = 2, #squares[state.machine] do list[#list + 1] = { object = squares[state.machine][i] } end
        return list
    end
    local real = require
    require = function(file)
        if string.find(file, "^ISUI/") or file == "OperationAcorn/Machines/Machines" then return true end
        return real(file)
    end
    local ok, err = pcall(real, "OperationAcorn/Machines/LootReach")
    require = real
    if not ok then error(err, 0) end
    local p = setmetatable({ player = 0, isCollapsed = false }, { __index = ISInventoryPage })
    return p, a1, a2, b1, b2, c1, c2, d1
end

test("the chosen bin's machine is lit whole, filled and outlined in the chosen colour", function()
    local page, a1, a2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    truthy(a1.lit and a2.lit, "both squares")
    eq(a1.colour, CHOSEN); eq(a2.colour, CHOSEN)
    truthy(outlinedIn(a1, CHOSEN) and outlinedIn(a2, CHOSEN), "every square outlined alike: one outline")
    -- the frames after: the game lights the bin's square again as it is; nothing else is set
    local sets = a2.sets
    for _ = 1, 10 do page:updateContainerHighlight() end
    truthy(outlinedIn(a1, CHOSEN))
    eq(a2.sets, sets, "an update with nothing changed sets nothing on the other square")
end)

test("going between a machine's two bins keeps every square lit", function()
    local page, a1, a2 = load()
    local binA, binB = { parent = a1 }, { parent = a2 }
    page.inventory = binA
    page:updateContainerHighlight()
    page.inventory = binB
    page:updateContainerHighlight()
    truthy(a1.lit and a2.lit, "the game switched the first bin's square off; it is lit again")
    eq(a1.colour, CHOSEN); eq(a2.colour, CHOSEN)
    truthy(outlinedIn(a1, CHOSEN) and outlinedIn(a2, CHOSEN))
end)

test("the machine under the mouse is outlined whole in the hover colour, and goes dark when the mouse goes", function()
    local page, a1, a2, b1, b2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    local button = { inventory = { parent = b1 } }
    page:onMouseOverButton(button)
    page:updateContainerHighlight()
    truthy(outlinedIn(b1, HOVER) and outlinedIn(b2, HOVER), "every square outlined in the hover colour")
    truthy(not b1.lit and not b2.lit, "outlined only, as the game's hover")
    page:onMouseOutButton(button)
    page:updateContainerHighlight()
    truthy(not b1.outline and not b2.outline, "nothing left outlined in the hover colour")
    truthy(a1.lit and a2.lit, "the chosen machine keeps its light")
end)

test("the mouse over the chosen machine's other bin keeps that square in the chosen colour", function()
    local page, a1, a2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    page:onMouseOverButton({ inventory = { parent = a2 } })
    truthy(outlinedIn(a2, CHOSEN), "the game's hover outline is put back at once")
    page:updateContainerHighlight()
    truthy(outlinedIn(a2, CHOSEN) and a2.lit)
end)

test("a square the game switches off stays lit: no frame shows it dark", function()
    local page, a1, a2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    -- as the game does when the mouse leaves the chosen machine's other bin
    page:stopHighlightContainer(a2)
    truthy(a2.lit and outlinedIn(a2, CHOSEN), "lit again at once, before the world is drawn")
    eq(a2.colour, CHOSEN)
    page:updateContainerHighlight()
    truthy(a2.lit); eq(a2.colour, CHOSEN)
end)

test("a hovered machine the game switches off as the mouse leaves goes dark at the next update", function()
    local page, a1, _, b1 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    local button = { inventory = { parent = b1 } }
    page:onMouseOverButton(button)
    page:updateContainerHighlight()
    truthy(b1.outline)
    page:onMouseOutButton(button)
    page:stopHighlightContainer(b1)
    page:updateContainerHighlight()
    truthy(not b1.outline and not b1.lit, "not left lit")
end)

test("a machine of one square is lit the same way", function()
    local page, a1, _, _, _, _, _, d1 = load()
    page.inventory = { parent = d1 }
    page:updateContainerHighlight()
    truthy(d1.lit and outlinedIn(d1, CHOSEN))
    page.inventory = { parent = a1 }
    page:stopHighlightContainer(d1)
    page:updateContainerHighlight()
    truthy(not d1.lit and not d1.outline, "dark once another is chosen")
end)

test("a cabinet with a container on each square is lit whole, from either half", function()
    local page, _, _, _, _, c1, c2 = load()
    page.inventory = { parent = c2 }
    page:updateContainerHighlight()
    truthy(c1.lit and c2.lit and outlinedIn(c1, CHOSEN) and outlinedIn(c2, CHOSEN), "both halves, as one")
    page.inventory = { parent = c1 }
    page:updateContainerHighlight()
    truthy(c1.lit and c2.lit and outlinedIn(c2, CHOSEN), "the same from the other half")
end)

test("without the game's container outline option: filled, not outlined", function()
    local page, a1, a2, b1 = load()
    outlineOption = false
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    truthy(a2.lit and not a2.outline)
    page:onMouseOverButton({ inventory = { parent = b1 } })
    page:updateContainerHighlight()
    truthy(not b1.lit, "nothing for the mouse, as the game")
end)

test("a collapsed window lights nothing", function()
    local page, a1, a2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    page.isCollapsed = true
    page:updateContainerHighlight()
    truthy(not a2.lit and not a2.outline, "the machine's other square goes dark with the window")
end)
