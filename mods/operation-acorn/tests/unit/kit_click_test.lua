-- Every drawn control of the mods answers a click with its sound (PZUIKit UI.click, UI.placeClick, UI.clickSound): a
-- mouse handler that does neither, nor says where its sound is or why it has none ("(sound: ...)", "(silent: ...)"
-- next to it), is one more control that clicks silently. Read from the sources of this mod, Building Utilities and the
-- UI kit, a class's handlers together.

local ROOTS = {
    "OperationAcorn/42/media/lua/client",
    "../building-utilities/BuildingUtilities/42/media/lua/client",
    "../pz-ui-kit/PZUIKit/42/media/lua/client",
}

local function luaFiles(dir, out)
    for _, name in ipairs(listfiles(dir)) do
        local path = dir .. "/" .. name
        if string.match(name, "%.lua$") then out[#out + 1] = path
        elseif not string.find(name, ".", 1, true) then luaFiles(path, out) end
    end
    return out
end

local HANDLERS = { onMouseDown = true, onMouseUp = true, onMouseDoubleClick = true, onRightMouseDown = true,
    onRightMouseUp = true }

local function answers(line)
    return string.find(line, "UI.click(", 1, true) or string.find(line, "UI.placeClick(", 1, true)
        or string.find(line, "UI.clickSound(", 1, true) or string.find(line, "(sound:", 1, true)
        or string.find(line, "(silent:", 1, true)
end

test("every mouse handler of the mods' controls sounds its click through the kit, or says why not", function()
    local files = {}
    for _, root in ipairs(ROOTS) do luaFiles(root, files) end
    assert(#files > 50, "the client files found")
    local classes, order, found = {}, {}, 0
    for _, path in ipairs(files) do
        local lines = {}
        for line in string.gmatch(readfile(path), "([^\n]*)\n?") do lines[#lines + 1] = line end
        for i, line in ipairs(lines) do
            local class, handler = string.match(line, "^function ([%w_]+):([%w_]+)%(")
            if class and HANDLERS[handler] then
                found = found + 1
                local key = path .. " " .. class
                local c = classes[key]
                if not c then
                    c = { at = path .. ":" .. i .. " " .. class, ok = false }
                    classes[key] = c
                    order[#order + 1] = key
                end
                if i > 1 and answers(lines[i - 1]) then c.ok = true end
                local j = i
                -- the body: to the function's own end, or the line itself for a one-line handler
                if not string.match(line, " end$") then
                    j = i + 1
                    while lines[j] and lines[j] ~= "end" do j = j + 1 end
                end
                for k = i, math.min(j, #lines) do
                    if answers(lines[k]) then c.ok = true end
                end
            end
        end
    end
    assert(found > 30, "the handlers found")
    local bad = {}
    for _, key in ipairs(order) do
        if not classes[key].ok then bad[#bad + 1] = classes[key].at end
    end
    eq(table.concat(bad, "\n"), "")
end)
