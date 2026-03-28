# EpochDB — Project Epoch Community Database

A two-part system: a **WoW 3.3.5 addon** that silently collects data, and a **website** that displays community statistics.

---

## 📦 Addon Installation

1. Copy the `EpochDB/` folder into your addons directory:
   ```
   World of Warcraft/Interface/AddOns/EpochDB/
   ```
2. Restart WoW or use `/reload`
3. The addon loads automatically — no configuration needed

### What it tracks
| Category | What's recorded |
|----------|----------------|
| **Kills** | Creature name, zone, kill count, first/last kill time |
| **Loot**  | Item ID, name, quality, drop source, quantity |
| **Items** | All unique items seen in bags (ID, name, ilvl, slot, quality) |
| **Quests**| Quest name, zone, completion count, item rewards |

### Slash Commands
```
/edb          — summary stats
/edb kills    — top killed creatures
/edb items    — item count
/edb quests   — quest count
/edb loot     — loot summary
/edb reset    — clear all collected data
```

---

## ⬆ Uploading Your Data

After playing, your data is saved to:
```
WoW/WTF/Account/[YOUR_ACCOUNT]/SavedVariables/EpochDB.lua
```

1. Open the website (`https://epochdb-api.onrender.com/`)
2. Click **⬆ Upload Data** in the top-right
3. Browse to and select your `EpochDB.lua` file
4. Click **Submit to Database**

Your data merges with the community database. Kills, loot, and quests you recorded are added to the global counts.

---

## 🌐 Website

The `https://epochdb-api.onrender.com/` file is a standalone single-page app. No server required for browsing — just open it in any browser.

### Sections
- **Kills** — ranked creature kill counts, filterable by type and zone
- **Items** — item database with quality, ilvl, and source
- **Quests** — completion counts and XP rewards
- **Loot** — drop rates calculated from community data
- **Players** — leaderboard of top contributors

### Production Setup (optional)
To make uploads persistent, set up a small backend:
```
POST /api/upload   — accepts the .lua file, parses and stores data
GET  /api/stats    — returns aggregated JSON for the website
```

A simple Python/Flask or Node.js server can handle parsing the Lua SavedVariables format, which uses standard Lua table syntax.

---

## 🔧 Lua Data Format

The SavedVariables file (`EpochDB.lua`) is plain text Lua. Example structure:

```lua
EpochDBData = {
    kills = {
        ["The Lich King|Icecrown Citadel"] = {
            name = "The Lich King",
            zone = "Icecrown Citadel",
            count = 3,
            firstKill = "2024-01-15 20:11:04",
            lastKill  = "2024-01-17 21:33:41",
        },
    },
    loot = {
        ["49623"] = {
            id = "49623",
            name = "Shadowmourne",
            quality = 5,
            count = 1,
            sources = { ["The Lich King"] = 1 },
        },
    },
    quests = { ... },
    items  = { ... },
    meta = {
        player = "Arthaniel",
        realm  = "Epoch",
        class  = "DEATHKNIGHT",
    }
}
```

---

## 📋 Files

```
epoch-db/
├── index.html              ← Website (open in browser)
└── addon/
    └── EpochDB/
        ├── EpochDB.toc     ← Addon manifest
        └── EpochDB.lua     ← Main addon code
```

---

*Built for Project Epoch — WoW 3.3.5a (build 12340)*
