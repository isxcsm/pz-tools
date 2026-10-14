-- The breaker box window's pipes (BU.Water): with more than one, at the top of the water tab a card per pipe with what
-- its tanks hold (and a row per building when they are in more than one), set up, renamed and removed there; a pipe
-- chip on each tank's, room's, fixture's and water unit's row, and the menu it opens. The row putting in a new pipe
-- (ISBUAddPipe), and what the tab lists under the rooms besides the fixtures: the tanks and the water units
-- (BU.WaterUnits). The level over time is on the tab's card (ISBUPanelWindow:measureWater).
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

-- The pipe cards, for a panel with more than one pipe: each pipe and its buildings. The card's members are what is
-- on it (outlined in its colour while the mouse is over the card).
function ISBUPanelWindow:pipeRows(add, state, devices)
    local panel = self.panel
    if not Water.shown(panel) then return end
    add({ kind = "header", text = getText("IGUI_BU_Pipes") })
    for _, pipe in ipairs(Water.pipes(panel)) do
        local id = pipe.id
        local each = state and state.pipes and state.pipes[id]
        local members = {}
        for _, at in ipairs(panel.water.producers) do
            if Water.producerPipe(panel, at) == id then
                members[#members + 1] = { at = at }
            end
        end
        for _, device in ipairs(devices) do
            if device.state == "on" and device.pipe == id then
                members[#members + 1] = { device = device }
            end
        end
        for _, unit in ipairs(Units.of(panel.id, "water")) do
            local inlet, outlet = Water.unitPipes(panel, unit)
            if inlet == id or outlet == id then members[#members + 1] = { unit = unit } end
        end
        -- its tooltip only says what is wrong with its water
        local lines = {}
        if WaterUnits.unpurifiedPipes() then lines[#lines + 1] = getText("IGUI_BU_PipeUnpurifiedTip") end
        local foreign = each and each.foreign > 0
        if foreign then lines[#lines + 1] = " <RGB:1,0.45,0.4> " .. getText("IGUI_BU_PipeForeignTip") end
        local right = each and each.capacity > 0 and getText("IGUI_BU_Left_Water", string.format("%.0f", each.amount),
            string.format("%.0f", each.capacity)) or "-"
        add({ kind = "waterPipe", pipe = id, text = Water.pipeName(panel, id), right = right, bad = foreign,
            removable = id ~= Water.FIRST, members = members, colour = Water.colour(id) },
            #lines > 0 and table.concat(lines, " <LINE> ") or nil)
        -- A row per building its tanks are in, with more than one: what they hold, and the highest floor with tanks.
        local keys = {}
        for key, building in pairs(each and each.buildings or {}) do
            if building.capacity > 0 then keys[#keys + 1] = key end
        end
        if #keys > 1 then
            table.sort(keys, function(a, b) return buildingName(panel, a) < buildingName(panel, b) end)
            for _, key in ipairs(keys) do
                local building = each.buildings[key]
                add({ kind = "pipeBuilding", pipe = id, text = getText("IGUI_BU_PipeBuildingRow", buildingName(panel, key),
                    BU.floorName(building.top or 0)), right = getText("IGUI_BU_Left_Water",
                    string.format("%.0f", building.amount), string.format("%.0f", building.capacity)) })
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
    local menu = UI.menu(self, Ui.PALETTE)
    for _, pipe in ipairs(Water.pipes(self.panel)) do
        local option = menu:addOption(Water.pipeName(self.panel, pipe.id), nil, function() choose(pipe.id) end)
        option.swatch = Water.colour(pipe.id)
        if pipe.id == current then option.current = true end
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

-- A click on a pipe's card or the row putting one in: a pipe is put in or taken out at the box, a pipe wrench in hand
-- (ISBUPanelWindow:work); taken out once the player says yes, saying where what is on it goes.
function ISBUPanelWindow:onPipeRow(row, x, width)
    if row.kind == "addPipe" then
        if not Costs.affords(self.playerObj, Costs.addPipe()) then
            return HaloTextHelper.addBadText(self.playerObj, getText("IGUI_BU_Reason_cantAfford"))
        end
        return self:work(ISBUAddPipe:new(self.playerObj, self.panel))
    end
    for _, button in ipairs(Ui.pipeButtons(width, row)) do
        if x >= button.x and x <= button.x + button.w then
            if button.name == "Rename" then return self:askPipeName(row.pipe) end
            return self:askRemovePipe(row.pipe)
        end
    end
end

function ISBUPanelWindow:askRemovePipe(id)
    local panel = self.panel
    if not Costs.affords(self.playerObj, Costs.removePipe()) then
        return HaloTextHelper.addBadText(self.playerObj, getText("IGUI_BU_Reason_cantAfford"))
    end
    UI.confirm(self.playerObj, getText("IGUI_BU_RemovePipeConfirm", Water.pipeName(panel, id),
        Water.pipeName(panel, Water.FIRST)), self, function(window)
        window:work(ISBURemovePipe:new(window.playerObj, window.panel, id))
    end)
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
    elseif unit.kind == "firesprinkler" then
        return getText(WaterUnits.spraying(unit) and "IGUI_BU_FireSprinkler_spraying" or "IGUI_BU_FireSprinkler_waiting")
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

-- The units that use the water of their pipe (their inlet only).
local USERS = { sprinkler = true, firesprinkler = true }

-- The pipe chips of a unit's row: a pump's outlet, a sprinkler's inlet, a filter's and a booster pump's both.
local function unitChips(panel, unit)
    local inlet, outlet = Water.unitPipes(panel, unit)
    if unit.kind == "pump" then return { "PipeOut" }, { PipeOut = outlet } end
    if USERS[unit.kind] then return { "Pipe" }, { Pipe = inlet } end
    return { "PipeIn", "PipeOut" }, { PipeIn = inlet, PipeOut = outlet }
end

-- What the water tab lists under the zone's rooms with the fixtures (ISBUPanelWindow:fill): the tanks, the water units,
-- those whose line supplies nothing, and (unless the view hides them) what could hold water that no box has. Each
-- { row, tip, x, y, z, ref, rank }: rank in that order (a room lists them so, by name within a rank); its row (its name, with where it is when it stands in no room of the zone; what it holds
-- or does on the right; its pipe chips) and its line's ref, for the room or relay it hangs from. A tank's text for the
-- plan goes into view.producerText. A unit whose inlet reaches no tank of its pipe says so in red ("too high").
function ISBUPanelWindow:waterPlaced(state, view)
    local panel = self.panel
    local shown = Water.shown(panel)
    local layout = BU.Networks.waterLayout(panel)
    local rooms = Panels.zoneRooms(panel)
    local result = {}
    local function name(text, x, y, z)
        if Panels.roomHaving(rooms, x, y, z) then return text end
        return text .. "  (" .. Panels.where(panel, x, y, z) .. ")"
    end
    local function put(rank, row, tip, at, ref)
        row.kind, row.nested, row.water = "producer", true, true
        result[#result + 1] = { row = row, tip = tip, x = at.x, y = at.y, z = at.z, ref = ref, rank = rank }
    end
    local tank = getText("IGUI_BU_Legend_tank")
    for index, at in ipairs(panel.water.producers) do
        local seen = PanelWindow.seenProducer(state, at)
        -- One the networks do not hold (its line cut) as it stands on its square, when that is loaded.
        local amount, capacity = seen and seen.amount, seen and seen.capacity
        local storage = not amount and Panels.waterStorage(at.x, at.y, at.z)
        if storage then amount, capacity = storage:getAmount(), storage:getCapacity() end
        local right = getText("IGUI_BU_TankHolds", amount and string.format("%.0f", amount) or "-",
            capacity and string.format("%.0f", capacity) or "-")
        -- Holding what is not water: left out of the pipes until it is emptied.
        if seen and seen.foreign then right = right .. "  " .. getText("IGUI_BU_TankForeign") end
        local ref = BU.Links.producerRef(at.x, at.y, at.z)
        local cut = BU.Links.reason(panel, ref) ~= nil
        if cut then right = right .. "  " .. getText("IGUI_BU_LineNotSupplied") end
        view.producerText[index] = tank .. "  " .. right
        local row = { text = name(tank, at.x, at.y, at.z), right = right, index = index, at = at, cut = cut,
            inUse = PanelWindow.producerInUse(state, at) and not cut, bad = seen and seen.foreign }
        if shown then row.chips, row.pipes = { "Pipe" }, { Pipe = Water.producerPipe(panel, at) } end
        put(1, row, cut and BU.Links.reasonText(panel, ref) or nil, at, ref)
    end
    for _, unit in ipairs(Units.of(panel.id, "water")) do
        local row = { unit = unit, text = name(Units.name(unit), unit.x, unit.y, unit.z),
            right = self:waterUnitStatus(unit), inUse = unit.running == true }
        local inlet = Water.unitPipes(panel, unit)
        if inlet and unit.panel and (USERS[unit.kind] or unit.kind == "filter") and layout.tanks[inlet] then
            local building, level = Water.placeOf(panel, unit.x, unit.y, unit.z, BU.Links.unitRef(unit))
            local id = Water.useId(layout, inlet, building, level)
            if id and not Water.reachesTank(layout, id) then row.bad, row.right = true, getText("IGUI_BU_TooHigh") end
        end
        if shown then row.chips, row.pipes = unitChips(panel, unit) end
        put(2, row, getText("IGUI_BU_UnitTip_" .. unit.kind), unit, BU.Links.unitRef(unit))
    end
    for _, unit in ipairs(BU.Store.unitList(nil, panel.id)) do
        local ref = BU.Links.unitRef(unit)
        if not BU.RELAY_KINDS[unit.kind] and Units.utility(unit) == "water" and BU.enabled(unit.kind)
            and not BU.Links.live(panel, ref) then
            put(3, { at = unit, cut = true, text = name(Units.name(unit), unit.x, unit.y, unit.z),
                right = getText("IGUI_BU_LineNotSupplied") }, BU.Links.reasonText(panel, ref), unit, ref)
        end
    end
    if not PanelWindow.options.hideUnwired then
        for _, at in ipairs(view.unwired) do
            put(4, { at = at, unwired = true, text = name(at.unit and Units.name(at.unit) or tank, at.x, at.y, at.z),
                right = getText("IGUI_BU_NotWired") }, getText("IGUI_BU_UnwiredProducerTip"), at, nil)
        end
    end
    return result
end

-- A click on a water unit's row: its pipe chips (its line is taken away at the unit). True when it hit one.
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
                if USERS[unit.kind] then outlet = nil end
                Sync.send(self.playerObj, "setUnitPipes", { panel = self.panel.id, unit = unit.id, inlet = inlet,
                    outlet = outlet })
            end)
            return true
        end
    end
    return false
end
