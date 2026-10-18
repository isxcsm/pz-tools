-- P10 kits after a reload: compares the weapons p10_kits.lua left (marked OA_P10 in their modData, found in the
-- inventory) with the values it wrote to Zomboid/Lua/oadev/p10_kits.txt before the save and the reload.
--   - the file is there, and each weapon is still in the inventory with its kit counts (damage, critical, repair);
--   - getMinDamage, getMaxDamage, getCriticalChance, getCondition and the most condition are as written (the values the
--     game saved or the ones Gear.refreshAll worked out again when the game started: both end here, so this says whether
--     the player gets the right numbers; it cannot say which of the two it was);
--   - they are also what the kits make of the script (Rules.damage / Rules.crit on the script's damage and the chance
--     noted before the first critical kit, plus the attached parts' damage);
--   - the part left on each firearm is still on; the tooltip lines are still there.
-- Then the weapons are taken away and the file marked used (this is the end of p10_kits). Run it after `pzdev reload`
-- (or a save and a load) following p10_kits.lua.
-- Prints "[p10kitsafter]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

local FILE = "oadev/p10_kits.txt"

P10T.start("p10kitsafter", function(a)
    local Gear = OA.Gear
    local Rules = Gear.Rules
    local K = Rules.KEY
    local player = getPlayer()
    local inventory = player:getInventory()
    local function eps(x, y, e) return type(x) == "number" and type(y) == "number" and math.abs(x - y) <= (e or 1e-3) end

    local lines = P10T.read(FILE)
    if not a.check("the file of p10_kits.lua is there", lines ~= nil and #lines >= 2 and string.sub(lines[1], 1, 8) == "p10kits ", lines and lines[1] or "none") then
        return
    end
    a.say("written by:", lines[1])
    local found = {}
    local items = inventory:getAllEvalRecurse(function(item) return item:hasModData() and item:getModData().OA_P10 ~= nil end)
    for i = 0, items:size() - 1 do found[items:get(i):getModData().OA_P10] = items:get(i) end

    -- a row is "label key=value key=value ...": the values hold no spaces
    local function parse(row)
        local map = {}
        for key, value in string.gmatch(row, "(%w+)=(%S*)") do map[key] = value end
        return map
    end
    for i = 2, #lines do
        local row = lines[i]
        local label = string.match(row, "^(%S+)")
        local f = parse(row)
        local w = found[label]
        if not a.check(label .. " is in the inventory", w ~= nil) then
            -- (nothing more to compare)
        else
            local script = w:getScriptItem()
            local d, c, r = Gear.weaponKits(w)
            a.check(label .. " kit counts kept: damage " .. f.d .. " critical " .. f.c .. " repair " .. f.r,
                d == tonumber(f.d) and c == tonumber(f.c) and r == tonumber(f.r), d .. " " .. c .. " " .. r)
            a.check(label .. " min damage as written", eps(w:getMinDamage(), tonumber(f.min)),
                w:getMinDamage() .. " written " .. f.min)
            a.check(label .. " max damage as written", eps(w:getMaxDamage(), tonumber(f.max)),
                w:getMaxDamage() .. " written " .. f.max)
            a.check(label .. " critical chance as written", eps(w:getCriticalChance(), tonumber(f.crit)),
                w:getCriticalChance() .. " written " .. f.crit)
            a.check(label .. " condition as written", w:getCondition() == tonumber(f.cond)
                and w:getConditionMax() == tonumber(f.most), w:getCondition() .. "/" .. w:getConditionMax()
                .. " written " .. f.cond .. "/" .. f.most)
            -- what the kits make of the script
            local sum, names, pl = 0, {}, w:getAllWeaponParts()
            for j = 0, (pl and pl:size() or 0) - 1 do
                sum = sum + pl:get(j):getDamage()
                names[#names + 1] = pl:get(j):getFullType()
            end
            table.sort(names)
            a.check(label .. " damage is the kits on the script plus the parts'", eps(w:getMinDamage(), Rules.damage(script:getMinDamage(), d) + sum)
                and eps(w:getMaxDamage(), Rules.damage(script:getMaxDamage(), d) + sum),
                w:getMinDamage() .. "-" .. w:getMaxDamage() .. " want " .. (Rules.damage(script:getMinDamage(), d) + sum) .. "-"
                .. (Rules.damage(script:getMaxDamage(), d) + sum))
            local base = w:getModData()[K.WEAPON_CRIT]
            a.check(label .. " critical chance is the noted one plus the kits", base ~= nil and eps(w:getCriticalChance(), Rules.crit(base, c)),
                tostring(base) .. " + " .. c .. " kits -> " .. w:getCriticalChance())
            a.check(label .. " base chance noted as written", eps(base, tonumber(f.basecrit)), tostring(base))
            a.check(label .. " parts still on: " .. table.concat(names, ","), table.concat(names, ",") == (f.parts or ""),
                "written " .. tostring(f.parts))
            local tips = Gear.itemLines(w)
            a.check(label .. " the tooltip lines are there", tips ~= nil and #tips == 3, tips and #tips or "nil")
            -- refreshing again moves nothing
            local min, max, crit = w:getMinDamage(), w:getMaxDamage(), w:getCriticalChance()
            Gear.refreshItem(w)
            a.check(label .. " Gear.refreshItem moves nothing", eps(w:getMinDamage(), min) and eps(w:getMaxDamage(), max)
                and eps(w:getCriticalChance(), crit))
        end
    end
    -- the end of p10_kits: the weapons go
    for _, w in pairs(found) do
        if w:getContainer() then w:getContainer():Remove(w) end
    end
    P10T.write(FILE, { "p10kits used" })
    a.say("the weapons are taken away and the file marked used")
end)
