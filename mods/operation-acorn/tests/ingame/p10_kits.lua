-- P10 kits: the weapon kits (Gear/Gear.lua, NUMBERS 7 'Weapon kits') fitted to a melee weapon (Base.BaseballBat) and
-- two firearms (Base.Pistol, Base.HuntingRifle), through Gear.fitItem as the menu's timed action calls it.
--   1. damage kits: getMinDamage and getMaxDamage +10% of the script's per kit (two kits: +20%), the critical chance and the
--      condition unmoved, the kit used up, the notice (key and "+N%");
--   2. critical kits: getCriticalChance +5 points of the chance it had before the first one per kit, the damage unmoved;
--   3. repair kits: refused on a weapon at its most condition (the kit kept), else the condition up by a tenth of its most
--      (at least 1), never past it; the repair count kept;
--   4. the tooltip lines (Gear.itemLines) for the kits fitted, built as the language gives them;
--   5. weapon parts on the firearms (the pistol: Base.TritiumSights and Base.Laser, the rifle: Base.x2Scope), attached and
--      detached as the game's own action does (attachWeaponPart / detachWeaponPart): the values keep being the kits'
--      on the script plus the parts' damage, as the game left them and after Gear.refreshItem; a part given a damage
--      of 0.5 (WeaponPart.setDamage, no vanilla part has any) is added and taken off exactly;
--   6. the values written to Zomboid/Lua/oadev/p10_kits.txt, for p10_kits_after.lua to compare after a save and a reload
--      (the sights and the scope stay attached for that; the weapons stay in the inventory, marked in their modData).
-- Setup: none. Changes the inventory: the weapons stay until p10_kits_after.lua has run (it takes them away); with
-- P10_KITS_KEEP = false set first they go at the end of this run (then there is nothing to compare after a reload).
-- What a hit does with the damage (a firearm's hit damage comes straight from its minimum to maximum) is the jar's: not
-- scripted, shoot or swing at a zombie by hand.
-- Prints "[p10kits]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

local FILE = "oadev/p10_kits.txt"

P10T.start("p10kits", function(a)
    local Gear = OA.Gear
    local Rules = Gear.Rules
    local K = Rules.KEY
    local player = getPlayer()
    local inventory = player:getInventory()
    local notices = P10T.capture(a, "notice", true)
    local manager = getScriptManager()
    local keep = P10_KITS_KEEP ~= false

    local specs = {
        { label = "bat", type = "Base.BaseballBat", parts = {} },
        { label = "pistol", type = "Base.Pistol", parts = { "Base.TritiumSights", "Base.Laser" } },
        { label = "rifle", type = "Base.HuntingRifle", parts = { "Base.x2Scope" } },
    }

    local function eps(x, y, e) return type(x) == "number" and type(y) == "number" and math.abs(x - y) <= (e or 1e-3) end
    local function partsDamage(weapon)
        local sum, list = 0, weapon:getAllWeaponParts()
        for i = 0, (list and list:size() or 0) - 1 do sum = sum + list:get(i):getDamage() end
        return sum
    end
    local function line(weapon, base)
        return string.format("min %.4f max %.4f crit %.2f cond %d/%d (script %.4f-%.4f)", weapon:getMinDamage(), weapon:getMaxDamage(),
            weapon:getCriticalChance(), weapon:getCondition(), weapon:getConditionMax(), base.min, base.max)
    end
    local function kit(fullType)
        local item = inventory:AddItem(fullType)
        a.check("the kit " .. fullType .. " exists", item ~= nil)
        return item
    end
    local lastNotice = function() return notices[#notices] and notices[#notices].detail end

    local written = { "p10kits v1 day " .. tostring(OA.day()) .. " hour " .. string.format("%.2f", getGameTime():getTimeOfDay()) }
    local made = {}
    a.cleanup(function()
        if not keep then
            for _, w in ipairs(made) do
                if w:getContainer() then w:getContainer():Remove(w) end
            end
        end
    end)

    for _, spec in ipairs(specs) do
        local label = spec.label
        if not manager:FindItem(spec.type) then
            a.say(label, "skipped: no item", spec.type)
        else
            local w = inventory:AddItem(spec.type)
            made[#made + 1] = w
            w:getModData().OA_P10 = label
            local script = w:getScriptItem()
            local base = { min = script:getMinDamage(), max = script:getMaxDamage() }
            local crit0, cond0, most0 = w:getCriticalChance(), w:getCondition(), w:getConditionMax()
            a.say(label, spec.type, "fresh:", line(w, base))
            a.check(label .. " is a kit target (a weapon)", Gear.targetOf(w) == "weapon", tostring(Gear.targetOf(w)))
            a.check(label .. " fresh: the script's damage", eps(w:getMinDamage(), base.min) and eps(w:getMaxDamage(), base.max))
            a.check(label .. " has no kits", select(1, Gear.weaponKits(w)) == 0 and Gear.itemLines(w) == nil)

            -- 1. damage
            for n = 1, 2 do
                local k = kit("OperationAcorn.KitWeaponDamage")
                local ok, value = Gear.fitItem(player, k, w)
                a.check(label .. " damage kit " .. n .. " fitted", ok == true, tostring(ok) .. " " .. tostring(value))
                a.check(label .. " damage kit " .. n .. ": min +" .. (n * 10) .. "%", eps(w:getMinDamage(), base.min * (1 + 0.1 * n)),
                    w:getMinDamage() .. " want " .. base.min * (1 + 0.1 * n))
                a.check(label .. " damage kit " .. n .. ": max +" .. (n * 10) .. "%", eps(w:getMaxDamage(), base.max * (1 + 0.1 * n)),
                    w:getMaxDamage() .. " want " .. base.max * (1 + 0.1 * n))
                a.check(label .. " damage kit " .. n .. ": crit and condition unmoved", eps(w:getCriticalChance(), crit0)
                    and w:getCondition() == cond0, w:getCriticalChance() .. " " .. w:getCondition())
                a.check(label .. " damage kit " .. n .. ": the kit is used up and counted", k:getContainer() == nil
                    and select(1, Gear.weaponKits(w)) == n)
                local note = lastNotice()
                a.check(label .. " damage kit " .. n .. ": the notice", note ~= nil and note.key == "IGUI_OA_Gear_Fitted_weaponDamage"
                    and note.args[2] == "+" .. (n * 10) .. "%", note and (note.key .. " " .. tostring(note.args and note.args[2])) or "none")
            end

            -- 2. critical
            for n = 1, 2 do
                local k = kit("OperationAcorn.KitWeaponCrit")
                local ok = Gear.fitItem(player, k, w)
                a.check(label .. " critical kit " .. n .. " fitted", ok == true)
                a.check(label .. " critical kit " .. n .. ": +" .. (5 * n) .. " points", eps(w:getCriticalChance(), crit0 + 5 * n),
                    w:getCriticalChance() .. " want " .. (crit0 + 5 * n))
                a.check(label .. " critical kit " .. n .. ": damage unmoved", eps(w:getMinDamage(), base.min * 1.2) and eps(w:getMaxDamage(), base.max * 1.2))
            end
            a.check(label .. " the chance before the first critical kit is kept", eps(w:getModData()[K.WEAPON_CRIT], crit0), w:getModData()[K.WEAPON_CRIT])

            -- 3. repair
            local rk = kit("OperationAcorn.KitWeaponRepair")
            local ok, why = Gear.fitItem(player, rk, w)
            a.check(label .. " repair kit refused at the most condition", ok == false and why == "full" and rk:getContainer() ~= nil,
                tostring(ok) .. " " .. tostring(why))
            local gain = Rules.repairGain(most0)
            w:setCondition(math.max(1, math.floor(most0 / 2)), false)
            local hurt = w:getCondition()
            ok = Gear.fitItem(player, rk, w)
            a.check(label .. " repair kit: +" .. gain .. " of " .. most0 .. " (a tenth, at least 1)", ok == true
                and w:getCondition() == math.min(most0, hurt + gain), hurt .. " -> " .. w:getCondition())
            local rk2 = kit("OperationAcorn.KitWeaponRepair")
            w:setCondition(math.max(1, most0 - 1), false)
            ok = Gear.fitItem(player, rk2, w)
            a.check(label .. " repair kit: never past the most condition", ok == true and w:getCondition() == most0, w:getCondition())
            a.check(label .. " two repair kits counted", select(3, Gear.weaponKits(w)) == 2)

            -- 4. the tooltip
            local lines = Gear.itemLines(w)
            local want = {
                getText("Tooltip_OA_Gear_WeaponDamage", "2", "20"),
                getText("Tooltip_OA_Gear_WeaponCrit", "2", tostring(2 * Rules.CRIT_STEP)),
                getText("Tooltip_OA_Gear_WeaponRepair", "2"),
            }
            a.check(label .. " tooltip: three lines", lines ~= nil and #lines == 3, lines and #lines or "nil")
            if lines then
                for i = 1, 3 do
                    a.check(label .. " tooltip line " .. i .. " reads", lines[i] == want[i] and string.find(lines[i], "Tooltip_OA_", 1, true) == nil, lines[i])
                end
                a.check(label .. " tooltip: the damage line says the kits and the percent", string.find(lines[1], "2", 1, true) ~= nil
                    and string.find(lines[1], "20", 1, true) ~= nil, lines[1])
            end
            Gear.refreshItem(w)
            Gear.refreshItem(w)
            a.check(label .. " refreshing again changes nothing", eps(w:getMinDamage(), base.min * 1.2) and eps(w:getMaxDamage(), base.max * 1.2)
                and eps(w:getCriticalChance(), crit0 + 10) and w:getCondition() == most0)

            -- 5. parts
            local d, c = Gear.weaponKits(w)
            local function partChecks(step)
                local sum = partsDamage(w)
                local wantMin, wantMax = Rules.damage(base.min, d) + sum, Rules.damage(base.max, d) + sum
                local rawMin, rawMax, rawCrit = w:getMinDamage(), w:getMaxDamage(), w:getCriticalChance()
                a.check(label .. " " .. step .. ": damage is the kits on the script plus the parts' " .. string.format("%.2f", sum),
                    eps(rawMin, wantMin) and eps(rawMax, wantMax), rawMin .. "-" .. rawMax .. " want " .. wantMin .. "-" .. wantMax)
                a.check(label .. " " .. step .. ": critical chance kept", eps(rawCrit, Rules.crit(w:getModData()[K.WEAPON_CRIT], c)), rawCrit)
                a.check(label .. " " .. step .. ": kit counts kept", select(1, Gear.weaponKits(w)) == d and select(2, Gear.weaponKits(w)) == c)
                Gear.refreshItem(w)
                a.check(label .. " " .. step .. ": the same after Gear.refreshItem", eps(w:getMinDamage(), rawMin) and eps(w:getMaxDamage(), rawMax)
                    and eps(w:getCriticalChance(), rawCrit), w:getMinDamage() .. "-" .. w:getMaxDamage())
                a.check(label .. " " .. step .. ": the tooltip still says the kits", Gear.itemLines(w) ~= nil and #Gear.itemLines(w) == 3)
            end
            if #spec.parts > 0 then
                local attached = {}
                for i, partType in ipairs(spec.parts) do
                    if manager:FindItem(partType) then
                        local part = inventory:AddItem(partType)
                        -- the second part (the laser) is given a damage of its own, which no vanilla part has
                        local synthetic = i == 2
                        if synthetic then part:setDamage(0.5) end
                        w:attachWeaponPart(player, part)
                        inventory:Remove(part)
                        attached[#attached + 1] = { part = part, type = partType, synthetic = synthetic }
                        partChecks("attached " .. partType .. (synthetic and " (+0.5 damage)" or ""))
                    else
                        a.say(label, "skipped part", partType, "(no such item)")
                    end
                end
                -- the synthetic part comes off again; the other stays for the reload
                for i = #attached, 1, -1 do
                    if attached[i].synthetic then
                        w:detachWeaponPart(player, attached[i].part)
                        table.remove(attached, i)
                        partChecks("detached the damaging part")
                    end
                end
                -- every part off and on once more: the values return to the kits on the script
                for i = #attached, 1, -1 do w:detachWeaponPart(player, attached[i].part) end
                partChecks("all parts detached")
                a.check(label .. " all parts detached: damage is the kits on the script alone", eps(w:getMinDamage(), base.min * 1.2)
                    and eps(w:getMaxDamage(), base.max * 1.2), w:getMinDamage() .. "-" .. w:getMaxDamage())
                for _, p in ipairs(attached) do w:attachWeaponPart(player, p.part) end
                partChecks("the part put on again for the reload")
            end

            -- 6. the file
            local md = w:getModData()
            local names = {}
            local pl = w:getAllWeaponParts()
            for i = 0, (pl and pl:size() or 0) - 1 do names[#names + 1] = pl:get(i):getFullType() end
            table.sort(names)
            written[#written + 1] = string.format("%s type=%s min=%.5f max=%.5f crit=%.3f cond=%d most=%d d=%d c=%d r=%d basemin=%.5f basemax=%.5f basecrit=%.3f parts=%s",
                label, spec.type, w:getMinDamage(), w:getMaxDamage(), w:getCriticalChance(), w:getCondition(), w:getConditionMax(),
                select(1, Gear.weaponKits(w)), select(2, Gear.weaponKits(w)), select(3, Gear.weaponKits(w)), base.min, base.max,
                md[K.WEAPON_CRIT] or 0, table.concat(names, ","))
            a.say(label, "final:", line(w, base), "parts", table.concat(names, ","))
        end
    end
    P10T.write(FILE, written)
    a.say("written", #written - 1, "weapons to Zomboid/Lua/" .. FILE .. "; save, reload, then run p10_kits_after.lua")
end)
