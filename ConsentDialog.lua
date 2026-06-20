----------------------------------------------------------------------
-- VoidRaidToolsReader — first-run consent dialog + opt-out controls.
--
-- On first PLAYER_LOGIN after install we show a one-time dialog
-- explaining exactly what the addon collects and uploads, with three
-- buttons: Allow uploads, Local-only, Read more.
--
-- The choice persists in VoidRaidToolsReaderDB.consent:
--   "allowed"  → SessionRecorder queues sessions for upload (default
--                behavior; pending_uploads gets drained by Go uploader)
--   "local"    → sessions still record locally for /vrtsr inspection but
--                queueForUpload is a no-op (queue stays empty)
--   nil        → first run; dialog will fire next PLAYER_LOGIN
--
-- /vrtr  → shows current state + opens dialog if you want to change it
----------------------------------------------------------------------

local CONSENT_VERSION = 2  -- bump if we add new data categories or wording

local UPLOADER_URL = "https://github.com/bughatti/voidscout-uploader/releases/latest"

VoidRaidToolsReaderDB = VoidRaidToolsReaderDB or {}

local function readConsent()
    local c = VoidRaidToolsReaderDB.consent
    if type(c) ~= "table" then return nil end
    if c.version ~= CONSENT_VERSION then return nil end  -- new version → re-prompt
    return c.choice  -- "allowed" or "local"
end

local function writeConsent(choice)
    VoidRaidToolsReaderDB.consent = {
        version = CONSENT_VERSION,
        choice  = choice,
        chosen_at = time(),
    }
end

-- Public predicate read by SessionRecorder's queueForUpload.
function VRTReader_IsUploadAllowed()
    return readConsent() == "allowed"
end

----------------------------------------------------------------------
-- Dialog
----------------------------------------------------------------------
local dlg
local function BuildDialog()
    if dlg then return dlg end
    local f = CreateFrame("Frame", "VRTReader_ConsentDialog", UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetSize(620, 560)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cff00c7ffVoidRaidTools Reader|r — what gets uploaded")

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    body:SetPoint("TOPLEFT", 22, -50)
    body:SetPoint("TOPRIGHT", -22, -50)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetText(
        "Reader watches boss fights and can upload what it sees to |cffffd700api.voidscout.io|r so the community can score performance and analyze raid mechanics.\n\n" ..
        "|cffffd700What gets uploaded:|r boss cast events (ETEA), group composition (names/realms/classes/specs), friendly buff/debuff traces during pulls, encounter ID + difficulty + kill/wipe outcome.\n\n" ..
        "|cffffd700We do NOT upload:|r protected actions, gear / inventory, chat, system info, anything outside an active encounter.\n\n" ..
        "All data is publicly visible to your client during play (same as Warcraft Logs, Archon, BigWigs)."
    )

    -- Uploader requirement callout — the box that explains the gotcha that
    -- bit Vede's raid mates: clicking "Allow uploads" only flips the addon
    -- flag, it does NOT install a network daemon. Without the Go uploader
    -- running, sessions just pile up locally and never reach the server.
    local up_title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    up_title:SetPoint("TOPLEFT", 22, -260)
    up_title:SetText("|cffff7755STEP 2 — you also need the uploader:|r")

    local up_body = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    up_body:SetPoint("TOPLEFT", 22, -284)
    up_body:SetPoint("TOPRIGHT", -22, -284)
    up_body:SetJustifyH("LEFT")
    up_body:SetJustifyV("TOP")
    up_body:SetText(
        "WoW addons can't make HTTP requests — that's a Blizzard sandbox rule. So the actual upload to the server is done by a tiny background program (|cffffd700voidscout-uploader.exe|r on Windows, same name on Mac/Linux). Download once, run it once, it stays in your tray and uploads sessions in the background. Auto-updates itself.\n\n" ..
        "Without it: Reader records fine, sessions pile up locally, |cffff7755nothing reaches voidscout.io|r."
    )

    local url_label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    url_label:SetPoint("TOPLEFT", 22, -394)
    url_label:SetText("|cffffd700Download (Ctrl+C to copy):|r")

    local url_box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    url_box:SetSize(540, 24)
    url_box:SetPoint("TOPLEFT", 30, -414)
    url_box:SetAutoFocus(false)
    url_box:SetText(UPLOADER_URL)
    url_box:SetCursorPosition(0)
    url_box:HighlightText()
    url_box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Re-select the text whenever the user clicks the box so Ctrl+C just works.
    url_box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    url_box:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= UPLOADER_URL then
            self:SetText(UPLOADER_URL)
        end
        self:HighlightText()
    end)

    local btn_allow = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn_allow:SetSize(170, 26)
    btn_allow:SetPoint("BOTTOMLEFT", 22, 18)
    btn_allow:SetText("Allow uploads")
    btn_allow:SetScript("OnClick", function()
        writeConsent("allowed")
        print("|cff00c7ff[VRT Reader]|r uploads ENABLED. Toggle anytime with |cffffd700/vrtr|r.")
        f:Hide()
    end)

    local btn_local = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn_local:SetSize(170, 26)
    btn_local:SetPoint("BOTTOM", 0, 18)
    btn_local:SetText("Local-only (no upload)")
    btn_local:SetScript("OnClick", function()
        writeConsent("local")
        print("|cff00c7ff[VRT Reader]|r local-only mode. Recordings stay on your PC. Toggle with |cffffd700/vrtr|r.")
        f:Hide()
    end)

    -- "Delete + go local" — flips to local-only AND queues a server-side
    -- deletion request via the shared opt_out_requested SavedVariables
    -- flag. The Go uploader picks it up on next run and POSTs
    -- /api/opt-out. Reader is the silent recorder companion to VRT, and
    -- the uploader uses VoidScoutDB for both opt-out queue + Reader
    -- session queue (single uploader for the suite).
    local btn_delete = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn_delete:SetSize(170, 26)
    btn_delete:SetPoint("BOTTOMRIGHT", -22, 18)
    btn_delete:SetText("Delete + go local")
    btn_delete:SetScript("OnClick", function()
        VoidScoutDB = VoidScoutDB or {}
        writeConsent("local")
        local name  = UnitName("player") or ""
        local realm = GetRealmName() or ""
        realm = realm:gsub("[^%w]", "")
        local region = "us"
        if GetCurrentRegion then
            local rid = GetCurrentRegion()
            region = ({"us","kr","eu","tw","cn"})[rid] or "us"
        end
        VoidScoutDB.opt_out_requested = {
            name           = name,
            realm          = realm,
            region         = region,
            requested_at   = time(),
            source         = "VRTReader-in-game",
            attempts       = 0,
        }
        print(("|cffffd700[VRT Reader]|r Deletion requested for |cffffaa20%s-%s-%s|r. Uploader will send within ~15 min. Recordings still work locally."):format(
            name, realm, region:upper()))
        f:Hide()
    end)

    local btn_close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    btn_close:SetPoint("TOPRIGHT", -4, -4)

    f:Hide()
    dlg = f
    return f
end

local function ShowDialog()
    BuildDialog():Show()
end

----------------------------------------------------------------------
-- Slash + login trigger
----------------------------------------------------------------------
SLASH_VRTR1 = "/vrtr"
SlashCmdList["VRTR"] = function(arg)
    arg = (arg or ""):lower():match("^%s*(.-)%s*$")
    if arg == "optout" or arg == "local" then
        writeConsent("local")
        print("|cff00c7ff[VRT Reader]|r switched to LOCAL-ONLY. Recordings stay on your PC.")
        return
    end
    if arg == "optin" or arg == "allow" then
        writeConsent("allowed")
        print("|cff00c7ff[VRT Reader]|r switched to UPLOADS ENABLED.")
        return
    end
    local c = readConsent()
    if c == "allowed" then
        print("|cff00c7ff[VRT Reader]|r currently: |cff20ff20uploads ENABLED|r. To stop, |cffffd700/vrtr optout|r.")
        print("  Need the uploader? |cffffd700" .. UPLOADER_URL .. "|r")
        print("  Without the uploader running, sessions stay on this PC and never reach voidscout.io.")
    elseif c == "local" then
        print("|cff00c7ff[VRT Reader]|r currently: |cffffaa20LOCAL-ONLY|r. To allow uploads, |cffffd700/vrtr optin|r.")
    else
        print("|cff00c7ff[VRT Reader]|r no consent choice on file. Opening dialog...")
        ShowDialog()
    end
end

local f = CreateFrame("Frame", "VRTReader_ConsentLoginFrame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        if readConsent() == nil then
            -- Delay one second so the login chat dust settles before
            -- popping a fullscreen dialog at the user.
            C_Timer.After(1.0, ShowDialog)
        end
        self:UnregisterAllEvents()
    end
end)
