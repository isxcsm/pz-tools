-- A machine of several squares is one thing in the loot window. Its containers are listed when the player stands by
-- any of its squares (the game lists the containers of the squares around the player only, and a machine's are on one
-- or two of them), and when one of them is chosen or under the mouse every square of the machine is lit with it, as the
-- game lights a container's object (a refiner's four, not only the one its containers are on; a locker's two halves).
-- Both are done when the window changes, not each frame: the list when the game refreshes it, the light when the chosen
-- container changes.
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

-- player number -> the objects other code lights (the game keeps its own record local to ISInventoryPage, given to it
-- through OnObjectHighlighted; the same is kept here): those are left as they are, as the game leaves them
local elsewhere = {}
local onHighlighted = ISInventoryPage.OnObjectHighlighted
function ISInventoryPage.OnObjectHighlighted(playerNum, object, isHighlighted)
    elsewhere[playerNum] = elsewhere[playerNum] or setmetatable({}, { __mode = "k" })
    elsewhere[playerNum][object] = isHighlighted or nil
    return onHighlighted(playerNum, object, isHighlighted)
end

-- A machine is lit as one thing, every square as the game lights a container's object: the chosen one filled and
-- outlined in the chosen colour, the one under the mouse outlined in the hover colour (the outline only with the game's
-- container outline option on). The game outlines the silhouettes of one colour together, so the squares outlined alike
-- are one outline with no seams between them (the API keeps a colour's objects together in the pass). kind: "chosen",
-- "hover", or nil for none.
local function light(page, object, kind)
    local player = page.player
    if elsewhere[player] and elsewhere[player][object] then return end
    local core = getCore()
    object:setHighlighted(player, kind == "chosen", false)
    if kind == "chosen" then object:setHighlightColor(player, core:getObjectHighlitedColor()) end
    local outlined = kind ~= nil and core:getOptionDoContainerOutline()
    object:setOutlineHighlight(player, outlined)
    object:setOutlineHlAttached(player, outlined)
    if outlined then
        local colour = kind == "chosen" and core:getObjectHighlitedColor() or core:getWorldItemHighlightColor()
        object:setOutlineHighlightCol(player, colour:getR(), colour:getG(), colour:getB(), 1)
    end
end

-- The squares lit with a container of the machine an object belongs to: the whole machine; nil when it is not a
-- machine's.
local function machineSquares(object)
    if not object or not Machines.isMachineObject(object) then return nil end
    local anchor, state = Machines.anchorOf(object)
    if not anchor or not state then return nil end
    return squaresOf(anchor, state)
end

-- What a page lights of the machines, as one state: the machine of the chosen container in the chosen colour, the
-- machine of the button under the mouse in the hover colour (the chosen one keeps its own). The game switches single
-- objects on and off from several places (the mouse over and out of a button, choosing, its update each frame), and
-- following each of them left squares lit or dark (seen in game: a square left lit in the hover colour after the mouse
-- went, the light jumping to one square when going between a machine's two bins). So the state is worked out from what
-- the page shows, and when it changes, or when the game has switched one of its squares, every square is set again.
-- page -> { chosen = container, hover = container, collapsed, objects = { [object] = "chosen" | "hover" }, dirty }
local applied = setmetatable({}, { __mode = "k" })

local function hoverContainer(page)
    if page.isCollapsed then return nil end
    local button = page.mouseOverButton
    return button and button.inventory or nil
end

local function reconcile(page, chosen, hover)
    local was = applied[page]
    local objects = {}
    local chosenSquares = (not page.isCollapsed) and machineSquares(chosen and page:getContainerParent(chosen)) or nil
    if chosenSquares then
        for _, o in ipairs(chosenSquares) do objects[o] = "chosen" end
    end
    local hoverSquares = machineSquares(hover and page:getContainerParent(hover))
    if hoverSquares then
        for _, o in ipairs(hoverSquares) do objects[o] = objects[o] or "hover" end
    end
    if was then
        for o in pairs(was.objects) do
            if not objects[o] then light(page, o, nil) end
        end
    end
    for o, kind in pairs(objects) do light(page, o, kind) end
    applied[page] = { chosen = chosen, hover = hover, collapsed = page.isCollapsed, objects = objects }
end

-- Each frame the game lights the chosen container's object again, as it is lit here: compared, and set again only
-- when something changed.
local original = ISInventoryPage.updateContainerHighlight

-- (after the original; what it returned is passed on, as a frame function: no table made)
local function reconciled(self, ...)
    local chosen = self.coloredInv
    local hover = hoverContainer(self)
    local was = applied[self]
    if not (was and not was.dirty and was.chosen == chosen and was.hover == hover and was.collapsed == self.isCollapsed) then
        reconcile(self, chosen, hover)
    end
    return ...
end

function ISInventoryPage:updateContainerHighlight(...)
    return reconciled(self, original(self, ...))
end

-- The mouse over a container's button: the game outlines that object at once in the hover colour; a square of a
-- machine lit as chosen gets its own light back (the next update lights the machine under the mouse).
local overButton = ISInventoryPage.onMouseOverButton
local function overLit(self, button, ...)
    local object = button and button.inventory and self:getContainerParent(button.inventory)
    local was = applied[self]
    local kind = object and was and was.objects[object]
    if kind then light(self, object, kind) end
    return ...
end

function ISInventoryPage:onMouseOverButton(button, ...)
    return overLit(self, button, overButton(self, button, ...))
end

-- The game switches an object off as the mouse leaves it or another container is chosen (the mouse leaving one bin
-- of the chosen machine for another switched that square off). When it is one of a machine's squares the page lights,
-- it is lit again at once as it was, so that no frame shows it dark (seen in game as a flicker), and everything is
-- worked out again at the next update (which turns it off if it should be: one frame lit too long, never one dark).
local stopHighlight = ISInventoryPage.stopHighlightContainer
local function stopLit(self, container, ...)
    local was = applied[self]
    local kind = was and was.objects[container]
    if kind then
        light(self, container, kind)
        was.dirty = true
    end
    return ...
end

function ISInventoryPage:stopHighlightContainer(container, ...)
    return stopLit(self, container, stopHighlight(self, container, ...))
end
