-- The breaker box window and its plan: what the plan shows, zones edited on it, its menus and the range shown on
-- the ground.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Store, Panels, Networks, Sync, Geometry, Energy, Units = BU.Store, BU.Panels, BU.Networks, BU.Sync, BU.Geometry,
    BU.Energy, BU.Units
local Ui = BU.PanelUi
local OUTSIDE, load2, deviceObjects, outline, unoutline = Ui.OUTSIDE, Ui.load2, Ui.deviceObjects, Ui.outline,
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
        rooms[#rooms + 1] = { id = room.id, title = self.titles[room.id] or BU.roomName(room.name or ""), level = room.level, rects = room.rects }
    end
    local devices = {}
    local hide = PanelWindow.options.hideUnwired
    for _, device in ipairs(view.devices) do
        local entry = device.entry
        if not (hide and not device.wired) then
            devices[#devices + 1] = { key = device.key, x = entry.x, y = entry.y, z = entry.z, roomId = device.roomId,
                inside = device.inside, state = device.state, wired = device.wired, held = device.held,
                power = device.power, utility = utility, name = view.names[device.key] or "",
                status = view.status[device.key], fresh = view.fresh[device.key] }
        end
    end
    local producers = {}
    if not panel.parent then
        local state = view.state
        for index, at in ipairs(panel[utility].producers) do
            local inUse = PanelWindow.producerInUse(state, at)
            -- A tank in its group's colour, with more than one group.
            local colour = utility == "water" and #BU.Water.groups(panel) > 1
                and PanelWindow.groupColour(panel, BU.Water.producerGroup(at)) or nil
            producers[#producers + 1] = { x = at.x, y = at.y, z = at.z, inUse = inUse, colour = colour,
                text = view.producerText[index] }
        end
        -- The units: power's as its source, water's each on its own (in its group's colour, with more than one).
        local inUse = utility == "power" and Energy.inUse(state)
        for _, unit in ipairs(Units.of(panel.id, utility)) do
            local text = Units.name(unit)
            if utility == "water" then text = text .. "  " .. self:waterUnitStatus(unit) end
            local colour = utility == "water" and #BU.Water.groups(panel) > 1
                and PanelWindow.groupColour(panel, BU.WaterUnits.group(unit)) or nil
            producers[#producers + 1] = { x = unit.x, y = unit.y, z = unit.z, inUse = inUse or unit.running == true or unit.boosting == true,
                unit = unit.kind, colour = colour, text = text }
        end
        -- What it could take and no box has: grey, as devices not connected are.
        if not hide then
            for _, at in ipairs(view.unwired or {}) do
                local name = at.unit and Units.name(at.unit) or BU.displayName(at.x, at.y, at.z, at.sprite)
                producers[#producers + 1] = { x = at.x, y = at.y, z = at.z, unwired = true, unit = at.unit and at.unit.kind,
                    text = name .. "  " .. getText("IGUI_BU_NotWired") }
            end
        end
    end
    -- The zones of the building: this box's, the free rooms and other boxes'.
    local zone, inZone = {}, 0
    for id, entry in pairs(Panels.zoneStates(panel, self.building, self.rooms or {})) do
        zone[id] = { state = entry.state, owner = entry.owner and Panels.name(entry.owner) }
        if entry.state == "mine" then inZone = inZone + 1 end
    end
    local editable = self.building ~= nil
    if not editable then self.zoneEditing = false end
    -- The range, while the window shows it in the world.
    local ranges, tier = nil, panel.tier or 1
    local rangeKey = (self.building and self.building.key or "") .. "|" .. tier .. "|" .. Panels.attachedSize(self.building)
    if self.rangeShown then
        ranges = { reach = BU.connectRange(tier) }
        if utility == "power" then
            ranges.noise = self:generatorNoises()
            rangeKey = rangeKey .. "|" .. noiseKey(ranges.noise)
        end
    end
    -- The boxes of the building (this one alone where it stands in none).
    local boxes, subBoxes = {}, false
    for _, other in ipairs(self.building and Panels.ofBuilding(self.building.key) or { panel }) do
        boxes[#boxes + 1] = { x = other.x, y = other.y, z = other.z, sub = other.parent ~= nil, own = other.id == panel.id,
            text = Panels.name(other) }
        subBoxes = subBoxes or other.parent ~= nil
    end
    self.plan:setData({ utility = utility, supplied = view.state and view.state.supplied, rooms = rooms, devices = devices,
        producers = producers, box = { x = panel.x, y = panel.y, z = panel.z }, boxes = boxes, subBoxes = subBoxes,
        filter = self.roomFilter,
        zone = zone, zoneEditable = editable, zoneEdit = self.zoneEditing == true, zoneNote = getText("IGUI_BU_ZoneNote", inZone),
        farNote = self.building and self:farNote() or nil,
        reached = self.building and { Panels.floorsInReach(panel, self.building) } or nil,
        waterSupply = utility == "water" and self.waterSupply and self.waterSupply.byLevel or nil,
        ranges = ranges, rangeKey = rangeKey })
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

-- The zone asked for, as a set of room ids; one empty is refused here as on the server.
function ISBUPanelWindow:sendZone(set)
    local ids = {}
    for id in pairs(set) do ids[#ids + 1] = id end
    if #ids == 0 then
        HaloTextHelper.addBadText(self.playerObj, getText("IGUI_BU_ZoneEmpty"))
        return
    end
    table.sort(ids)
    Sync.send(self.playerObj, "setZone", { panel = self.panel.id, rooms = ids })
end

-- Why a floor is not one this box's zone can take: the floors it can, that an upgrade reaches more (below the top
-- tier), and that a box on another floor takes the rest.
function ISBUPanelWindow:farNote()
    local low, high = Panels.floorsInReach(self.panel, self.building)
    local text = getText("IGUI_BU_ZoneFar", BU.floorName(low), BU.floorName(high))
    if (self.panel.tier or 1) < BU.TIERS then text = text .. " " .. getText("IGUI_BU_ZoneFarUpgrade") end
    return text .. " " .. getText("IGUI_BU_ZoneFarSub")
end

function ISBUPanelWindow:toggleZoneRoom(id)
    local states = Panels.zoneStates(self.panel, self.building, self.rooms or {})
    local entry = states[id]
    if entry and entry.state == "far" then HaloTextHelper.addBadText(self.playerObj, self:farNote()) end
    if not entry or entry.state == "taken" or entry.state == "far" then return end
    local set = self:zoneSet()
    set[id] = entry.state == "free" or nil
    self:sendZone(set)
end

-- The zone's menu, for a floor: its free rooms in, its rooms out, only it; the free rooms of every floor the box
-- reaches, where it does not reach them all; or the whole building. A floor it does not reach says so.
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
    local far = not Panels.reachesLevel(self.panel, level)
    local function taking(option)
        if not far then return end
        option.notAvailable = true
        local tip = ISToolTip:new()
        tip:initialise()
        tip:setVisible(false)
        tip.description = self:farNote()
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
                if states[room.id].state == "free" then set[room.id] = true end
            end
            window:sendZone(set)
        end)
    elseif self.panel.rooms and Panels.canTakeWhole(self.panel, self.building) then
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

-- The device under the mouse on the plan, outlined in the world.
function ISBUPanelWindow:outlineDevice(key)
    local playerNum = self.playerObj:getPlayerNum()
    unoutline(playerNum, self.planOutlined)
    self.planOutlined = {}
    if not key then return end
    local view = self.views[self:activeUtility()]
    for _, device in ipairs(view and view.devices or {}) do
        if device.key == key then outline(playerNum, deviceObjects(device), getCore():getGoodHighlitedColor(), self.planOutlined) end
    end
end

-- A dot clicked on the plan: its row, unfolded and shown.
function ISBUPanelWindow:showDevice(key)
    local utility = self:activeUtility()
    local view = self.views[utility]
    local roomId, level
    for _, device in ipairs(view and view.devices or {}) do
        if device.key == key then roomId, level = device.inside and device.roomId or OUTSIDE, device.entry.z end
    end
    if not roomId then return end
    PanelWindow.folded[self.panel.id .. "|" .. utility .. "|" .. roomId] = nil
    PanelWindow.folded[self.panel.id .. "|" .. utility .. "|floor|" .. level] = false
    if self.roomFilter and self.roomFilter ~= roomId then self.roomFilter = nil end
    if PanelWindow.options.activeOnly then PanelWindow.options.activeOnly = false; self:placeOptions() end
    self:redraw()
    local list = self.lists[utility]
    for index, item in ipairs(list.items) do
        if item.item.device and item.item.device.key == key then
            list.selected = index
            list:ensureVisible(index)
        end
    end
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
        menu:addOption(getText(on and "IGUI_BU_Menu_Disconnect" or "IGUI_BU_Menu_Connect"), self, ISBUPanelWindow.switchDevice, utility, device)
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
        if on and utility == "power" and Panels.sheds(panel) then
            menu:addOption(getText(device.essential and "IGUI_BU_Menu_NotEssential" or "IGUI_BU_Menu_Essential"), playerObj, Sync.send,
                "setEssential", { panel = panel.id, key = key, on = not device.essential })
        end
    end
    menu:addOption(getText("IGUI_BU_Menu_ShowInList"), self, ISBUPanelWindow.showDevice, key)
end

-- The menu of a room right-clicked on the plan: all of it on or off, or only it in the list.
function ISBUPanelWindow:roomMenu(id)
    local utility = self:activeUtility()
    local view = self.views[utility]
    local totals = view and view.totals[id]
    local playerObj = self.playerObj
    local menu = ISContextMenu.get(playerObj:getPlayerNum(), getMouseX(), getMouseY())
    menu:addOption(totals and totals.title or (self.titles[id] or ""), nil, nil).isDisabled = true
    if totals and totals.count > 0 then
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

-- The box's generators and how far each is heard (Panels.generatorNoise): { x, y, z, radius, running }. A sub-panel
-- has none of its own, nor has a box while power is off (BU.enabled).
function ISBUPanelWindow:generatorNoises()
    local result = {}
    local panel = self.panel
    if panel.parent or not BU.enabled("power") then return result end
    local state = Networks.state(panel, "power")
    for _, at in ipairs(panel.power.producers) do
        local inUse = PanelWindow.producerInUse(state, at)
        local radius, running = Panels.generatorNoise(at.x, at.y, at.z, inUse)
        result[#result + 1] = { x = at.x, y = at.y, z = at.z, radius = radius, running = running }
    end
    return result
end

-- The range: on the ground around the building, where devices outside, producers and units reach (blue); producers
-- within it that are no panel's are outlined. Around each of the box's generators, on its floor, how far zombies hear
-- it (red, dim while it is off).
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
    local rooms = Panels.rooms(Panels.building(panel))
    if #rooms == 0 then return end
    -- Devices outside, producers and units join by the rooms of their own floor, the ground here (the whole outline
    -- where it has none): one ring, the edge of the plan's area (Geometry.reach).
    local ground, all = Geometry.roomRects(rooms, 0)
    local rings = { { area = Geometry.reach(#ground > 0 and ground or all, BU.connectRange(panel.tier)),
        colour = ColorInfo.new(0.3, 0.6, 1, 1) } }
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
    self.rangeJob = { rings = rings, producers = rings[1].area, inside = Geometry.reach(all, 0), minX = minX, maxX = maxX, y = minY, maxY = maxY }
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
            if Geometry.reached(job.producers, x, y) and not Geometry.reached(job.inside, x, y) then
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
