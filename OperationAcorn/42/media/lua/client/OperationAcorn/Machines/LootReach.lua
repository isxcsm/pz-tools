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

local function light(page, object, on)
    if elsewhere[page.player] and elsewhere[page.player][object] then return end
    object:setHighlighted(page.player, on, false)
    if on and getCore():getOptionDoContainerOutline() then
        local colour = getCore():getObjectHighlitedColor()
        object:setOutlineHighlight(page.player, true)
        object:setOutlineHlAttached(page.player, true)
        object:setOutlineHighlightCol(page.player, colour:getR(), colour:getG(), colour:getB(), 1)
    elseif not on then
        object:setOutlineHighlight(page.player, false)
        object:setOutlineHlAttached(page.player, false)
    end
    if on then object:setHighlightColor(page.player, getCore():getObjectHighlitedColor()) end
end

local original = ISInventoryPage.updateContainerHighlight
function ISInventoryPage:updateContainerHighlight()
    original(self)
    -- the container the game lights now (none while the window is collapsed)
    local container = self.coloredInv
    local was = lit[self]
    if (was and was.container) == container then return end
    if was then
        for _, object in ipairs(was.objects) do light(self, object, false) end
    end
    local objects = {}
    -- (kept for any container, so that the next frame asks nothing)
    lit[self] = { container = container, objects = objects }
    local parent = container and container:getParent()
    if not parent or not Machines.isMachineObject(parent) then return end
    local anchor, state = Machines.anchorOf(parent)
    if not anchor or not state then return end
    for _, object in ipairs(squaresOf(anchor, state)) do
        if object ~= parent and object:getContainerCount() == 0 then
            light(self, object, true)
            objects[#objects + 1] = object
        end
    end
end
