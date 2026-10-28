# VoidRaidToolsReader Changelog

## [1.0.10] — 2026-10-15

### Changed
- **Records less.** In the open world it now records only fights with **rares and world bosses** (it used to record every fight anywhere). Raids, dungeons and delves are unchanged.
- Turned off old research logging that recorded game events, system messages and every played sound into your saved data — none of it was used. Your saved file gets smaller.
- The privacy section now spells out exactly when it records.

## [1.0.9] — 2026-10-14

### Changed
- Updated for WoW 12.1.5 — no longer shows as out of date.

## [1.0.8] — 2026-10-06

### Changed
- The Void addons info panel (`/vhub info`) now lists only the addons you can actually get, with up-to-date descriptions.

## [1.0.7] — 2026-08-11

### Fixed
- **Patch 12.1 taint crashes:** the `UNIT_AURA` handler threw secret-value errors
  in instances — first a boolean test on secret `isFullUpdate`
  (`SessionRecorder.lua:562`), then `ipairs` on the now-secret `addedAuras` table
  (`:577`). All secret-prone aura data (`isFullUpdate`, the `addedAuras` list, and
  per-aura `isHarmful`/`spellId`) is now guarded with `issecretvalue`; the raw
  UNIT_AURA capture path is skipped when the payload is secret (instanced aura
  data still comes from the periodic probe / ETEA), so no more Lua error spam.

### Changed
- Compatibility with patch 12.1 "Curse of Ula'tek" (TOC interface bump to 12.1).

## 1.0.6 — 2026-06-22

### Changed
- Quieter login — removed the leftover "poly detector armed" startup line.

## 1.0.5 — 2026-06-22

### Changed
- Quieter startup — removed the load-banner chat messages that printed on login.

## 1.0.4 — 2026-06-20

### Compatibility
- Updated for WoW **12.0.7** (Sporefall). Verified every C_* API call against the patched client — all present; no code changes needed.

## 1.0.3 — 2026-06-10

### Changed
- **Consent dialog now spells out the uploader requirement.** Previously the dialog said "Allow uploads will upload sessions to voidscout.io" which made it sound like clicking the button was sufficient. In reality the Lua sandbox prohibits addons from making HTTP requests directly, so a separate background daemon (`voidscout-uploader.exe`) has to be installed for data to actually leave the machine. The dialog now includes a "STEP 2 — you also need the uploader" section with a copyable GitHub Releases URL.
- `CONSENT_VERSION` bumped 1 → 2 so existing users see the updated dialog once on next login.
- `/vrtr` slash now also prints the uploader URL when consent is "allowed", in case the user forgot or the daemon got killed.

## 1.0.2 — 2026-06-10

### Fixed
- **First-session crash**: `SessionRecorder.generateUUID()` called `math.randomseed`, which Blizzard removed from the WoW Lua sandbox in 12.0.5. The session's first event push crashed with `attempt to call a nil value`, blocking the entire Reader from recording. `math.random` is already pre-seeded — the seed call was both unnecessary and fatal.
- **Script-time-limit watchdog crashes mid-raid**: 14 ring-buffer sites across `SessionRecorder.lua`, `Core.lua`, and `IdentityProbes.lua` used the naive `while #t > cap do table.remove(t, 1) end` pattern. `table.remove(t, 1)` shifts every element — so once a buffer crossed its cap, every subsequent event triggered a full-array shift. In a 20-man raid (~50+ events/sec) the watchdog fired within a minute and dumped errors like `"Script has exceeded its execution time limit"` (we saw counts of 48-67). All sites replaced with a single O(n) bulk drop of the oldest 10% — next 10% of appends are then free, amortizing the cost.

### Internal
- Added `_capLog(t, cap)` helper in `Core.lua` (exported as `VoidRaidToolsReader_capLog`); mirrored in `IdentityProbes.lua` so each file is self-contained.

## 1.0.1 — 2026-06-09

### Added
- First-run consent dialog explaining what gets uploaded and offering an "Allow uploads" / "Local-only" choice. Persists in `VoidRaidToolsReaderDB.consent`.
- `/vrtr` slash for consent state + opt-out: `/vrtr optout` (local-only), `/vrtr optin` (allow uploads), `/vrtr` (show current state, open dialog if undecided).
- `VRTReader_IsUploadAllowed()` public predicate that `SessionRecorder.queueForUpload` checks before pushing to `pending_uploads`. Local-only mode still records sessions to disk for `/vrtsr` inspection, just doesn't queue for upload.
- `PLAYER_LOGIN` backfill drainer in `SessionRecorder`: any stored session that finished but never hit the upload queue (logout/disband/reload mid-fight skipped `endSession`) gets pushed in now, deduped by `session_id`.
- README documenting exactly what's collected, what isn't, and the TOS posture (same data shape as Warcraft Logs / Archon / WoWAnalyzer combat-log uploads).

## 1.0.0 — 2026-06

First release. Silent session recorder for VoidRaidTools. Captures per-encounter ETEA events + friendly aura applications + group composition to `VoidRaidToolsReaderDB`. Go uploader at `voidscout-uploader/` drains the queue to `api.voidscout.io`.
