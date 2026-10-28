# VoidRaidToolsReader

**The required companion to VoidRaidTools — records boss events so its alerts know what really happens in each fight.**

VoidRaidToolsReader quietly records boss and enemy casts and party buff/debuff traces during fights in raids and dungeons. VoidRaidTools uses that data to fire the right alerts, and — only if you allow it — your sessions help the shared model learn what each boss actually does in Midnight content.

---

## Features

- **Fight recording** — boss and enemy cast events with clean spell IDs, captured only during fights in raids, dungeons and delves, and against rares and world bosses in the open world
- **Your choice of mode** — allow uploads, or keep everything local-only; switch anytime
- **See exactly what's stored** — list recent sessions and the upload queue in game, or read the saved file in any text editor
- **Lightweight** — records only those fights; nothing in cities, queues, or ordinary open-world combat

---

## Slash Commands

| Command | What it does |
|---|---|
| `/vrtr` | Show your current upload choice (opens the consent dialog if you haven't chosen) |
| `/vrtr optout` | Switch to local-only (also `/vrtr local`) |
| `/vrtr optin` | Allow uploads (also `/vrtr allow`) |
| `/vrtsr` | List recent recorded sessions |
| `/vrtsr queue` | Show sessions waiting to upload |
| `/vrtsr clear-queue` | Empty the upload queue (sessions stay saved locally) |

---

## Getting Started

1. Install **VoidRaidToolsReader** and **VoidRaidTools** with the CurseForge app (or copy both folders into `World of Warcraft/_retail_/Interface/AddOns/`).
2. Restart WoW or `/reload`.
3. On first login, choose **Allow uploads** or **Local-only** in the consent dialog.

---

## Privacy & Data

### When it records
- **Raids, dungeons and delves** — boss encounters, Mythic+ runs and trash fights
- **Open world** — only fights with a **rare** or **world boss**

### What's recorded during a fight
- **Boss and enemy cast events** and their spell IDs (spell names are looked up on the server, not sent)
- **Your group roster** — names, realms, classes, specs, and roles, as shown in your party frames
- **Buff/debuff traces** on you and your group, during the fight only
- **Fight details** — boss or zone, difficulty, group size, kill or wipe, start and end time
- **How many times raid markers changed** (not the markers themselves)
- **Your own position** — never anyone else's

### What's never recorded
- Anything outside those fights — including ordinary open-world combat
- Chat or whispers
- Your gear, bags, currency, achievements, or bank
- Other addons' data, protected game data, keystrokes, or system/hardware info

### Uploading (optional)
WoW addons can't make web requests, so uploads go through a small separate app, **voidscout-uploader** — open source (MIT), a single ~7 MB file, nothing else to install. The same app serves VoidScout, so you only install it once.

- **Optional** — VoidRaidTools and the Reader work fully without it
- **Get it:** [voidscout.io/install](https://voidscout.io/install) or the [GitHub releases page](https://github.com/bughatti/voidscout-uploader/releases/latest)

### Playing by the rules
Every API used is part of Blizzard's documented addon interface. The data is the same kind Warcraft Logs, Archon, WoWAnalyzer, and Details upload — we just run our own server. No anti-cheat bypassing, no restricted actions, and no reading other players' positions.

---

## Compatibility

- **WoW 12.1.5** (Midnight Season 2)
- Install together with **VoidRaidTools**

---

*Part of the Void addon family by Vede · MIT licensed · free M+ & raid player lookups at [voidscout.io](https://voidscout.io) · more addons & apps at [tinkerline.io](https://tinkerline.io) · [Discord](https://discord.gg/7ZHmx7zMDh)*
