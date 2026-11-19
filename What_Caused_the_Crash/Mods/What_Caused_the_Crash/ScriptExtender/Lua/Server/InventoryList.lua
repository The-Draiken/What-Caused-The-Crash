-- Inventory list + stash: find which item in a character's inventory breaks the dice-roll screen.
--
--   !wcc_list_inventory            list the host character's inventory (MCM: "List my character's inventory")
--   !wcc_list_inventory <name>     list another party member's (part of the name is enough, e.g. karl)
--   !wcc_stash <what>              send items from the last listed inventory to the camp chest:
--        a word        every item whose name, template or stat entry contains it   (!wcc_stash dice)
--        numbers       items from the list                                         (!wcc_stash 3 7 12)
--        a range       items from the list                                         (!wcc_stash 1-40)
--        half1 / half2 the first or second half of the list                        (!wcc_stash half1)
-- Only top-level items are numbered and moved (a bag moves with everything in it). Items are sent to the camp chest,
-- never deleted. Every move is added to Script Extender/WhatCausedTheCrash/stash_log.txt.
-- Result: Script Extender/WhatCausedTheCrash/inventory_list.txt and the Script Extender console (no message boxes).
--
-- Finding the item: list, stash half1, try a dice roll. Crash -> the item is in half2 (reload, stash half2 instead and
-- keep halving the other way); no crash -> it is in half1 (take them back from the chest, list again, halve again).

local W = WCC
local FILE = "WhatCausedTheCrash/inventory_list.txt"
local STASH_LOG = "WhatCausedTheCrash/stash_log.txt"
local listed = { owner = nil, ownerName = nil, items = {} }   -- last list: top-level items

local function str(v) local ok, r = pcall(tostring, v) return ok and r or "?" end
local function q(fn, ...) local ok, a, b = pcall(fn, ...) if ok then return a, b end return nil, nil end
local function guidOf(uuid) return str(uuid):match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or str(uuid) end
local function say(text) Ext.Utils.Print("[WhatCausedTheCrash] " .. text) end

local modNames = {}
local function modName(id)
    id = str(id)
    if id == "" or id == "nil" then return nil end
    if modNames[id] == nil then
        local n = q(function() return Ext.Mod.GetMod(id).Info.Name end)
        modNames[id] = n and str(n) or id
    end
    return modNames[id]
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

-- everything worth knowing about one item
local function describe(entity, uuid)
    local d = { id = uuid }
    d.name = q(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end) or ""
    d.template = q(function() return Osi.GetTemplate(uuid) end) or ""
    d.statsId = q(function() return str(entity.Data.StatsId) end)
    if not d.statsId or d.statsId == "nil" or d.statsId == "" then d.statsId = q(function() return Osi.GetStatString(uuid) end) or "" end
    local _, stack = q(function() return Osi.GetStackAmount(uuid) end)
    d.stack = tonumber(stack) or 1
    d.equipped = q(function() return Osi.IsEquipped(uuid) end) == 1
    local stat = (d.statsId ~= "") and q(function() return Ext.Stats.Get(d.statsId, nil, false) end) or nil
    if stat then
        d.statMod = modName(q(function() return stat.ModId end))
        d.statType = q(function() return str(stat.ModifierList) end)
    end
    local tid = guidOf(d.template)
    local tpl = q(function() return Ext.Template.GetTemplate(tid) end) or q(function() return Ext.Template.GetRootTemplate(tid) end)
    d.templateFound = tpl ~= nil
    if tpl then d.templateFile = q(function() return str(tpl.FileName) end) end
    local text = (d.name .. " " .. d.template .. " " .. d.statsId):lower()
    d.dice = text:find("dice", 1, true) ~= nil or text:find("d20", 1, true) ~= nil
    d.notFound = (not d.templateFound) or (d.statsId ~= "" and not stat) or d.name == "" or d.name:lower():find("not found", 1, true) ~= nil
    d.missingSpells = (d.templateFound and W.ItemMissingSpells) and (q(W.ItemMissingSpells, d.template) or {}) or {}
    return d
end

local function walk(entity, depth, out, parent)
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
                    local d = describe(item, iuuid)
                    d.depth, d.parent = depth, parent
                    out[#out + 1] = d
                    walk(item, depth + 1, out, d)
                end
            end
        end
    end
end

local function findMember(word)
    local host = q(function() return guidOf(Osi.GetHostCharacter()) end)
    if not word or word == "" then return host end
    word = word:lower()
    for _, uuid in ipairs(party()) do
        if charName(uuid):lower():find(word, 1, true) or uuid:find(word, 1, true) then return uuid end
    end
    return nil
end

local function line(d, num)
    local flags = {}
    if d.equipped then flags[#flags + 1] = "EQUIPPED" end
    if d.dice then flags[#flags + 1] = "DICE" end
    if d.notFound then flags[#flags + 1] = "NOT FOUND" end
    if #d.missingSpells > 0 then flags[#flags + 1] = "MISSING SPELL: " .. table.concat(d.missingSpells, ", ") end
    return string.format("%s%s %s%s  | template: %s | stats: %s%s%s%s",
        string.rep("      ", d.depth), num and string.format("%3d.", num) or "    -", d.name ~= "" and d.name or "(no name)",
        d.stack > 1 and (" x" .. d.stack) or "", d.template ~= "" and d.template or "(none)", d.statsId ~= "" and d.statsId or "(none)",
        d.statMod and (" | stat from: " .. d.statMod) or "", d.templateFile and (" | template file: " .. d.templateFile) or "",
        #flags > 0 and ("   [" .. table.concat(flags, ", ") .. "]") or "")
end

local function list(who)
    local owner = findMember(who)
    if not owner then say("no party member matches '" .. str(who) .. "'") return end
    local entity = q(function() return Ext.Entity.Get(owner) end)
    local all = {}
    if entity then walk(entity, 0, all, nil) end
    listed = { owner = owner, ownerName = charName(owner), items = {} }
    local lines = { "WHAT CAUSED THE CRASH - INVENTORY OF " .. listed.ownerName .. " (" .. owner .. ")",
        "Numbered = top-level items (what !wcc_stash moves). Indented = inside the bag above it.",
        "Flags: EQUIPPED, DICE (dice-related name/template/stat), NOT FOUND (template, stat entry or name missing),",
        "       MISSING SPELL (casts a spell that does not exist - this broke the dice-roll screen before).", "" }
    local dice, nf, ms, top = 0, 0, 0, 0
    for _, d in ipairs(all) do
        if d.depth == 0 then
            top = top + 1
            listed.items[top] = d
            lines[#lines + 1] = line(d, top)
        else
            lines[#lines + 1] = line(d, nil)
        end
        if d.dice then dice = dice + 1 end
        if d.notFound then nf = nf + 1 end
        if #d.missingSpells > 0 then ms = ms + 1 end
    end
    if #all == 0 then lines[#lines + 1] = "No items could be read (empty inventory, or the inventory reading failed)." end
    table.insert(lines, 5, string.format("%d items (%d top-level), %d dice-related, %d with something not found, %d casting a missing spell.", #all, top, dice, nf, ms))
    pcall(Ext.IO.SaveFile, FILE, table.concat(lines, "\n"))
    say(string.format("inventory of %s: %d items (%d top-level), %d dice-related, %d not found, %d casting a missing spell. List: Script Extender/WhatCausedTheCrash/inventory_list.txt",
        listed.ownerName, #all, top, dice, nf, ms))
    pcall(function() W.Log("SCAN", "inventory list of " .. listed.ownerName .. ": " .. #all .. " items") end)
    return all
end

local function stash(arg)
    if not listed.owner or #listed.items == 0 then say("list an inventory first: !wcc_list_inventory") return 0 end
    arg = str(arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local pick = {}
    local n = #listed.items
    local half = math.ceil(n / 2)
    if arg == "half1" then for i = 1, half do pick[#pick + 1] = i end
    elseif arg == "half2" then for i = half + 1, n do pick[#pick + 1] = i end
    elseif arg:match("^%d+%s*%-%s*%d+$") then
        local a, b = arg:match("^(%d+)%s*%-%s*(%d+)$")
        for i = tonumber(a), math.min(n, tonumber(b)) do pick[#pick + 1] = i end
    elseif arg:match("^[%d%s,]+$") then
        for x in arg:gmatch("%d+") do pick[#pick + 1] = tonumber(x) end
    elseif arg ~= "" then
        local word = arg:lower()
        for i, d in ipairs(listed.items) do
            if (d.name .. " " .. d.template .. " " .. d.statsId):lower():find(word, 1, true) then pick[#pick + 1] = i end
        end
    end
    if #pick == 0 then say("nothing matched '" .. arg .. "' (use a word, numbers, a range like 1-40, half1 or half2)") return 0 end
    local host = q(function() return Osi.GetHostCharacter() end) or listed.owner
    local moved, failed, log = 0, 0, {}
    for _, i in ipairs(pick) do
        local d = listed.items[i]
        if d and not d.stashed then
            if pcall(function() Osi.SendToCampChest(d.id, host) end) then
                d.stashed = true
                moved = moved + 1
                log[#log + 1] = "  " .. line(d, i):gsub("^%s+", "")
            else
                failed = failed + 1
            end
        end
    end
    local when = q(function() return Ext.Timer.ClockTime() end) or "?"
    local prev = q(function() return Ext.IO.LoadFile(STASH_LOG) end) or
        "WHAT CAUSED THE CRASH - ITEMS SENT TO THE CAMP CHEST BY !wcc_stash (oldest first, never overwritten)\n"
    pcall(Ext.IO.SaveFile, STASH_LOG, prev .. string.format("\n=== %s - from %s - '%s' - %d sent to camp ===\n", str(when),
        listed.ownerName, arg, moved) .. table.concat(log, "\n") .. "\n")
    say(string.format("sent %d item(s) from %s to the camp chest%s. Logged in stash_log.txt. Now try the dice roll.",
        moved, listed.ownerName, failed > 0 and (" (" .. failed .. " refused)") or ""))
    return moved
end

-- MCM: "List my character's inventory" (unticks itself)
local subscribed, lastTick = false, -1e9
local function subscribe()
    if subscribed then return end
    subscribed = pcall(function()
        Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
            if payload and payload.modUUID == ModuleUUID and payload.settingId == "ListInventoryNow" and payload.value == true then
                pcall(function() Mods.BG3MCM.MCMAPI:SetSettingValue("ListInventoryNow", false, ModuleUUID) end)
                local t = tonumber(q(function() return Ext.Utils.MonotonicTime() end)) or 0
                local tooSoon = t - lastTick < 15000
                lastTick = t
                if tooSoon then return end
                local ok, err = pcall(list, nil)
                if not ok then Ext.Utils.PrintError("[WhatCausedTheCrash] inventory list failed: " .. str(err)) end
            end
        end)
    end)
end
pcall(function() Ext.Events.SessionLoaded:Subscribe(subscribe) end)
pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", subscribe)

Ext.RegisterConsoleCommand("wcc_list_inventory", function(_, ...)
    local ok, err = pcall(list, table.concat({ ... }, " "))
    if not ok then Ext.Utils.PrintError("[WhatCausedTheCrash] inventory list failed: " .. str(err)) end
end)
Ext.RegisterConsoleCommand("wcc_stash", function(_, ...)
    local ok, err = pcall(stash, table.concat({ ... }, " "))
    if not ok then Ext.Utils.PrintError("[WhatCausedTheCrash] stash failed: " .. str(err)) end
end)

W.InventoryList, W.InventoryStash = list, stash
