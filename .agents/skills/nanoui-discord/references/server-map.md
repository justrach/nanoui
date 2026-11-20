# Server Map & Discord API Notes

Guild **`nanoui`**: `1566720297040879660` (`COMMUNITY`, `NEWS`).
Icon URL (`256px`): `https://cdn.discordapp.com/icons/1566720297040879660/9777196fa75cb415f5c824645dd12080.png?size=256`.

## Categories & Channels (in Display Order)

| Category | Pos | Channel | Type | ID | Notes |
|---|---:|---|---|---:|---|
| `📌 INFO` (`1569192898975764481`) | 0 | `#welcome` | text (`0`) | `1569192906168860862` | Pinned welcome cards: `1569192924439388307` |
| `📌 INFO` | 1 | `#announcements` | news (`5`) | `1569192908026937545` | Fed by `release.yml` (`nanoui Releases` webhook) |
| `📌 INFO` | 2 | `#roadmap` | text (`0`) | `1573183364758896743` | Pinned 4-card roadmap/benchmarks: `1573183368391036930` |
| `📌 INFO` | 3 | `#github` | text (`0`) | `1569192909939548361` | Live GitHub commits, PRs, issues feed |
| `📌 INFO` | 4 | `#arrivals` | text (`0`) | `1571372523965128754` | New-member join feed |
| `📌 INFO` | 5 | `#moderator-only` | text (`0`) | `1571387265563758663` | Maintainer moderation & Discord updates |
| `💬 COMMUNITY` (`1566720297946587229`) | 0 | `#general` | text (`0`) | `1566720297946587231` | General Zig & nanoui chat |
| `💬 COMMUNITY` | 1 | `#showcase` | text (`0`) | `1569192913567482016` | `nui snapshot` / `--nanoui-play` demos |
| `💬 COMMUNITY` | 2 | `#discussion-wednesdays` | forum (`15`) | `1573232152378867832` | Pinned guide thread: `1573232222901899307` |
| `💬 COMMUNITY` | 3 | `#help` | forum (`15`) | `1571387281384800367` | Tagged troubleshooting Q&A forum |
| `🛠️ DEVELOPMENT` (`1569192902327017502`) | 0 | `#ui-and-kit` | text (`0`) | `1569192917036310619` | Widgets, `nanoui.kit`, `ui.motion`, text |
| `🛠️ DEVELOPMENT` | 1 | `#platforms` | text (`0`) | `1569192918554513519` | macOS/iOS/iPadOS/Android/Linux/Windows |
| `🛠️ DEVELOPMENT` | 2 | `#apps` | text (`0`) | `1569192920882352209` | Ecosystem apps (`nanoterm`, `nanobrowser`, etc.) |
| `🔊 VOICE` (`1566720297946587230`) | 0 | `#Pairing & Hangout` | voice (`2`) | `1566720297946587232` | Weekly event host (`1573232242455609344`) |

## Forum Tags

### `#discussion-wednesdays` (`1573232152378867832`)

| Tag | Emoji | Moderated | ID |
|---|---|---:|---:|
| `Weekly Thread` | `🗓️` | Yes | `1573232152378867833` |
| `Topic Pitch` | `💡` | No | `1573232152378867834` |
| `Roadmap & RFC` | `🗺️` | No | `1573232152378867835` |
| `Performance & Proofs` | `⚡` | No | `1573232152378867836` |
| `UI & nanoui.kit` | `🎨` | No | `1573232152378867837` |
| `Mobile & Platforms` | `📱` | No | `1573232152378867838` |
| `Show & Tell` | `🧪` | No | `1573232152378867839` |

### `#help` (`1571387281384800367`)

| Tag | Emoji | ID |
|---|---|---:|
| `Native UI & Kit` | `🎨` | `1571387281384800368` |
| `Webview & IPC` | `🌐` | `1571387281384800369` |
| `macOS & iOS` | `🍎` | `1571387281384800370` |
| `Windows` | `🪟` | `1571387281384800371` |
| `Linux` | `🐧` | `1571387281384800372` |
| `Android` | `🤖` | `1571387281384800373` |
| `Build & Tooling` | `🔧` | `1571387281384800374` |
| `Solved` | `✅` | `1571387281384800375` |

## Roles

| Role | Color | ID |
|---|---:|---:|
| `Maintainer` | `0xf7a41d` | `1569192890670911498` |
| `Contributor` | `0x3b82f6` | `1569192892403155019` |
| `Builder` | `0x22c55e` | `1569192894307508274` |
| `nanobot` | `0x0` | `1569191835912511511` |
| `@everyone` | `0x0` | `1566720297040879660` |

## Verified Discord REST API v10 Quirks

- **Pinning a forum post:** `POST /channels/{forum_id}/threads` returns `thread["id"]`. To pin the thread at the top of the forum, `PATCH /channels/{thread_id}` with `{"flags": 2}` (`PINNED`).
- **Reacting to a forum starter post:** A forum thread's initial message shares `message_id == thread_id`. URL-encode emoji (e.g., `urllib.parse.quote("1️⃣", safe="")`) and space `PUT /reactions/{emoji}/@me` calls by `~0.45s`.
- **Reordering channels:** `PATCH /guilds/{guild_id}/channels` accepts `[{"id": ..., "position": ...}, ...]` and returns `204`.
- **Weekly Wednesday event recurrence:** `POST /guilds/{guild_id}/scheduled-events` supports `recurrence_rule` (`{"start": "...T14:00:00+00:00", "frequency": 2, "interval": 1, "by_weekday": [2]}` — `2` = weekly, `[2]` = Wednesday). Keep a single-event fallback if an older server rule rejects `recurrence_rule`.
- **`nanoui Releases` webhook visibility:** Without the privileged `MESSAGE_CONTENT` intent, `GET /channels/{id}/messages` returns full `embeds` and `content` for `@nanobot`'s own messages, but redacts them on other bots' or webhooks' messages. Match release webhook posts by `author.username == "nanoui Releases"` and timestamp.
