-- The weapon kits on real swings (E2E.md 11.1): a bat swung by the game's own attack (IsoPlayer.pressedAttack) at a zombie
-- standing where the mouse points (the swing turns to the mouse; the cursor is not moved), many times before and after
-- the kits are fitted. The damage is the zombie's health lost a swing; the critical chance and the critical damage are
-- also asked of the game's own functions (IsoPlayer.calculateCritChance, IsoGameCharacter.processHitDamage) on the same
-- weapon, for the bat and a pistol. Lines are tagged "[ukits]". God mode on while it runs; the weapons are left in the
-- inventory, the zombie taken away. About a minute.
local OA = OperationAcorn
local Gear = OA.Gear
local player = getPlayer()
local function say(...) print("[ukits]", ...) end

local SWINGS = UK_SWINGS or 40
local GAP = 1600 -- real ms between swings (the swing and the zombie's reaction end)

local function mouseDir()
    local mx, my = getMouseX(), getMouseY()
    local wx = screenToIsoX(0, mx, my, player:getZ())
    local wy = screenToIsoY(0, mx, my, player:getZ())
    local dx, dy = wx - player:getX(), wy - player:getY()
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.01 then return 1, 0 end
    return dx / d, dy / d
end

local function give(kind)
    local w = player:getInventory():AddItem(kind)
    return w
end

local zombie
local function placeZombie()
    local dx, dy = mouseDir()
    local x, y = player:getX() + dx * 0.9, player:getY() + dy * 0.9
    if not zombie or zombie:isDead() then
        local list = addZombiesInOutfit(math.floor(x), math.floor(y), math.floor(player:getZ()), 1, "Generic01", 50)
        zombie = list:get(0)
        zombie:setUseless(true)
    end
    zombie:setX(x) zombie:setY(y) zombie:setZ(player:getZ())
    zombie:setLastX(x) zombie:setLastY(y)
    zombie:setHealth(100)
end

-- the game's own numbers for a weapon: crit chance against the zombie, a critical hit's damage for a 1.0 hit
local function asked(w)
    player:setPrimaryHandItem(w)
    if w:isTwoHandWeapon() then player:setSecondaryHandItem(w) else player:setSecondaryHandItem(nil) end
    placeZombie()
    local chance = player:calculateCritChance(zombie)
    player:setCriticalHit(true)
    local crit = zombie:processHitDamage(w, player, 1.0, false, 1.0)
    player:setCriticalHit(false)
    local plain = zombie:processHitDamage(w, player, 1.0, false, 1.0)
    zombie:setHealth(100)
    return chance, crit, plain, w:getCriticalChance(), w:getCriticalDamageMultiplier(), w:getMinDamage(), w:getMaxDamage()
end

local function fit(kitType, w)
    local kit = player:getInventory():AddItem(kitType)
    local ok, why = Gear.fitItem(player, kit, w)
    return ok, why
end

-- swings, then the next step
local steps, current = {}, nil
local function swings(label, w, n, after)
    local lost, hits, crits, kills, done, next = {}, 0, 0, 0, 0, getTimestampMs() + 500
    local before
    local function tick()
        if getTimestampMs() < next then return end
        if before then
            local l = before - zombie:getHealth()
            -- a zombie put down at once (a kill on the ground) loses all it had: not a hit's damage
            if l > 0.0001 and l < 50 then hits = hits + 1 lost[#lost + 1] = l if player:isCriticalHit() then crits = crits + 1 end
            elseif l >= 50 then kills = kills + 1 end
            done = done + 1
            before = nil
            if done >= n then
                Events.OnTick.Remove(tick)
                table.sort(lost)
                local median = lost[math.floor((#lost + 1) / 2)] or 0
                say(label, "swings", n, "hits", hits, "crits", crits, "put down", kills, "median", string.format("%.3f", median),
                    "min", lost[1] and string.format("%.3f", lost[1]) or "-", "max", lost[#lost] and string.format("%.3f", lost[#lost]) or "-")
                after(median, hits)
                return
            end
        end
        player:setPrimaryHandItem(w)
        if w:isTwoHandWeapon() then player:setSecondaryHandItem(w) end
        placeZombie()
        before = zombie:getHealth()
        player:pressedAttack()
        next = getTimestampMs() + GAP
    end
    Events.OnTick.Add(tick)
end

player:setGodMod(true)
local bat = give("Base.BaseballBat")
local pistol = give("Base.Pistol")
local b0 = { asked(bat) }
local p0 = { asked(pistol) }
say("bat before: critChance(game)", b0[1], "crit hit", string.format("%.3f", b0[2]), "plain hit", string.format("%.3f", b0[3]),
    "weapon crit", b0[4], "x", b0[5], "dmg", b0[6], b0[7])
say("pistol before: critChance(game)", p0[1], "crit hit", string.format("%.3f", p0[2]), "plain", string.format("%.3f", p0[3]),
    "weapon crit", p0[4], "x", p0[5], "dmg", p0[6], p0[7])

swings("bat without kits", bat, SWINGS, function(mean0)
    for _, k in ipairs({ "OperationAcorn.KitWeaponDamage", "OperationAcorn.KitWeaponCrit", "OperationAcorn.KitWeaponCritDamage" }) do
        say("fit", k, "bat", fit(k, bat))
        say("fit", k, "pistol", fit(k, pistol))
    end
    local b1 = { asked(bat) }
    local p1 = { asked(pistol) }
    say("bat after: critChance(game)", b1[1], "crit hit", string.format("%.3f", b1[2]), "plain", string.format("%.3f", b1[3]),
        "weapon crit", b1[4], "x", b1[5], "dmg", b1[6], b1[7])
    say("pistol after: critChance(game)", p1[1], "crit hit", string.format("%.3f", p1[2]), "plain", string.format("%.3f", p1[3]),
        "weapon crit", p1[4], "x", p1[5], "dmg", p1[6], p1[7])
    local function check(what, ok, ...) say(what, ok and "ok" or "BAD", ...) end
    -- the weapon's chance goes up 5 points; the game scales a melee weapon's chance by its own factor, before and after alike
    check("bat crit chance: weapon +5, the game's number up by its own scale", math.abs(b1[4] - b0[4] - 5) < 0.01
        and math.abs((b1[1] - b0[1]) - 5 * b0[1] / b0[4]) < 1, b0[4], b1[4], b0[1], b1[1])
    check("pistol crit chance: weapon +5, the game's number +5", math.abs(p1[4] - p0[4] - 5) < 0.01 and math.abs(p1[1] - p0[1] - 5) < 1, p0[1], p1[1])
    check("bat crit damage x1.1 of its multiplier (game)", math.abs(b1[5] / b0[5] - 1.1) < 0.01, b0[5], b1[5])
    check("pistol crit damage x1.1 (game)", math.abs(p1[5] / p0[5] - 1.1) < 0.01, p0[5], p1[5])
    swings("bat with kits", bat, SWINGS, function(mean1)
        check("bat swing damage up (median of real swings)", mean0 > 0 and mean1 / mean0 > 1.0, string.format("%.3f", mean0), string.format("%.3f", mean1))
        if zombie then zombie:removeFromWorld() zombie:removeFromSquare() end
        player:setGodMod(false)
        say("done")
    end)
end)
