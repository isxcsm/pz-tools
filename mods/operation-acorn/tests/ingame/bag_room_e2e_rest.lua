-- bag_room_e2e.lua's last part alone: a vehicle's biggest container full of planks (its weight and the vehicle's mass),
-- furniture on the map weighed for the pickup check, and a full bag with the nodes taken away. Lines "[bagrest]".
RUN("p3_lib.lua")
local OA = OperationAcorn
local Effects = OA.Upgrades.Effects
local Carry = OA.Upgrades.Carry
local t = STEPS("bagrest")
local record, player, u = P3T.record()
local inv = player:getInventory()
local NODES = { "materials", "materials", "materials", "materialsPlus", "materialsPlus", "furniture", "furniture" }
local function setRanks(ranks)
    P3T.fresh(u)
    for _, id in ipairs(ranks) do P3T.buy(u, id) end
    Effects.apply(record)
end
local function near(a, b, e) return math.abs(a - b) <= (e or 0.05) end

t.run({
    { 0, function()
        setRanks(NODES)
        -- the nearest vehicle's biggest container
        local best, bestCar
        local cars = OA.vehicles()
        for j = 0, cars:size() - 1 do
            local car = cars:get(j)
            if car:DistTo(player) < 30 then
                for i = 0, car:getPartCount() - 1 do
                    local c = car:getPartByIndex(i):getItemContainer()
                    if c and (not best or c:getCapacity() > best:getCapacity()) then best, bestCar = c, car end
                end
            end
        end
        t.check("a vehicle container near", best ~= nil)
        if not best then return end
        best:removeAllItems()
        for _ = 1, 20 do best:AddItem("Base.Plank") end
        t.check("the container counts the planks half", near(best:getCapacityWeight(), 30), best:getCapacityWeight() .. "/" .. best:getCapacity())
        bestCar:updateTotalMass()
        local withNodes, items = bestCar:getMass(), bestCar:getTotalContainerItemWeight()
        setRanks({})
        bestCar:updateTotalMass()
        local without, itemsRaw = bestCar:getMass(), bestCar:getTotalContainerItemWeight()
        setRanks(NODES)
        bestCar:updateTotalMass()
        t.say("info vehicle", bestCar:getScriptName(), "items", items, "mass", withNodes, "| without the nodes: items", itemsRaw, "mass", without)
        t.check("the vehicle carries the planks lighter", items < itemsRaw and withNodes < without, withNodes .. " vs " .. without)
        best:removeAllItems()
        bestCar:updateTotalMass()
        -- furniture on the map
        local props = ISMoveableSpriteProps.new(getSprite("furniture_seating_indoor_01_0"))
        local weight = props and props.weight
        t.check("a sofa weighed as carried", type(weight) == "number" and near(Carry.moveableWeight(props), weight / 2), tostring(weight))
        -- a full bag, the nodes taken away
        local bag = inv:AddItem("Base.Bag_ALICEpack")
        local bi = bag:getInventory()
        for _ = 1, 18 do bi:AddItem("Base.Plank") end
        t.check("18 planks fill the bag to 27", near(bi:getCapacityWeight(), 27), bi:getCapacityWeight())
        setRanks({})
        t.check("without the nodes the bag is over its room", bi:getCapacityWeight() > 28, bi:getCapacityWeight())
        t.check("nothing more goes in", not bi:hasRoomFor(player, instanceItem("Base.Plank")))
        t.check("nothing fell out", bi:getItems():size() == 18)
        inv:Remove(bag)
    end },
})
