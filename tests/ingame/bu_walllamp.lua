-- A vanilla outdoor lamp (facing south, on the north wall of its square) put on the square just south of one of the
-- test building's ground rooms, outside it; then whether the API lists it as the building's, with the room across
-- the wall, and leaves it out of what is near. The lamp stays: BUWALLLAMP holds it; running again with
-- BUWALLLAMP_REMOVE=true takes it away. "[bulamp]" lines.
local BU = BuildingUtilities
local panel = BU.Store.get(ModData.getOrCreate("BUTEST").panel)
local api = BU.api()
local building = BU.Panels.building(panel)
if BUWALLLAMP_REMOVE and BUWALLLAMP then
    BUWALLLAMP:getSquare():transmitRemoveItemFromSquare(BUWALLLAMP)
    BUWALLLAMP, BUWALLLAMP_REMOVE = nil, nil
    print("[bulamp] removed")
    return
end
if not BUWALLLAMP then
    local cell = getCell()
    for _, room in ipairs(BU.Panels.rooms(building)) do
        if room.level == 0 and not BUWALLLAMP then
            for _, rect in ipairs(room.rects) do
                local y = rect.y + rect.h
                for x = rect.x, rect.x + rect.w - 1 do
                    local square = cell:getGridSquare(x, y, 0)
                    if not BUWALLLAMP and square and not square:getRoom() and square:getObjects():size() <= 2 then
                        local lamp = IsoLightSwitch.new(cell, square, getSprite("lighting_outdoor_01_24"), -1)
                        square:AddSpecialObject(lamp)
                        BUWALLLAMP = lamp
                        print("[bulamp] lamp at", x, y, "room across", room.name, "type", lamp:getObjectName())
                    end
                end
            end
        end
    end
end
if not BUWALLLAMP then print("[bulamp] no square south of a room") return end
local lx, ly = BUWALLLAMP:getSquare():getX(), BUWALLLAMP:getSquare():getY()
local listed, near = nil, false
for _, object in ipairs(api.buildings.objects(building.key, "power")) do
    if object.x == lx and object.y == ly and object.sprite == "lighting_outdoor_01_24" then listed = object end
end
for _, object in ipairs(api.buildings.near(building.key, 3, "power")) do
    if object.x == lx and object.y == ly then near = true end
end
print("[bulamp] listed", listed ~= nil, "room", listed and listed.room, "power", listed and listed.power, "near", near)
