-- Small window that opens when the mod detects the game struggling. It lists the NPCs that are
-- fighting far from the party and lets you freeze them (they stand still) or release them.

local win = Ext.IMGUI.NewWindow("What Caused the Crash")
win.Open = false
win.Closeable = true
win:SetSize({460, 380})

local reasonText = win:AddText("Waiting for a warning...")
local frozenText = win:AddText("")
win:AddSeparator()
win:AddText("Fights your party is not part of (busiest first):")
local listText = win:AddText("none")
win:AddSeparator()

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

local function Send(tbl)
    pcall(Ext.Net.PostMessageToServer, "WCC_Cmd", Ext.Json.Stringify(tbl))
end

local freezeBtn = win:AddButton("Freeze these fights")
freezeBtn.OnClick = function() Send({ cmd = "freeze_far" }) end
local releaseBtn = win:AddButton("Release all")
releaseBtn.SameLine = true
releaseBtn.OnClick = function() Send({ cmd = "release_all" }) end

local autoBox = win:AddCheckbox("Freeze them automatically when a warning appears", false)
autoBox.OnChange = function(c) Send({ cmd = "set_auto", value = c.Checked }) end
local alwaysBox = win:AddCheckbox("Always freeze fights the party is not in", false)
alwaysBox.OnChange = function(c) Send({ cmd = "set_always", value = c.Checked }) end

listenNet("WCC_State", function(_, payload)
    local ok, st = pcall(Ext.Json.Parse, payload)
    if not ok or type(st) ~= "table" then return end
    reasonText.Label = "Last warning: " .. tostring(st.reason)
    frozenText.Label = "Frozen fights: " .. tostring(st.frozen)
    local lines = {}
    for i, c in ipairs(st.candidates or {}) do
        lines[i] = string.format("%s  (%dm from party, activity %d)", c.label, c.dist, c.heat)
    end
    listText.Label = #lines > 0 and table.concat(lines, "\n") or "none"
    autoBox.Checked = st.auto and true or false
    alwaysBox.Checked = st.always and true or false
    if st.open then win.Open = true end
end)
