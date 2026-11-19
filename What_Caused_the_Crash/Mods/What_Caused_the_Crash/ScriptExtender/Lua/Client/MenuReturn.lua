-- Menu-return watch: finds out whether leaving a level (going back to the main menu) crashed, and what was
-- running when it did.
--
-- Every game-state step (Running -> UnloadLevel -> ... -> Menu) is written to menu_return.txt the moment it
-- happens. Reaching the main menu writes REACHED_MENU. If the game dies on the way, the file stops at the last
-- step. On the next launch this script sees an unfinished trip and writes a crash report with:
--   * the steps the game got through and the one it died in,
--   * the server's unload trace (Server/Profiler.lua): every mod script handler that ran while unloading;
--     a handler still marked RUNNING on the last line is the prime suspect.
-- Reports are never overwritten: each goes to menu_crash_reports/ under its own time, and the newest is also
-- copied to MENU_RETURN_CRASH_REPORT.txt.
--
-- Two things learned from the first real run:
--   * Loading a save from the main menu also passes through UnloadLevel. Only an unload that follows Running
--     (actual play) counts as leaving a level.
--   * Client scripts are restarted while the game loads or unloads, and with a big mod list that restart can
--     come two minutes after the last recorded step. So "same game still running" is decided first by a marker
--     kept in the game's memory (it survives a script restart but not a new launch), and only then by time.

local DIR = "WhatCausedTheCrash/"
local FILE = DIR .. "menu_return.txt"
local REPORT = DIR .. "MENU_RETURN_CRASH_REPORT.txt"
local REPORT_DIR = DIR .. "menu_crash_reports/"
local TRACE = DIR .. "unload_trace.txt"
local SAME_RUN_SECONDS = 90
local TRACE_MATCH_SECONDS = 180
-- a text handle used only as an in-memory marker for "this game process has run our script before"
local MARKER_HANDLE = "h5dcc0001g7a11g4b2cg9e3fg0123456789ab"

local function str(v) local ok, r = pcall(tostring, v) return ok and r or "?" end
local function q(fn, ...) local ok, a = pcall(fn, ...) if ok then return a end return nil end
local function epoch() return tonumber(q(function() return Ext.Timer.ClockEpoch() end)) end
local function mono() return tonumber(q(function() return Ext.Utils.MonotonicTime() end)) end
local function clockText() return str(q(function() return Ext.Timer.ClockTime() end) or "?") end
local function loadFile(path) return q(function() return Ext.IO.LoadFile(path) end) end
local function save(path, text) pcall(Ext.IO.SaveFile, path, text) end
local function say(text) pcall(Ext.Utils.Print, "[WhatCausedTheCrash] " .. text) end

local function readMarker()
    local t = q(function() return Ext.Loca.GetTranslatedString(MARKER_HANDLE) end)
    if type(t) == "string" and t:sub(1, 4) == "WCC:" then return t end
    return nil
end

local lines = {}   -- this run's record, as written to FILE

-- "epoch|mono|kind|text|clock"
local function record(kind, text)
    lines[#lines + 1] = table.concat({ str(epoch() or ""), str(mono() or ""), kind, text, clockText() }, "|")
    save(FILE, table.concat(lines, "\n") .. "\n")
end

local function parse(content)
    local rows = {}
    for l in tostring(content or ""):gmatch("[^\n]+") do
        local e, m, kind, text, when = l:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|?(.*)$")
        if kind then rows[#rows + 1] = { epoch = tonumber(e), mono = tonumber(m), kind = kind, text = text, when = when, raw = l } end
    end
    return rows
end

local function toState(row) return row.text:match("%->%s*(%S+)$") or "" end

-- What the previous record says. Returns nil (nothing to report), "same-run" or "crashed", then the row where
-- the level started unloading and a table of what the decision was based on.
local function verdict(rows, sameProcess)
    local wasRunning, unloadAt = false, nil
    for i, r in ipairs(rows) do
        if r.kind == "STATE" then
            local to = toState(r)
            if to == "Running" then
                wasRunning, unloadAt = true, nil
            elseif wasRunning and not unloadAt and (to:find("Unload", 1, true) or to == "Disconnect") then
                unloadAt = i
            end
        end
    end
    if not unloadAt then return nil end   -- never left a level that was being played
    for i = unloadAt, #rows do
        local k = rows[i].kind
        if k == "REACHED_MENU" or k == "QUIT" then return nil end
    end
    local last = rows[#rows]
    local nowE, nowM = epoch(), mono()
    local gap = (last.epoch and nowE) and (nowE - last.epoch) or ((last.mono and nowM) and (nowM - last.mono) / 1000 or nil)
    local why = { gap = gap, sameProcess = sameProcess }
    if sameProcess then return "same-run", unloadAt, why end
    if gap and gap >= 0 and gap < SAME_RUN_SECONDS then return "same-run", unloadAt, why end
    return "crashed", unloadAt, why
end

local function buildReport(rows, unloadAt, why)
    local out = {
        "WHAT CAUSED THE CRASH - THE GAME CRASHED WHILE LEAVING THE LEVEL (on the way back to the main menu)",
        "(If you quit to the desktop last time and it closed normally, ignore this file.)",
        "",
        "Steps the game went through (the last one is where it died):",
    }
    for i = unloadAt, #rows do
        local r = rows[i]
        out[#out + 1] = string.format("  %s  %-17s %s", r.when ~= "" and r.when or "?", r.kind, r.text)
    end
    local lastState = "?"
    for i = #rows, unloadAt, -1 do
        if rows[i].kind == "STATE" then lastState = toState(rows[i]) break end
    end
    out[#out + 1] = ""
    out[#out + 1] = "It died during: " .. lastState .. " (the main menu was never reached)."
    out[#out + 1] = string.format("How this was decided: the game was started again %s after the last step, and the in-memory marker of the earlier game was gone.",
        why and why.gap and string.format("%.0f s", why.gap) or "some time")
    out[#out + 1] = ""
    local trace = loadFile(TRACE)
    if trace and trace ~= "" then
        local traceEpoch = tonumber(trace:match("epoch=(%d+)"))
        local unloadEpoch = rows[unloadAt].epoch
        local matches = not (traceEpoch and unloadEpoch) or math.abs(traceEpoch - unloadEpoch) <= TRACE_MATCH_SECONDS
        local tl = {}
        for l in trace:gmatch("[^\n]+") do tl[#tl + 1] = l end
        local lastLine = tl[#tl] or ""
        if not matches then
            out[#out + 1] = "The server unload trace on disk is from a DIFFERENT unload (see its time below), not from this trip,"
            out[#out + 1] = "so it does not show what ran during this crash."
        elseif lastLine:find("RUNNING", 1, true) then
            out[#out + 1] = "SUSPECT: the game died while this mod script handler was running:"
            out[#out + 1] = "  " .. lastLine
            out[#out + 1] = "The file name and line in it point to the mod. Try leaving the level without that mod (or with that"
            out[#out + 1] = "feature of it switched off), or send this report to its author."
        else
            out[#out + 1] = "No mod script was running at the moment of the crash: every handler in the trace below finished."
            out[#out + 1] = "So the crash is in the game's own unloading - usually caused by a mod's content (models, textures,"
            out[#out + 1] = "effects, templates) rather than its scripts. The handlers at the end of the trace show which mods"
            out[#out + 1] = "were still doing things while the game unloaded; they are the place to start."
        end
        out[#out + 1] = ""
        out[#out + 1] = "SERVER UNLOAD TRACE (last 300 handler calls):"
        out[#out + 1] = string.rep("=", 70)
        out[#out + 1] = trace
    else
        out[#out + 1] = "No server unload trace was found (unload_trace.txt), so there is no list of what mod scripts ran."
    end
    return table.concat(out, "\n") .. "\n"
end

-- ==================== on load: look at how the previous trip ended ====================
local marker = readMarker()
local sameProcess = marker ~= nil
if not marker then
    pcall(function() Ext.Loca.UpdateTranslatedString(MARKER_HANDLE, "WCC:" .. str(epoch() or mono() or "set")) end)
end
local markerNote = sameProcess and "marker found: same game process as before"
    or (readMarker() and "marker set: first script start in this game process" or "marker unavailable")

local previous = parse(loadFile(FILE))
local outcome, unloadAt, why = verdict(previous, sameProcess)
if outcome == "crashed" then
    local text = buildReport(previous, unloadAt, why)
    local stamp = str(previous[unloadAt].when or ""):gsub("%..*$", ""):gsub("[^%d]+", "-")
    if stamp == "" then stamp = str(epoch() or mono() or "unknown") end
    save(REPORT_DIR .. "MENU_RETURN_CRASH_" .. stamp .. ".txt", text)   -- kept: never overwritten by a later one
    save(REPORT, text)
    save(DIR .. "previous_menu_return.txt", loadFile(FILE) or "")
    say("The game crashed last time while leaving the level. See Script Extender/" .. REPORT)
    lines = {}
    record("START", "game started (the previous trip out of the level crashed - see MENU_RETURN_CRASH_REPORT.txt); " .. markerNote)
elseif sameProcess or outcome == "same-run" then
    -- scripts restarted inside the same game run: keep the record and carry on watching
    for _, r in ipairs(previous) do lines[#lines + 1] = r.raw end
    record("SCRIPTS_RESTARTED", "client scripts reloaded; " .. markerNote)
else
    lines = {}
    record("START", "client scripts loaded; " .. markerNote)
end

pcall(function()
    Ext.Events.GameStateChanged:Subscribe(function(e)
        local from, to = str(e.FromState), str(e.ToState)
        if to == "Running" then
            lines = {}   -- a new stretch of play: only the next trip out of the level matters
        end
        record("STATE", from .. " -> " .. to)
        if to == "Menu" then
            record("REACHED_MENU", "the main menu loaded - no crash")
        elseif to:find("Exit", 1, true) then
            record("QUIT", "the game is quitting to the desktop")
        end
    end)
end)

WCC_MenuReturn = { verdict = verdict, parse = parse, buildReport = buildReport }
