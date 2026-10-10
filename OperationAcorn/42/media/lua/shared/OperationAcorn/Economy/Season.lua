-- The season of the in-game month and what the team wants in it (NUMBERS 2, DESIGN-terminal 5.3). The random demand
-- event (one category x1.25 for 5 days) draws its category with these weights; its line is then the team's own words
-- for the season when the category is one the season raises. Pure but for the month, which comes from the game clock.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Season = {}
OA.Season = Season

Season.NAMES = { "winter", "spring", "summer", "autumn" }

-- The weights a season gives categories (the others weigh 1): "winter" B clothing x3, F household x2, and so on.
Season.WANTS = {
    winter = { B = 3, F = 2 },
    spring = { H = 3, K = 2 },
    summer = { I = 3, C = 2 },
    autumn = { A = 3, H = 2 },
}

-- Lines the team has for each (season, category) it raises: IGUI_OA_Econ_Season_<season>_<category>_<1..LINES>.
Season.LINES = 2

-- The game's month, 1 (January) to 12. GameTime:getMonth() counts from 0 (the vanilla farming code adds one too).
function Season.month()
    return getGameTime():getMonth() + 1
end

-- December to February winter, March to May spring, June to August summer, September to November autumn.
function Season.of(month)
    if month <= 2 or month == 12 then return "winter" end
    if month <= 5 then return "spring" end
    if month <= 8 then return "summer" end
    return "autumn"
end

function Season.current()
    return Season.of(Season.month())
end

-- The weight of a category in a season.
function Season.weight(season, category)
    local wants = Season.WANTS[season]
    return wants and wants[category] or 1
end

function Season.raised(season, category)
    return Season.weight(season, category) > 1
end

-- The key of a season's line for a category (n is 1 to Season.LINES), and of the season's name.
function Season.lineKey(season, category, n)
    return "IGUI_OA_Econ_Season_" .. season .. "_" .. category .. "_" .. n
end

function Season.nameKey(season)
    return "IGUI_OA_Econ_SeasonName_" .. season
end

-- Whether an event's key is one of the season lines (they name no category: the line says it).
function Season.isLineKey(key)
    return type(key) == "string" and string.find(key, "_Econ_Season_", 1, true) ~= nil
end

-- Picks a category from `letters` by the season's weights; `roll(a, b)` is a whole random number from a to b.
function Season.pick(letters, season, roll)
    local total = 0
    for _, c in ipairs(letters) do total = total + Season.weight(season, c) end
    local at = roll(1, total)
    local acc = 0
    for _, c in ipairs(letters) do
        acc = acc + Season.weight(season, c)
        if at <= acc then return c end
    end
    return letters[#letters]
end

-- Picks a category the season does not raise (a glut never lands on what the team wants now).
function Season.pickOther(letters, season, roll)
    local rest = {}
    for _, c in ipairs(letters) do
        if not Season.raised(season, c) then rest[#rest + 1] = c end
    end
    if #rest == 0 then rest = letters end
    return rest[roll(1, #rest)]
end

return Season
