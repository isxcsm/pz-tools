-- The looks of the units and the box (the units' sync, BU.PanelLook): a pump, a filter and a solar panel put down near
-- the player, the pump and filter wired to the test panel; each state set by hand and the sprite or overlay read. The
-- test panel's box turned into an old save's terminal and shown (it takes the console), then tripped, blinked and
-- reset. Every new sprite is checked to exist. "[bulooks]" lines, each "ok" or "BAD"; BULOOKS_CLEAN() takes the
-- units away and puts the box's breaker back as it was.
local BU = BuildingUtilities
local Store, Changes, Units, WaterUnits, Solar, Panels, PanelLook = BU.Store, BU.Changes, BU.Units, BU.WaterUnits,
    BU.Solar, BU.Panels, BU.PanelLook
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)

local function say(...) print("[bulooks]", ...) end
local function check(what, got, want) say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want)) end
local function spriteOf(object) return object:getSprite():getName() end
local function overlayOf(object) return object:getOverlaySprite() and object:getOverlaySprite():getName() or "none" end

local missing = 0
local function exists(name)
    local sprite = getSprite(name)
    if not sprite or not sprite:getTextureForCurrentFrame(IsoDirections.N) then say("BAD missing", name); missing = missing + 1 end
end
for _, looks in ipairs({ WaterUnits.PUMP_LOOKS, WaterUnits.FILTER_LOOKS, PanelLook.SPRITES, Solar.SNOW_OVERLAYS }) do
    for _, sprites in pairs(looks) do
        for _, name in pairs(sprites) do exists(name) end
    end
end
say("sprites missing", missing)

-- Free outdoor squares near the player.
local squares, p = {}, getPlayer():getSquare()
for r = 1, 8 do
    for dy = -r, r do
        for dx = -r, r do
            local q = getCell():getGridSquare(p:getX() + dx, p:getY() + dy, 0)
            if #squares < 3 and q and q:isOutside() and Units.canInstall("solar", q) then
                local taken = false
                for _, other in ipairs(squares) do taken = taken or other == q end
                if not taken then squares[#squares + 1] = q end
            end
        end
    end
end
if #squares < 3 then say("BAD not enough free squares outside near the player"); return end

local pump = Changes.installUnit("pump", squares[1], WaterUnits.PUMP_SPRITES.S)
local filter = Changes.installUnit("filter", squares[2], WaterUnits.FILTER_SPRITES.across)
local solar = Changes.installUnit("solar", squares[3], Solar.SPRITES.W)
Changes.connectUnit(pump, panel, {})
Changes.connectUnit(filter, panel, {})

-- The pump, facing S throughout.
local pumpObject = Units.object(pump)
local function pumpAs(running, fluid, frozen, want)
    local wasFrozen = panel.water.frozen
    pump.running, pump.fluid, panel.water.frozen = running, fluid, frozen
    Units.definition("pump").sync(pump, pumpObject)
    check("pump " .. WaterUnits.pumpLook(pump), spriteOf(pumpObject), want)
    panel.water.frozen = wasFrozen
end
pumpAs(true, "TaintedWater", nil, WaterUnits.PUMP_LOOKS.running.S)
pumpAs(true, nil, nil, WaterUnits.PUMP_LOOKS.dry.S)
pumpAs(true, "TaintedWater", true, WaterUnits.PUMP_LOOKS.frozen.S)
pumpAs(nil, "TaintedWater", nil, WaterUnits.PUMP_LOOKS.stopped.S)

-- The filter, its pipe across.
local filterObject = Units.object(filter)
local function filterAs(working, media, want)
    filter.working, filter.media = working, media
    Units.definition("filter").sync(filter, filterObject)
    check("filter " .. WaterUnits.filterLook(filter), spriteOf(filterObject), want)
end
filterAs(true, WaterUnits.FILTER_HOURS, WaterUnits.FILTER_LOOKS.working.across)
filterAs(true, 0, WaterUnits.FILTER_LOOKS.spent.across)
filterAs(nil, WaterUnits.FILTER_HOURS, WaterUnits.FILTER_LOOKS.resting.across)

-- The solar panel's snow.
local solarObject = Units.object(solar)
local function snowAs(snow, want)
    solar.snow = snow
    Units.definition("solar").sync(solar, solarObject)
    check("snow " .. tostring(snow), overlayOf(solarObject), want)
end
snowAs(0.2, Solar.SNOW_OVERLAYS.light.W)
snowAs(0.8, Solar.SNOW_OVERLAYS.heavy.W)
snowAs(nil, "none")

-- The box: an old terminal takes the console, facing as it did; then tripped, blinking, reset.
local box = Panels.object(panel)
local before, tripped = spriteOf(box), panel.tripped
local facing = PanelLook.of(box) and PanelLook.of(box).facing or 1
box:setSprite(getSprite(BU.OLD_PANEL_SPRITES[facing]))
PanelLook.show(panel)
local look = PanelLook.wanted(panel)
check("old box takes the console (" .. look .. ")", spriteOf(box), PanelLook.SPRITES[look][facing])
check("its stored sprite", panel.sprite, BU.PANEL_SPRITES[facing])
panel.tripped = true
PanelLook.show(panel)
check("tripped", spriteOf(box), PanelLook.SPRITES.tripped[facing])
PanelLook.blink(box, false)
check("blink dark", spriteOf(box), PanelLook.SPRITES.trippedDark[facing])
PanelLook.show(panel)
check("the server keeps the dark frame", spriteOf(box), PanelLook.SPRITES.trippedDark[facing])
PanelLook.blink(box, true)
check("blink lit", spriteOf(box), PanelLook.SPRITES.tripped[facing])
panel.tripped = tripped
PanelLook.show(panel)
check("reset", spriteOf(box), PanelLook.SPRITES[PanelLook.wanted(panel)][facing])
say("box was", before, "is", spriteOf(box))

function BULOOKS_CLEAN()
    for _, unit in ipairs({ pump, filter, solar }) do Changes.removeUnit(unit) end
    panel.tripped = tripped
    PanelLook.show(panel)
    say("cleaned")
end
