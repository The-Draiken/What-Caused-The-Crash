-- Missing-things scan: goes through every party member's inventory (bags included), statuses and passives and lists
-- anything the game cannot find - an item whose template or stat entry no longer exists (usually left behind by a
-- removed or changed mod), an item that casts a spell with no stat entry (a scroll whose spell was never added or was
-- removed), an item whose name resolves to nothing / "Not Found", a status or passive with no stat
-- entry. The dice-roll screen reads the roller's and the party's items and statuses, so such leftovers are suspects.
--
--   MCM "Scan inventories and statuses for missing things"  or console  !wcc_scan_missing
--   MCM "Delete what the scan found"                         or console  !wcc_delete_missing all   (or a number: 3)
-- Result: Script Extender/WhatCausedTheCrash/missing_scan.txt and the Script Extender console (no message box: closing
-- one crashed the game on the setup this was built for).
-- Delete only touches what the last scan in this session listed, and checks each one is still missing first:
-- items are deleted, statuses removed, passives removed. Make a new save before deleting.
-- Every deletion is added to Script Extender/WhatCausedTheCrash/deleted_log.txt (never overwritten): when, who, the
-- item's name, template, stat entry, stack and id, and why it was flagged - so you can trace what fixed the crash.

local W = WCC
local FILE = "WhatCausedTheCrash/missing_scan.txt"
local DELETED_LOG = "WhatCausedTheCrash/deleted_log.txt"   -- only ever added to, never overwritten
local found = {}          -- last scan: { kind, owner, ownerName, id, name, reasons }
local scannedAt = nil

local function str(v) local ok, r = pcall(tostring, v) return ok and r or "?" end
local function q(fn, ...) local ok, a, b = pcall(fn, ...) if ok then return a, b end return nil, nil end
local function guidOf(uuid) return str(uuid):match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or str(uuid) end
local function getStat(name)
    if not name or name == "" then return nil end
    local ok, s = pcall(Ext.Stats.Get, name, nil, false)
    if ok then return s end
    return nil
end

local function charName(uuid)
    local n = q(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
    if n and n ~= "" then return n end
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

-- ==================== CHECKS ====================

local function templateExists(id)
    if not id or id == "" then return false end
    if q(function() return Ext.Template.GetTemplate(id) end) then return true end
    if q(function() return Ext.Template.GetRootTemplate(id) end) then return true end
    return false
end

-- spells an item casts or teaches when used (scrolls, potions, ...) that have no stat entry. Found in the field: VBT's
-- "Scroll of Dying Star's Breath" casts VBT_Spell_3_BreathOfHadar, which no pak defines - carrying it crashed the game
-- whenever the dice-roll screen opened (that screen looks at what the roller could use).
local ACTION_LISTS = { "OnUsePeaceActions", "OnUseActions" }
local SPELL_FIELDS = { "SpellId", "SkillID", "Spell" }
local function templateSpells(t)
    local spells = {}
    for _, listName in ipairs(ACTION_LISTS) do
        local actions = q(function() return t[listName] end)
        if type(actions) == "table" or type(actions) == "userdata" then
            pcall(function()
                for _, a in pairs(actions) do
                    for _, f in ipairs(SPELL_FIELDS) do
                        local v = q(function() return a[f] end)
                        if type(v) == "string" and v ~= "" then spells[#spells + 1] = v end
                    end
                end
            end)
        end
    end
    return spells
end
local function itemMissingSpells(tplId)
    tplId = guidOf(tplId)
    local missing, seenSpell = {}, {}
    for _ = 1, 6 do   -- the template, or the nearest parent template that has use actions
        if not tplId or tplId == "" then break end
        local t = q(function() return Ext.Template.GetTemplate(tplId) end) or q(function() return Ext.Template.GetRootTemplate(tplId) end)
        if not t then break end
        local spells = templateSpells(t)
        if #spells > 0 then
            for _, s in ipairs(spells) do
                if not seenSpell[s] then
                    seenSpell[s] = true
                    if not getStat(s) then missing[#missing + 1] = s end
                end
            end
            break
        end
        local parent = q(function() return str(t.ParentTemplateId) end)
        if not parent or parent == "" or parent == "nil" or guidOf(parent) == tplId then break end
        tplId = guidOf(parent)
    end
    return missing
end

-- reasons an item is "not found", or nil when it is fine
local function itemProblems(entity, uuid)
    local reasons = {}
    local tpl = q(function() return Osi.GetTemplate(uuid) end)
    if not tpl or tpl == "" then
        reasons[#reasons + 1] = "has no template"
    elseif not templateExists(guidOf(tpl)) then
        reasons[#reasons + 1] = "template " .. str(tpl) .. " not found"
    else
        for _, s in ipairs(itemMissingSpells(tpl)) do
            reasons[#reasons + 1] = "casts spell " .. s .. ", which does not exist"
        end
    end
    local statsId = q(function() return str(entity.Data.StatsId) end)
    if not statsId or statsId == "" or statsId == "nil" then statsId = q(function() return Osi.GetStatString(uuid) end) end
    if statsId and statsId ~= "" and statsId ~= "nil" and not getStat(statsId) then
        reasons[#reasons + 1] = "stat entry " .. statsId .. " not found"
    end
    local name = q(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
    if name == nil or name == "" then
        reasons[#reasons + 1] = "name resolves to nothing"
    elseif name:lower():find("not found", 1, true) then
        reasons[#reasons + 1] = "name shows \"" .. name .. "\""
    end
    if #reasons == 0 then return nil end
    return reasons, name, tpl, statsId
end

local function scanInventory(entity, owner, ownerName, depth, out, counts)
    if depth > 6 then return end
    local ok, invs = pcall(function() return entity.InventoryOwner.Inventories end)
    if not ok or not invs then return end
    for _, inv in pairs(invs) do
        local okI, items = pcall(function() return inv.InventoryContainer.Items end)
        if okI and items then
            for _, slot in pairs(items) do
                local item = slot.Item
                local okU, iuuid = pcall(function() return item.Uuid.EntityUuid end)
                if okU and iuuid then
                    counts.items = counts.items + 1
                    local reasons, name, tpl, statsId = itemProblems(item, iuuid)
                    if reasons then
                        local _, stack = q(function() return Osi.GetStackAmount(iuuid) end)
                        out[#out + 1] = { kind = "item", owner = owner, ownerName = ownerName, id = iuuid,
                            name = (name and name ~= "") and name or (tpl or statsId or iuuid), reasons = reasons,
                            template = tpl, statsId = statsId, stack = tonumber(stack) }
                    end
                    scanInventory(item, owner, ownerName, depth + 1, out, counts)
                end
            end
        end
    end
end

-- statuses the engine creates itself (DYING, HEAL, ...): they never have a stat entry and must not be removed
local ENGINE_STATUSES = { DYING = true, HEAL = true, KNOCKED_DOWN = true, TELEPORT_FALLING = true, UNLOCK = true,
    SMELLY = true, CLEAN = true, SITTING = true, LYING = true, SUMMONING = true, STORY_FROZEN = true, ROTATE = true,
    MATERIAL = true, FEAR = true, EFFECT = true, DEACTIVATED = true, CLIMBING = true, INCAPACITATED = true,
    INSURFACE = true, BOOST = true, REACTION = true, DOWNED = true, DESTROYING = true, ENCUMBERED = true }
local function isEngineStatus(id)
    if ENGINE_STATUSES[id] then return true end
    local ok, known = pcall(function()
        for _, v in pairs(Ext.Enums.StatusType) do if tostring(v) == id then return true end end
        return false
    end)
    return ok and known == true
end

local function scanCharacter(uuid, out, counts)
    local nm = charName(uuid)
    local entity = q(function() return Ext.Entity.Get(uuid) end)
    if not entity then return nm end
    scanInventory(entity, uuid, nm, 0, out, counts)
    pcall(function()
        for _, s in pairs(entity.StatusContainer.Statuses) do
            local id = str(s)
            counts.statuses = counts.statuses + 1
            if id ~= "" and not getStat(id) and not isEngineStatus(id) then
                out[#out + 1] = { kind = "status", owner = uuid, ownerName = nm, id = id, name = id,
                    reasons = { "status has no stat entry" } }
            end
        end
    end)
    pcall(function()
        for _, p in pairs(entity.PassiveContainer.Passives) do
            local id = str(p.Passive.PassiveId)
            counts.passives = counts.passives + 1
            if id ~= "" and not getStat(id) then
                out[#out + 1] = { kind = "passive", owner = uuid, ownerName = nm, id = id, name = id,
                    reasons = { "passive has no stat entry" } }
            end
        end
    end)
    return nm
end

local function stillMissing(e)
    if e.kind == "item" then
        local entity = q(function() return Ext.Entity.Get(e.id) end)
        if not entity then return false end
        return itemProblems(entity, e.id) ~= nil
    end
    return getStat(e.id) == nil
end

-- ==================== SCAN / DELETE ====================

-- console only: closing a message box crashed the game on a setup with the dice-roll crash, so no pop-ups here
local function notify(text)
    Ext.Utils.Print("[WhatCausedTheCrash] " .. text)
end

local function scan(trigger)
    local members = party()
    local out, counts = {}, { items = 0, statuses = 0, passives = 0 }
    local names = {}
    for _, uuid in ipairs(members) do names[#names + 1] = scanCharacter(uuid, out, counts) end
    -- safety: a check that flags a big share of all items is not working in this game version (a lookup that always
    -- fails), not a real finding - drop its results so "Delete" can never empty the inventories
    local distrusted = {}
    local byCheck = { template = 0, stat = 0, name = 0, spell = 0 }
    local function checkOf(reason)
        if reason:find("casts spell", 1, true) then return "spell" end
        if reason:find("template", 1, true) then return "template" end
        if reason:find("stat entry", 1, true) then return "stat" end
        if reason:find("name", 1, true) then return "name" end
    end
    for _, e in ipairs(out) do
        if e.kind == "item" then
            local seen = {}
            for _, r in ipairs(e.reasons) do
                local c = checkOf(r)
                if c and not seen[c] then seen[c] = true byCheck[c] = byCheck[c] + 1 end
            end
        end
    end
    for c, n in pairs(byCheck) do
        if n > 5 and n > counts.items * 0.25 then distrusted[c] = n end
    end
    if next(distrusted) then
        local kept = {}
        for _, e in ipairs(out) do
            if e.kind == "item" then
                local reasons = {}
                for _, r in ipairs(e.reasons) do
                    if not distrusted[checkOf(r) or ""] then reasons[#reasons + 1] = r end
                end
                e.reasons = reasons
                if #reasons > 0 then kept[#kept + 1] = e end
            else
                kept[#kept + 1] = e
            end
        end
        out = kept
    end
    found, scannedAt = out, q(function() return Ext.Utils.MonotonicTime() end)
    local lines = { "WHAT CAUSED THE CRASH - MISSING-THINGS SCAN (" .. str(trigger) .. ")",
        "Party: " .. table.concat(names, ", "),
        string.format("Checked %d items (bags included), %d statuses, %d passives.", counts.items, counts.statuses, counts.passives),
        "", }
    if counts.items == 0 then
        lines[#lines + 1] = "WARNING: no items were read at all - the inventory reading did not work, so this result says nothing about items."
        lines[#lines + 1] = ""
    end
    for c, n in pairs(distrusted) do
        lines[#lines + 1] = string.format("WARNING: the %s check flagged %d of %d items - it is not working in this game version, so its results were dropped.", c, n, counts.items)
    end
    if next(distrusted) then lines[#lines + 1] = "" end
    if #out == 0 then
        lines[#lines + 1] = "Nothing missing found."
    else
        lines[#lines + 1] = #out .. " thing(s) the game cannot find:"
        for i, e in ipairs(out) do
            lines[#lines + 1] = string.format("%3d. %-7s %s   on %s   - %s", i, e.kind, e.name, e.ownerName, table.concat(e.reasons, "; "))
            lines[#lines + 1] = "          id: " .. str(e.id)
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "To remove them: make a new save, then tick \"Delete what the scan found\" in MCM, or type"
        lines[#lines + 1] = "!wcc_delete_missing all   (or one number, e.g. !wcc_delete_missing 3) in the Script Extender console."
    end
    pcall(Ext.IO.SaveFile, FILE, table.concat(lines, "\n"))
    pcall(function() W.Log("SCAN", "missing-things scan: " .. #out .. " found, " .. counts.items .. " items checked") end)

    local box = { string.format("WHAT CAUSED THE CRASH - missing-things scan: checked %d items, %d statuses, %d passives.",
        counts.items, counts.statuses, counts.passives) }
    if counts.items == 0 then box[#box + 1] = "No items could be read - the item part of the scan did not work." end
    if #out == 0 then
        box[#box + 1] = "Nothing missing found."
    else
        box[#box + 1] = #out .. " thing(s) the game cannot find:"
        for i = 1, math.min(8, #out) do
            local e = out[i]
            box[#box + 1] = string.format("%d. %s %s on %s", i, e.kind, e.name, e.ownerName)
        end
        if #out > 8 then box[#box + 1] = "... and " .. (#out - 8) .. " more." end
        box[#box + 1] = "Make a new save, then tick \"Delete what the scan found\" in MCM to remove them."
    end
    box[#box + 1] = "Full list: Script Extender/WhatCausedTheCrash/missing_scan.txt"
    notify(table.concat(box, "\n"))
    return out, counts
end

local function delete(which)
    if not scannedAt then
        notify("WHAT CAUSED THE CRASH: run the missing-things scan first (nothing to delete yet).")
        return 0
    end
    local pick = {}
    which = str(which or "all")
    if which == "all" or which == "" or which == "nil" then
        for i = 1, #found do pick[#pick + 1] = i end
    else
        for n in which:gmatch("%d+") do pick[#pick + 1] = tonumber(n) end
    end
    local done, skipped, failed, log, record = 0, 0, 0, {}, {}
    for _, i in ipairs(pick) do
        local e = found[i]
        if e and not e.removed then
            if not stillMissing(e) then
                skipped = skipped + 1
                log[#log + 1] = string.format("%d. %s %s on %s - no longer missing, left alone", i, e.kind, e.name, e.ownerName)
            else
                local ok
                if e.kind == "item" then
                    ok = pcall(function() Osi.RequestDelete(e.id) end)
                elseif e.kind == "status" then
                    ok = pcall(function() Osi.RemoveStatus(e.owner, e.id) end)
                else
                    ok = pcall(function() Osi.RemovePassive(e.owner, e.id) end)
                end
                if ok then
                    e.removed = true
                    done = done + 1
                    log[#log + 1] = string.format("%d. %s %s on %s - removed", i, e.kind, e.name, e.ownerName)
                    record[#record + 1] = table.concat({
                        string.format("  %s  %s  on %s (%s)", e.kind:upper(), e.name, e.ownerName, str(e.owner)),
                        e.kind == "item" and string.format("      template: %s | stat entry: %s | stack: %s | item id: %s",
                            str(e.template), str(e.statsId), str(e.stack or 1), str(e.id))
                            or ("      id: " .. str(e.id)),
                        "      why it was flagged: " .. table.concat(e.reasons, "; "),
                    }, "\n")
                else
                    failed = failed + 1
                    log[#log + 1] = string.format("%d. %s %s on %s - the game refused", i, e.kind, e.name, e.ownerName)
                end
            end
        end
    end
    if #record > 0 then
        local when = q(function() return Ext.Timer.ClockTime() end) or "?"
        local prev = q(function() return Ext.IO.LoadFile(DELETED_LOG) end) or
            "WHAT CAUSED THE CRASH - EVERYTHING THE MISSING-THINGS SCAN DELETED (oldest first, never overwritten)\n" ..
            "The template and stat entry names usually show which mod an item came from.\n"
        pcall(Ext.IO.SaveFile, DELETED_LOG, prev .. "\n=== " .. str(when) .. " - " .. #record .. " removed ===\n"
            .. table.concat(record, "\n") .. "\n")
    end
    local old = q(function() return Ext.IO.LoadFile(FILE) end) or ""
    pcall(Ext.IO.SaveFile, FILE, old .. "\n\nDELETED:\n" .. table.concat(log, "\n"))
    pcall(function() W.Log("SCAN", string.format("missing-things delete: %d removed, %d left alone, %d refused", done, skipped, failed)) end)
    local box = { string.format("WHAT CAUSED THE CRASH - removed %d thing(s)%s%s.", done,
        skipped > 0 and (", " .. skipped .. " no longer missing") or "", failed > 0 and (", " .. failed .. " refused by the game") or "") }
    for i = 1, math.min(8, #log) do box[#box + 1] = log[i] end
    if done > 0 then box[#box + 1] = "Recorded in Script Extender/WhatCausedTheCrash/deleted_log.txt" end
    box[#box + 1] = "Save under a new name and test the dice roll."
    notify(table.concat(box, "\n"))
    return done
end

-- ==================== MCM / CONSOLE ====================

local lastTick = {}
local function nowMs() return tonumber(q(function() return Ext.Utils.MonotonicTime() end)) or 0 end
local function debounced(id)
    local t = nowMs()
    local tooSoon = lastTick[id] and (t - lastTick[id] < 15000)
    lastTick[id] = t
    return tooSoon
end

local subscribed = false
local function subscribe()
    if subscribed then return end
    subscribed = pcall(function()
        Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
            if not payload or payload.modUUID ~= ModuleUUID or payload.value ~= true then return end
            local id = payload.settingId
            if id ~= "ScanMissingNow" and id ~= "DeleteMissingNow" then return end
            pcall(function() Mods.BG3MCM.MCMAPI:SetSettingValue(id, false, ModuleUUID) end)
            if debounced(id) then return end
            local ok, err
            if id == "ScanMissingNow" then ok, err = pcall(scan, "MCM") else ok, err = pcall(delete, "all") end
            if not ok then Ext.Utils.PrintError("[WhatCausedTheCrash] " .. id .. " failed: " .. str(err)) end
        end)
    end)
end
pcall(function() Ext.Events.SessionLoaded:Subscribe(subscribe) end)
pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", subscribe)

Ext.RegisterConsoleCommand("wcc_scan_missing", function()
    local ok, err = pcall(scan, "console")
    if not ok then Ext.Utils.PrintError("[WhatCausedTheCrash] missing scan failed: " .. str(err)) end
end)
Ext.RegisterConsoleCommand("wcc_delete_missing", function(_, ...)
    local args = table.concat({ ... }, " ")
    local ok, err = pcall(delete, args ~= "" and args or "all")
    if not ok then Ext.Utils.PrintError("[WhatCausedTheCrash] missing delete failed: " .. str(err)) end
end)

W.MissingScan, W.MissingDelete, W.ItemMissingSpells = scan, delete, itemMissingSpells
