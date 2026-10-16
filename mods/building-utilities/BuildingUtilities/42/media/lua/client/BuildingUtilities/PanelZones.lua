-- The breaker box window and its plan: what the plan shows, zones edited on it, its menus and the range shown on
-- the ground.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Store, Panels, Networks, Sync, Geometry, Energy, Units, Links = BU.Store, BU.Panels, BU.Networks, BU.Sync,
    BU.Geometry, BU.Energy, BU.Units, BU.Links
local Ui = BU.PanelUi
local load2, deviceObjects, outline, unoutline = Ui.load2, Ui.deviceObjects, Ui.outline,
    Ui.unoutline
local PanelWindow, Job = BU.PanelWindow, BU.Job

-- What the generators' noise rings are of, to tell when one changed.
local function noiseKey(noises)
    local parts = {}
    for _, noise in ipairs(noises) do
        parts[#parts + 1] = noise.x .. "," .. noise.y .. "," .. noise.z .. "," .. noise.radius .. (noise.running and "+" or "-")
    end
    return table.concat(parts, "|")
end

-- The plan.

-- What the plan shows, as tasks of a job (BU.Job): the rooms and devices, the producers and units, the relays and
-- lines, then the zones and the data given to the plan, which lays it out only when it differs from what it shows
-- (ISBUPlan:setData).
function ISBUPanelWindow:planTasks()
    if not self.plan then return {} end
    local utility = self:activeUtility()
    local view = self.views[utility]
    if not view then return {} end
    local panel = self.panel
    local tasks = {}
    local function task(fn) tasks[#tasks + 1] = fn end
    local paint, pipeList, pipes, hide
    -- what each part of the data is against what the plan shows, made as the part is (setData does not compare it again)
    local shown, verified = self.plan.data, {}
    local function check(key, value)
        if shown then verified[key] = ISBUPlan.same(shown[key], value, 1) end
    end
    local rooms, devices, producers, relays, liveRelays, lines = {}, {}, {}, {}, {}, {}
    task(function()
        self.planUtility = utility
        -- a pipe being put on rooms: each room in its pipe's colour
        paint = utility == "water" and self:paintingPipe() or nil
        if utility == "water" and BU.Water.shown(panel) then
            pipeList = {}
            for _, pipe in ipairs(BU.Water.pipes(panel)) do
                pipeList[#pipeList + 1] = { colour = BU.Water.colour(pipe.id), name = BU.Water.pipeName(panel, pipe.id) }
            end
        end
        for _, room in ipairs(self.rooms or {}) do
            rooms[#rooms + 1] = { id = room.id, title = self.titles[room.id] or BU.roomName(room.name or ""), level = room.level,
                rects = room.rects, building = room.building,
                pipeColour = paint and BU.Water.colour(BU.Water.roomPipe(panel, room.key) or BU.Water.FIRST) or nil }
        end
        hide = PanelWindow.options.hideUnwired
        -- Water with more than one pipe: each thing in its pipe's colour (a fixture's dot too, dark while it is off), and
        -- the lines too.
        pipes = utility == "water" and BU.Water.shown(panel)
        for _, device in ipairs(view.devices) do
            local entry = device.entry
            if not (hide and not device.wired) then
                devices[#devices + 1] = { key = device.key, x = entry.x, y = entry.y, z = entry.z, roomId = device.roomId,
                    inside = device.inside, state = device.state, wired = device.wired, held = device.held, cut = device.cut,
                    power = device.power, utility = utility, name = view.names[device.key] or "",
                    status = view.status[device.key], fresh = view.fresh[device.key],
                    ref = not device.inside and device.wired and Links.deviceRef(device.key) or nil,
                    pipeColour = pipes and device.pipe and BU.Water.colour(device.pipe) or nil }
            end
        end
        check("rooms", rooms)
        check("devices", devices)
    end)
    task(function()
        local state = view.state
        for index, at in ipairs(panel[utility].producers) do
            local inUse = PanelWindow.producerInUse(state, at)
            local ref = Links.producerRef(at.x, at.y, at.z)
            local cut = Links.reason(panel, ref) ~= nil
            local colour = pipes and BU.Water.colour(BU.Water.producerPipe(panel, at)) or nil
            producers[#producers + 1] = { x = at.x, y = at.y, z = at.z, inUse = inUse and not cut, colour = colour, cut = cut,
                off = at.off,
                ref = ref, key = ISBUPanelWindow.squareKey(at), text = (view.producerText[index] or "") .. (cut and "  " .. getText("IGUI_BU_LineNotSupplied") or "") }
        end
        -- The units: power's as its source, water's each on its own (in its inlet's colour, a pump in its outlet's; a
        -- filter or a booster pump between two pipes half in each, colour2 its outlet's); one whose line supplies nothing
        -- grey.
        local inUse = utility == "power" and Energy.inUse(state)
        for _, unit in ipairs(Store.unitList(nil, panel.id)) do
            if not BU.RELAY_KINDS[unit.kind] and Units.utility(unit) == utility and BU.enabled(unit.kind) then
                local ref = Links.unitRef(unit)
                local live = Links.live(panel, ref)
                local text = Units.name(unit)
                if not live then text = text .. "  " .. getText("IGUI_BU_LineNotSupplied")
                elseif utility == "water" then text = text .. "  " .. self:waterUnitStatus(unit) end
                local colour, colour2
                if pipes then
                    local inlet, outlet = BU.Water.unitPipes(panel, unit)
                    colour = BU.Water.colour(inlet or outlet)
                    if inlet and outlet and outlet ~= inlet then colour2 = BU.Water.colour(outlet) end
                end
                -- power's units share their kind's source row
                local key = utility == "power" and ISBUPanelWindow.sourceKey(unit.kind) or ISBUPanelWindow.squareKey(unit)
                producers[#producers + 1] = { x = unit.x, y = unit.y, z = unit.z, unit = unit.kind, colour = colour, colour2 = colour2,
                    off = unit.off, ref = ref, key = key, cut = not live, inUse = live and (inUse or unit.running == true), text = text }
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
        check("producers", producers)
    end)
    -- The relays of this utility, and the lines: each from its thing to what it hangs on (its wall square, a relay, a
    -- device), grey where it supplies nothing.
    task(function()
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
        check("relays", relays)
    end)
    task(Job.each(function() return Links.of(panel) end, function(line)
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
    end))
    task(function() check("lines", lines) end)
    local zone, inZone, farLevels, editable, ranges, rangeKey, boxes = {}, 0, {}, false, nil, nil, {}
    task(function()
        -- The zones of the rooms: this box's, the free rooms and other boxes'; a room it cannot take says why.
        for id, entry in pairs(Panels.zoneStates(panel, self.rooms or {})) do
            zone[id] = { state = entry.state, owner = entry.owner and Panels.name(entry.owner) }
            if entry.state == "mine" then inZone = inZone + 1 end
        end
        local takeable = {}
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
        editable = #(self.rooms or {}) > 0
        check("zone", zone)
        check("farLevels", farLevels)
        if not editable then self.zoneEditing = false end
    end)
    task(function()
        -- The range, while the plan shows it: from the zone's rooms (an outdoor box's square) and its relays.
        local tier = panel.tier or 1
        rangeKey = tier .. "|" .. Store.linkVersion() .. "|" .. tostring(panel.zone) .. "|"
            .. Panels.attachedSize(self.building)
        if self.rangeShown then
            ranges = { reach = BU.connectRange(tier), relayReach = BU.relayRange(), relays = liveRelays }
            if utility == "power" then
                ranges.noise = self:generatorNoises()
                rangeKey = rangeKey .. "|" .. noiseKey(ranges.noise)
            end
        end
        -- The boxes whose zones can have these rooms (this one alone where there are none).
        local seenBox = {}
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
    end)
    task(function(_, job)
        Job.insert(job, self.plan:dataTasks({ utility = utility, supplied = view.state and view.state.supplied, rooms = rooms, devices = devices,
            producers = producers, relays = relays, lines = lines, box = { x = panel.x, y = panel.y, z = panel.z },
            outdoor = panel.outdoor == true, boxes = boxes, filter = self.roomFilter,
            zone = zone, zoneEditable = editable, zoneEdit = self.zoneEditing == true, zoneNote = getText("IGUI_BU_ZoneNote", inZone),
            farLevels = farLevels, waterSupply = utility == "water" and self.waterSupply and self.waterSupply.byLevel or nil,
            ranges = ranges, rangeKey = rangeKey, pipes = pipeList, pipeCombo = pipeList ~= nil,
            pipePaint = paint and { id = paint, colour = BU.Water.colour(paint), name = BU.Water.pipeName(panel, paint) } or nil },
            verified))
    end)
    return tasks
end

-- The plan's data again, at once (see planTasks). The player's own doing takes over a refresh under way.
function ISBUPanelWindow:updatePlan()
    self:cancelJob()
    Job.runAll(self:planTasks())
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
    if on then self.roomFilter, self.pipePainting = nil, nil end
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
    local states = Panels.zoneStates(self.panel, self.rooms or {})
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
    local states = Panels.zoneStates(self.panel, self.rooms or {})
    local menu = Ui.UI.menu(self, Ui.PALETTE)
    menu:addHead(BU.floorName(level))
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
        option.off = true
        option.tip = self:farNote(far)
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
    local menu = Ui.UI.menu(self, Ui.PALETTE)
    menu:addHead(view.names[key] or "")
    if device.state == "other" or not device.wired then
        menu:addOption(view.status[key] or "").off = true
    else
        local on = device.state == "on"
        if Panels.cuts(panel) and not device.cut then
            menu:addOption(getText(on and "IGUI_BU_Menu_Disconnect" or "IGUI_BU_Menu_Connect"), self, ISBUPanelWindow.switchDevice, utility, device)
        end
        if on and utility == "power" and (panel.tier or 1) >= BU.TIMER_TIER then
            menu:addOption(getText("IGUI_BU_Menu_ShowInList"), self, ISBUPanelWindow.showThing, key)
            menu:addHead(getText("IGUI_BU_Menu_Timer"))
            for _, schedule in ipairs(BU.SCHEDULES) do
                local option = menu:addOption(getText("IGUI_BU_Schedule_" .. schedule), playerObj, Sync.send, "setSchedule",
                    { panel = panel.id, key = key, schedule = schedule })
                if schedule == device.schedule then option.current = true end
            end
            return
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
    local menu = Ui.UI.menu(self, Ui.PALETTE)
    menu:addHead(totals and totals.title or (self.titles[id] or ""))
    if totals and totals.count > 0 and Panels.cuts(self.panel) then
        local send = function(on)
            Sync.send(playerObj, "setRoomInside", { panel = self.panel.id, utility = utility, room = id, on = on,
                units = totals.units, producers = totals.producers })
        end
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

-- The range, on the plan alone (updatePlan gives it the rings: the reach from the zone's rooms and from its relays,
-- the generators' noise); nothing is drawn in the world.
function ISBUPanelWindow:showRange(on) self.rangeShown = on end

function ISBUPanelWindow:onRange()
    self:showRange(not self.rangeShown)
    self:updatePlan()
end
