-- Pause a fight restored from a save, two MCM options (both off by default):
--   "Pause the fight during loading (resumes by itself)": paused when the level starts, resumed once the game has run
--     smoothly for a few seconds after loading (the load's own freeze is over), so the fight does not compete with it.
--   "Pause a fight that was saved in progress": paused until you untick it. Wins if both are ticked.
-- A save made during a fight brings that fight back while the level loads. If such a save crashes a few seconds after
-- loading, this pauses the fight with the game's own PauseCombat (the call vanilla scripts use while a dialog runs
-- mid-fight) as soon as the level starts, so nothing in it is processed. While it is paused, attacks and throws
-- start their animation and stop. Unticking the option, or "!wcc_resume_fight" in the Script Extender console,
-- resumes it.

local W = WCC
local restored = {}   -- combat guid -> true: fights that started while the save was still loading
local paused = {}
local running = false
-- automatic resume: once the game has run SETTLE_MS without a hitch longer than HITCH_MS, no sooner than MIN_MS and
-- no later than MAX_MS after gameplay is ready. Resuming fights straight away at load crashed the game in an earlier
-- version, which is why it waits for the load to settle.
local HITCH_MS, SETTLE_MS, MIN_MS, MAX_MS = 250, 3000, 2000, 60000
local auto = nil      -- { ready = time gameplay was ready, last = last tick time, calmSince = time }
local tickSub = nil
local stopWatching, resumeAll  -- defined below, used by the load-state handler above them

local function str(v) local ok, r = pcall(tostring, v) return ok and r or "?" end

local function mcm(id)
    local ok, v = pcall(function() return Mods.BG3MCM.MCMAPI:GetSettingValue(id, ModuleUUID) end)
    if ok then return v end
    return nil
end

local PAUSED_TEXT = "WHAT CAUSED THE CRASH: the fight that was in progress when this save was made has been paused, so nobody "
    .. "in it can act. To continue the fight, untick \"Pause a fight that was saved in progress (until you untick it)\" in MCM, or type "
    .. "!wcc_resume_fight in the Script Extender console."

Ext.Events.GameStateChanged:Subscribe(function(e)
    local to = str(e.ToState)
    if to == "Running" then running = true
    elseif to:find("Load") or to:find("Unload") or to:find("Menu") then
        running = false
        restored, paused = {}, {}
        stopWatching()
    end
end)

-- fights that start before the game is running were in the save
pcall(Ext.Osiris.RegisterListener, "CombatStarted", 1, "after", function(cid)
    if not running then restored[str(cid)] = true end
end)

local function now()
    local ok, t = pcall(function() return Ext.Utils.MonotonicTime() end)
    return ok and tonumber(t) or 0
end


function stopWatching()
    if tickSub then pcall(function() Ext.Events.Tick:Unsubscribe(tickSub) end) end
    tickSub, auto = nil, nil
end

local function watchTick()
    if not auto then return end
    local t = now()
    if auto.last and t - auto.last > HITCH_MS then auto.calmSince = t end
    auto.last = t
    local sinceReady = t - auto.ready
    if sinceReady < MAX_MS and not running then return end   -- the time limit below applies no matter what
    if sinceReady >= MAX_MS then
        stopWatching()
        resumeAll(string.format("loading did not settle within %d s, resumed anyway", MAX_MS // 1000))
    elseif sinceReady >= MIN_MS and t - auto.calmSince >= SETTLE_MS then
        stopWatching()
        resumeAll(string.format("loading settled %.1f s after gameplay was ready", sinceReady / 1000))
    end
end

pcall(Ext.Osiris.RegisterListener, "LevelGameplayReady", 2, "after", function()
    if auto then
        auto.ready = now()
        auto.calmSince = auto.ready
    end
end)

pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", function()
    local manual = mcm("PauseRestoredFight")
    local during = mcm("PauseFightDuringLoad")
    if not manual and not during then return end
    -- also any fight the party is in right now, in case the save's fight was restored without a CombatStarted
    pcall(function()
        for _, row in ipairs(Osi.DB_Is_InCombat:Get(nil, nil)) do
            local okP, isPlayer = pcall(function() return Osi.IsPlayer(row[1]) end)
            if okP and isPlayer == 1 then restored[str(row[2])] = true end
        end
    end)
    local n = 0
    for cid in pairs(restored) do
        local ok, err = pcall(Osi.PauseCombat, cid)
        if ok then paused[cid] = true n = n + 1 end
        W.Log("LOADPAUSE", "paused fight restored from the save " .. cid:sub(1, 8) .. (ok and "" or (" — failed: " .. str(err))))
    end
    if n == 0 then W.Log("LOADPAUSE", "no fight was restored from this save, nothing paused") end
    W.FlushNow()
    if n > 0 and manual then
        pcall(function() Osi.OpenMessageBox(Osi.GetHostCharacter(), PAUSED_TEXT) end)
    elseif n > 0 then
        -- resumes by itself once the load has settled
        stopWatching()
        -- ready is set here too: if LevelGameplayReady never fires (or fired before this), the fight would
        -- otherwise never resume, not even at the time limit
        auto = { last = now() }
        auto.calmSince, auto.ready = auto.last, auto.last
        local ok, sub = pcall(function() return Ext.Events.Tick:Subscribe(watchTick) end)
        if ok then tickSub = sub else
            W.Log("LOADPAUSE", "could not watch the game tick; resuming now")
            auto = nil
            resumeAll("tick unavailable")
        end
    end
end)

function resumeAll(why)
    local n = 0
    for cid in pairs(paused) do
        if pcall(Osi.ResumeCombat, cid) then n = n + 1 end
        paused[cid] = nil
    end
    W.Log("LOADPAUSE", "resumed " .. n .. " fight(s) (" .. why .. ")")
    W.FlushNow()
    Ext.Utils.Print("[WhatCausedTheCrash] resumed " .. n .. " fight(s)")
    return n
end

Ext.RegisterConsoleCommand("wcc_resume_fight", function() stopWatching() resumeAll("console") end)

-- unticking the option resumes the fight it paused
local subscribed = false
local function subscribe()
    if subscribed then return end
    subscribed = pcall(function()
        Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
            if payload and payload.modUUID == ModuleUUID and payload.settingId == "PauseRestoredFight" and payload.value == false then
                resumeAll("option unticked")
            end
        end)
    end)
end
pcall(function() Ext.Events.SessionLoaded:Subscribe(subscribe) end)
pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", subscribe)
