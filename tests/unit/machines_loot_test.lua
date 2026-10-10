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
    -- two machines: A of two squares (its bins on each), B of one
    local a1, a2, b1 = object("a1"), object("a2"), object("b1")
    local machineOf = { [a1] = "A", [a2] = "A", [b1] = "B" }
    local squares = { A = { a1, a2 }, B = { b1 } }
    OA.Machines = OA.Machines or {}
    OA.Machines.isMachineObject = function(o) return machineOf[o] ~= nil end
    OA.Machines.anchorOf = function(o) local m = machineOf[o]; return squares[m][1], { machine = m } end
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
    return p, a1, a2, b1
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
    page:onMouseOutButton(button)
    page:updateContainerHighlight()
    truthy(not b1.lit, "nothing left lit in the hover colour")
    truthy(a1.lit and a2.lit, "the chosen machine keeps its light")
end)

test("a square the game switches off is lit again at the next update", function()
    local page, a1, a2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    page:stopHighlightContainer(a2)
    truthy(not a2.lit)
    page:updateContainerHighlight()
    truthy(a2.lit); eq(a2.colour, CHOSEN)
end)

test("a collapsed window lights nothing", function()
    local page, a1, a2 = load()
    page.inventory = { parent = a1 }
    page:updateContainerHighlight()
    page.isCollapsed = true
    page:updateContainerHighlight()
    truthy(not a2.lit, "the machine's other square goes dark with the window")
end)
