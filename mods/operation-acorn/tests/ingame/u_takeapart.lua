-- The user's path for taking a utility panel apart where it stands (BU ContextMenu: "제어반 해체" on an active box
-- and on a bare one): the world menu's option, its cost, the confirm (the UI kit's), and the action done.
-- Stage 1 (this file with TA_STAGE nil): finds an active box and a bare one, gives the tools, stands by the active
-- one, opens its world menu and selects the option: the confirm is left open for a picture.
-- Stage 2 (TA_STAGE = 2): presses yes and returns; stage 3 (TA_STAGE = 3) checks the box is gone and the parts came,
-- then does the same on the bare box and leaves its confirm open.
local BU = BuildingUtilities
local p = getPlayer()
local out = {}
local function say(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end out[#out + 1] = table.concat(t, " ") end
local function done() print("TAKEAPART " .. table.concat(out, " ; ")) end

local function boards()
    return p:getInventory():getCountTypeRecurse("BuildingUtilities.ControlBoard")
end

-- On a free square beside the box with no wall between (the walk to it then stays a step), or east of it when its
-- square is not loaded yet.
local function standBy(x, y, z)
    local sq = getCell():getGridSquare(x, y, z)
    local tx, ty = x + 1, y
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local n = sq and getCell():getGridSquare(x + d[1], y + d[2], z)
        if n and n:isFree(false) and not sq:isBlockedTo(n) then tx, ty = x + d[1], y + d[2] break end
    end
    p:setX(tx + 0.5) p:setY(ty + 0.5) p:setZ(z)
    p:setLastX(tx + 0.5) p:setLastY(ty + 0.5)
end

-- the option of the world menu on an object
local function openMenuOn(object)
    local menu = ISWorldObjectContextMenu.createMenu(0, { object }, getMouseX(), getMouseY(), false)
    local found
    for _, o in ipairs(menu and menu.options or {}) do
        if o and o.name == getText("ContextMenu_BU_TakeApart") then found = o end
    end
    return menu, found
end

local function selectOption(menu, option)
    say("option", option.name, "notAvailable", tostring(option.notAvailable == true),
        "tip", option.toolTip and option.toolTip.description or "-")
    menu:setVisible(false)
    option.onSelect(option.target, option.param1, option.param2, option.param3, option.param4, option.param5,
        option.param6)
    say("confirm open", tostring(PZUIConfirm.open ~= nil), PZUIConfirm.open and table.concat(PZUIConfirm.open.lines, "/") or "")
end

local function findBare()
    local cell = getCell()
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    for r = 0, 60 do
        for x = px - r, px + r do
            for y = py - r, py + r do
                if math.abs(x - px) == r or math.abs(y - py) == r then
                    local sq = cell:getGridSquare(x, y, 0)
                    local o = sq and BU.Panels.bareOn(sq)
                    if o then return o end
                end
            end
        end
    end
end

TA = TA or {}
if not TA_STAGE then
    local inv = p:getInventory()
    if inv:getCountTypeRecurse("Base.Screwdriver") == 0 then inv:AddItem("Base.Screwdriver") end
    if inv:getCountTypeRecurse("Base.Pliers") == 0 then inv:AddItem("Base.Pliers") end
    local panel
    for _, each in pairs(BU.Store.panels()) do panel = each break end
    if not panel then say("no active box") return done() end
    TA.panel = { id = panel.id, x = panel.x, y = panel.y, z = panel.z, tier = panel.tier or 1,
        lines = #BU.Links.of(panel) }
    TA.boards = boards()
    say("active box", panel.id, panel.x, panel.y, panel.z, "tier", panel.tier or 1, "lines", TA.panel.lines,
        "boards before", TA.boards)
    standBy(panel.x, panel.y, panel.z)
    local object = BU.Panels.object(panel)
    if not object then say("no object (not loaded?)") return done() end
    local menu, option = openMenuOn(object)
    if not option then say("NO OPTION on the active box") return done() end
    selectOption(menu, option)
    return done()
elseif TA_STAGE == 2 then
    PZUIConfirm.open:onYesButton()
    say("yes pressed; queue", #(ISTimedActionQueue.getTimedActionQueue(p).queue or {}))
    return done()
elseif TA_STAGE == 3 then
    local a = TA.panel
    say("active gone from store", tostring(BU.Store.get(a.id) == nil), "bare left there",
        tostring(BU.Panels.bareOn(getCell():getGridSquare(a.x, a.y, a.z)) ~= nil),
        "boards", TA.boards, "->", boards(), "expected +", BU.Costs.boardsIn(a.tier),
        "held", tostring(p:getPrimaryHandItem() and p:getPrimaryHandItem():getFullType()))
    local bare = findBare()
    if not bare then say("no bare box near") return done() end
    local sq = bare:getSquare()
    TA.bare = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
    TA.boards = boards()
    say("bare box", sq:getX(), sq:getY(), sq:getZ())
    standBy(sq:getX(), sq:getY(), sq:getZ())
    local menu, option = openMenuOn(bare)
    if not option then say("NO OPTION on the bare box") return done() end
    selectOption(menu, option)
    return done()
elseif TA_STAGE == 5 then
    -- only the confirm of the bare box nearest, left open (its text: the question and what comes back)
    local bare = findBare()
    if not bare then say("no bare box near") return done() end
    local sq = bare:getSquare()
    standBy(sq:getX(), sq:getY(), sq:getZ())
    local menu, option = openMenuOn(bare)
    if not option then say("NO OPTION on the bare box") return done() end
    selectOption(menu, option)
    return done()
elseif TA_STAGE == 4 then
    local b = TA.bare
    say("bare gone", tostring(BU.Panels.bareOn(getCell():getGridSquare(b.x, b.y, b.z)) == nil),
        "boards", TA.boards, "->", boards())
    return done()
end
