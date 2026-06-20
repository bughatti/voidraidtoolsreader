----------------------------------------------------------------------
-- VoidRaidToolsReader Minimap — standardized minimap button.
-- Global name VoidRaidToolsReaderMinimapBtn so VoidHubBundle discovers it.
--
--   Size: 28x28 button, 20x20 icon, 54x54 border, offset (-2, 2)
--   Radius: (Minimap:GetWidth() / 2) + 6
--   Angle stored as DEGREES in VoidRaidToolsReaderCharDB.minimapAngle (default 240)
--
-- Click behavior:
--   Left  -> open consent dialog (status check, opt-in / opt-out)
--   Right -> dump session queue summary to chat (/vrtsr queue)
----------------------------------------------------------------------
local btn

local function PositionButton(b)
    VoidRaidToolsReaderCharDB = VoidRaidToolsReaderCharDB or {}
    local angle  = math.rad(VoidRaidToolsReaderCharDB.minimapAngle or 240)
    local radius = (Minimap:GetWidth() / 2) + 6
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
end

local function CreateMinimapButton()
    if btn then return btn end
    if _G.VoidRaidToolsReaderMinimapBtn then btn = _G.VoidRaidToolsReaderMinimapBtn; return btn end
    if not Minimap then return end

    btn = CreateFrame("Button", "VoidRaidToolsReaderMinimapBtn", Minimap)
    btn:SetSize(28, 28)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 10)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    -- "Eye" — fits the "silent observer / recorder" role
    icon:SetTexture("Interface\\Icons\\Spell_Shadow_EvilEye")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            -- Route through the existing /vrtsr queue handler to print
            -- the upload queue summary to chat.
            local handler = SlashCmdList and SlashCmdList["VRTSR"]
            if handler then handler("queue") end
        else
            -- Open the consent dialog via the existing /vrtr slash.
            local handler = SlashCmdList and SlashCmdList["VRTR"]
            if handler then handler("") end
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("|cff00c7ffVRT|r |cffff8040Reader|r", 1, 1, 1)
        -- Show current consent state inline.
        local choice = "(undecided)"
        if VRTReader_IsUploadAllowed and VoidRaidToolsReaderDB
           and VoidRaidToolsReaderDB.consent then
            local c = VoidRaidToolsReaderDB.consent.choice
            if c == "allowed" then
                choice = "|cff20ff20uploads ENABLED|r"
            elseif c == "local" then
                choice = "|cffffaa20LOCAL-ONLY|r"
            end
        end
        GameTooltip:AddLine("Mode: " .. choice, 0.85, 0.85, 0.85)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Left-click: open consent / toggle uploads", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Right-click: show session upload queue", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Drag: reposition around minimap", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self) self._dragging = true end)
    btn:SetScript("OnDragStop",  function(self) self._dragging = false end)
    btn:SetScript("OnUpdate", function(self)
        if self._dragging then
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local px, py = GetCursorPosition()
            if not mx or not px or not scale then return end
            px = px / scale; py = py / scale
            VoidRaidToolsReaderCharDB = VoidRaidToolsReaderCharDB or {}
            VoidRaidToolsReaderCharDB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
            PositionButton(self)
        end
    end)

    PositionButton(btn)
    return btn
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    CreateMinimapButton()
    VoidRaidToolsReaderCharDB = VoidRaidToolsReaderCharDB or {}
    if btn and VoidRaidToolsReaderCharDB.minimapHidden then btn:Hide() end
end)
