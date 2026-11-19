-- BaseAIGuard: diagnostic + optional guard for NPCs that Skynet skips ("neither enemy nor ally", e.g. Rath
-- fighting on the party's side). The game's own AI then decides their turn, and with hundreds of spells
-- (Absolute's Laboratory etc.) that can take a minute or more of frozen game (seen: 62 s + 44 s freezes on
-- Rath's turn). Lua cannot interrupt the engine while it thinks, so the only fix is to stop it starting.
--   wcc_baseai log   : only log "BASEAI" lines with the spell count (default)
--   wcc_baseai skip  : end the turn at once for such NPCs that have more than <limit> spells
--   wcc_baseai limit <n>   (default 40)      wcc_baseai off
local mode, limit = "log", 40

local function SpellCount(guid)
    local ok, n = pcall(function()
        local e = Ext.Entity.Get(guid)
        local c = 0
        for _ in pairs(e.SpellBook.Spells) do c = c + 1 end
        return c
    end)
    return ok and n or -1
end

local function IsPartyMember(guid)
    local ok, r = pcall(function() return Osi.IsPartyMember(guid, 1) == 1 end)
    return ok and r
end

Ext.Osiris.RegisterListener("TurnStarted", 1, "after", function(obj)
    if mode == "off" or type(obj) ~= "string" then return end
    local ok, isChar = pcall(function() return Osi.IsCharacter(obj) == 1 end)
    if not ok or not isChar or IsPartyMember(obj) then return end
    local host = Osi.GetHostCharacter()
    local okE, enemy = pcall(function() return Osi.IsEnemy(obj, host) == 1 end)
    if okE and enemy then return end -- enemies are Skynet's job
    local n = SpellCount(obj)
    if n >= 25 then
        local name = WCC and WCC.Label and WCC.Label(obj) or obj
        if WCC and WCC.Log then pcall(WCC.Log, "BASEAI", string.format("%s: not an enemy, %d spells, mode=%s", name, n, mode)) end
        if mode == "skip" and n > limit then
            Ext.Timer.WaitFor(200, function() pcall(Osi.EndTurn, obj) end)
            if WCC and WCC.Log then pcall(WCC.Log, "BASEAI", name .. ": turn ended at once (too many spells for the base AI)") end
        end
    end
end)

Ext.RegisterConsoleCommand("wcc_baseai", function(_, a, b)
    if a == "log" or a == "skip" or a == "off" then mode = a
    elseif a == "limit" and tonumber(b) then limit = tonumber(b) end
    Ext.Utils.Print(string.format("[WCC] BaseAIGuard mode=%s limit=%d", mode, limit))
end)
