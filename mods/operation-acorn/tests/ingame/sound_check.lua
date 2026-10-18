-- The mods' own sounds (SOUND-SYSTEM.md): the kit's sound script read by the game, each of its sounds playing, and every
-- cue of the tables naming a sound the game knows (a vanilla one or one of the mods'). Prints SOUND lines.
local sm = getSoundManager()
for _, name in ipairs({ "KIT_Key_1", "KIT_Key_8", "KIT_KeySpace", "KIT_KeyEnter", "KIT_KeyBack" }) do
    print("SOUND " .. name .. " known " .. tostring(GameSounds.isKnownSound(name)) .. " id " .. tostring(sm:playUISound(name)))
end
local missing, count = {}, 0
for _, cues in ipairs({ OperationAcorn.Sounds.CUES, BuildingUtilities.Sounds.CUES }) do
    for cue, def in pairs(cues) do
        count = count + 1
        if def.sound and not GameSounds.isKnownSound(def.sound) then missing[#missing + 1] = cue .. "=" .. def.sound end
    end
end
print("SOUND cues " .. count .. " unknown: " .. (#missing == 0 and "none" or table.concat(missing, ", ")))
