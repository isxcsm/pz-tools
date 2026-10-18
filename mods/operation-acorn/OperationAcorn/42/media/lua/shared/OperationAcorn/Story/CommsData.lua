-- The team's calls (SCENES.md 3, 4; LORE 6): the scenes played in the terminal's comms tab, the short one-way calls that
-- come into it, the two calls on the spot (the field call device), and the field monologues the tab keeps as field
-- records. Only ids, speakers and rules are here: every line's text is a translation (IGUI_OA_Comms_<id>_<n>, the erased
-- words of a line IGUI_OA_Comms_<id>_<n>_x), with {cut:N} (the signal breaks up for N seconds), {mute:N} (nothing comes
-- for N seconds) and the kit's {p:N} pauses in it. A save keeps only ids (Story/Comms).
require "OperationAcorn/Core"
local OA = OperationAcorn
local Data = {}
OA.CommsData = Data

-- Kinds: "scene" (played in the comms tab), "short" (a one-way call: a line that comes into the tab), "field" (a call on
-- the spot, over the screen, while the game runs), "say" (a field monologue over the character's head, kept in the tab
-- as a field record).
--
-- Fields of an entry:
--   trigger  what fires it: "first" (the terminal is first used), "settled" (a crate's settlement), "serum" (the first
--            enhanced serum), "tier:N" (trust tier N entered), "story:<id>" (that story mission's box was settled; the
--            handover mission: ended), "brief:<key>" (that story mission is being started: CommsData.BRIEFS), "field:<id>" (that story mission's helicopter is coming), "crate:N" (the first
--            supply crate landed at tier N), "sent:<doc>" (that 2반 paper has gone in a crate), "after:<id>:<hours>"
--            (game hours after that scene was played), "nextday:<id>" (a game day after the one that scene was played
--            on), "handedover" (the handover's last crate opened), "say:<story id>:<event>" (a field monologue, said by the mission's code)
--   tier     the trust tier the entry belongs to: a terminal entry not fired by the time the tier is passed is dropped
--   mission  fired by a story mission: never dropped
--   keep     never dropped (the scene after the handover)
--   world    a one-time event of the team's (the line going dead, Ordway's transfer, the cut air time, the radio
--            operator gone) at that tier: a character that comes into the world after a character has reached it never
--            hears it (Comms.join)
--   era      "admin": fires only for a character that came into the world after the handover (its first calls with
--            관리 7, in the place of the team's); entries without one never fire for it up to TEAM_LAST_TIER
--   waits    the entry that must have been played (or dropped) first
--   greet    the first line opens with the greeting of the tier it is played at (LORE 6)
--   sign     the call sign: "oak" (참나무) or "admin" (관리 7)
--   lines    { speaker, ... }: "oak" (the team), "me" (the protagonist), "noise" (static only, `s` seconds), "mute"
--            (nothing, `s` seconds); `erase` on a "me" line: words typed and deleted first (key _x); `late` on a line: a
--            text of its own (key _late) when the first crate came late; `pause` on a line: a beat before it (seconds:
--            a turn of thought between two lines of one speaker); `stop`, `del`, `after` on an erased line: how long the
--            erased words sit, how fast they are deleted (characters a second), the thinking before the sent words
--            (CommsScript's ERASE_ when left out): longer as the feeling turns further between them
Data.ENTRIES = {
    -- The briefings (SCENES 4): played as the player starts a story mission, before any other call waiting; the mission
    -- begins when one is over. Keyed by the story (a choice's option, the soil sample's place).
    { id = "B1", kind = "scene", trigger = "brief:evidence", tier = 1, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "B2", kind = "scene", trigger = "brief:clinic", tier = 2, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "B3a", kind = "scene", trigger = "brief:observation_a", tier = 3, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "B3b", kind = "scene", trigger = "brief:observation_b", tier = 3, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "B4", kind = "scene", trigger = "brief:cooler", tier = 4, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "B5", kind = "scene", trigger = "brief:gym", tier = 5, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "B6", kind = "scene", trigger = "brief:ward", tier = 6, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "B7", kind = "scene", trigger = "brief:cells", tier = 7, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "BS1", kind = "scene", trigger = "brief:soil_site", tier = 7, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "BS2", kind = "scene", trigger = "brief:soil_plain", tier = 7, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "B8", kind = "scene", trigger = "brief:handover", tier = 8, mission = true, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "BR1", kind = "scene", trigger = "brief:revisit_ledger", tier = 9, mission = true, sign = "admin", lines = {
        { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "BR2", kind = "scene", trigger = "brief:revisit_roster", tier = 10, mission = true, sign = "admin", lines = {
        { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "BR3", kind = "scene", trigger = "brief:revisit_police", tier = 11, mission = true, sign = "admin", lines = {
        { "me" }, { "oak" }, { "noise", s = 1 } } },

    { id = "S0", kind = "scene", trigger = "first", tier = 0, sign = "oak", lines = {
        { "noise", s = 2 }, { "oak" }, { "mute", s = 3 }, { "oak" },
        { "me", erase = true, stop = 1.6, after = 1.8 }, { "oak" }, { "me" }, { "oak" },
        { "me", late = true }, { "oak", late = true }, { "me" }, { "oak" }, { "me", erase = true }, { "oak" },
        { "me" }, { "noise", s = 3 } } },
    { id = "S1", kind = "scene", trigger = "settled", tier = 1, waits = "S0", greet = true, sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "me", pause = 2 }, { "oak" }, { "me" },
        { "oak" },
        { "me", erase = true, stop = 1.6, after = 2.2 } } },
    -- what the missions are: after the first settlement's call; no mission is offered before it (Missions.opened)
    { id = "S1M", kind = "scene", trigger = "settled", tier = 1, waits = "S1", sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "s1_bedding", kind = "short", trigger = "tier:1", tier = 1, waits = "S1", greet = true, sign = "oak" },
    { id = "S1F", kind = "scene", trigger = "story:evidence", tier = 1, mission = true, waits = "S1", sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "me", pause = 1 }, { "oak" } } },
    { id = "S2", kind = "scene", trigger = "serum", tier = 2, waits = "S1", greet = true, sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" },
        { "me", erase = true, stop = 1.8, after = 2 }, { "oak" } } },
    { id = "S2B", kind = "scene", trigger = "after:S2:12", tier = 2, waits = "S2", sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "noise", s = 3 } } },
    { id = "s2_filter", kind = "short", trigger = "tier:2", tier = 2, waits = "S1", greet = true, sign = "oak" },
    { id = "s2_correction", kind = "short", trigger = "sent:reply_first", tier = 2, waits = "S1", greet = true, sign = "oak" },
    { id = "S2F", kind = "scene", trigger = "story:clinic", tier = 2, mission = true, waits = "S1", sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" } } },
    { id = "S3", kind = "scene", trigger = "tier:3", tier = 3, waits = "S2B", greet = true, sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" } } },
    { id = "s3_meteor", kind = "short", trigger = "tier:3", tier = 3, waits = "S3", greet = true, sign = "oak" },
    { id = "s3_fragment", kind = "short", trigger = "sent:reply_fragment", tier = 3, waits = "S3", greet = true, sign = "oak" },
    { id = "S4", kind = "scene", trigger = "tier:4", tier = 4, waits = "S3", world = 4, sign = "oak", lines = {
        { "noise", s = 5 }, { "me" }, { "noise", s = 3 }, { "me" }, { "mute", s = 4 }, { "me", erase = true },
        { "noise", s = 2 } } },
    { id = "S4B", kind = "scene", trigger = "nextday:S4", tier = 4, waits = "S4", world = 4, greet = true, sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" },
        { "me", erase = true, stop = 1.6, after = 2 } } },
    { id = "s4_committee", kind = "short", trigger = "tier:4", tier = 4, waits = "S4B", greet = true, sign = "oak" },
    { id = "S4F", kind = "scene", trigger = "story:cooler", tier = 4, mission = true, waits = "S4B", sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" },
        { "me", erase = true, stop = 1.6, after = 1.8 } } },
    { id = "S5", kind = "scene", trigger = "tier:5", tier = 5, waits = "S4B", world = 5, sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" } } },
    { id = "S5F", kind = "field", trigger = "field:gym", tier = 5, mission = true, sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "oak" }, { "oak" } } },
    { id = "S6", kind = "scene", trigger = "crate:6", tier = 6, waits = "S5", sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me", erase = true, stop = 1.6, after = 1.8 },
        { "me", pause = 1.5 }, { "oak" } } },
    { id = "s6_list", kind = "short", trigger = "tier:6", tier = 6, waits = "S6", greet = true, sign = "oak" },
    { id = "S6F", kind = "scene", trigger = "story:ward", tier = 6, mission = true, waits = "S6", sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" } } },
    { id = "S7", kind = "scene", trigger = "crate:7", tier = 7, waits = "S6", world = 7, sign = "oak", lines = {
        { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" } } },
    { id = "s7_list", kind = "short", trigger = "tier:7", tier = 7, waits = "S7", greet = true, sign = "oak" },
    { id = "S7F", kind = "scene", trigger = "story:cells", tier = 7, mission = true, waits = "S7", sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" } } },
    { id = "s8_handover", kind = "short", trigger = "tier:8", tier = 8, waits = "S7", greet = true, sign = "oak" },
    { id = "S8F", kind = "field", trigger = "field:handover", tier = 8, mission = true, sign = "oak", lines = {
        { "oak" }, { "me", erase = true, stop = 1.8, after = 1.8 }, { "oak" } } },
    { id = "S8", kind = "scene", trigger = "story:handover", tier = 8, mission = true, waits = "S7", sign = "oak", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" }, { "oak" },
        { "me", erase = true, stop = 2, del = 5, after = 2.2 }, { "oak" }, { "oak" },
        { "oak" }, { "me", pause = 1.2 }, { "noise", s = 5 } } },
    { id = "S9", kind = "scene", trigger = "handedover", tier = 8, keep = true, waits = "S8", sign = "admin", lines = {
        { "oak" }, { "me" }, { "oak" }, { "me" }, { "oak" },
        { "me", erase = true, stop = 2.2, del = 5, after = 2.6 } } },
    -- A character that came into the world after the handover: 관리 7's first contact and its call after the first
    -- settlement (what the missions are), in the place of S0 and S1M.
    { id = "K0", kind = "scene", trigger = "first", tier = 0, era = "admin", sign = "admin", lines = {
        { "noise", s = 2 }, { "oak" }, { "mute", s = 3 }, { "oak" },
        { "me", erase = true, stop = 1.6, after = 1.8 }, { "oak" }, { "me", late = true }, { "oak", late = true },
        { "me" }, { "oak" }, { "me", erase = true }, { "oak" }, { "me" }, { "noise", s = 3 } } },
    { id = "K0M", kind = "scene", trigger = "settled", tier = 1, era = "admin", waits = "K0", sign = "admin", lines = {
        { "oak" }, { "me" }, { "oak" }, { "noise", s = 1 } } },
    { id = "K1", kind = "scene", trigger = "tier:9", tier = 9, waits = "S9", sign = "admin", lines = { { "oak" } } },
    { id = "K2", kind = "scene", trigger = "tier:10", tier = 10, waits = "K1", sign = "admin", lines = {
        { "oak" }, { "me" }, { "oak" } } },
    { id = "K3", kind = "scene", trigger = "tier:11", tier = 11, waits = "K2", sign = "admin", lines = {
        { "oak" }, { "me" } } },
    { id = "K4", kind = "scene", trigger = "tier:12", tier = 12, waits = "K3", sign = "admin", lines = {
        { "oak" }, { "me", erase = true, stop = 2, del = 5, after = 2 } } },

    -- Field monologues (SCENES 4, 5): said once over the character's head and kept in the tab as field records.
    -- `say:<story id>:<event>`: enter (the circle first entered), pickup (the story's item taken), put (the sealed case
    -- left), waited (the wait at the drop is over), plank (the last plank of the cells' door off).
    { id = "P1_enter", kind = "say", trigger = "say:evidence:enter", tier = 1 },
    { id = "S1F_pickup", kind = "say", trigger = "say:evidence:pickup", tier = 1 },
    { id = "S2F_put", kind = "say", trigger = "say:clinic:put", tier = 2 },
    { id = "S2F_waited", kind = "say", trigger = "say:clinic:waited", tier = 2 },
    { id = "S2F_pickup", kind = "say", trigger = "say:clinic:pickup", tier = 2 },
    { id = "P3a_enter", kind = "say", trigger = "say:observation_a:enter", tier = 3 },
    { id = "P3b_enter", kind = "say", trigger = "say:observation_b:enter", tier = 3 },
    { id = "P4_enter", kind = "say", trigger = "say:cooler:enter", tier = 4 },
    { id = "S4F_pickup", kind = "say", trigger = "say:cooler:pickup", tier = 4 },
    { id = "P5_enter", kind = "say", trigger = "say:gym:enter", tier = 5 },
    { id = "S6F_pickup", kind = "say", trigger = "say:ward:pickup", tier = 6 },
    { id = "S7F_plank", kind = "say", trigger = "say:cells:plank", tier = 7 },
}

Data.BY_ID = {}
-- The briefings by the key their trigger names (Missions.briefOf).
Data.BRIEFS = {}
for i, e in ipairs(Data.ENTRIES) do
    e.order = i
    Data.BY_ID[e.id] = e
    local key = string.match(e.trigger, "^brief:(.+)$")
    if key then Data.BRIEFS[key] = e.id end
end

-- The field monologues of the story missions after the handover: one at each, on entering the circle, in turn; when
-- all are said there are no more (SCENES 5).
Data.AFTER_SAYS = { "A1", "A2", "A3", "A4" }

-- The last tier of the team's own calls (the handover's): a character that comes into the world after the handover
-- has none of them (Comms.join).
Data.TEAM_LAST_TIER = 8

-- The last tier that has a greeting of its own: 1 to 4; 5 to 8 open with the number; after the handover the long form.
Data.GREETED = { [1] = true, [2] = true, [3] = true, [4] = true }

return Data
