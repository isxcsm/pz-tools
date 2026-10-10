-- A machine of several squares is one thing in the loot window. Its containers are listed when the player stands by
-- any of its squares (the game lists the containers of the squares around the player only, and a machine's are on one
-- or two of them), and when one of them is chosen every square of the machine that holds no container of its own is
-- lit with it (a refiner's four, not only the one its containers are on). Both are done when the window changes, not
-- each frame: the list when the game refreshes it, the light when the chosen container changes.
require "ISUI/ISInventoryPage"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines

-- The objects of a machine's squares: the anchor and its parts (those on loaded squares).
local function squaresOf(anchor, state)
    local list = { anchor }
    for _, part in ipairs(Machines.partsOf(state)) do list[#list + 1] = part.object end
    return list
end

-- Lists the containers of the machines by the player that the game did not (their squares are out of its reach).
local function onRefresh(page, stage)
    if stage ~= "beforeFloor" or page.onCharacter then return end
    local playerObj = getSpecificPlayer(page.player)
    local here = playerObj and playerObj:getCurrentSquare()
    if not here then return end
    local listed = {}
    for _, button in ipairs(page.backpacks) do listed[button.inventory] = true end
    local seen = {}
    local cx, cy, cz = here:getX(), here:getY(), here:getZ()
    for dy = -1, 1 do
        for dx = -1, 1 do
            local square = getCell():getGridSquare(cx + dx, cy + dy, cz)
            -- as the game: not through walls
            if square and (square == here or here:canReachTo(square)) then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if Machines.isMachineObject(object) then
                        local anchor, state = Machines.anchorOf(object)
                        if anchor and state and not seen[anchor] then
                            seen[anchor] = true
                            for _, holder in ipairs(squaresOf(anchor, state)) do
                                for n = 0, holder:getContainerCount() - 1 do
                                    local container = holder:getContainerByIndex(n)
                                    if not listed[container] then
                                        listed[container] = true
                                        local title = getTextOrNull("IGUI_ContainerTitle_" .. container:getType()) or container:getType()
                                        page:addContainerButton(container, nil, title, title)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
Events.OnRefreshInventoryWindowContainers.Add(onRefresh)

-- page -> { container = the one lit for, objects = the squares lit with it }
local lit = setmetatable({}, { __mode = "k" })

-- player number -> the objects other code lights (the game keeps its own record local to ISInventoryPage, given to it
-- through OnObjectHighlighted; the same is kept here): those are left as they are, as the game leaves them
local elsewhere = {}
local onHighlighted = ISInventoryPage.OnObjectHighlighted
function ISInventoryPage.OnObjectHighlighted(playerNum, object, isHighlighted)
    elsewhere[playerNum] = elsewhere[playerNum] or setmetatable({}, { __mode = "k" })
    elsewhere[playerNum][object] = isHighlighted or nil
    return onHighlighted(playerNum, object, isHighlighted)
end

-- A machine is lit as one thing: every square in the same colour and without the outline. The game outlines each object
-- on its own, and the outline of a square behind is drawn over the square in front, so outlined squares showed their
-- seams and the one holding the container looked lit apart from the rest (seen in game, a refiner's four).
local function light(page, object, on, colour)
    if elsewhere[page.player] and elsewhere[page.player][object] then return end
    object:setHighlighted(page.player, on, false)
    object:setOutlineHighlight(page.player, false)
    object:setOutlineHlAttached(page.player, false)
    if on then object:setHighlightColor(page.player, colour) end
end

-- The squares of the machine an object belongs to, or nil when it is not a machine's.
local function machineSquares(object)
    if not object or not Machines.isMachineObject(object) then return nil end
    local anchor, state = Machines.anchorOf(object)
    if not anchor or not state then return nil end
    return squaresOf(anchor, state)
end

-- page -> { object = the square the mouse is over a button of, objects = its machine's squares, lit in the hover colour }
local hovered = setmetatable({}, { __mode = "k" })

local function isLitFor(page, object)
    local was = lit[page]
    if not was then return false end
    for _, o in ipairs(was.objects) do
        if o == object then return true end
    end
    return false
end

local function endHover(page)
    local hover = hovered[page]
    if not hover then return end
    hovered[page] = nil
    for _, object in ipairs(hover.objects) do
        if not isLitFor(page, object) then light(page, object, false) end
    end
end

local original = ISInventoryPage.updateContainerHighlight
function ISInventoryPage:updateContainerHighlight()
    original(self)
    -- the container the game lights now (none while the window is collapsed)
    local container = self.coloredInv
    local was = lit[self]
    if (was and was.container) == container then
        -- the game outlines the chosen container's object again each time; a machine's stays without it
        if was and was.parent then was.parent:setOutlineHighlight(self.player, false) end
        return
    end
    if was then
        for _, object in ipairs(was.objects) do light(self, object, false) end
    end
    local objects = {}
    -- (kept for any container, so that the next frame asks nothing)
    lit[self] = { container = container, objects = objects }
    local parent = container and container:getParent()
    local squares = machineSquares(parent)
    if not squares then return end
    lit[self].parent = parent
    local colour = getCore():getObjectHighlitedColor()
    for _, object in ipairs(squares) do
        light(self, object, true, colour)
        objects[#objects + 1] = object
    end
end

-- The mouse over a container's button: the game outlines that container's object in the world; a machine's squares are
-- all lit instead, in the same colour (the chosen machine keeps its own light).
local overButton = ISInventoryPage.onMouseOverButton
function ISInventoryPage:onMouseOverButton(button, x, y)
    overButton(self, button, x, y)
    local object = self.mouseOverColoredContainer
    local hover = hovered[self]
    if hover and hover.object ~= object then endHover(self) end
    if not object or hovered[self] or self.isCollapsed then return end
    local squares = machineSquares(object)
    if not squares then return end
    local colour = getCore():getWorldItemHighlightColor()
    local objects = {}
    for _, o in ipairs(squares) do
        if not isLitFor(self, o) then
            light(self, o, true, colour)
            objects[#objects + 1] = o
        end
    end
    hovered[self] = { object = object, objects = objects }
end

local stopHighlight = ISInventoryPage.stopHighlightContainer
function ISInventoryPage:stopHighlightContainer(container)
    stopHighlight(self, container)
    local hover = hovered[self]
    if hover and hover.object == container then endHover(self) end
end
