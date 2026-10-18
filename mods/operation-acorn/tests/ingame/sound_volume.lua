-- The API's fix of the game's volume (SOUND-SYSTEM.md): a mod's file sound is under its master's setting, an FMOD event's
-- clip is not touched (the game's mixer turns it down). Sets the sound manager's volume for a moment, then the option's
-- again. Prints SOUND lines.
local hooks = PZExtAPI and PZExtAPI.hooks and PZExtAPI.hooks() or {}
print("SOUND hook " .. tostring(hooks["GameSoundClip.getEffectiveVolume"]) .. " " .. tostring(hooks["GameSoundClip.getEffectiveVolumeInMenu"]))
local sm, core = getSoundManager(), getCore()
local file = GameSounds.getSound("KIT_Key"):getRandomClip()
local event = GameSounds.getSound("UIActivateButton"):getRandomClip()
print("SOUND option " .. core:getOptionSoundVolume() .. ": file " .. file:getEffectiveVolume() .. " event " .. event:getEffectiveVolume())
sm:setSoundVolume(0.5)
print("SOUND at 0.5: file " .. file:getEffectiveVolume() .. " event " .. event:getEffectiveVolume())
sm:setSoundVolume(core:getOptionSoundVolume() / 10)
print("SOUND back: file " .. file:getEffectiveVolume())
