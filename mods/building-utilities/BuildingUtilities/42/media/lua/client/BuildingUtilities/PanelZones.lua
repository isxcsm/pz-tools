-- The breaker box window and its plan: what the plan shows, zones edited on it, its menus and the range shown on
-- the ground.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Store, Panels, Networks, Sync, Geometry, Energy, Units, Links = BU.Store, BU.Panels, BU.Networks, BU.Sync,
    BU.Geometry, BU.Energy, BU.Units, BU.Links
local Ui = BU.PanelUi
local load2, deviceObjects, outline, unoutline = Ui.load2, Ui.deviceObjects, Ui.outline,
    Ui.unoutline
local PanelWindow = BU.PanelWindow

-- What the generators' noise rings are of, to tell when one changed.
local function noiseKey(noises)
    local parts = {}
    for _, noise in ipairs(noises) do
        parts[#parts + 1] = noise.x .. "," .. noise.y .. "," .. noise.z .. "," .. noise.radius .. (noise.running and "+" or "-")
    end
    return table.concat(parts, "|")
end

-- The plan.

function ISBUPanelWindow:updatePlan()
    if not self.plan then return end
    local utility = self:activeUtility()
    local view = self.views[utility]
    if not view then return end
    self.planUtility = utility
    local panel = self.panel
    local rooms = {}
    for _, room in ipairs(self.rooms or {}) do
        rooms[#rooms + 1] = { id = room.id, title = self.titles[room.id] or BU.roomName(room.name or ""), level = room.level,
            rects = room.rects, building = room.building }
    end
    local devices = {}
    local hide = PanelWindow.options.hideUnwired
    -- Water with more than one pipe: each thing in its pipe's colour (a fixture ringed in it), and the lines too.
    local pipes = utility == "water" and BU.Water.shown(panel)
    for _, device in ipairs(view.devices) do
        local entry = device.entry
        if not (hide and not device.wired) then
            devices[#devices + 1] = { key = device.key, x = entry.x, y = entry.y, z = entry.z, roomId = device.roomId,
                inside = device.inside, state = device.state, wired = device.wired, held = device.held, cut = device.cut,
                power = device.power, utility = utility, name = view.names[device.key] or "",
                status = view.status[device.key], fresh = view.fresh[device.key],
                ref = not device.inside and device.wired and Links.deviceRef(device.key) or nil,
                ring = pipes and device.state == "on" and BU.Water.colour(device.pipe) or nil }
        end
    end
    local producers = {}
    local state = view.state
    for index, at in ipairs(panel[utility].producers) do
        local inUse = PanelWindow.producerInUse(state, at)
        local ref = Links.producerRef(at.x, at.y, at.z)
        local cut = Links.reason(panel, ref) ~= nil
        local colour = pipes and BU.Water.colour(BU.Water.producerPipe(panel, at)) or nil
        producers[#producers + 1] = { x = at.x, y = at.y, z = at.z, inUse = inUse and not cut, colour = colour, cut = cut,
            ref = ref, key = ISBUPanelWindow.squareKey(at), text = (view.producerText[index] or "") .. (cut and "  " .. getText("IGUI_BU_LineNotSupplied") or "") }
    end
    -- The units: power's as its source, water's each on its own (in its inlet's colour, a pump in its outlet's); one
    -- whose line supplies nothing grey.
    local inUse = utility == "power" and Energy.inUse(state)
    for _, unit in ipairs(Store.unitList(nil, panel.id)) do
        if not BU.RELAY_KINDS[unit.kind] and Units.utility(unit) == utility and BU.enabled(unit.kind) then
            local ref = Links.unitRef(unit)
            local live = Links.live(panel, ref)
            local text = Units.name(unit)
            if not live then text = text .. "  " .. getText("IGUI_BU_LineNotSupplied")
            elseif utility == "water" then text = text .. "  " .. self:waterUnitStatus(unit) end
            local colour
            if pipes then
                local inlet, outlet = BU.Water.unitPipes(panel, unit)
                colour = BU.Water.colour(inlet or outlet)
            end
            -- power's units share their kind's source row
            local key = utility == "power" and ISBUPanelWindow.sourceKey(unit.kind) or ISBUPanelWindow.squareKey(unit)
            producers[#producers + 1] = { x = unit.x, y = unit.y, z = unit.z, unit = unit.kind, colour = colour, ref = ref,
                key = key, cut = not live, inUse = live and (inUse or unit.running == true), text = text }
        end
    end
    -- What it could take and no box has: grey, as devices not connected are.
    if not hide then
        for _, at in ipairs(view.unwired or {}) do
            local name = at.unit and Units.name(at.unit) or utility == "water" and getText("IGUI_BU_Legend_tank")
                or BU.displayName(at.x, at.y, at.z, at.sprite)
            producers[#producers + 1] = { x = at.x, y = at.y, z = at.z, unwired = true, unit = at.unit and at.unit.kind,
                key = ISBUPanelWindow.squareKey(at), text = name .. "  " .. getText("IGUI_BU_NotWired") }
        end
    end
    -- The relays of this utility, and the lines: each from its thing to what it hangs on (its wall square, a relay, a
    -- device), grey where it supplies nothing.
    local relays, liveRelays = {}, {}
    for _, unit in ipairs(Panels.relaysOf(panel)) do
        if Units.utility(unit) == utility then
            local ref = Links.unitRef(unit)
            local live = Links.live(panel, ref)
            relays[#relays + 1] = { x = unit.x, y = unit.y, z = unit.z, kind = unit.kind, ref = ref, cut = not live,
                key = ISBUPanelWindow.squareKey(unit),
                text = Units.name(unit) .. "  " .. (live and self:relayRooms(unit) or getText("IGUI_BU_LineNotSupplied")) }
            if live then liveRelays[#liveRelays + 1] = { x = unit.x, y = unit.y, z = unit.z } end
        end
    end
    local lines = {}
    for _, line in ipairs(Links.of(panel)) do
        if line.utility == utility then
            local tx, ty, tz = Links.endOf(line)
            if tx then
                local pipe, outlet
                if pipes then pipe, outlet = BU.Water.linePipes(panel, line) end
                lines[#lines + 1] = { ref = line.ref, x1 = line.x, y1 = line.y, z1 = line.z, x2 = tx, y2 = ty, z2 = tz,
                    way = Links.way(line), live = Links.live(panel, line.ref), colour = pipe and BU.Water.colour(pipe) or nil,
                    colour2 = outlet and BU.Water.colour(outlet) or nil }
            end
        end
    end
    -- The zones of the rooms: this box's, the free rooms and other boxes'; a room it cannot take says why.
    local zone, inZone = {}, 0
    for id, entry in pairs(Panels.zoneStates(panel, self.building, self.rooms or {})) do
        zone[id] = { state = entry.state, owner = entry.owner and Panels.name(entry.owner) }
        if entry.state == "mine" then inZone = inZone + 1 end
    end
    local farLevels, takeable = {}, {}
    for _, room in ipairs(self.rooms or {}) do
        local entry = zone[room.id]
        if entry.state == "far" then
            entry.note = self:farNote(room)
            if farLevels[room.level] == nil then farLevels[room.level] = true end
        else
            takeable[room.level] = true
        end
    end
    for level in pairs(takeable) do farLevels[level] = nil end
    local editable = #(self.rooms or {}) > 0
    if not editable then self.zoneEditing = false end
    -- The range, while the window shows it in the world: from the zone's rooms (an outdoor box's square) and its relays.
    local ranges, tier = nil, panel.tier or 1
    local rangeKey = tier .. "|" .. Store.linkVersion() .. "|" .. tostring(panel.zone) .. "|"
        .. Panels.attachedSize(self.building)
    if self.rangeShown then
        ranges = { reach = BU.connectRange(tier), relayReach = BU.relayRange(), relays = liveRelays }
        if utility == "power" then
            ranges.noise = self:generatorNoises()
            rangeKey = rangeKey .. "|" .. noiseKey(ranges.noise)
        end
    end
    -- The boxes whose zones can have these rooms (this one alone where there are none).
    local boxes, seenBox = {}, {}
    local claimers = { panel }
    for _, building in ipairs(Panels.zoneBuildings(panel)) do
        for _, other in ipairs(Panels.ofBuilding(building.key)) do claimers[#claimers + 1] = other end
    end
    for _, other in ipairs(claimers) do
        if not seenBox[other.id] then
            seenBox[other.id] = true
            boxes[#boxes + 1] = { x = other.x, y = other.y, z = other.z, own = other.id == panel.id, text = Panels.name(other) }
        end
    end
    self.plan:setData({ utility = utility, supplied = view.state and view.state.supplied, rooms = rooms, devices = devices,
        producers = producers, relays = relays, lines = lines, box = { x = panel.x, y = panel.y, z = panel.z },
        outdoor = panel.outdoor == true, boxes = boxes, filter = self.roomFilter,
        zone = zone, zoneEditable = editable, zoneEdit = self.zoneEditing == true, zoneNote = getText("IGUI_BU_ZoneNote", inZone),
        farLevels = farLevels, waterSupply = utility == "water" and self.waterSupply and self.waterSupply.byLevel or nil,
        ranges = ranges, rangeKey = rangeKey })
end

-- What a relay standing in a building takes there, for its row: how many rooms of its box's zone are about it; nothing
-- outside.
function ISBUPanelWindow:relayRooms(unit)
    local building = Panels.buildingAt(unit.x, unit.y, unit.z)
    if not building then return "" end
    local count = 0
    for _, room in ipairs(Panels.zoneRooms(self.panel)) do
        if room.building == building.key and math.abs(room.level - unit.z) <= BU.RELAY_FLOORS then count = count + 1 end
    end
    return getText("IGUI_BU_RelayRooms", count)
end

-- The rows of a utility's lines, after its producers: units whose line supplies nothing (dim, the mouse over one tells
-- why), the relays under a header with how many the box has of what its tier allows (of both utilities, as the tier
-- counts them), and how many branches supply nothing, a click showing the next on the plan.
function ISBUPanelWindow:lineRows(add, utility)
    local panel = self.panel
    -- (water's are under their rooms, ISBUPanelWindow:waterPlaced)
    for _, unit in ipairs(utility == "water" and {} or Store.unitList(nil, panel.id)) do
        local ref = Links.unitRef(unit)
        if not BU.RELAY_KINDS[unit.kind] and Units.utility(unit) == utility and BU.enabled(unit.kind)
                and not Links.live(panel, ref) then
            add({ kind = "producer", unwired = true, at = unit, water = utility == "water",
                text = getText("IGUI_BU_CutUnitRow", Units.name(unit), Panels.where(panel, unit.x, unit.y, unit.z)) },
                Links.reasonText(panel, ref))
        end
    end
    local dead = {}
    for _, line in ipairs(Links.deadHeads(panel)) do
        if line.utility == utility then dead[#dead + 1] = line end
    end
    self.deadLines = self.deadLines or {}
    self.deadLines[utility] = dead
    if #dead > 0 then
        add({ kind = "note", dead = true, text = getText("IGUI_BU_DeadBranches", #dead) }, getText("IGUI_BU_DeadBranchesTip"))
    end
    local relays, limit = Panels.relaysOf(panel), BU.relayLimit(panel.tier)
    if #relays == 0 and limit == 0 then return end
    -- this utility's relays, counted with the other's: they share the tier's limit
    add({ kind = "header", text = getText("IGUI_BU_Relays_" .. utility), right = getText("IGUI_BU_RelaysUsed", #relays, limit) },
        getText("IGUI_BU_RelaysUsedTip_" .. utility))
    local any = false
    for _, unit in ipairs(relays) do
        if Units.utility(unit) == utility then
            any = true
            local ref = Links.unitRef(unit)
            local live = Links.live(panel, ref)
            add({ kind = "producer", relay = unit, water = true, unwired = not live,
                text = getText("IGUI_BU_RelayRow", Units.name(unit), Panels.where(panel, unit.x, unit.y, unit.z),
                    live and self:relayRooms(unit) or getText("IGUI_BU_LineNotSupplied")) },
                live and getText("IGUI_BU_RelayRowTip") or Links.reasonText(panel, ref))
        end
    end
    if not any then add({ kind = "note", text = getText("IGUI_BU_NoRelays_" .. utility) }) end
end

-- The next branch that supplies nothing, shown on the plan (a click on the list's count goes round them).
function ISBUPanelWindow:showDead(utility)
    local dead = self.deadLines and self.deadLines[utility] or {}
    if #dead == 0 then return end
    self.deadIndex = (self.deadIndex or 0) + 1
    if self.deadIndex > #dead then self.deadIndex = 1 end
    local line = dead[self.deadIndex]
    self:showOnPlan(line.x, line.y, line.z)
end

-- A square shown on the plan: its floor, zoomed in on it, marked a moment.
function ISBUPanelWindow:showOnPlan(x, y, z)
    if self.plan then self.plan:focusOn(x, y, z) end
end

-- Zones. The plan shows them, and while they are edited a click there takes a room in or out of this box's.
function ISBUPanelWindow:setZoneEditing(on)
    self.zoneEditing = on
    if on then self.roomFilter = nil end
    self:updatePlan()
end

-- The room ids of this box's zone now, as a set.
function ISBUPanelWindow:zoneSet()
    local result = {}
    for _, room in ipairs(self.rooms or {}) do
        if Panels.inZone(self.panel, room.id) then result[room.id] = true end
    end
    return result
end

-- The zone asked for, as a set of room ids, sent as the rooms' keys; one empty is refused here as on the server.
function ISBUPanelWindow:sendZone(set)
    local keys = {}
    for _, room in ipairs(self.rooms or {}) do
        if set[room.id] then keys[#keys + 1] = room.key end
    end
    if #keys == 0 then
        HaloTextHelper.addBadText(self.playerObj, getText("IGUI_BU_ZoneEmpty"))
        return
    end
    table.sort(keys)
    Sync.send(self.playerObj, "setZone", { panel = self.panel.id, rooms = keys })
end

-- Why a room is not one this box's zone can take: in its own building, the floors it can, that an upgrade reaches
-- more (below the top tier), and that a box on another floor takes the rest; in another, how many floors about its
-- relay there it takes.
function ISBUPanelWindow:farNote(room)
    if not self.building or room.building ~= self.building.key then
        return getText("IGUI_BU_ZoneFarRelay", BU.RELAY_FLOORS)
    end
    local low, high = Panels.floorsInReach(self.panel, self.building)
    local text = getText("IGUI_BU_ZoneFar", BU.floorName(low), BU.floorName(high))
    if (self.panel.tier or 1) < BU.TIERS then text = text .. " " .. getText("IGUI_BU_ZoneFarUpgrade") end
    return text .. " " .. getText("IGUI_BU_ZoneFarSub")
end

-- A room of the window's rooms by its id, or nil.
function ISBUPanelWindow:roomOf(id)
    for _, room in ipairs(self.rooms or {}) do
        if room.id == id then return room end
    end
    return nil
end

function ISBUPanelWindow:toggleZoneRoom(id)
    local states = Panels.zoneStates(self.panel, self.building, self.rooms or {})
    local entry = states[id]
    if entry and entry.state == "far" then HaloTextHelper.addBadText(self.playerObj, self:farNote(self:roomOf(id))) end
    if not entry or entry.state == "taken" or entry.state == "far" then return end
    local set = self:zoneSet()
    set[id] = entry.state == "free" or nil
    self:sendZone(set)
end

-- The zone's menu, for a floor (of every building the plan shows): its free rooms in, its rooms out, only it; the free
-- rooms of every floor the box reaches in its own building, where it does not reach them all; or the whole building.
-- A floor it can take no room of says why.
function ISBUPanelWindow:zoneMenu(level)
    local states = Panels.zoneStates(self.panel, self.building, self.rooms or {})
    local menu = ISContextMenu.get(self.playerObj:getPlayerNum(), getMouseX(), getMouseY())
    menu:addOption(BU.floorName(level), nil, nil).isDisabled = true
    local function floorSet(keepOthers, take)
        local set = keepOthers and self:zoneSet() or {}
        for _, room in ipairs(self.rooms or {}) do
            local state = states[room.id].state
            if room.level == level and state ~= "taken" and state ~= "far" then set[room.id] = take or nil end
        end
        return set
    end
    local far
    for _, room in ipairs(self.rooms or {}) do
        if room.level == level then
            if states[room.id].state == "far" then far = far or room else far = false; break end
        end
    end
    local function taking(option)
        if not far then return end
        option.notAvailable = true
        local tip = ISToolTip:new()
        tip:initialise()
        tip:setVisible(false)
        tip.description = self:farNote(far)
        option.toolTip = tip
    end
    taking(menu:addOption(getText("IGUI_BU_Menu_ZoneFloorAdd"), self, function(window) window:sendZone(floorSet(true, true)) end))
    menu:addOption(getText("IGUI_BU_Menu_ZoneFloorRemove"), self, function(window) window:sendZone(floorSet(true, false)) end)
    taking(menu:addOption(getText("IGUI_BU_Menu_ZoneFloorOnly"), self, function(window) window:sendZone(floorSet(false, true)) end))
    if not self.building then return end
    local low, high = Panels.floorsInReach(self.panel, self.building)
    if low > self.building.minLevel or high < self.building.maxLevel then
        menu:addOption(getText("IGUI_BU_Menu_ZoneReach", BU.floorName(low), BU.floorName(high)), self, function(window)
            local set = window:zoneSet()
            for _, room in ipairs(window.rooms or {}) do
                if states[room.id].state == "free" and room.building == window.building.key then set[room.id] = true end
            end
            window:sendZone(set)
        end)
    elseif self.panel.zone and Panels.canTakeWhole(self.panel, self.building) then
        menu:addOption(getText("IGUI_BU_Menu_ZoneWhole"), self, function(window)
            Sync.send(window.playerObj, "setZone", { panel = window.panel.id, whole = true })
        end)
    end
end

-- A room of the plan in words: its name and what its devices draw.
function ISBUPanelWindow:roomStatus(id)
    local view = self.views[self:activeUtility()]
    local totals = view and view.totals[id or ""]
    local title = totals and totals.title or (self.titles and self.titles[id]) or ""
    if not totals then return title end
    if self:activeUtility() == "power" then return title .. "  " .. load2(totals.total) end
    return title .. "  " .. totals.on .. " / " .. totals.count
end

-- What a thing is known by in the list and on the plan alike, so that hovering, clicking and choosing go one way for
-- all: a device's key; a producer's, unit's or relay's square; power's units by their kind's source row (the solar
-- panels share one). A row carries its key (ISBUPanelWindow:fill), a dot or square of the plan its own.
function ISBUPanelWindow.squareKey(at) return at.x .. "," .. at.y .. "," .. at.z end
function ISBUPanelWindow.sourceKey(kind) return "source|" .. kind end
function ISBUPanelWindow.rowKey(row)
    if row.device then return row.device.key end
    if row.source then return ISBUPanelWindow.sourceKey(row.source) end
    local at = row.relay or row.unit or row.at
    return at and at.x and ISBUPanelWindow.squareKey(at) or nil
end

-- The thing under the mouse on the plan, outlined in the world: a device, else what its row stands for.
function ISBUPanelWindow:outlineThing(key)
    local playerNum = self.playerObj:getPlayerNum()
    unoutline(playerNum, self.planOutlined)
    self.planOutlined = {}
    if not key then return end
    local utility = self:activeUtility()
    local view = self.views[utility]
    for _, device in ipairs(view and view.devices or {}) do
        if device.key == key then
            outline(playerNum, deviceObjects(device), getCore():getGoodHighlitedColor(), self.planOutlined)
            return
        end
    end
    for _, item in ipairs(self.lists[utility].items) do
        if item.item.key == key then
            outline(playerNum, Ui.rowObjects(item.item), getCore():getGoodHighlitedColor(), self.planOutlined)
            return
        end
    end
end

-- What a mark of the pipes' schematic stands for, outlined in the world (rows as Ui.rowObjects takes them: { at },
-- { unit }); none for an empty list.
function ISBUPanelWindow:outlineRows(rows)
    local playerNum = self.playerObj:getPlayerNum()
    unoutline(playerNum, self.planOutlined)
    self.planOutlined = {}
    if #rows == 0 then return end
    outline(playerNum, Ui.rowObjects({ members = rows }), getCore():getGoodHighlitedColor(), self.planOutlined)
end

-- A thing clicked on the plan (or "show in list"): its row, chosen and shown. A device's room and floor unfold and a
-- filter that hides it lifts; a row hidden as not connected is listed again.
function ISBUPanelWindow:showThing(key)
    local utility = self:activeUtility()
    local view = self.views[utility]
    for _, device in ipairs(view and view.devices or {}) do
        local roomId, level = nil, nil
        if device.key == key then roomId, level = Ui.groupOf(device) end
        if roomId then
            PanelWindow.folded[self.panel.id .. "|" .. utility .. "|" .. roomId] = nil
            PanelWindow.folded[self.panel.id .. "|" .. utility .. "|floor|" .. (level or device.entry.z)] = false
            if self.roomFilter and self.roomFilter ~= roomId then self.roomFilter = nil end
            if PanelWindow.options.activeOnly then PanelWindow.options.activeOnly = false; self:placeOptions() end
            self:redraw()
        end
    end
    if self:chooseRow(utility, key) or not PanelWindow.options.hideUnwired then return end
    PanelWindow.options.hideUnwired = false
    self:placeOptions()
    self:redraw()
    self:updatePlan()
    self:chooseRow(utility, key)
end

-- A row chosen: selected, scrolled to and flashed (from the plan); it stays selected as the list fills anew
-- (ISBUPanelWindow:fill). Whether the list has it.
function ISBUPanelWindow:chooseRow(utility, key, quiet)
    self.chosenRow = key and { utility = utility, key = key } or nil
    local list = self.lists[utility]
    list.selected = -1
    if not key then return false end
    for index, item in ipairs(list.items) do
        if item.item.key == key then
            list.selected = index
            if not quiet then
                list:ensureVisible(index)
                Ui.UI.placeFlash(list, index)
            end
            return true
        end
    end
    return false
end

-- A room clicked on the plan: the list shows only it; nil shows them all again.
function ISBUPanelWindow:filterRoom(id)
    self.roomFilter = id
    self:redraw()
    self:updatePlan()
end

-- The menu of a dot right-clicked on the plan: what its row offers.
function ISBUPanelWindow:deviceMenu(key)
    local utility = self:activeUtility()
    local view = self.views[utility]
    local device
    for _, candidate in ipairs(view and view.devices or {}) do if candidate.key == key then device = candidate end end
    if not device then return end
    local panel, playerObj = self.panel, self.playerObj
    local menu = ISContextMenu.get(playerObj:getPlayerNum(), getMouseX(), getMouseY())
    menu:addOption(view.names[key] or "", nil, nil).isDisabled = true
    if device.state == "other" or not device.wired then
        menu:addOption(view.status[key] or "", nil, nil).isDisabled = true
    else
        local on = device.state == "on"
        if Panels.cuts(panel) then
            menu:addOption(getText(on and "IGUI_BU_Menu_Disconnect" or "IGUI_BU_Menu_Connect"), self, ISBUPanelWindow.switchDevice, utility, device)
        end
        if on and utility == "power" and (panel.tier or 1) >= BU.TIMER_TIER then
            local timer = menu:addOption(getText("IGUI_BU_Menu_Timer"), nil, nil)
            local sub = ISContextMenu:getNew(menu)
            menu:addSubMenu(timer, sub)
            for _, schedule in ipairs(BU.SCHEDULES) do
                local option = sub:addOption(getText("IGUI_BU_Schedule_" .. schedule), playerObj, Sync.send, "setSchedule",
                    { panel = panel.id, key = key, schedule = schedule })
                if schedule == device.schedule then option.isDisabled = true end
            end
        end
    end
    menu:addOption(getText("IGUI_BU_Menu_ShowInList"), self, ISBUPanelWindow.showThing, key)
end

-- The menu of a room right-clicked on the plan: all of it on or off, or only it in the list.
function ISBUPanelWindow:roomMenu(id)
    local utility = self:activeUtility()
    local view = self.views[utility]
    local totals = view and view.totals[id]
    local playerObj = self.playerObj
    local menu = ISContextMenu.get(playerObj:getPlayerNum(), getMouseX(), getMouseY())
    menu:addOption(totals and totals.title or (self.titles[id] or ""), nil, nil).isDisabled = true
    if totals and totals.count > 0 and Panels.cuts(self.panel) then
        local send = function(on) Sync.send(playerObj, "setRoomInside", { panel = self.panel.id, utility = utility, room = id, on = on }) end
        if totals.on < totals.count then menu:addOption(getText("IGUI_BU_Menu_RoomOn"), true, send) end
        if totals.on > 0 then menu:addOption(getText("IGUI_BU_Menu_RoomOff"), false, send) end
    end
    if self.roomFilter == id then
        menu:addOption(getText("IGUI_BU_Menu_AllRooms"), self, ISBUPanelWindow.filterRoom, nil)
    else
        menu:addOption(getText("IGUI_BU_Menu_OnlyRoom"), self, ISBUPanelWindow.filterRoom, id)
    end
end

-- The box's generators and how far each is heard (Panels.generatorNoise): { x, y, z, radius, running }. None while
-- power is off (BU.enabled).
function ISBUPanelWindow:generatorNoises()
    local result = {}
    local panel = self.panel
    if not BU.enabled("power") then return result end
    local state = Networks.state(panel, "power")
    for _, at in ipairs(panel.power.producers) do
        local inUse = PanelWindow.producerInUse(state, at)
        local radius, running = Panels.generatorNoise(at.x, at.y, at.z, inUse)
        result[#result + 1] = { x = at.x, y = at.y, z = at.z, radius = radius, running = running }
    end
    return result
end

-- The range: on the ground around the zone's rooms (an outdoor box's square), where devices outside, producers and
-- units reach from a wall (blue), and around each relay of the box that supplies, on its floor, where a line from it
-- reaches; producers within reach that are no panel's are outlined. Around each of the box's generators, on its floor,
-- how far zombies hear it (red, dim while it is off).
-- Rows of the range's squares outlined each frame, until this many milliseconds went in it: the world shows the range
-- over a few frames instead of stopping for it.
local RANGE_BUDGET_MS = 8

function ISBUPanelWindow:showRange(on)
    local playerNum = self.playerObj:getPlayerNum()
    unoutline(playerNum, self.rangeObjects)
    self.rangeObjects = {}
    self.rangeShown = on
    self.rangeJob = nil
    if not on then return end
    local noises = self:generatorNoises()
    self.rangeNoiseKey = noiseKey(noises)
    local panel = self.panel
    local rooms = Panels.zoneRooms(panel)
    local ground, all = Geometry.roomRects(rooms, 0)
    if panel.outdoor then ground, all = { { x = panel.x, y = panel.y, w = 1, h = 1 } }, {} end
    if #ground == 0 and #all == 0 then return end
    -- Devices outside, producers and units join by the zone's rooms of their own floor, the ground here (the whole
    -- outline where it has none): one ring, the edge of the plan's area (Geometry.reach).
    local blue = ColorInfo.new(0.3, 0.6, 1, 1)
    local rings = { { area = Geometry.reach(#ground > 0 and ground or all, BU.connectRange(panel.tier)), colour = blue } }
    for _, unit in ipairs(Panels.relaysOf(panel)) do
        if Links.live(panel, Links.unitRef(unit)) then
            rings[#rings + 1] = { area = Geometry.reach({ { x = unit.x, y = unit.y, w = 1, h = 1 } }, BU.relayRange()),
                z = unit.z, colour = blue }
        end
    end
    for _, noise in ipairs(noises) do
        rings[#rings + 1] = { area = Geometry.disc(noise.x, noise.y, noise.radius), z = noise.z,
            colour = noise.running and ColorInfo.new(1, 0.35, 0.3, 1) or ColorInfo.new(0.6, 0.3, 0.3, 1) }
    end
    -- The squares to go over: the box around every ring's area.
    local minX, minY, maxX, maxY
    for _, ring in ipairs(rings) do
        local area = ring.area
        minX, minY = math.min(minX or area.minX, area.minX), math.min(minY or area.minY, area.minY)
        maxX = math.max(maxX or area.minX + area.w - 1, area.minX + area.w - 1)
        maxY = math.max(maxY or area.minY + area.h - 1, area.minY + area.h - 1)
    end
    -- Producers inside the building are not looked for.
    self.rangeJob = { rings = rings, producers = rings[1].area, inside = #all > 0 and Geometry.reach(all, 0) or nil,
        minX = minX, maxX = maxX, y = minY, maxY = maxY }
    self:stepRange()
end

-- Outlines the range's next rows, as many as the frame's budget allows (ISBUPanelWindow.prerender calls it): each
-- ring's edge on its floor (the ground but for a generator's), and the producers not connected yet within reach.
function ISBUPanelWindow:stepRange()
    local job = self.rangeJob
    local playerNum = self.playerObj:getPlayerNum()
    local producerColour = getCore():getGoodHighlitedColor()
    local cell = getCell()
    local started = getTimestampMs()
    while job.y <= job.maxY and getTimestampMs() - started < RANGE_BUDGET_MS do
        local y = job.y
        job.y = y + 1
        for x = job.minX, job.maxX do
            for _, ring in ipairs(job.rings) do
                if Geometry.onEdge(ring.area, x, y) then
                    local square = cell:getGridSquare(x, y, ring.z or 0)
                    local floor = square and square:getFloor()
                    if floor then outline(playerNum, { floor }, ring.colour, self.rangeObjects) end
                end
            end
            if Geometry.reached(job.producers, x, y) and not (job.inside and Geometry.reached(job.inside, x, y)) then
                local utility, object = Panels.producerOn(cell:getGridSquare(x, y, 0))
                if utility and not Store.producerOwner(x, y, 0) then outline(playerNum, { object }, producerColour, self.rangeObjects) end
            end
        end
    end
    if job.y > job.maxY then self.rangeJob = nil end
end

-- The range shown again when a generator's noise changed (it started or stopped, came or went); the window's
-- refresh calls it.
function ISBUPanelWindow:checkRange()
    if self.rangeShown and noiseKey(self:generatorNoises()) ~= self.rangeNoiseKey then self:showRange(true) end
end

function ISBUPanelWindow:onRange()
    self:showRange(not self.rangeShown)
    self:updatePlan()
end
