# VoidRaidToolsReader — required companion to VoidRaidTools

**CurseForge:** project 1570328. Not mirrored publicly. README = CF description (player-facing only, see `../README-STYLE.md`).

## Developer notes (moved from the README 2026-10-05)

- **Consent:** first `PLAYER_LOGIN` shows the dialog. "Allow" queues sessions to `pending_uploads`
  (drained by the Go `voidscout-uploader`); "Local-only" still records to `VoidRaidToolsReaderDB`
  for `/vrtsr` review but never queues. Bump `CONSENT_VERSION` when adding a data category — the
  prompt re-fires once on next login (v1→v2 in 1.0.3).
- **Payload on disk:** `VoidRaidToolsReaderDB.blackbox.sessions` in
  `WTF/.../SavedVariables/VoidRaidToolsReader.lua` after a `/reload`.
- **Capture sources:** `ENCOUNTER_TIMELINE_EVENT_ADDED` + `C_EncounterEvents.GetEventInfo` (clean
  spell ID), `UNIT_AURA` on player + party/raid tokens (encounter window only — 12.1 secret-value
  guards added in 1.0.7), `C_Map.GetPlayerMapPosition("player")` (self only).
- **Ring buffers:** use `_capLog(t, cap)` (exported `VoidRaidToolsReader_capLog`), never
  `while #t > cap do table.remove(t, 1)` — script-time-limit crashes mid-raid (1.0.2).
- **No `math.randomseed`** — removed from the 12.0.5 sandbox (1.0.2 first-session crash).
