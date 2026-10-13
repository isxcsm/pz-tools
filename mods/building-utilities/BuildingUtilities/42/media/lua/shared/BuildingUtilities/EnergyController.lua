-- How a panel's units hand the load to a generator and take it back (BU.Energy), by fixed rules at every tier: the
-- bank carries it down to HANDOVER while a generator can take over, and takes it back once it holds TAKE_BACK or the
-- solar panels make the load with the margin to start. A generator never charges the bank. A player may switch to
-- solar earlier by hand.
local BU = BuildingUtilities
local Energy = BU.Energy

-- Shares of the bank: below HANDOVER the load goes to a generator that can take it; at TAKE_BACK the bank takes it
-- back. With no generator to hand over to, the bank is drawn empty and carries the load again from BANK_START.
Energy.HANDOVER, Energy.TAKE_BACK = 0.20, 0.80

-- How the source runs for a panel this minute: load (what its devices draw), floor (the share of the bank it is not
-- drawn below: HANDOVER while a generator could take over, else none), restart (the share it needs to carry the load
-- again: TAKE_BACK while a generator could carry it, else BANK_START) and generators (whether a generator of the panel
-- could take over: on a loaded square, as the API hands over only to those, with fuel, not broken, and not out of
-- service: one a player switched off by hand the API never starts).
function Energy.rules(panel, state)
    local generators = false
    for _, producer in ipairs(state.producers or {}) do
        if not producer.source and not producer.outOfService and getCell():getGridSquare(producer.x, producer.y, producer.z)
                and (producer.fuel == nil or producer.fuel > 0) and (producer.condition == nil or producer.condition > 0) then
            generators = true
        end
    end
    return { load = math.max(0, state.load or 0), floor = generators and Energy.HANDOVER or 0,
        restart = generators and Energy.TAKE_BACK or Energy.BANK_START, generators = generators }
end

-- Whether the source is ready to take the load over from a generator, by its rules: the solar panels make it with
-- the margin to start, or the bank holds more than its restart share. Its output and bank as Energy.run left them.
function Energy.ready(rules, output, bank)
    return Energy.canCarry(output, rules.load, false) or (bank ~= nil and bank.usable > bank.capacity * rules.restart)
end

-- The share of the bank "switch to solar" needs: BANK_START over the floor, so that the bank does not hand the load
-- straight back.
function Energy.switchShare(rules) return rules.floor + Energy.BANK_START end

-- "Switch to solar": whether a player may hand the load of a panel from the generator in use to its source now
-- (offered: the panel has a source, its power is on and something else supplies it), whether the source is ready to
-- carry it (its solar panels make the load with the margin, or the bank holds its switch share), and the source's
-- rules when offered. The API then switches the generator off, on standby: it takes over again when the source falls
-- short. The panel does the same on its own once the source is ready by its rules (Energy.ready).
function Energy.sourceOffer(panel, state)
    if not (Energy.hasSource(panel) and state and state.supplied and not Energy.inUse(state)
            and BU.Networks.powerAllowed(panel)) then
        return false, false, nil
    end
    local rules = Energy.rules(panel, state)
    local output, bank = Energy.output(panel), Energy.bank(panel)
    local ready = Energy.canCarry(output, rules.load, false)
        or (bank ~= nil and bank.usable > bank.capacity * Energy.switchShare(rules))
    return true, ready, rules
end

-- Why the source is not ready to take the load over, in words.
function Energy.notReadyText(rules)
    return getText("IGUI_BU_Reason_sourceNotReady", BU.percent(Energy.switchShare(rules) * 100))
end
