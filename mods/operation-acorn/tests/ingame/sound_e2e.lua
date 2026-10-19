-- The sounds' combined check (SOUND-SYSTEM.md S6): the mods' own sounds known to the game, every cue's sound known, a
-- timed action's sound playing from the character as it works and stopped as it is stopped (the story's soil sample,
-- stopped midway: nothing is sent), the lock pick's sound still going past its clip (it loops) and stopped, the titles
-- with sounds shown (stamp, type, notice; heard by the player), and the title candidates of the game measured: which
-- still play 2, 5 and 10 s after being played once (a title stops its sounds, with a short fade, once it is gone). Prints [sounde2e] lines.
local OA = OperationAcorn
local Sound = PZUIKit.Sound
local t = STEPS("sounde2e")
local player = getPlayer()
local sm = getSoundManager()

-- (ours: the keyboard, the printer, the lock pick, and every installed title pick, whatever is picked)
local OWN = { "KIT_Key_1", "KIT_Key_8", "KIT_KeySpace", "KIT_KeyEnter", "KIT_KeyBack", "KIT_PrintRow", "OA_LockPick" }
for _, style in ipairs({ "stamp", "dust", "notice", "discovery", "unveil", "sink", "pulse", "bleed", "brief" }) do
    for _, name in pairs(Sound.titleSounds(style) or {}) do OWN[#OWN + 1] = name end
end
local PROBE = { "CampfireLight", "UseMatch", "UseLighter", "TuneIn", "VehicleRadioTuneIn", "HeartBeat", "WaterDrip",
    "LureHitWater", "RadioZap" }
local action, lockId, probeIds, probeAt = nil, nil, {}, nil
-- an invisible or ghost character makes no sound (the game's playSound gives 0): both off for the check, back after
local wasInvisible, wasGhost = player:isInvisible(), player:isGhostMode()
player:setInvisible(false)
player:setGhostMode(false)

local function stillPlaying()
    local still = {}
    for _, name in ipairs(PROBE) do
        if probeIds[name] and sm:isPlayingUISound(probeIds[name]) then still[#still + 1] = name end
    end
    return #still == 0 and "none" or table.concat(still, ", ")
end

t.run({
    { 0, function()
        local unknown = {}
        for _, name in ipairs(OWN) do
            if not GameSounds.isKnownSound(name) then unknown[#unknown + 1] = name end
        end
        t.check("the mods' own sounds known", #unknown == 0, table.concat(unknown, ","))
        local missing, count = {}, 0
        local kitCues = {}
        for _, style in ipairs({ "stamp", "dust", "notice", "discovery", "unveil", "sink", "pulse", "bleed", "brief", "type" }) do
            local title, line = Sound.titleSounds(style)
            -- (a typed style's keys are a list: each its own)
            for prefix, sounds in pairs({ [style .. "."] = title or {}, [style .. ".line."] = line or {} }) do
                for moment, name in pairs(sounds) do
                    if type(name) == "table" then
                        for n, key in ipairs(name) do kitCues[prefix .. moment .. n] = { sound = key } end
                    else
                        kitCues[prefix .. moment] = { sound = name }
                    end
                end
            end
        end
        for _, cues in ipairs({ OA.Sounds.CUES, BuildingUtilities.Sounds.CUES, kitCues }) do
            for cue, def in pairs(cues) do
                count = count + 1
                if def.sound and not GameSounds.isKnownSound(def.sound) then missing[#missing + 1] = cue .. "=" .. def.sound end
            end
        end
        t.check("every cue's sound known (" .. count .. ")", #missing == 0, table.concat(missing, ", "))
        -- the title candidates, played once on the screen, all together
        for _, name in ipairs(PROBE) do
            probeIds[name] = GameSounds.isKnownSound(name) and sm:playUISound(name) or nil
            if not probeIds[name] then t.say("probe", name, "not a sound") end
        end
        probeAt = getTimestampMs()
        -- a timed action with a sound, from the character
        action = ISOAStoryAction:new(player, "soil", {}, 600)
        ISTimedActionQueue.add(action)
    end },
    { 1500, function()
        t.check("the soil sample's sound from the character as it works", action.kitSound ~= nil
            and player:getEmitter():isPlaying(action.kitSound), action.kitSound)
        ISTimedActionQueue.clear(player)
    end },
    { 300, function()
        t.check("stopped with the action", action.kitSound == nil, action.kitSound)
        lockId = player:playSound(Sound.name("oa.action.pick"))
        t.check("the lock pick's sound plays", lockId ~= nil and lockId ~= 0, lockId)
        t.say("probe after " .. (getTimestampMs() - probeAt) .. " ms still playing: " .. stillPlaying())
    end },
    { 3000, function()
        t.say("probe after " .. (getTimestampMs() - probeAt) .. " ms still playing: " .. stillPlaying())
    end },
    { 4500, function()
        t.check("the lock pick's sound still going past its clip (loops)", player:getEmitter():isPlaying(lockId))
        player:stopOrTriggerSound(lockId)
        t.say("probe after " .. (getTimestampMs() - probeAt) .. " ms still playing: " .. stillPlaying())
    end },
    { 500, function()
        t.check("the lock pick's sound stopped", not player:getEmitter():isPlaying(lockId))
        for _, id in pairs(probeIds) do sm:stopUISound(id) end
        player:setInvisible(wasInvisible)
        player:setGhostMode(wasGhost)
        local id = OA.Store.idOf(player)
        t.check("a stamp title with its sounds", OA.Titles.show(id, { key = "IGUI_OA_Title_Site", sub = "IGUI_OA_Title_SiteSub",
            style = "stamp" }) ~= nil)
        t.check("a typewriter title with its sounds", OA.Titles.show(id, { key = "IGUI_OA_Title_Site", sub = "IGUI_OA_Title_SiteSub",
            style = "type" }) ~= nil)
        t.check("a notice title with its sound", OA.Titles.show(id, { key = "IGUI_OA_Title_Sealed", style = "notice" }) ~= nil)
    end },
})
