-- P4: every document and story line renders without a missing translation, the folder and mission tabs are in the
-- terminal, the viewer opens. Marks two documents read in the record: use a throwaway save. After it runs, open the
-- terminal and look at the tabs (the folder lists the two documents). It adds no manifest: the folder's manifests are
-- the helicopter's, and a test number added on every run once showed up as one manifest three times.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4docs")
local record, player = P4T.record()
if not record then say("no record"); return end
local function missing(text) return string.find(text, "IGUI_OA_Story", 1, true) ~= nil end
local bad = 0
for _, id in ipairs(OA.StoryDocs.all()) do
    local text = OA.StoryDocs.body(record, id, "medical", 412)
    local title = getText(OA.StoryDocs.titleKey(id))
    if missing(text) or missing(title) then say("BAD missing text", id); bad = bad + 1 end
end
P4T.check(say, "all documents have text", bad == 0, bad)
local lines = 0
for _, list in ipairs({ OA.StoryData.STAGES, OA.StoryData.MILESTONES }) do
    for _, def in pairs(list) do
        for _, id in ipairs(def.notes) do
            if missing(getText("IGUI_OA_Story_Note_" .. id, "0347")) then say("BAD note", id); lines = lines + 1 end
        end
    end
end
P4T.check(say, "notes have text", lines == 0, lines)
OA.Story.markRead(record, "police_card", "police")
OA.Story.markRead(record, "clinic_log", "medical")
OA.Sync.changed("story", record.id)
P4T.check(say, "the comms tab (with the folder) is given", OA.Terminal and OA.Terminal.tab("comms") ~= nil)
P4T.check(say, "the folder lists the two documents", #OA.StoryFolder.flat(OA.StoryFolder.entries(record)) >= 2)
OA.StoryViewer.open(player, { { id = "police_card", variant = "police", noRecord = true },
                              { id = "cooler_front", noRecord = true } })
say("the viewer is open with two pages: look at the layout and the previous/next buttons")
