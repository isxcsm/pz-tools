-- The breaker box window and its plan: what the plan shows, zones edited on it, its menus and the range shown on
-- the ground.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Store, Panels, Networks, Costs, Actions, Sync, Geometry, Energy, Units = BU.Store, BU.Panels, BU.Networks, BU.Costs,
    BU.Actions, BU.Sync, BU.Geometry, BU.Energy, BU.Units
local Ui = BU.PanelUi
local OUTSIDE, load2, deviceObjects, outline, unoutline = Ui.OUTSIDE, Ui.load2, Ui.deviceObjects, Ui.outline,
    Ui.unoutline
local PanelWindow = BU.PanelWindow

-- The plan.

function ISBUPanelWindow:updatePlan()
    if not (self.plan and self.plan:getIsVisible()) then return end
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
    for _, device in ipairs(view.devices) do
        local entry = device.entry
        local choosable = self.choosing[utility] == true and not device.inside and device.state == "off"
        devices[#devices + 1] = { key = device.key, x = entry.x, y = entry.y, z = entry.z, roomId = device.roomId, inside = device.inside,
            state = device.state, held = device.held, power = device.power, utility = utility,
            -- Out to a device outside while it takes something.
            flow = not device.inside and device.state == "on" and not device.held and view.state and view.state.supplied
                and (utility == "water" or (device.power or 0) > 0) and -1 or nil,
            name = view.names[device.key] or "", status = view.status[device.key],
            choosable = choosable, chosen = choosable and self.chosen[utility][device.key] == true,
            fresh = view.fresh[device.key] }
    end
    local producers = {}
    if not panel.parent then
        local state = view.state
        local supplied = state and state.supplied
        for index, at in ipairs(panel[utility].producers) do
            local inUse = state and state.producer and state.producer.x == at.x and state.producer.y == at.y and state.producer.z == at.z
            -- What runs to the box: the generator in use; for water, each tank with water in it.
            local flow
            if utility == "power" then flow = inUse and supplied and 1 or nil
            else
                local seen = PanelWindow.seenProducer(state, at)
                flow = supplied and seen and (seen.amount or 0) > 0 and 1 or nil
            end
            producers[#producers + 1] = { x = at.x, y = at.y, z = at.z, inUse = inUse, flow = flow, text = view.producerText[index] }
        end
        if utility == "power" then
            local inUse = Energy.inUse(state)
            for _, unit in ipairs(Store.unitList(nil, panel.id)) do
                producers[#producers + 1] = { x = unit.x, y = unit.y, z = unit.z, inUse = inUse, unit = unit.kind,
                    flow = state and Units.flow(unit, panel, state) or nil,
                    text = Units.name(unit) .. (view.sourceText and "  " .. view.sourceText or "") }
            end
        end
    end
    -- The zones of the building: this box's, the free rooms and other boxes'.
    local zone, inZone = {}, 0
    for id, entry in pairs(Panels.zoneStates(panel, self.building, self.rooms or {})) do
        zone[id] = { state = entry.state, owner = entry.owner and Panels.name(entry.owner) }
        if entry.state == "mine" then inZone = inZone + 1 end
    end
    local editable = Panels.zonesSupported() and self.building ~= nil
    if not editable then self.zoneEditing = false end
    -- The range, while the window shows it in the world.
    local ranges, tier = nil, panel.tier or 1
    if self.rangeShown then
        local exterior = BU.exteriorRange(tier)
        ranges = { exterior = exterior > 0 and exterior or nil, producer = not panel.parent and BU.producerRange(tier) or nil }
    end
    self.plan:setData({ utility = utility, supplied = view.state and view.state.supplied, rooms = rooms, devices = devices,
        producers = producers, box = { x = panel.x, y = panel.y, z = panel.z }, boxText = Panels.name(panel), filter = self.roomFilter,
        zone = zone, zoneEditable = editable, zoneEdit = self.zoneEditing == true, zoneNote = getText("IGUI_BU_ZoneNote", inZone),
        ranges = ranges, rangeKey = (self.building and self.building.key or "") .. "|" .. tier,
        choosing = self.choosing[utility] == true })
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

function ISBUPanelWindow:toggleZoneRoom(id)
    local states = Panels.zoneStates(self.panel, self.building, self.rooms or {})
    local entry = states[id]
    if not entry or entry.state == "taken" then return end
    local set = self:zoneSet()
    set[id] = entry.state == "free" or nil
    self:sendZone(set)
end

-- The zone's menu, for a floor: its free rooms in, its rooms out, only it, or the whole building.
function ISBUPanelWindow:zoneMenu(level)
    local states = Panels.zoneStates(self.panel, self.building, self.rooms or {})
    local menu = ISContextMenu.get(self.playerObj:getPlayerNum(), getMouseX(), getMouseY())
    menu:addOption(BU.floorName(level), nil, nil).notAvailable = true
    local function floorSet(keepOthers, take)
        local set = keepOthers and self:zoneSet() or {}
        for _, room in ipairs(self.rooms or {}) do
            if room.level == level and states[room.id].state ~= "taken" then set[room.id] = take or nil end
        end
        return set
    end
    menu:addOption(getText("IGUI_BU_Menu_ZoneFloorAdd"), self, function(window) window:sendZone(floorSet(true, true)) end)
    menu:addOption(getText("IGUI_BU_Menu_ZoneFloorRemove"), self, function(window) window:sendZone(floorSet(true, false)) end)
    menu:addOption(getText("IGUI_BU_Menu_ZoneFloorOnly"), self, function(window) window:sendZone(floorSet(false, true)) end)
    if self.building and #Panels.ofBuilding(self.building.key) == 1 and self.panel.rooms then
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
    local roomId
    for _, device in ipairs(view and view.devices or {}) do
        if device.key == key then roomId = device.inside and device.roomId or OUTSIDE end
    end
    if not roomId then return end
    PanelWindow.folded[self.panel.id .. "|" .. utility .. "|" .. roomId] = nil
    if self.roomFilter and self.roomFilter ~= roomId then self.roomFilter = nil end
    if PanelWindow.options.activeOnly then PanelWindow.options.activeOnly = false; self:placeOptions() end
    self:refresh()
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
    self:refresh()
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
    menu:addOption(view.names[key] or "", nil, nil).notAvailable = true
    if device.state == "other" then
        menu:addOption(view.status[key] or "", nil, nil).notAvailable = true
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
                if schedule == device.schedule then option.notAvailable = true end
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
    menu:addOption(totals and totals.title or (self.titles[id] or ""), nil, nil).notAvailable = true
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

-- The range: on the ground around the building, where producers reach (yellow, for a main panel) and where devices
-- outside reach (blue); producers within reach that are no panel's are outlined.
function ISBUPanelWindow:showRange(on)
    local playerNum = self.playerObj:getPlayerNum()
    unoutline(playerNum, self.rangeObjects)
    self.rangeObjects = {}
    self.rangeShown = on
    if not on then return end
    local panel = self.panel
    local rooms = Panels.rooms(Panels.building(panel))
    if #rooms == 0 then return end
    -- Devices outside join by the rooms of their own floor, the ground here; producers by the whole outline.
    local ground = {}
    for _, room in ipairs(rooms) do
        if room.level == 0 then ground[#ground + 1] = room end
    end
    local minX, minY, maxX, maxY
    for _, room in ipairs(rooms) do
        for _, rect in ipairs(room.rects) do
            minX, minY = math.min(minX or rect.x, rect.x), math.min(minY or rect.y, rect.y)
            maxX, maxY = math.max(maxX or rect.x + rect.w - 1, rect.x + rect.w - 1), math.max(maxY or rect.y + rect.h - 1, rect.y + rect.h - 1)
        end
    end
    -- A range of 0 has no ring: devices outside do not join at all.
    local rings, reach = {}, 0
    local exterior, producers = BU.exteriorRange(panel.tier), BU.producerRange(panel.tier)
    if exterior > 0 then
        rings[#rings + 1] = { steps = exterior, colour = ColorInfo.new(0.3, 0.6, 1, 1), ground = true }
        reach = exterior
    end
    if not panel.parent then
        rings[#rings + 1] = { steps = producers, colour = ColorInfo.new(1, 0.85, 0.2, 1) }
        reach = math.max(reach, producers)
    end
    local producerColour = getCore():getGoodHighlitedColor()
    for x = minX - reach, maxX + reach do
        for y = minY - reach, maxY + reach do
            local square = getCell():getGridSquare(x, y, 0)
            if square then
                local steps = Geometry.toBuilding(x, y, rooms)
                local groundSteps = Geometry.toBuilding(x, y, ground)
                for _, ring in ipairs(rings) do
                    local floor = (ring.ground and groundSteps or steps) == ring.steps and square:getFloor()
                    if floor then outline(playerNum, { floor }, ring.colour, self.rangeObjects) end
                end
                if not panel.parent and steps and steps > 0 and steps <= producers then
                    local utility, object = Panels.producerOn(square)
                    if utility and not Store.producerOwner(x, y, 0) then outline(playerNum, { object }, producerColour, self.rangeObjects) end
                end
            end
        end
    end
end

function ISBUPanelWindow:onRange()
    self:showRange(not self.rangeShown)
    self.rangeButton:setTitle(getText(self.rangeShown and "IGUI_BU_RangeHide" or "IGUI_BU_RangeShow"))
    self:updatePlan()
end
