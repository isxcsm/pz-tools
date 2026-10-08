-- The research team's own radio frequency (DESIGN 9: the radio is for listening; trade is by the terminal). A
-- dynamic channel, set up while the game loads its radio scripts, on a frequency that is free in this game: the vanilla
-- channels are fixed in RadioData.xml (89.4, 91.2, 93.2, 94.2, 95.0, 98.0, 101.2, 107.6) and the emergency broadcast
-- picks a random one from 88.0 to 108.0 in steps of 0.2; none of them is taken. The broadcast repeats the terminal's
-- radio log briefly; nothing essential is only here (LORE 2).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Story"
local OA = OperationAcorn
local Radio = {}
OA.StoryRadio = Radio

Radio.UUID = "OAK-2B-4417"
-- Preferred frequencies, in order, kHz (multiples of 200 as the game's own). The first that is free is used.
Radio.CANDIDATES = { 104600, 103800, 105400, 99800, 96600, 100600, 102200 }
-- On the air at these hours (game hour of the day).
Radio.HOURS = { [7] = true, [13] = true, [19] = true }

local function modData()
    return getGameTime():getModData()
end

-- The frequency in use, or nil before the channel is set up (kHz).
function Radio.frequency()
    return modData().OA_RadioFrequency
end

-- The frequency as the radio shows it, in MHz with a decimal.
function Radio.frequencyText()
    local f = Radio.frequency()
    if not f then return nil end
    return string.format("%.1f", f / 1000)
end

local function taken(scriptManager)
    local used = {}
    local list = scriptManager:getChannelsList()
    for i = 0, list:size() - 1 do used[list:get(i):GetFrequency()] = true end
    return used
end

-- A frequency no channel has: the saved one if still free, else the first free candidate, else a random free one.
function Radio.choose(used, saved, candidates, random)
    if saved and not used[saved] then return saved end
    for _, f in ipairs(candidates or Radio.CANDIDATES) do
        if not used[f] then return f end
    end
    for _ = 1, 200 do
        local f = (random or OA.random)(440, 540) * 200
        if not used[f] then return f end
    end
    return nil
end

-- The most advanced record (the broadcast is the world's, not one player's).
local function leadRecord()
    local best, score
    for _, record in pairs(OA.Store.players()) do
        local stage, milestones = OA.Story.progress(record)
        local s = stage + milestones * 10 + (OA.Story.handedOver(record) and 100 or 0)
        if not score or s > score then best, score = record, s end
    end
    return best
end

-- The lines on the air at an hour: the greeting and a line or two of the stage. Strings.
function Radio.lines(record)
    local lines = {}
    if not record then
        lines[1] = getText("IGUI_OA_Story_Broadcast_idle")
        return lines
    end
    local greeting = OA.Story.greeting(record)
    if greeting and greeting ~= "" then lines[#lines + 1] = greeting end
    local stage, milestones = OA.Story.progress(record)
    local key = OA.Story.handedOver(record) and "H" or tostring(OA.clamp(stage, 0, 5))
    local count = OA.StoryData.BROADCAST_LINES[key] or 1
    local n = OA.random(1, math.max(1, count))
    lines[#lines + 1] = getText("IGUI_OA_Story_Broadcast_" .. key .. "_" .. n, OA.Story.number(record))
    lines[#lines + 1] = getText("IGUI_OA_Story_Broadcast_end")
    return lines
end

local function broadcast(channel, gametime)
    local hour = gametime:getHour()
    if not Radio.HOURS[hour] then return end
    local bc = RadioBroadCast.new("OA-" .. tostring(OA.random(100000, 999999)), -1, -1)
    for _, text in ipairs(Radio.lines(leadRecord())) do
        bc:AddRadioLine(RadioLine.new(text, 0.65, 0.85, 0.65))
    end
    channel:setAiringBroadcast(bc)
end

local function onLoadRadioScripts(scriptManager, isNewGame)
    local data = modData()
    local freq = Radio.choose(taken(scriptManager), data.OA_RadioFrequency)
    if not freq then
        OA.log("no free radio frequency")
        return
    end
    data.OA_RadioFrequency = freq
    local channel = DynamicRadioChannel.new(getText("IGUI_OA_Story_RadioChannel"), freq, ChannelCategory.Military, Radio.UUID)
    scriptManager:AddChannel(channel, false)
    -- The game's dynamic radio calls a script's OnEveryHour for each channel it has cached by uuid.
    if DynamicRadio then
        DynamicRadio.cache[Radio.UUID] = channel
        table.insert(DynamicRadio.scripts, {
            channelUUID = Radio.UUID,
            OnEveryHour = function(ch, gametime, radio) broadcast(ch, gametime) end,
        })
    end
    OA.log("radio channel at", freq)
end

Events.OnLoadRadioScripts.Add(onLoadRadioScripts)

return Radio
