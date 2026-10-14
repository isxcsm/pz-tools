-- How the loot window lights a machine of several squares (client/Machines/LootReach): the chosen bin's machine all
-- in the chosen colour, the machine under the mouse in the hover colour, set again only when that changes or when the
-- game has switched one of its squares, and never left lit after the mouse goes. The game's page is a stand-in that
-- does what the game's does to single objects (it lights and outlines the chosen container's object each update,
-- outlines the hovered one, and switches objects off).
require "OperationAcorn/Core"
local OA = OperationAcorn

local CHOSEN, HOVER = { name = "chosen" }, { name = "hover" }

-- An object of a square: what is set on it for player 0.
local function object(name)
    local o = { name = name, lit = false, outline = false, colour = nil, sets = 0 }
    function o:setHighlighted(_, on) self.lit = on; self.sets = self.sets + 1 end
    function o:setOutlineHighlight(_, on) self.outline = on end
    function o:setOutlineHlAttached() end
    function o:setOutlineHighlightCol() end
    function o:setHighlightColor(_, c) self.colour = c end
    return o
end

local function load()
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
            self.coloredInv = self.inventory
        end
    end
    function page:onMouseOverButton(button)
        self.mouseOverButton = button
        local o = self:getContainerParent(button.inventory)
        if o then o:setOutlineHighlight(self.player, true) end
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
            getWorldItemHighlightColor = function() return HOVER end }
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
    return p, a1, a2, b1, c1, c2, d1
end

test("the chosen bin's machine is lit whole in the chosen colour, without outlines", function()
    local page, a1, a2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    truthy(a1.lit and a2.lit, "both squares")
    eq(a1.colour, CHOSEN); eq(a2.colour, CHOSEN)
    truthy(not a1.outline, "the outline the game puts on is taken off")
    -- the frames after: the game outlines it again; nothing else is set
    local sets = a2.sets
    for _ = 1, 10 do page:updateContainerHighlight() end
    truthy(not a1.outline)
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
    truthy(not a2.outline)
end)

test("the machine under the mouse is lit in the hover colour, and goes dark when the mouse goes", function()
    local page, a1, a2, b1 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    local button = { inventory = { parent = b1 } }
    page:onMouseOverButton(button)
    truthy(not b1.outline, "not outlined even for the frame before the update")
    page:updateContainerHighlight()
    truthy(b1.lit); eq(b1.colour, HOVER)
    truthy(not b1.outline, "lit as one, not outlined")
    page:onMouseOutButton(button)
    page:updateContainerHighlight()
    truthy(not b1.lit, "nothing left lit in the hover colour")
    truthy(a1.lit and a2.lit, "the chosen machine keeps its light")
end)

test("a square the game switches off stays lit: no frame shows it dark", function()
    local page, a1, a2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    -- as the game does when the mouse leaves the chosen machine's other bin
    page:stopHighlightContainer(a2)
    truthy(a2.lit, "lit again at once, before the world is drawn")
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
    truthy(b1.lit)
    page:onMouseOutButton(button)
    page:stopHighlightContainer(b1)
    page:updateContainerHighlight()
    truthy(not b1.lit, "not left lit")
end)

test("a machine of one square is lit as the game lights its crates: outlined", function()
    local page, a1, _, _, _, _, d1 = load()
    page.inventory = { parent = d1 }
    page:updateContainerHighlight()
    truthy(d1.lit and d1.outline, "the game's light and outline kept")
    local button = { inventory = { parent = d1 } }
    page:onMouseOverButton(button)
    truthy(d1.outline, "outlined under the mouse too")
    page.inventory = { parent = a1 }
    page:stopHighlightContainer(d1)
    page:updateContainerHighlight()
    truthy(not d1.lit, "not kept lit by the machines' light once another is chosen")
end)

test("a collapsed window lights nothing", function()
    local page, a1, a2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    page.isCollapsed = true
    page:updateContainerHighlight()
    truthy(not a2.lit, "the machine's other square goes dark with the window")
end)

test("a cabinet with a container on each square is left to the game: the chosen half alone, outlined", function()
    local page, _, _, _, c1, c2 = load()
    page.inventory = { parent = c2 }
    page:updateContainerHighlight()
    truthy(c2.lit and not c1.lit, "the chosen half only")
    truthy(c2.outline, "with the game's outline")
    eq(c2.colour, nil, "in the game's own colour")
    page.inventory = { parent = c1 }
    page:updateContainerHighlight()
    truthy(c1.lit and c1.outline and not c2.lit, "the other half when it is chosen")
    page:onMouseOverButton({ inventory = { parent = c2 } })
    truthy(c2.outline, "the hovered half keeps the game's outline")
end)
