-- Line bundles (DESIGN-terminal 18): the self-talk and the texts that come again are drawn from bundles so that the
-- same event does not say the same sentence each time. A bundle's lines are translation keys `<prefix><id>_<n>` from
-- 1 up to the first one missing, so each language can have its own number of lines; what a line needs (night, a long
-- infection, a tree...) is in the bundle's table here, by line number, never in the key.
--
-- Drawing: every line of a bundle is used once before any comes again, in a shuffled order, and a new round never
-- starts with the line just said. Only the order left is kept, in a state table the caller gives (the character's
-- mod data for self-talk, a record's section for what the server sends).
require "OperationAcorn/Core"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Later"
local OA = OperationAcorn
local Say = {}
OA.Say = Say

-- The bundles: [id] = { prefix (default IGUI_OA_Say_), tags = { [line] = { tag = value } }, cooldown (game hours
-- between two lines, none by default) }. Units add theirs with Say.define.
Say.BUNDLES = {}

function Say.define(id, def)
    Say.BUNDLES[id] = def or {}
end

local function text(key)
    if getTextOrNull then return getTextOrNull(key) end
    local t = getText(key)
    if t ~= key then return t end
    return nil
end

function Say.key(id, n)
    local def = Say.BUNDLES[id]
    if def and def.prefix then return def.prefix .. id .. "_" .. n end
    return "IGUI_OA_Say_" .. id .. "_" .. n
end

-- How many lines a bundle has in the language played (counted once: a language changes only with a restart).
local counts = {}
function Say.count(id)
    local n = counts[id]
    if not n then
        n = 0
        while text(Say.key(id, n + 1)) do n = n + 1 end
        counts[id] = n
    end
    return n
end

-- Whether line n of a bundle may be said in a context: every tag the line has must have that value in it.
function Say.fits(id, n, ctx)
    local def = Say.BUNDLES[id]
    local tags = def and def.tags and def.tags[n]
    if not tags then return true end
    for tag, value in pairs(tags) do
        if (ctx and ctx[tag]) ~= value then return false end
    end
    return true
end

-- A new round of a bundle's lines, shuffled, the line just said put last.
local function round(count, last)
    local order = {}
    for i = 1, count do order[i] = i end
    for i = count, 2, -1 do
        local j = OA.random(1, i)
        order[i], order[j] = order[j], order[i]
    end
    if last and count > 1 then
        for i, n in ipairs(order) do
            if n == last then
                table.remove(order, i)
                order[#order + 1] = n
                break
            end
        end
    end
    return order
end

local function take(s, id, count, ctx)
    for i, n in ipairs(s.left) do
        if n <= count and Say.fits(id, n, ctx) then
            table.remove(s.left, i)
            return n
        end
    end
    return nil
end

-- The next line of a bundle for a context: its number, or nil (no line fits, the bundle has none, or it is in its
-- cooldown). `state` keeps the order left per bundle: state[id] = { left = { n... }, last, at }.
function Say.pick(state, id, ctx, now)
    local count = Say.count(id)
    if count == 0 then return nil end
    local def = Say.BUNDLES[id] or {}
    local s = state[id]
    if not s then
        s = { left = {} }
        state[id] = s
    end
    now = now or OA.hours()
    if def.cooldown and s.at and now - s.at < def.cooldown then return nil end
    local n = take(s, id, count, ctx)
    if not n then
        s.left = round(count, s.last)
        n = take(s, id, count, ctx)
    end
    if not n then return nil end
    s.last, s.at = n, now
    return n
end

-- The key of the next line, or nil.
function Say.line(state, id, ctx, now)
    local n = Say.pick(state, id, ctx, now)
    return n and Say.key(id, n) or nil
end

-- What holds a line back on the character's side: functions (character, id, ctx) -> true when it would be said
-- out of turn (a hint about a piece the character has seen already: Story/Highlight).
Say.held = {}

-- Self-talk: the character says the next line of a bundle over its head (the sandbox option 혼잣말, on by
-- default), unless something holds it (Say.held). The order is kept in the character's mod data, so it goes on after
-- a reload. Returns the key said.
function Say.say(character, id, ctx)
    if not character or OA.option("Monologue") == false then return nil end
    for _, hold in ipairs(Say.held) do
        if hold(character, id, ctx) then return nil end
    end
    local data = character:getModData()
    data.OA_Say = data.OA_Say or {}
    local key = Say.line(data.OA_Say, id, ctx)
    if key then character:Say(getText(key)) end
    return key
end

-- Self-talk the server's side asks for (a mission's place reached, a drop site stood at, a cure that took): the
-- player's own client says it, alone at once. ctx is the context the bundle's tags are matched against; `delay` is
-- real seconds to wait first (a stamp on the screen is let be read), the line is drawn when it is said.
function Say.tell(playerId, id, ctx, delay)
    if isServer() then
        sendServerCommand(OA.MOD, "say", { player = playerId, id = id, ctx = ctx, delay = delay })
    else
        OA.Sync.deliver("say", playerId, { id = id, ctx = ctx, delay = delay })
    end
end

-- A story monologue (SCENES.md 2): a line of the story's own (a translation key, not a bundle) that the server asks the
-- player's client to say, once, as the game says any line (no second saying to hold it longer: the game's own way is
-- left as it is). `delay` is real seconds to wait first, as Say.tell's.
function Say.story(playerId, key, delay)
    if isServer() then
        sendServerCommand(OA.MOD, "storySay", { player = playerId, key = key, delay = delay })
    else
        OA.Sync.deliver("storySay", playerId, { key = key, delay = delay })
    end
end

OA.Sync.listen("storySay", function(playerId, detail)
    local player = getPlayer and getPlayer()
    if not (player and detail and type(detail.key) == "string") or OA.Store.idOf(player) ~= playerId then return end
    if OA.option("Monologue") == false then return end
    local line = getText(detail.key)
    if type(detail.delay) == "number" and detail.delay > 0 then
        OA.Trade.Later.after(detail.delay, function()
            local now = getPlayer and getPlayer()
            if now == player and not now:isDead() then now:Say(line) end
        end)
        return
    end
    player:Say(line)
end)

OA.Sync.listen("say", function(playerId, detail)
    local player = getPlayer and getPlayer()
    if not (player and detail) or OA.Store.idOf(player) ~= playerId then return end
    if type(detail.delay) == "number" and detail.delay > 0 then
        OA.Trade.Later.after(detail.delay, function()
            local now = getPlayer and getPlayer()
            if now and not now:isDead() and OA.Store.idOf(now) == playerId then Say.say(now, detail.id, detail.ctx) end
        end)
        return
    end
    Say.say(player, detail.id, detail.ctx)
end)

return Say
