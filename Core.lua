----------------------------------------------------------------------
-- VoidRaidToolsReader (VRT-R)
--
-- A SIBLING diagnostic addon to VoidRaidTools. Reads hostile cast data
-- intentionally (knowing it accepts secret-value taint) and broadcasts
-- the readings to VRT via the addon chat channel. The recipient (VRT)
-- gets the data in a fresh execution context — addon messages reset
-- the taint chain per Blizzard's design.
--
-- DESIGN GOALS:
--   - No UI. No popups. No decisions. Pure read+broadcast.
--   - No SecureActionButton, no protected actions, nothing that could
--     break from being tainted. This addon is allowed to "die quietly"
--     to taint because it has nothing to protect.
--   - All reads wrapped in pcall so a malformed return doesn't kill us.
--
-- TEST GOALS:
--   - Confirm VRT's secure buttons KEEP WORKING while this addon is
--     installed and actively broadcasting tainted data.
--   - Collect data on which hostile units can be read + when.
--   - Compare what VRT-R sees vs what VRT's existing C_EncounterEvents
--     bridge sees.
----------------------------------------------------------------------

local ADDON_NAME, NS = ...
local ADDON_PREFIX = "VRT_R"

-- Forward declarations — these functions are called from the OnEvent
-- closure below but defined later in the file. Without these the OnEvent
-- closure captures GLOBAL references which resolve to nil at fire time.
local probePlaterRuntimeData
local tryPlaterCallback
local laundryTaintTest

-- Local SavedVariables for the reader itself (separate from VRT's DB so
-- we can compare side-by-side what each addon captured).
VoidRaidToolsReaderDB = VoidRaidToolsReaderDB or {}

local function getDB()
    VoidRaidToolsReaderDB.events    = VoidRaidToolsReaderDB.events    or {}
    VoidRaidToolsReaderDB.sent_count = VoidRaidToolsReaderDB.sent_count or 0
    VoidRaidToolsReaderDB.start_time = VoidRaidToolsReaderDB.start_time or time()
    return VoidRaidToolsReaderDB
end

local CAP_EVENTS = 500   -- how many local-side reads to keep for offline review

-- O(n) bulk drop instead of O(n²) repeated table.remove(t, 1). When the
-- buffer overflows we drop the oldest 10% in one shift, so the next 10%
-- of appends incur no overhead. Was tripping the watchdog at 50+ Hz.
local function _capLog(t, cap)
    local n = #t
    if n <= cap then return end
    local drop = math.floor(cap * 0.1)
    if drop < 1 then drop = 1 end
    local m = n - drop
    for i = 1, m do t[i] = t[i + drop] end
    for i = m + 1, n do t[i] = nil end
end
VoidRaidToolsReader_capLog = _capLog  -- export so IdentityProbes can reuse

local function pushCapped(t, v, cap)
    t[#t + 1] = v
    _capLog(t, cap)
end

----------------------------------------------------------------------
-- Send: WHISPER to self. SendAddonMessage on PARTY/INSTANCE_CHAT does
-- NOT echo back to the sender — so for solo testing (you in a follower
-- dungeon), we whisper to ourselves to get the message round-trip.
----------------------------------------------------------------------
local self_name -- cached
local function MyName()
    if self_name then return self_name end
    self_name = UnitName("player")
    return self_name
end

-- Send() is a no-op now. All probe data we needed has been collected;
-- the conclusion is in [[wow-12-secret-spellid-impossible]]. Keeping the
-- function as a stub so existing probe call sites don't need editing —
-- they just do nothing. POLY_INCOMING broadcasts go directly via
-- C_ChatInfo.SendAddonMessage, not through Send.
local function Send(kind, body)
    -- intentionally no-op
end

----------------------------------------------------------------------
-- Reader: hostile cast events
--
-- We deliberately call UnitCastingInfo + UnitChannelInfo on tainted
-- units. We expect to accept secret-tainted return values. Our pcall
-- protects against API errors, not taint propagation — taint will flow
-- into this addon and stay here.
----------------------------------------------------------------------
local function readCastInfo(unit)
    local ok, name, _, _, startMS, endMS, _, castID, notInt, spellID = pcall(UnitCastingInfo, unit)
    if not ok then return nil end
    if name then
        return {
            kind = "cast",
            name = name,
            spell_id = spellID,
            cast_id = castID,
            start_ms = startMS,
            end_ms = endMS,
            not_int = notInt,
        }
    end
    -- Not casting — try channel
    local ok2, cname, _, _, cstart, cend, _, cnotInt, cspellID = pcall(UnitChannelInfo, unit)
    if not ok2 then return nil end
    if cname then
        return {
            kind = "channel",
            name = cname,
            spell_id = cspellID,
            start_ms = cstart,
            end_ms = cend,
            not_int = cnotInt,
        }
    end
    return nil
end

----------------------------------------------------------------------
-- PROBE HELPERS — return CLEAN string status codes regardless of input
----------------------------------------------------------------------
local function statusOf(ok, v)
    if not ok then return "err" end
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "secret" end
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then
        -- Sanitize: rounding so the number-as-string is safe and short
        local r = math.floor(v * 1000) / 1000
        return tostring(r)
    end
    if type(v) == "string" then
        -- A string from a clean source is fine; from a secret could still
        -- be tagged. Guard with a length sanity check and strip pipes/^.
        local s = v:gsub("[|^]", "_"):sub(1, 32)
        return "str:" .. s
    end
    return "type:" .. type(v)
end

-- Convert any incoming event arg to a safe clean string for ferrying.
-- nil → "?", secret → "secret", clean → sanitized string.
local function safeStr(v, maxlen)
    if v == nil then return "?" end
    if issecretvalue and issecretvalue(v) then return "secret" end
    if type(v) ~= "string" then
        local ok, s = pcall(tostring, v)
        if not ok then return "errstr" end
        v = s
    end
    -- If tostring returned something secret-tagged (e.g. tostring(secret))
    if issecretvalue and issecretvalue(v) then return "secret" end
    local ok2, sanitized = pcall(function()
        return v:gsub("[|^]", "_"):sub(1, maxlen or 64)
    end)
    if not ok2 then return "gsubthrew" end
    return sanitized
end

local function probeField(t, k)
    if not t then return "no_table" end
    local ok, v = pcall(function() return t[k] end)
    return statusOf(ok, v)
end

local function probeMethod(t, m)
    if not t or not t[m] then return "no_method" end
    local ok, v = pcall(t[m], t)
    return statusOf(ok, v)
end

-- NEW PROBE: try reading cast bar TEXTURE assets. Blizzard may use
-- different texture paths for important vs uninterruptible vs normal.
local function probeTexture(t)
    if not t then return "no_tex" end
    local ok, v = pcall(t.GetTexture, t)
    if not ok then return "err" end
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "secret" end
    return "str:" .. tostring(v):gsub("[|^]", "_"):sub(1, 64)
end

-- NEW PROBE: try reading status bar color (interruptible vs not might differ)
local function probeBarColor(sb)
    if not sb then return "no_sb" end
    local ok, r, g, b = pcall(sb.GetStatusBarColor, sb)
    if not ok then return "err" end
    return ("r=%.2f,g=%.2f,b=%.2f"):format(r or 0, g or 0, b or 0)
end

-- NEW PROBE 7: try alternate unit tokens (focus / mouseover / target)
local function probeAlternateTokens()
    local parts = {}
    for _, tok in ipairs({ "target", "mouseover", "focus", "targettarget" }) do
        if UnitExists(tok) and UnitCanAttack("player", tok) then
            local ok, name, _, _, _, _, _, _, notInt, spellID = pcall(UnitCastingInfo, tok)
            if not ok then
                parts[#parts+1] = tok .. "=err"
            else
                local name_s = statusOf(true, name)
                local sid_s = statusOf(true, spellID)
                parts[#parts+1] = tok .. ":name=" .. name_s .. ",sid=" .. sid_s
            end
        end
    end
    if #parts == 0 then return "none_present" end
    return table.concat(parts, "|")
end

-- NEW PROBE 8: GameTooltip:SetUnit scrape
local function probeTooltipScrape(unit)
    if not GameTooltip then return "no_tooltip" end
    local ok = pcall(GameTooltip.SetOwner, GameTooltip, UIParent, "ANCHOR_NONE")
    if not ok then return "owner_err" end
    local ok2 = pcall(GameTooltip.SetUnit, GameTooltip, unit)
    if not ok2 then return "setunit_err" end
    local parts = {}
    for i = 1, 4 do
        local fs = _G["GameTooltipTextLeft" .. i]
        if fs then
            local ok3, t = pcall(fs.GetText, fs)
            if ok3 and t and not (issecretvalue and issecretvalue(t)) then
                local clean = tostring(t):gsub("[|^]", "_"):sub(1, 32)
                parts[#parts+1] = "L" .. i .. "=" .. clean
            else
                parts[#parts+1] = "L" .. i .. "=" .. statusOf(ok3, t)
            end
        end
    end
    pcall(GameTooltip.Hide, GameTooltip)
    if #parts == 0 then return "empty" end
    return table.concat(parts, ",")
end

-- NEW PROBE 9: direct slot-1 aura read on player (not just predicate)
local function probePlayerAuraSlot1()
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return "no_api" end
    local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HARMFUL")
    if not ok then return "err" end
    if data == nil then return "nil" end
    if issecretvalue and issecretvalue(data) then return "secret_data" end
    -- data is a table — try to read spellID
    local ok2, sid = pcall(function() return data.spellId end)
    if not ok2 then return "spellid_err" end
    if sid == nil then return "spellid_nil" end
    if issecretvalue and issecretvalue(sid) then return "spellid_secret" end
    return "sid=" .. tostring(sid)
end

-- PROBE 1+5+6: walk the nameplate frame thoroughly
local function inspectCastBar(unit)
    local ok_pf, pf = pcall(function()
        return C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    end)
    if not ok_pf or not pf then return "noframe" end

    local castBar, mobName
    pcall(function()
        local uf = pf.UnitFrame
        if uf and uf.castBar then castBar = uf.castBar
        elseif pf.castBar then castBar = pf.castBar
        elseif uf and uf.CastingBar then castBar = uf.CastingBar
        end
        -- mob name from displayed FontString (not UnitName which is secret)
        if uf and uf.name then mobName = uf.name end
    end)

    local parts = {}
    -- Standard props (already tested)
    parts[#parts+1] = "barType=" .. probeField(castBar, "barType")
    parts[#parts+1] = "imp="     .. probeField(castBar, "isHighlightedImportantCast")
    parts[#parts+1] = "val="     .. probeMethod(castBar, "GetValue")

    -- NEW PROBE 4: ImportantCastFlashAnim direct check
    local flashAnim
    pcall(function() flashAnim = castBar and castBar.ImportantCastFlashAnim end)
    parts[#parts+1] = "flash="   .. probeMethod(flashAnim, "IsPlaying")

    -- NEW PROBE 1: FontString text reads on the cast bar
    local castText
    pcall(function() castText = castBar and castBar.Text end)
    if castText then
        local ok, t = pcall(castText.GetText, castText)
        if not ok then parts[#parts+1] = "castTxt=err"
        elseif t == nil then parts[#parts+1] = "castTxt=nil"
        elseif issecretvalue and issecretvalue(t) then parts[#parts+1] = "castTxt=secret"
        else
            -- Sanitize and truncate
            local clean = tostring(t):gsub("[|^]", "_"):sub(1, 24)
            parts[#parts+1] = "castTxt=" .. clean
        end
    else
        parts[#parts+1] = "castTxt=noText"
    end

    -- NEW PROBE 5: mob name FontString text read
    if mobName then
        local ok, t = pcall(mobName.GetText, mobName)
        if not ok then parts[#parts+1] = "mobName=err"
        elseif t == nil then parts[#parts+1] = "mobName=nil"
        elseif issecretvalue and issecretvalue(t) then parts[#parts+1] = "mobName=secret"
        else
            local clean = tostring(t):gsub("[|^]", "_"):sub(1, 24)
            parts[#parts+1] = "mobName=" .. clean
        end
    else
        parts[#parts+1] = "mobName=noName"
    end

    return table.concat(parts, ",")
end

----------------------------------------------------------------------
-- LAUNDER PROBE — Plater pattern: secret key + clean table = clean result?
--   Plater does cast_colors[secret_spellID] and gets back hardcoded RGB
--   values that drive its visual highlighting. We replicate the mechanism
--   to see if table lookup launders the secret-tainted spellID into a
--   clean returned value we can ferry across the wire.
--
--   Three tests run per cast:
--     L1) Direct lookup in a hand-built priority-spells table
--         (catches a hit if MT trash happens to cast one of these IDs)
--     L2) Metatable __index returning a clean literal for ANY key
--         (universal — if this returns a clean string, the mechanism works)
--     L3) Arithmetic in __index (test if the secret key still throws
--         inside the metamethod body)
----------------------------------------------------------------------

-- Curated priority kicks (sample from VRT priority list — non-exhaustive,
-- just enough for occasional real-match hits during MT). Spell ID -> clean tag.
local PRIORITY_KICKS_PROBE = {
    -- MT bosses
    [248831] = "DREAD_SCREECH",
    [244750] = "MIND_BLAST",
    [263959] = "FELBOLT",
    [263914] = "DELIBERATE_LIGHTNING",
    -- Common interruptible casts across many dungeons
    [118]    = "POLYMORPH",
    [605]    = "MIND_CONTROL",
    [8122]   = "PSYCHIC_SCREAM",
    [1604]   = "DAZED",
    [122]    = "FROST_NOVA",
    -- Heals
    [2061]   = "FLASH_HEAL",
    [2060]   = "GREATER_HEAL",
    [596]    = "PRAYER_OF_HEALING",
    -- Generic Midnight-era trash threats
    [1218015] = "VOID_BOLT_TRASH",
    [1217712] = "MASS_RESTORE",
    [1218011] = "AETHER_LANCE",
}

-- Catch-all metatable that returns a clean literal for ANY key.
-- If this works, we don't need to enumerate spell IDs — every cast yields
-- a clean signal we can ferry.
local LAUNDER_CATCH_MT = {
    __index = function(_, _) return "CAUGHT_CLEAN" end,
}
local LAUNDER_CATCH = setmetatable({}, LAUNDER_CATCH_MT)

-- Catch-all that does ARITHMETIC inside __index using the key. Tests
-- whether secret values are usable inside metamethod bodies.
local LAUNDER_ARITH_MT = {
    __index = function(_, k)
        local ok, r = pcall(function() return (k or 0) + 1 end)
        if not ok then return "ARITH_THREW" end
        return "ARITH_OK_" .. tostring(r):sub(1, 16)
    end,
}
local LAUNDER_ARITH = setmetatable({}, LAUNDER_ARITH_MT)

local function probeLaunder(unit)
    -- Grab the secret spellID fresh
    local ok_uci, _, _, _, _, _, _, _, _, sid = pcall(UnitCastingInfo, unit)
    if not ok_uci then return "uci_err" end
    if sid == nil then return "sid_nil" end

    local parts = {}

    -- L1: direct lookup in curated table
    local ok1, r1 = pcall(function() return PRIORITY_KICKS_PROBE[sid] end)
    if not ok1 then
        parts[#parts+1] = "L1=THREW"
    elseif r1 == nil then
        parts[#parts+1] = "L1=miss"
    else
        local taint_tag = (issecretvalue and issecretvalue(r1)) and "SEC" or "CLEAN"
        parts[#parts+1] = "L1=" .. taint_tag .. "_" .. tostring(r1):sub(1, 24)
    end

    -- L2: metatable __index catch-all
    local ok2, r2 = pcall(function() return LAUNDER_CATCH[sid] end)
    if not ok2 then
        parts[#parts+1] = "L2=THREW"
    elseif r2 == nil then
        parts[#parts+1] = "L2=nil"
    else
        local taint_tag = (issecretvalue and issecretvalue(r2)) and "SEC" or "CLEAN"
        parts[#parts+1] = "L2=" .. taint_tag .. "_" .. tostring(r2):sub(1, 24)
    end

    -- L3: metatable __index that does arithmetic with the secret key
    local ok3, r3 = pcall(function() return LAUNDER_ARITH[sid] end)
    if not ok3 then
        parts[#parts+1] = "L3=THREW"
    elseif r3 == nil then
        parts[#parts+1] = "L3=nil"
    else
        local taint_tag = (issecretvalue and issecretvalue(r3)) and "SEC" or "CLEAN"
        parts[#parts+1] = "L3=" .. taint_tag .. "_" .. tostring(r3):sub(1, 24)
    end

    -- L4: integer comparison using secret as right-hand operand
    --   tests whether secret can survive type/equality checks
    local ok4, r4 = pcall(function() return sid == 248831 end)
    if not ok4 then
        parts[#parts+1] = "L4=THREW"
    else
        local taint_tag = (issecretvalue and issecretvalue(r4)) and "SEC" or "CLEAN"
        parts[#parts+1] = "L4=" .. taint_tag .. "_" .. tostring(r4)
    end

    return table.concat(parts, "^")
end

----------------------------------------------------------------------
-- BATCH MORE-PROBES — everything else we haven't tried
----------------------------------------------------------------------

-- A) Built-in type/numeric conversion launders
local function probeBuiltinLaunder(sid)
    local parts = {}
    -- A1: tonumber
    local ok, r = pcall(tonumber, sid)
    parts[#parts+1] = "tonum=" .. statusOf(ok, r)
    -- A2: string.format with %d
    local ok2, r2 = pcall(string.format, "%d", sid)
    parts[#parts+1] = "fmt=" .. statusOf(ok2, r2)
    -- A3: math.floor
    local ok3, r3 = pcall(math.floor, sid)
    parts[#parts+1] = "floor=" .. statusOf(ok3, r3)
    -- A4: bit.band
    if _G.bit and bit.band then
        local ok4, r4 = pcall(bit.band, sid, 0xFFFFFFFF)
        parts[#parts+1] = "band=" .. statusOf(ok4, r4)
    else
        parts[#parts+1] = "band=no_bit_lib"
    end
    -- A5: math.abs
    local ok5, r5 = pcall(math.abs, sid)
    parts[#parts+1] = "abs=" .. statusOf(ok5, r5)
    -- A6: type()
    local ok6, r6 = pcall(type, sid)
    parts[#parts+1] = "type=" .. statusOf(ok6, r6)
    return table.concat(parts, "|")
end

-- B) C_Spell API probes with secret sid as input
local function probeCSpellAPIs(sid)
    local parts = {}
    if C_Spell then
        if C_Spell.IsSpellImportant then
            local ok, r = pcall(C_Spell.IsSpellImportant, sid)
            parts[#parts+1] = "imp=" .. statusOf(ok, r)
        end
        if C_Spell.GetSpellName then
            local ok, r = pcall(C_Spell.GetSpellName, sid)
            parts[#parts+1] = "name=" .. statusOf(ok, r)
        end
        if C_Spell.GetSpellInfo then
            local ok, r = pcall(C_Spell.GetSpellInfo, sid)
            -- returns a table — probe spellID inside it
            if ok and type(r) == "table" then
                local ok2, sid2 = pcall(function() return r.spellID end)
                parts[#parts+1] = "info.sid=" .. statusOf(ok2, sid2)
            else
                parts[#parts+1] = "info=" .. statusOf(ok, r)
            end
        end
        if C_Spell.GetSpellTexture then
            local ok, r = pcall(C_Spell.GetSpellTexture, sid)
            parts[#parts+1] = "tex=" .. statusOf(ok, r)
        end
        if C_Spell.IsSpellHarmful then
            local ok, r = pcall(C_Spell.IsSpellHarmful, sid)
            parts[#parts+1] = "harm=" .. statusOf(ok, r)
        end
    end
    if _G.IsHelpfulSpell then
        local ok, r = pcall(_G.IsHelpfulSpell, sid)
        parts[#parts+1] = "isHelp=" .. statusOf(ok, r)
    end
    if _G.IsHarmfulSpell then
        local ok, r = pcall(_G.IsHarmfulSpell, sid)
        parts[#parts+1] = "isHarm=" .. statusOf(ok, r)
    end
    if #parts == 0 then return "no_apis" end
    return table.concat(parts, "|")
end

-- C0) Third-party API probes with secret sid as input.
--   Plater.IsSpellInterruptable, DBM:GetAltSpellName, BigWigsAPI.GetSpellRename.
--   These all do table lookups internally. If ANY of them tolerates a secret
--   key (Blizzard could whitelist), we win.
local function probeThirdPartyAPIs(sid)
    local parts = {}
    if _G.Plater and Plater.IsSpellInterruptable then
        local ok, r = pcall(Plater.IsSpellInterruptable, sid)
        parts[#parts+1] = "plater_int=" .. statusOf(ok, r)
    end
    if _G.DBM and DBM.GetAltSpellName then
        local ok, r = pcall(DBM.GetAltSpellName, DBM, sid)
        parts[#parts+1] = "dbm_alt=" .. statusOf(ok, r)
    end
    if _G.BigWigsAPI and BigWigsAPI.GetSpellRename then
        local ok, r = pcall(BigWigsAPI.GetSpellRename, sid)
        parts[#parts+1] = "bw_rename=" .. statusOf(ok, r)
    end
    if #parts == 0 then return "no_apis" end
    return table.concat(parts, "|")
end

-- C) GameTooltip:SetSpellByID + FontString scrape — DISABLED
--   This path goes through C_TooltipInfo.GetSpellByID inside
--   securecallfunction, which validates the spell ID and throws "bad
--   argument" on secret-tainted input. The error ESCAPES our outer pcall
--   because securecallfunction has its own error reporting boundary.
--   Calling this on a secret sid triggers a Blizzard error pop-up for
--   the user. Hard-disabled to avoid that.
local function probeTooltipSpell(sid)
    return "disabled_securecall_escapes_pcall"
end

-- D) Recursive frame walk on nameplate (one extra level deeper)
local function probeNameplateChildren(unit)
    local pf = C_NamePlate and C_NamePlate.GetNamePlateForUnit
        and C_NamePlate.GetNamePlateForUnit(unit)
    if not pf then return "noframe" end
    local parts = {}
    local function walk(frame, prefix, depth)
        if depth > 3 then return end
        local ok, children = pcall(frame.GetChildren, frame)
        if not ok or not children then return end
        local n = select("#", children) or 0
        local args = { children }
        for i = 1, math.min(n, 8) do
            local c = args[i]
            if c then
                local name = "?"
                pcall(function() name = c.GetName and c:GetName() or "(noname)" end)
                local objType = "?"
                pcall(function() objType = c.GetObjectType and c:GetObjectType() or "?" end)
                parts[#parts+1] = prefix .. (name or "?") .. ":" .. objType
                walk(c, prefix .. "/" .. (name or "?"), depth + 1)
            end
        end
    end
    pcall(walk, pf, "", 0)
    if #parts == 0 then return "empty" end
    return table.concat(parts, "|"):sub(1, 200)
end

-- UCI field-by-field taint probe
--   UnitCastingInfo returns 9 values. We know spellId (9th) is secret.
--   This probe captures the taint status of EACH return individually,
--   so we can see which fields might still be clean (esp. notInterruptible).
local function probeUCIFields(unit)
    local ok, name, text, texture, st, et, isTrade, castID, notInt, sid =
        pcall(UnitCastingInfo, unit)
    if not ok then return "uci_threw" end
    -- Each statusOf call is pcall-safe. We tag each field separately.
    return ("name=%s|text=%s|tex=%s|st=%s|et=%s|trade=%s|castID=%s|notInt=%s|sid=%s"):format(
        statusOf(true, name),
        statusOf(true, text),
        statusOf(true, texture),
        statusOf(true, st),
        statusOf(true, et),
        statusOf(true, isTrade),
        statusOf(true, castID),
        statusOf(true, notInt),
        statusOf(true, sid)
    )
end

-- Also probe UnitChannelInfo (different return shape)
local function probeChannelFields(unit)
    local ok, name, text, texture, st, et, isTrade, notInt, sid =
        pcall(UnitChannelInfo, unit)
    if not ok then return "uch_threw" end
    if name == nil then return "uch_no_channel" end
    return ("ch_name=%s|ch_notInt=%s|ch_sid=%s"):format(
        statusOf(true, name),
        statusOf(true, notInt),
        statusOf(true, sid)
    )
end

-- PROBE 3: PlayerIsSpellTarget on the casting unit
local function probePlayerIsSpellTarget(unit)
    if not _G.PlayerIsSpellTarget then return "no_api" end
    local ok, v = pcall(_G.PlayerIsSpellTarget, unit)
    return statusOf(ok, v)
end

-- E) Plater function enumeration (boot-time, one-shot).
--    Lists every Plater.* function we can call. Look for any that takes
--    a unit and returns cast info — those would be a clean accessor.
local function probePlaterFunctions()
    if not _G.Plater then return "no_plater" end
    local fns = {}
    local ok = pcall(function()
        for k, v in pairs(Plater) do
            if type(v) == "function" then
                -- Filter to cast-related names
                local kl = k:lower()
                if kl:find("cast") or kl:find("spell") or kl:find("interrupt")
                   or kl:find("kick") or kl:find("important") then
                    fns[#fns+1] = k
                end
            end
        end
    end)
    if not ok then return "iter_err" end
    if #fns == 0 then return "no_cast_funcs" end
    -- Bump truncation; broadcast in chunks if needed (addon msg limit ~240b)
    local joined = table.concat(fns, ",")
    return joined:sub(1, 230)
end

-- E2) PlaterDB.InterruptableSpells inventory + IsSpellInterruptable probe.
--    Tells us: how many spell IDs Plater has cached as interruptable,
--    and whether the lookup throws when fed a secret sid.
local function probePlaterInterruptDB()
    if not _G.PlaterDB then return "no_PlaterDB" end
    local count = 0
    local sample = {}
    pcall(function()
        if PlaterDB.InterruptableSpells then
            for sid, _ in pairs(PlaterDB.InterruptableSpells) do
                count = count + 1
                if count <= 5 then sample[#sample+1] = tostring(sid) end
            end
        end
    end)
    -- Try Plater.IsSpellInterruptable with a known clean ID (control)
    local clean_test = "no_fn"
    if Plater and Plater.IsSpellInterruptable then
        local ok, r = pcall(Plater.IsSpellInterruptable, 248831)  -- known kick
        clean_test = "clean_input=" .. statusOf(ok, r)
    end
    return ("count=%d|sample=%s|%s"):format(
        count, table.concat(sample, ","), clean_test
    )
end

-- F) SavedVariables launder check (boot-time).
--    Last session we saved a value (which was the launder probe result).
--    Now check if any stored values from prior session have taint tags.
--    Also seed a fresh secret-tagged value during a cast (if we can capture
--    one) to test on the NEXT reload.
local function probeSavedVarsLaunder()
    if not VoidRaidToolsReaderDB then return "no_db" end
    local db = VoidRaidToolsReaderDB
    local parts = {}
    -- Check if last_secret_seed survived reload
    if db.last_secret_seed ~= nil then
        local v = db.last_secret_seed
        if issecretvalue and issecretvalue(v) then
            parts[#parts+1] = "seed=STILL_SECRET"
        else
            local ok, str = pcall(tostring, v)
            if ok then parts[#parts+1] = "seed=CLEAN_" .. tostring(str):sub(1, 32)
            else parts[#parts+1] = "seed=cleanish_err" end
        end
    else
        parts[#parts+1] = "seed=none"
    end
    -- Check launder_runs counter
    parts[#parts+1] = "runs=" .. tostring(db.launder_runs or 0)
    return table.concat(parts, "|")
end

-- Try to seed a secret-tainted value into SavedVariables on first cast
-- captured during this session, so next reload can check it.
local function seedSecretToSavedVars(unit)
    if not VoidRaidToolsReaderDB then return end
    local db = VoidRaidToolsReaderDB
    if db.last_secret_seed_at == nil or (time() - db.last_secret_seed_at) > 120 then
        local _, _, _, _, _, _, _, _, _, sid = pcall(UnitCastingInfo, unit)
        if sid ~= nil then
            -- Just write the raw value. If serialization launders, we'll see
            -- it as clean on next reload. If not, it stays secret-tagged.
            db.last_secret_seed = sid
            db.last_secret_seed_at = time()
            db.launder_runs = (db.launder_runs or 0) + 1
        end
    end
end

local function snapshot(unit)
    if not UnitExists(unit) then return end
    if not UnitCanAttack("player", unit) then return end

    -- Taint exposure — read secret data on purpose
    pcall(UnitCastingInfo, unit)
    pcall(UnitChannelInfo, unit)

    -- LAUNDER PROBE FIRST — the Plater pattern test. Other probes
    -- (tooltip scrape, aura reads, alt unit tokens) have been observed
    -- to throw uncaught, killing the snapshot mid-flight. Run LAUNDER
    -- first so we always get its result.
    local launder_ok, launder_result = pcall(probeLaunder, unit)
    if not launder_ok then
        Send("LAUNDER", unit .. "^OUTER_THREW")
    else
        Send("LAUNDER", unit .. "^" .. (launder_result or "nil"))
    end

    -- UCI/UCH field-by-field taint map. Answers: is notInterruptible
    -- clean? Are timestamps clean? Is the cast bar name secret? etc.
    pcall(function()
        Send("UCI_FIELDS", unit .. "^" .. probeUCIFields(unit))
    end)
    pcall(function()
        Send("UCH_FIELDS", unit .. "^" .. probeChannelFields(unit))
    end)

    -- BATCH MORE-PROBES — everything else untested.
    -- Don't pre-check sid for nil (truthy check on secret may throw) —
    -- probe functions handle nil internally via their own pcalls.
    local _, _, _, _, _, _, _, _, _, sid_for_more = pcall(UnitCastingInfo, unit)
    pcall(function()
        Send("MORE_BUILTIN", unit .. "^" .. probeBuiltinLaunder(sid_for_more))
    end)
    pcall(function()
        Send("MORE_CSPELL", unit .. "^" .. probeCSpellAPIs(sid_for_more))
    end)
    pcall(function()
        Send("MORE_TTSPELL", unit .. "^" .. probeTooltipSpell(sid_for_more))
    end)
    pcall(function()
        Send("MORE_3RDPARTY", unit .. "^" .. probeThirdPartyAPIs(sid_for_more))
    end)
    pcall(function()
        Send("MORE_NPLATE", unit .. "^" .. probeNameplateChildren(unit))
    end)

    -- Seed a secret-tainted spellID into SavedVariables so next /reload
    -- can check whether serialization launders the taint tag.
    pcall(seedSecretToSavedVars, unit)

    -- IMMEDIATE probe (each wrapped to localize crashes)
    pcall(function()
        local cbar0 = inspectCastBar(unit)
        local pist = probePlayerIsSpellTarget(unit)
        Send("PROBE", unit .. "^t=0^" .. cbar0 .. "^pist=" .. pist)
    end)

    -- DELAYED probes — let Blizzard's UI populate the cast bar fields
    C_Timer.After(0.05, function()
        if UnitExists(unit) then
            pcall(function()
                Send("PROBE", unit .. "^t=50^" .. inspectCastBar(unit))
            end)
        end
    end)
    C_Timer.After(0.2, function()
        if UnitExists(unit) then
            pcall(function()
                Send("PROBE", unit .. "^t=200^" .. inspectCastBar(unit))
            end)
        end
    end)

    -- NEW BATCH probes — each wrapped individually
    pcall(function()
        Send("ALT_TOK", unit .. "^" .. probeAlternateTokens())
    end)
    pcall(function()
        local pf = C_NamePlate and C_NamePlate.GetNamePlateForUnit
            and C_NamePlate.GetNamePlateForUnit(unit)
        if pf and pf.UnitFrame and pf.UnitFrame.castBar then
            local cb = pf.UnitFrame.castBar
            local icon = cb.Icon
            local shield = cb.BorderShield
            local sb_tex = cb.GetStatusBarTexture and cb:GetStatusBarTexture()
            Send("VISUAL", unit .. "^iconTex=" .. probeTexture(icon)
                .. "^shieldTex=" .. probeTexture(shield)
                .. "^barTex=" .. probeTexture(sb_tex)
                .. "^color=" .. probeBarColor(cb))
        end
    end)
    pcall(function()
        Send("TOOLTIP", unit .. "^" .. probeTooltipScrape(unit))
    end)
    pcall(function()
        Send("AURA1", "player^" .. probePlayerAuraSlot1())
    end)

    local d = getDB()
    d.snapshot_count = (d.snapshot_count or 0) + 1
end

local function snapshotEnd(unit, why)
    -- All inputs here are clean Lua literals — unit is a fixed token
    -- string, why is one of "stop"/"interrupted"/"success"/"failed".
    Send("END", (unit or "?") .. "^" .. (why or "?"))
end

----------------------------------------------------------------------
-- Event frame — hostile cast lifecycle
----------------------------------------------------------------------
local frame = CreateFrame("Frame", "VRT_Reader_EventFrame")

-- RegisterUnitEvent only accepts up to 8 unit ids per call. With ~45
-- units (5 boss + 40 nameplate), the extras get silently ignored.
-- Use plain RegisterEvent and filter by unit pattern in the handler.
local function registerHostileUnitEvents()
    for _, ev in ipairs({
        "UNIT_SPELLCAST_START",
        "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_STOP",
        "UNIT_SPELLCAST_CHANNEL_STOP",
        "UNIT_SPELLCAST_INTERRUPTED",
        "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_FAILED",
        -- PROBE 2: interruptibility state change events. We don't
        -- need the spell ID — just knowing "this unit is now kickable"
        -- is signal enough for a generic alert.
        "UNIT_SPELLCAST_INTERRUPTIBLE",
        "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
        -- NEW PROBE 3: trash mob telegraphs sometimes use these chat
        -- channels. Strings here are usually clean (different code path
        -- than CLEU/UnitCastingInfo).
        "CHAT_MSG_MONSTER_EMOTE",
        "CHAT_MSG_MONSTER_SAY",
        "CHAT_MSG_MONSTER_YELL",
        "CHAT_MSG_RAID_BOSS_EMOTE",
        "CHAT_MSG_RAID_BOSS_WHISPER",
        -- NEW PROBES (extra batch):
        "CHAT_MSG_ADDON",       -- listen to all other addons' broadcasts
        "PLAYER_CONTROL_LOST",  -- when we get CC'd
        "PLAYER_CONTROL_GAINED",
        "COMBAT_TEXT_UPDATE",   -- scrolling combat text
        "UI_INFO_MESSAGE",      -- system info messages
        "UI_ERROR_MESSAGE",     -- system error messages
        "UPDATE_MOUSEOVER_UNIT",
        -- Nameplate lifecycle — clears stale cast buffer on disappear.
        "NAME_PLATE_UNIT_REMOVED",
        "NAME_PLATE_UNIT_ADDED",
        -- Player aura — fires whenever you gain/lose a buff or debuff.
        -- When Polymorph (or any CC) LANDS on you, we capture the
        -- clean spell ID via slot 1 of HARMFUL filter.
        "UNIT_AURA",
    }) do
        frame:RegisterEvent(ev)
    end
end

----------------------------------------------------------------------
-- MAGISTER POLY DETECTOR
--   Watches per-nameplate UNIT_SPELLCAST_START events. Detects the
--   Arcane Magister signature: 3 casts within ~12 seconds with short
--   intervals (~3-5s each). When detected, fires a loud alert predicting
--   the NEXT cast will be Polymorph.
--
--   No taint risk — only uses CLEAN unit token + CLEAN timestamps. No
--   reads of UnitCastingInfo / spell IDs.
----------------------------------------------------------------------
----------------------------------------------------------------------
-- DURATION-BASED MAGISTER POLY DETECTOR
--
-- Combat log analysis (44 ABs vs 6 Polys observed) showed:
--   Arcane Bolt (filler) cast time: 2.44-2.55s (avg 2.49s)
--   Polymorph (kick) cast time:     3.47-3.50s (avg 3.49s)
-- Clean 0.92-second gap between when AB completes and Poly is still
-- casting. We exploit this to IDENTIFY THE SPELL instead of guessing:
--
--   UNIT_SPELLCAST_START on hostile nameplate -> start 2.6s timer
--   UNIT_SPELLCAST_STOP/SUCCEEDED/INTERRUPTED -> cancel timer
--   Timer fires (cast still ongoing at 2.6s) -> THIS IS POLYMORPH
--   Flash NOW. User has ~0.85s to Mind Freeze (instant cast).
----------------------------------------------------------------------

local POLY_DETECT_THRESHOLD = 2.6   -- past AB (2.55 max), before Poly (3.47 min)

local active_casts = {}  -- unit_token -> { timer, start_ts }

local function cancelDetectorTimer(unit)
    local entry = active_casts[unit]
    if entry then
        if entry.timer then
            pcall(entry.timer.Cancel, entry.timer)
        end
        local elapsed = entry.start_ts and (GetTime() - entry.start_ts) or 0
        local d = getDB()
        d.detector_log = d.detector_log or {}
        table.insert(d.detector_log, {
            at = time(), unit = unit, action = "canceled",
            extra = string.format("elapsed=%.2f", elapsed),
        })
        _capLog(d.detector_log, 500)
    end
    active_casts[unit] = nil
end

-- Reset per-nameplate state when the nameplate disappears.
local function clearNameplateState(unit)
    cancelDetectorTimer(unit)
end

-- Cancel detector when cast ends (interrupted/succeeded/stop/failed).
local function disarmNameplate(unit)
    cancelDetectorTimer(unit)
end

-- Debug log: records every detector decision so we can see what's happening.
local function detLog(unit, action, extra)
    local d = getDB()
    d.detector_log = d.detector_log or {}
    table.insert(d.detector_log, {
        at = time(), unit = unit, action = action, extra = extra or ""
    })
    _capLog(d.detector_log, 500)
end

-- TARGET-OF-TARGET PROBE
--   Read who the hostile is currently targeting. If the target is a
--   friendly player, UnitName resolves cleanly (player names are never
--   secret). Hypothesis: Polymorph targets a non-tank; Arcane Bolt
--   targets the tank. Captured at every UNIT_SPELLCAST_START.
local function probeHostileTarget(unit)
    local d = getDB()
    d.target_probe = d.target_probe or {}
    local tot = unit .. "target"  -- e.g. "nameplate3target"
    local entry = { at = time(), gt = GetTime(), unit = unit }
    pcall(function() entry.tot_exists = UnitExists(tot) end)
    pcall(function() entry.tot_name = UnitName(tot) end)
    pcall(function() entry.tot_is_player = UnitIsPlayer(tot) end)
    pcall(function() entry.tot_is_self = UnitIsUnit(tot, "player") end)
    pcall(function() entry.tot_role = UnitGroupRolesAssigned(tot) end)
    pcall(function()
        local _, classfile = UnitClass(tot)
        entry.tot_class = classfile
    end)
    -- Sanitize secret-tainted strings via the safeStr helper
    if entry.tot_name then entry.tot_name = safeStr(entry.tot_name, 32) end
    if entry.tot_role then entry.tot_role = safeStr(entry.tot_role, 16) end
    if entry.tot_class then entry.tot_class = safeStr(entry.tot_class, 16) end
    table.insert(d.target_probe, entry)
    _capLog(d.target_probe, 500)
end

local function onNameplateCast(unit)
    if type(unit) ~= "string" then return end
    if not unit:find("^nameplate%d+$") then
        detLog(tostring(unit), "skip_not_nameplate")
        return
    end
    -- New: probe target-of-target BEFORE any other logic.
    pcall(probeHostileTarget, unit)
    -- DEFAULT NAMEPLATE PROBE: with Plater DISABLED, the Blizzard default
    -- cast bar widget is active and unmodified. We can read:
    --   castBar:GetHeight()  -- bar geometry (clean float)
    --   castBar.isHighlightedImportantCast  -- Blizzard's boolean
    --   castBar.ImportantCastIndicator:IsShown()  -- glow halo visibility
    --   castBar.ImportantCastFlashAnim:IsPlaying()  -- alpha pulse
    pcall(function()
        local pf = C_NamePlate and C_NamePlate.GetNamePlateForUnit
            and C_NamePlate.GetNamePlateForUnit(unit)
        if pf and pf.UnitFrame and pf.UnitFrame.castBar then
            local cb = pf.UnitFrame.castBar
            local d = getDB()
            d.default_castbar_probe = d.default_castbar_probe or {}
            local entry = { at = time(), gt = GetTime(), unit = unit }
            -- 1) GEOMETRY — the cleanest possible signal
            pcall(function() entry.height = cb:GetHeight() end)
            pcall(function() entry.width  = cb:GetWidth() end)
            pcall(function() entry.scale  = cb:GetScale() end)
            pcall(function() entry.alpha  = cb:GetAlpha() end)
            -- 2) Blizzard's isHighlightedImportantCast field
            entry.imp_flag = statusOf(true, cb.isHighlightedImportantCast)
            entry.bar_type = statusOf(true, cb.barType)
            -- 3) ImportantCastIndicator (the glow halo texture)
            pcall(function()
                if cb.ImportantCastIndicator then
                    entry.ind_shown = cb.ImportantCastIndicator:IsShown() and "true" or "false"
                    entry.ind_alpha = cb.ImportantCastIndicator:GetAlpha()
                    entry.ind_atlas = (cb.ImportantCastIndicator.GetAtlas and cb.ImportantCastIndicator:GetAtlas()) or "?"
                else
                    entry.ind_shown = "no_indicator"
                end
            end)
            -- 4) ImportantCastFlashAnim (alpha pulse animation)
            pcall(function()
                if cb.ImportantCastFlashAnim then
                    entry.flash_playing = cb.ImportantCastFlashAnim:IsPlaying() and "true" or "false"
                else
                    entry.flash_playing = "no_anim"
                end
            end)
            -- 5) Probe Plater's DF field too (will be nil if Plater disabled)
            entry.is_important_lower = statusOf(true, cb.isImportant)
            table.insert(d.default_castbar_probe, entry)
            _capLog(d.default_castbar_probe, 200)
        end
    end)
    cancelDetectorTimer(unit)
    local start_ts = GetTime()
    local entry = { start_ts = start_ts }
    active_casts[unit] = entry
    detLog(unit, "armed", string.format("threshold=%.2f", POLY_DETECT_THRESHOLD))
    entry.timer = C_Timer.NewTimer(POLY_DETECT_THRESHOLD, function()
        if active_casts[unit] ~= entry then
            detLog(unit, "timer_fired_but_stale")
            return
        end
        active_casts[unit] = nil
        local elapsed = GetTime() - start_ts
        detLog(unit, "POLY_FIRED", string.format("elapsed=%.2f", elapsed))
        if C_ChatInfo and C_ChatInfo.SendAddonMessage then
            local name = MyName()
            if name then
                pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX,
                      "POLY_INCOMING|" .. unit, "WHISPER", name)
            end
        end
        local d = getDB()
        d.poly_alerts = d.poly_alerts or {}
        table.insert(d.poly_alerts, {
            unit = unit, at = time(),
            method = "duration",
            elapsed_at_alert = elapsed,
        })
        _capLog(d.poly_alerts, 100)
    end)
end

-- NEW PROBE 2: hooksecurefunc on stock Blizzard cast bar updates.
-- Our hook runs INSIDE Blizzard's secure-context call. If their code
-- has access to clean spell data to render the bar, our hook might see
-- it too. Try several candidate functions Blizzard exposes.
local function tryHookSecure(name, hook_fn)
    if not _G[name] then return false end
    local ok = pcall(hooksecurefunc, name, hook_fn)
    return ok
end

local hook_fire_count = 0
local function onCastBarUpdate(castBar, unit)
    -- We're inside Blizzard's call. Probe everything we can:
    if not castBar then return end
    hook_fire_count = hook_fire_count + 1
    -- Only report the first few + every 50 to avoid chat spam
    if hook_fire_count > 5 and hook_fire_count % 50 ~= 0 then return end
    local u = tostring(unit or castBar.unit or "?"):sub(1, 16)
    local sid = "?"
    pcall(function() sid = statusOf(true, castBar.spellID) end)
    local sn = "?"
    pcall(function() sn = statusOf(true, castBar.spellName) end)
    local txt = "?"
    pcall(function()
        if castBar.Text then
            local ok, t = pcall(castBar.Text.GetText, castBar.Text)
            txt = statusOf(ok, t)
        end
    end)
    Send("HOOK", ("u=%s^sid=%s^sn=%s^txt=%s^n=%d"):format(u, sid, sn, txt, hook_fire_count))
end

local function isHostileUnitToken(unit)
    if type(unit) ~= "string" then return false end
    if unit == "boss1" or unit == "boss2" or unit == "boss3"
       or unit == "boss4" or unit == "boss5" then return true end
    return unit:find("^nameplate%d+$") ~= nil
end

local function isUnitSpellcastEvent(event)
    return event == "UNIT_SPELLCAST_START"
        or event == "UNIT_SPELLCAST_CHANNEL_START"
        or event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_SUCCEEDED"
        or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_INTERRUPTIBLE"
        or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE"
end

frame:RegisterEvent("ADDON_LOADED")

----------------------------------------------------------------------
-- KITCHEN-SINK EVENT PROBE
--   Register every event we can think of. Log timestamps for later
--   correlation against Polymorph cast times. If any event fires near
--   Poly but never near AB, we found a discriminator.
----------------------------------------------------------------------
local SINK_EVENTS = {
    "UNIT_TARGET", "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE",
    "UNIT_HEALTH", "UNIT_HEALTH_FREQUENT", "UNIT_POWER_UPDATE",
    "UNIT_POWER_FREQUENT", "UNIT_COMBAT", "UNIT_DAMAGED", "UNIT_ATTACK",
    "UNIT_DEFENSE", "UNIT_LEVEL", "UNIT_DISPLAYPOWER", "UNIT_FACTION",
    "UNIT_FLAGS", "UNIT_MODEL_CHANGED", "UNIT_NAME_UPDATE", "UNIT_PHASE",
    "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_EMPOWER_START",
    "UNIT_SPELLCAST_EMPOWER_STOP", "UNIT_PORTRAIT_UPDATE", "UNIT_CONNECTION",
    "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED", "PLAYER_DEAD", "PLAYER_ALIVE",
    "PLAYER_LEAVE_COMBAT", "PLAYER_ENTER_COMBAT", "PLAYER_FORM_CHANGED",
    "NAME_PLATE_CREATED", "NAMEPLATE_TARGET_DRAW_OVER_OWN",
    "COMBAT_RATING_UPDATE", "COMBAT_TARGET_CHANGED",
    "ENCOUNTER_TIMELINE_EVENT_ADDED", "ENCOUNTER_TIMELINE_EVENT_REMOVED",
    "ENCOUNTER_TIMELINE_EVENT_STATE_CHANGED",
    "GROUP_ROSTER_UPDATE", "PARTY_MEMBER_DISABLE", "PARTY_MEMBER_ENABLE",
    "RAID_TARGET_UPDATE",
    "CHAT_MSG_TARGETICONS", "CHAT_MSG_SYSTEM",
    "WORLD_STATE_TIMER_START", "WORLD_STATE_TIMER_STOP",
    "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA",
    "SPELLS_CHANGED", "SPELL_TEXT_UPDATE",
    "ITEM_LOCKED", "ITEM_UNLOCKED",
    "ACTIONBAR_UPDATE_USABLE", "ACTIONBAR_UPDATE_COOLDOWN",
    "ACTIONBAR_UPDATE_STATE",
}
local sink_frame = CreateFrame("Frame", "VRT_Reader_SinkEventFrame")
for _, ev in ipairs(SINK_EVENTS) do
    pcall(sink_frame.RegisterEvent, sink_frame, ev)
end
sink_frame:SetScript("OnEvent", function(_, ev, a1, a2, a3)
    local d = getDB()
    d.sink_log = d.sink_log or {}
    table.insert(d.sink_log, {
        at = time(), gt = GetTime(),
        ev = ev,
        a1 = safeStr(a1, 24),
        a2 = safeStr(a2, 24),
        a3 = safeStr(a3, 24),
    })
    _capLog(d.sink_log, 10000)
end)

----------------------------------------------------------------------
-- SOUND CAPTURE PROBE
--   Hook PlaySoundFile + PlaySound to record every sound the engine
--   plays. Sound IDs are plain Blizzard constants — entirely outside
--   the secret-value gate system. After a pull with confirmed Poly
--   casts in the combat log, we cross-reference our sound log with
--   Poly cast timestamps to identify the Polymorph sound ID.
----------------------------------------------------------------------
local sound_count = 0
local function recordSound(label, soundID, channel)
    sound_count = sound_count + 1
    -- Cheap dedup: same soundID within 100ms = probably same event echoing,
    -- skip to avoid filling the log.
    if not soundID then return end
    local d = getDB()
    d.sound_log = d.sound_log or {}
    -- Reject obvious UI sounds we don't care about by sound ID range.
    -- (We'll filter more in analysis.) For now: log everything to find
    -- the unique-to-Poly signal.
    table.insert(d.sound_log, {
        at = time(),
        gt = GetTime(),
        src = label,
        sid = soundID,
        ch = channel or "",
    })
    _capLog(d.sound_log, 5000)
end

if _G.PlaySoundFile then
    pcall(hooksecurefunc, "PlaySoundFile", function(sound, channel)
        recordSound("File", sound, channel)
    end)
end
if _G.PlaySound then
    pcall(hooksecurefunc, "PlaySound", function(soundKitID, channel, forceNoDuplicates, runFinishCallback)
        recordSound("Kit", soundKitID, channel)
    end)
end

frame:RegisterEvent("PLAYER_LOGIN")
local raw_event_count = 0
local hostile_event_count = 0
frame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
        end
        return
    end
    if event == "PLAYER_LOGIN" then
        registerHostileUnitEvents()
        -- EXBOSS DATA PROBE: walk EXBoss/Exwind/EXBossData globals to
        -- discover what's exposed. Dump shape + sample of every table
        -- so we can decide which to consume for VRT trash detection.
        -- Delayed by 3s to let dependent addons fully initialize.
        C_Timer.After(3, function()
            local d = getDB()
            d.exboss_probe = d.exboss_probe or {}
            local results = {}
            local NAMESPACES = {
                "EXBossData", "EXBoss", "EXBoss_DB", "EXBOSS",
                "ExwindCore", "ExwindTools", "Exwind", "Exwind_DB",
                "EXBOSS_DB", "EXWIND",
            }
            for _, ns_name in ipairs(NAMESPACES) do
                local ns = _G[ns_name]
                if ns == nil then
                    results[#results+1] = ns_name .. ": ABSENT"
                elseif type(ns) ~= "table" then
                    results[#results+1] = ns_name .. ": type=" .. type(ns)
                else
                    local key_count = 0
                    local sample_keys = {}
                    local sample_types = {}
                    for k, v in pairs(ns) do
                        key_count = key_count + 1
                        if #sample_keys < 8 then
                            sample_keys[#sample_keys+1] = tostring(k):sub(1, 24)
                            sample_types[#sample_types+1] = type(v)
                        end
                    end
                    results[#results+1] = string.format(
                        "%s: TABLE keys=%d sample={%s} types={%s}",
                        ns_name, key_count,
                        table.concat(sample_keys, ","),
                        table.concat(sample_types, ",")
                    )
                end
            end
            -- Also walk _G keys matching EX/Exwind/Boss patterns we
            -- might have missed.
            local extras = {}
            for k, v in pairs(_G) do
                local lk = tostring(k):lower()
                if (lk:find("exboss") or lk:find("exwind") or lk:find("^ex_") or lk:find("trashmob") or lk:find("trashcd"))
                   and type(v) == "table" then
                    extras[#extras+1] = tostring(k)
                end
                if #extras >= 40 then break end
            end
            results[#results+1] = "EXTRAS=" .. table.concat(extras, ",")
            d.exboss_probe[#d.exboss_probe+1] = {
                at = time(),
                entries = results,
            }
            _capLog(d.exboss_probe, 10)
            -- (Chat print removed — EXBoss has been disabled. Probe still
            -- runs silently in case it's ever re-enabled; results in DB.)
            d.exboss_deep_sentinel = time()
            -- DEEP DIVE: extract the trash mob data structure.
            -- Wrapped in pcall so any error here doesn't blow up the timer.
            local probe_ok, probe_err = pcall(function()
            -- Specifically inspect Arcane Magister (232369), the mob
            -- we've been using as our test case.
            d.exboss_deep = d.exboss_deep or {}
            local deep = { at = time(), notes = {} }
            -- TraitS root via the public API
            local ok_traits, traits = pcall(function()
                return _G.EXBossData and EXBossData.GetTrashMobTraitsRoot
                    and EXBossData.GetTrashMobTraitsRoot()
            end)
            if ok_traits and type(traits) == "table" then
                local count = 0
                for _ in pairs(traits) do count = count + 1 end
                deep.notes[#deep.notes+1] = "TraitsRoot: " .. count .. " entries"
                -- Magister-specific dump
                local m = traits[232369]
                if m then
                    deep.notes[#deep.notes+1] = "Magister(232369) trait keys: "
                    for k, _ in pairs(m) do
                        deep.notes[#deep.notes+1] = "  ." .. tostring(k)
                    end
                    -- Sample castDurations if present
                    if type(m.castDurations) == "table" then
                        local parts = {}
                        for k, v in pairs(m.castDurations) do
                            parts[#parts+1] = tostring(k) .. "=" .. tostring(v)
                        end
                        deep.notes[#deep.notes+1] = "  castDurations={" .. table.concat(parts, ",") .. "}"
                    end
                    if type(m.spellIDs) == "table" then
                        local parts = {}
                        for k, v in pairs(m.spellIDs) do
                            parts[#parts+1] = tostring(k) .. "=" .. tostring(v)
                        end
                        deep.notes[#deep.notes+1] = "  spellIDs={" .. table.concat(parts, ",") .. "}"
                    end
                else
                    deep.notes[#deep.notes+1] = "Magister(232369) NOT in TraitsRoot"
                end
            else
                deep.notes[#deep.notes+1] = "TraitsRoot: not callable"
            end
            -- CD data root
            local ok_cd, cd_root = pcall(function()
                return _G.EXBossData and EXBossData.GetTrashCDPresetRoot
                    and EXBossData.GetTrashCDPresetRoot()
            end)
            if ok_cd and type(cd_root) == "table" then
                local cnt = 0
                for _ in pairs(cd_root) do cnt = cnt + 1 end
                deep.notes[#deep.notes+1] = "CDPresetRoot: " .. cnt .. " entries"
            else
                deep.notes[#deep.notes+1] = "CDPresetRoot: not callable"
            end
            -- Walk EXBOSS_TRASH_MOB_TRAITS directly
            if _G.EXBOSS_TRASH_MOB_TRAITS then
                local cnt = 0
                for _ in pairs(EXBOSS_TRASH_MOB_TRAITS) do cnt = cnt + 1 end
                deep.notes[#deep.notes+1] = "EXBOSS_TRASH_MOB_TRAITS direct: " .. cnt
                local m = EXBOSS_TRASH_MOB_TRAITS[232369]
                if m and type(m) == "table" then
                    deep.notes[#deep.notes+1] = "  direct Magister[232369] keys:"
                    for k, v in pairs(m) do
                        deep.notes[#deep.notes+1] = "    ." .. tostring(k) .. " type=" .. type(v)
                    end
                end
            end
            -- Walk EXBOSS_TRASH_CD_DATA directly
            if _G.EXBOSS_TRASH_CD_DATA then
                local cnt = 0
                for _ in pairs(EXBOSS_TRASH_CD_DATA) do cnt = cnt + 1 end
                deep.notes[#deep.notes+1] = "EXBOSS_TRASH_CD_DATA direct: " .. cnt
                deep.notes[#deep.notes+1] = "  KEYS in EXBOSS_TRASH_CD_DATA:"
                for k, v in pairs(EXBOSS_TRASH_CD_DATA) do
                    local desc = type(v) == "table" and ("table") or type(v)
                    if type(v) == "table" then
                        local subcnt = 0
                        for _ in pairs(v) do subcnt = subcnt + 1 end
                        desc = "table[" .. subcnt .. "]"
                    end
                    deep.notes[#deep.notes+1] = "    [" .. tostring(k) .. "] = " .. desc
                end
                local m = EXBOSS_TRASH_CD_DATA[232369]
                if m and type(m) == "table" then
                    deep.notes[#deep.notes+1] = "  direct Magister[232369] CD entries:"
                    for spell_id, sched in pairs(m) do
                        local parts = {}
                        if type(sched) == "table" then
                            for k, v in pairs(sched) do
                                parts[#parts+1] = tostring(k) .. "=" .. tostring(v):sub(1, 20)
                            end
                        end
                        deep.notes[#deep.notes+1] = "    spellID=" .. tostring(spell_id) .. " {" .. table.concat(parts, ",") .. "}"
                    end
                end
            end
            -- Walk TRAITS directly too — dump all keys
            if _G.EXBOSS_TRASH_MOB_TRAITS then
                deep.notes[#deep.notes+1] = "  KEYS in EXBOSS_TRASH_MOB_TRAITS:"
                for k, v in pairs(EXBOSS_TRASH_MOB_TRAITS) do
                    deep.notes[#deep.notes+1] = "    [" .. tostring(k) .. "] = " .. type(v)
                end
            end
            -- ENCOUNTER data — fixed timeline + encounter triggers
            if _G.EXBOSS_FIXED_TIMELINE_ENCOUNTERS then
                local cnt = 0
                for _ in pairs(EXBOSS_FIXED_TIMELINE_ENCOUNTERS) do cnt = cnt + 1 end
                deep.notes[#deep.notes+1] = "EXBOSS_FIXED_TIMELINE_ENCOUNTERS: " .. cnt
                local n = 0
                for k, _ in pairs(EXBOSS_FIXED_TIMELINE_ENCOUNTERS) do
                    deep.notes[#deep.notes+1] = "  [" .. tostring(k) .. "]"
                    n = n + 1; if n >= 15 then break end
                end
            end
            if _G.EXBOSS_ENCOUNTER_DATA then
                local cnt = 0
                for _ in pairs(EXBOSS_ENCOUNTER_DATA) do cnt = cnt + 1 end
                deep.notes[#deep.notes+1] = "EXBOSS_ENCOUNTER_DATA: " .. cnt
                local n = 0
                for k, _ in pairs(EXBOSS_ENCOUNTER_DATA) do
                    deep.notes[#deep.notes+1] = "  [" .. tostring(k) .. "]"
                    n = n + 1; if n >= 10 then break end
                end
            end
            -- BUILTIN trash presets — likely has MT data
            if _G.EXBOSS_BUILTIN_TRASH_PRESETS then
                local cnt = 0
                for _ in pairs(EXBOSS_BUILTIN_TRASH_PRESETS) do cnt = cnt + 1 end
                deep.notes[#deep.notes+1] = "EXBOSS_BUILTIN_TRASH_PRESETS: " .. cnt
                local n = 0
                for k, v in pairs(EXBOSS_BUILTIN_TRASH_PRESETS) do
                    local sub = type(v) == "table" and "table" or type(v)
                    if type(v) == "table" then
                        local sc = 0
                        for _ in pairs(v) do sc = sc + 1 end
                        sub = "table[" .. sc .. "]"
                    end
                    deep.notes[#deep.notes+1] = "  [" .. tostring(k) .. "] = " .. sub
                    n = n + 1; if n >= 25 then break end
                end
            end
            -- Dump CURRENT zone info so we can map the user's current
            -- dungeon to one of the 8 mapIDs in the CD_DATA table.
            local zone_text  = (GetZoneText and GetZoneText()) or "?"
            local subzone    = (GetSubZoneText and GetSubZoneText()) or "?"
            local instance_id = "?"
            if GetInstanceInfo then
                local _, _, _, _, _, _, _, instID = GetInstanceInfo()
                instance_id = tostring(instID or "?")
            end
            local map_id = "?"
            if C_Map and C_Map.GetBestMapForUnit then
                map_id = tostring(C_Map.GetBestMapForUnit("player") or "?")
            end
            deep.notes[#deep.notes+1] = string.format(
                "ZONE: text=%s sub=%s instanceID=%s mapID=%s",
                zone_text, subzone, instance_id, map_id
            )
            -- Drill into each of the 8 CD_DATA keys, dump first level
            if _G.EXBOSS_TRASH_CD_DATA then
                for top_key, top_val in pairs(EXBOSS_TRASH_CD_DATA) do
                    if type(top_val) == "table" then
                        local subkeys = {}
                        for sk, sv in pairs(top_val) do
                            local sd = type(sv) == "table" and "T" or type(sv):sub(1,1)
                            if type(sv) == "table" then
                                local scc = 0
                                for _ in pairs(sv) do scc = scc + 1 end
                                sd = "T[" .. scc .. "]"
                            end
                            subkeys[#subkeys+1] = tostring(sk) .. ":" .. sd
                        end
                        deep.notes[#deep.notes+1] = string.format(
                            "CD_DATA[%s] sub={%s}", tostring(top_key),
                            table.concat(subkeys, ","):sub(1, 200))
                    end
                end
            end
            -- Drill into TRAITS.rows
            if _G.EXBOSS_TRASH_MOB_TRAITS and type(EXBOSS_TRASH_MOB_TRAITS.rows) == "table" then
                local rc = 0
                for _ in pairs(EXBOSS_TRASH_MOB_TRAITS.rows) do rc = rc + 1 end
                deep.notes[#deep.notes+1] = "TRAITS.rows count: " .. rc
                -- Sample first 5 rows
                local n = 0
                for k, v in pairs(EXBOSS_TRASH_MOB_TRAITS.rows) do
                    n = n + 1
                    if n > 5 then break end
                    local sub = type(v) == "table" and "table" or type(v)
                    if type(v) == "table" then
                        local sk = {}
                        for kk, _ in pairs(v) do sk[#sk+1] = tostring(kk) end
                        sub = "table{" .. table.concat(sk, ",") .. "}"
                    end
                    deep.notes[#deep.notes+1] = "  TRAITS.rows[" .. tostring(k) .. "] = " .. sub:sub(1,150)
                end
            end
            -- Drill into ENCOUNTER_DATA.maps
            if _G.EXBOSS_ENCOUNTER_DATA and type(EXBOSS_ENCOUNTER_DATA.maps) == "table" then
                local mc = 0
                for _ in pairs(EXBOSS_ENCOUNTER_DATA.maps) do mc = mc + 1 end
                deep.notes[#deep.notes+1] = "ENCOUNTER_DATA.maps count: " .. mc
                local n = 0
                for k, v in pairs(EXBOSS_ENCOUNTER_DATA.maps) do
                    n = n + 1; if n > 8 then break end
                    deep.notes[#deep.notes+1] = "  maps[" .. tostring(k) .. "] type=" .. type(v)
                end
            end
            -- THE GOAL: drill into the CURRENT zone's mob data.
            -- instanceID we read earlier should match one of the 8 keys.
            local zone_iid = tonumber(instance_id)
            if zone_iid and _G.EXBOSS_TRASH_CD_DATA and EXBOSS_TRASH_CD_DATA[zone_iid] then
                local entry = EXBOSS_TRASH_CD_DATA[zone_iid]
                deep.notes[#deep.notes+1] = "ZONE MATCH: CD_DATA[" .. zone_iid .. "]"
                deep.notes[#deep.notes+1] = "  mapName=" .. tostring(entry.mapName or "?")
                if type(entry.mobs) == "table" then
                    local mc = 0
                    for _ in pairs(entry.mobs) do mc = mc + 1 end
                    deep.notes[#deep.notes+1] = "  mobs count=" .. mc
                    local n = 0
                    for mob_k, mob_v in pairs(entry.mobs) do
                        n = n + 1; if n > 20 then break end
                        if type(mob_v) == "table" then
                            local sk = {}
                            for kk, vv in pairs(mob_v) do
                                local tn = type(vv) == "table" and "T" or type(vv):sub(1,1)
                                if type(vv) == "table" then
                                    local cc = 0
                                    for _ in pairs(vv) do cc = cc + 1 end
                                    tn = "T[" .. cc .. "]"
                                end
                                sk[#sk+1] = tostring(kk) .. ":" .. tn
                            end
                            deep.notes[#deep.notes+1] = "  mobs[" .. tostring(mob_k) .. "] = {" .. table.concat(sk, ",") .. "}"
                            -- If npcID field exists, dump it
                            if mob_v.npcID then
                                deep.notes[#deep.notes+1] = "    npcID=" .. tostring(mob_v.npcID)
                            end
                            -- Look for spell schedule (likely cdEvents, casts, schedule, or similar)
                            for sub_k, sub_v in pairs(mob_v) do
                                if type(sub_v) == "table" then
                                    local sc = 0
                                    for _ in pairs(sub_v) do sc = sc + 1 end
                                    if sc > 0 then
                                        deep.notes[#deep.notes+1] = "    " .. tostring(sub_k) .. " table has " .. sc .. " entries"
                                        -- Sample first 2 entries
                                        local nn = 0
                                        for sk2, sv2 in pairs(sub_v) do
                                            nn = nn + 1; if nn > 2 then break end
                                            if type(sv2) == "table" then
                                                local kparts = {}
                                                for kkk, vvv in pairs(sv2) do
                                                    kparts[#kparts+1] = tostring(kkk) .. "=" .. tostring(vvv):sub(1,20)
                                                end
                                                deep.notes[#deep.notes+1] = "      [" .. tostring(sk2) .. "] = {" .. table.concat(kparts, ",") .. "}"
                                            else
                                                deep.notes[#deep.notes+1] = "      [" .. tostring(sk2) .. "] = " .. tostring(sv2):sub(1,40)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            else
                deep.notes[#deep.notes+1] = "ZONE NO MATCH (iid=" .. tostring(zone_iid) .. ")"
            end
            -- SEARCH for Arcane Magister (232369) across ALL EXBoss data.
            -- The user knows from experience that Poly (Magister) and Fear
            -- (Void Terror) are the only priority kicks in MT. EXBoss's MT
            -- mob list doesn't include Magister, so search everywhere.
            local TARGET_MAGISTER = 232369
            local TARGET_POLY     = 468966  -- Polymorph
            local function deepSearch(t, target, path, depth, maxDepth, hits)
                if depth > maxDepth then return end
                if type(t) ~= "table" then return end
                for k, v in pairs(t) do
                    local current_path = path .. "." .. tostring(k)
                    if k == target or v == target then
                        hits[#hits+1] = current_path .. " (key/value match)"
                    end
                    if type(v) == "table" and #hits < 20 then
                        deepSearch(v, target, current_path, depth + 1, maxDepth, hits)
                    end
                end
            end
            -- Magister NPC ID search
            local mag_hits = {}
            if _G.EXBOSS_TRASH_CD_DATA then
                deepSearch(EXBOSS_TRASH_CD_DATA, TARGET_MAGISTER, "CD_DATA", 1, 4, mag_hits)
            end
            if _G.EXBOSS_TRASH_MOB_TRAITS then
                deepSearch(EXBOSS_TRASH_MOB_TRAITS, TARGET_MAGISTER, "TRAITS", 1, 4, mag_hits)
            end
            if _G.EXBOSS_BUILTIN_TRASH_PRESETS then
                deepSearch(EXBOSS_BUILTIN_TRASH_PRESETS, TARGET_MAGISTER, "PRESETS", 1, 6, mag_hits)
            end
            deep.notes[#deep.notes+1] = "MAGISTER(232369) HITS: " .. #mag_hits
            for _, h in ipairs(mag_hits) do
                deep.notes[#deep.notes+1] = "  " .. h:sub(1, 200)
            end
            -- Polymorph spell ID search
            local poly_hits = {}
            if _G.EXBOSS_TRASH_CD_DATA then
                deepSearch(EXBOSS_TRASH_CD_DATA, TARGET_POLY, "CD_DATA", 1, 4, poly_hits)
            end
            if _G.EXBOSS_BUILTIN_TRASH_PRESETS then
                deepSearch(EXBOSS_BUILTIN_TRASH_PRESETS, TARGET_POLY, "PRESETS", 1, 6, poly_hits)
            end
            deep.notes[#deep.notes+1] = "POLY(468966) HITS: " .. #poly_hits
            for _, h in ipairs(poly_hits) do
                deep.notes[#deep.notes+1] = "  " .. h:sub(1, 200)
            end
            -- Dump ALL TRAITS.rows that might be MT-related (column 3 looks
            -- like NPC ID per our row[1] sample)
            if _G.EXBOSS_TRASH_MOB_TRAITS and type(EXBOSS_TRASH_MOB_TRAITS.rows) == "table" then
                deep.notes[#deep.notes+1] = "TRAITS rows search for Magister:"
                for idx, row in pairs(EXBOSS_TRASH_MOB_TRAITS.rows) do
                    if type(row) == "table" then
                        -- Row schema (guess): [3]=npcID, [4]=mobName
                        if row[3] == TARGET_MAGISTER or tostring(row[3]) == tostring(TARGET_MAGISTER) then
                            local parts = {}
                            for k, v in pairs(row) do
                                parts[#parts+1] = tostring(k) .. "=" .. tostring(v):sub(1, 30)
                            end
                            deep.notes[#deep.notes+1] = "  row[" .. idx .. "]: " .. table.concat(parts, ", ")
                        end
                    end
                end
            end
            -- Also peek inside TRAITS.rows to see row schema
            if _G.EXBOSS_TRASH_MOB_TRAITS and type(EXBOSS_TRASH_MOB_TRAITS.rows) == "table" then
                local first_row = EXBOSS_TRASH_MOB_TRAITS.rows[1]
                if type(first_row) == "table" then
                    local parts = {}
                    for k, v in pairs(first_row) do
                        parts[#parts+1] = tostring(k) .. "=" .. tostring(v):sub(1,30)
                    end
                    deep.notes[#deep.notes+1] = "  TRAITS row[1] full: {" .. table.concat(parts, ", ") .. "}"
                end
            end
            -- Drill into BUILTIN_TRASH_PRESETS.packs
            if _G.EXBOSS_BUILTIN_TRASH_PRESETS and type(EXBOSS_BUILTIN_TRASH_PRESETS.packs) == "table" then
                local pc = 0
                for _ in pairs(EXBOSS_BUILTIN_TRASH_PRESETS.packs) do pc = pc + 1 end
                deep.notes[#deep.notes+1] = "PRESETS.packs count: " .. pc
                local n = 0
                for k, v in pairs(EXBOSS_BUILTIN_TRASH_PRESETS.packs) do
                    n = n + 1; if n > 8 then break end
                    local sub = type(v) == "table" and "table" or type(v)
                    if type(v) == "table" then
                        local sk = {}
                        for kk, _ in pairs(v) do sk[#sk+1] = tostring(kk) end
                        sub = "table{" .. table.concat(sk, ",") .. "}"
                    end
                    deep.notes[#deep.notes+1] = "  packs[" .. tostring(k) .. "] = " .. sub:sub(1,180)
                end
            end
            d.exboss_deep[#d.exboss_deep+1] = deep
            _capLog(d.exboss_deep, 5)
            end)  -- close pcall
            if not probe_ok then
                d.exboss_deep_error = tostring(probe_err)
            else
                d.exboss_deep_completed = time()
            end
            -- (Chat prints removed — silent. Status in SavedVariables.)
        end)
        -- Try hooksecurefunc on several Blizzard candidates
        local hooks_attempted = {}
        for _, fname in ipairs({
            "CompactUnitFrame_UpdateCastBar",
            "TargetFrameSpellBar_OnEvent",
            "CastingBarFrame_OnEvent",
            "NamePlateCastingBarMixin_OnEvent",
        }) do
            if tryHookSecure(fname, onCastBarUpdate) then
                hooks_attempted[#hooks_attempted+1] = fname .. ":ok"
            else
                hooks_attempted[#hooks_attempted+1] = fname .. ":miss"
            end
        end

        -- MIXIN METHOD HOOKS — the big test.
        -- CastingBarMixin:OnEvent is called by the game engine on
        -- UNIT_SPELLCAST_* events. Inside Blizzard's code, line 332 reads
        -- `local ..., spellID = UnitCastingInfo(unit)` in PRIVILEGED context.
        -- It then writes `self.spellID = spellID` at line 361.
        --
        -- When OUR hook runs AFTER Blizzard's OnEvent, self.spellID has just
        -- been set. If hooksecurefunc preserves privileged context (it should
        -- for engine-triggered calls), self.spellID is CLEAN in our hook.
        --
        -- We compare against our known list. The compare runs in privileged
        -- context (since the args are clean). We write a CLEAN derived string
        -- to the Reader DB. That's our breakthrough chain.
        local mixin_hooks = {}
        local function mixinHookOnEvent(self, event, ...)
            -- self is the cast bar widget. self.unit is the unit token.
            -- self.spellID just got set by Blizzard. Try to read it cleanly.
            local hook_fired = (VoidRaidToolsReaderDB.mixin_hook_fires or 0) + 1
            VoidRaidToolsReaderDB.mixin_hook_fires = hook_fired
            local u = "?"
            pcall(function() u = self.unit or "?" end)
            local sid_status = "?"
            local sid_val = nil
            pcall(function()
                sid_val = self.spellID
                sid_status = statusOf(true, sid_val)
            end)
            -- Try ARITHMETIC on the read value in the hook's context
            -- (if hook is in privileged ctx, this should NOT throw)
            local arith_test = "?"
            pcall(function()
                local r = (sid_val or 0) + 1
                arith_test = "ok:" .. tostring(r):sub(1, 16)
            end)
            -- Try equality with a known literal
            local eq_test = "?"
            pcall(function()
                if sid_val == 248831 then eq_test = "true"
                else eq_test = "false" end
            end)
            -- Read the barType (was set by GetEffectiveType from clean inputs)
            local bt_status = "?"
            pcall(function() bt_status = statusOf(true, self.barType) end)
            -- Read isHighlightedImportantCast (Blizzard sets this in
            -- UpdateHighlightImportantCast based on a clean lookup)
            local imp_status = "?"
            pcall(function() imp_status = statusOf(true, self.isHighlightedImportantCast) end)
            -- Send results (lossless to Reader DB)
            Send("MIXIN_HOOK", ("event=%s|u=%s|sid=%s|arith=%s|eq=%s|bt=%s|imp=%s|n=%d"):format(
                tostring(event):sub(1, 32), tostring(u):sub(1, 16),
                sid_status, arith_test:sub(1, 24), eq_test, bt_status, imp_status, hook_fired
            ))
        end
        -- Also hook UpdateHighlightImportantCast — fires AFTER spellID set
        local function mixinHookImportant(self)
            local imp_status = "?"
            local sid_status = "?"
            pcall(function() imp_status = statusOf(true, self.isHighlightedImportantCast) end)
            pcall(function() sid_status = statusOf(true, self.spellID) end)
            local u = "?"
            pcall(function() u = self.unit or "?" end)
            Send("MIXIN_IMPORTANT", ("u=%s|imp=%s|sid=%s"):format(
                tostring(u):sub(1, 16), imp_status, sid_status
            ))
        end
        if _G.CastingBarMixin then
            local ok1 = pcall(hooksecurefunc, CastingBarMixin, "OnEvent", mixinHookOnEvent)
            mixin_hooks[#mixin_hooks+1] = "CBM.OnEvent:" .. (ok1 and "ok" or "err")
            if CastingBarMixin.UpdateHighlightImportantCast then
                local ok2 = pcall(hooksecurefunc, CastingBarMixin, "UpdateHighlightImportantCast", mixinHookImportant)
                mixin_hooks[#mixin_hooks+1] = "CBM.UpdHighlight:" .. (ok2 and "ok" or "err")
            else
                mixin_hooks[#mixin_hooks+1] = "CBM.UpdHighlight:missing"
            end
        else
            mixin_hooks[#mixin_hooks+1] = "CBM:absent"
        end

        -- FORCE-ENABLE highlightImportantCasts on every known cast bar
        -- widget. CastingBarMixin:UpdateHighlightImportantCast at line 884
        -- short-circuits when this flag is false. Enabling it lets the chain
        -- reach C_Spell.IsSpellImportant — which runs in Blizzard's privileged
        -- context and may store a CLEAN boolean to self.isHighlightedImportantCast.
        local force_enabled = {}
        for _, fname in ipairs({
            "TargetFrameSpellBar", "FocusFrameSpellBar", "PetCastingBarFrame",
            "Boss1TargetFrameSpellBar", "Boss2TargetFrameSpellBar",
            "Boss3TargetFrameSpellBar", "Boss4TargetFrameSpellBar",
            "Boss5TargetFrameSpellBar",
        }) do
            local f = _G[fname]
            if f and f.SetHighlightImportantCasts then
                local ok = pcall(f.SetHighlightImportantCasts, f, true)
                force_enabled[#force_enabled+1] = fname .. ":" .. (ok and "ok" or "err")
            else
                force_enabled[#force_enabled+1] = fname .. ":missing"
            end
        end
        Send("FORCE_HIGHLIGHT", table.concat(force_enabled, ","))
        -- Plater's CastBarOnEvent_Hook — exposed top-level. Same idea.
        if _G.Plater and Plater.CastBarOnEvent_Hook then
            local ok3 = pcall(hooksecurefunc, Plater, "CastBarOnEvent_Hook", mixinHookOnEvent)
            mixin_hooks[#mixin_hooks+1] = "Plater.CBOE:" .. (ok3 and "ok" or "err")
        else
            mixin_hooks[#mixin_hooks+1] = "Plater.CBOE:missing"
        end
        Send("MIXIN_HOOKS", table.concat(mixin_hooks, ","))
        -- Register OTHER addon prefixes so we receive their broadcasts
        -- via CHAT_MSG_ADDON. We can't catch what isn't registered.
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            for _, p in ipairs({
                "D5", "D4", "DBM", "DBM4",                  -- DBM variants
                "BigWigs", "BWPS", "Transcriptor",          -- BigWigs + tools
                "PLATER", "Plater", "P_Plater",             -- Plater variants
                "EXRT", "MRT",                              -- Method Raid Tools
                "TLR",                                      -- The Last Reminder
                "WeakAuras",                                -- WA broadcasts (if anything)
            }) do
                pcall(C_ChatInfo.RegisterAddonMessagePrefix, p)
            end
        end
        -- Try Plater callbacks for common event names
        local plater_state = "absent"
        local plater_cb_attempts = {}
        if _G.Plater then
            plater_state = "present"
            if Plater.RegisterCallback then
                for _, evname in ipairs({
                    "OnUnitNamePlateAdded", "OnUnitNamePlateRemoved",
                    "OnCastStart", "OnCastUpdate", "OnCastEnd",
                    "OnSpellCast", "OnSpellCastSuccess",
                    "UPDATE_NAMEPLATE_HEALTH",
                    "OnHealthUpdate", "OnUpdate",
                }) do
                    if tryPlaterCallback(evname) then
                        plater_cb_attempts[#plater_cb_attempts+1] = evname .. ":ok"
                    else
                        plater_cb_attempts[#plater_cb_attempts+1] = evname .. ":miss"
                    end
                end
            end
            -- Probe Plater's runtime data tables
            probePlaterRuntimeData()
            -- Plater function enumeration (cast/spell/interrupt related)
            pcall(function()
                Send("PLATER_FNS", probePlaterFunctions())
            end)
            -- PlaterDB.InterruptableSpells inventory + control test
            pcall(function()
                Send("PLATER_INT_DB", probePlaterInterruptDB())
            end)
            -- Try hooksecurefunc on a wider set of Plater + Blizzard
            -- functions we found in source.
            for _, fname in ipairs({
                "Plater.UpdateCastbarIcon",
                "Plater.UpdateCastbarTargetText",
                "Plater.UpdateCastBar",
                "Plater.OnCastStart",
                "NamePlateCastBar_OnEvent",
            }) do
                pcall(function()
                    local owner, key = fname:match("^([^%.]+)%.(.+)$")
                    if owner and key and _G[owner] and _G[owner][key] then
                        local ok = pcall(hooksecurefunc, _G[owner], key, onCastBarUpdate)
                        if ok then hooks_attempted[#hooks_attempted+1] = fname .. ":ok"
                        else hooks_attempted[#hooks_attempted+1] = fname .. ":hookerr" end
                    elseif not owner and _G[fname] then
                        local ok = pcall(hooksecurefunc, fname, onCastBarUpdate)
                        if ok then hooks_attempted[#hooks_attempted+1] = fname .. ":ok"
                        else hooks_attempted[#hooks_attempted+1] = fname .. ":hookerr" end
                    else
                        hooks_attempted[#hooks_attempted+1] = fname .. ":missing"
                    end
                end)
            end
        end
        -- SavedVariables launder check — did last session's seeded secret
        -- survive serialization with its taint tag?
        pcall(function()
            Send("SV_LAUNDER", probeSavedVarsLaunder())
        end)
        -- Silent boot — single line indicator only.
        return
    end
    raw_event_count = raw_event_count + 1
    -- Silent — no more raw event prints.
    -- Hostile-unit filter ONLY applies to UNIT_SPELLCAST_* events. Other
    -- events (CHAT_MSG_ADDON, COMBAT_TEXT_UPDATE, etc.) have non-unit arg1
    -- and must be routed past the filter.
    if isUnitSpellcastEvent(event) then
        if not isHostileUnitToken(arg1) then return end
        hostile_event_count = hostile_event_count + 1
    end
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        -- NEW: friendly-cast detection. When a friendly healer NPC or party
        -- member starts casting a dispel spell, we know a CC just landed.
        -- Friendly cast info IS CLEAN (party2/party3/etc. allow UnitCastingInfo).
        if type(arg1) == "string" and (arg1:find("^party%d") or arg1:find("^vehicle") or arg1 == "pet") then
            pcall(function()
                local ok, name, _, _, _, _, _, _, _, sid = pcall(UnitCastingInfo, arg1)
                if ok and name then
                    local d = getDB()
                    d.friendly_cast_log = d.friendly_cast_log or {}
                    table.insert(d.friendly_cast_log, {
                        at = time(), gt = GetTime(),
                        unit = arg1,
                        name = safeStr(name, 32),
                        sid = statusOf(true, sid),
                    })
                    _capLog(d.friendly_cast_log, 200)
                end
            end)
        end
        onNameplateCast(arg1)
        snapshot(arg1)
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        snapshotEnd(arg1, "stop")
        -- Cancel poly-detector timer: cast ended (any reason). If it
        -- ended within 2.6s, it was AB or filler; if it ended past 2.6s,
        -- the alert already fired (cancel is a no-op).
        if type(arg1) == "string" and arg1:find("^nameplate%d+$") then
            cancelDetectorTimer(arg1)
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        snapshotEnd(arg1, "interrupted")
        if type(arg1) == "string" and arg1:find("^nameplate%d+$") then
            cancelDetectorTimer(arg1)
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        snapshotEnd(arg1, "success")
        if type(arg1) == "string" and arg1:find("^nameplate%d+$") then
            cancelDetectorTimer(arg1)
        end
    elseif event == "UNIT_SPELLCAST_FAILED" then
        snapshotEnd(arg1, "failed")
        if type(arg1) == "string" and arg1:find("^nameplate%d+$") then
            cancelDetectorTimer(arg1)
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" then
        Send("INT_STATE", arg1 .. "^kickable")
    elseif event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        Send("INT_STATE", arg1 .. "^uninterruptible")
    elseif event == "CHAT_MSG_MONSTER_EMOTE"
        or event == "CHAT_MSG_MONSTER_SAY"
        or event == "CHAT_MSG_MONSTER_YELL"
        or event == "CHAT_MSG_RAID_BOSS_EMOTE"
        or event == "CHAT_MSG_RAID_BOSS_WHISPER" then
        -- Boss/mob chat text is secret-tagged in 12.0.5; safeStr launders.
        local text = safeStr(arg1, 80)
        local source = safeStr(arg2, 32)
        local short_event = event:gsub("CHAT_MSG_", "")
        Send("CHAT", short_event .. "^" .. source .. "^" .. text)
    elseif event == "CHAT_MSG_ADDON" then
        -- arg1=prefix arg2=payload arg3=channel arg4=sender. We listen to
        -- ALL addon broadcasts to see if DBM/BigWigs/Plater carry usable
        -- spell info in their cross-user sync messages.
        local prefix = safeStr(arg1, 24)
        if prefix == ADDON_PREFIX then return end  -- ignore our own
        local payload = safeStr(arg2, 120)
        Send("ADDON_MSG", prefix .. "^" .. payload)
    elseif event == "PLAYER_CONTROL_LOST" then
        -- We just got CC'd. Read slot 1 of player's harmful auras NOW —
        -- the CC effect's spell IS the most recent harmful aura.
        local res = probePlayerAuraSlot1()
        Send("CC_LOST", "player^" .. res)
    elseif event == "PLAYER_CONTROL_GAINED" then
        Send("CC_GAINED", "player")
    elseif event == "COMBAT_TEXT_UPDATE" then
        Send("CT", safeStr(arg1, 24) .. "^" .. safeStr(arg2, 64))
    elseif event == "UI_INFO_MESSAGE" or event == "UI_ERROR_MESSAGE" then
        local mtype = event:gsub("UI_", "")
        Send("UI_MSG", mtype .. "^" .. safeStr(arg1, 24) .. "^" .. safeStr(arg2, 64))
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        if UnitExists("mouseover") and UnitCanAttack("player", "mouseover") then
            -- mouseover changed to hostile — try reading its cast
            local ok, name, _, _, _, _, _, _, _, sid = pcall(UnitCastingInfo, "mouseover")
            if ok and name then
                Send("MOUSEOVER", "name=" .. statusOf(true, name) .. "^sid=" .. statusOf(true, sid))
            end
        end
    elseif event == "UNIT_AURA" then
        -- NEW: by-ID aura query for known priority CC spells.
        -- We provide the spell ID — Blizzard answers yes/no. This is a
        -- different code path than iterating slots.
        if arg1 == "player" and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
            local d = getDB()
            d.byid_aura_log = d.byid_aura_log or {}
            local PRIORITY_CCS = {
                {id = 468966, name = "POLY"},          -- Magister Polymorph
                {id = 1218015, name = "VOID_BOLT"},   -- void terror filler
                -- Add other suspected priority CC IDs here as we identify them
            }
            for _, sp in ipairs(PRIORITY_CCS) do
                local ok, data = pcall(C_UnitAuras.GetPlayerAuraBySpellID, sp.id)
                if ok and data then
                    -- Aura with this ID exists. Capture everything we can read.
                    table.insert(d.byid_aura_log, {
                        at = time(), gt = GetTime(),
                        query_name = sp.name,
                        query_id = sp.id,
                        result_present = "table",
                        result_name = safeStr(data.name, 40),
                        result_sid = statusOf(true, data.spellId),
                        result_src = safeStr(data.sourceUnit, 32),
                    })
                    _capLog(d.byid_aura_log, 200)
                end
            end
        end
        -- Original slot-1 capture (kept for comparison)
        if arg1 == "player" then
            -- Read slot 1 of HARMFUL — clean mid-combat per our findings.
            local d = getDB()
            d.player_aura_log = d.player_aura_log or {}
            pcall(function()
                if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
                    local data = C_UnitAuras.GetAuraDataByIndex("player", 1, "HARMFUL")
                    if data then
                        table.insert(d.player_aura_log, {
                            at = time(), gt = GetTime(),
                            spell_id = statusOf(true, data.spellId),
                            name = safeStr(data.name, 40),
                            source = safeStr(data.sourceUnit, 32),
                            duration = statusOf(true, data.duration),
                        })
                        _capLog(d.player_aura_log, 200)
                    end
                end
            end)
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        -- Nameplate just disappeared. Mob died, ran behind a wall, or got
        -- out of view range. Clear the per-nameplate cast buffer so a
        -- future reassignment of this slot doesn't inherit stale data.
        if type(arg1) == "string" then
            clearNameplateState(arg1)
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- Belt-and-suspenders: clear on add too. If REMOVED didn't fire
        -- for some reason and a different mob now owns this slot, we
        -- want a clean start.
        if type(arg1) == "string" then
            clearNameplateState(arg1)
        end
    end
end)

----------------------------------------------------------------------
-- Plater API integration probe
--   Try common Plater callback / hook names. Plater absorbs the taint
--   internally (it has no SecureActionButtons); if its callback fires
--   with usable parameters we have a clean stepping-stone.
--   Try Plater.RegisterCallback first, then alternate patterns.
----------------------------------------------------------------------
local plater_callback_fire_count = 0
function tryPlaterCallback(event_name)
    if not _G.Plater or not Plater.RegisterCallback then return false end
    local cb = function(...)
        plater_callback_fire_count = plater_callback_fire_count + 1
        if plater_callback_fire_count > 3 and plater_callback_fire_count % 30 ~= 0 then return end
        local args = { ... }
        local parts = { event_name }
        for i = 1, math.min(#args, 4) do
            local v = args[i]
            if type(v) == "table" then
                local sid = statusOf(true, v.SpellID or v.spellID)
                local sn = statusOf(true, v.SpellName or v.spellName)
                local u = v.unit or v.namePlateUnitToken or "?"
                parts[#parts+1] = ("a%d:t=table,unit=%s,sid=%s,sn=%s"):format(i, tostring(u):sub(1,16), sid, sn)
            else
                parts[#parts+1] = ("a%d=%s"):format(i, statusOf(true, v))
            end
        end
        Send("PLATER_CB", table.concat(parts, "^"))
    end
    -- Plater's CallbackHandler usually wants colon syntax: Plater:RegisterCallback(self, event, fn)
    -- Try a few common signatures defensively.
    -- Pattern 1: Plater:RegisterCallback(self_table, event, fn)
    local ok1 = pcall(Plater.RegisterCallback, Plater, {}, event_name, cb)
    if ok1 then return true end
    -- Pattern 2: Plater.RegisterCallback(event, fn) — simple
    local ok2 = pcall(Plater.RegisterCallback, event_name, cb)
    if ok2 then return true end
    -- Pattern 3: Plater.RegisterCallback(some_id, event, fn)
    local ok3 = pcall(Plater.RegisterCallback, "VRT_R_" .. event_name, event_name, cb)
    return ok3
end

----------------------------------------------------------------------
-- Plater runtime data introspection (at boot)
--   If Plater stores a DB of seen spells, walk it and broadcast a
--   summary. No real-time signal but tells us what spell IDs Plater
--   has captured this session.
----------------------------------------------------------------------
function probePlaterRuntimeData()
    if not _G.Plater then
        Send("PLATER_DB", "absent")
        return
    end
    local fields_present = {}
    for _, k in ipairs({ "SpellCache", "CapturedSpells", "DB_CAPTURED_SPELLS",
                          "DB_CAPTURED_CASTS", "LastCastBySpellID",
                          "SpellHashTable", "SpellsTable" }) do
        if Plater[k] ~= nil then
            local t = type(Plater[k])
            local count = "?"
            if t == "table" then
                local n = 0
                pcall(function() for _ in pairs(Plater[k]) do n = n + 1 end end)
                count = tostring(n)
            end
            fields_present[#fields_present+1] = k .. "(" .. t .. "," .. count .. ")"
        end
    end
    if Plater.db and Plater.db.profile and Plater.db.profile.cast_colors then
        local n = 0
        pcall(function() for _ in pairs(Plater.db.profile.cast_colors) do n = n + 1 end end)
        fields_present[#fields_present+1] = "db.profile.cast_colors(table," .. n .. ")"
    end
    Send("PLATER_DB", #fields_present == 0 and "no_known_fields"
        or table.concat(fields_present, ","))
end

----------------------------------------------------------------------
-- C_NamePlate.GetNamePlates() walk + child enumeration
--   On each cast snapshot, also walk every active nameplate and probe
--   every child frame looking for ANY readable spell-related FontString
--   or value. Brute-force discovery.
----------------------------------------------------------------------
local function probeAllNameplates()
    if not C_NamePlate or not C_NamePlate.GetNamePlates then return "no_api" end
    local ok, plates = pcall(C_NamePlate.GetNamePlates)
    if not ok or type(plates) ~= "table" then return "err" end
    return "count=" .. #plates
end

----------------------------------------------------------------------
-- SavedVariables-launder-taint test
--   Write a known-secret value to a test slot. On next /reload, we'll
--   read it back and check if the secret tag survived serialization.
----------------------------------------------------------------------
function laundryTaintTest(secret_val)
    local d = getDB()
    -- Attempt to store the secret value. pcall in case the
    -- SavedVariables serializer chokes on it.
    pcall(function()
        d.laundry_pending = secret_val
        d.laundry_marker = "set at " .. tostring(time())
    end)
end
