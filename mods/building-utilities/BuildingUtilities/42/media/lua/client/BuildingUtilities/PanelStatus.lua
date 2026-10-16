-- The breaker box window's status line: for the utility shown, what supplies it now, how long that lasts (a battery
-- and fuel told the same way) and why it is the one supplying, as the server's rules decide it (BU.Energy.rules,
-- Server.lua checkSource). Green while supplied, amber when it soon will not be or was cut on purpose, red without.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Panels, Networks, Energy = BU.Panels, BU.Networks, BU.Energy
local Ui = BU.PanelUi
local FONT_HGT_SMALL, PAD, load2, duration = Ui.FONT_HGT_SMALL, Ui.PAD, Ui.load2, Ui.duration
local PanelWindow = BU.PanelWindow

local OK, WARN, BAD = "ok", "warn", "bad"
PanelWindow.STATUS_COLOURS = { ok = { 0.35, 0.85, 0.4 }, warn = { 0.95, 0.75, 0.2 }, bad = { 0.95, 0.3, 0.3 } }
-- A battery or fuel with less than this many hours left is told in amber.
local SOON = 12

-- The power producer square the network uses now, as its place in the panel's order, or nil.
local function producerIndex(panel, state)
    for index, producer in ipairs(panel.power.producers) do
        if PanelWindow.producerInUse(state, producer) then return index end
    end
    return nil
end

-- Why no generator of the panel runs: the first reason its producers give, or nil.
local function generatorTrouble(state)
    local far, empty, broken, off = false, false, false, false
    for _, producer in ipairs(state and state.producers or {}) do
        if not producer.source then
            if not getCell():getGridSquare(producer.x, producer.y, producer.z) then far = true
            elseif producer.condition ~= nil and producer.condition <= 0 then broken = true
            elseif producer.fuel ~= nil and producer.fuel <= 0 then empty = true
            else off = true end
        end
    end
    if off then return getText("IGUI_BU_Why_GeneratorOff") end
    if far then return getText("IGUI_BU_Why_NotLoaded") end
    if empty then return getText("IGUI_BU_Why_NoFuel") end
    if broken then return getText("IGUI_BU_Why_Broken") end
    return nil
end

-- The bank's charge and how long it lasts drawn as now, or until full charging as now; nil without a bank. The flow
-- is the bank's last minute (panel.bankFlow) unless given: while the bank carries the load, what the solar panels
-- lack now, since the last minute may have been before it took over.
local function bankLeft(panel, bank, rules, flow)
    if not bank then return nil end
    local charge = BU.percent(bank.charge * 100)
    flow = flow or panel.bankFlow or 0
    if flow < -0.0005 then
        local hours = Energy.bankHoursLeft(bank, rules.floor, flow)
        return getText("IGUI_BU_Left_Bank", charge, duration(hours)), hours
    end
    if flow > 0.0005 and bank.energy < bank.capacity then
        return getText("IGUI_BU_Left_BankFull", charge, duration((bank.capacity - bank.energy) / flow))
    end
    return getText("IGUI_BU_Left_BankHeld", charge)
end

-- Why the units' source does not carry the load: night, or the solar panels make less than it.
local function solarShort(output, load)
    if Energy.sunlight() <= 0 then return getText("IGUI_BU_Why_Night") end
    return getText("IGUI_BU_Why_SolarShort", load2(output), load2(load))
end

-- A box whose breaker is down, or whose main switch a player has off, as its own status.
local function trippedStatus(panel)
    return { text = getText("IGUI_BU_St_Tripped"), reason = getText("IGUI_BU_Why_Tripped", load2(Panels.limit(panel))),
        level = BAD }
end

local function switchedOffStatus()
    return { text = getText("IGUI_BU_St_Off"), reason = getText("IGUI_BU_Why_SwitchedOff"), level = WARN }
end

-- A box over its limit, while its power is on: how long its breaker holds as now (a reason, amber), or nil.
local function overloaded(result, panel, load, limit)
    if not BU.overloadEnabled() or load <= limit + 1e-6 then return result end
    local hours = Panels.breakerHoursLeft(Panels.breaker(panel), load / math.max(limit, 1e-6))
    result.reason = getText("IGUI_BU_Why_Overload", Ui.shortDuration(hours or 0))
    result.level = WARN
    return result
end

-- A panel's power: { text, left, reason, level }. bank: the panel's bank as the caller has it (false for none), else read here.
local function powerStatus(panel, state, given)
    -- The grid carries what it reaches (gridFirst): the box's own supply is told only while something it does not
    -- reach draws (a player-built room, the box's pumps).
    local grid = getWorld():isHydroPowerOn()
    if grid and not (state and state.gridFirst and (state.load or 0) > 1e-6) then
        return { text = getText("IGUI_BU_St_Grid"), reason = getText("IGUI_BU_Why_Grid"), level = OK }
    end
    if panel.tripped then return trippedStatus(panel) end
    if panel.switchedOff then return switchedOffStatus() end
    if not state then return { text = getText("IGUI_BU_St_None"), level = BAD } end
    local hasSource = Energy.hasSource(panel)
    local rules = Energy.rules(panel, state)
    local bank = hasSource and (given == nil and Energy.bank(panel) or given) or nil
    local output = hasSource and Energy.output(panel) or 0
    if state.supplied and Energy.inUse(state) then
        local result = { level = OK }
        if bank and output < rules.load then
            local left, hours = bankLeft(panel, bank, rules, output - rules.load)
            result.text, result.left, result.reason = getText("IGUI_BU_St_Bank"), left, solarShort(output, rules.load)
            if hours and hours < SOON then result.level = WARN end
        else
            result.left = bankLeft(panel, bank, rules)
            result.text = getText("IGUI_BU_St_Solar")
            result.reason = getText("IGUI_BU_Why_SolarOver", load2(output), load2(rules.load))
        end
        if grid then result.reason = getText("IGUI_BU_Why_GridPart") end
        return overloaded(result, panel, rules.load, Panels.limit(panel, bank or false))
    end
    if state.supplied then
        local index = producerIndex(panel, state)
        local result = { text = getText("IGUI_BU_St_Generator", index or "?"), level = OK }
        -- The bank gives what goes over the box's own share, down to empty (Energy.overDraw).
        local over = hasSource and Energy.overDraw(panel, state, rules, bank) or 0
        local bankRules = over > 0 and { floor = 0 } or rules
        if state.hoursLeft then
            local fuel = getText("IGUI_BU_Left_Fuel", duration(state.hoursLeft))
            if state.hoursLeft < SOON then result.level = WARN end
            local left = bankLeft(panel, bank, bankRules)
            result.left = left and left .. "  " .. fuel or fuel
        elseif over > 0 then
            result.left = bankLeft(panel, bank, bankRules)
        end
        if over > 0 then
            result.reason = getText("IGUI_BU_Why_OverDraw", load2(over))
        elseif hasSource and bank then
            result.reason = getText("IGUI_BU_Why_BankLow", BU.percent(Energy.HANDOVER * 100), BU.percent(Energy.TAKE_BACK * 100))
        elseif hasSource then
            result.reason = solarShort(output, rules.load)
        elseif index and index > 1 then
            result.reason = getText("IGUI_BU_Why_Priority")
        end
        if grid then result.reason = getText("IGUI_BU_Why_GridPart") end
        return overloaded(result, panel, rules.load, Panels.limit(panel, bank or false))
    end
    -- Without supply the bank carries nothing: what the solar panels make charges it.
    local result = { text = getText("IGUI_BU_St_None"), level = BAD,
        left = bankLeft(panel, bank, rules, output * Energy.efficiency()) }
    if #panel.power.producers == 0 and not hasSource then
        result.reason = getText("IGUI_BU_Why_NoProducers")
    elseif hasSource and #panel.power.producers == 0 then
        result.reason = getText("IGUI_BU_Why_SourceShort", BU.percent(rules.restart * 100))
    else
        result.reason = generatorTrouble(state) or (hasSource and getText("IGUI_BU_Why_SourceShort", BU.percent(rules.restart * 100))) or nil
    end
    return result
end

-- Floors as text: each range "12F" or "12F to 16F", joined.
local function floorsText(ranges)
    local parts = {}
    for _, range in ipairs(ranges) do
        parts[#parts + 1] = range[1] == range[2] and BU.floorName(range[1])
            or getText("IGUI_BU_FloorSpan", BU.floorName(range[1]), BU.floorName(range[2]))
    end
    return table.concat(parts, ", ")
end

-- How water reaches the floors of a panel with fixtures connected (supply: ISBUPanelWindow:workOutWaterSupply;
-- nothing told without it): the floors with a fixture no tank of its pipe reaches (a reason and WARN).
local function supplyNote(supply)
    if not supply or #supply.dry == 0 then return nil end
    return getText("IGUI_BU_Why_AboveTanks", floorsText(supply.dry)), WARN
end

-- A panel's water: { text, left, reason, level }.
local function waterStatus(panel, state, supply)
    local available, why = BU.waterAvailable()
    if not available then
        return { text = getText("IGUI_BU_St_WaterUnavailable"), reason = getText("IGUI_BU_Why_NoWaterHooks", why), level = BAD }
    end
    if state and state.mains then
        local held = #panel.water.producers > 0 and getText("IGUI_BU_Left_Water", string.format("%.0f", state.amount or 0),
            string.format("%.0f", state.capacity or 0)) or nil
        return { text = getText("IGUI_BU_St_Mains"), left = held, reason = getText("IGUI_BU_Why_Mains"), level = OK }
    end
    if panel.water.frozen then
        return { text = getText("IGUI_BU_St_Frozen"), level = BAD,
            reason = getText("IGUI_BU_Why_Frozen", BU.Water.THAW_ABOVE, BU.Water.THAW_HOURS) }
    end
    if #panel.water.producers == 0 then
        return { text = getText("IGUI_BU_St_WaterNone"), reason = getText("IGUI_BU_Why_NoTanks"), level = BAD }
    end
    local held = state and getText("IGUI_BU_Left_Water", string.format("%.0f", state.amount or 0), string.format("%.0f", state.capacity or 0))
    if state and state.supplied then
        local level = (state.capacity or 0) > 0 and (state.amount or 0) < state.capacity * 0.1 and WARN or OK
        local reason, warn = supplyNote(supply)
        return { text = getText("IGUI_BU_St_Water"), left = held, level = warn or level, reason = reason }
    end
    return { text = getText("IGUI_BU_St_WaterEmpty"), left = held, reason = getText("IGUI_BU_Why_Rain"), level = BAD }
end

-- The status of a panel's utility. supply: how water reaches the panel's floors with fixtures
-- (ISBUPanelWindow:workOutWaterSupply), to tell of them. bank: the panel's bank, when the caller has it (false: none).
function PanelWindow.status(panel, utility, supply, bank)
    local state = Networks.state(panel, utility)
    if utility == "water" then return waterStatus(panel, state, supply) end
    return powerStatus(panel, state, bank)
end

-- The floors where a connected water fixture has no tank of its pipe at its floor or above (too high), from the
-- water tab's rows as last filled: { dry (ranges of floors), byLevel ("dry" by floor) }; nil before the tab has rows,
-- with water off, or while the box has no tanks (the status says that already). Worked out once a refresh, for the
-- status line and the plan.
function ISBUPanelWindow:workOutWaterSupply()
    local view = self.views and self.views.water
    if not view or not BU.enabled("water") or not BU.waterAvailable() or #self.panel.water.producers == 0 then return nil end
    local Water = BU.Water
    local layout = BU.Networks.waterLayout(self.panel)
    local byLevel, levels = {}, {}
    for _, device in ipairs(view.devices or {}) do
        if device.state == "on" and device.building and layout.tanks[device.pipe or Water.FIRST] then
            local id = Water.useId(layout, device.pipe, device.building, device.level)
            if id and not Water.reachesTank(layout, id) and not byLevel[device.level] then
                byLevel[device.level] = "dry"
                levels[#levels + 1] = device.level
            end
        end
    end
    table.sort(levels)
    local dry = {}
    for _, level in ipairs(levels) do
        local last = dry[#dry]
        if last and last[2] == level - 1 then last[2] = level else dry[#dry + 1] = { level, level } end
    end
    return { dry = dry, byLevel = byLevel }
end

-- The status line as drawn: the text and what is left on it after the dot; the reason after it in grey when it fits
-- (it ends at reasonEnd), else only in the tooltip, which has the utilities that are on in full. Measured here, not
-- each frame. None with both off.
function ISBUPanelWindow:updateStatus()
    self.statusUtility = self:activeUtility()
    if not self.statusUtility then
        self.status = nil
        self.statusArea:setTooltip(nil)
        return
    end
    local supply = self.waterSupply
    local status = PanelWindow.status(self.panel, self.statusUtility, supply, self.bank)
    local text = status.left and status.text .. ", " .. status.left or status.text
    local textX = PAD + FONT_HGT_SMALL
    self.status = { text = text, textX = textX, colour = PanelWindow.STATUS_COLOURS[status.level] }
    if status.reason then
        local UI = Ui.UI
        self.status.reason = "- " .. status.reason
        self.status.reasonX = textX + UI.textWidth(text) + 12
        self.status.reasonEnd = self.status.reasonX + UI.textWidth(self.status.reason)
    end
    local lines = {}
    for _, utility in ipairs(self.utilities) do
        local each = utility == self.statusUtility and status or PanelWindow.status(self.panel, utility, supply, self.bank)
        lines[#lines + 1] = " <RGB:1,1,1> " .. getText("IGUI_BU_Tab_" .. utility) .. ": " .. each.text
        if each.left then lines[#lines + 1] = " <RGB:0.8,0.8,0.8> " .. each.left end
        if each.reason then lines[#lines + 1] = " <RGB:0.7,0.7,0.7> " .. each.reason end
    end
    self.statusArea:setTooltip(table.concat(lines, " <LINE> "))
end
