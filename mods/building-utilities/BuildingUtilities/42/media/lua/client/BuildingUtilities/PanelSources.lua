-- The breaker box window's rows for the units' source (solar panels, the bank), and what each generator does.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Store, Sync, Energy, Units = BU.Store, BU.Sync, BU.Energy, BU.Units
local Ui = BU.PanelUi
local load2 = Ui.load2
local PanelWindow = BU.PanelWindow

-- A producer square as the network's state last saw it, or nil.
function PanelWindow.seenProducer(state, at)
    for _, producer in ipairs(state and state.producers or {}) do
        if producer.x == at.x and producer.y == at.y and producer.z == at.z then return producer end
    end
    return nil
end

-- Whether a producer square is the one the network uses now (state.producer).
function PanelWindow.producerInUse(state, at)
    local using = state and state.producer
    return using ~= nil and not using.source and using.x == at.x and using.y == at.y and using.z == at.z
end

-- What a generator of the panel does, as the network's state last saw it: "running" (it carries the load), "out"
-- (out of service: a player switched it off by hand, and the API leaves it off until a player switches it on),
-- "cannot" (off, without fuel or broken), "standby" (off, and the API starts it when the one in use stops, or as its
-- network is switched on again), or nil while the API has not seen it.
function PanelWindow.generatorState(state, at)
    if PanelWindow.producerInUse(state, at) then return "running" end
    local seen = PanelWindow.seenProducer(state, at)
    if not seen then return nil end
    if seen.running then return "running" end
    if seen.outOfService then return "out" end
    if seen.running == nil then return nil end
    if (seen.fuel ~= nil and seen.fuel <= 0) or (seen.condition ~= nil and seen.condition <= 0) then return "cannot" end
    return "standby"
end

-- A generator's state in words, for its row ("-" while unknown).
local GENERATOR_STATE_TEXT = { running = "IGUI_BU_Running", standby = "IGUI_BU_Standby", out = "IGUI_BU_OutOfService",
    cannot = "IGUI_BU_CannotRun" }
function PanelWindow.generatorStateText(state)
    return state and getText(GENERATOR_STATE_TEXT[state]) or "-"
end

-- Units as a row's members (outlined in the world with it).
local function unitRows(units)
    local rows = {}
    for _, unit in ipairs(units) do rows[#rows + 1] = { unit = unit } end
    return rows
end

-- The units' source, a row each for { row, tooltip }: the solar panels (how many, what they make, whether they carry
-- the load, snow on them) and the bank (its charge, charging or drawn, worn batteries, cold).
function ISBUPanelWindow:sourceRows(state)
    local panel, rows = self.panel, {}
    local output, count, snow = Energy.output(panel)
    local seen = Energy.sourceState(state)
    local inUse = Energy.inUse(state)
    -- the bank the window measured (measureLoad)
    local bank = self.bank
    if bank == nil then bank = Energy.bank(panel) end
    bank = bank or nil
    if count > 0 then
        local status
        if Energy.sunlight() <= 0 then status = getText("IGUI_BU_SolarNight")
        elseif bank then status = ""
        elseif inUse then status = getText("IGUI_BU_Running")
        elseif seen and seen.available then status = getText("IGUI_BU_Standby")
        else status = getText("IGUI_BU_SolarShort") end
        local text = getText("IGUI_BU_SolarRow", count, load2(output), status)
        if snow >= Energy.SNOW_TRACE then text = text .. "  " .. getText("IGUI_BU_SolarSnow", BU.percent(snow * 100)) end
        -- Only the mechanics this game has on are told.
        local tooltip = getText("IGUI_BU_SolarLightTip", load2(Energy.rated()), BU.percent(Energy.sunlight() * 100))
        if Energy.snowEnabled() then tooltip = tooltip .. " " .. getText("IGUI_BU_SolarSnowTip") end
        tooltip = tooltip .. " " .. getText(bank and "IGUI_BU_SolarBankTip" or "IGUI_BU_SolarTip", load2(state and state.load or 0))
        rows[#rows + 1] = { row = { kind = "source", text = text, inUse = inUse and not bank, source = "solar",
            members = unitRows(Units.working(panel, "solar")) }, tooltip = tooltip }
    end
    local racks = BU.enabled("rack") and Store.unitList("rack", panel.id) or {}
    if #racks > 0 then
        local text, tooltip
        if bank then
            local flow = panel.bankFlow or 0
            local status = getText("IGUI_BU_Standby")
            if flow > 0.0005 then status = getText("IGUI_BU_BankCharging", load2(flow))
            elseif flow < -0.0005 then status = getText("IGUI_BU_BankDrawn", load2(-flow)) end
            text = getText("IGUI_BU_BankRow", #racks, BU.percent(bank.charge * 100), string.format("%.1f", bank.energy),
                string.format("%.1f", bank.capacity), load2(Energy.boost(panel, bank)), status)
            if bank.drag > 0.005 then text = text .. "  " .. getText("IGUI_BU_BankDrag", BU.percent(bank.drag * 100)) end
            if #bank.bypassed > 0 then text = text .. "  " .. getText("IGUI_BU_BankBypassed", #bank.bypassed) end
            if bank.cold > 0.005 then text = text .. "  " .. getText("IGUI_BU_BankCold", BU.percent(bank.cold * 100)) end
            tooltip = getText("IGUI_BU_BankTip", #bank.batteries, #racks, BU.percent(Energy.efficiency() * 100))
            if Energy.wearRate() > 0 then tooltip = tooltip .. " " .. getText("IGUI_BU_BankWearTip") end
            if Energy.heatWearEnabled() and Energy.wearRate() > 0 then
                tooltip = tooltip .. " " .. getText("IGUI_BU_BankHeatTip")
            end
            if Energy.dragEnabled() then tooltip = tooltip .. " " .. getText("IGUI_BU_BankDragTip") end
            if (panel.tier or 1) >= Energy.BYPASS_TIER then
                tooltip = tooltip .. " " .. getText("IGUI_BU_BankBypassTip", Energy.WEAK)
            end
            if Energy.coldLockEnabled() then tooltip = tooltip .. " " .. getText("IGUI_BU_BankColdTip") end
            tooltip = tooltip .. " " .. getText("IGUI_BU_BankEmptyTip") .. " <LINE> <LINE> "
                .. getText("IGUI_BU_HandoverTip", BU.percent(Energy.HANDOVER * 100), BU.percent(Energy.TAKE_BACK * 100))
        else
            text = getText("IGUI_BU_BankEmpty", #racks)
        end
        rows[#rows + 1] = { row = { kind = "source", text = text, inUse = inUse and bank ~= nil, source = "rack",
            members = unitRows(racks) }, tooltip = tooltip }
    end
    -- "Switch to solar" on the first row, while something else carries the load (Energy.sourceOffer).
    local offered, ready, rules = Energy.sourceOffer(panel, state)
    if offered and rows[1] then
        local first = rows[1]
        first.row.useSource, first.row.useSourceReady = true, ready
        first.row.useSourceReason = not ready and Energy.notReadyText(rules) or nil
        local note = ready and getText("IGUI_BU_UseSourceTip") or first.row.useSourceReason
        first.tooltip = (first.tooltip and first.tooltip .. " <LINE> <LINE> " or "") .. note
    end
    return rows
end
