-- Line bundles: counting the keys, the shuffled rounds, the tags, the cooldown and self-talk.
require "OperationAcorn/Core"
require "OperationAcorn/Say"
local OA = OperationAcorn
local Say = OA.Say

-- A language with `n` lines for each bundle named in `lines`.
local function language(lines)
    getTextOrNull = function(key)
        for id, n in pairs(lines) do
            local k = tonumber(string.match(key, "^IGUI_OA_Say_" .. id .. "_(%d+)$"))
            if k and k >= 1 and k <= n then return key end
        end
        return nil
    end
end

test("a bundle has as many lines as there are keys from 1", function()
    language({ Count = 4 })
    eq(Say.count("Count"), 4)
    eq(Say.count("Nothing"), 0)
    eq(Say.key("Count", 2), "IGUI_OA_Say_Count_2")
    Say.define("Doc", { prefix = "IGUI_OA_Doc_" })
    eq(Say.key("Doc", 1), "IGUI_OA_Doc_Doc_1")
end)

test("every line once before any comes again, and a round never starts with the last line", function()
    language({ Round = 5 })
    local state = {}
    for _ = 1, 20 do
        local seen = {}
        for i = 1, 5 do
            local n = Say.pick(state, "Round", nil, 0)
            truthy(n and not seen[n], "a new line in the round")
            seen[n] = true
        end
        local last = state.Round.last
        local first = Say.pick(state, "Round", nil, 0)
        truthy(first ~= last, "the next round does not start with the line just said")
        -- finish that round
        for _ = 1, 4 do Say.pick(state, "Round", nil, 0) end
    end
end)

test("a line with tags is said only where they fit", function()
    language({ Tagged = 4 })
    Say.define("Tagged", { tags = { [1] = { night = true }, [2] = { night = true }, [3] = { night = false } } })
    local state = {}
    for _ = 1, 12 do
        local n = Say.pick(state, "Tagged", { night = false }, 0)
        truthy(n == 3 or n == 4, "a day line or one without tags")
    end
    for _ = 1, 12 do
        local n = Say.pick(state, "Tagged", { night = true }, 0)
        truthy(n == 1 or n == 2 or n == 4, "a night line or one without tags")
    end
    truthy(Say.fits("Tagged", 4, nil))
    eq(Say.fits("Tagged", 1, nil), false, "no context: a tagged line does not fit")
end)

test("nothing fits or no lines: nil, and the state is left usable", function()
    language({ Only = 1 })
    Say.define("Only", { tags = { [1] = { tree = "load" } } })
    local state = {}
    eq(Say.pick(state, "Only", { tree = "scout" }, 0), nil)
    eq(Say.pick(state, "Only", { tree = "load" }, 0), 1)
    eq(Say.pick(state, "Only", { tree = "load" }, 0), 1, "one line: it comes again")
    eq(Say.pick({}, "Empty", nil, 0), nil)
end)

test("a bundle with a cooldown says nothing until it has passed", function()
    language({ Cool = 3 })
    Say.define("Cool", { cooldown = 24 })
    local state = {}
    truthy(Say.pick(state, "Cool", nil, 10))
    eq(Say.pick(state, "Cool", nil, 20), nil, "ten hours later")
    truthy(Say.pick(state, "Cool", nil, 34.5), "a day later")
end)

test("a language with fewer lines skips the numbers it does not have", function()
    language({ Shrink = 2 })
    local state = { Shrink = { left = { 5, 4, 2 } } }
    eq(Say.pick(state, "Shrink", nil, 0), 2)
end)

test("self-talk says the line over the head, keeps the order on the character, and can be turned off", function()
    language({ Talk = 3 })
    local said, data = {}, {}
    local character = { getModData = function() return data end, Say = function(_, t) said[#said + 1] = t end }
    local key = Say.say(character, "Talk")
    truthy(key)
    eq(said[1], key)
    truthy(data.OA_Say.Talk, "the order is on the character")
    SandboxVars.OperationAcorn.Monologue = false
    eq(Say.say(character, "Talk"), nil)
    eq(#said, 1)
    SandboxVars.OperationAcorn.Monologue = true
    -- held back on the character's side
    Say.held[#Say.held + 1] = function(_, id, ctx) return id == "Talk" and ctx and ctx.seen end
    eq(Say.say(character, "Talk", { seen = true }), nil)
    truthy(Say.say(character, "Talk", {}))
    Say.held[#Say.held] = nil
end)

test("self-talk the server asks for with a delay waits for it, then says the line of that moment", function()
    language({ Late = 3 })
    local said, data = {}, { OA_Id = "me" }
    local player = { getModData = function() return data end, Say = function(_, t) said[#said + 1] = t end,
        isDead = function() return false end }
    getPlayer = function() return player end
    Say.tell("me", "Late", nil, 2.5)
    eq(#said, 0, "not yet")
    TEST.fire("OnTick")
    eq(#said, 1, "the clock has moved on")
    Say.tell("me", "Late")
    eq(#said, 2, "no delay: at once")
    Say.tell("someone", "Late")
    eq(#said, 2, "another player's line is not said here")
    player.isDead = function() return true end
    Say.tell("me", "Late", nil, 2.5)
    TEST.fire("OnTick")
    eq(#said, 2, "a character who died in between says nothing")
    getPlayer = nil
end)

