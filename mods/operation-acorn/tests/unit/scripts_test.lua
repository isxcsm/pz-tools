-- The item scripts (media/scripts/OA_*.txt) as the game's parser needs them: every brace closed, nothing closed twice,
-- one module block per file. A file with an unclosed block loads none of its items and the game says nothing (found in
-- game: the story items were all missing).
local DIR = "OperationAcorn/42/media/scripts/"

test("every script file closes its blocks", function()
    local files = 0
    for _, name in ipairs(listfiles(DIR)) do
        if string.find(name, "^OA_.*%.txt$") then
            files = files + 1
            local text = readfile(DIR .. name)
            -- Comments may hold braces: take them out first.
            text = string.gsub(text, "/%*.-%*/", "")
            local depth, lowest, line = 0, 0, 1
            for i = 1, string.len(text) do
                local c = string.sub(text, i, i)
                if c == "{" then depth = depth + 1
                elseif c == "}" then
                    depth = depth - 1
                    if depth < lowest then lowest = depth end
                elseif c == "\n" then line = line + 1 end
            end
            eq(depth, 0, name .. ": blocks left open at the end")
            eq(lowest, 0, name .. ": a block closed that was not open")
            truthy(string.find(text, "^%s*module%s+OperationAcorn"), name .. " starts with the module")
        end
    end
    truthy(files >= 6, "found the script files")
end)
