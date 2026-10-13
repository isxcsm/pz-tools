-- The breaker box window's pipes (BU.Water): with more than one, at the top of the water tab a card per pipe with what
-- its tanks hold (and a row per building when they are in more than one), set up, renamed and removed there; a pipe
-- chip on each tank's, room's, fixture's and water unit's row, and the menu it opens. The row putting in a new pipe
-- (ISBUAddPipe), and the water units' rows (BU.WaterUnits). The level over time is on the tab's card
-- (ISBUPanelWindow:measureWater).
require "BuildingUtilities/PanelWindow"
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Water, Sync, Units, WaterUnits, Panels, Costs = BU.Water, BU.Sync, BU.Units, BU.WaterUnits, BU.Panels, BU.Costs
local Ui = BU.PanelUi
local UI = Ui.UI
local PanelWindow = BU.PanelWindow

-- A building's name on a pipe's card: this one (the box's), outside (an outdoor box's), else where it is from the box.
local function buildingName(panel, key)
    if key == Water.OUTDOOR then return getText("IGUI_BU_PipeOutside") end
    local own = Panels.building(panel)
    if own and own.key == key then return getText("IGUI_BU_PipeThisBuilding") end
    local x, y = tostring(key):match("^(%-?%d+),(%-?%d+)")
    if not x then return tostring(key) end
    return getText("IGUI_BU_PipeOtherBuilding", Panels.where(panel, tonumber(x), tonumber(y)))
end

-- What a machine does between two pipes, for the cards' tooltips: by pipe, lines.
local function flows(panel)
    local result = {}
    local function line(pipe, text)
        result[pipe] = result[pipe] or {}
        table.insert(result[pipe], text)
    end
    for _, unit in ipairs(Units.of(panel.id, "water")) do
        local inlet, outlet = Water.unitPipes(panel, unit)
        if unit.kind == "pump" then
            line(outlet, getText("IGUI_BU_PipeFlow_pump"))
        elseif (unit.kind == "filter" or unit.kind == "booster") and inlet ~= outlet then
            line(inlet, getText("IGUI_BU_PipeFlowOut_" .. unit.kind, Water.pipeName(panel, outlet)))
            line(outlet, getText("IGUI_BU_PipeFlowIn_" .. unit.kind, Water.pipeName(panel, inlet)))
        elseif unit.kind == "filter" then
            line(inlet, getText("IGUI_BU_PipeFlow_filterSame"))
        elseif unit.kind == "booster" then
            line(inlet, getText("IGUI_BU_PipeFlow_boosterSame"))
        end
    end
    return result
end

-- The pipe cards, for a panel with more than one pipe: each pipe and its buildings. The card's members are what is
-- on it (outlined in its colour while the mouse is over the card).
function ISBUPanelWindow:pipeRows(add, state, devices)
    local panel = self.panel
    if not Water.shown(panel) then return end
    local layout = BU.Networks.waterLayout(panel)
    local machines = flows(panel)
    add({ kind = "header", text = getText("IGUI_BU_Pipes") })
    for _, pipe in ipairs(Water.pipes(panel)) do
        local id = pipe.id
        local each = state and state.pipes and state.pipes[id]
        local members, tanks, fixtures = {}, 0, 0
        for _, at in ipairs(panel.water.producers) do
            if Water.producerPipe(panel, at) == id then
                tanks = tanks + 1
                members[#members + 1] = { at = at }
            end
        end
        for _, device in ipairs(devices) do
            if device.state == "on" and device.pipe == id then
                fixtures = fixtures + 1
                members[#members + 1] = { device = device }
            end
        end
        for _, unit in ipairs(Units.of(panel.id, "water")) do
            local inlet, outlet = Water.unitPipes(panel, unit)
            if inlet == id or outlet == id then members[#members + 1] = { unit = unit } end
        end
        local lines = { getText("IGUI_BU_PipeTip", tanks, fixtures) }
        for _, text in ipairs(machines[id] or {}) do lines[#lines + 1] = text end
        if WaterUnits.unpurifiedPipes() then lines[#lines + 1] = getText("IGUI_BU_PipeUnpurifiedTip") end
        if pipe.reserve then lines[#lines + 1] = getText("IGUI_BU_PipeReserve", BU.percent(pipe.reserve)) end
        local foreign = each and each.foreign > 0
        if foreign then lines[#lines + 1] = " <RGB:1,0.45,0.4> " .. getText("IGUI_BU_PipeForeignTip") end
        local right = each and each.capacity > 0 and getText("IGUI_BU_Left_Water", string.format("%.0f", each.amount),
            string.format("%.0f", each.capacity)) or "-"
        add({ kind = "waterPipe", pipe = id, text = Water.pipeName(panel, id), right = right, bad = foreign,
            removable = id ~= Water.FIRST, members = members, colour = Water.colour(id) }, table.concat(lines, " <LINE> "))
        -- A row per building its tanks are in, with more than one: what they hold, and the highest floor with tanks.
        local keys = {}
        for key, building in pairs(each and each.buildings or {}) do
            if building.capacity > 0 then keys[#keys + 1] = key end
        end
        if #keys > 1 then
            table.sort(keys, function(a, b) return buildingName(panel, a) < buildingName(panel, b) end)
            for _, key in ipairs(keys) do
                local building = each.buildings[key]
                local crossing = layout.crossings[key]
                local tip = crossing and crossing ~= math.huge
                    and getText("IGUI_BU_PipeCrossingTip", BU.floorName(crossing)) or nil
                add({ kind = "pipeBuilding", pipe = id, text = getText("IGUI_BU_PipeBuildingRow", buildingName(panel, key),
                    BU.floorName(building.top or 0)), right = getText("IGUI_BU_Left_Water",
                    string.format("%.0f", building.amount), string.format("%.0f", building.capacity)) }, tip)
            end
        end
    end
end

-- The row putting in a new pipe (none with all colours in use), with what it takes.
function ISBUPanelWindow:addPipeRow(add)
    local panel = self.panel
    local id = Water.nextPipe(panel)
    if not id then return end
    local cost = Costs.addPipe()
    local affords = Costs.affords(self.playerObj, cost)
    add({ kind = "addPipe", text = getText("IGUI_BU_AddPipe"), reason = not affords or nil },
        getText("IGUI_BU_AddPipeTip", getText("IGUI_BU_Pipe_" .. Water.COLOUR_NAMES[id], id)) .. " <LINE> "
            .. Costs.describe(self.playerObj, cost))
end

-- A menu of the pipes at the mouse; the current one is not offered. back: a last option (a fixture's room's pipe).
function ISBUPanelWindow:pipeMenu(current, choose, back)
    local menu = ISContextMenu.get(self.playerObj:getPlayerNum(), getMouseX(), getMouseY())
    for _, pipe in ipairs(Water.pipes(self.panel)) do
        local option = menu:addOption(Water.pipeName(self.panel, pipe.id), nil, function() choose(pipe.id) end)
        if pipe.id == current then option.notAvailable = true end
    end
    if back then menu:addOption(back, nil, function() choose(nil) end) end
end

-- A name asked for (the kit's prompt, over the window), then sent: a pipe's new name (empty for its colour's).
function ISBUPanelWindow:askPipeName(id)
    local pipe = Water.pipe(self.panel, id)
    if not pipe then return end
    UI.prompt(self.playerObj, getText("IGUI_BU_PipeNamePrompt"), pipe.name or "", self, function(window, name)
        Sync.send(window.playerObj, "renamePipe", { panel = window.panel.id, pipe = id, name = name })
    end, self)
end

-- A pipe's settings in a menu: how full its tanks stay for its people (sprinklers stop there).
function ISBUPanelWindow:pipeSettingsMenu(id)
    local panel = self.panel
    local pipe = Water.pipe(panel, id)
    if not pipe then return end
    local menu = ISContextMenu.get(self.playerObj:getPlayerNum(), getMouseX(), getMouseY())
    local reserve = menu:addOption(getText("IGUI_BU_PipeReserve", pipe.reserve and BU.percent(pipe.reserve)
        or getText("IGUI_BU_ReserveNone")))
    local reserves = ISContextMenu:getNew(menu)
    menu:addSubMenu(reserve, reserves)
    for _, percent in ipairs({ 0, 10, 25, 50, 75 }) do
        local option = reserves:addOption(percent == 0 and getText("IGUI_BU_ReserveNone") or BU.percent(percent), nil,
            function() Sync.send(self.playerObj, "setPipeReserve", { panel = panel.id, pipe = id, percent = percent }) end)
        if (pipe.reserve or 0) == percent then option.notAvailable = true end
    end
end

-- A click on a pipe's card or the row putting one in: the new pipe is laid at the box, a pipe wrench in hand.
function ISBUPanelWindow:onPipeRow(row, x, width)
    if row.kind == "addPipe" then
        if not Costs.affords(self.playerObj, Costs.addPipe()) then
            return HaloTextHelper.addBadText(self.playerObj, getText("IGUI_BU_Reason_cantAfford"))
        end
        local panel = self.panel
        return BU.ContextMenu.queueAt(self.playerObj, panel.x, panel.y, panel.z, ISBUAddPipe:new(self.playerObj, panel))
    end
    for _, button in ipairs(Ui.pipeButtons(width, row)) do
        if x >= button.x and x <= button.x + button.w then
            if button.name == "Settings" then return self:pipeSettingsMenu(row.pipe) end
            if button.name == "Rename" then return self:askPipeName(row.pipe) end
            return Sync.send(self.playerObj, "removePipe", { panel = self.panel.id, pipe = row.pipe })
        end
    end
end

-- A tank's pipe chip.
function ISBUPanelWindow:producerPipeMenu(row)
    self:pipeMenu(row.pipes.Pipe, function(id)
        if id then Sync.send(self.playerObj, "setProducerPipe", { panel = self.panel.id, utility = "water", index = row.index, pipe = id }) end
    end)
end

-- A fixture's pipe chip; one the player put on another pipe than its room's can go back to its room's.
function ISBUPanelWindow:devicePipeMenu(device)
    local back = device.pipeChosen and device.roomKey and getText("IGUI_BU_PipeOfRoom") or nil
    self:pipeMenu(device.pipe, function(id)
        Sync.send(self.playerObj, "setDevicePipe", { panel = self.panel.id, utility = "water", key = device.key, pipe = id })
    end, back)
end

-- A room's pipe chip: the pipe its fixtures are on.
function ISBUPanelWindow:roomPipeMenu(row)
    self:pipeMenu(row.pipe, function(id)
        if id then Sync.send(self.playerObj, "setRoomPipe", { panel = self.panel.id, room = row.roomKey, pipe = id }) end
    end)
end

-- What a water unit does now, in a few words.
function ISBUPanelWindow:waterUnitStatus(unit)
    if unit.kind == "pump" then
        if unit.running and unit.idle == "noWater" then return getText("IGUI_BU_Pump_noWater") end
        if unit.running then return getText("IGUI_BU_Pump_running", unit.moved or WaterUnits.PUMP_RATE) end
        return getText("IGUI_BU_Pump_" .. (unit.idle or "noPower"))
    elseif unit.kind == "booster" then
        if unit.running then return getText("IGUI_BU_Booster_running", unit.moved or WaterUnits.BOOSTER_RATE) end
        return getText("IGUI_BU_Booster_" .. (unit.idle or "noPower"))
    elseif unit.kind == "sprinkler" then
        return getText(WaterUnits.spraying(unit) and "IGUI_BU_Sprinkler_watering" or "IGUI_BU_Sprinkler_waiting")
    end
    local media = getText("IGUI_BU_FilterMedia", BU.percent(WaterUnits.mediaLeft(unit) * 100))
    local inlet, outlet = Water.unitPipes(self.panel, unit)
    if inlet ~= outlet then
        if unit.running then return media .. ", " .. getText("IGUI_BU_Filter_moving", unit.moved or WaterUnits.FILTER_RATE) end
        if unit.idle then return media .. ", " .. getText("IGUI_BU_Filter_" .. unit.idle) end
    elseif unit.running then
        return media .. ", " .. getText("IGUI_BU_Filter_purifying")
    end
    if WaterUnits.unpurifiedPipes() or inlet ~= outlet then return media end
    -- The option asks for unpurified pipes, but this game's API cannot keep the taint: say so, not just "resting".
    local purify, why = BU.purifyAvailable()
    if BU.sandbox("RiskPlumbingUnpurified", false) == true and not purify then
        return media .. ", " .. getText("IGUI_BU_Filter_restingNoRisk", why)
    end
    return media .. ", " .. getText("IGUI_BU_Filter_resting")
end

-- The pipe chips of a unit's row: a pump's outlet, a sprinkler's inlet, a filter's and a booster pump's both.
local function unitChips(panel, unit)
    local inlet, outlet = Water.unitPipes(panel, unit)
    if unit.kind == "pump" then return { "PipeOut" }, { PipeOut = outlet } end
    if unit.kind == "sprinkler" then return { "Pipe" }, { Pipe = inlet } end
    return { "PipeIn", "PipeOut" }, { PipeIn = inlet, PipeOut = outlet }
end

-- The water units' rows, after the tanks: what each does, its pipes (with more than one) and its line. One whose
-- inlet reaches no tank of its pipe says so in red ("too high").
function ISBUPanelWindow:waterUnitRows(add)
    local panel = self.panel
    local shown = Water.shown(panel)
    local layout = BU.Networks.waterLayout(panel)
    for _, unit in ipairs(Units.of(panel.id, "water")) do
        local text = getText("IGUI_BU_WaterUnitRow", Units.name(unit), Panels.where(panel, unit.x, unit.y, unit.z),
            self:waterUnitStatus(unit))
        local row = { kind = "producer", unit = unit, text = text, water = true, inUse = unit.running == true }
        local inlet = Water.unitPipes(panel, unit)
        if inlet and unit.panel and (unit.kind == "sprinkler" or unit.kind == "filter") and layout.tanks[inlet] then
            local building, level = Water.placeOf(panel, unit.x, unit.y, unit.z, BU.Links.unitRef(unit))
            local id = Water.useId(layout, inlet, building, level)
            if id and not Water.reachesTank(layout, id) then
                row.bad, row.text = true, text .. "  " .. getText("IGUI_BU_TooHigh")
            end
        end
        if shown then row.chips, row.pipes = unitChips(panel, unit) end
        add(row, getText("IGUI_BU_UnitTip_" .. unit.kind))
    end
end

-- A click on a water unit's row: its pipe chips (its line is taken away at the unit).
function ISBUPanelWindow:onWaterUnitRow(row, x, width)
    local unit = row.unit
    for _, button in ipairs(Ui.producerButtons(width, row)) do
        if x >= button.x and x <= button.x + button.w then
            local inlet, outlet = Water.unitPipes(self.panel, unit)
            self:pipeMenu(row.pipes[button.name], function(id)
                if not id then return end
                if button.name == "PipeOut" and unit.kind == "pump" then inlet, outlet = id, nil
                elseif button.name == "PipeOut" then outlet = id
                else inlet = id end
                if unit.kind == "sprinkler" then outlet = nil end
                Sync.send(self.playerObj, "setUnitPipes", { panel = self.panel.id, unit = unit.id, inlet = inlet,
                    outlet = outlet })
            end)
        end
    end
end
