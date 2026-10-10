-- The machine window (DESIGN 12: right-click a machine -> maintenance), drawn as research-team equipment in the field
-- terminal's palette (mockups/machines/a-equipment.html): what the machine does and what to do next, its jobs and bins,
-- its performance, its parts, the rain storage's water or the lure's hours, and the buttons for each (the switch, a
-- bin opened in the loot window, a part put in, swapped or taken out with a timed action, the water poured or moved,
-- the lure taken back or cleared).
-- The window is the game's and in pixels; its body is ours, in design units and our faces (Trade/UI.lua), and grows
-- with the scale. A body taller than the screen allows (the saw's three parts at 900p) scrolls in a window kept to
-- nine tenths of the screen.
-- An open window reads the machine a few times a second (WindowModel.read: the status once), lays it out again only
-- when what it shows changed (WindowLayout), and each frame only paints that list. Nothing runs when it is closed.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISInventoryPage"
require "ISUI/ISInventoryPaneContextMenu"
require "ISUI/ISWorldObjectContextMenu"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Trade/StatusDraw"
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/Actions"
require "OperationAcorn/Machines/WindowModel"
require "OperationAcorn/Machines/WindowLayout"
local OA = OperationAcorn
local UI, Draw = OA.Trade.UI, OA.Trade.Draw
local Machines = OA.Machines
local Data, Logic = Machines.Data, Machines.Logic
local Model, Layout = Machines.WindowModel, Machines.WindowLayout

OAMachineWindow = ISCollapsableWindow:derive("OAMachineWindow")
OAMachineWindow.windows = {}

-- How often (real ms) an open window reads its machine; the least time between two asks to work (a job is due); how
-- seldom an idle machine with something in it is asked (as the loot window's watch, Watch.lua).
OAMachineWindow.READ_MS = 250
OAMachineWindow.ASK_MS = 400
OAMachineWindow.IDLE_ASK_MS = 3000
-- How long (real ms) the loot window keeps a bin chosen after [열기], while it lists the bins of the new place.
OAMachineWindow.SELECT_MS = 1500
-- How often the window looks whether the character is still near the machine (ms), and how near (squares from the
-- nearest square of its footprint, so that a large machine counts from whichever side the character stands at).
OAMachineWindow.NEAR_MS = 500
OAMachineWindow.REACH = 3

-- Whether a character at px, py is within `reach` squares of a footprint of w by h squares from x, y.
function OAMachineWindow.within(px, py, x, y, w, h, reach)
    local dx = math.max(x - px, 0, px - (x + w))
    local dy = math.max(y - py, 0, py - (y + h))
    return dx * dx + dy * dy <= reach * reach
end

-- The most of the screen's height the window takes; a wheel step of a body that scrolls, and its bar's width.
OAMachineWindow.SCREEN_SHARE = 0.9
OAMachineWindow.WHEEL = 36
OAMachineWindow.BAR = 4

-- The hover of a button or a card, and the tooltip of what the mouse is over (as the status screens'). `scroll`: how
-- far the list is scrolled up in the element (design units).
local function paintHover(el, L, p, scroll)
    if not (L and el:isMouseOver()) then return end
    scroll = scroll or 0
    local mx, my = el:getMouseX(), el:getMouseY()
    local hit = Draw.hitAt(L, mx, my + scroll)
    if not hit then return end
    if hit.button and hit.enabled then
        el:drawRect(hit.x + 1, hit.y - scroll + 1, hit.w - 2, hit.h - 2, 0.10, p.sel[1], p.sel[2], p.sel[3])
    elseif hit.hover then
        el:drawRect(hit.x + 1, hit.y - scroll + 1, hit.w - 2, hit.h - 2, 0.08, p.sel[1], p.sel[2], p.sel[3])
    end
    if hit.tip then Draw.paintTip(el, p, hit.tip, mx + 12, my + 18) end
end

-- The body ------------------------------------------------------------------------------------------------------------

OAMachineBody = ISPanel:derive("OAMachineBody")

function OAMachineBody:new(x, y, width, height, window)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.window = window
    o.background = false
    o.contentH, o.scroll = height, 0
    return o
end

-- How far the content can scroll (0 when it all shows), and the scroll kept inside it.
function OAMachineBody:maxScroll()
    return math.max(0, self.contentH - self.height)
end

function OAMachineBody:setScroll(v)
    self.scroll = math.max(0, math.min(self:maxScroll(), v))
end

function OAMachineBody:prerender()
    if self.scroll == 0 and self:maxScroll() == 0 then return Draw.paint(self, self.list) end
    self:setStencilRect(0, 0, self.width, self.height)
    Draw.paint(self, self.list, -UI.px(self.scroll))
    self:clearStencilRect()
    -- where the part on show is: a thin bar on the right
    local p, h = self.window.palette, self.height
    local th = math.max(16, math.floor(h * h / self.contentH))
    local ty = math.floor((h - th) * self.scroll / self:maxScroll())
    UI.fill(self, self.width - OAMachineWindow.BAR - 1, ty, OAMachineWindow.BAR, th, p.border, 0.9)
end

function OAMachineBody:render()
    paintHover(self, self.list, self.window.palette, self.scroll)
end

function OAMachineBody:onMouseDown(x, y)
    local hit = Draw.hitAt(self.list, x, y + self.scroll)
    if hit and hit.id and hit.enabled then self.window:onHit(hit) end
    return true
end

function OAMachineBody:onMouseWheel(del)
    if self:maxScroll() <= 0 then return false end
    self:setScroll(self.scroll + del * OAMachineWindow.WHEEL)
    return true
end

UI.scaled(OAMachineBody, ISPanel)

-- The part picker: the parts the character carries that fit a slot, under the button that opened it (or above it
-- near the bottom of the screen). A click on a row puts that part in; a click anywhere else closes it.
OAMachinePicker = ISPanel:derive("OAMachinePicker")

function OAMachinePicker:new(x, y, window, slot, entries, pick)
    local L = Draw.list(window.palette)
    local h = Layout.picker(L, pick, Layout.PICKER_WIDTH)
    Draw.bake(L)
    local o = ISPanel:new(x, y, Layout.PICKER_WIDTH, h)
    setmetatable(o, self)
    self.__index = self
    o.window, o.slot, o.entries, o.list = window, slot, entries, L
    o.background = false
    return o
end

function OAMachinePicker:prerender()
    Draw.paint(self, self.list)
end

function OAMachinePicker:render()
    paintHover(self, self.list, self.window.palette)
end

function OAMachinePicker:onMouseDown(x, y)
    local hit = Draw.hitAt(self.list, x, y)
    if hit and hit.id == "pick" then
        local entry = self.entries[hit.index]
        if entry then self.window:doInstall(self.slot, entry.item) end
    end
    self:close()
    return true
end

function OAMachinePicker:onMouseDownOutside()
    self:close()
end

function OAMachinePicker:close()
    if self.window.picker == self then self.window.picker = nil end
    self:setVisible(false)
    self:removeFromUIManager()
end

UI.scaled(OAMachinePicker, ISPanel)

-- The window ------------------------------------------------------------------------------------------------------------

function OAMachineWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local p = self.palette
    -- Only the close box stays of the vanilla title bar, drawn in the palette and our face (as the terminal's).
    for _, b in ipairs({ self.pinButton, self.collapseButton, self.infoButton }) do
        if b then b:setVisible(false) end
    end
    UI.closeBox(self, p)
    self.body = OAMachineBody:new(0, UI.dp(self:titleBarHeight()), Layout.WIDTH, 100, self)
    self.body:initialise()
    self:addChild(self.body)
    self:refresh(true)
end

-- The title bar is as high as our Small face (the game's would follow its own font).
function OAMachineWindow:titleBarHeight() return UI.titleBarHeight() end
function OAMachineWindow:resizeWidgetHeight() return UI.resizeWidgetHeight() end

-- Reads the machine and lays the window out again when what it shows changed (or when `force`). The window takes the
-- body's height, up to its share of the screen (the body then scrolls).
function OAMachineWindow:refresh(force)
    local input = Model.read(self.object)
    if not input then return end
    local model = Model.build(input)
    self.model = model
    local key = Model.key(model)
    if not force and key == self.key then return end
    self.key = key
    local L = Draw.list(self.palette)
    local h = Layout.build(L, model, Layout.WIDTH)
    Draw.bake(L)
    local body = self.body
    body.list, body.contentH = L, h
    local th = self:titleBarHeight()
    local shown = math.min(h, UI.dp(math.floor(getCore():getScreenHeight() * OAMachineWindow.SCREEN_SHARE) - th))
    if shown ~= body.height then
        body:setHeight(shown)
        self:setHeight(th + UI.px(shown))
    end
    body:setScroll(body.scroll)
end

-- A due job (or something new in an idle machine): the machine is asked to work now, not at its next ten-minute step.
function OAMachineWindow:askWork(now)
    local model = self.model
    if not model then return end
    local want = model.due or (model.idleWithInput and OA.due(self.due, "idle", now, OAMachineWindow.IDLE_ASK_MS))
    if want and OA.due(self.due, "ask", now, OAMachineWindow.ASK_MS) then
        OA.Sync.send(self.character, "machineWork", { machine = self.machineId })
    end
end

function OAMachineWindow:update()
    ISCollapsableWindow.update(self)
    -- another window worked the scale or the faces out again: this one was made with the old ones
    if self.era ~= UI.era then return self:close() end
    if not self.object or self.object:getObjectIndex() == -1 or self.character:isDead() then return self:close() end
    local now = getTimestampMs()
    -- walked away from the machine: the window goes
    if OA.due(self.due, "near", now, OAMachineWindow.NEAR_MS) then
        local square = self.object:getSquare()
        if not square then return self:close() end
        local w, h = Machines.footprint(self.kind, self.dir)
        if not OAMachineWindow.within(self.character:getX(), self.character:getY(), square:getX(), square:getY(), w, h,
            OAMachineWindow.REACH) then
            return self:close()
        end
    end
    if OA.due(self.due, "read", now, OAMachineWindow.READ_MS) then
        self:refresh()
        self:askWork(now)
    end
end

function OAMachineWindow:prerender()
    local p = self.palette
    local th = self:titleBarHeight()
    UI.fill(self, 0, 0, self.width, self.height, p.bg, p.bgAlpha)
    UI.fill(self, 0, 0, self.width, th, p.title)
    UI.windowTitle(self, self.title, p.text)
    UI.fill(self, 0, th - 1, self.width, 1, p.border)
end

function OAMachineWindow:render()
    UI.frame(self, 0, 0, self.width, self.height, self.palette.border)
end

function OAMachineWindow:close()
    if self.picker then self.picker:close() end
    self:setVisible(false)
    self:removeFromUIManager()
    if OAMachineWindow.windows[self.machineId] == self then OAMachineWindow.windows[self.machineId] = nil end
end

-- The buttons -----------------------------------------------------------------------------------------------------------

-- Walks next to a square, then does the action.
local function queueAt(character, square, action)
    if square and luautils.walkAdj(character, square, true) then ISTimedActionQueue.add(action) end
end

function OAMachineWindow:onHit(hit)
    local id = hit.id
    if id == "switch" then
        local state = Machines.state(self.object)
        OA.Sync.send(self.character, "machineSwitch", { machine = self.machineId, on = state and state.on == false })
        self.due.read = nil
    elseif id == "open" then
        self:openBox(hit.role)
    elseif id == "part" then
        if hit.action == "remove" then self:doRemove(hit.slot) else self:openPicker(hit) end
    elseif id == "rain:transfer" or id == "rain:empty" then
        local fluid = self.object.getFluidContainer and self.object:getFluidContainer()
        if not fluid then return end
        if id == "rain:transfer" then ISWorldObjectContextMenu.onFluidTransfer(self.playerNum, fluid)
        else ISWorldObjectContextMenu.onFluidEmpty(self.playerNum, fluid) end
    elseif id == "lure:take" or id == "lure:clear" then
        local square = self.object:getSquare()
        if not square then return end
        local class = id == "lure:take" and ISOAMachineTakeLure or ISOAMachinePickUp
        queueAt(self.character, square, class:new(self.character, self.machineId, square:getX(), square:getY(), square:getZ()))
    end
end

-- The loot window chooses a bin (as the game's own actions do it, ISOpenVehicleDoor), shown if it was collapsed.
local function showBox(character, container)
    local loot = getPlayerLoot(character:getPlayerNum())
    if not loot then return end
    loot:setForceSelectedContainer(container, OAMachineWindow.SELECT_MS)
    ISInventoryPage.dirtyUI()
    loot:setVisible(true)
    if loot.isCollapsed then
        loot.isCollapsed = false
        loot:clearMaxDrawHeight()
        loot.collapseCounter = -30
    end
end

-- [열기]: walks to the square the bin is on, then the loot window shows it.
function OAMachineWindow:openBox(role)
    local container = Machines.container(self.object, role)
    if not container then return end
    local holder = container:getParent() or self.object
    local square = holder:getSquare()
    if not square then return end
    if luautils.walkAdj(self.character, square, true) then
        ISTimedActionQueue.queueActions(self.character, showBox, container)
    end
end

local TIER_RANK = { old = 1, normal = 2, modern = 3 }

-- The parts the character carries that fit a slot: looked for now, as the player pressed the button. Best first.
function OAMachineWindow:candidates(slot)
    local object = self.object
    -- oa-scan: ok (the player pressed the button: once)
    local found = Machines.collect(self.character:getInventory(), function(item)
        return Machines.canInstall(object, slot, item) and Machines.partOf(item) or nil
    end, 40)
    local function condition(item)
        return item:getCondition() * Data.CONDITION_MAX / math.max(1, item:getConditionMax())
    end
    for _, entry in ipairs(found) do entry.cond = condition(entry.item) end
    table.sort(found, function(a, b)
        local ra, rb = TIER_RANK[a.data.tier] or 0, TIER_RANK[b.data.tier] or 0
        if ra ~= rb then return ra > rb end
        return a.cond > b.cond
    end)
    return found
end

function OAMachineWindow:openPicker(hit)
    if self.picker then self.picker:close() end
    local slot = hit.slot
    local entries = self:candidates(slot)
    local rows = {}
    for i, entry in ipairs(entries) do
        local def = Logic.partDef(self.kind, slot, entry.data.tier)
        local cond = entry.cond
        rows[i] = { icon = entry.item:getFullType(), name = entry.item:getName(), cond = math.floor(cond + 0.5) .. "%",
            tone = cond <= 0 and "bad" or (cond < Data.WORN_BELOW and "warn" or "good"),
            effect = def and Model.effect(entry.data.part, def) or "" }
    end
    local pick = { title = getText("IGUI_OA_Machine_Pick_Title", getText("IGUI_OA_Machine_Slot_" .. slot)),
        none = getText("ContextMenu_OA_Machine_NoPart"), rows = rows }
    -- under the button, inside the screen (design units)
    local bx = UI.dp(self.body:getAbsoluteX()) + hit.x
    local by = UI.dp(self.body:getAbsoluteY()) + hit.y - self.body.scroll
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    local picker = OAMachinePicker:new(0, 0, self, slot, entries, pick)
    local x = math.max(0, math.min(bx + hit.w - Layout.PICKER_WIDTH, screenW - Layout.PICKER_WIDTH))
    local y = by + hit.h + 2
    if y + picker.height > screenH then y = math.max(0, by - picker.height - 2) end
    picker.x, picker.y = x, y
    picker:initialise()
    picker:addToUIManager()
    picker:setVisible(true)
    self.picker = picker
end

-- Puts a part in (the one in the slot comes out to the character's bag).
function OAMachineWindow:doInstall(slot, item)
    local square = self.object:getSquare()
    if not square then return end
    ISInventoryPaneContextMenu.transferIfNeeded(self.character, item)
    queueAt(self.character, square,
        ISOAMachinePartIn:new(self.character, self.machineId, square:getX(), square:getY(), square:getZ(), slot, item))
end

function OAMachineWindow:doRemove(slot)
    local square = self.object:getSquare()
    if not square then return end
    queueAt(self.character, square,
        ISOAMachinePartOut:new(self.character, self.machineId, square:getX(), square:getY(), square:getZ(), slot))
end

-- Opening ---------------------------------------------------------------------------------------------------------------

function OAMachineWindow:new(x, y, character, object)
    local state = Machines.state(object)
    local o = ISCollapsableWindow:new(x, y, UI.px(Layout.WIDTH), 200)
    setmetatable(o, self)
    self.__index = self
    o.palette = UI.palette("field")
    o.era = UI.era
    o.due = {}
    o.character = character
    o.playerNum = character:getPlayerNum()
    o.object = object
    o.machineId = state.id
    o.kind = state.kind
    o.dir = state.dir
    o.title = Machines.name(state.kind)
    o:setResizable(false)
    return o
end

-- Opens the window of a machine for a character (one window a machine), in the middle of the screen.
function OAMachineWindow.open(character, object)
    local state = Machines.state(object)
    if not state then return end
    local old = OAMachineWindow.windows[state.id]
    if old then old:close() end
    UI.refreshScale()
    local width = UI.px(Layout.WIDTH)
    local window = OAMachineWindow:new((getCore():getScreenWidth() - width) / 2, 0, character, object)
    window:initialise()
    window:addToUIManager()
    window:setY(math.max(0, (getCore():getScreenHeight() - window.height) / 2))
    window:setVisible(true)
    OAMachineWindow.windows[state.id] = window
    return window
end

-- A machine was switched (the server answers): its window reads it again now.
OA.Sync.listen("machines", function(_, detail)
    local window = type(detail) == "table" and OAMachineWindow.windows[detail.machine]
    if window then window:refresh() end
end)

return OAMachineWindow
