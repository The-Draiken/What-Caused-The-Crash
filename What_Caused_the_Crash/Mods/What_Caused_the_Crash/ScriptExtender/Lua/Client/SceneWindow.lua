-- "Scene snapshots" tab in the MCM window (Server/SceneSnapshot.lua does the work): every capture with its level, time
-- and kind, and buttons to recreate everything, recreate only the environment, select it, rename or delete it.
-- These are ordinary IMGUI buttons, not MCM event buttons. If MCM will not take the tab, "!wcc_scenes_window" in the
-- client console opens the same list in a window of its own.

local INDEX = "WhatCausedTheCrash/scenes/index.json"

local function send(tbl)
    local ok, err = pcall(Ext.Net.PostMessageToServer, "WCC_Scene", Ext.Json.Stringify(tbl))
    Ext.Utils.Print("[WhatCausedTheCrash] Scene snapshots tab: " .. tostring(tbl.cmd) .. " " .. tostring(tbl.id or "")
        .. (ok and " sent" or (" could not be sent: " .. tostring(err))))
end

local function readIndex()
    local raw = Ext.IO.LoadFile(INDEX)
    if raw and raw ~= "" then
        local ok, t = pcall(Ext.Json.Parse, raw)
        if ok and type(t) == "table" then t.scenes = t.scenes or {} return t end
    end
    return { scenes = {} }
end

local views = {}  -- every place the list is shown (tab, window), re-rendered when it changes

local function render(view)
    if view.list then pcall(function() view.list:Destroy() end) end
    local list = view.parent:AddGroup("wcc_scene_list")
    view.list = list
    local idx = readIndex()
    if #idx.scenes == 0 then
        list:AddText("No captures yet. Tick \"Capture the scene on load\" in the What Caused the Crash tab and load the save,")
        list:AddText("or press \"Capture the scene now\" while the scene you want is on screen.")
        return
    end
    for i = #idx.scenes, 1, -1 do
        local e = idx.scenes[i]
        list:AddSeparator()
        list:AddText(string.format("%d. %s%s", i, tostring(e.name), e.id == idx.selected and "   [selected]" or ""))
        list:AddText(string.format("    %s  |  %s  |  %d characters, %d objects  |  captured %s", tostring(e.level), tostring(e.kind),
            tonumber(e.characters) or 0, tonumber(e.objects) or 0, tostring(e.time)))
        local all = list:AddButton("Recreate everything##all" .. e.id)
        all.OnClick = function() send({ cmd = "apply", id = e.id, mode = "all" }) end
        local env = list:AddButton("Recreate environment only##env" .. e.id)
        env.SameLine = true
        env.OnClick = function() send({ cmd = "apply", id = e.id, mode = "environment" }) end
        local sel = list:AddButton("Select##sel" .. e.id)
        sel.SameLine = true
        sel.OnClick = function() send({ cmd = "select", id = e.id }) end
        local name = list:AddInputText("##name" .. e.id, tostring(e.name))
        local ren = list:AddButton("Rename##ren" .. e.id)
        ren.SameLine = true
        ren.OnClick = function() send({ cmd = "rename", id = e.id, name = name.Text }) end
        local del = list:AddButton("Delete##del" .. e.id)
        del.SameLine = true
        del.OnClick = function() send({ cmd = "delete", id = e.id }) end
    end
end

local function refreshAll()
    for _, v in ipairs(views) do pcall(render, v) end
end

local function build(parent)
    local view = { parent = parent }
    parent:AddText("Recreate a captured scene in an earlier save of the same area. Press OK on the message that appears,")
    parent:AddText("then touch nothing until \"Scene recreated\" shows. Check the result before you save.")
    parent:AddText("[selected] is the capture used by the \"Recreate the scene now\" checkbox and !wcc_scene_apply.")
    local refresh = parent:AddButton("Refresh list")
    refresh.OnClick = refreshAll
    local cap = parent:AddButton("Capture the scene now")
    cap.SameLine = true
    cap.OnClick = function() send({ cmd = "capture" }) end
    views[#views + 1] = view
    render(view)
end

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

-- the server says the list changed (capture, rename, delete, select)
listenNet("WCC_SceneList", function() refreshAll() end)

-- MCM tab. This mod loads before MCM, so keep trying until MCM takes it.
local tabAdded = false
local function addTab()
    if tabAdded then return true end
    local ok = false
    local api = MCM or (Mods and Mods.What_Caused_the_Crash and Mods.What_Caused_the_Crash.MCM)
    if api and api.InsertModMenuTab then
        ok = pcall(function() api.InsertModMenuTab("Scene snapshots", build) end)
    end
    if not ok and Mods and Mods.BG3MCM and Mods.BG3MCM.IMGUIAPI and Mods.BG3MCM.IMGUIAPI.InsertModMenuTab then
        ok = pcall(function() Mods.BG3MCM.IMGUIAPI:InsertModMenuTab(ModuleUUID, "Scene snapshots", build) end)
    end
    tabAdded = ok
    if ok then Ext.Utils.Print("[WhatCausedTheCrash] Scene snapshots tab added to the MCM window") end
    return ok
end

local ticks = 0
local sub
sub = Ext.Events.Tick:Subscribe(function()
    ticks = ticks + 1
    if ticks % 30 ~= 0 then return end
    if addTab() then
        Ext.Events.Tick:Unsubscribe(sub)
    elseif ticks > 30 * 60 * 20 then
        Ext.Events.Tick:Unsubscribe(sub)
        Ext.Utils.PrintWarning("[WhatCausedTheCrash] the Scene snapshots tab could not be added to MCM: type !wcc_scenes_window")
    end
end)

-- fallback: the same list in its own window
local win
Ext.RegisterConsoleCommand("wcc_scenes_window", function()
    if not win then
        win = Ext.IMGUI.NewWindow("Scene snapshots")
        win.Closeable = true
        win:SetSize({ 720, 520 })
        build(win)
    end
    win.Open = true
    refreshAll()
end)
