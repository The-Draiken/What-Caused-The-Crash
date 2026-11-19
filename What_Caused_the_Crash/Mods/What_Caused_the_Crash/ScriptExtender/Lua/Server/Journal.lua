-- What Caused the Crash: rolling "black box" journal.
-- A hard crash kills the game before Lua can react, so we keep a ring buffer of recent
-- events and flush it to disk many times a second. After a crash, the file on disk holds
-- the last things the game was doing. On the next session load it is archived and a
-- crash report is produced.

local Cfg = {
    dir = "WhatCausedTheCrash/",
    maxEntries = 800,          -- ring buffer size
    flushMs = 400,             -- max time between journal writes while dirty
    stallMs = 1500,            -- a tick gap longer than this is logged as a STALL
    hardStallMs = 5000,        -- a single gap this long triggers DANGER
    stallsForDanger = 3,       -- this many stalls inside stallWindowMs triggers DANGER
    stallWindowMs = 20000,
    graceMs = 10000,           -- ignore stalls this long after the game reaches Running
    snapshotCombatMs = 5000,
    snapshotIdleMs = 30000,
    dangerCooldownMs = 60000,
    autoPauseOnDanger = false, -- freeze menu replaces this; set true to also pause the party
    maxDangerReports = 5,
    heatWindowMs = 10000,      -- window for the 'hot actors' ranking
}

-- Shared with Freeze.lua
WCC = { Cfg = Cfg, combatants = {}, combatOf = {}, members = {}, running = false }

-- Statuses that fire constantly and tell us nothing. Counted for heat, not written to the journal.
local NOISY = {
    IDLE_EXPRESSION = true, DEAD_COMBAT_BLOCK = true, RAW_LONG_JUMP_READY = true,
    RAW_LONG_JUMP_CHECK = true, FLANKED = true, REACTION = true,
}

local JOURNAL = Cfg.dir .. "live_journal.txt"
local PREVIOUS = Cfg.dir .. "previous_session_journal.txt"
local CRASH_REPORT = Cfg.dir .. "LAST_CRASH_REPORT.txt"
local CLEAN_MARK = "CLEAN_EXIT"
local MSGBOX_TEXT = "WHAT CAUSED THE CRASH: the game is struggling (see the DANGER report in Script Extender/WhatCausedTheCrash). Press OK to resume."

local now = Ext.Utils.MonotonicTime
local t0 = now()

---------------------------------------------------------------------------
-- Ring buffer
---------------------------------------------------------------------------
local ring, total = {}, 0
local dirty, lastFlush = false, 0
local lastSnapshot = ""

local function Log(kind, msg)
    total = total + 1
    ring[(total - 1) % Cfg.maxEntries + 1] = string.format("[%8.2f] %-8s %s", (now() - t0) / 1000, kind, msg)
    dirty = true
end

local function Dump(extraHeader)
    local out = {
        "WHAT CAUSED THE CRASH - journal (oldest first, newest last)",
        string.format("entries logged: %d (showing last %d) | session seconds: %.1f", total,
            math.min(total, Cfg.maxEntries), (now() - t0) / 1000),
    }
    if extraHeader then out[#out + 1] = extraHeader end
    if lastSnapshot ~= "" then out[#out + 1] = "last snapshot: " .. lastSnapshot end
    out[#out + 1] = string.rep("-", 70)
    for i = math.max(1, total - Cfg.maxEntries + 1), total do
        out[#out + 1] = ring[(i - 1) % Cfg.maxEntries + 1]
    end
    return table.concat(out, "\n") .. "\n"
end

local function FlushNow()
    pcall(Ext.IO.SaveFile, JOURNAL, Dump())
    dirty, lastFlush = false, now()
end

---------------------------------------------------------------------------
-- Labels (template name + short guid) for Osiris arguments
---------------------------------------------------------------------------
local labels, labelCount = {}, 0
local GUID_PAT = "(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$"

local function Label(v)
    if type(v) ~= "string" then return tostring(v) end
    local cached = labels[v]
    if cached then return cached end
    local guid = v:match(GUID_PAT)
    if not guid then return v end
    local name = v:sub(1, #v - #guid - 1)
    if name == "" then
        local ok, tpl = pcall(function() return Osi.GetTemplate(guid) end)
        name = (ok and type(tpl) == "string") and tpl or ""
    end
    name = (name:gsub("_%x%x%x%x%x%x%x%x%-.*$", ""))
    local out = (name ~= "") and (name .. "|" .. guid:sub(1, 8)) or guid:sub(1, 8)
    if labelCount > 5000 then labels, labelCount = {}, 0 end
    labels[v], labelCount = out, labelCount + 1
    return out
end

local function FmtArgs(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = Label((select(i, ...))) end
    return table.concat(t, ", ")
end

---------------------------------------------------------------------------
-- Snapshot: what is alive right now
---------------------------------------------------------------------------
-- Heat: how many events each actor produced recently (a proxy for "who is busy").
local heat, heatPrev, heatSwap = {}, {}, now()
local function Heat(guid)
    if type(guid) ~= "string" then return end
    local t = now()
    if t - heatSwap >= Cfg.heatWindowMs then heatPrev, heat, heatSwap = heat, {}, t end
    heat[guid] = (heat[guid] or 0) + 1
end

local function TopHeat(n)
    local merged = {}
    for g, c in pairs(heatPrev) do merged[g] = c end
    for g, c in pairs(heat) do merged[g] = (merged[g] or 0) + c end
    local rows = {}
    for g, c in pairs(merged) do rows[#rows + 1] = { g, c } end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    local out = {}
    for i = 1, math.min(n, #rows) do out[i] = rows[i] end
    return out
end
WCC.TopHeat = TopHeat

local function Snapshot(reason)
    local nChars = 0
    for guid in pairs(WCC.combatants) do
        local ok, isChar = pcall(function() return Osi.IsCharacter(guid) == 1 end)
        if ok and isChar then nChars = nChars + 1 end
    end
    local top = {}
    for i, row in ipairs(TopHeat(6)) do top[i] = Label(row[1]):gsub("|.*$", "") .. "x" .. row[2] end
    lastSnapshot = string.format("combatCharacters=%d luaMemKB=%d hot=[%s]",
        nChars, math.floor(collectgarbage("count")), table.concat(top, ", "))
    Log("SNAPSHOT", (reason or "periodic") .. " | " .. lastSnapshot)
end

---------------------------------------------------------------------------
-- Pause (same Pause component Pause The Game uses)
---------------------------------------------------------------------------
local paused = false

local function SetPause(on)
    local ok, members = pcall(Ext.Entity.GetAllEntitiesWithComponent, "PartyMember")
    if not ok or not members then return end
    for _, m in ipairs(members) do
        pcall(function()
            local e = Ext.Entity.Get(m.Uuid.EntityUuid)
            if on then
                if not e:GetComponent("Pause") then e:CreateComponent("Pause") end
            elseif e:GetComponent("Pause") then
                e:RemoveComponent("Pause")
            end
        end)
    end
    paused = on
end

---------------------------------------------------------------------------
-- Danger handling
---------------------------------------------------------------------------
local dangerAt, dangerCount = nil, 0

local function Danger(reason)
    local t = now()
    if dangerAt and t - dangerAt < Cfg.dangerCooldownMs then return end
    dangerAt = t
    Log("DANGER", reason)
    Snapshot("danger")
    FlushNow()
    if dangerCount < Cfg.maxDangerReports then
        dangerCount = dangerCount + 1
        pcall(Ext.IO.SaveFile, string.format("%sDANGER_report_%d.txt", Cfg.dir, dangerCount),
            Dump("DANGER: " .. reason))
    end
    if WCC.OnDanger then pcall(WCC.OnDanger, reason) end
    if Cfg.autoPauseOnDanger then
        SetPause(true)
        pcall(function() Osi.OpenMessageBox(Osi.GetHostCharacter(), MSGBOX_TEXT) end)
    end
end

---------------------------------------------------------------------------
-- Archive the previous session and build a crash report if it ended badly
---------------------------------------------------------------------------
local function ArchivePrevious()
    local ok, prev = pcall(Ext.IO.LoadFile, JOURNAL)
    if not ok or not prev or prev == "" then return end
    pcall(Ext.IO.SaveFile, PREVIOUS, prev)
    if prev:find(CLEAN_MARK, 1, true) then return end

    local lines = {}
    for line in prev:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local tail = {}
    for i = math.max(1, #lines - 80), #lines do tail[#tail + 1] = lines[i] end
    pcall(Ext.IO.SaveFile, CRASH_REPORT, table.concat({
        "WHAT CAUSED THE CRASH - PROBABLE CRASH REPORT",
        "The previous session's journal has no clean-exit marker, so the game most likely crashed",
        "(or was force-closed). The LAST lines below are the last things the game logged.",
        "Also check: %LOCALAPPDATA%\\Larian Studios\\Baldur's Gate 3\\Crashdumps and the Script Extender log.",
        "Full journal: previous_session_journal.txt",
        string.rep("=", 70),
        table.concat(tail, "\n"),
        "",
    }, "\n"))
    Ext.Utils.Print("[WhatCausedTheCrash] Previous session looks like a crash. See " .. CRASH_REPORT)
end

---------------------------------------------------------------------------
-- Event hooks
---------------------------------------------------------------------------
local graceUntil = now() + Cfg.graceMs
local combatCount = 0

-- name, arity
local osirisEvents = {
    { "CombatStarted", 1 }, { "CombatEnded", 1 },
    { "EnteredCombat", 2 }, { "LeftCombat", 2 },
    { "TurnStarted", 1 }, { "TurnEnded", 1 },
    { "StatusApplied", 4 }, { "StatusRemoved", 4 },
    { "UsingSpell", 5 }, { "UsingSpellOnTarget", 6 },
    { "AttackedBy", 7 }, { "Died", 1 }, { "Resurrected", 1 },
    { "TeleportedFromTo", 6 }, { "LevelGameplayStarted", 2 },
    { "DialogStarted", 2 }, { "DialogEnded", 2 },
    { "AutomatedDialogStarted", 2 }, { "AutomatedDialogEnded", 2 },
    { "AutomatedDialogRequestFailed", 2 }, { "DialogRequestFailed", 1 },
    { "DialogActorJoined", 4 }, { "DialogActorLeft", 4 },
    { "TemplateAddedTo", 4 }, { "EnteredForceTurnBased", 1 }, { "LeftForceTurnBased", 1 },
}

for _, ev in ipairs(osirisEvents) do
    local name = ev[1]
    local ok, err = pcall(Ext.Osiris.RegisterListener, name, ev[2], "after", function(...)
        local a1, a2 = ...
        if name == "CombatStarted" then combatCount = combatCount + 1
        elseif name == "EnteredCombat" then
            WCC.combatants[a1] = true
            WCC.combatOf[a1] = a2
            WCC.members[a2] = WCC.members[a2] or {}
            WCC.members[a2][a1] = true
            if WCC.OnEnteredCombat then pcall(WCC.OnEnteredCombat, a1, a2) end
        elseif name == "LeftCombat" or name == "Died" then
            WCC.combatants[a1] = nil
            local cid = WCC.combatOf[a1]
            if cid and WCC.members[cid] then WCC.members[cid][a1] = nil end
            WCC.combatOf[a1] = nil
        elseif name == "CombatEnded" then
            combatCount = math.max(0, combatCount - 1)
            if WCC.OnCombatEnded then pcall(WCC.OnCombatEnded, a1) end
            for g in pairs(WCC.members[a1] or {}) do WCC.combatOf[g], WCC.combatants[g] = nil, nil end
            WCC.members[a1] = nil
        elseif name == "LevelGameplayStarted" then graceUntil = now() + Cfg.graceMs end

        if name == "StatusApplied" or name == "StatusRemoved" or name == "AttackedBy"
            or name == "UsingSpell" or name == "UsingSpellOnTarget" then
            Heat(a1)
        end
        if (name == "StatusApplied" or name == "StatusRemoved") and NOISY[a2] then return end
        Log(name, FmtArgs(...))
        -- Scripted dialogs are a prime crash suspect: write at once so the last one survives a hang.
        if name:find("Dialog", 1, true) then FlushNow() end
    end)
    if not ok then Log("WARN", "could not hook " .. name .. ": " .. tostring(err)) end
end

pcall(Ext.Osiris.RegisterListener, "MessageBoxClosed", 2, "after", function(_, message)
    if paused and message == MSGBOX_TEXT then
        SetPause(false)
        Log("INFO", "resumed after danger pause")
    end
end)

-- Every character entity that gets created: this is what shows "what was being loaded".
local okSub, errSub = pcall(function()
    Ext.Entity.Subscribe("ServerCharacter", function(entity, _, flags)
        local isCreate = true
        pcall(function() isCreate = flags.Create end)
        if not isCreate then return end
        local ok, uuid = pcall(function() return entity.Uuid.EntityUuid end)
        Log("SPAWN", ok and uuid and Label(uuid) or tostring(entity))
    end)
end)
if not okSub then Log("WARN", "entity spawn tracking unavailable: " .. tostring(errSub)) end

Ext.Events.GameStateChanged:Subscribe(function(e)
    local to = tostring(e.ToState)
    Log("STATE", tostring(e.FromState) .. " -> " .. to)
    WCC.running = (to == "Running")
    if WCC.running then graceUntil = now() + Cfg.graceMs end
    -- Leaving the level: trace every mod handler from here on (Profiler.lua), so a crash on the way back to
    -- the main menu names what was running. The client side (Client/MenuReturn.lua) checks the menu was reached.
    if WCC_PROF and WCC_PROF.StartTrace then
        if WCC_PROF.tracing and to == "Running" then
            pcall(WCC_PROF.StopTrace, "game state " .. tostring(e.FromState) .. " -> " .. to)
        elseif WCC_PROF.tracing then
            pcall(WCC_PROF.TraceNote, "game state " .. tostring(e.FromState) .. " -> " .. to)
        elseif to:find("Unload") or to:find("Disconnect") then
            pcall(WCC_PROF.StartTrace, "game state " .. tostring(e.FromState) .. " -> " .. to)
        end
    end
    if to:find("Unload") or to:find("Exit") or to:find("Disconnect") or to:find("Menu") then
        WCC.combatants, WCC.combatOf, WCC.members = {}, {}, {}
        Log(CLEAN_MARK, "game state " .. to)
        FlushNow()
    end
end)

local lastTick, lastSnap, stalls = now(), 0, {}
Ext.Events.Tick:Subscribe(function()
    local t = now()
    local gap = t - lastTick
    lastTick = t

    -- Handler profiler (Profiler.lua): single slow calls, and what was busiest around a stall.
    if WCC_PROF then
        local q = WCC_PROF.slow
        if #q > 0 then
            for i = 1, math.min(#q, 20) do
                Log("SLOW", string.format("%s took %.0f ms", q[i].key, q[i].ms))
            end
            WCC_PROF.slow = {}
        end
        local sp = WCC_PROF.spikes
        if sp and #sp > 0 then
            for i = 1, math.min(#sp, 10) do
                Log("MEMSPIKE", string.format("%s grew Lua memory by %.1f MB in one call", sp[i].key, sp[i].kb / 1024))
            end
            WCC_PROF.spikes = {}
        end
        if t - (WCC.lastProfReport or 0) >= 20000 then
            WCC.lastProfReport = t
            pcall(WCC_PROF.Report)
        end
    end

    if WCC.running and t >= graceUntil and gap > Cfg.stallMs then
        Log("STALL", string.format("tick gap %d ms", gap))
        if WCC_PROF then
            local ok, top = pcall(WCC_PROF.TopRecent, 4)
            if ok then Log("PROFILE", "busiest handlers just before: " .. top) end
            local okM, mem = pcall(WCC_PROF.TopMemRecent, 3)
            if okM and mem ~= "" then Log("PROFILE", "heaviest Lua allocators just before: " .. mem) end
        end
        stalls[#stalls + 1] = t
        local kept = {}
        for _, s in ipairs(stalls) do if t - s <= Cfg.stallWindowMs then kept[#kept + 1] = s end end
        stalls = kept
        if gap >= Cfg.hardStallMs then
            Danger(string.format("single freeze of %d ms", gap))
        elseif #stalls >= Cfg.stallsForDanger then
            Danger(string.format("%d stalls in %d s", #stalls, Cfg.stallWindowMs / 1000))
        end
    end

    local every = combatCount > 0 and Cfg.snapshotCombatMs or Cfg.snapshotIdleMs
    if WCC.running and t - lastSnap >= every and t >= graceUntil then
        lastSnap = t
        Snapshot()
    end

    if dirty and t - lastFlush >= Cfg.flushMs then FlushNow() end
end)

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
ArchivePrevious()
Log("START", "What Caused the Crash active. Journal: Script Extender/" .. JOURNAL)
pcall(function() Log("REGION", tostring(Osi.GetRegion(Osi.GetHostCharacter()))) end)
pcall(function()
    Log("START", "characters loaded: " .. #Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter"))
end)
Snapshot("start")
FlushNow()

Ext.RegisterConsoleCommand("wcc", function()
    Snapshot("manual")
    FlushNow()
    Ext.Utils.Print(Dump())
end)
Ext.RegisterConsoleCommand("wcc_resume", function() SetPause(false) end)

WCC.Log, WCC.Label, WCC.Snapshot, WCC.FlushNow = Log, Label, Snapshot, FlushNow
Ext.Require("Server/Freeze.lua")
Ext.Require("Server/SceneSnapshot.lua")
Ext.Require("Server/LoadPause.lua")
Ext.Require("Server/PartyStatScan.lua")
Ext.Require("Server/MissingScan.lua")
Ext.Require("Server/InventoryList.lua")

Ext.Utils.Print("[WhatCausedTheCrash] Recording to Script Extender/" .. JOURNAL)
