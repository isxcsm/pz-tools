-- The breaker box window's rows for the units' source (solar panels, the bank) and the charge controller's
-- settings, and what each generator does.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Store, Sync, Energy = BU.Store, BU.Sync, BU.Energy
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

-- What a generator of the panel does, as the network's state last saw it: "running" (it carries the load), "cannot"
-- (off, without fuel or broken), "standby" (the API switched it off and starts it when the one in use stops), "out"
-- (out of service: a player switched it off, and the API leaves it off until a player switches it on), or nil while
-- the API has not seen it.
function PanelWindow.generatorState(state, at)
    if PanelWindow.producerInUse(state, at) then return "running" end
    local seen = PanelWindow.seenProducer(state, at)
    if not seen then return nil end
    if seen.running then return "running" end
    if (seen.fuel ~= nil and seen.fuel <= 0) or (seen.condition ~= nil and seen.condition <= 0) then return "cannot" end
    if seen.standby then return "standby" end
    if seen.running == nil then return nil end
    return "out"
end

-- A generator's state in words, for its row ("-" while unknown).
local GENERATOR_STATE_TEXT = { running = "IGUI_BU_Running", standby = "IGUI_BU_Standby", out = "IGUI_BU_OutOfService",
    cannot = "IGUI_BU_CannotRun" }
function PanelWindow.generatorStateText(state)
    return state and getText(GENERATOR_STATE_TEXT[state]) or "-"
end

-- The units' source, a row each for { row, tooltip }: the solar panels (how many, what they make, whether they carry
-- the load, snow on them) and the bank (its charge, charging or drawn, worn batteries, cold).
function ISBUPanelWindow:sourceRows(state)
    local panel, rows = self.panel, {}
    local output, count, snow = Energy.output(panel)
    local seen = Energy.sourceState(state)
    local inUse = Energy.inUse(state)
    local bank = Energy.bank(panel)
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
        rows[#rows + 1] = { row = { kind = "source", text = text, inUse = inUse and not bank }, tooltip = tooltip }
    end
    local racks = Store.unitList("rack", panel.id)
    if #racks > 0 then
        local text, tooltip
        if bank then
            local flow = panel.bankFlow or 0
            local status = getText("IGUI_BU_Standby")
            if flow > 0.0005 then status = getText("IGUI_BU_BankCharging", load2(flow))
            elseif flow < -0.0005 then status = getText("IGUI_BU_BankDrawn", load2(-flow)) end
            text = getText("IGUI_BU_BankRow", BU.percent(bank.charge * 100), string.format("%.1f", bank.energy),
                string.format("%.1f", bank.capacity), status)
            if bank.weak > 0 then text = text .. "  " .. getText("IGUI_BU_BankWeak", bank.weak) end
            if panel.quietCut then text = text .. "  " .. getText("IGUI_BU_QuietCut") end
            if bank.cold > 0.005 then text = text .. "  " .. getText("IGUI_BU_BankCold", BU.percent(bank.cold * 100)) end
            tooltip = getText("IGUI_BU_BankTip", #bank.batteries, #racks, BU.percent(Energy.efficiency() * 100))
            if Energy.wearRate() > 0 then tooltip = tooltip .. " " .. getText("IGUI_BU_BankWearTip") end
            if Energy.weakDrainEnabled() then
                tooltip = tooltip .. " " .. getText("IGUI_BU_BankWeakTip", Energy.WEAK, BU.percent(Energy.WEAK_PER_DAY * 100))
            end
            if Energy.coldLockEnabled() then tooltip = tooltip .. " " .. getText("IGUI_BU_BankColdTip") end
            tooltip = tooltip .. " " .. getText("IGUI_BU_BankEmptyTip") .. " <LINE> "
            for _, battery in ipairs(bank.batteries) do tooltip = tooltip .. " <LINE> " .. BU.Rack.batteryText(battery) end
        else
            text = getText("IGUI_BU_BankEmpty", #racks)
        end
        local controller = (panel.tier or 1) >= BU.CONTROLLER_TIER
        if controller then tooltip = (tooltip and tooltip .. " <LINE> <LINE> " or "") .. self:controllerText() end
        rows[#rows + 1] = { row = { kind = "source", text = text, inUse = inUse and bank ~= nil, settings = controller }, tooltip = tooltip }
    end
    return rows
end

-- The charge controller's settings in words, for the bank's tooltip.
function ISBUPanelWindow:controllerText()
    local settings = Energy.settings(self.panel)
    local quiet = settings.quietFrom == settings.quietTo and getText("IGUI_BU_QuietNone")
        or getText("IGUI_BU_QuietHours", settings.quietFrom, settings.quietTo)
    local text = getText("IGUI_BU_ControllerTip", BU.percent(settings.start), BU.percent(settings.stop), quiet)
    if (self.panel.tier or 1) >= BU.SMART_TIER then text = text .. " <LINE> <LINE> " .. getText("IGUI_BU_ProtectTip", BU.percent(settings.protect)) end
    return text
end

-- The charge controller's menu: each setting from its choices.
function ISBUPanelWindow:controllerMenu()
    local panel, playerObj = self.panel, self.playerObj
    local settings = Energy.settings(panel)
    local menu = ISContextMenu.get(playerObj:getPlayerNum(), getMouseX(), getMouseY())
    local function send(changes)
        local args = { panel = panel.id }
        for name, value in pairs(changes) do args[name] = value end
        Sync.send(playerObj, "setController", args)
    end
    local function submenu(title, choices, current, label, changes)
        local sub = ISContextMenu:getNew(menu)
        menu:addSubMenu(menu:addOption(title, nil, nil), sub)
        for _, choice in ipairs(choices) do
            local option = sub:addOption(label(choice), nil, function() send(changes(choice)) end)
            if current(choice) then option.notAvailable = true end
        end
        return sub
    end
    local percentLabel = BU.percent
    submenu(getText("IGUI_BU_SetStart", BU.percent(settings.start)), Energy.CHOICES.start, function(v) return v == settings.start or v >= settings.stop end,
        percentLabel, function(v) return { start = v } end)
    submenu(getText("IGUI_BU_SetStop", BU.percent(settings.stop)), Energy.CHOICES.stop, function(v) return v == settings.stop or v <= settings.start end,
        percentLabel, function(v) return { stop = v } end)
    submenu(getText("IGUI_BU_SetQuiet"), Energy.CHOICES.quiet,
        function(pair) return pair[1] == settings.quietFrom and pair[2] == settings.quietTo end,
        function(pair)
            if pair[1] == pair[2] then return getText("IGUI_BU_QuietNone") end
            return getText("IGUI_BU_QuietHours", pair[1], pair[2])
        end,
        function(pair) return { quietFrom = pair[1], quietTo = pair[2] } end)
    if (panel.tier or 1) >= BU.SMART_TIER then
        submenu(getText("IGUI_BU_SetProtect", BU.percent(settings.protect)), Energy.CHOICES.protect, function(v) return v == settings.protect end,
            percentLabel, function(v) return { protect = v } end)
    end
end
