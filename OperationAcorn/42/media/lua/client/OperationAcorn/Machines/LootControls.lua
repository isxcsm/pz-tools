-- The on/off button of a working machine in the loot window, where the game puts the oven's: on the row of buttons
-- under a container of the machine (its in- or output), on the right with the buttons that act on the object.
require "ISUI/LootWindow/ISLootWindowContainerControls"
require "ISUI/LootWindow/ISLootWindowObjectControlHandler"
require "OperationAcorn/Sync"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines

ISLootWindowObjectControlHandler_OAMachineToggle =
    ISLootWindowObjectControlHandler:derive("ISLootWindowObjectControlHandler_OAMachineToggle")
local Handler = ISLootWindowObjectControlHandler_OAMachineToggle

-- The machine's state when the object is a working machine's tile, else nil.
local function stateOf(object)
    if not object or not Machines.isMachineObject(object) then return nil end
    local state = Machines.state(Machines.anchorOf(object))
    if not state or not Machines.Data.processes(state.kind) then return nil end
    return state
end

local function title(state)
    return getText(state.on == false and "ContextMenu_Turn_On" or "ContextMenu_Turn_Off")
end

function Handler:shouldBeVisible()
    return stateOf(self.object) ~= nil
end

-- Whether the button can be pressed now: switching off always; switching on only with the parts it needs (else why).
local function usable(object, state)
    if state.on ~= false then return true end
    return Machines.canSwitchOn(Machines.anchorOf(object))
end

function Handler:getControl()
    local state = stateOf(self.object)
    self.control = self:getButtonControl(title(state))
    local ok, why = usable(self.object, state)
    self.control:setEnable(ok == true)
    self.control:setTooltip(why)
    return self.control
end

function Handler:handleJoypadContextMenu(context)
    local state = stateOf(self.object)
    if not state then return end
    local option = self:addJoypadContextMenuOption(context, title(state))
    local ok, why = usable(self.object, state)
    if not ok then
        option.notAvailable = true
        local tip = ISToolTip:new()
        tip:initialise()
        tip.description = why or ""
        option.toolTip = tip
    end
end

function Handler:perform()
    local state = stateOf(self.object)
    if state and usable(self.object, state) then
        OA.Sync.send(self.playerObj, "machineSwitch", { machine = state.id, on = state.on == false })
    end
end

function Handler:new()
    local o = ISLootWindowObjectControlHandler.new(self)
    o.altColor = true
    return o
end

ISLootWindowContainerControls.AddHandler(Handler, true)
