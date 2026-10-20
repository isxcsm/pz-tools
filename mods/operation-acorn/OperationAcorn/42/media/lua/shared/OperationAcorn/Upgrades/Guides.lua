-- The papers the research team sends to the terminal's folder for the infection (DESIGN-terminal 17.6, 18): the handling
-- notice with the first positive test, and the certificate of a cure, one of three by how long the infection lasted.
-- They are guide documents (Story/Docs): in the folder at once, new until opened, and the helicopter screen's card and the
-- comms tab's dot lead to them (11.1). Their texts are IGUI_OA_Story_DocTitle_<id> and IGUI_OA_Story_Doc_<id>.
require "OperationAcorn/Core"
require "OperationAcorn/Story/Docs"
local OA = OperationAcorn
local Docs, Story = OA.StoryDocs, OA.Story
local Guides = {}
OA.Upgrades = OA.Upgrades or {}
OA.Upgrades.Guides = Guides

Guides.NOTICE = "infection_guide"
Guides.CERT = { short = "cure_cert_short", normal = "cure_cert_normal", long = "cure_cert_long" }

-- The certificate keeps its days and doses as one number (days * 1000 + doses), the paper's `extra`.
function Guides.pack(days, doses)
    return math.min(days, 9999) * 1000 + math.min(doses, 999)
end

local function certBody(id)
    return function(record, _, extra)
        local n = tonumber(extra) or 0
        return getText("IGUI_OA_Story_Doc_" .. id, Story.number(record), math.floor(n / 1000), n - math.floor(n / 1000) * 1000)
    end
end

Docs.addGuide(Guides.NOTICE)
for _, id in pairs(Guides.CERT) do Docs.addGuide(id, certBody(id)) end

-- Puts a guide in a record's folder (once: a paper the folder has is not sent again). Returns true when it was sent.
function Guides.deliver(record, id, extra)
    return Story.deliverDocument(record, id, nil, extra)
end

-- The certificate for an infection that lasted `days` days with `doses` delay drugs, by its length ("short", "normal"
-- or "long"). Returns true when it was sent and its id.
function Guides.certify(record, length, days, doses)
    local id = Guides.CERT[length] or Guides.CERT.normal
    return Guides.deliver(record, id, Guides.pack(days, doses)), id
end

-- The title that tells a paper has come: its name over the line that leads to the terminal.
function Guides.title(playerId, id)
    OA.Sync.title(playerId, { key = Docs.titleKey(id), sub = "IGUI_OA_Title_GuideSub", style = "type" })
end

return Guides
