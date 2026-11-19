-- Handler profiler: times every Osiris listener and Ext.Timer callback registered AFTER this file
-- runs, and attributes the time to the mod/file/line that registered it.
--
-- IMPORTANT: this only sees handlers registered after it loads, so "What Caused the Crash" must be
-- at the TOP of the load order (Script Extender loads mods' Lua in load order). The report lists
-- how many handlers were wrapped per mod, so you can see whether that worked.
--
-- Output:
--   * WhatCausedTheCrash/profile.txt   (rewritten every ~20 s while something changed)
--   * journal lines:  SLOW  <handler> took N ms      (any single call >= slowMs)
--                     PROFILE recent: ...            (right after every STALL)
-- Overhead is a closure call and two clock reads per handler call. Console: wcc_prof, wcc_prof_off, wcc_prof_on.

WCC_PROF = WCC_PROF or {}
local P = WCC_PROF

P.enabled = true
P.recs = {}
P.slow = {}          -- queue drained into the journal by Journal.lua
P.slowMs = 50
P.byMod = {}         -- mod folder -> number of handlers wrapped
P.unknown = 0

-- Lua memory per handler: the growth of the Lua heap across each call (collectgarbage("count"), KB).
-- Only growth is counted (a garbage-collection step inside a call can make the raw difference negative),
-- so it is a lower bound on what the call allocated, and a call that triggers nested handlers includes theirs.
local gc = collectgarbage
P.memOk = type(gc) == "function" and pcall(gc, "count")
P.trackMem = false  -- per-handler Lua memory tracking is off by default; "wcc_prof_mem on" enables it
P.spikes = {}        -- single calls that grew the heap by >= spikeKB, drained into the journal by Journal.lua
P.spikeKB = 20480    -- 20 MB

local floor = math.floor

local hasDebug = type(debug) == "table" and type(debug.getinfo) == "function"

local clockOk, clockVal = pcall(function() return os.clock() end)
P.preciseClock = clockOk and type(clockVal) == "number"
if P.preciseClock then
    P.clock = function() return os.clock() * 1000 end
else
    P.clock = Ext.Utils.MonotonicTime -- whole milliseconds: short handlers will read as 0
end

local OUR_UUID = ModuleUUID
local modNameCache = {}

local function ModName(uuid)
    if type(uuid) ~= "string" or uuid == "" then return nil end
    local cached = modNameCache[uuid]
    if cached ~= nil then return cached or nil end
    local ok, mod = pcall(Ext.Mod.GetMod, uuid)
    local name = ok and mod and mod.Info and (mod.Info.Name or mod.Info.Directory) or false
    modNameCache[uuid] = name
    return name or nil
end

-- A callback that uses globals has an _ENV upvalue: the environment of the mod that defined it,
-- which holds that mod's ModuleUUID.
local function ModFromFunction(cb)
    if not hasDebug or type(debug.getupvalue) ~= "function" then return nil end
    for i = 1, 80 do
        local ok, name, val = pcall(debug.getupvalue, cb, i)
        if not ok or name == nil then break end
        if name == "_ENV" and type(val) == "table" then
            local uuid = rawget(val, "ModuleUUID")
            if type(uuid) ~= "string" then
                local ok2, v = pcall(function() return val.ModuleUUID end)
                uuid = ok2 and v or nil
            end
            return ModName(uuid)
        end
    end
    return nil
end

local function Describe(cb)
    local mod = ModFromFunction(cb)
    -- Registration happens while the owning mod's script loads; if the global ModuleUUID seen from
    -- here is not ours, it is probably theirs.
    if not mod and ModuleUUID ~= nil and ModuleUUID ~= OUR_UUID then mod = ModName(ModuleUUID) end

    local where = "?"
    if hasDebug then
        local ok, info = pcall(debug.getinfo, cb, "S")
        if ok and info and info.source then
            local src = (tostring(info.source):gsub("^[@=]", ""))
            mod = mod or src:match("Mods/([^/\\]+)") or src:match("([^/\\]+)[/\\]ScriptExtender")
            local file = src:match("([^/\\]+)$") or src
            where = file .. ":" .. tostring(info.linedefined or 0)
        end
    end
    return (mod or "?"), where
end

---------------------------------------------------------------------------
-- Unload trace: while the game is leaving a level (going back to the main menu), every wrapped
-- handler call is written to unload_trace.txt BEFORE it runs and marked done after. If the game dies
-- inside a mod's handler, that handler is the last line, still marked RUNNING.
---------------------------------------------------------------------------
local TRACE_FILE = "WhatCausedTheCrash/unload_trace.txt"
local TRACE_KEEP = 300           -- lines kept (oldest dropped)
local TRACE_FLUSH_ALL = 3000     -- after this many calls, write every 50th call only
P.tracing = false
local trace = { lines = {}, calls = 0, t0 = 0, header = "" }

local function TraceFlush()
    local out = { trace.header, string.rep("-", 70) }
    for i = 1, #trace.lines do
        local l = trace.lines[i]
        if l.kind == "note" then
            out[#out + 1] = l.text
        else
            out[#out + 1] = string.format("[+%7.2fs] %s%s  %s", l.t / 1000,
                l.done and "done     " or "RUNNING  ", l.count > 1 and (" x" .. l.count) or "", l.key)
        end
    end
    pcall(Ext.IO.SaveFile, TRACE_FILE, table.concat(out, "\n") .. "\n")
end

local function TracePush(line)
    trace.lines[#trace.lines + 1] = line
    if #trace.lines > TRACE_KEEP then table.remove(trace.lines, 1) end
end

function P.TraceNote(text)
    if not P.tracing then return end
    TracePush({ kind = "note", text = string.format("[+%7.2fs] ----- %s", (Ext.Utils.MonotonicTime() - trace.t0) / 1000, text) })
    TraceFlush()
end

function P.StartTrace(reason)
    if P.tracing then return P.TraceNote(reason) end
    P.tracing = true
    trace.lines, trace.calls, trace.t0 = {}, 0, Ext.Utils.MonotonicTime()
    local when, ep = "?", "?"
    pcall(function() when = tostring(Ext.Timer.ClockTime()) end)
    pcall(function() ep = tostring(Ext.Timer.ClockEpoch()) end)
    trace.header = "WHAT CAUSED THE CRASH - UNLOAD TRACE (game leaving the level, " .. when .. ") epoch=" .. ep .. "\n" ..
        "Every mod script handler that ran while the game was unloading, oldest first.\n" ..
        "RUNNING on the LAST line = the game died inside that handler: that mod is the prime suspect.\n" ..
        "All lines done = no mod script was running at the moment of the crash (the game's own unloading crashed)."
    TracePush({ kind = "note", text = "[+   0.00s] ----- " .. tostring(reason) })
    TraceFlush()
end

-- back in a level (loading a save from inside the game also unloads first): stop, so play is not slowed
function P.StopTrace(reason)
    if not P.tracing then return end
    P.TraceNote(tostring(reason) .. " - trace stopped, the game is running again")
    P.tracing = false
end

local function TraceEnter(key)
    trace.calls = trace.calls + 1
    local last = trace.lines[#trace.lines]
    local line
    if last and last.kind ~= "note" and last.key == key and last.done then
        line = last
        line.count, line.done = line.count + 1, false
    else
        line = { key = key, count = 1, done = false, t = Ext.Utils.MonotonicTime() - trace.t0 }
        TracePush(line)
    end
    if trace.calls <= TRACE_FLUSH_ALL or trace.calls % 50 == 0 then TraceFlush() end
    return line
end

local function Wrap(key, mod, cb)
    local rec = P.recs[key]
    if not rec then
        rec = { key = key, calls = 0, total = 0, max = 0, wtotal = 0, bucket = 0, rcur = 0, rprev = 0,
                mem = 0, memW = 0, memMax = 0, mcur = 0, mprev = 0 }
        P.recs[key] = rec
        if mod == "?" then P.unknown = P.unknown + 1 else P.byMod[mod] = (P.byMod[mod] or 0) + 1 end
    end
    local clock = P.clock
    return function(...)
        if P.tracing then
            local line = TraceEnter(key)
            local r1, r2 = cb(...)
            line.done = true
            -- written too: before, the last handler always showed RUNNING, whether it had finished or not
            if trace.calls <= TRACE_FLUSH_ALL then TraceFlush() end
            return r1, r2
        end
        if not P.enabled then return cb(...) end
        local track = P.trackMem
        local m0 = track and gc("count") or 0
        local t0 = clock()
        local r1, r2 = cb(...)
        local dt = clock() - t0
        rec.calls = rec.calls + 1
        rec.total = rec.total + dt
        rec.wtotal = rec.wtotal + dt
        if dt > rec.max then rec.max = dt end
        local b = floor(t0 / 5000)
        if rec.bucket ~= b then
            rec.rprev = (rec.bucket == b - 1) and rec.rcur or 0
            rec.mprev = (rec.bucket == b - 1) and rec.mcur or 0
            rec.rcur, rec.mcur, rec.bucket = 0, 0, b
        end
        rec.rcur = rec.rcur + dt
        if track then
            local dm = gc("count") - m0
            if dm > 0 then
                rec.mem = rec.mem + dm
                rec.memW = rec.memW + dm
                rec.mcur = rec.mcur + dm
                if dm > rec.memMax then rec.memMax = dm end
                if dm >= P.spikeKB and #P.spikes < 50 then P.spikes[#P.spikes + 1] = { key = key, kb = dm } end
            end
        end
        if dt >= P.slowMs and #P.slow < 200 then P.slow[#P.slow + 1] = { key = key, ms = dt } end
        return r1, r2
    end
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------
local origReg = Ext.Osiris.RegisterListener
local okReg, errReg = pcall(function()
    Ext.Osiris.RegisterListener = function(name, arity, timing, cb, ...)
        if type(cb) == "function" then
            local mod, where = Describe(cb)
            cb = Wrap(string.format("%s/%s  %s  %s", tostring(name), tostring(timing), mod, where), mod, cb)
        end
        return origReg(name, arity, timing, cb, ...)
    end
end)
P.hookedOsiris = okReg
if not okReg then P.hookError = tostring(errReg) end

for _, fname in ipairs({ "WaitFor", "WaitForRealtime" }) do
    local orig = Ext.Timer and Ext.Timer[fname]
    if orig then
        pcall(function()
            Ext.Timer[fname] = function(delay, cb, ...)
                if type(cb) == "function" then
                    local mod, where = Describe(cb)
                    cb = Wrap(string.format("Timer.%s  %s  %s", fname, mod, where), mod, cb)
                end
                return orig(delay, cb, ...)
            end
        end)
    end
end

---------------------------------------------------------------------------
-- Reporting
---------------------------------------------------------------------------
--- "key 123ms, key 98ms" for the handlers busiest in the last ~5-10 seconds.
function P.TopRecent(n)
    local b = floor(P.clock() / 5000)
    local rows = {}
    for _, r in pairs(P.recs) do
        local v = 0
        if r.bucket == b then v = r.rcur + r.rprev elseif r.bucket == b - 1 then v = r.rcur end
        if v > 0 then rows[#rows + 1] = { r.key, v } end
    end
    table.sort(rows, function(a, c) return a[2] > c[2] end)
    local out = {}
    for i = 1, math.min(n or 3, #rows) do
        out[i] = string.format("[%s] %.0f ms", rows[i][1], rows[i][2])
    end
    return #out > 0 and table.concat(out, " | ") or "no wrapped handler was busy"
end

--- "key 12.3 MB, key 4.0 MB" for the handlers whose calls grew the Lua heap most in the last ~5-10 seconds
--- (only entries of at least minKB; "" when nothing qualified or memory tracking is off).
function P.TopMemRecent(n, minKB)
    if not P.trackMem then return "" end
    minKB = minKB or 1024
    local b = floor(P.clock() / 5000)
    local rows = {}
    for _, r in pairs(P.recs) do
        local v = 0
        if r.bucket == b then v = r.mcur + r.mprev elseif r.bucket == b - 1 then v = r.mcur end
        if v >= minKB then rows[#rows + 1] = { r.key, v } end
    end
    table.sort(rows, function(a, c) return a[2] > c[2] end)
    local out = {}
    for i = 1, math.min(n or 3, #rows) do
        out[i] = string.format("[%s] %.1f MB", rows[i][1], rows[i][2] / 1024)
    end
    return table.concat(out, " | ")
end

function P.Report()
    local rows = {}
    for _, r in pairs(P.recs) do rows[#rows + 1] = r end

    local out = {
        "WHAT CAUSED THE CRASH - handler profile",
        string.format("hook: osiris=%s debug.getinfo=%s clock=%s | handlers wrapped: %d (source unknown: %d)",
            tostring(P.hookedOsiris), tostring(hasDebug), P.preciseClock and "os.clock (precise)" or "MonotonicTime (1 ms)",
            #rows, P.unknown),
    }
    local mods = {}
    for m, c in pairs(P.byMod) do mods[#mods + 1] = m .. "=" .. c end
    table.sort(mods)
    out[#out + 1] = "per mod: " .. (#mods > 0 and table.concat(mods, ", ") or "(none - is this mod first in the load order?)")
    if P.hookError then out[#out + 1] = "hook error: " .. P.hookError end

    -- Handlers registered per source file: shows at a glance whether a given mod's scripts
    -- (e.g. Skynet.lua) registered anything at all.
    local perFile = {}
    for _, r in ipairs(rows) do
        local file = r.key:match("(%S+):%d+$") or "?"
        perFile[file] = (perFile[file] or 0) + 1
    end
    local files = {}
    for f, c in pairs(perFile) do files[#files + 1] = { f, c } end
    table.sort(files, function(a, b) return a[2] > b[2] end)
    local fl = {}
    for i = 1, math.min(40, #files) do fl[i] = files[i][1] .. "=" .. files[i][2] end
    out[#out + 1] = "handlers per file (top 40): " .. table.concat(fl, ", ")
    out[#out + 1] = string.format("Skynet check: Skynet.lua=%d Logging.lua=%d InsideSkynet.lua=%d",
        perFile["Skynet.lua"] or 0, perFile["Logging.lua"] or 0, perFile["InsideSkynet.lua"] or 0)
    -- Load-progress markers set by Skynet.lua itself (globals): BootstrapRan is set first, then the
    -- helper functions defined near the top (line ~262) and near the registrar (line ~8005), then
    -- RegisterAll at the very end. The first one that is missing is where loading stopped.
    local G = _G or {}
    out[#out + 1] = string.format("Skynet load markers: BootstrapRan=%s GetTrackedDuplicates=%s TryBuffEnemy=%s RegisterAll=%s",
        tostring(G.Skynet_BootstrapRan), type(G.Skynet_GetTrackedDuplicates), type(G.Skynet_TryBuffEnemy),
        type(G.Skynet_RegisterAllOsirisListeners))

    table.sort(rows, function(a, b) return a.total > b.total end)
    out[#out + 1] = ""
    out[#out + 1] = "SESSION TOTALS (top 30)      total_ms    calls   avg_ms   max_ms"
    for i = 1, math.min(30, #rows) do
        local r = rows[i]
        out[#out + 1] = string.format("%10.0f %8d %8.3f %8.1f   %s", r.total, r.calls, r.total / math.max(1, r.calls), r.max, r.key)
    end

    table.sort(rows, function(a, b) return a.max > b.max end)
    out[#out + 1] = ""
    out[#out + 1] = "SLOWEST SINGLE CALLS (top 15)"
    for i = 1, math.min(15, #rows) do
        local r = rows[i]
        out[#out + 1] = string.format("%8.1f ms max   (%d calls)   %s", r.max, r.calls, r.key)
    end

    table.sort(rows, function(a, b) return a.wtotal > b.wtotal end)
    out[#out + 1] = ""
    out[#out + 1] = "SINCE LAST REPORT (top 15)"
    for i = 1, math.min(15, #rows) do
        local r = rows[i]
        if r.wtotal > 0 then out[#out + 1] = string.format("%10.0f ms   %s", r.wtotal, r.key) end
    end
    for _, r in ipairs(rows) do r.wtotal = 0 end

    -- Lua heap growth across handler calls (see the note at the top of the file about what this measures).
    out[#out + 1] = ""
    if P.trackMem then
        out[#out + 1] = string.format("LUA MEMORY: heap now %.0f MB. Growth of the heap across each handler's calls (lower bound; nested handlers included)",
            gc("count") / 1024)
        table.sort(rows, function(a, b) return a.mem > b.mem end)
        out[#out + 1] = "BY SESSION TOTAL (top 20)    total_MB    calls   avg_KB   max_MB"
        for i = 1, math.min(20, #rows) do
            local r = rows[i]
            if r.mem > 0 then
                out[#out + 1] = string.format("%14.1f %8d %8.1f %8.1f   %s", r.mem / 1024, r.calls, r.mem / math.max(1, r.calls), r.memMax / 1024, r.key)
            end
        end
        table.sort(rows, function(a, b) return a.memW > b.memW end)
        out[#out + 1] = "SINCE LAST REPORT (top 10)"
        for i = 1, math.min(10, #rows) do
            local r = rows[i]
            if r.memW > 0 then out[#out + 1] = string.format("%10.1f MB   %s", r.memW / 1024, r.key) end
        end
        for _, r in ipairs(rows) do r.memW = 0 end
    else
        out[#out + 1] = "LUA MEMORY: tracking is off (wcc_prof_mem on) or collectgarbage is not available here."
    end

    pcall(Ext.IO.SaveFile, "WhatCausedTheCrash/profile.txt", table.concat(out, "\n") .. "\n")
end

Ext.RegisterConsoleCommand("wcc_prof", function() P.Report(); Ext.Utils.Print("profile written to Script Extender/WhatCausedTheCrash/profile.txt") end)
Ext.RegisterConsoleCommand("wcc_prof_off", function() P.enabled = false end)
Ext.RegisterConsoleCommand("wcc_prof_on", function() P.enabled = true end)
Ext.RegisterConsoleCommand("wcc_prof_mem", function(_, arg)
    if arg == "on" then P.trackMem = P.memOk elseif arg == "off" then P.trackMem = false end
    Ext.Utils.Print("[WhatCausedTheCrash] Lua memory tracking: " .. (P.trackMem and "on" or "off")
        .. (P.memOk and "" or " (collectgarbage not available)"))
end)

Ext.Utils.Print("[WhatCausedTheCrash] Profiler active (osiris hook: " .. tostring(P.hookedOsiris) .. ", debug.getinfo: " .. tostring(hasDebug) .. ")")
