----------------------------------------------------------------------
-- VoidHubBundle — drop-in shared across all Void* addons.
--
-- Cooperative election: the first Void* addon that loads creates the
-- single hub button. Any other Void* addon loaded after sees the global
-- flag and skips creation. If the "owning" addon is later disabled, the
-- next /reload triggers another addon to create it.
--
-- Left-click hub → vertical row of Void* minimap icons
-- Right-click hub → info panel about all Void* addons (cross-promotion)
--
-- Position persistence: uses shared SavedVariablesPerCharacter VoidHubCharDB
-- (each Void* addon's TOC must include this var name for persistence to
-- work regardless of which addon owns the hub this session).
----------------------------------------------------------------------

-- Election guard — only first-loaded Void* addon does the work
if _G.__VoidHubLoaded then return end
_G.__VoidHubLoaded = true

local CYAN_R, CYAN_G, CYAN_B = 0.00, 0.78, 1.00
local BORDER_TEX = "Interface\\Minimap\\MiniMap-TrackingBorder"
local hubBtn, popupFrame, infoFrame
local popupItems = {}

----------------------------------------------------------------------
-- Whitelist of OUR Void* addons (don't pick up third-party "Void*" addons)
----------------------------------------------------------------------
local KNOWN_VOID_ADDONS = {
    { name = "VoidAH",         label = "Auction House",     desc = "Streamlined auction browser with deal-finder and quick-sell." },
    { name = "VoidAlert",      label = "Alerts",            desc = "Custom on-screen alerts for combat events." },
    { name = "VoidBags",       label = "Bags",              desc = "Unified bag UI with sorting, quality borders, and item search." },
    { name = "VoidCalendar",   label = "Calendar",          desc = "Calendar replacement with cross-region timezone awareness, class roster, and reminders." },
    { name = "VoidCheatSheet", label = "Cheat Sheets",      desc = "Boss/dungeon strategy notes pinned to your screen." },
    { name = "VoidComp",       label = "Comp Tool",         desc = "Group composition planning and balance helper." },
    { name = "VoidDice",       label = "Dice Roller",       desc = "Standardized loot-roll rolls for raids." },
    { name = "VoidFisher",     label = "Fishing",           desc = "Helper for AFK fishing and route tracking." },
    { name = "VoidGear",       label = "Gear Planner",      desc = "Loadout manager with stat-budget gear scoring." },
    { name = "VoidLFG",        label = "Group Finder",      desc = "Enhanced LFG dialog with party history and quality filters." },
    { name = "VoidProf",       label = "Professions",       desc = "Profession tracking, recipe finder, and crafting queue." },
    { name = "VoidPug",        label = "Pug Tracker",       desc = "Track pug raid lockouts, leader/roster, BNet contacts, and reset timers." },
    { name = "VoidQuest",      label = "Quests",            desc = "Quest helper with proximity sort and step-by-step guides." },
    { name = "VoidRaidTools",  label = "Raid Tools",        desc = "Per-boss raid mechanic alerts: kicks, dispels, tank swaps, soaks via ETEA. L'ura memory game." },
    { name = "VoidRaidToolsReader", label = "VRT Reader",   desc = "Silent session recorder companion to VoidRaidTools. Required for cross-class data capture." },
    { name = "VoidScout",      label = "Scout",             desc = "Utility-aware applicant scoring for LFG premade groups. 8-axis behavioral analysis." },
    { name = "VoidSequencer",  label = "Sequencer",         desc = "One-button rotation sequencer with ST/AoE switch and auto-cooldowns (Unholy DK)." },
    { name = "VoidStealth",    label = "Stealth Bars",      desc = "Fades action bars out during combat for a clean screen. Keybinds stay live." },
    { name = "VoidTank",       label = "Tank Tools",        desc = "Tank-swap alerts and threat tracking." },
    { name = "VoidUI",         label = "UI Overhaul",       desc = "Full UI replacement with class-themed accents." },
}

local function PositionHub(btn)
    VoidHubCharDB = VoidHubCharDB or {}
    local angle  = math.rad(VoidHubCharDB.minimapAngle or 215)
    local radius = (Minimap:GetWidth() / 2) + 6
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
end

local function DiscoverVoidButtons()
    local found = {}
    for _, info in ipairs(KNOWN_VOID_ADDONS) do
        local btn = _G[info.name .. "MinimapBtn"]
        if btn and type(btn) == "table"
            and btn.GetObjectType and btn:GetObjectType() == "Button" then
            table.insert(found, { name = info.label, fullName = info.name, button = btn })
        end
    end
    return found
end

----------------------------------------------------------------------
-- Popup (left-click) — vertical row of installed Void* minimap icons
----------------------------------------------------------------------
local function BuildPopup()
    if popupFrame then return popupFrame end
    popupFrame = CreateFrame("Frame", "VoidHubPopup", Minimap)
    popupFrame:SetSize(40, 40)
    popupFrame:SetFrameStrata("MEDIUM")
    popupFrame:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 12)
    popupFrame:Hide()
    popupFrame:SetScript("OnShow", function(self)
        self:EnableMouse(true)
        self:SetScript("OnEvent", function(_, event)
            if event == "GLOBAL_MOUSE_DOWN" then
                if hubBtn and (hubBtn:IsMouseOver() or self:IsMouseOver()) then return end
                self:Hide()
            end
        end)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    popupFrame:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    return popupFrame
end

local function RefreshPopup()
    BuildPopup()
    for _, it in ipairs(popupItems) do if type(it) == "table" and it.SetPoint then it:Hide() end end

    local buttons = DiscoverVoidButtons()
    local slotSize, gap, n = 28, 4, #buttons
    if n == 0 then
        popupFrame:SetSize(160, 30)
        if not popupItems._noneLabel then
            local lbl = popupFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            lbl:SetPoint("CENTER")
            popupItems._noneLabel = lbl
        end
        popupItems._noneLabel:SetText("No Void* addons found")
        popupItems._noneLabel:Show()
        return
    end
    if popupItems._noneLabel then popupItems._noneLabel:Hide() end

    popupFrame:SetSize(slotSize + 8, n * (slotSize + gap) - gap + 4)
    for i, entry in ipairs(buttons) do
        local item = popupItems[i]
        if not item then
            item = CreateFrame("Button", nil, popupFrame)
            item:SetSize(slotSize, slotSize)
            item.icon = item:CreateTexture(nil, "BACKGROUND")
            item.icon:SetSize(20, 20)
            item.icon:SetPoint("CENTER")
            item.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            item.border = item:CreateTexture(nil, "OVERLAY")
            item.border:SetSize(54, 54)
            item.border:SetPoint("TOPLEFT", -2, 2)
            item.border:SetTexture(BORDER_TEX)
            item.hl = item:CreateTexture(nil, "OVERLAY")
            item.hl:SetSize(20, 20)
            item.hl:SetPoint("CENTER")
            item.hl:SetColorTexture(CYAN_R, CYAN_G, CYAN_B, 0.35)
            item.hl:Hide()
            item:SetScript("OnEnter", function(self)
                self.hl:Show()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(("|cff00c7ff%s|r"):format(self._fullName or self._name or "?"))
                GameTooltip:AddLine("Click to open", 1, 1, 1)
                GameTooltip:Show()
            end)
            item:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
            popupItems[i] = item
        end
        item:ClearAllPoints()
        item:SetPoint("TOP", popupFrame, "TOP", 0, -(4 + (i - 1) * (slotSize + gap)))
        item._name, item._fullName, item._addonButton = entry.name, entry.fullName, entry.button
        local srcTexture
        if entry.button.GetRegions then
            for _, region in ipairs({ entry.button:GetRegions() }) do
                if region.GetTexture and region:GetObjectType() == "Texture" then
                    local tex = region:GetTexture()
                    if tex and not tostring(tex):find("Minimap%-Tracking") then srcTexture = tex; break end
                end
            end
        end
        item.icon:SetTexture(srcTexture or "Interface\\Icons\\spell_shadow_summonvoidwalker")
        item:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        item:SetScript("OnClick", function(self, button)
            popupFrame:Hide()
            local script = self._addonButton:GetScript("OnClick")
            if script then script(self._addonButton, button) end
        end)
        item:Show()
    end
end

local function TogglePopup()
    BuildPopup()
    if popupFrame:IsShown() then popupFrame:Hide(); return end
    RefreshPopup()
    popupFrame:ClearAllPoints()
    local screenW = GetScreenWidth() or 1920
    local mapCenterX = Minimap:GetCenter() or (screenW / 2)
    if mapCenterX > screenW / 2 then
        popupFrame:SetPoint("TOPRIGHT", Minimap, "TOPLEFT", -8, 0)
    else
        popupFrame:SetPoint("TOPLEFT", Minimap, "TOPRIGHT", 8, 0)
    end
    popupFrame:Show()
end

----------------------------------------------------------------------
-- Info panel (right-click) — full list of Void* addons with descriptions,
-- highlighting which ones the user has installed
----------------------------------------------------------------------
local function BuildInfoFrame()
    if infoFrame then return infoFrame end
    infoFrame = CreateFrame("Frame", "VoidHubInfo", UIParent, "BackdropTemplate")
    infoFrame:SetSize(440, 540)
    infoFrame:SetPoint("CENTER")
    infoFrame:SetFrameStrata("HIGH")
    infoFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    infoFrame:SetBackdropColor(0.04, 0.05, 0.08, 0.97)
    infoFrame:SetBackdropBorderColor(CYAN_R, CYAN_G, CYAN_B, 0.85)
    infoFrame:Hide()
    infoFrame:SetMovable(true)
    infoFrame:EnableMouse(true)
    infoFrame:RegisterForDrag("LeftButton")
    infoFrame:SetScript("OnDragStart", infoFrame.StartMoving)
    infoFrame:SetScript("OnDragStop", infoFrame.StopMovingOrSizing)
    table.insert(UISpecialFrames, "VoidHubInfo")

    -- Title
    local title = infoFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cff00c7ffVoid Addons|r")

    -- Close button
    local close = CreateFrame("Button", nil, infoFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- Scrollable list of addons
    local scroll = CreateFrame("ScrollFrame", nil, infoFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -36)
    scroll:SetPoint("BOTTOMRIGHT", -30, 14)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(390, 1)
    scroll:SetScrollChild(content)

    local yOff = 0
    for _, info in ipairs(KNOWN_VOID_ADDONS) do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(390, 52)
        row:SetPoint("TOPLEFT", 0, -yOff)

        local installed = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(info.name))
            or (IsAddOnLoaded and IsAddOnLoaded(info.name))

        local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameFs:SetPoint("TOPLEFT", 4, -2)
        nameFs:SetText(("|cff00c7ff%s|r  |cff%s%s|r"):format(
            info.name,
            installed and "66ff66" or "888888",
            installed and "[installed]" or "[not installed]"
        ))

        local labelFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        labelFs:SetPoint("TOPLEFT", 4, -18)
        labelFs:SetText(info.label)
        labelFs:SetTextColor(0.8, 0.8, 0.85)

        local descFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        descFs:SetPoint("TOPLEFT", 4, -32)
        descFs:SetPoint("RIGHT", -4, 0)
        descFs:SetJustifyH("LEFT")
        descFs:SetText(info.desc)
        descFs:SetTextColor(0.65, 0.65, 0.7)

        yOff = yOff + 56
    end
    content:SetHeight(yOff)

    -- Footer
    local footer = infoFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("BOTTOM", 0, 4)
    footer:SetText("Find more at curseforge.com/wow — search 'Void'")
    footer:SetTextColor(0.5, 0.5, 0.55)

    return infoFrame
end

local function ToggleInfo()
    BuildInfoFrame()
    if infoFrame:IsShown() then infoFrame:Hide() else infoFrame:Show() end
end

----------------------------------------------------------------------
-- Hub button on minimap
----------------------------------------------------------------------
local function CreateHubButton()
    if hubBtn then return end
    if _G.VoidHubMinimapBtn then return end   -- another addon's bundle already created it
    if not Minimap then return end

    hubBtn = CreateFrame("Button", "VoidHubMinimapBtn", Minimap)
    hubBtn:SetSize(28, 28)
    hubBtn:SetFrameStrata("MEDIUM")
    hubBtn:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 11)

    local icon = hubBtn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\spell_shadow_summonvoidwalker")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = hubBtn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetTexture(BORDER_TEX)

    hubBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    hubBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ToggleInfo() else TogglePopup() end
    end)
    hubBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("|cff00c7ffVoidHub|r")
        GameTooltip:AddLine("Left-click: open Void addons", 1, 1, 1)
        GameTooltip:AddLine("Right-click: info on all Void addons", 1, 1, 1)
        GameTooltip:AddLine("Drag: reposition", 0.7, 0.7, 0.7)
        local buttons = DiscoverVoidButtons()
        if #buttons > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(("|cff8c8c9e%d Void addon(s) detected|r"):format(#buttons))
        end
        GameTooltip:Show()
    end)
    hubBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    hubBtn:SetMovable(true)
    hubBtn:RegisterForDrag("LeftButton")
    hubBtn:SetScript("OnDragStart", function(self) self._dragging = true end)
    hubBtn:SetScript("OnDragStop",  function(self) self._dragging = false end)
    hubBtn:SetScript("OnUpdate", function(self)
        if self._dragging then
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local px, py = GetCursorPosition()
            px = px / scale; py = py / scale
            VoidHubCharDB = VoidHubCharDB or {}
            VoidHubCharDB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
            PositionHub(self)
        end
    end)
    PositionHub(hubBtn)
end

----------------------------------------------------------------------
-- Satellite-icon consolidation: once the hub is up, hide the individual
-- Void* minimap buttons so the minimap isn't cluttered. The hub popup
-- still launches them via the source button's OnClick — they just become
-- invisible launch shims. User can opt out by setting
-- VoidHubCharDB.showSatellites = true (right-click hub → toggle, /vhub satellites).
----------------------------------------------------------------------
local _satelliteHookInstalled = {}

local function HideSatellites()
    VoidHubCharDB = VoidHubCharDB or {}
    if VoidHubCharDB.showSatellites then return end
    for _, info in ipairs(KNOWN_VOID_ADDONS) do
        local btn = _G[info.name .. "MinimapBtn"]
        if btn and btn.Hide then
            btn:Hide()
            -- Lock the button hidden: any later Show() (from the owning
            -- addon's own login/config path) gets silently reverted on the
            -- next frame. Avoid hooking Show directly (taint-prone); use a
            -- one-shot OnShow handler instead.
            if not _satelliteHookInstalled[info.name] and btn.HookScript then
                btn:HookScript("OnShow", function(self)
                    if not (VoidHubCharDB and VoidHubCharDB.showSatellites) then
                        self:Hide()
                    end
                end)
                _satelliteHookInstalled[info.name] = true
            end
        end
    end
end

local function ShowSatellites()
    for _, info in ipairs(KNOWN_VOID_ADDONS) do
        local btn = _G[info.name .. "MinimapBtn"]
        if btn and btn.Show then btn:Show() end
    end
end

----------------------------------------------------------------------
-- Slash command for the hub itself: /vhub
----------------------------------------------------------------------
SLASH_VOIDHUB1 = "/vhub"
SlashCmdList["VOIDHUB"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    VoidHubCharDB = VoidHubCharDB or {}
    if msg == "satellites" or msg == "sat" or msg == "icons" then
        VoidHubCharDB.showSatellites = not VoidHubCharDB.showSatellites
        if VoidHubCharDB.showSatellites then
            ShowSatellites()
            print("|cff00c7ff[VoidHub]|r Individual minimap icons |cff66ff66shown|r.")
        else
            HideSatellites()
            print("|cff00c7ff[VoidHub]|r Individual minimap icons |cffff9933hidden|r — use the hub.")
        end
    elseif msg == "info" or msg == "i" then
        ToggleInfo()
    elseif msg == "" or msg == "help" then
        print("|cff00c7ff[VoidHub]|r Commands:")
        print("  |cff00c7ff/vhub|r — show this help")
        print("  |cff00c7ff/vhub satellites|r — toggle individual minimap icons")
        print("  |cff00c7ff/vhub info|r — open the Void Addons info panel")
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    C_Timer.After(0.5, function()
        CreateHubButton()
        HideSatellites()
    end)
    -- Re-sweep for late-loading addons (LoD, etc.)
    C_Timer.After(2.0, HideSatellites)
    C_Timer.After(5.0, HideSatellites)
end)
