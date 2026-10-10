-- P4: every document and story line renders without a missing translation, the folder and mission tabs are in the
-- terminal, the viewer opens. Marks two documents read and keeps a manifest in the record: use a throwaway save.
-- After it runs, open the terminal and look at the tabs (the folder lists the two documents and the manifest).
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4docs")
local record, player = P4T.record()
if not record then say("no record"); return end
local function missing(text) return string.find(text, "IGUI_OA_Story", 1, true) ~= nil end
local bad = 0
for _, id in ipairs(OA.StoryDocs.all()) do
    local text = OA.StoryDocs.body(record, id, "westpoint_clinic", 412)
    local title = getText(OA.StoryDocs.titleKey(id))
    if missing(text) or missing(title) then say("BAD missing text", id); bad = bad + 1 end
end
P4T.check(say, "all documents have text", bad == 0, bad)
local lines = 0
for _, list in ipairs({ OA.StoryData.STAGES, OA.StoryData.MILESTONES }) do
    for _, def in pairs(list) do
        for _, id in ipairs(def.radio) do
            if missing(getText("IGUI_OA_Story_Radio_" .. id, "0347")) then say("BAD radio", id); lines = lines + 1 end
        end
        for _, id in ipairs(def.notes) do
            if missing(getText("IGUI_OA_Story_Note_" .. id, "0347")) then say("BAD note", id); lines = lines + 1 end
        end
    end
end
P4T.check(say, "radio lines and notes have text", lines == 0, lines)
-- The radio copies in the folder: a title and a text for the first contact, each stage and milestone, the handover.
local copies = { { id = "first", keys = { "first" } }, { id = "first", keys = { "first_late" } },
    { id = "handover", keys = { OA.StoryData.HANDOVER_RADIO } } }
for n, def in pairs(OA.StoryData.STAGES) do copies[#copies + 1] = { id = "s" .. n, stage = n, keys = def.radio } end
for k, def in pairs(OA.StoryData.MILESTONES) do
    copies[#copies + 1] = { id = "m" .. k, stage = OA.StoryData.LAST_STAGE + k, keys = def.radio }
end
local badCopies = 0
for _, copy in ipairs(copies) do
    if missing(OA.Story.copyTitle(copy)) or missing(OA.Story.copyText(record, copy)) then
        say("BAD radio copy", copy.id); badCopies = badCopies + 1
    end
end
P4T.check(say, "radio copies have title and text", badCopies == 0, badCopies)
OA.Story.markRead(record, "police_card", "muldraugh_pd")
OA.Story.markRead(record, "clinic_log", "westpoint_clinic")
OA.Story.addManifest(record, 1042, "test manifest text")
OA.Sync.changed("story", record.id)
local tabs = OA.Terminal and OA.Terminal.tabs(record, player) or {}
local ids = {}
for _, t in ipairs(tabs) do ids[#ids + 1] = t.id end
say("terminal tabs now", table.concat(ids, ","))
P4T.check(say, "the folder tab is there", string.find(table.concat(ids, ","), "story_docs", 1, true) ~= nil)
OA.StoryViewer.open(player, { { id = "police_card", variant = "muldraugh_pd", noRecord = true },
                              { id = "cooler_front", noRecord = true } })
say("the viewer is open with two pages: look at the layout and the previous/next buttons")
