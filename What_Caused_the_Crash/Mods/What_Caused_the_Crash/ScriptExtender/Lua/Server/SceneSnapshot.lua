-- Scene snapshot: copy the end of a fight from a save that cannot be played into an earlier save of the same place.
--
-- Captures are kept as a list (Script Extender/WhatCausedTheCrash/scenes/), each with a name, level, time and kind, and
-- managed from the "Scene snapshots" tab in the MCM window: recreate everything, recreate only the environment, rename,
-- delete, or select the one the console command and the MCM checkbox use.
--
-- Capture: with "Capture the scene on load" on in MCM, the first save loaded writes
--   Script Extender/WhatCausedTheCrash/scene_snapshot.json right after the level starts (before anything that could
--   crash later in the load). An existing snapshot is never overwritten automatically, so loading the earlier save with
--   the option still on cannot replace it. "!wcc_scene_capture" in the console captures now and overwrites.
-- Apply:   on the earlier save, the MCM button "Recreate the captured scene" (or "!wcc_scene_apply") puts every captured
--   character back where it stood, with the same HP, statuses and life/death, gives the party the same inventory,
--   equipment, experience and approval, the same spell slots and class resources left, the same spells and item
--   powers on cooldown (once per short/long rest), and the same number of short rests left, and kills whoever was
--   dead so the game runs their deaths normally (a dead party member keeps the captured gear and death markers).
--   Summons are cast again by their owners at the captured spot and given their captured HP and statuses.
-- Whole level (MCM "Also capture the whole level", off by default because it reads every item in the level):
--   every dead character anywhere in the level is captured too (and killed / moved to where its body lay on apply),
--   and every item's owner, so items that were destroyed or used up are deleted and items that changed hands
--   (picked up, looted, dropped) are moved to where they ended up. Living characters outside the room are untouched.
-- Pause first (MCM "Pause the game before capturing", off by default): the game is paused the moment the level
--   starts by giving the party the engine's Pause component (what pause mods use), then the capture runs in the same
--   call, and the game stays paused so you can quit. "!wcc_scene_unpause" resumes. Untested against a crashing save:
--   the load can still freeze before the pause takes effect, which is why it is an option.
-- Not copied: story flags, journal and dialogue history, level-up choices, other mods' saved variables.

local W = WCC
local captureLevel, applyLevelDead, applyLevelItems, findSummonSpell, existingOfTemplate, newSummonOf
local captureEnvironment, applyEnvironment
local LEGACY_FILE = "WhatCausedTheCrash/scene_snapshot.json"  -- single snapshot of the first version, imported once
local DIR = "WhatCausedTheCrash/scenes/"
local INDEX = DIR .. "index.json"
local RADIUS = 60
-- statuses that only mean something during a turn; a save made mid-turn can carry them out of combat
local TURN_ONLY = { DOWNED5E_ACTIVE_TURN = true, D5E_USED_BACTION = true, D5E_USED_ACTION = true, RAW_CURRENT_TURN = true }
local SLOTS = { "Helmet", "Breast", "Cloak", "Melee Main Weapon", "Melee Offhand Weapon", "Ranged Main Weapon",
    "Ranged Offhand Weapon", "Ring", "Ring2", "Underwear", "Boots", "Gloves", "Amulet", "Wings", "Horns", "Overhead",
    "MusicalInstrument", "VanityBody", "VanityBoots" }

local function str(v) local ok, r = pcall(tostring, v) return ok and r or "?" end
local function q(fn, ...) local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end return nil, nil, nil end
local function flag(fn, ...) local ok, v = pcall(fn, ...) return ok and v == 1 end
local function levelOf(r) local ok, v = pcall(function() return r.Level end) return ok and tonumber(v) or 0 end
-- Osi.Die takes the death type as a number (Ext.Enums.StatsDeathType: 3 = DoT); a name such as "DoT" is rejected
local DEATH_DOT = 3
local function kill(uuid, source, treasure)
    local ok, err = pcall(function() Osi.Die(uuid, DEATH_DOT, source, treasure, 1, 0) end)
    return ok, err
end

local function say(kind, msg) W.Log(kind, msg) Ext.Utils.Print("[WhatCausedTheCrash] " .. msg) end

local function guidOf(uuid) return str(uuid):match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or str(uuid) end
local function host() return q(function() return Osi.GetHostCharacter() end) end

local function partySet()
    local set = {}
    local ok, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
    if ok and type(rows) == "table" then
        for _, r in ipairs(rows) do set[guidOf(r[1])] = true end
    end
    return set
end

-- nil when MCM cannot be read, so callers can tell "off" from "unknown" (options that default to on use ~= false)
local function mcm(id)
    local ok, v = pcall(function() return Mods.BG3MCM.MCMAPI:GetSettingValue(id, ModuleUUID) end)
    if ok then return v end
    return nil
end

-- ==================== STORAGE: A LIST OF CAPTURES ====================

local function clockText()
    local ok, t = pcall(function() return Ext.Timer.ClockTime() end)
    return ok and t and str(t) or "time unknown"
end

local idCounter = 0
local function newId()
    idCounter = idCounter + 1
    local ok, e = pcall(function() return Ext.Timer.ClockEpoch() end)
    if ok and tonumber(e) then return string.format("scene_%d", e) end
    local okM, m = pcall(function() return Ext.Utils.MonotonicTime() end)
    return string.format("scene_%d_%d", okM and math.floor(tonumber(m) or 0) or 0, idCounter)
end

local saveIndex
local function loadIndex()
    local idx
    local raw = Ext.IO.LoadFile(INDEX)
    if raw and raw ~= "" then
        local ok, t = pcall(Ext.Json.Parse, raw)
        if ok and type(t) == "table" then idx = t end
    end
    idx = idx or { scenes = {} }
    idx.scenes = idx.scenes or {}
    -- the single snapshot of the first version becomes the first entry of the list
    if not idx.legacyImported then
        idx.legacyImported = true
        local old = Ext.IO.LoadFile(LEGACY_FILE)
        if old and old ~= "" then
            local ok, sc = pcall(Ext.Json.Parse, old)
            if ok and type(sc) == "table" then
                table.insert(idx.scenes, 1, { id = "scene_imported", file = LEGACY_FILE, name = "Imported snapshot (first version)",
                    time = "before the list existed", level = sc.level, kind = sc.levelItems and "60 m room + whole level" or "60 m room",
                    characters = #(sc.characters or {}), objects = 0 })
                idx.selected = idx.selected or "scene_imported"
            end
        end
        saveIndex(idx)
    end
    return idx
end

function saveIndex(idx)
    pcall(Ext.IO.SaveFile, INDEX, Ext.Json.Stringify(idx))
    pcall(function() Ext.Net.BroadcastMessage("WCC_SceneList", "changed") end)
end

-- id given: that capture; otherwise the selected one; otherwise the newest
local function findEntry(idx, id)
    if id then
        for i, e in ipairs(idx.scenes) do
            if e.id == id or tostring(i) == tostring(id) then return e end
        end
        return nil
    end
    if idx.selected then
        for _, e in ipairs(idx.scenes) do if e.id == idx.selected then return e end end
    end
    return idx.scenes[#idx.scenes]
end

-- ==================== CAPTURE ====================

local function statusList(ent, uuid)
    local out = {}
    local ok, list = pcall(function() return ent.StatusContainer.Statuses end)
    if not ok or not list then return out end
    for _, sid in pairs(list) do
        local id = str(sid)
        if not TURN_ONLY[id] then
            out[#out + 1] = { id = id, turns = q(function() return Osi.GetStatusTurns(uuid, id) end) or -1 }
        end
    end
    return out
end

local function addItems(ent, counts, depth)
    if depth > 4 then return end
    local ok, invs = pcall(function() return ent.InventoryOwner.Inventories end)
    if not ok or not invs then return end
    for _, inv in pairs(invs) do
        local okI, items = pcall(function() return inv.InventoryContainer.Items end)
        if okI and items then
            for _, slot in pairs(items) do
                local item = slot.Item
                local okU, iuuid = pcall(function() return item.Uuid.EntityUuid end)
                if okU and iuuid then
                    local tpl = q(function() return Osi.GetTemplate(iuuid) end)
                    if tpl then
                        local _, total = q(function() return Osi.GetStackAmount(iuuid) end)
                        counts[tpl] = (counts[tpl] or 0) + math.max(1, tonumber(total) or 1)
                    end
                    addItems(item, counts, depth + 1)
                end
            end
        end
    end
end

local function captureCharacter(ent, uuid, party)
    local x, y, z = q(function() return Osi.GetPosition(uuid) end)
    if type(x) ~= "number" then return nil end
    local _, ry = q(function() return Osi.GetRotation(uuid) end)
    local c = {
        uuid = uuid,
        label = W.Label(uuid),
        template = q(function() return Osi.GetTemplate(uuid) end),
        x = x, y = y, z = z, rot = ry,
        dead = flag(function() return Osi.IsDead(uuid) end),
        hp = q(function() return Osi.GetHitpoints(uuid) end),
        maxhp = q(function() return Osi.GetMaxHitpoints(uuid) end),
        summon = flag(function() return Osi.IsSummon(uuid) end),
        party = party[uuid] == true or flag(function() return Osi.IsPartyMember(uuid, 1) end),
        statuses = statusList(ent, uuid),
    }
    if c.summon then
        -- who summoned it and with what, so it can be summoned again: owner, and the summon/lifetime components raw
        c.owner = q(function() return Osi.CharacterGetOwner(uuid) end)
        c.summonData = q(function() return Ext.Types.Serialize(ent.IsSummon) end)
        c.lifetime = q(function() return Ext.Types.Serialize(ent.SummonLifetime) end)
        c.statusTime = {}
        for _, st in ipairs(c.statuses) do
            c.statusTime[st.id] = q(function() return Osi.GetStatusCurrentLifetime(uuid, st.id) end)
        end
    end
    if c.party and not c.summon then
        c.items = {}
        addItems(ent, c.items, 0)
        c.equipped = {}
        for _, s in ipairs(SLOTS) do
            local item = q(function() return Osi.GetEquippedItem(uuid, s) end)
            if item then c.equipped[s] = q(function() return Osi.GetTemplate(item) end) end
        end
        c.xp = q(function() return ent.Experience.TotalExperience end)
        -- spell slots, ki, rage, channel divinity, hit dice... and once-per-rest cooldowns, as whole components
        c.resources = q(function() return Ext.Types.Serialize(ent.ActionResources) end)
        c.cooldowns = q(function() return Ext.Types.Serialize(ent.SpellBookCooldowns) end)
        c.resAmounts = {}
        pcall(function()
            for key, list in pairs(ent.ActionResources.Resources) do
                for _, r in pairs(list) do
                    c.resAmounts[#c.resAmounts + 1] = { key = str(key), level = levelOf(r), amount = r.Amount }
                end
            end
        end)
    end
    return c
end

-- Whole-level part: dead characters outside the room, and every item with the inventory that holds it
-- (none = lying in the world, with its position).
function captureLevel(chars, room)
    local inRoom = {}
    for _, c in ipairs(room) do inRoom[c.uuid] = true end
    local dead = {}
    for _, ent in ipairs(chars) do
        local okU, uuid = pcall(function() return ent.Uuid.EntityUuid end)
        if okU and uuid and not inRoom[uuid] and flag(function() return Osi.IsDead(uuid) end) then
            local x, y, z = q(function() return Osi.GetPosition(uuid) end)
            if type(x) == "number" then
                dead[#dead + 1] = { uuid = uuid, label = W.Label(uuid), x = x, y = y, z = z, dead = true,
                    template = q(function() return Osi.GetTemplate(uuid) end), summon = flag(function() return Osi.IsSummon(uuid) end) }
            end
        end
    end
    local items = {}
    local ok, ents = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerItem") end)
    if ok and type(ents) == "table" then
        for _, ent in ipairs(ents) do
            local okU, uuid = pcall(function() return ent.Uuid.EntityUuid end)
            if okU and uuid then
                local holder = q(function() return Osi.GetDirectInventoryOwner(uuid) end)
                local rec = { t = q(function() return Osi.GetTemplate(uuid) end) }
                if holder then
                    rec.h = guidOf(holder)
                else
                    local x, y, z = q(function() return Osi.GetPosition(uuid) end)
                    if type(x) == "number" then rec.p = { x, y, z } end
                end
                items[uuid] = rec
            end
        end
    end
    return dead, items
end

local JSON_OPTS = { Beautify = false, StringifyInternalTypes = true, IterateUserdata = true, AvoidRecursion = true, MaxDepth = 64 }
local RAW_FIELDS = { "summonData", "lifetime", "cooldowns", "resources" }

local function encode(scene)
    local ok, text = pcall(Ext.Json.Stringify, scene, JSON_OPTS)
    if ok and type(text) == "string" then return text, nil end
    local firstErr = text
    -- find the raw game components that cannot be written and drop only those
    local dropped = {}
    for _, field in ipairs(RAW_FIELDS) do
        local n = 0
        for _, c in ipairs(scene.characters) do
            if c[field] ~= nil and not pcall(Ext.Json.Stringify, c[field], JSON_OPTS) then
                c[field] = nil
                n = n + 1
            end
        end
        if n > 0 then dropped[#dropped + 1] = field .. " (" .. n .. ")" end
    end
    ok, text = pcall(Ext.Json.Stringify, scene, JSON_OPTS)
    if ok and type(text) == "string" then
        return text, "could not store " .. table.concat(dropped, ", ") .. " (" .. str(firstErr) .. ")"
    end
    return nil, "could not encode the snapshot: " .. str(text)
end

-- Environment around the party: every object lying in the world within the radius (doors, chandeliers, braziers,
-- crates...) with whether it is destroyed, open, locked, and its statuses (burning, wet...), plus the ground surface
-- (fire, oil, water...) under each captured character and object, and each object's hit points (a scorched door).
function captureEnvironment(cx, cy, cz, chars, withSurfaces)
    local env = { objects = {}, surfaces = {} }
    local ok, ents = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerItem") end)
    if not ok or type(ents) ~= "table" then return env end
    local seenSurface = {}
    local function addSurface(uuid, x, y, z)
        if not withSurfaces or type(x) ~= "number" then return end
        local sfc = q(function() return Osi.GetSurfaceGroundAt(uuid) end)
        if sfc and sfc ~= "" and not str(sfc):find("None", 1, true) then
            local key = string.format("%d|%d|%s", math.floor(x), math.floor(z), str(sfc))
            if not seenSurface[key] then
                seenSurface[key] = true
                env.surfaces[#env.surfaces + 1] = { x = x, y = y, z = z, type = str(sfc) }
            end
        end
    end
    for _, ent in ipairs(ents) do
        local okU, uuid = pcall(function() return ent.Uuid.EntityUuid end)
        if okU and uuid and not q(function() return Osi.GetDirectInventoryOwner(uuid) end) then
            local x, y, z = q(function() return Osi.GetPosition(uuid) end)
            if type(x) == "number" and (q(function() return Osi.GetDistanceToPosition(uuid, cx, cy, cz) end) or 1e9) <= RADIUS then
                local o = { uuid = uuid, t = q(function() return Osi.GetTemplate(uuid) end), x = x, y = y, z = z,
                    destroyed = flag(function() return Osi.IsDestroyed(uuid) end),
                    hp = q(function() return Osi.GetHitpoints(uuid) end), maxhp = q(function() return Osi.GetMaxHitpoints(uuid) end),
                    opened = q(function() return Osi.IsOpened(uuid) end), locked = q(function() return Osi.IsLocked(uuid) end),
                    statuses = {} }
                pcall(function()
                    for _, sid in pairs(ent.StatusContainer.Statuses) do
                        local id = str(sid)
                        o.statuses[#o.statuses + 1] = { id = id, turns = q(function() return Osi.GetStatusTurns(uuid, id) end) or -1 }
                    end
                end)
                env.objects[#env.objects + 1] = o
                addSurface(uuid, x, y, z)
            end
        end
    end
    for _, c in ipairs(chars) do addSurface(c.uuid, c.x, c.y, c.z) end
    -- every item that still exists anywhere in the level (in inventories too): an object near the party in the earlier
    -- save that is not in this list no longer existed in the captured save (a cut rope, a smashed crate)
    env.present = {}
    for _, ent in ipairs(ents) do
        local okU, uuid = pcall(function() return ent.Uuid.EntityUuid end)
        if okU and uuid then env.present[#env.present + 1] = uuid end
    end
    -- items sent to camp: in the camp chest (DB_Camp_UserCampChest). Its contents may not be loaded away from camp;
    -- readable says whether they could be read, so an item that is gone from here is never destroyed when it might
    -- just be in camp
    env.camp = { chests = {}, items = {}, readable = false }
    local function collect(holder, depth)
        if depth > 4 then return end
        pcall(function()
            for _, inv in pairs(holder.InventoryOwner.Inventories) do
                for _, slot in pairs(inv.InventoryContainer.Items) do
                    local item = slot.Item
                    local u = item.Uuid.EntityUuid
                    env.camp.items[#env.camp.items + 1] = u
                    collect(item, depth + 1)
                end
            end
        end)
    end
    pcall(function()
        for _, row in ipairs(Osi.DB_Camp_UserCampChest:Get(nil, nil)) do
            local chest = guidOf(row[2])
            env.camp.chests[#env.camp.chests + 1] = chest
            local okE, cent = pcall(Ext.Entity.Get, chest)
            if okE and cent then
                local okI = pcall(function() return cent.InventoryOwner.Inventories end)
                if okI then env.camp.readable = true end
                collect(cent, 0)
            end
        end
    end)
    for _, u in ipairs(env.camp.items) do env.present[#env.present + 1] = u end
    return env
end

local function capture(why)
    local h = host()
    if not h then say("SCENE", "capture failed: no host character") return false end
    local cx, cy, cz = q(function() return Osi.GetPosition(h) end)
    local party = partySet()
    local scene = { version = 1, why = why, level = q(function() return Osi.GetRegion(h) end), host = str(h),
        center = { cx, cy, cz }, radius = RADIUS, characters = {}, approval = {} }
    local ok, ents = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter") end)
    if not ok or type(ents) ~= "table" then say("SCENE", "capture failed: entity list unavailable") return false end
    local failed = 0
    for _, ent in ipairs(ents) do
        local okU, uuid = pcall(function() return ent.Uuid.EntityUuid end)
        if okU and uuid then
            local inRange = party[uuid] or (q(function() return Osi.GetDistanceToPosition(uuid, cx, cy, cz) end) or 1e9) <= RADIUS
            if inRange then
                local okC, c = pcall(captureCharacter, ent, uuid, party)
                if okC and c then
                    scene.characters[#scene.characters + 1] = c
                elseif not okC then
                    failed = failed + 1
                    if failed <= 5 then W.Log("SCENE", "could not capture " .. str(uuid) .. ": " .. str(c)) end
                end
            end
        end
    end
    scene.shortRests = q(function() return Osi.PartyGetActionResourceValue(h, "ShortRestPoint") end)
    for _, c in ipairs(scene.characters) do
        if c.party and c.uuid ~= guidOf(h) then
            local r = q(function() return Osi.GetApprovalRating(c.uuid, h) end)
            if r then scene.approval[#scene.approval + 1] = { owner = c.uuid, rating = r } end
        end
    end
    local extra = ""
    if mcm("CaptureWholeLevel") then
        local dead, items = captureLevel(ents, scene.characters)
        scene.levelDead, scene.levelItems = dead, items
        local n = 0
        for _ in pairs(items) do n = n + 1 end
        extra = string.format(", plus %d dead character(s) and %d item(s) level-wide", #dead, n)
    end
    local objects = 0
    if mcm("CaptureEnvironment") ~= false then
        scene.environment = captureEnvironment(cx, cy, cz, scene.characters, mcm("CaptureSurfaces") ~= false)
        objects = #scene.environment.objects
        extra = extra .. string.format(", %d object(s) and %d ground surface(s)", objects, #scene.environment.surfaces)
    end
    local id = newId()
    local idx = loadIndex()
    for _, e in ipairs(idx.scenes) do if e.id == id then id = id .. "_" .. (#idx.scenes + 1) end end
    local file = DIR .. id .. ".json"
    local kind = (scene.levelItems and "60 m room + whole level" or "60 m room") .. (scene.environment and " + environment" or "")
    scene.name = string.format("%s - %s - %s", str(scene.level), clockText(), kind)
    local text, warn = encode(scene)
    local okS, err = false, warn
    if text then okS, err = pcall(Ext.IO.SaveFile, file, text) end
    if okS then
        idx.scenes[#idx.scenes + 1] = { id = id, file = file, name = scene.name, time = clockText(), level = scene.level, kind = kind,
            characters = #scene.characters, objects = objects }
        idx.selected = id
        saveIndex(idx)
    end
    if warn and text then W.Log("SCENE", "warning: " .. warn) end
    if failed > 0 then W.Log("SCENE", "warning: " .. failed .. " character(s) could not be captured") end
    say("SCENE", string.format("captured %d character(s) within %dm of the host in %s%s (%s) as \"%s\"%s", #scene.characters, RADIUS,
        str(scene.level), extra, why, str(scene.name), okS and "" or (" — WRITE FAILED: " .. str(err))))
    W.FlushNow()
    return okS
end

-- ==================== APPLY ====================

local function currentStatuses(uuid)
    local set = {}
    local ok, list = pcall(function() return Ext.Entity.Get(uuid).StatusContainer.Statuses end)
    if ok and list then for _, sid in pairs(list) do set[str(sid)] = true end end
    return set
end

local function currentItems(uuid)
    local counts = {}
    local ok, ent = pcall(Ext.Entity.Get, uuid)
    if ok and ent then addItems(ent, counts, 0) end
    return counts
end

local function setHp(uuid, hp)
    if type(hp) ~= "number" then return end
    pcall(function() Osi.SetHitpoints(uuid, hp, "") end)
    pcall(function()
        local ent = Ext.Entity.Get(uuid)
        ent.Health.Hp = hp
        ent:Replicate("Health")
    end)
end

local function applyStatuses(c, report)
    local want = {}
    for _, s in ipairs(c.statuses or {}) do want[s.id] = s end
    local have = currentStatuses(c.uuid)
    for id, s in pairs(want) do
        if not have[id] then
            local turns = tonumber(s.turns) or -1
            local dur = turns > 0 and turns * 6.0 or -1.0
            if turns ~= 0 and pcall(function() Osi.ApplyStatus(c.uuid, id, dur, 1, c.uuid) end) then report.statusAdded = report.statusAdded + 1 end
        end
    end
    for id in pairs(have) do
        if not want[id] then
            if pcall(function() Osi.RemoveStatus(c.uuid, id, "00000000-0000-0000-0000-000000000000") end) then
                report.statusRemoved = report.statusRemoved + 1
            end
        end
    end
end

local function applyInventory(c, report)
    local have = currentItems(c.uuid)
    for tpl, n in pairs(c.items or {}) do
        local diff = n - (have[tpl] or 0)
        if diff > 0 and pcall(function() Osi.TemplateAddTo(tpl, c.uuid, diff, 0) end) then report.itemsAdded = report.itemsAdded + diff end
    end
    for tpl, n in pairs(have) do
        local diff = n - ((c.items or {})[tpl] or 0)
        if diff > 0 and pcall(function() Osi.TemplateRemoveFrom(tpl, c.uuid, diff) end) then report.itemsRemoved = report.itemsRemoved + diff end
    end
end

-- Spell slots and class resources, then once-per-rest cooldowns: write the captured components back whole, then check
-- each resource amount and set any that did not take directly.
local function applyResources(c, report)
    local okE, ent = pcall(Ext.Entity.Get, c.uuid)
    if not okE or not ent then return end
    if c.resources and pcall(function() Ext.Types.Unserialize(ent.ActionResources, c.resources) end) then
        pcall(function() ent:Replicate("ActionResources") end)
    end
    local fixed = 0
    pcall(function()
        for _, want in ipairs(c.resAmounts or {}) do
            for key, list in pairs(ent.ActionResources.Resources) do
                if str(key) == want.key then
                    for _, r in pairs(list) do
                        if levelOf(r) == want.level and r.Amount ~= want.amount then
                            r.Amount = want.amount
                            fixed = fixed + 1
                        end
                    end
                end
            end
        end
    end)
    if fixed > 0 then pcall(function() ent:Replicate("ActionResources") end) end
    local mismatched = 0
    pcall(function()
        for _, want in ipairs(c.resAmounts or {}) do
            for key, list in pairs(ent.ActionResources.Resources) do
                if str(key) == want.key then
                    for _, r in pairs(list) do
                        if levelOf(r) == want.level and r.Amount ~= want.amount then mismatched = mismatched + 1 end
                    end
                end
            end
        end
    end)
    report.resources = report.resources + #(c.resAmounts or {}) - mismatched
    if mismatched > 0 then report.notes[#report.notes + 1] = c.label .. ": " .. mismatched .. " resource amount(s) did not take" end
    if c.cooldowns then
        if pcall(function() Ext.Types.Unserialize(ent.SpellBookCooldowns, c.cooldowns) end) then
            pcall(function() ent:Replicate("SpellBookCooldowns") end)
            report.cooldowns = report.cooldowns + 1
        else
            report.notes[#report.notes + 1] = c.label .. ": spell cooldowns could not be written"
        end
    end
end

local function applyEquipment(c, report)
    for slot, tpl in pairs(c.equipped or {}) do
        local cur = q(function() return Osi.GetEquippedItem(c.uuid, slot) end)
        local curTpl = cur and q(function() return Osi.GetTemplate(cur) end)
        if curTpl ~= tpl then
            local item = q(function() return Osi.GetItemByTemplateInInventory(tpl, c.uuid) end)
            if item and pcall(function() Osi.Equip(c.uuid, item, 1, 0, 0) end) then report.equipped = report.equipped + 1
            else report.notes[#report.notes + 1] = c.label .. ": could not equip " .. str(tpl) .. " in " .. slot end
        end
    end
end

local function moveDistance(uuid, x, y, z)
    return q(function() return Osi.GetDistanceToPosition(uuid, x, y, z) end) or 0
end

-- Dead characters outside the room: kill the ones alive in this save, move every body to where it lay.
-- Living characters outside the room are never touched.
function applyLevelDead(list, h, report)
    for _, c in ipairs(list) do
        local exists = flag(function() return Osi.Exists(c.uuid) end)
        if not exists and not c.summon and c.template then
            local new = q(function() return Osi.CreateAt(c.template, c.x, c.y, c.z, 0, 0, "") end)
            if new then c.uuid = guidOf(new) exists = true report.created = report.created + 1 end
        end
        if exists then
            local deadNow = flag(function() return Osi.IsDead(c.uuid) end)
            if moveDistance(c.uuid, c.x, c.y, c.z) > 1.0 and pcall(function() Osi.TeleportToPosition(c.uuid, c.x, c.y, c.z, "", 0, 0, 0, 0, 1) end) then
                report.levelBodiesMoved = report.levelBodiesMoved + 1
            end
            if not deadNow then
                local okK, errK = kill(c.uuid, h, 1)
                if okK then report.levelKilled = report.levelKilled + 1
                else report.notes[#report.notes + 1] = c.label .. ": could not be killed (" .. str(errK) .. ")" end
            end
        end
    end
end

-- Items: one that no longer exists in the captured save is deleted; one held by a different inventory, or lying
-- somewhere else, is moved to where it ended up. Items that only exist in the captured save (new loot) are counted.
function applyLevelItems(items, report)
    local ok, ents = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerItem") end)
    if not ok or type(ents) ~= "table" then report.notes[#report.notes + 1] = "level items: entity list unavailable" return end
    local seen = {}
    for _, ent in ipairs(ents) do
        local okU, uuid = pcall(function() return ent.Uuid.EntityUuid end)
        if okU and uuid then
            seen[uuid] = true
            local want = items[uuid]
            if not want then
                if pcall(function() Osi.RequestDelete(uuid) end) then report.levelDeleted = report.levelDeleted + 1 end
            else
                local holder = q(function() return Osi.GetDirectInventoryOwner(uuid) end)
                holder = holder and guidOf(holder) or nil
                if want.h then
                    if holder ~= want.h and flag(function() return Osi.Exists(want.h) end)
                        and pcall(function() Osi.ToInventory(uuid, want.h, -1, 0, 0) end) then
                        report.levelMoved = report.levelMoved + 1
                    end
                elseif want.p then
                    if holder or moveDistance(uuid, want.p[1], want.p[2], want.p[3]) > 0.5 then
                        if pcall(function() Osi.TeleportToPosition(uuid, want.p[1], want.p[2], want.p[3], "", 0, 0, 0, 0, 0) end) then
                            report.levelMoved = report.levelMoved + 1
                        end
                    end
                end
            end
        end
    end
    for uuid in pairs(items) do
        if not seen[uuid] then report.levelNew = report.levelNew + 1 end
    end
end

-- ==================== SUMMONS ====================
-- A summon cannot be copied: a creature made from its template would not belong to its caster. Its owner casts the
-- spell that summoned it again instead. The spell is the one whose properties summon this template: first searched
-- in the owner's spell book, then among all spells.
local SUMMON_WAIT_MS = 4000

local function lower(v) return string.lower(str(v)) end

local function summonsTemplate(spell, tguid)
    local okP, txt = pcall(function() return Ext.Json.Stringify(Ext.Stats.Get(spell).SpellProperties, JSON_OPTS) end)
    if okP and type(txt) == "string" and lower(txt):find(tguid, 1, true) then return true end
    return false
end

function findSummonSpell(c)
    if not c.owner then return nil, "owner unknown" end
    if not c.template then return nil, "template unknown" end
    local tguid = lower(guidOf(c.template))
    local owner = guidOf(c.owner)
    if not flag(function() return Osi.Exists(owner) end) then return nil, "owner not in this save" end
    local book = {}
    pcall(function()
        for _, sp in pairs(Ext.Entity.Get(owner).SpellBook.Spells) do book[#book + 1] = str(sp.Id.Prototype) end
    end)
    for _, spell in ipairs(book) do
        if summonsTemplate(spell, tguid) then c.owner = owner return spell end
    end
    local okA, all = pcall(Ext.Stats.GetStats, "SpellData")
    if okA and type(all) == "table" then
        for _, spell in ipairs(all) do
            if summonsTemplate(spell, tguid) then c.owner = owner return spell end
        end
    end
    -- the spell data did not show the template: match by name within the owner's spell book instead
    -- (Spiritual_Weapon_Trident -> Target_SpiritualWeapon_Trident; a summon stack such as DWE_InvokeDuplicityStack
    -- -> Target_DWE_InvokeDuplicity_Container)
    local function letters(v) return (lower(v):gsub("[^%a]", "")) end
    local keys = { letters(str(c.template):gsub("_%x+%-%x+%-%x+%-%x+%-%x+$", "")) }
    local stack = c.summonData and c.summonData.field_28
    if type(stack) == "string" and stack ~= "" then keys[#keys + 1] = letters(stack:gsub("Stack$", "")) end
    for _, key in ipairs(keys) do
        if #key >= 6 then
            for _, spell in ipairs(book) do
                if letters(spell):find(key, 1, true) then c.owner = owner return spell end
            end
        end
    end
    return nil, "no spell found that summons " .. str(c.template)
end

function existingOfTemplate(template)
    local set = {}
    local ok, ents = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter") end)
    if ok and type(ents) == "table" then
        for _, ent in ipairs(ents) do
            local okU, uuid = pcall(function() return ent.Uuid.EntityUuid end)
            if okU and uuid and q(function() return Osi.GetTemplate(uuid) end) == template then set[uuid] = true end
        end
    end
    return set
end

function newSummonOf(c, before)
    for uuid in pairs(existingOfTemplate(c.template)) do
        if not before[uuid] then
            local owner = q(function() return Osi.CharacterGetOwner(uuid) end)
            if not owner or guidOf(owner) == guidOf(c.owner) then return uuid end
        end
    end
    return nil
end

-- ==================== ENVIRONMENT ====================
local SURFACE_TURNS = 3.0

-- Destroyed: objects the capture marks as destroyed, and objects near the party in this save that no longer existed in
-- the captured save (a cut rope: destroying it drops its fire bowl by itself). Nothing is deleted. Other objects that
-- moved in the fight are moved afterwards, and only if they are not already where they ended up.
function applyEnvironment(env, h, report, done, center, radius)
    local NULL = "00000000-0000-0000-0000-000000000000"
    local toCheck, toMove = {}, {}
    local captured = {}
    for _, o in ipairs(env.objects or {}) do captured[o.uuid] = true end
    local present, inCamp = nil, {}
    if env.present then
        present = {}
        for _, u in ipairs(env.present) do present[u] = true end
    end
    local campReadable = env.camp and env.camp.readable
    for _, u in ipairs(env.camp and env.camp.items or {}) do inCamp[u] = true end
    local campLeftAlone = 0
    if center and center[1] then
        pcall(function()
            for _, ent in ipairs(Ext.Entity.GetAllEntitiesWithComponent("ServerItem")) do
                local uuid = ent.Uuid.EntityUuid
                if not captured[uuid] and not q(function() return Osi.GetDirectInventoryOwner(uuid) end)
                    and (q(function() return Osi.GetDistanceToPosition(uuid, center[1], center[2], center[3]) end) or 1e9) <= (radius or RADIUS) then
                    -- with the capture's full item list: gone if it did not exist anywhere; captures made before that list
                    -- existed: only objects that cannot be picked up (an item picked up during the fight is not gone)
                    local movable = q(function() return Osi.IsMovable(uuid) end) ~= 0
                    if inCamp[uuid] then
                        -- it was sent to camp in the captured save
                        if pcall(function() Osi.SendToCampChest(uuid, h) end) then report.envToCamp = report.envToCamp + 1 end
                    else
                        local gone
                        if present then gone = not present[uuid] else gone = not movable end
                        -- an item that could have been sent to camp is only destroyed when the camp chest was readable
                        if gone and movable and not campReadable then
                            gone = false
                            campLeftAlone = campLeftAlone + 1
                        end
                        if gone and not flag(function() return Osi.IsDestroyed(uuid) end)
                            and pcall(function() Osi.ApplyDamage(uuid, 100000, "Bludgeoning", NULL) end) then
                            toCheck[#toCheck + 1] = { uuid = uuid, t = q(function() return Osi.GetTemplate(uuid) end), gone = true }
                        end
                    end
                end
            end
        end)
    end
    if campLeftAlone > 0 then
        report.notes[#report.notes + 1] = campLeftAlone .. " loose item(s) gone from the capture were left alone: the camp chest could not be "
            .. "read when it was captured, so they may have been sent to camp"
    end
    for _, o in ipairs(env.objects or {}) do
        if not flag(function() return Osi.Exists(o.uuid) end) then
            report.envMissing = report.envMissing + 1
        else
            local destroyedNow = flag(function() return Osi.IsDestroyed(o.uuid) end)
            if o.destroyed and not destroyedNow then
                if pcall(function() Osi.ApplyDamage(o.uuid, 100000, "Bludgeoning", NULL) end) then toCheck[#toCheck + 1] = o end
            elseif not o.destroyed and destroyedNow then
                report.notes[#report.notes + 1] = str(o.t) .. ": destroyed in this save but not in the capture (cannot be repaired)"
            end
            if not o.destroyed then
                -- damage it took (a door scorched by fire) without being destroyed
                if type(o.hp) == "number" and o.hp > 0 then
                    local now = q(function() return Osi.GetHitpoints(o.uuid) end)
                    if type(now) == "number" and now ~= o.hp and pcall(function() Osi.SetHitpoints(o.uuid, o.hp, "") end) then
                        report.envHp = report.envHp + 1
                    end
                end
                if type(o.x) == "number" then toMove[#toMove + 1] = o end
                local openedNow = q(function() return Osi.IsOpened(o.uuid) end)
                if o.opened ~= nil and openedNow ~= nil and o.opened ~= openedNow then
                    if pcall(function() if o.opened == 1 then Osi.Open(o.uuid) else Osi.Close(o.uuid) end end) then report.envDoors = report.envDoors + 1 end
                end
                local lockedNow = q(function() return Osi.IsLocked(o.uuid) end)
                if o.locked ~= nil and lockedNow ~= nil and o.locked ~= lockedNow then
                    if pcall(function() if o.locked == 1 then Osi.Lock(o.uuid, "") else Osi.Unlock(o.uuid, h) end end) then report.envDoors = report.envDoors + 1 end
                end
                local want, have = {}, {}
                for _, st in ipairs(o.statuses or {}) do want[st.id] = st end
                pcall(function() for _, sid in pairs(Ext.Entity.Get(o.uuid).StatusContainer.Statuses) do have[str(sid)] = true end end)
                for id, st in pairs(want) do
                    if not have[id] then
                        local turns = tonumber(st.turns) or -1
                        if turns ~= 0 and pcall(function() Osi.ApplyStatus(o.uuid, id, turns > 0 and turns * 6.0 or -1.0, 1, NULL) end) then
                            report.envStatuses = report.envStatuses + 1
                        end
                    end
                end
                for id in pairs(have) do
                    if not want[id] and pcall(function() Osi.RemoveStatus(o.uuid, id, NULL) end) then report.envStatuses = report.envStatuses + 1 end
                end
            end
        end
    end
    for _, sf in ipairs(env.surfaces or {}) do
        -- a chasm is part of the level, not something a fight leaves behind: creating one would open a hole in the floor
        if str(sf.type):find("Chasm", 1, true) then
            report.notes[#report.notes + 1] = "skipped a " .. str(sf.type) .. " surface (part of the level)"
        elseif pcall(function() Osi.CreateSurfaceAtPosition(sf.x, sf.y, sf.z, sf.type, 1.5, SURFACE_TURNS, NULL) end) then
            report.envSurfaces = report.envSurfaces + 1
        end
    end
    -- after the destroys have played out (a falling bowl has landed): count them, then move what is still out of place
    Ext.Timer.WaitFor(3000, function()
        for _, o in ipairs(toCheck) do
            if flag(function() return Osi.IsDestroyed(o.uuid) end) or not flag(function() return Osi.Exists(o.uuid) end) then
                if o.gone then report.envGone = report.envGone + 1 else report.envDestroyed = report.envDestroyed + 1 end
            else
                report.notes[#report.notes + 1] = str(o.t) .. ": damage did not destroy it"
            end
        end
        for _, o in ipairs(toMove) do
            if flag(function() return Osi.Exists(o.uuid) end)
                and (q(function() return Osi.GetDistanceToPosition(o.uuid, o.x, o.y, o.z) end) or 0) > 0.5
                and pcall(function() Osi.TeleportToPosition(o.uuid, o.x, o.y, o.z, "", 0, 0, 0, 0, 0) end) then
                report.envMoved = report.envMoved + 1
            end
        end
        if done then done() end
    end)
end

local START_TEXT = "WHAT CAUSED THE CRASH: recreating the captured scene. Press OK, then do not move, click or press anything "
    .. "until the message \"Scene recreated\" appears (a few seconds, longer if summons are being cast again)."
local DONE_TEXT = "WHAT CAUSED THE CRASH: Scene recreated. You can play again. Check your party, inventory and the room before you save."

local function notify(text)
    local h = host()
    if h then pcall(function() Osi.OpenMessageBox(h, text) end) end
end

local function envSummary(report)
    return string.format("environment: destroyed %d, destroyed because gone from the capture %d, sent to camp %d, damage (HP) set %d, "
        .. "moved %d, doors/locks changed %d, object statuses changed %d, ground surfaces made %d, objects not in this save %d",
        report.envDestroyed, report.envGone, report.envToCamp, report.envHp, report.envMoved, report.envDoors, report.envStatuses,
        report.envSurfaces, report.envMissing)
end

-- mode "all" (default) recreates everything, "environment" only the objects and ground surfaces
local function apply(id, mode)
    mode = mode or "all"
    local idx = loadIndex()
    local entry = findEntry(idx, id)
    if not entry then say("SCENE", "apply: no capture " .. (id and ("'" .. str(id) .. "'") or "in the list")) return end
    local raw = Ext.IO.LoadFile(entry.file)
    if not raw or raw == "" then say("SCENE", "apply: the file of \"" .. str(entry.name) .. "\" is missing") return end
    local ok, scene = pcall(Ext.Json.Parse, raw)
    if not ok or type(scene) ~= "table" then say("SCENE", "apply: \"" .. str(entry.name) .. "\" is unreadable") return end
    W.Log("SCENE", "recreating \"" .. str(entry.name) .. "\" (" .. mode .. ")")
    local h = host()
    local level = h and q(function() return Osi.GetRegion(h) end)
    if level ~= scene.level then
        say("SCENE", "apply refused: the snapshot is from " .. str(scene.level) .. ", you are in " .. str(level))
        return
    end
    notify(START_TEXT)
    if mode == "environment" then
        local rep2 = { envDestroyed = 0, envGone = 0, envToCamp = 0, envHp = 0, envMoved = 0, envDoors = 0, envStatuses = 0, envSurfaces = 0, envMissing = 0, notes = {} }
        if not scene.environment then
            say("SCENE", "\"" .. str(entry.name) .. "\" has no environment data (captured before it existed)")
            notify(DONE_TEXT)
            return
        end
        applyEnvironment(scene.environment, h, rep2, function()
            say("SCENE", envSummary(rep2))
            for i, n in ipairs(rep2.notes) do if i <= 40 then W.Log("SCENE", "  " .. n) end end
            W.FlushNow()
            notify(DONE_TEXT)
        end, scene.center, scene.radius)
        return
    end
    local report = { envDestroyed = 0, envGone = 0, envToCamp = 0, envHp = 0, envMoved = 0, envDoors = 0, envStatuses = 0, envSurfaces = 0, envMissing = 0, moved = 0, created = 0, killed = 0, revived = 0, statusAdded = 0, statusRemoved = 0,
        itemsAdded = 0, itemsRemoved = 0, equipped = 0, xp = 0, approval = 0, skipped = 0, notes = {},
        levelKilled = 0, levelBodiesMoved = 0, levelDeleted = 0, levelMoved = 0, levelNew = 0,
        resources = 0, cooldowns = 0, shortRests = "unchanged", summonsReused = 0, summonsRemoved = 0 }

    local NULL = "00000000-0000-0000-0000-000000000000"
    local pendingKill = {}  -- dead party members: their inventory and gear are matched first, then they die
    local summons = {}      -- summons that are not in this save: their owners cast them again
    local function isParty(c) return c.party and not c.summon end

    -- 0. summons the party already has in this save: a captured summon reuses one of the same kind from the same
    --    owner instead of being cast again; any left over afterwards were not there at the end of the fight
    local partyGuids = {}
    for _, c in ipairs(scene.characters) do
        if isParty(c) then partyGuids[guidOf(c.uuid)] = true end
    end
    local spare = {}  -- "template|owner" -> list of summon uuids in this save
    local claimed = {}
    pcall(function()
        for _, ent in ipairs(Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")) do
            local uuid = ent.Uuid.EntityUuid
            if flag(function() return Osi.IsSummon(uuid) end) and not flag(function() return Osi.IsDead(uuid) end) then
                local owner = q(function() return Osi.CharacterGetOwner(uuid) end)
                if owner and partyGuids[guidOf(owner)] then
                    local key = str(q(function() return Osi.GetTemplate(uuid) end)) .. "|" .. guidOf(owner)
                    spare[key] = spare[key] or {}
                    table.insert(spare[key], uuid)
                end
            end
        end
    end)
    for _, c in ipairs(scene.characters) do
        if c.summon and flag(function() return Osi.Exists(c.uuid) end) then claimed[c.uuid] = true end
    end

    -- 1. make sure everyone exists, is alive or dead as needed, and stands where they stood. Everyone else first (the
    --    dead are killed where they lay), the party last, so it never arrives next to an enemy that is still alive.
    local order = {}
    for _, c in ipairs(scene.characters) do if not c.party then order[#order + 1] = c end end
    for _, c in ipairs(scene.characters) do if c.party then order[#order + 1] = c end end
    for _, c in ipairs(order) do
        local exists = flag(function() return Osi.Exists(c.uuid) end)
        if not exists and c.summon and c.owner then
            for _, uuid in ipairs(spare[str(c.template) .. "|" .. guidOf(c.owner)] or {}) do
                if not claimed[uuid] then
                    claimed[uuid] = true
                    c.uuid = uuid
                    exists = true
                    report.summonsReused = report.summonsReused + 1
                    break
                end
            end
        end
        if not exists then
            if c.summon then
                summons[#summons + 1] = c
            elseif not c.template then
                report.skipped = report.skipped + 1
                report.notes[#report.notes + 1] = c.label .. ": not in this save and not recreated (no template)"
            else
                local new = q(function() return Osi.CreateAt(c.template, c.x, c.y, c.z, 0, 0, "") end)
                if new then
                    report.created = report.created + 1
                    c.uuid = guidOf(new)
                    exists = true
                else
                    report.notes[#report.notes + 1] = c.label .. ": could not be created from " .. str(c.template)
                end
            end
        end
        if exists then
            local deadNow = flag(function() return Osi.IsDead(c.uuid) end)
            if not c.dead and deadNow and pcall(function() Osi.Resurrect(c.uuid, "", 0) end) then report.revived = report.revived + 1 end
            if pcall(function() Osi.TeleportToPosition(c.uuid, c.x, c.y, c.z, "", 0, 0, 0, 0, 1) end) then report.moved = report.moved + 1 end
            if c.dead and not deadNow then
                if isParty(c) then
                    pendingKill[#pendingKill + 1] = c
                -- an enemy dies right away, before the party arrives (the party is moved after everyone else)
                else
                    local okK, errK = kill(c.uuid, h, 1)
                    if okK then report.killed = report.killed + 1
                    else report.notes[#report.notes + 1] = c.label .. ": could not be killed (" .. str(errK) .. ")" end
                end
            end
        end
    end

    -- party summons in this save that no captured summon took over did not exist at the end of the fight
    for _, list in pairs(spare) do
        for _, uuid in ipairs(list) do
            if not claimed[uuid] and pcall(function() Osi.RequestDeleteTemporary(uuid) end) then
                report.summonsRemoved = report.summonsRemoved + 1
            end
        end
    end

    -- 1b. whole level: bodies and items (before the party inventory is matched, so a picked-up item is moved by
    --     identity rather than created again from its template)
    if scene.levelDead then applyLevelDead(scene.levelDead, h, report) end
    if scene.levelItems then applyLevelItems(scene.levelItems, report) end
    -- 1c. objects and ground surfaces around the party
    if scene.environment then applyEnvironment(scene.environment, h, report, nil, scene.center, scene.radius) end

    local function restorePartyResources()
        for _, c in ipairs(scene.characters) do
            if isParty(c) and not c.dead and flag(function() return Osi.Exists(c.uuid) end) then applyResources(c, report) end
        end
        if type(scene.shortRests) == "number" then
            local now = q(function() return Osi.PartyGetActionResourceValue(h, "ShortRestPoint") end)
            if type(now) == "number" and now ~= scene.shortRests
                and pcall(function() Osi.PartyIncreaseActionResourceValue(h, "ShortRestPoint", scene.shortRests - now) end) then
                report.shortRests = str(now) .. " -> " .. str(scene.shortRests)
            end
        end
    end

    -- 2. HP and statuses of the living; inventory and experience of the whole party, the dead included
    Ext.Timer.WaitFor(1500, function()
        for _, c in ipairs(scene.characters) do
            if flag(function() return Osi.Exists(c.uuid) end) then
                if not c.dead then
                    setHp(c.uuid, c.hp)
                    applyStatuses(c, report)
                end
                if isParty(c) then
                    applyInventory(c, report)
                    if type(c.xp) == "number" then
                        local now = q(function() return Ext.Entity.Get(c.uuid).Experience.TotalExperience end)
                        if type(now) == "number" and c.xp > now and pcall(function() Osi.AddExplorationExperience(c.uuid, c.xp - now) end) then
                            report.xp = report.xp + (c.xp - now)
                        end
                    end
                end
            end
        end
        restorePartyResources()
        for _, a in ipairs(scene.approval or {}) do
            local now = q(function() return Osi.GetApprovalRating(a.owner, h) end)
            if type(now) == "number" and now ~= a.rating then
                if pcall(function() Osi.ChangeApprovalRating(a.owner, h, 0, a.rating - now) end) then report.approval = report.approval + 1 end
            end
        end
    end)

    -- 3. equip once the items exist (the dead too), then the dead party members die where they lay
    Ext.Timer.WaitFor(2500, function()
        for _, c in ipairs(scene.characters) do
            if isParty(c) then applyEquipment(c, report) end
        end
    end)
    Ext.Timer.WaitFor(3500, function()
        for _, c in ipairs(pendingKill) do
            local okK, errK = kill(c.uuid, NULL, 0)
            if okK then report.killed = report.killed + 1
            else report.notes[#report.notes + 1] = c.label .. ": could not be killed (" .. str(errK) .. ")" end
        end
    end)
    -- their death markers and injuries: added, nothing removed (dying sets its own statuses)
    Ext.Timer.WaitFor(4500, function()
        for _, c in ipairs(pendingKill) do
            local have = currentStatuses(c.uuid)
            for _, st in ipairs(c.statuses or {}) do
                if not have[st.id] then
                    local turns = tonumber(st.turns) or -1
                    if turns ~= 0 and pcall(function() Osi.ApplyStatus(c.uuid, st.id, turns > 0 and turns * 6.0 or -1.0, 1, c.uuid) end) then
                        report.statusAdded = report.statusAdded + 1
                    end
                end
            end
        end
    end)

    -- 5. once the summons are back: slots and cooldowns again (the casts used them), HP check, report, done
    local function finish()
        restorePartyResources()
        Ext.Timer.WaitFor(1000, function()
            local hpOff = 0
            for _, c in ipairs(scene.characters) do
                if not c.dead and type(c.hp) == "number" and flag(function() return Osi.Exists(c.uuid) end) then
                    local now = q(function() return Osi.GetHitpoints(c.uuid) end)
                    if now ~= c.hp then setHp(c.uuid, c.hp) hpOff = hpOff + 1 end
                end
            end
            say("SCENE", string.format("recreated: moved %d, created %d, revived %d, killed %d, statuses +%d/-%d, items +%d/-%d, "
                .. "equipped %d, xp +%d, approval %d, skipped %d, HP re-set %d",
                report.moved, report.created, report.revived, report.killed, report.statusAdded, report.statusRemoved,
                report.itemsAdded, report.itemsRemoved, report.equipped, report.xp, report.approval, report.skipped, hpOff))
            say("SCENE", string.format("party resources: %d amount(s) set, cooldowns written for %d character(s), short rests %s; "
                .. "summons cast again %d of %d, already here and reused %d, extra removed %d", report.resources, report.cooldowns,
                report.shortRests, report.summoned, #summons, report.summonsReused, report.summonsRemoved))
            if scene.environment then say("SCENE", envSummary(report)) end
            if scene.levelDead or scene.levelItems then
                say("SCENE", string.format("whole level: killed %d, bodies moved %d, items deleted %d, items moved %d, "
                    .. "items only in the captured save (not created) %d",
                    report.levelKilled, report.levelBodiesMoved, report.levelDeleted, report.levelMoved, report.levelNew))
            end
            for i, n in ipairs(report.notes) do
                if i > 40 then break end
                W.Log("SCENE", "  " .. n)
            end
            W.FlushNow()
            notify(DONE_TEXT)
        end)
    end

    -- 4. summons: each owner casts the spell that made it at the captured spot, one at a time; the new summon then
    --    gets the captured HP and statuses
    report.summoned = 0
    local function castNext(i)
        if i > #summons then finish() return end
        local c = summons[i]
        local spell, why = findSummonSpell(c)
        if not spell then
            report.notes[#report.notes + 1] = c.label .. ": not cast again (" .. why .. ")"
            castNext(i + 1)
            return
        end
        local before = existingOfTemplate(c.template)
        local okCast = pcall(function() Osi.UseSpellAtPosition(c.owner, spell, c.x, c.y, c.z, 1) end)
        if not okCast then
            report.notes[#report.notes + 1] = c.label .. ": " .. spell .. " could not be cast"
            castNext(i + 1)
            return
        end
        Ext.Timer.WaitFor(SUMMON_WAIT_MS, function()
            local new = newSummonOf(c, before)
            if new then
                report.summoned = report.summoned + 1
                pcall(function() Osi.TeleportToPosition(new, c.x, c.y, c.z, "", 0, 0, 0, 0, 1) end)
                local copy = {}
                for k, v in pairs(c) do copy[k] = v end
                copy.uuid = new
                setHp(new, c.hp)
                applyStatuses(copy, report)
            else
                report.notes[#report.notes + 1] = c.label .. ": " .. spell .. " was cast but no new summon appeared"
            end
            castNext(i + 1)
        end)
    end
    Ext.Timer.WaitFor(5000, function() castNext(1) end)
end

-- ==================== HOOKS ====================

local PAUSED_TEXT = "WHAT CAUSED THE CRASH: the game was paused when the level started so the scene could be captured. "
    .. "The capture is finished (check the journal for the result). Press OK to resume the game. If you do nothing it resumes by itself after a minute."
local AUTO_RESUME_MS = 60000

local function partyEntities()
    local list = {}
    local ok, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
    if ok and type(rows) == "table" then
        for _, r in ipairs(rows) do
            local okE, ent = pcall(Ext.Entity.Get, guidOf(r[1]))
            if okE and ent then list[#list + 1] = ent end
        end
    end
    return list
end

-- The engine's own pause: a Pause component on the party's characters.
local pausedByUs = {}          -- entities this capture paused, so exactly those are unpaused again
local pausedForCapture = false
local function setPause(on)
    local n = 0
    local list = partyEntities()
    if not on then for _, ent in ipairs(pausedByUs) do list[#list + 1] = ent end end
    for _, ent in ipairs(list) do
        local done = pcall(function()
            local has = ent:GetComponent("Pause") ~= nil
            if on and not has then ent:CreateComponent("Pause") n = n + 1 pausedByUs[#pausedByUs + 1] = ent
            elseif not on and has then ent:RemoveComponent("Pause") n = n + 1 end
        end)
        if not done then W.Log("SCENE", (on and "pause" or "unpause") .. " failed for a party member") end
    end
    if not on then pausedByUs = {} end
    return n
end

-- Ends the capture pause. Called when the message box is closed, when no box could be shown, after
-- AUTO_RESUME_MS, and when the level unloads - whichever comes first; later calls do nothing.
local function resumeAfterCapture(why)
    if not pausedForCapture then return 0 end
    pausedForCapture = false
    local n = setPause(false)
    say("SCENE", "game resumed after the capture: unpaused " .. n .. " party member(s) (" .. why .. ")")
    pcall(W.FlushNow)
    return n
end
W.ResumeAfterCapture = resumeAfterCapture

pcall(Ext.Osiris.RegisterListener, "MessageBoxClosed", 2, "after", function(_, message)
    if message == PAUSED_TEXT then resumeAfterCapture("OK pressed") end
end)
pcall(function()
    Ext.Events.GameStateChanged:Subscribe(function(e)
        local to = str(e.ToState)
        if to:find("Unload", 1, true) or to:find("Menu", 1, true) then pausedForCapture, pausedByUs = false, {} end
    end)
end)

pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", function()
    if not mcm("CaptureSceneOnLoad") then return end
    -- only pause when a capture is actually going to run, so loading the earlier save is not paused
    -- one capture per tick of the option: it switches itself off, so loading the earlier save next does not capture again
    pcall(function() Mods.BG3MCM.MCMAPI:SetSettingValue("CaptureSceneOnLoad", false, ModuleUUID) end)
    local pauseFirst = mcm("PauseBeforeCapture")
    if pauseFirst then
        local n = setPause(true)
        pausedForCapture = true
        W.Log("SCENE", "paused the game for the capture (" .. n .. " party member(s))")
        W.FlushNow()
    end
    local okC, errC = pcall(capture, "on load")
    if not okC then
        W.Log("SCENE", "capture FAILED with an error: " .. str(errC))
        W.FlushNow()
    end
    if pauseFirst then
        local h = host()
        local shown = h ~= nil and pcall(function() Osi.OpenMessageBox(h, PAUSED_TEXT) end)
        if not shown then
            resumeAfterCapture("no message box could be shown")
        else
            -- real time, not game time: the game clock may not advance while paused
            local wait = (Ext.Timer and Ext.Timer.WaitForRealtime) or (Ext.Timer and Ext.Timer.WaitFor)
            local okT = wait ~= nil and pcall(wait, AUTO_RESUME_MS, function() resumeAfterCapture("resumed by itself after a minute") end)
            if not okT then resumeAfterCapture("no timer available") end
        end
    end
end)

Ext.RegisterConsoleCommand("wcc_scene_unpause", function()
    pausedForCapture = false
    say("SCENE", "unpaused " .. setPause(false) .. " party member(s)")
end)

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

-- commands from the "Scene snapshots" tab (Client/SceneWindow.lua)
listenNet("WCC_Scene", function(_, payload)
    local okP, msg = pcall(Ext.Json.Parse, payload)
    if not okP or type(msg) ~= "table" then msg = { cmd = str(payload) } end
    W.Log("SCENE", "scene list: " .. str(msg.cmd) .. " " .. str(msg.id or "") .. " " .. str(msg.mode or ""))
    W.FlushNow()
    Ext.Utils.Print("[WhatCausedTheCrash] received from the Scene snapshots tab: " .. str(msg.cmd) .. " " .. str(msg.id or "") .. " " .. str(msg.mode or ""))
    if msg.cmd == "apply" then
        apply(msg.id, msg.mode)
    elseif msg.cmd == "capture" then
        capture("button")
    elseif msg.cmd == "select" or msg.cmd == "delete" or msg.cmd == "rename" then
        local idx = loadIndex()
        for i, e in ipairs(idx.scenes) do
            if e.id == msg.id then
                if msg.cmd == "select" then idx.selected = e.id
                elseif msg.cmd == "rename" and type(msg.name) == "string" and msg.name ~= "" then e.name = msg.name
                elseif msg.cmd == "delete" then
                    pcall(Ext.IO.SaveFile, e.file, "")
                    table.remove(idx.scenes, i)
                    if idx.selected == e.id then idx.selected = nil end
                end
                break
            end
        end
        saveIndex(idx)
    end
end)

-- Backup trigger that does not need MCM's buttons: ticking "Recreate the scene now" runs it and unticks itself.
local tickSubscribed = false
local function subscribeTick()
    if tickSubscribed then return end
    tickSubscribed = pcall(function()
        Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
            if payload and payload.modUUID == ModuleUUID and payload.settingId == "RecreateSceneNow" and payload.value == true then
                W.Log("SCENE", "Recreate ticked in MCM (selected capture)")
                pcall(function() Mods.BG3MCM.MCMAPI:SetSettingValue("RecreateSceneNow", false, ModuleUUID) end)
                apply()
            end
        end)
    end)
end
pcall(function() Ext.Events.SessionLoaded:Subscribe(subscribeTick) end)
pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", subscribeTick)

Ext.RegisterConsoleCommand("wcc_scene_capture", function() capture("console") end)
-- !wcc_scene_apply [number]: the selected capture, or the one with that number in !wcc_scenes
Ext.RegisterConsoleCommand("wcc_scene_apply", function(_, which) apply(which) end)
Ext.RegisterConsoleCommand("wcc_scene_apply_env", function(_, which) apply(which, "environment") end)
Ext.RegisterConsoleCommand("wcc_scenes", function()
    local idx = loadIndex()
    if #idx.scenes == 0 then Ext.Utils.Print("[WhatCausedTheCrash] no captures yet") return end
    for i, e in ipairs(idx.scenes) do
        Ext.Utils.Print(string.format("[WhatCausedTheCrash] %d%s %s (%s, %d characters, %d objects)", i, e.id == idx.selected and " *" or "",
            str(e.name), str(e.kind), tonumber(e.characters) or 0, tonumber(e.objects) or 0))
    end
end)
Ext.RegisterConsoleCommand("wcc_scene_select", function(_, which)
    local idx = loadIndex()
    local e = findEntry(idx, which)
    if e then idx.selected = e.id saveIndex(idx) Ext.Utils.Print("[WhatCausedTheCrash] selected: " .. str(e.name)) end
end)

W.SceneCapture, W.SceneApply, W.SceneApplyEnvironment = capture, apply, applyEnvironment
