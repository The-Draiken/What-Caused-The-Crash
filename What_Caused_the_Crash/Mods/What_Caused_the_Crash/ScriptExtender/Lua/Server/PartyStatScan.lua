-- Party stat scan: lists the stat entries the party carries (passives, statuses, equipped items and everything they
-- grant) and ranks the ones most likely to break the dice-roll screen.
--
-- Run it from MCM ("Scan the party's stats now" - it unticks itself) or the console: !wcc_scan_party
-- Result: Script Extender/WhatCausedTheCrash/party_stat_scan.txt and the top suspects in the Script Extender console.
--
-- Why these checks: the roll screen evaluates everything that hooks into ability checks (passives whose
-- StatsFunctorContext / EnabledContext / ToggleOffContext include OnAbilityCheck - Lucky, Tides of Chaos, Guidance-like
-- options - and interrupts that fire on rolls) and every boost that changes the roll. APCS 3.1 crashed that screen
-- through such a passive (Stress_SavingThrow_Passive, OnAttacked;OnAbilityCheck, asking IsAttack() during an ability
-- check). Mistakes of that kind are ranked first. Base-game entries are listed only if a mod replaced them.
-- The crash happening whatever party member rolls points at something every party member has: such entries get a
-- higher score.

local W = WCC
local FILE = "WhatCausedTheCrash/party_stat_scan.txt"
local BASE_MODS = { Gustav = true, GustavDev = true, GustavX = true, Shared = true, SharedDev = true, Honour = true,
    HonourX = true, MainUI = true, ModBrowser = true }
local SLOTS = { "Helmet", "Breast", "Cloak", "MeleeMainHand", "MeleeOffHand", "RangedMainHand", "RangedOffHand", "Ring",
    "Ring2", "Underwear", "Boots", "Gloves", "Amulet", "MusicalInstrument", "VanityBody", "VanityBoots", "Wings", "Horns",
    "Overhead" }
local HOOK_FIELDS = { "StatsFunctorContext", "EnabledContext", "ToggleOffContext", "ToggleOnContext" }
local TEXT_FIELDS = { "Boosts", "BoostConditions", "Conditions", "RemoveConditions", "EnabledConditions",
    "TickFunctors", "OnApplyFunctors", "OnRemoveFunctors", "StatsFunctors", "ToggleOnFunctors", "ToggleOffFunctors",
    "AuraStatuses", "Roll", "Success", "Failure" }
local ATTACK_ONLY = { "IsAttack", "IsCritical", "IsCriticalMiss", "IsHit", "IsMiss", "IsKillingBlow", "IsMeleeAttack",
    "IsRangedAttack", "IsWeaponAttack", "IsSpellAttack", "IsUnarmedAttack" }

local function str(v) local ok, r = pcall(tostring, v) return ok and r or "?" end
local function guidOf(uuid) return str(uuid):match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or str(uuid) end

-- a stat field as text: strings stay, flag lists / tables are joined
local function field(stat, name)
    local ok, v = pcall(function() return stat[name] end)
    if not ok or v == nil then return "" end
    if type(v) == "table" or type(v) == "userdata" then
        local parts = {}
        local okp = pcall(function() for _, x in pairs(v) do parts[#parts + 1] = str(x) end end)
        if okp and #parts > 0 then return table.concat(parts, ";") end
        return ""
    end
    return str(v)
end

local function getStat(name)
    if not name or name == "" then return nil end
    local ok, s = pcall(Ext.Stats.Get, name, nil, false)
    if ok then return s end
    return nil
end

local modNames = {}
local function modName(id)
    id = str(id)
    if id == "" or id == "nil" then return "?" end
    if modNames[id] then return modNames[id] end
    local ok, n = pcall(function() return Ext.Mod.GetMod(id).Info.Name end)
    modNames[id] = (ok and n) and str(n) or id
    return modNames[id]
end

local function bracketProblem(v)
    local depth = 0
    for ch in v:gmatch("[()]") do
        depth = depth + (ch == "(" and 1 or -1)
        if depth < 0 then return "a ) with no matching (" end
    end
    if depth > 0 then return depth .. " unclosed (" end
    local _, quotes = v:gsub("'", "")
    if quotes % 2 == 1 then return "odd number of ' quotes" end
    return nil
end

local function charName(uuid)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
    if ok and n and n ~= "" then return n end
    return guidOf(uuid):sub(1, 8)
end

local function party()
    local list, seen = {}, {}
    for _, db in ipairs({ "DB_PartyMembers", "DB_Players" }) do
        local ok, rows = pcall(function() return Osi[db]:Get(nil) end)
        if ok and type(rows) == "table" then
            for _, r in ipairs(rows) do
                local g = guidOf(r[1])
                if not seen[g] then seen[g] = true list[#list + 1] = g end
            end
        end
    end
    return list
end

-- ==================== COLLECT: what each party member carries ====================

local function collect(uuid)
    local found = {}   -- statName -> how it got there
    local function add(name, how)
        if name and name ~= "" and not found[name] then found[name] = how end
    end
    local entity = nil
    pcall(function() entity = Ext.Entity.Get(uuid) end)
    if entity then
        pcall(function()
            for _, p in pairs(entity.PassiveContainer.Passives) do add(str(p.Passive.PassiveId), "passive") end
        end)
        pcall(function()
            for _, s in pairs(entity.StatusContainer.Statuses) do add(str(s), "status") end
        end)
    end
    for _, slot in ipairs(SLOTS) do
        local ok, item = pcall(Osi.GetEquippedItem, uuid, slot)
        if ok and item then
            local statsId = nil
            pcall(function() statsId = str(Ext.Entity.Get(item).Data.StatsId) end)
            if not statsId or statsId == "" or statsId == "nil" then
                pcall(function() statsId = Osi.GetStatString(item) end)
            end
            if statsId and statsId ~= "" then add(statsId, "equipped (" .. slot .. ")") end
        end
    end
    -- follow what these grant: passives of statuses and items, statuses of items, interrupts unlocked by boosts
    local queue = {}
    for name in pairs(found) do queue[#queue + 1] = name end
    local i = 1
    while i <= #queue and i < 2000 do
        local name = queue[i]; i = i + 1
        local s = getStat(name)
        if s then
            for _, f in ipairs({ "Passives", "PassivesOnEquip", "StatusOnEquip" }) do
                for raw in field(s, f):gmatch("[^;]+") do
                    local p = raw:gsub("^%s+", ""):gsub("%s+$", "")
                    if p ~= "" and not found[p] then
                        found[p] = "granted by " .. name
                        queue[#queue + 1] = p
                    end
                end
            end
            for intr in field(s, "Boosts"):gmatch("UnlockInterrupt%(%s*([%w_]+)") do
                if not found[intr] then found[intr] = "interrupt unlocked by " .. name queue[#queue + 1] = intr end
            end
        end
    end
    return found
end

-- ==================== JUDGE: what is wrong with one entry ====================

local function judge(name)
    local s = getStat(name)
    local r = { name = name, score = 0, notes = {}, missing = (s == nil) }
    if not s then return r end
    r.type = field(s, "ModifierList")
    if r.type == "" then r.type = field(s, "StatsType") end
    local modId, origId = field(s, "ModId"), field(s, "OriginalModId")
    r.mod, r.origMod = modName(modId), modName(origId)
    r.base = BASE_MODS[r.mod] == true
    r.replacedBase = (not r.base) and BASE_MODS[r.origMod] == true

    local function note(points, text) r.score = r.score + points r.notes[#r.notes + 1] = text end

    -- 1. hooks into ability checks (the roll screen evaluates these)
    local hooked = false
    for _, f in ipairs(HOOK_FIELDS) do
        if field(s, f):find("OnAbilityCheck", 1, true) then hooked = true end
    end
    local ictx = field(s, "InterruptContext")
    if ictx:find("Roll", 1, true) then hooked = true end
    if hooked and not r.base then
        if ictx ~= "" then
            note(2, "a reaction that can trigger on rolls (" .. ictx .. ")")
        else
            note(5, "runs when an ability check starts (roll screen)")
        end
        local cond = field(s, "Conditions")
        if field(s, "StatsFunctorContext"):find("OnAbilityCheck", 1, true) and not cond:find("HasContextFlag", 1, true) then
            for _, fn in ipairs(ATTACK_ONLY) do
                if cond:find(fn .. "(", 1, true) then
                    note(4, "asks " .. fn .. "() during an ability check without a context check (the APCS 3.1 crash pattern)")
                    break
                end
            end
        end
        if (field(s, "ToggleOffContext") ~= "" or field(s, "EnabledContext") ~= "")
            and not field(s, "Properties"):find("IsToggled", 1, true) then
            note(3, "has roll-screen toggle settings but is not a toggled passive")
        end
        if r.replacedBase then note(1, "replaces the base game's version (" .. r.origMod .. ")") end
    end

    -- 2. syntax mistakes in boosts, conditions and functors
    for _, f in ipairs(TEXT_FIELDS) do
        local v = field(s, f)
        if v ~= "" then
            local p = bracketProblem(v)
            if p then note(4, f .. ": " .. p) end
        end
    end

    -- 3. references to entries nobody defines
    local using = field(s, "Using")
    if using ~= "" and using ~= name and not getStat(using) then note(4, "using \"" .. using .. "\", which does not exist") end
    for _, f in ipairs({ "Passives", "PassivesOnEquip", "StatusOnEquip" }) do
        for raw in field(s, f):gmatch("[^;]+") do
            local p = raw:gsub("^%s+", ""):gsub("%s+$", "")
            if p ~= "" and not getStat(p) then note(3, f .. " lists " .. p .. ", which does not exist") end
        end
    end

    -- 4. changes ability checks (read by the roll screen) - minor on its own
    if not r.base then
        local boosts = field(s, "Boosts")
        if boosts:find("SkillCheck", 1, true) or boosts:find("AllAbilities", 1, true) or boosts:find("RawAbility", 1, true)
            or boosts:find("Advantage(Skill", 1, true) or boosts:find("Disadvantage(Skill", 1, true)
            or boosts:find("Advantage(Ability", 1, true) or boosts:find("Disadvantage(Ability", 1, true) then
            note(1, "changes ability-check rolls")
        end
    end
    return r
end

-- ==================== SCAN ====================

local function scan(trigger)
    local members = party()
    local lines = { "WHAT CAUSED THE CRASH - PARTY STAT SCAN (" .. str(trigger) .. ")",
        "Party members scanned: " .. #members, "",
        "Each entry the party carries (passive, status, equipped item and what they grant) is checked. Score: higher =",
        "more likely to break the dice-roll screen. Entries every party member has score extra, because the crash happens",
        "whoever rolls. Base-game entries are left out unless a mod replaced them.", "" }
    local carriers = {}   -- statName -> { names }
    local howOf = {}
    for _, uuid in ipairs(members) do
        local nm = charName(uuid)
        lines[#lines + 1] = "  " .. nm .. "  (" .. uuid .. ")"
        for statName, how in pairs(collect(uuid)) do
            carriers[statName] = carriers[statName] or {}
            table.insert(carriers[statName], nm)
            howOf[statName] = howOf[statName] or how
        end
    end
    local results, missing, total = {}, {}, 0
    for statName, who in pairs(carriers) do
        total = total + 1
        local r = judge(statName)
        r.who, r.how = who, howOf[statName]
        if r.missing then
            if howOf[statName] ~= "status" then   -- engine statuses have no stat entry
                missing[#missing + 1] = r
                r.type, r.mod = "missing", "?"
                if str(howOf[statName]):find("interrupt unlocked by", 1, true) then
                    r.score = 6
                    r.notes = { "unlocks a reaction that does not exist - the game checks the reactions of everyone nearby on every roll" }
                else
                    r.score = 3
                    r.notes = { "points at a stat entry that does not exist" }
                end
                local src = getStat((str(howOf[statName]):match("by (.+)$")) or "")
                if src then r.mod = modName(field(src, "ModId")) end
                results[#results + 1] = r
            end
        elseif r.score > 0 then
            if #members > 1 and #who == #members then
                r.score = r.score + 2
                r.notes[#r.notes + 1] = "every party member has it"
            end
            results[#results + 1] = r
        end
    end
    table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.name < b.name
    end)
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Entries checked: %d.  Flagged: %d.  Referenced but missing: %d.", total, #results, #missing)
    lines[#lines + 1] = ""
    for i, r in ipairs(results) do
        lines[#lines + 1] = string.format("%3d. [score %d] %s  (%s)  from mod: %s%s", i, r.score, r.name, r.type or "?",
            r.mod or "?", (r.origMod and r.origMod ~= r.mod) and ("  (originally " .. r.origMod .. ")") or "")
        lines[#lines + 1] = "       how the party has it: " .. str(r.how) .. "  | who: " .. table.concat(r.who, ", ")
        for _, n in ipairs(r.notes) do lines[#lines + 1] = "       - " .. n end
    end
    if #missing > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Granted or equipped but with no stat entry (a mod points at something that does not exist):"
        for _, r in ipairs(missing) do
            lines[#lines + 1] = "   " .. r.name .. "  (" .. str(r.how) .. "; " .. table.concat(r.who, ", ") .. ")"
        end
    end
    pcall(Ext.IO.SaveFile, FILE, table.concat(lines, "\n"))

    local box = { "WHAT CAUSED THE CRASH - party stat scan done (" .. #results .. " flagged).", "Most likely to break the roll screen:" }
    for i = 1, math.min(5, #results) do
        local r = results[i]
        box[#box + 1] = string.format("%d. %s (%s) - %s", i, r.name, r.mod or "?", r.notes[1] or "")
    end
    if #results == 0 then box[#box + 1] = "Nothing flagged." end
    box[#box + 1] = "Full list: Script Extender/WhatCausedTheCrash/party_stat_scan.txt"
    local text = table.concat(box, "\n")
    Ext.Utils.Print("[WhatCausedTheCrash] " .. text)
    pcall(function() W.Log("SCAN", "party stat scan: " .. #results .. " flagged, top: " .. (results[1] and results[1].name or "none")) end)
    -- no message box: closing one crashed the game on the setup this was built for
    return results, lines
end

-- MCM: ticking "Scan the party's stats now" runs the scan and unticks itself
local subscribed = false
local lastScan = -1e9
local function nowMs()
    local ok, t = pcall(function() return Ext.Utils.MonotonicTime() end)
    return ok and tonumber(t) or 0
end
local function subscribe()
    if subscribed then return end
    subscribed = pcall(function()
        Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
            if payload and payload.modUUID == ModuleUUID and payload.settingId == "ScanPartyStatsNow" and payload.value == true then
                pcall(function() Mods.BG3MCM.MCMAPI:SetSettingValue("ScanPartyStatsNow", false, ModuleUUID) end)
                local t = nowMs()
                local tooSoon = t - lastScan < 15000   -- ticked again while the last scan's box was up
                lastScan = t                            -- every tick restarts the wait, so steady clicking scans once
                if tooSoon then return end
                local ok, err = pcall(scan, "MCM")
                if not ok then Ext.Utils.PrintError("[WhatCausedTheCrash] party stat scan failed: " .. str(err)) end
            end
        end)
    end)
end
pcall(function() Ext.Events.SessionLoaded:Subscribe(subscribe) end)
pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", subscribe)

Ext.RegisterConsoleCommand("wcc_scan_party", function()
    local ok, err = pcall(scan, "console")
    if not ok then Ext.Utils.PrintError("[WhatCausedTheCrash] party stat scan failed: " .. str(err)) end
end)

W.PartyStatScan = scan
W._PartyScanJudge = judge
