-- Freeze: holds combats the party is NOT part of.
--
-- Every combat has its own GUID and its own turn order. A "foreign" combat is one where no
-- party member is a participant (e.g. refugees vs. druids outside while you fight inside).
-- Freezing a foreign combat PAUSES it with the game's own PauseCombat (the call vanilla scripts use
-- while a dialog plays mid-fight). Everyone stays in the combat, no turns are processed, nobody is
-- removed from it. The only method; the older "take them out of combat" one was removed because story
-- scripts read a character leaving combat as "the fight is over" (the Grove druids then ran to the
-- prison early).
-- A paused combat is resumed when a party member enters it or comes within nearMeters of it, and while
-- the game saves (so no save stores a paused combat). Combats already running in a loaded save are found
-- from the story database at the first check after load.
--
-- WCC_FROZEN (Stats/Generated/Data/Status.txt) is no longer applied. It stays defined only so a save
-- made with an older version can have the leftover status cleared on load.
--
-- Standalone module: needs only the WCC table from Journal.lua (Log, Label, combat tracking, heat).
-- WCC.IsFrozenCharacter(guid) is true for members of a paused combat, so other mods can skip their turn logic.

local Cfg = {
    freezeForeign = false,   -- always freeze combats the party isn't in (MCM / window toggle)
    autoOnDanger = false,    -- freeze foreign combats when a DANGER warning fires
    nearMeters = 25,         -- party this close to a member of a combat = it is not foreign
    checkMs = 2000,
    minNpcs = 2,             -- ignore "combats" with fewer characters than this (items, surfaces)
    spinTurns = 8,           -- more than this many turns in spinWindowMs inside a frozen combat
    spinWindowMs = 2000,     --   means the hold isn't working: release it and back off
    backoffMs = 60000,
    releaseHoldMs = 10000,   -- a fight just released is not paused again for this long
    refreezeMargin = 5,      -- ...and afterwards only once the party is this many meters beyond nearMeters
}
WCC.FreezeCfg = Cfg

local STATUS = "WCC_FROZEN"
local Log, Label = WCC.Log, WCC.Label
local now = Ext.Utils.MonotonicTime

local frozenCombat = {}   -- combatGuid -> list of member guids (snapshot taken when frozen)
local frozenChar = {}     -- guid -> true
local backoff = {}        -- combatGuid -> time until which we won't re-freeze
local turnStamps = {}     -- combatGuid -> list of recent TurnStarted times
local isChar = {}         -- guid -> bool (cache)
local releasedOnce = {}   -- combatGuid -> true: released before, so re-pausing needs the extra margin

local function ShortName(guid)
    return (Label(guid):gsub("|.*$", ""))
end

local function IsCharacter(guid)
    local c = isChar[guid]
    if c == nil then
        local ok, r = pcall(function() return Osi.IsCharacter(guid) == 1 end)
        c = ok and r or false
        isChar[guid] = c
    end
    return c
end

local function IsParty(guid)
    local ok, r = pcall(function() return Osi.IsPartyMember(guid, 1) == 1 end)
    return ok and r
end

local function NpcMembers(cid)
    local out = {}
    for guid in pairs(WCC.members[cid] or {}) do
        if IsCharacter(guid) and not IsParty(guid) then out[#out + 1] = guid end
    end
    return out
end

---------------------------------------------------------------------------
-- Party / combat relationships
---------------------------------------------------------------------------
local function PartyGuids()
    local out = {}
    local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "PartyMember")
    if ok and list then
        for _, m in ipairs(list) do
            local ok2, u = pcall(function() return m.Uuid.EntityUuid end)
            if ok2 and u then out[#out + 1] = u end
        end
    end
    return out
end

local function PartyCombats(party)
    local set = {}
    for _, p in ipairs(party) do
        local ok, cid = pcall(Osi.CombatGetGuidFor, p)
        if ok and type(cid) == "string" and cid ~= "" and cid ~= "00000000-0000-0000-0000-000000000000" then
            set[cid] = true
        end
    end
    return set
end

-- Straight-line meters from world positions. (Osi.GetDistanceTo returned ~850 for fights that
-- were about 30 m away in the first real test, so it is not trusted here.)
local function Position(guid)
    local ok, x, y, z = pcall(Osi.GetPosition, guid)
    if ok and type(x) == "number" then return x, y, z end
end

local function MinDistance(members, party)
    local pp = {}
    for _, p in ipairs(party) do
        local x, y, z = Position(p)
        if x then pp[#pp + 1] = { x, y, z } end
    end
    local best = math.huge
    -- every member (capped high): looking at only the first 12 made the release check and the pause check
    -- disagree in big fights, so such a fight was released and paused again in the same tick and stayed stuck
    for i = 1, math.min(#members, 200) do
        local x, y, z = Position(members[i])
        if x then
            for _, q in ipairs(pp) do
                local dx, dy, dz = x - q[1], y - q[2], z - q[3]
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d < best then best = d end
            end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Freeze / release a combat
---------------------------------------------------------------------------
local pausedCombat = {}   -- combatGuid -> true (held with PauseCombat, members not touched)

-- A foreign combat is held with the game's own PauseCombat (the call vanilla scripts use while a dialog
-- plays in a fight). Everyone stays in the combat, no turns run, nobody leaves combat. (The old method
-- took the NPCs out of combat; scripted events read that as "the fight is over" and sent the Grove
-- druids to the prison early. It was removed on purpose; do not bring it back.)
local function FreezeCombat(cid, why)
    if frozenCombat[cid] then return end
    local npcs = NpcMembers(cid)
    local ok = pcall(Osi.PauseCombat, cid)
    if not ok then
        Log("WARN", "PauseCombat failed for " .. cid:sub(1, 8) .. "; leaving that fight alone for a while")
        backoff[cid] = now() + Cfg.backoffMs
        return
    end
    frozenCombat[cid] = npcs
    turnStamps[cid] = {}
    pausedCombat[cid] = true
    for _, g in ipairs(npcs) do frozenChar[g] = true end
    Log("FREEZE", string.format("combat %s (%d NPCs) PAUSED, nobody leaves combat. %s", cid:sub(1, 8), #npcs, why or ""))
end

local function IsAlive(guid)
    local ok, dead = pcall(function() return Osi.IsDead(guid) end)
    return ok and dead ~= 1
end

--- Diagnostic: write the turn order(s) (name + initiative) to the journal. Component names are a best
--- guess ("TurnOrder" / TurnOrder.TurnOrder / Entity / Initiative), so every step is pcall-guarded.
local orderFailLogged = false
local function DumpTurnOrder(tag)
    local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "TurnOrder")
    if not ok or not list then
        if not orderFailLogged then orderFailLogged = true; Log("WARN", "turn order component not readable") end
        return
    end
    for idx, e in ipairs(list) do
        local parts = {}
        local okp = pcall(function()
            for _, entry in ipairs(e.TurnOrder.TurnOrder) do
                local name, init = "?", "?"
                pcall(function() name = ShortName(entry.Entity.Uuid.EntityUuid) end)
                pcall(function() init = tostring(entry.Initiative) end)
                parts[#parts + 1] = name .. "(" .. init .. ")"
            end
        end)
        if okp and #parts > 0 then
            Log("ORDER", string.format("%s #%d: %s", tag, idx, table.concat(parts, " > ")))
        end
    end
end
WCC.DumpTurnOrder = DumpTurnOrder

pcall(Ext.Osiris.RegisterListener, "CombatRoundStarted", 2, "after", function(cid, round)
    local party = PartyGuids()
    if not PartyCombats(party)[cid] then return end
    local r = tonumber(round) or 0
    if r <= 2 then DumpTurnOrder(string.format("round %s of %s", tostring(round), tostring(cid):sub(1, 8))) end
end)

local function ReleaseCombat(cid, why)
    local members = frozenCombat[cid]
    if not members then return end
    frozenCombat[cid], turnStamps[cid] = nil, nil
    pausedCombat[cid] = nil
    DumpTurnOrder("before resume " .. cid:sub(1, 8))
    pcall(Osi.ResumeCombat, cid)
    Ext.Timer.WaitFor(1000, function() DumpTurnOrder("after resume " .. cid:sub(1, 8)) end)
    for _, guid in ipairs(members) do frozenChar[guid] = nil end
    releasedOnce[cid] = true
    local hold = now() + Cfg.releaseHoldMs
    if (backoff[cid] or 0) < hold then backoff[cid] = hold end
    Log("RELEASE", string.format("combat %s (%s) - resumed", cid:sub(1, 8), why or ""))
end

local function ReleaseAll(why)
    local list = {}
    for cid in pairs(frozenCombat) do list[#list + 1] = cid end   -- copy: ReleaseCombat edits the table
    for _, cid in ipairs(list) do ReleaseCombat(cid, why) end
    return #list
end

local function FrozenCount()
    local n = 0
    for _ in pairs(frozenCombat) do n = n + 1 end
    return n
end

WCC.IsFrozenCharacter = function(guid)
    return frozenChar[guid] == true
end

--- Foreign combats right now: { cid, npcs, dist, heat }, busiest first.
local function ForeignCombats()
    local party = PartyGuids()
    if #party == 0 then return {} end
    local pc = PartyCombats(party)
    local heat = {}
    for _, row in ipairs(WCC.TopHeat(500)) do heat[row[1]] = row[2] end

    local rows = {}
    for cid in pairs(WCC.members) do
        if not pc[cid] then
            local npcs = NpcMembers(cid)
            if #npcs >= Cfg.minNpcs then
                local dist = MinDistance(npcs, party)
                if dist > Cfg.nearMeters + (releasedOnce[cid] and Cfg.refreezeMargin or 0) then
                    local h = 0
                    for _, g in ipairs(npcs) do h = h + (heat[g] or 0) end
                    rows[#rows + 1] = { cid = cid, npcs = npcs, dist = dist, heat = h }
                end
            end
        end
    end
    table.sort(rows, function(a, b) return a.heat > b.heat end)
    return rows
end

local function FreezeAllForeign(why)
    local n, t = 0, now()
    for _, row in ipairs(ForeignCombats()) do
        if not frozenCombat[row.cid] and (backoff[row.cid] or 0) <= t then
            FreezeCombat(row.cid, why)
            n = n + 1
        end
    end
    return n
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------
-- A character joining an already-frozen combat is frozen too.
WCC.OnEnteredCombat = function(guid, cid)
    if IsParty(guid) then
        if pausedCombat[cid] and frozenCombat[cid] then
            ReleaseCombat(cid, "party member entered")
        end
        return
    end
    if frozenCombat[cid] and IsCharacter(guid) and not IsParty(guid) then
        table.insert(frozenCombat[cid], guid)
        frozenChar[guid] = true
    end
end

WCC.OnCombatEnded = function(cid)
    backoff[cid], releasedOnce[cid] = nil, nil
    -- a held fight that ended is no longer held
    if frozenCombat[cid] then
        for _, g in ipairs(frozenCombat[cid]) do frozenChar[g] = nil end
        frozenCombat[cid], pausedCombat[cid], turnStamps[cid] = nil, nil, nil
    end
end

-- Spin guard: if turns in a frozen combat fly by, the hold isn't holding. Back off rather
-- than make things worse.
Ext.Osiris.RegisterListener("TurnStarted", 1, "after", function(guid)
    local cid = WCC.combatOf[guid]
    if not cid or not frozenCombat[cid] then return end
    local t = now()
    local stamps = turnStamps[cid]
    stamps[#stamps + 1] = t
    while stamps[1] and t - stamps[1] > Cfg.spinWindowMs do table.remove(stamps, 1) end
    if #stamps > Cfg.spinTurns then
        Log("WARN", string.format("turns in frozen combat %s are cycling (%d in %d ms); releasing it for %d s",
            cid:sub(1, 8), #stamps, Cfg.spinWindowMs, Cfg.backoffMs / 1000))
        ReleaseCombat(cid, "turns cycling")
        backoff[cid] = t + Cfg.backoffMs
    end
end)

-- Never let a save be written while a combat is paused: a paused combat stored in a save is the prime
-- suspect for the crash right after loading such a save. Resume before the game saves, pause again after.
local resumedForSave = {}
local saving = false
Ext.Events.GameStateChanged:Subscribe(function(e)
    local to, from = tostring(e.ToState), tostring(e.FromState)
    if to:find("Unload", 1, true) then
        -- the level is going away and its fights with it: forget what was held, so nothing stale is "held" next level
        frozenCombat, frozenChar, pausedCombat, turnStamps, backoff, releasedOnce = {}, {}, {}, {}, {}, {}
        resumedForSave, saving = {}, false
    elseif to:find("Save", 1, true) then
        saving = true
        resumedForSave = {}
        for cid in pairs(pausedCombat) do
            if pcall(Osi.ResumeCombat, cid) then resumedForSave[#resumedForSave + 1] = cid end
        end
        Log("INFO", string.format("SAVE starting: resumed %d paused combat(s), %d tracked", #resumedForSave, FrozenCount()))
        if WCC.FlushNow then pcall(WCC.FlushNow) end -- written now, so a crash during the save still leaves this line
    elseif from:find("Save", 1, true) then
        saving = false
        local list = resumedForSave
        resumedForSave = {}
        if #list == 0 then return end
        -- Pause again right now, before the first tick after the save: with a delay the druids got
        -- ~2.7 s of turns (Aelar, RitualDruid_005, DruidGuard_003 started turns) in the first test.
        for _, cid in ipairs(list) do
            if pausedCombat[cid] and frozenCombat[cid] then pcall(Osi.PauseCombat, cid) end
        end
        Log("INFO", "SAVE finished: re-paused " .. #list .. " combat(s) immediately")
        Ext.Timer.WaitFor(500, function()
            for _, cid in ipairs(list) do
                if pausedCombat[cid] and frozenCombat[cid] then pcall(Osi.PauseCombat, cid) end
            end
            Log("INFO", "re-paused " .. #list .. " combat(s) after the save")
        end)
    end
end)

-- Something resumed a combat we are holding (a dialog ending, a script): pause it again.
pcall(Ext.Osiris.RegisterListener, "CombatResumed", 1, "after", function(cid)
    if pausedCombat[cid] and frozenCombat[cid] and not saving then
        Ext.Timer.WaitFor(300, function()
            if pausedCombat[cid] and frozenCombat[cid] and not saving then pcall(Osi.PauseCombat, cid) end
        end)
    end
end)

-- WCC_FROZEN is permanent until removed, so a save made while frozen would keep NPCs frozen
-- forever. On the first Running tick of each session, clear any leftovers; the normal rules
-- below then re-freeze whatever should be frozen.
local cleaned = false
local function CleanupLeftovers()
    cleaned = true
    local n = 0
    local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
    if not ok or not list then return end
    for _, e in ipairs(list) do
        pcall(function()
            local guid = e.Uuid.EntityUuid
            if Osi.HasActiveStatus(guid, STATUS) == 1 then
                Osi.RemoveStatus(guid, STATUS)
                n = n + 1
            end
        end)
    end
    frozenChar = {}
    if n > 0 then Log("INFO", "cleared " .. n .. " leftover " .. STATUS .. " status(es) from the loaded save") end

    -- A save made while a combat was paused would keep it paused. Resume every combat found in the save;
    -- the normal rules below pause the foreign ones again.
    -- Combats that already exist in the loaded save fire no EnteredCombat events, so the tracker never knew
    -- about them and never paused them (a save made mid-fight then ran every Grove fight unpaused -> overload
    -- crash ~30 s after load). Read them from the story database instead.
    local found = 0
    local okdb, rows = pcall(function() return Osi.DB_Is_InCombat:Get(nil, nil) end)
    if okdb and rows then
        for _, row in pairs(rows) do
            local g, cid = row[1], row[2]
            if type(g) == "string" and type(cid) == "string" and cid ~= "" and IsCharacter(g) then
                WCC.combatants[g] = true
                WCC.combatOf[g] = cid
                WCC.members[cid] = WCC.members[cid] or {}
                if not WCC.members[cid][g] then found = found + 1 end
                WCC.members[cid][g] = true
            end
        end
    end
    if found > 0 then Log("INFO", "found " .. found .. " combatant(s) already in combat in the loaded save") end

    -- DISABLED: calling ResumeCombat on every combat at load crashed the game right after the save loaded
    -- (twice, on saves made while fights were paused). A paused combat found in a save is resumed instead
    -- by the game's own rules (a script or dialog ending) or, if it stays stuck, by loading a save made
    -- before the pause.
end

local lastCheck = 0
Ext.Events.Tick:Subscribe(function()
    local t = now()
    if not WCC.running or t - lastCheck < Cfg.checkMs then return end
    lastCheck = t
    if not cleaned then CleanupLeftovers() end
    if not WCC.mcmLoaded and WCC.mcmAttempts < 20 and WCC.LoadMcm then WCC.LoadMcm() end
    if not next(WCC.members) and not next(frozenCombat) then return end

    local party = PartyGuids()
    local pc = PartyCombats(party)

    -- Release frozen fights the party walked up to, or that have lost most of their NPCs.
    for cid, members in pairs(frozenCombat) do
        local living = {}
        for _, g in ipairs(members) do
            if IsAlive(g) then living[#living + 1] = g end
        end
        if pc[cid] then
            ReleaseCombat(cid, "party joined")
        elseif #living < Cfg.minNpcs then
            ReleaseCombat(cid, "too few NPCs left")
        elseif MinDistance(living, party) < Cfg.nearMeters then
            ReleaseCombat(cid, "party approached")
        end
    end

    if Cfg.freezeForeign then FreezeAllForeign("party not in this combat") end
end)

---------------------------------------------------------------------------
-- Danger hook + UI plumbing
---------------------------------------------------------------------------
local function BuildState(reason)
    local list = {}
    for i, row in ipairs(ForeignCombats()) do
        if i > 8 then break end
        local names = {}
        for j = 1, math.min(3, #row.npcs) do names[j] = ShortName(row.npcs[j]) end
        list[i] = {
            label = string.format("%s (%d NPCs: %s)", row.cid:sub(1, 8), #row.npcs, table.concat(names, ", ")),
            dist = math.floor(row.dist), heat = row.heat,
        }
    end
    return {
        reason = reason, candidates = list, frozen = FrozenCount(),
        auto = Cfg.autoOnDanger, always = Cfg.freezeForeign,
    }
end

local function Broadcast(reason, openWindow)
    local st = BuildState(reason)
    st.open = openWindow or false
    pcall(Ext.Net.BroadcastMessage, "WCC_State", Ext.Json.Stringify(st))
end

WCC.OnDanger = function(reason)
    local rows = ForeignCombats()
    local parts = {}
    for i = 1, math.min(5, #rows) do
        parts[i] = string.format("%s %d NPCs %dm heat=%d", rows[i].cid:sub(1, 8), #rows[i].npcs,
            math.floor(rows[i].dist), rows[i].heat)
    end
    Log("FOREIGN", #rows == 0 and "no combats without the party" or table.concat(parts, "; "))
    if Cfg.autoOnDanger then
        Log("INFO", "auto-freeze on danger: froze " .. FreezeAllForeign("danger") .. " combat(s)")
    end
    Broadcast(reason, true)
end

local function ApplySetting(id, value)
    if id == "FreezeForeignCombats" then
        local was = Cfg.freezeForeign
        Cfg.freezeForeign = value and true or false
        -- unticking releases what is held; before, held fights stayed paused until the party walked up to them
        if was and not Cfg.freezeForeign then
            Log("INFO", "freeze option turned off: released " .. ReleaseAll("option turned off") .. " held fight(s)")
        end
    elseif id == "AutoFreezeOnDanger" then Cfg.autoOnDanger = value and true or false
    elseif id == "ReleaseDistance" and type(value) == "number" then Cfg.nearMeters = value
    end
end

-- MCM (optional). This mod now loads FIRST (so the profiler can see every other mod's handlers),
-- which is before BG3MCM exists, so the saved values can't be read at load time. Read them once the
-- session has loaded, and keep retrying from the tick until it works. The outcome is logged.
WCC.mcmLoaded, WCC.mcmAttempts = false, 0
local mcmSubscribed = false

local function LoadMcm()
    WCC.mcmAttempts = WCC.mcmAttempts + 1
    if not WCC.mcmLoaded then
        local ok, err = pcall(function()
            local api = Mods.BG3MCM.MCMAPI
            local got = 0
            for _, id in ipairs({ "FreezeForeignCombats", "AutoFreezeOnDanger", "ReleaseDistance" }) do
                local v = api:GetSettingValue(id, ModuleUUID)
                if v ~= nil then
                    ApplySetting(id, v)
                    got = got + 1
                end
            end
            if got == 0 then error("MCM returned no values") end
        end)
        if ok then
            WCC.mcmLoaded = true
            Log("INFO", string.format("MCM settings loaded (attempt %d): freezeForeign=%s autoOnDanger=%s releaseDistance=%s",
                WCC.mcmAttempts, tostring(Cfg.freezeForeign), tostring(Cfg.autoOnDanger), tostring(Cfg.nearMeters)))
        elseif WCC.mcmAttempts == 1 or WCC.mcmAttempts == 10 then
            Log("WARN", "MCM settings not readable yet (attempt " .. WCC.mcmAttempts .. "): " .. tostring(err))
        end
    end
    if not mcmSubscribed then
        mcmSubscribed = pcall(function()
            Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
                if payload and payload.modUUID == ModuleUUID then
                    ApplySetting(payload.settingId, payload.value)
                    Log("INFO", "MCM setting " .. tostring(payload.settingId) .. " = " .. tostring(payload.value))
                end
            end)
        end)
    end
end
WCC.LoadMcm = LoadMcm
Ext.Events.SessionLoaded:Subscribe(LoadMcm)

-- Messages between the game's client and server: Ext.RegisterNetListener is the Script Extender's function for
-- receiving them (an earlier version called Ext.Net.RegisterListener, which does not exist, so nothing arrived).
local function listenNet(channel, fn)
    local reg = (type(Ext.RegisterNetListener) == "function" and Ext.RegisterNetListener)
        or (Ext.Net and type(Ext.Net.RegisterListener) == "function" and Ext.Net.RegisterListener) or nil
    if not reg then
        pcall(Ext.Utils.PrintWarning or Ext.Utils.Print, "[WhatCausedTheCrash] cannot listen for '" .. channel .. "' messages in this Script Extender version")
        return false
    end
    local ok, err = pcall(reg, channel, fn)
    if not ok then pcall(Ext.Utils.Print, "[WhatCausedTheCrash] listening for '" .. channel .. "' failed: " .. tostring(err)) end
    return ok
end

listenNet("WCC_Cmd", function(_, payload)
    local ok, msg = pcall(Ext.Json.Parse, payload)
    if not ok or type(msg) ~= "table" then return end
    if msg.cmd == "freeze_far" then
        Log("INFO", "manual freeze: " .. FreezeAllForeign("manual") .. " combat(s)")
    elseif msg.cmd == "release_all" then
        Cfg.freezeForeign = false
        ReleaseAll("manual")
    elseif msg.cmd == "set_auto" then
        Cfg.autoOnDanger = msg.value and true or false
    elseif msg.cmd == "set_always" then
        ApplySetting("FreezeForeignCombats", msg.value)
    end
    Broadcast("updated", false)
end)

Ext.RegisterConsoleCommand("wcc_freeze", function() Ext.Utils.Print("frozen combats: " .. FreezeAllForeign("console")) end)
Ext.RegisterConsoleCommand("wcc_unfreeze", function() Cfg.freezeForeign = false; ReleaseAll("console") end)
Ext.RegisterConsoleCommand("wcc_combats", function()
    local pc = PartyCombats(PartyGuids())
    for cid, members in pairs(WCC.members) do
        local n = 0
        for _ in pairs(members) do n = n + 1 end
        Ext.Utils.Print(string.format("%s members=%d npcs=%d party=%s frozen=%s", cid:sub(1, 8), n,
            #NpcMembers(cid), tostring(pc[cid] == true), tostring(frozenCombat[cid] ~= nil)))
    end
end)
