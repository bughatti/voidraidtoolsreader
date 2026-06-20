----------------------------------------------------------------------
-- VoidRaidToolsReader — SessionRecorder
--
-- The Reader's "always-on" forensic mode. Captures every clean signal
-- we discovered + continuously probes unknowns so other zones surface
-- new data. All to Reader's own SavedVariables file. Silent — no chat,
-- no popup, no UI.
--
-- This is the consolidated forensic recorder (Reader is now the single
-- discovery surface; the duplicate VRT BlackBox module has been
-- retired). The Reader's other modules (Core sound capture, target
-- probes, IdentityProbes research slashes) all coexist here — see
-- VoidRaidToolsReader.toc for the file order.
--
-- Captures (all keyed under VoidRaidToolsReaderDB.sessions):
--   - Session boundaries: ENCOUNTER_START/END, CHALLENGE_MODE_*,
--     PLAYER_REGEN_DISABLED/ENABLED fallback for trash combats
--   - Position + map + zone + subzone at session start
--   - Group composition snapshot (class/spec/role) at session start
--   - ETEA boss events with CLEAN spell IDs via C_EncounterEvents
--     bridge + IsSpellImportant tagging
--   - Hostile nameplate cast events with rich probe payload (every
--     clean field we confirmed in MT + C_Secrets predicate sweep)
--   - Cast durations on STOP/SUCCEEDED/INTERRUPTED
--   - Per-fingerprint duration histogram (statistical mob ID over time)
--   - Friendly aura landings on player+party with IsSpellImportant
--   - Marker activity (count)
--   - Periodic 5s probe of all visible hostile nameplates
--
-- Bounded: 10 sessions, 5000 events per session, 200 friendly aura
-- landings per session. Older silently rolls off.
----------------------------------------------------------------------

local MAX_SESSIONS          = 25
local MAX_EVENTS_PER_SESS   = 5000
-- Bumped from 200 → 1000 because the raid-wide UNIT_AURA listener
-- (player + party + raid) generates significantly more friendly aura
-- landings per minute. 1000 covers a full boss attempt in 20-man.
local MAX_AURAS_PER_SESS    = 1000
-- Upload queue cap. The Go uploader drains it on its next poll;
-- if it can't keep up (offline, retry storm), older entries roll off.
local MAX_PENDING_UPLOADS   = 20
local SCHEMA_VERSION        = "1.0"
local UPLOADER_VERSION      = "vrt-reader/0.2.0"
-- Long period — the periodic probe iterates up to MAX_PROBE_NAMEPLATES
-- nameplates with a full UnitX + C_Secrets predicate sweep per unit.
-- 30s keeps the per-tick budget well under WoW's script-timeout cap.
local PERIODIC_PROBE_PERIOD = 30.0
local MAX_PROBE_NAMEPLATES  = 10

local current_session = nil
local active_casts    = {}

----------------------------------------------------------------------
-- Storage helpers
----------------------------------------------------------------------
local function getDB()
    VoidRaidToolsReaderDB = VoidRaidToolsReaderDB or {}
    VoidRaidToolsReaderDB.blackbox = VoidRaidToolsReaderDB.blackbox or { sessions = {} }
    return VoidRaidToolsReaderDB.blackbox
end

local function getUploadQueue()
    VoidRaidToolsReaderDB = VoidRaidToolsReaderDB or {}
    VoidRaidToolsReaderDB.pending_uploads = VoidRaidToolsReaderDB.pending_uploads or {}
    return VoidRaidToolsReaderDB.pending_uploads
end

-- Generate a v4-style UUID. math.random is sufficient for session
-- identifiers — collisions across a single user's history are negligible.
-- WoW removes math.randomseed from the Lua sandbox; the RNG is already
-- seeded for us, so seeding here used to crash with "attempt to call a
-- nil value" at the call site. Just consume math.random directly.
local function generateUUID()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (string.gsub(template, "[xy]", function(c)
        local r = math.random(0, 15)
        if c == "y" then r = (r % 4) + 8 end
        return string.format("%x", r)
    end))
end

-- Ring-buffer drop: when over cap, drop the oldest 10% in ONE O(n) pass
-- instead of calling table.remove(t,1) for every single overflow event.
-- The naive O(n²) version was triggering "exceeded execution time limit"
-- during 20-man raid pulls (~50 events/sec * 5000-entry shift per event).
local function dropOldest(t, cap, chunk_pct)
    local n = #t
    if n <= cap then return end
    local drop = math.floor(cap * (chunk_pct or 0.10))
    if drop < 1 then drop = 1 end
    if drop > n then drop = n end
    local m = n - drop
    for i = 1, m do
        t[i] = t[i + drop]
    end
    for i = m + 1, n do
        t[i] = nil
    end
end

local function pushEvent(kind, payload)
    if not current_session then return end
    current_session.events[#current_session.events + 1] = {
        gt      = GetTime() - current_session.start_gt,
        kind    = kind,
        payload = payload,
    }
    dropOldest(current_session.events, MAX_EVENTS_PER_SESS, 0.10)
end

local function pushAura(payload)
    if not current_session then return end
    current_session.auras = current_session.auras or {}
    current_session.auras[#current_session.auras + 1] = {
        gt      = GetTime() - current_session.start_gt,
        payload = payload,
    }
    dropOldest(current_session.auras, MAX_AURAS_PER_SESS, 0.10)
end

local function incHistogram(fingerprint, duration_seconds)
    if not current_session then return end
    current_session.histogram = current_session.histogram or {}
    local h = current_session.histogram
    h[fingerprint] = h[fingerprint] or { count = 0, durations = {} }
    h[fingerprint].count = h[fingerprint].count + 1
    local bucket = math.floor(duration_seconds * 10 + 0.5) / 10
    h[fingerprint].durations[tostring(bucket)] =
        (h[fingerprint].durations[tostring(bucket)] or 0) + 1
end

local function snapshotPosition()
    local map_id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not map_id then return nil end
    local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map_id, "player")
    return {
        map_id  = map_id,
        zone    = GetRealZoneText() or GetZoneText(),
        subzone = GetSubZoneText(),
        x       = pos and pos.x or nil,
        y       = pos and pos.y or nil,
    }
end

local function snapshotGroup()
    local group = { player = {} }
    local _, plr_class = UnitClass("player")
    group.player.class = plr_class
    if GetSpecialization then
        local idx = GetSpecialization()
        if idx then
            local _, name = GetSpecializationInfo(idx)
            group.player.spec = name
        end
    end
    group.player.role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or nil
    local members = {}
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            local _, cls = UnitClass(u)
            members[#members + 1] = {
                unit  = u,
                class = cls,
                role  = UnitGroupRolesAssigned and UnitGroupRolesAssigned(u) or nil,
            }
        end
    end
    group.party = members
    return group
end

----------------------------------------------------------------------
-- Fingerprint + probe helpers
----------------------------------------------------------------------
local function getFingerprint(unit)
    if not UnitExists(unit) then return nil end
    if not UnitCanAttack("player", unit) then return nil end
    local cls = UnitClassification(unit)
    if cls ~= "elite" and cls ~= "rare" and cls ~= "rareelite" then return nil end
    local family_type = type((UnitCreatureFamily(unit)))
    return cls .. "/" .. family_type
end

local function sweepPredicates(unit)
    local Sec = _G.C_Secrets
    if type(Sec) ~= "table" then return nil end
    local function call(fname, ...)
        local fn = Sec[fname]
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if not ok then return nil end
        return v
    end
    return {
        identity     = call("ShouldUnitIdentityBeSecret", unit),
        health_max   = call("ShouldUnitHealthMaxBeSecret", unit),
        casting      = call("ShouldUnitSpellCastingBeSecret", unit),
        power        = call("ShouldUnitPowerBeSecret", unit),
        threat_state = call("ShouldUnitThreatStateBeSecret", "player", unit),
        comparison   = call("ShouldUnitComparisonBeSecret", "player", unit),
        auras_global = call("ShouldAurasBeSecret"),
        stats_global = call("ShouldUnitStatsBeSecret"),
    }
end

local function probeNameplate(unit)
    return {
        unit          = unit,
        marked        = (type(GetRaidTargetIndex(unit)) == "number"),
        classification = UnitClassification(unit),
        family_type   = type((UnitCreatureFamily(unit))),
        level         = UnitLevel(unit),
        reaction      = UnitReaction("player", unit),
        is_quest_boss = UnitIsQuestBoss and UnitIsQuestBoss(unit) or nil,
        tap_denied    = UnitIsTapDenied(unit),
        is_dead       = UnitIsDead(unit),
        can_attack    = UnitCanAttack("player", unit),
        is_target     = UnitIsUnit(unit, "target"),
        is_focus      = UnitIsUnit(unit, "focus"),
        selection     = UnitSelectionType and UnitSelectionType(unit) or nil,
        predicates    = sweepPredicates(unit),
    }
end

local function tagSpellImportant(spell_id)
    if not spell_id then return nil end
    if C_Spell and C_Spell.IsSpellImportant then
        local ok, v = pcall(C_Spell.IsSpellImportant, spell_id)
        if ok then return v end
    end
    return nil
end

----------------------------------------------------------------------
-- Session lifecycle
----------------------------------------------------------------------
local function startSession(label, info)
    if current_session then current_session.end_ts = time() end
    local db = getDB()
    current_session = {
        label      = label,
        session_id = generateUUID(),
        start_ts   = time(),
        start_gt   = GetTime(),
        info       = info or {},
        position   = snapshotPosition(),
        group      = snapshotGroup(),
        events     = {},
        auras      = {},
        histogram  = {},
    }
    db.sessions[#db.sessions + 1] = current_session
    dropOldest(db.sessions, MAX_SESSIONS, 0.20)
    active_casts = {}
end

----------------------------------------------------------------------
-- Build the upload-shaped table per schema_version 1.0.
-- See voidscout-data/session_recorder_schema.md for the wire format.
-- The Go uploader (task #112) drains pending_uploads and JSONifies on
-- the Go side — addon stays in Lua tables to avoid double-serialization.
----------------------------------------------------------------------
local function buildExportTable(s)
    if not s then return nil end

    local info = s.info or {}
    local duration_s = (s.end_gt and s.start_gt) and (s.end_gt - s.start_gt) or 0
    local probe_samples = {}
    local marker_update_count = 0
    local out_events = {}
    for _, ev in ipairs(s.events or {}) do
        local p = ev.payload or {}
        if ev.kind == "marker_update" then
            marker_update_count = marker_update_count + 1
        elseif ev.kind == "probe_sample" then
            probe_samples[#probe_samples + 1] = {
                gt        = ev.gt,
                position  = p.position,
                nameplates = p.nameplates,
            }
        elseif ev.kind == "etea" then
            out_events[#out_events + 1] = {
                gt        = ev.gt,
                kind      = "etea",
                etea_id   = p.id,
                spell_id  = p.clean_spell_id,
                etea_kind = p.kind,
                target    = p.target,
                important = p.important,
            }
        elseif ev.kind == "cast_start" then
            out_events[#out_events + 1] = {
                gt             = ev.gt,
                kind           = "cast_start",
                unit           = p.unit,
                marked         = p.marked,
                fingerprint    = p.fingerprint,
                classification = p.classification,
            }
        elseif ev.kind == "cast_done" then
            out_events[#out_events + 1] = {
                gt          = ev.gt,
                kind        = "cast_done",
                unit        = p.unit,
                duration    = p.duration,
                marked      = p.marked,
                fingerprint = p.fingerprint,
            }
        elseif ev.kind == "cast_interrupted" then
            out_events[#out_events + 1] = {
                gt          = ev.gt,
                kind        = "cast_interrupted",
                unit        = p.unit,
                duration    = p.duration,
                marked      = p.marked,
                fingerprint = p.fingerprint,
            }
        end
    end

    local out_auras = {}
    for _, a in ipairs(s.auras or {}) do
        local p = a.payload or {}
        out_auras[#out_auras + 1] = {
            gt          = a.gt,
            target_unit = p.target_unit,
            source_unit = p.source_unit,
            spell_id    = p.spell_id,
            spell_name  = p.spell_name,
            is_helpful  = p.is_helpful,
            is_harmful  = p.is_harmful,
            duration    = p.duration,
            important   = p.important,
        }
    end

    local encounter
    if s.label == "encounter" then
        encounter = {
            id         = info.id,
            name       = info.name,
            difficulty = info.difficulty,
            group_size = info.group_size,
            success    = s.success,
        }
    elseif s.label == "mplus" then
        encounter = {
            id     = info.map_id,
            map_id = info.map_id,
            zone   = info.zone,
        }
    end

    return {
        schema_version    = SCHEMA_VERSION,
        uploader_version  = UPLOADER_VERSION,
        session_id        = s.session_id,
        label             = s.label,
        encounter         = encounter,
        timing = {
            start_ts   = s.start_ts,
            end_ts     = s.end_ts,
            duration_s = duration_s,
        },
        position             = s.position,
        group                = s.group,
        events               = out_events,
        auras                = out_auras,
        histogram            = s.histogram or {},
        probe_samples        = probe_samples,
        marker_update_count  = marker_update_count,
    }
end

local function queueForUpload(s)
    if not s then return end
    -- Consent gate. If the user picked "local-only" in the consent
    -- dialog, we still keep the session in db.sessions for /vrtsr
    -- review but we don't push it to pending_uploads (so the Go
    -- uploader has nothing to drain).
    if VRTReader_IsUploadAllowed and not VRTReader_IsUploadAllowed() then
        return
    end
    -- Skip very short "combat" fallback sessions — these are usually
    -- trash-pull noise. Encounter and M+ sessions always queue.
    if s.label == "combat" then
        local dur = (s.end_gt and s.start_gt) and (s.end_gt - s.start_gt) or 0
        if dur < 5 then return end
    end
    local export = buildExportTable(s)
    if not export then return end
    local q = getUploadQueue()
    q[#q + 1] = {
        queued_ts = time(),
        status    = "pending",
        payload   = export,
    }
    dropOldest(q, MAX_PENDING_UPLOADS, 0.20)
end

local function endSession(success)
    if not current_session then return end
    current_session.end_ts  = time()
    current_session.end_gt  = GetTime()
    current_session.success = success
    -- Queue the export-shaped snapshot for the Go uploader. We keep
    -- the original session in db.sessions for /vrtsr summary inspection,
    -- and ALSO push the slim export to pending_uploads. Two copies for
    -- now until the Go uploader is verified working.
    queueForUpload(current_session)
    current_session = nil
    active_casts = {}
end

local function periodicProbe()
    if not current_session then return end
    local samples = {}
    -- Capped to MAX_PROBE_NAMEPLATES to keep tick budget safe. Each
    -- probe runs ~20 function calls (UnitX + 8 C_Secrets predicates);
    -- 10 nameplates = 200 calls per tick, fine.
    local taken = 0
    for i = 1, 40 do
        if taken >= MAX_PROBE_NAMEPLATES then break end
        local u = "nameplate" .. i
        if UnitExists(u) and UnitCanAttack("player", u) then
            samples[#samples + 1] = probeNameplate(u)
            taken = taken + 1
        end
    end
    if #samples > 0 then
        pushEvent("probe_sample", { nameplates = samples, position = snapshotPosition() })
    end
end

----------------------------------------------------------------------
-- Event handler
----------------------------------------------------------------------
local function OnEvent(_, event, ...)
    if event == "ENCOUNTER_START" then
        local encounterID, encounterName, difficultyID, groupSize = ...
        startSession("encounter", {
            id = encounterID, name = encounterName,
            difficulty = difficultyID, group_size = groupSize,
        })

    elseif event == "ENCOUNTER_END" then
        local _, _, _, _, success = ...
        endSession(success == 1)

    elseif event == "CHALLENGE_MODE_START" then
        local map_id
        if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
            map_id = C_ChallengeMode.GetActiveChallengeMapID()
        end
        startSession("mplus", {
            map_id = map_id, zone = GetRealZoneText() or GetZoneText(),
        })

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        endSession(true)

    elseif event == "PLAYER_REGEN_DISABLED" then
        if not current_session then startSession("combat", {}) end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended. Close ANY active session — not just "combat"
        -- label. Raid resets / wipes don't always fire ENCOUNTER_END,
        -- so without this an encounter session stays open and the
        -- NEXT combat (trash, different boss) gets concatenated into
        -- the same session. That contamination broke our Lightblinded
        -- second-pull analysis. Close it here, let the next
        -- ENCOUNTER_START/PLAYER_REGEN_DISABLED start a fresh one.
        if current_session then
            endSession(nil)
        end

    elseif event == "ENCOUNTER_TIMELINE_EVENT_ADDED" then
        local eventInfo = ...
        if eventInfo and current_session then
            local clean_spell_id
            if C_EncounterEvents and C_EncounterEvents.GetEventInfo then
                local info = C_EncounterEvents.GetEventInfo(eventInfo.id)
                if info then clean_spell_id = info.spellID end
            end
            pushEvent("etea", {
                id             = eventInfo.id,
                clean_spell_id = clean_spell_id,
                important      = tagSpellImportant(clean_spell_id),
                kind           = eventInfo.kind,
                target         = eventInfo.target,
            })
        end

    elseif event == "UNIT_SPELLCAST_START"
        or event == "UNIT_SPELLCAST_CHANNEL_START" then
        local unit = ...
        if type(unit) == "string" and unit:find("^nameplate") then
            -- LIGHTWEIGHT cast capture — no full probe / no predicate
            -- sweep here. Per-cast probes were the second hot path that
            -- could pile up during busy raid pulls. The periodic probe
            -- still captures full state every 30s.
            local fp = getFingerprint(unit)
            local marked = (type(GetRaidTargetIndex(unit)) == "number")
            active_casts[unit] = {
                start_gt    = GetTime(),
                fingerprint = fp,
                marked      = marked,
            }
            pushEvent("cast_start", {
                unit        = unit,
                marked      = marked,
                fingerprint = fp,
                classification = UnitClassification(unit),
            })
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local unit = ...
        if type(unit) == "string" and active_casts[unit] then
            local rec = active_casts[unit]
            local duration = GetTime() - rec.start_gt
            pushEvent("cast_done", {
                unit = unit, duration = duration,
                marked = rec.marked, fingerprint = rec.fingerprint,
            })
            if rec.fingerprint then incHistogram(rec.fingerprint, duration) end
            active_casts[unit] = nil
        end

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        local unit = ...
        if type(unit) == "string" and active_casts[unit] then
            local rec = active_casts[unit]
            local duration = GetTime() - rec.start_gt
            pushEvent("cast_interrupted", {
                unit = unit, duration = duration,
                marked = rec.marked, fingerprint = rec.fingerprint,
            })
            active_casts[unit] = nil
        end

    elseif event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_STOP" then
        local unit = ...
        if type(unit) == "string" and active_casts[unit] then
            active_casts[unit] = nil
        end

    elseif event == "UNIT_AURA" then
        local unit, updateInfo = ...
        if type(unit) ~= "string" then return end
        -- Watch player, party (5-man), AND raid (raid1..raid40). The
        -- raid listener is needed for tank-swap detection — raid tanks
        -- are typically in other raid sub-groups, NOT your party slots.
        if unit ~= "player"
           and not unit:find("^party")
           and not unit:find("^raid") then return end
        if not updateInfo then return end
        if updateInfo.isFullUpdate then return end
        if updateInfo.addedAuras then
            -- In a raid, helpful auras (HoTs, buffs, raid CDs) are
            -- VERY high volume. Skip them to keep the bucket focused
            -- on harmful auras (debuffs / mechanic landings), which
            -- is what we actually need for tank-swap detection and
            -- post-fight mechanic analysis.
            local in_raid = IsInRaid and IsInRaid()
            for _, info in ipairs(updateInfo.addedAuras) do
                if info.spellId
                   and (not in_raid or info.isHarmful) then
                    pushAura({
                        target_unit = unit,
                        spell_id    = info.spellId,
                        spell_name  = info.name,
                        source_unit = info.sourceUnit,
                        is_helpful  = info.isHelpful,
                        is_harmful  = info.isHarmful,
                        duration    = info.duration,
                        important   = tagSpellImportant(info.spellId),
                    })
                end
            end
        end

    elseif event == "RAID_TARGET_UPDATE" then
        if current_session then pushEvent("marker_update", {}) end
    elseif event == "PLAYER_LOGIN" then
        -- Backfill drainer: any stored session that finished but never hit the
        -- upload queue (logout/disband/reload mid-fight skipped endSession) gets
        -- pushed in now. Idempotent via session_id dedup against queue.
        local db = getDB()
        local sessions = db.sessions or {}
        local q = getUploadQueue()
        local known = {}
        for _, e in ipairs(q) do
            local sid = e.payload and e.payload.session_id
            if sid then known[sid] = true end
        end
        local drained = 0
        for _, s in ipairs(sessions) do
            if s.end_ts and s.session_id and not known[s.session_id] then
                queueForUpload(s)
                drained = drained + 1
            end
        end
        if drained > 0 then
            print(("|cff00c7ff[VRT-R Sessions]|r backfilled %d stored session(s) to upload queue."):format(drained))
        end
    end
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
local frame = CreateFrame("Frame", "VRT_R_SessionRecorderFrame")
for _, ev in ipairs({
    "ENCOUNTER_START", "ENCOUNTER_END",
    "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "ENCOUNTER_TIMELINE_EVENT_ADDED",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_STOP",
    "UNIT_AURA",
    "RAID_TARGET_UPDATE",
    "PLAYER_LOGIN",
}) do
    frame:RegisterEvent(ev)
end
frame:SetScript("OnEvent", OnEvent)

local probe_ticker = C_Timer.NewTicker(PERIODIC_PROBE_PERIOD, periodicProbe)

----------------------------------------------------------------------
-- Slash: /vrtbb — silent until typed. Single discovery surface.
----------------------------------------------------------------------
-- /vrtsr — "Session Recorder" summary. (Old /vrtbb kept as alias so
-- muscle memory still works. Old data key VoidRaidToolsReaderDB.blackbox
-- is also still accepted on read for backwards compat with prior captures.)
SLASH_VRTSR1 = "/vrtsr"
SLASH_VRTSR2 = "/vrtbb"
SlashCmdList["VRTSR"] = function(arg)
    arg = (arg or ""):lower():match("^%s*(.-)%s*$")
    if arg == "queue" then
        local q = getUploadQueue()
        print(("|cff00c7ff[VRT-R Sessions]|r upload queue: %d pending"):format(#q))
        for i = math.max(1, #q - 5), #q do
            local e = q[i]
            local nm = (e.payload and e.payload.encounter and e.payload.encounter.name)
                       or (e.payload and e.payload.label) or "?"
            local n_events = e.payload and e.payload.events and #e.payload.events or 0
            local n_auras  = e.payload and e.payload.auras  and #e.payload.auras  or 0
            print(("  #%d %s %s — %d events, %d auras"):format(
                i, e.status or "pending", nm, n_events, n_auras))
        end
        print("  Drain location: VoidRaidToolsReaderDB.pending_uploads")
        return
    end
    if arg == "clear-queue" then
        VoidRaidToolsReaderDB = VoidRaidToolsReaderDB or {}
        VoidRaidToolsReaderDB.pending_uploads = {}
        print("|cff00c7ff[VRT-R Sessions]|r upload queue cleared.")
        return
    end
    local db = getDB()
    local sessions = db.sessions or {}
    print(("|cff00c7ff[VRT-R Sessions]|r %d sessions stored. Latest:"):format(#sessions))
    for i = math.max(1, #sessions - 5), #sessions do
        local s = sessions[i]
        local dur = (s.end_gt and s.start_gt) and (s.end_gt - s.start_gt) or 0
        local nm = (s.info and s.info.name) or s.label
        print(("  #%d %s %s (%.0fs, %d events, %d auras)"):format(
            i, s.label, nm or "?", dur,
            #(s.events or {}), #(s.auras or {})))
    end
    local q_count = #getUploadQueue()
    print(("  Upload queue: |cffffd700%d pending|r — /vrtsr queue, /vrtsr clear-queue"):format(q_count))
    print("  Full data: VoidRaidToolsReaderDB.blackbox.sessions")
end
