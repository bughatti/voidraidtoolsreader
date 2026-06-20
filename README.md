# VoidRaidToolsReader

Required companion to **VoidRaidTools**. Captures boss cast events and party aura traces during raid encounters so the alert engine and Probability Score model can learn what really fires in 12.0.5 Midnight content.

## What gets uploaded

Each completed raid encounter session is queued for upload to `api.voidscout.io`:

- **Boss cast events** — `ENCOUNTER_TIMELINE_EVENT_ADDED` payloads + the clean spell ID resolved via `C_EncounterEvents.GetEventInfo`. Names are looked up at the server, not sent.
- **Group roster** — your party/raid members' names, realms, classes, specs, roles as your client renders them in the party frame.
- **Friendly aura traces** — `UNIT_AURA` fires on player + party/raid tokens during the encounter window only.
- **Encounter metadata** — encounter ID, difficulty (Normal/Heroic/Mythic), group size, kill/wipe outcome, start/end timestamp.
- **Marker updates** — count of raid-target-icon changes during the pull (not the markers themselves).
- **Your own position** — periodic `C_Map.GetPlayerMapPosition("player")` reads. Self-only; we do not read other players' positions.

## What does NOT get uploaded

- Anything outside an active encounter (no city/world/AH/queue chatter)
- Chat or whisper content
- Your gear, inventory, currency, achievements, bank
- Other addons' SavedVariables
- Anything from protected APIs or memory
- Player keystrokes, system info, hardware fingerprints

## TOS posture

Every API used is in Blizzard's documented addon surface. The data shape is identical to what Warcraft Logs, Archon, WoWAnalyzer, and Details upload — the only difference is we run the server ourselves. We don't bypass anti-cheat, we don't write to SecureActionButton in a way that's restricted, we don't read other players' positions.

## Consent model

On first `PLAYER_LOGIN` after install you'll see a dialog with two buttons:

- **Allow uploads** — Reader queues sessions to `pending_uploads` and the Go uploader drains it to the server.
- **Local-only (no upload)** — Reader still records to `VoidRaidToolsReaderDB` for offline `/vrtsr` review, but never queues for upload.

You can flip the choice anytime:

- `/vrtr` — show current state, open dialog if not yet decided
- `/vrtr optout` (or `/vrtr local`) — disable uploads
- `/vrtr optin` (or `/vrtr allow`) — enable uploads

If you bump the consent dialog's `CONSENT_VERSION` (e.g. when adding a new data category), the prompt re-fires on next login.

## Inspecting what would be uploaded

- `/vrtsr` — list of recent stored sessions (encounter name, difficulty, event counts)
- `/vrtsr queue` — the `pending_uploads` queue (what the Go uploader is about to drain)
- `/vrtsr clear-queue` — wipe the pending queue (sessions remain in `db.sessions` for inspection)

The full payload of any session sits in `VoidRaidToolsReaderDB.blackbox.sessions` — open `VoidRaidToolsReader.lua` after a `/reload` and you can read every field with any text editor.

## Source of truth

This repo is the source. The deployed copy at
`Interface/AddOns/VoidRaidToolsReader/` is a sync target. Edit the source, sync to the install dir, then `/reload`.
