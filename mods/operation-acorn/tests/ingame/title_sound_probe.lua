-- Which of the game's sounds that could be a title's (SOUND-SYSTEM.md S6) end by themselves when played once on the
-- screen: a title plays a moment's sound once and never stops it, so one that keeps going (an event that loops until
-- stopped, as the game stops its tune-in and its campfire's lighting) cannot be one. Each is played once, all
-- together, and asked after 2, 5 and 10 s whether it still plays; then all are stopped. Prints TITLESOUND lines.
local CANDIDATES = { "CampfireLight", "UseMatch", "UseLighter", "TuneIn", "VehicleRadioTuneIn", "HeartBeat", "WaterDrip",
    "LureHitWater", "RadioZap" }
local sm = getSoundManager()
local ids, start, asked = {}, getTimestampMs(), {}
for _, name in ipairs(CANDIDATES) do
    ids[name] = GameSounds.isKnownSound(name) and sm:playUISound(name) or nil
    print("TITLESOUND " .. name .. " known " .. tostring(ids[name] ~= nil))
end
local function probe()
    local at = getTimestampMs() - start
    for _, mark in ipairs({ 2000, 5000, 10000 }) do
        if at >= mark and not asked[mark] then
            asked[mark] = true
            local still = {}
            for _, name in ipairs(CANDIDATES) do
                if ids[name] and sm:isPlayingUISound(ids[name]) then still[#still + 1] = name end
            end
            print("TITLESOUND after " .. mark / 1000 .. " s still playing: " .. (#still == 0 and "none" or table.concat(still, ", ")))
        end
    end
    if asked[10000] then
        for _, id in pairs(ids) do sm:stopUISound(id) end
        Events.OnTick.Remove(probe)
    end
end
Events.OnTick.Add(probe)
