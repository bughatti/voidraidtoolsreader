# VoidRaidToolsReader — CurseForge Submission

Copy each field into the matching CurseForge form input when creating the project.

## Basic info

**Project name**: VoidRaidToolsReader

**Slug**: `voidraidtoolsreader`

**Categories**:
- Combat
- Boss Encounters
- Data Broker / API

**Game version compatibility**: 12.0.5, 12.0.7

**Project URL**: https://www.curseforge.com/wow/addons/voidraidtoolsreader

## Description

**Required companion to VoidRaidTools. Silent session recorder that captures boss cast events and party aura traces during raid encounters so the alert engine and Probability Score model can learn what really fires in 12.0.5 Midnight content.**

## What it does

- Captures `ENCOUNTER_TIMELINE_EVENT_ADDED` payloads from active raid encounters, resolving clean spell IDs via `C_EncounterEvents.GetEventInfo`.
- Captures player + party `UNIT_AURA` traces during the encounter window only.
- Records group composition (names, realms, classes, specs as your client renders them).
- Tracks encounter metadata: ID, difficulty (N/H/M), group size, kill/wipe outcome, start/end timestamps.
- Counts raid-target-icon (marker) updates.
- Periodically samples your own map position (`C_Map.GetPlayerMapPosition("player")`). Self only — never other players.

## What it does NOT do

- Read anything outside an active encounter
- Read your gear / inventory / bank / currency
- Read other players' positions
- Read chat or whispers
- Touch protected APIs, anti-cheat-evading state, or system info

## Consent model

On first `PLAYER_LOGIN` after install you'll see a one-time dialog explaining what's uploaded with two buttons:
- **Allow uploads** — sessions queue for upload to `api.voidscout.io`.
- **Local-only** — sessions still record to `VoidRaidToolsReaderDB` for offline review but never queue for upload.

Toggle anytime with `/vrtr` (status), `/vrtr optout`, `/vrtr optin`.

## The companion uploader (optional)

Uploading uses a small **separate companion app** — **voidscout-uploader** (open-source/MIT, a single
~7 MB binary, no install dependencies), **shared with VoidScout**. WoW addons can't make web requests,
so this app is what drains the queue to api.voidscout.io. Optional — the Reader works fully without it
(offline `/vrtsr` review). **Get it at https://voidscout.io/install** (or GitHub Releases:
github.com/bughatti/voidscout-uploader). One app covers both VoidScout and VoidRaidToolsReader.

## TOS posture

Every API used is in Blizzard's documented addon surface. Data shape is identical to what Warcraft Logs, Archon, and WoWAnalyzer upload — we're not in different legal territory than those tools, the only difference is we run the server.

## Required companion

Pair with [VoidRaidTools](https://www.curseforge.com/wow/addons/voidraidtools). The Reader is the data capture layer; VRT is the alert engine that consumes the analysis the server produces.

## Notes for reviewers

- Self-disabled silent operation — no UI, no chat spam.
- `/vrtsr` slash for local session inspection.
- License: Apache 2.0 (LICENSE file included).
- Source: github.com/bughatti/voidraidtoolsreader (mirror of private monorepo).
