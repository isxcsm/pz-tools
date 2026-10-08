-- The machine window (DESIGN 12: right-click a machine -> maintenance): what the machine is doing, its parts and how
-- worn they are, buttons to put a part in or take it out (timed actions) and to switch it on or off. It reads the
-- machine's state each frame it is open; nothing runs when it is closed.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISContextMenu"
require "ISUI/ISWorldObjectContextMenu"
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/Actions"
local OA = OperationAcorn
local Machines = OA.Machines
local Data = Machines.Data

OAMachineWindow = ISCollapsableWindow:derive("OAMachineWindow")
OAMachineWindow.windows = {}

local FONT = UIFont.Small
local FONT_HGT = getTextManager():getFontHeight(FONT)
local ROW = FONT_HGT + 10
local WIDTH = 400

-- The text of the machine's state.
local function stateText(status)
    if not status.on then return getText("IGUI_OA_Machine_State_off") end
    if status.stopped then
        if status.broken then return getText("IGUI_OA_Machine_State_broken", getText("IGUI_OA_Machine_Slot_" .. status.broken)) end
        return getText("IGUI_OA_Machine_State_missing", getText("IGUI_OA_Machine_Slot_" .. (status.missing or "motor")))
    end
    if status.powered == false then return getText("IGUI_OA_Machine_State_noPower") end
    if status.running then return getText("IGUI_OA_Machine_State_running") end
    local reason = status.reason
    if reason == "noInput" or reason == "outputFull" or reason == "noTank" or reason == "noOwner" then
        return getText("IGUI_OA_Machine_State_" .. reason)
    end
    return getText("IGUI_OA_Machine_State_idle")
end

local function conditionColor(cond)
    if cond < Data.WORN_BELOW then return 1, 0.35, 0.3 end
    if cond < 50 then return 1, 0.85, 0.3 end
    return 0.6, 1, 0.6
end

local function number(x)
    if math.abs(x - math.floor(x)) < 0.005 then return tostring(math.floor(x)) end
    return string.format("%.2f", x)
end

function OAMachineWindow:slots()
    return Data.KINDS[self.kind].slots
end

-- The lines of info above the parts: the status and, for a machine that works, speed, load and noise; the water
-- or the time left for the two with one; and the hint.
local function infoLines(kind)
    local def = Data.KINDS[kind]
    if def.rate then return 5 end
    if kind == "rainStorage" or kind == "lure" then return 3 end
    return 2
end

-- The window's height for a machine kind.
local function heightFor(kind)
    local def = Data.KINDS[kind]
    local y = ISCollapsableWindow.TitleBarHeight() + 8 + infoLines(kind) * ROW
    if #def.slots > 0 then y = y + ROW * (1 + #def.slots) end
    if Data.processes(kind) then y = y + ROW + 6 end
    return y + 12
end

function OAMachineWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    self.partRows = {}
    local y = th + 8 + infoLines(self.kind) * ROW
    if #self:slots() > 0 then
        y = y + ROW
        for _, slot in ipairs(self:slots()) do
            local install = ISButton:new(WIDTH - 170, y, 76, ROW - 4, getText("IGUI_OA_Machine_Install"), self, OAMachineWindow.onInstall)
            install.internal = slot
            install:initialise()
            install:instantiate()
            self:addChild(install)
            local remove = ISButton:new(WIDTH - 90, y, 76, ROW - 4, getText("IGUI_OA_Machine_Remove"), self, OAMachineWindow.onRemove)
            remove.internal = slot
            remove:initialise()
            remove:instantiate()
            self:addChild(remove)
            self.partRows[slot] = { y = y, install = install, remove = remove }
            y = y + ROW
        end
    end
    self.partsEnd = y
    if Data.processes(self.kind) then
        self.switch = ISButton:new(10, y + 6, 120, ROW - 2, "", self, OAMachineWindow.onSwitch)
        self.switch:initialise()
        self.switch:instantiate()
        self:addChild(self.switch)
    end
end

-- Where a character walks to and what it does there.
local function queue(character, object, action)
    local square = object:getSquare()
    if square and luautils.walkAdj(character, square, true) then ISTimedActionQueue.add(action) end
end

function OAMachineWindow:onInstall(button)
    local slot = button.internal
    local object = self.object
    local candidates = Machines.collect(self.character:getInventory(), function(item)
        return Machines.canInstall(object, slot, item) and true or nil
    end, 40)
    local context = ISContextMenu.get(self.playerNum, button:getAbsoluteX(), button:getAbsoluteY() + button:getHeight())
    if #candidates == 0 then
        context:addOption(getText("ContextMenu_OA_Machine_NoPart"), nil, nil)
        return
    end
    for _, entry in ipairs(candidates) do
        local item = entry.item
        local percent = math.floor(item:getCondition() * 100 / math.max(1, item:getConditionMax()) + 0.5)
        local label = string.format("%s (%d%%)", item:getName(), percent)
        local option = context:addOption(label, self, OAMachineWindow.doInstall, slot, item)
        local info = Machines.partOf(item)
        if info then
            local tip = ISWorldObjectContextMenu.addToolTip()
            tip.description = getText("Tooltip_OA_Machine_Part_" .. info.part)
            option.toolTip = tip
        end
    end
end

function OAMachineWindow:doInstall(slot, item)
    local square = self.object:getSquare()
    if not square then return end
    ISInventoryPaneContextMenu.transferIfNeeded(self.character, item)
    queue(self.character, self.object,
        ISOAMachinePartIn:new(self.character, self.machineId, square:getX(), square:getY(), square:getZ(), slot, item))
end

function OAMachineWindow:onRemove(button)
    local square = self.object:getSquare()
    if not square then return end
    queue(self.character, self.object,
        ISOAMachinePartOut:new(self.character, self.machineId, square:getX(), square:getY(), square:getZ(), button.internal))
end

function OAMachineWindow:onSwitch()
    local state = Machines.state(self.object)
    if not state then return end
    OA.Sync.send(self.character, "machineSwitch", { machine = self.machineId, on = state.on == false })
end

function OAMachineWindow:update()
    ISCollapsableWindow.update(self)
    if self:getIsVisible() and (not self.object or self.object:getObjectIndex() == -1) then
        self:removeFromUIManager()
        OAMachineWindow.windows[self.machineId] = nil
        return
    end
    local status = Machines.status(self.object)
    if not status then return end
    if self.switch then
        self.switch:setTitle(getText(status.on and "IGUI_OA_Machine_SwitchOff" or "IGUI_OA_Machine_SwitchOn"))
        self.switch:setWidth(math.max(120, getTextManager():MeasureStringX(FONT, self.switch.title) + 20))
    end
    for slot, row in pairs(self.partRows) do
        row.remove:setEnable(status.parts[slot] ~= nil)
    end
end

function OAMachineWindow:render()
    ISCollapsableWindow.render(self)
    local status = Machines.status(self.object)
    if not status then return end
    local th = self:titleBarHeight()
    local y = th + 8
    local function line(label, value, r, g, b)
        self:drawText(label, 12, y, 0.8, 0.8, 0.8, 1, FONT)
        self:drawText(value, 130, y, r or 1, g or 1, b or 1, 1, FONT)
        y = y + ROW
    end
    line(getText("IGUI_OA_Machine_Status"), stateText(status), status.running and 0.6 or 1, status.running and 1 or 0.9, status.running and 0.6 or 0.6)
    local kind = self.kind
    local def = Data.KINDS[kind]
    if def.rate then
        -- the unit of work differs by kind (weight, clothes, logs, litres): each has its own line
        line(getText("IGUI_OA_Machine_Speed"), getText("IGUI_OA_Machine_SpeedValue_" .. kind, number(status.rate), number(status.speed)))
        line(getText("IGUI_OA_Machine_Load"), number(status.load))
        line(getText("IGUI_OA_Machine_Noise"), tostring(status.noise))
    elseif kind == "rainStorage" then
        line(getText("IGUI_OA_Machine_Water"), getText("IGUI_OA_Machine_WaterValue", number(status.water or 0), number(status.capacity or Data.RAIN_CAPACITY)))
    elseif kind == "lure" then
        line(getText("IGUI_OA_Machine_LureLeft"), status.spent and getText("IGUI_OA_Machine_LureSpent") or getText("IGUI_OA_Machine_Hours", number(status.left or 0)))
    end
    self:drawText(getText("IGUI_OA_Machine_Hint_" .. kind), 12, y, 0.65, 0.65, 0.65, 1, FONT)
    y = y + ROW

    if #self:slots() > 0 then
        self:drawText(getText("IGUI_OA_Machine_Parts"), 12, self.partRows[self:slots()[1]].y - ROW, 1, 1, 1, 1, FONT)
        for _, slot in ipairs(self:slots()) do
            local row = self.partRows[slot]
            self:drawText(getText("IGUI_OA_Machine_Slot_" .. slot), 12, row.y + 3, 0.8, 0.8, 0.8, 1, FONT)
            local part = status.parts[slot]
            if part then
                local r, g, b = conditionColor(part.cond)
                self:drawText(string.format("%s  %d%%", getText("IGUI_OA_Machine_Tier_" .. part.tier), math.floor(part.cond + 0.5)),
                    110, row.y + 3, r, g, b, 1, FONT)
            else
                self:drawText(getText("IGUI_OA_Machine_Empty"), 110, row.y + 3, 0.6, 0.6, 0.6, 1, FONT)
            end
        end
    end
end

function OAMachineWindow:close()
    self:removeFromUIManager()
    OAMachineWindow.windows[self.machineId] = nil
end

function OAMachineWindow:new(x, y, character, object)
    local state = Machines.state(object)
    local o = ISCollapsableWindow:new(x, y, WIDTH, heightFor(state.kind))
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = { r = 0.02, g = 0.02, b = 0.03, a = 0.93 }
    o.character = character
    o.playerNum = character:getPlayerNum()
    o.object = object
    o.machineId = state.id
    o.kind = state.kind
    o:setResizable(false)
    o:setTitle(Machines.name(state.kind))
    return o
end

-- Opens the window of a machine for a character (one window a machine).
function OAMachineWindow.open(character, object)
    local state = Machines.state(object)
    if not state then return end
    local old = OAMachineWindow.windows[state.id]
    if old then old:removeFromUIManager() end
    local window = OAMachineWindow:new(getCore():getScreenWidth() / 2 - WIDTH / 2, 120, character, object)
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    OAMachineWindow.windows[state.id] = window
    return window
end

return OAMachineWindow
