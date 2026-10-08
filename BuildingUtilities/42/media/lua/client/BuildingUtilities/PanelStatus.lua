-- The breaker box window's status line: for the utility shown, what supplies it now, how long that lasts (a battery
-- and fuel told the same way) and why it is the one supplying, as the server's rules decide it (BU.Energy.rules,
-- Server.lua checkSource). Green while supplied, amber when it soon will not be or was cut on purpose, red without.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Store, Panels, Networks, Energy = BU.Store, BU.Panels, BU.Networks, BU.Energy
local Ui = BU.PanelUi
local FONT_HGT_SMALL, PAD, load2, duration, count = Ui.FONT_HGT_SMALL, Ui.PAD, Ui.load2, Ui.duration, Ui.count
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

-- A box whose breaker is down, or whose main switch a player has off, as its own status (a sub-panel's too).
local function trippedStatus(panel)
    return { text = getText("IGUI_BU_St_Tripped"), reason = getText("IGUI_BU_Why_Tripped", load2(Panels.capacity(panel))),
        level = BAD }
end

local function switchedOffStatus()
    return { text = getText("IGUI_BU_St_Off"), reason = getText("IGUI_BU_Why_SwitchedOff"), level = WARN }
end

-- A main panel's power: { text, left, reason, level }.
local function powerStatus(panel, state)
    if getWorld():isHydroPowerOn() then
        return { text = getText("IGUI_BU_St_Grid"), reason = getText("IGUI_BU_Why_Grid"), level = OK }
    end
    if panel.tripped then return trippedStatus(panel) end
    if panel.switchedOff then return switchedOffStatus() end
    if not state then return { text = getText("IGUI_BU_St_None"), level = BAD } end
    local hasSource = Energy.hasSource(panel)
    local rules = Energy.rules(panel, state)
    local bank = hasSource and Energy.bank(panel) or nil
    local output = hasSource and Energy.output(panel) or 0
    if panel.quietCut then
        local settings = rules.settings
        return { text = getText("IGUI_BU_St_QuietCut"), left = bankLeft(panel, bank, rules),
            reason = getText("IGUI_BU_Why_Quiet", settings.quietFrom, settings.quietTo), level = WARN }
    end
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
        local saving = count(panel.power.saving)
        if saving > 0 then result.reason = getText("IGUI_BU_Why_Saving", saving) end
        return result
    end
    if state.supplied then
        local index = producerIndex(panel, state)
        local result = { text = getText("IGUI_BU_St_Generator", index or "?"), level = OK }
        if state.hoursLeft then
            local fuel = getText("IGUI_BU_Left_Fuel", duration(state.hoursLeft))
            if state.hoursLeft < SOON then result.level = WARN end
            local left = bankLeft(panel, bank, rules)
            result.left = left and left .. "  " .. fuel or fuel
        end
        local controller = Energy.hasController(panel)
        if hasSource and bank and controller and Energy.charging(panel) > 0 then
            result.reason = getText("IGUI_BU_Why_Charging", BU.percent(rules.settings.stop))
        elseif hasSource and bank and controller then
            result.reason = getText("IGUI_BU_Why_BankLow", BU.percent(rules.settings.start), BU.percent(rules.settings.stop))
        elseif hasSource and bank then
            result.reason = getText("IGUI_BU_Why_BankManual")
        elseif hasSource then
            result.reason = solarShort(output, rules.load)
        elseif index and index > 1 then
            result.reason = getText("IGUI_BU_Why_Priority")
        end
        return result
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

-- A main panel's water: { text, left, reason, level }.
local function waterStatus(panel, state)
    local available, why = BU.waterAvailable()
    if not available then
        return { text = getText("IGUI_BU_St_WaterUnavailable"), reason = getText("IGUI_BU_Why_NoWaterHooks", why), level = BAD }
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
        return { text = getText("IGUI_BU_St_Water"), left = held, level = level }
    end
    return { text = getText("IGUI_BU_St_WaterEmpty"), left = held, reason = getText("IGUI_BU_Why_Rain"), level = BAD }
end

-- The status of a panel's utility; a sub-panel's is its main panel's, told as coming from it.
function PanelWindow.status(panel, utility)
    local parent = Store.get(panel.parent)
    if parent and utility == "power" and panel.tripped then return trippedStatus(panel) end
    -- As for a main panel, the grid tells first while it runs.
    if parent and utility == "power" and panel.switchedOff and not getWorld():isHydroPowerOn() then
        return switchedOffStatus()
    end
    if parent then
        local result = PanelWindow.status(parent, utility)
        result.text = getText("IGUI_BU_St_Sub", Panels.name(parent), result.text)
        -- Water runs down only: the floors above every tank of the main panel have none.
        local low, high = nil, nil
        if utility == "water" then low, high = BU.Water.dryFloors(panel) end
        if low then
            local floors = low == high and BU.floorName(low) or getText("IGUI_BU_FloorSpan", BU.floorName(low), BU.floorName(high))
            result.reason = getText("IGUI_BU_Why_AboveTanks", floors)
            if result.level ~= BAD then result.level = WARN end
        end
        return result
    end
    local state = Networks.state(panel, utility)
    if utility == "water" then return waterStatus(panel, state) end
    return powerStatus(panel, state)
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
    local status = PanelWindow.status(self.panel, self.statusUtility)
    local text = status.left and status.text .. ", " .. status.left or status.text
    local textX = PAD + FONT_HGT_SMALL
    self.status = { text = text, textX = textX, colour = PanelWindow.STATUS_COLOURS[status.level] }
    if status.reason then
        local measure = getTextManager()
        self.status.reason = "- " .. status.reason
        self.status.reasonX = textX + measure:MeasureStringX(UIFont.Small, text) + 12
        self.status.reasonEnd = self.status.reasonX + measure:MeasureStringX(UIFont.Small, self.status.reason)
    end
    local lines = {}
    for _, utility in ipairs(self.utilities) do
        local each = PanelWindow.status(self.panel, utility)
        lines[#lines + 1] = " <RGB:1,1,1> " .. getText("IGUI_BU_Tab_" .. utility) .. ": " .. each.text
        if each.left then lines[#lines + 1] = " <RGB:0.8,0.8,0.8> " .. each.left end
        if each.reason then lines[#lines + 1] = " <RGB:0.7,0.7,0.7> " .. each.reason end
    end
    self.statusArea:setTooltip(table.concat(lines, " <LINE> "))
end
