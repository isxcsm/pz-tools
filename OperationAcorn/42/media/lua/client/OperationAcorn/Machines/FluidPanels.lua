-- The game's fluid panels (the container's info, the transfer) on a machine's container. The game closes them when the
-- player is more than ISFluidUtil.isoMaxPanelDist squares from the square of the container's owner, and a machine's
-- container is on its anchor, the footprint's corner: by the far side of the 2x2 rain storage the player is three
-- squares from it, and the panel closed as it opened. For a machine the distance is counted from its whole footprint.
require "Fluids/ISFluidInfoUI"
require "Fluids/ISFluidTransferUI"
require "OperationAcorn/Machines/Machines"
local Machines = OperationAcorn.Machines

local FluidPanels = {}
Machines.FluidPanels = FluidPanels

-- The footprint of the machine whose container a panel shows, { x0, y0, x1, y1 }, or false (not a machine's, or one
-- square: the game's own check is right). Worked out once a panel: a machine does not move while it stands.
function FluidPanels.bounds(panel, container)
    if panel.oaBounds == nil then
        panel.oaBounds = false
        local owner = container and container:getOwner()
        local state = owner and Machines.state(owner)
        local square = state and owner:getSquare()
        if square then
            local w, h = Machines.footprint(state.kind, state.dir)
            if w > 1 or h > 1 then
                local x, y = square:getX(), square:getY()
                panel.oaBounds = { x, y, x + w - 1, y + h - 1 }
            end
        end
    end
    return panel.oaBounds
end

-- Runs the game's check `fn` on a panel: for a machine's container the player must be within the game's distance of
-- the footprint (the game's own test, from each side), and the game's check runs with its distance widened by the
-- footprint so that it does not close the panel by the anchor alone (it still closes it on a container gone).
function FluidPanels.around(panel, container, fn, ...)
    local b = FluidPanels.bounds(panel, container)
    if not b then return fn(panel, ...) end
    local dist = ISFluidUtil.isoMaxPanelDist
    local player = panel.player
    if player then
        local px, py = player:getX(), player:getY()
        if px < b[1] - dist or px > b[3] + dist or py < b[2] - dist or py > b[4] + dist then
            panel:close()
            return
        end
    end
    ISFluidUtil.isoMaxPanelDist = dist + math.max(b[3] - b[1], b[4] - b[2])
    local ok, err = pcall(fn, panel, ...)
    ISFluidUtil.isoMaxPanelDist = dist
    if not ok then error(err, 0) end
end

local infoUpdate = ISFluidInfoUI.update
function ISFluidInfoUI:update()
    return FluidPanels.around(self, self.container, infoUpdate)
end

local transferValidate = ISFluidTransferUI.validatePanel
function ISFluidTransferUI:validatePanel(forceUpdate)
    return FluidPanels.around(self, self.container, transferValidate, forceUpdate)
end

return FluidPanels
