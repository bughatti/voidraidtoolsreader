----------------------------------------------------------------------
-- VoidRaidToolsReader — IdentityProbes  (v2)
--
-- Systematic probe of every untested clean-data surface for identifying
-- hostile mobs in 12.0.5 instances without touching the tainted GUID.
--
-- v2 changes vs v1:
--   - Fix `raw` capture so `false` and string returns are stored.
--   - Defer model probe by ~0.6s so the model is actually loaded.
--   - Recycle ONE 1x1 offscreen PlayerModel instead of leaking new
--     frames every probe fire (kills the black-silhouette artifact).
--   - Add UnitIsUnit comparison test.
--   - Add UnitSelectionType (selection color id — possibly clean).
--   - Add UnitNameplateShowsWidgetsAsInteractive + similar misc.
----------------------------------------------------------------------

local IP = {}
local _G = _G

-- Mirror of Core.lua's _capLog so this file is self-contained.
-- O(n) bulk drop instead of O(n²) repeated table.remove(t, 1).
local function _capLog(t, cap)
    local n = #t
    if n <= cap then return end
    local drop = math.floor(cap * 0.1)
    if drop < 1 then drop = 1 end
    local m = n - drop
    for i = 1, m do t[i] = t[i + drop] end
    for i = m + 1, n do t[i] = nil end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function safeCall(fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    return ok, a, b, c, d
end

local function tagSecret(v)
    if v == nil then return "n/a" end
    local g_issv = _G.issecretvalue
    if type(g_issv) ~= "function" then return "no_issv_global" end
    local ok, is_s = pcall(g_issv, v)
    if not ok then return "issv_err:" .. tostring(is_s) end
    if is_s == true then return "secret"
    elseif is_s == false then return "clean"
    else return "unknown" end
end

local function describe(v) return type(v) end

-- FIXED: capture raw for ANY clean primitive (bool incl. false, number, string).
local function safeRaw(ok, v)
    if not ok then return nil end
    if tagSecret(v) ~= "clean" then return nil end
    local t = type(v)
    if t == "boolean" or t == "number" or t == "string" then
        return v
    end
    return nil
end

----------------------------------------------------------------------
-- Shared model frame (recycled — no more leak)
----------------------------------------------------------------------
local shared_model
local function getSharedModel()
    if shared_model then return shared_model end
    -- Parent to an explicitly hidden container so the model can't render.
    local holder = CreateFrame("Frame", "VRT_R_ModelHolder", UIParent)
    holder:SetSize(1, 1)
    holder:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10000, 10000)  -- way offscreen
    holder:Hide()
    local m = CreateFrame("PlayerModel", "VRT_R_HiddenModel", holder)
    m:SetSize(1, 1)
    m:SetPoint("CENTER", holder, "CENTER")
    m:Hide()
    shared_model = m
    return m
end

----------------------------------------------------------------------
-- Probes
----------------------------------------------------------------------

local function probeC_Secrets(unit, out)
    out.predicates = out.predicates or {}
    local Sec = _G.C_Secrets
    if type(Sec) ~= "table" then
        out.predicates.error = "C_Secrets table missing"
        return
    end
    local function callPred(name, ...)
        local fn = Sec[name]
        if type(fn) ~= "function" then
            out.predicates[name] = { error = "fn missing" }
            return
        end
        local ok, res = safeCall(fn, ...)
        out.predicates[name] = {
            ok      = ok,
            value   = (ok and describe(res)) or tostring(res),
            secret  = tagSecret(res),
            raw     = safeRaw(ok, res),
        }
    end
    callPred("ShouldUnitIdentityBeSecret", unit)
    callPred("ShouldUnitHealthMaxBeSecret", unit)
    callPred("ShouldUnitPowerBeSecret", unit)
    callPred("ShouldUnitPowerMaxBeSecret", unit)
    callPred("ShouldUnitSpellCastingBeSecret", unit)
    callPred("ShouldUnitStatsBeSecret")
    callPred("ShouldUnitThreatStateBeSecret", "player", unit)
    callPred("ShouldUnitThreatValuesBeSecret", "player", unit)
    callPred("ShouldUnitComparisonBeSecret", "player", unit)
    callPred("ShouldAurasBeSecret")
    callPred("HasSecretRestrictions")
    callPred("CanCompareUnitTokens", "player", unit)
end

local function probeIdentity(unit, out)
    out.identity = {}
    local function rec(field, fn, ...)
        local ok, v, w = safeCall(fn, ...)
        out.identity[field] = {
            ok     = ok,
            kind   = describe(v),
            secret = tagSecret(v),
            raw    = safeRaw(ok, v),
            extra  = (ok and w ~= nil) and { kind = describe(w), secret = tagSecret(w) } or nil,
        }
    end
    rec("UnitName",    _G.UnitName,    unit)
    rec("UnitGUID",    _G.UnitGUID,    unit)
    rec("GetUnitName", _G.GetUnitName, unit, true)
end

local function probeHealthAndStats(unit, out)
    out.health = {}
    local function rec(field, fn, ...)
        local ok, v = safeCall(fn, ...)
        out.health[field] = {
            ok     = ok,
            kind   = describe(v),
            secret = tagSecret(v),
            raw    = safeRaw(ok, v),
        }
    end
    rec("UnitHealth",        _G.UnitHealth,    unit)
    rec("UnitHealthMax",     _G.UnitHealthMax, unit)
    rec("UnitPower",         _G.UnitPower,     unit)
    rec("UnitPowerMax",      _G.UnitPowerMax,  unit)
    rec("UnitLevel",         _G.UnitLevel,     unit)
    rec("UnitClassification",_G.UnitClassification, unit)
    rec("UnitCreatureType",  _G.UnitCreatureType,   unit)
    rec("UnitCreatureFamily",_G.UnitCreatureFamily, unit)
    rec("UnitRace",          _G.UnitRace,           unit)
    rec("UnitIsTapDenied",   _G.UnitIsTapDenied,    unit)
    rec("UnitCanAttack",     _G.UnitCanAttack, "player", unit)
    rec("UnitReaction",      _G.UnitReaction,  "player", unit)
    if _G.UnitSelectionType then
        rec("UnitSelectionType", _G.UnitSelectionType, unit)
    end
    if _G.UnitIsQuestBoss then
        rec("UnitIsQuestBoss", _G.UnitIsQuestBoss, unit)
    end
    if _G.UnitIsPossessed then
        rec("UnitIsPossessed", _G.UnitIsPossessed, unit)
    end
    if _G.UnitNameplateShowsWidgetsAsInteractive then
        rec("UnitNameplateShowsWidgetsAsInteractive",
            _G.UnitNameplateShowsWidgetsAsInteractive, unit)
    end
    -- Test direct unit-token comparison: can we discover the player is
    -- pointing at the same mob via two different tokens?
    if _G.UnitIsUnit then
        rec("UnitIsUnit_vs_target", _G.UnitIsUnit, unit, "target")
        rec("UnitIsUnit_vs_focus",  _G.UnitIsUnit, unit, "focus")
    end
    -- RAID TARGET MARKER — the human-as-identifier workflow.
    -- Markers are cooperative party metadata (player-set), so they
    -- *should* be clean even on hostile mobs in instances. If they are,
    -- "skull = kick" becomes a clean workflow with zero secret reads.
    if _G.GetRaidTargetIndex then
        rec("GetRaidTargetIndex", _G.GetRaidTargetIndex, unit)
    end
end

----------------------------------------------------------------------
-- Deferred model probe — model loads asynchronously, so we re-read
-- after a short delay.
----------------------------------------------------------------------
local function probeModelDeferred(unit, entry)
    local m = getSharedModel()
    -- Reset the model state and assign the unit. The HOLDER parent is
    -- Hide()'d so even if the model briefly renders, nothing shows.
    m:ClearModel()
    local ok_set = pcall(m.SetUnit, m, unit)
    entry.model = entry.model or {}
    entry.model.set_unit_ok = ok_set
    -- Read immediately (cache for comparison)
    local ok_id_0, id_0 = pcall(m.GetDisplayInfo, m)
    local ok_fid_0, fid_0 = pcall(m.GetModelFileID, m)
    entry.model.immediate = {
        GetDisplayInfo = { ok = ok_id_0, kind = describe(id_0),
                           secret = tagSecret(id_0), raw = safeRaw(ok_id_0, id_0) },
        GetModelFileID = { ok = ok_fid_0, kind = describe(fid_0),
                           secret = tagSecret(fid_0), raw = safeRaw(ok_fid_0, fid_0) },
    }
    -- Re-read after 0.6s, by which time the engine has loaded the model.
    if C_Timer and C_Timer.After then
        C_Timer.After(0.6, function()
            local ok_id, id = pcall(m.GetDisplayInfo, m)
            local ok_fid, fid = pcall(m.GetModelFileID, m)
            entry.model.deferred = {
                GetDisplayInfo = { ok = ok_id, kind = describe(id),
                                   secret = tagSecret(id), raw = safeRaw(ok_id, id) },
                GetModelFileID = { ok = ok_fid, kind = describe(fid),
                                   secret = tagSecret(fid), raw = safeRaw(ok_fid, fid) },
            }
            -- Clear the model after we're done so it can't render anything.
            pcall(m.ClearModel, m)
        end)
    end
end

----------------------------------------------------------------------
-- AURA probe — the new lead.
-- ShouldAurasBeSecret returns FALSE globally. Per-unit auras MIGHT also
-- be readable. If the Magister has any passive aura with a clean spell
-- ID, we have our fingerprint.
----------------------------------------------------------------------
local function probeAuras(unit, out)
    out.auras = { helpful = {}, harmful = {} }
    local CUA = _G.C_UnitAuras
    if type(CUA) ~= "table" then
        out.auras.error = "C_UnitAuras missing"
        return
    end

    -- Per-unit aura-index predicates first — does Blizzard say each
    -- specific index is gated?
    if _G.C_Secrets and _G.C_Secrets.ShouldUnitAuraIndexBeSecret then
        out.auras.predicates = {}
        for idx = 1, 5 do
            local ok, isS = safeCall(_G.C_Secrets.ShouldUnitAuraIndexBeSecret,
                                     unit, idx, "HELPFUL")
            out.auras.predicates["helpful_" .. idx] = {
                ok = ok, raw = safeRaw(ok, isS),
                kind = describe(isS), secret = tagSecret(isS),
            }
            local okH, isH = safeCall(_G.C_Secrets.ShouldUnitAuraIndexBeSecret,
                                      unit, idx, "HARMFUL")
            out.auras.predicates["harmful_" .. idx] = {
                ok = okH, raw = safeRaw(okH, isH),
                kind = describe(isH), secret = tagSecret(isH),
            }
        end
    end

    -- Try the new batched API: C_UnitAuras.GetAuras(unit)
    if type(CUA.GetAuras) == "function" then
        local ok, aurasTbl = safeCall(CUA.GetAuras, unit)
        out.auras.GetAuras = {
            ok = ok,
            kind = describe(aurasTbl),
            count = (ok and type(aurasTbl) == "table") and #aurasTbl or nil,
        }
        if ok and type(aurasTbl) == "table" then
            out.auras.GetAuras.sample = {}
            for i = 1, math.min(#aurasTbl, 5) do
                local a = aurasTbl[i]
                if type(a) == "table" then
                    out.auras.GetAuras.sample[i] = {
                        spellId        = safeRaw(true, a.spellId),
                        spellId_secret = tagSecret(a.spellId),
                        name           = safeRaw(true, a.name),
                        name_secret    = tagSecret(a.name),
                        sourceUnit     = safeRaw(true, a.sourceUnit),
                        isHelpful      = safeRaw(true, a.isHelpful),
                        isHarmful      = safeRaw(true, a.isHarmful),
                    }
                end
            end
        end
    end

    -- Walk indexed API: GetAuraDataByIndex(unit, index, filter)
    local function walkFilter(filter, out_bucket)
        if type(CUA.GetAuraDataByIndex) ~= "function" then
            out_bucket.error = "GetAuraDataByIndex missing"
            return
        end
        for idx = 1, 10 do
            local ok, info = safeCall(CUA.GetAuraDataByIndex, unit, idx, filter)
            if ok and type(info) == "table" then
                out_bucket[idx] = {
                    spellId        = safeRaw(true, info.spellId),
                    spellId_secret = tagSecret(info.spellId),
                    name           = safeRaw(true, info.name),
                    name_secret    = tagSecret(info.name),
                    sourceUnit     = safeRaw(true, info.sourceUnit),
                    duration       = safeRaw(true, info.duration),
                    duration_secret= tagSecret(info.duration),
                }
            elseif not ok then
                out_bucket["err_" .. idx] = tostring(info)
                break
            else
                -- No more auras at this index
                break
            end
        end
    end
    walkFilter("HELPFUL", out.auras.helpful)
    walkFilter("HARMFUL", out.auras.harmful)
end

local function probeNameplate(unit, out)
    out.nameplate = {}
    local C_NP = _G.C_NamePlate
    if type(C_NP) ~= "table" or type(C_NP.GetNamePlateForUnit) ~= "function" then
        out.nameplate.error = "C_NamePlate missing"
        return
    end
    local ok, np = safeCall(C_NP.GetNamePlateForUnit, unit)
    if not ok or not np then
        out.nameplate.no_nameplate = true
        return
    end
    out.nameplate.name      = np:GetName()
    out.nameplate.visible   = np:IsVisible()
    out.nameplate.unit_attr = np.namePlateUnitToken or np.unit
    local ucf = np.UnitFrame
    if ucf then
        out.nameplate.has_unit_frame = true
        if ucf.castBar then
            out.nameplate.castbar_visible = ucf.castBar:IsVisible()
            local cok, v = safeCall(ucf.castBar.GetValue, ucf.castBar)
            out.nameplate.castbar_value = {
                ok = cok, kind = describe(v),
                secret = tagSecret(v), raw = safeRaw(cok, v),
            }
        end
    end
end

local function probeThreat(unit, out)
    out.threat = {}
    local function rec(field, fn, ...)
        local ok, v = safeCall(fn, ...)
        out.threat[field] = {
            ok     = ok,
            kind   = describe(v),
            secret = tagSecret(v),
            raw    = safeRaw(ok, v),
        }
    end
    if _G.UnitThreatSituation then
        rec("UnitThreatSituation_self", _G.UnitThreatSituation, "player", unit)
    end
    if _G.UnitDetailedThreatSituation then
        rec("UnitDetailedThreatSituation", _G.UnitDetailedThreatSituation, "player", unit)
    end
end

----------------------------------------------------------------------
-- Snapshot
----------------------------------------------------------------------
local function snapshot(unit)
    if type(unit) ~= "string" then return end
    if not _G.UnitExists or not UnitExists(unit) then return end
    local canAttack = _G.UnitCanAttack and UnitCanAttack("player", unit)
    if not canAttack then return end

    VoidRaidToolsReaderDB = VoidRaidToolsReaderDB or {}
    VoidRaidToolsReaderDB.identity_probes = VoidRaidToolsReaderDB.identity_probes or {}

    local entry = {
        ts       = time(),
        gt       = GetTime(),
        unit     = unit,
        instance = (function()
            local cok, inst = safeCall(GetInstanceInfo)
            return cok and inst or "?"
        end)(),
    }

    probeC_Secrets(unit, entry)
    probeIdentity(unit, entry)
    probeHealthAndStats(unit, entry)
    probeAuras(unit, entry)
    probeNameplate(unit, entry)
    probeThreat(unit, entry)
    probeModelDeferred(unit, entry)  -- writes entry.model.immediate now, entry.model.deferred in 0.6s

    local probes = VoidRaidToolsReaderDB.identity_probes
    probes[#probes + 1] = entry
    _capLog(probes, 200)
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------
local frame = CreateFrame("Frame", "VRT_R_IdentityProbes")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("UNIT_SPELLCAST_START")

local last_fire = {}

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_TARGET_CHANGED" then
        snapshot("target")
    elseif event == "PLAYER_FOCUS_CHANGED" then
        snapshot("focus")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        if type(arg1) == "string" then
            local gt = GetTime()
            if (last_fire[arg1] or 0) + 2 < gt then
                last_fire[arg1] = gt
                snapshot(arg1)
            end
        end
    elseif event == "UNIT_SPELLCAST_START" then
        if arg1 == "target" or arg1 == "focus"
           or (type(arg1) == "string" and arg1:find("^nameplate")) then
            snapshot(arg1)
        end
    end
end)

----------------------------------------------------------------------
-- Summary slash command
----------------------------------------------------------------------
SLASH_VRTIPSUMMARY1 = "/vrtipsummary"
SlashCmdList["VRTIPSUMMARY"] = function()
    local db = VoidRaidToolsReaderDB and VoidRaidToolsReaderDB.identity_probes
    if not db or #db == 0 then
        print("|cffff8040[VRT-R IP]|r no probe entries yet")
        return
    end
    local clean_counts, secret_counts, raw_samples, total = {}, {}, {}, 0
    for _, e in ipairs(db) do
        total = total + 1
        local function tally(prefix, group)
            if type(group) ~= "table" then return end
            for k, v in pairs(group) do
                if type(v) == "table" and v.secret then
                    local key = prefix .. "." .. k
                    if v.secret == "clean" then
                        clean_counts[key] = (clean_counts[key] or 0) + 1
                        if v.raw ~= nil and not raw_samples[key] then
                            raw_samples[key] = tostring(v.raw)
                        end
                    elseif v.secret == "secret" then
                        secret_counts[key] = (secret_counts[key] or 0) + 1
                    end
                end
            end
        end
        tally("identity",   e.identity)
        tally("health",     e.health)
        tally("threat",     e.threat)
        tally("predicates", e.predicates)
        if e.model then
            tally("model.imm",      e.model.immediate)
            tally("model.deferred", e.model.deferred)
        end
    end
    print("|cff00c7ff[VRT-R IP]|r " .. total .. " entries. Clean fields (sample raw):")
    local rows = {}
    for k, n in pairs(clean_counts) do
        rows[#rows + 1] = { k = k, clean = n, secret = secret_counts[k] or 0, sample = raw_samples[k] or "" }
    end
    table.sort(rows, function(a, b) return a.clean > b.clean end)
    for _, r in ipairs(rows) do
        print(("  %s: clean=%d  secret=%d  sample=%s"):format(r.k, r.clean, r.secret, r.sample))
    end
end

----------------------------------------------------------------------
-- TargetUnit by name — the load-bearing test for ScanAndMark.
--
-- Stand near (but NOT in combat with) a Magister group. Type:
--   /vrttarget Arcane Magister
--
-- The addon will:
--   1) save your current target
--   2) attempt TargetUnit("Arcane Magister")
--   3) report whether a target was acquired
--   4) check whether it's hostile + attackable
--   5) attempt SetRaidTarget(target, 8) to place a skull
--   6) read back the marker via the clean type() trick
--   7) restore your previous target
--   8) print everything to chat AND save to SavedVariables
--
-- Default mob name if no argument: "Arcane Magister".
----------------------------------------------------------------------
SLASH_VRTTARGET1 = "/vrttarget"
SlashCmdList["VRTTARGET"] = function(arg)
    local mob_name = (arg and arg ~= "") and arg or "Arcane Magister"

    VoidRaidToolsReaderDB = VoidRaidToolsReaderDB or {}
    VoidRaidToolsReaderDB.target_tests = VoidRaidToolsReaderDB.target_tests or {}
    local log = {
        ts        = time(),
        mob_name  = mob_name,
        instance  = (function()
            local cok, inst = safeCall(GetInstanceInfo)
            return cok and inst or "?"
        end)(),
        in_combat = _G.UnitAffectingCombat and UnitAffectingCombat("player") or "?",
    }

    local print_line = function(s)
        print("|cff00c7ff[VRT-R TARGET]|r " .. s)
    end

    print_line("Testing TargetUnit(\"" .. mob_name .. "\")")
    log.had_target_before = UnitExists("target")
    log.target_was_hostile_before = log.had_target_before and UnitCanAttack("player", "target") or false

    -- The actual call
    local ok_call, err_call = pcall(TargetUnit, mob_name)
    log.targetunit_call_ok = ok_call
    if not ok_call then
        log.targetunit_err = tostring(err_call)
        print_line("  TargetUnit threw: " .. tostring(err_call))
    end

    -- Check what happened to our target
    log.target_exists_after = UnitExists("target")
    log.target_is_hostile  = log.target_exists_after and UnitCanAttack("player", "target") or false
    log.target_is_dead     = log.target_exists_after and UnitIsDead("target") or false

    if log.target_exists_after and log.target_is_hostile then
        print_line("  ✓ Target acquired (hostile)")
        -- Try the marker step
        local ok_mark, err_mark = pcall(SetRaidTarget, "target", 8)
        log.setraidtarget_ok = ok_mark
        if not ok_mark then
            log.setraidtarget_err = tostring(err_mark)
            print_line("  SetRaidTarget threw: " .. tostring(err_mark))
        else
            -- Read back the marker via clean type() trick
            local ok_read, marker = pcall(GetRaidTargetIndex, "target")
            log.get_marker_ok = ok_read
            log.marker_kind = type(marker)  -- "number" if marked, "nil" if not
            log.marker_is_number = (type(marker) == "number")
            log.marker_secret = tagSecret(marker)
            if log.marker_is_number then
                print_line("  ✓ SetRaidTarget worked — marker is present (kind=number)")
            else
                print_line("  ✗ SetRaidTarget called but marker not present (kind=" .. type(marker) .. ")")
            end
        end
    elseif log.target_exists_after then
        print_line("  Target acquired but NOT hostile — probably matched friendly NPC")
    else
        print_line("  No target acquired — no \"" .. mob_name .. "\" in range, OR call was blocked")
    end

    -- Restore tank's previous target
    if log.had_target_before then
        pcall(TargetLastTarget)
        log.restore_attempted = true
    else
        pcall(ClearTarget)
        log.restore_attempted = false
    end

    -- Save the log
    VoidRaidToolsReaderDB.target_tests[#VoidRaidToolsReaderDB.target_tests + 1] = log
    _capLog(VoidRaidToolsReaderDB.target_tests, 50)

    print_line("  log saved (entry #" .. #VoidRaidToolsReaderDB.target_tests .. ")")
end

return IP
