# Embed Templates & Weekly Community Playbooks

## 1. Safe Python REST Helper & Budget Validator

Never print tokens or raw `.env` values. Always validate Discord's `6000`-character multi-embed budget before `POST` or `PATCH`:

```python
import json, pathlib, urllib.error, urllib.request

def load_env(path="/Users/rachpradhan/nanoui/.env"):
    env = {}
    for line in pathlib.Path(path).read_text().splitlines():
        s = line.strip()
        if s and not s.startswith("#") and "=" in s:
            k, v = s.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

def discord_client(token):
    headers = {
        "Authorization": f"Bot {token}",
        "Content-Type": "application/json",
        "User-Agent": "DiscordBot (https://nanoui.dev, 1.0)",
    }
    def req(method, path, body=None):
        data = json.dumps(body).encode("utf-8") if body is not None else None
        r = urllib.request.Request("https://discord.com/api/v10" + path, data=data, headers=headers, method=method)
        with urllib.request.urlopen(r) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else None)
    return req

def validate_embeds(embeds):
    total = 0
    for e in embeds:
        fields = e.get("fields") or []
        assert len(e.get("title") or "") <= 256
        assert len(e.get("description") or "") <= 4096
        assert len(fields) <= 25
        total += len(e.get("title") or "") + len(e.get("description") or "")
        total += len((e.get("author") or {}).get("name") or "")
        total += len((e.get("footer") or {}).get("text") or "")
        for f in fields:
            assert len(f.get("name") or "") <= 256
            assert len(f.get("value") or "") <= 1024
            total += len(f.get("name") or "") + len(f.get("value") or "")
    assert total <= 6000, f"Combined embed chars {total} > 6000"
```

## 2. Four-Card `#roadmap` Architecture

Target message: `PATCH /channels/1573183364758896743/messages/1573183368391036930`.

| Card | Color | Layout & Content |
|---|---|---|
| `1` | Amber Gold (`16229405`) | `author` + `thumbnail` guild icon, links to Release / `docs/roadmap.md` / `docs/benchmarks.md` / Lean proofs, **Shipped** highlights, callout to `<#1573232152378867832>` |
| `2` | Sky Blue (`3900150`) | `🎯 Release Milestones` with 3 full-width fields (`🟡 patch`, `🔵 minor parity`, `🟣 engine & proofs`) |
| `3` | Emerald Green (`2278750`) | `🖥️ Platform Support Matrix` using **6 `inline: true` fields** (`🍎 macOS`, `📱 iOS`, `📲 iPadOS`, `🤖 Android`, `🐧 Linux`, `🪟 Windows`) for a `3×2` desktop grid |
| `4` | Violet (`9133302`) | `📊 Benchmarks`: aligned monospace code blocks (`text`) with block bars (`██░░░░░░░░`), frame medians, `ReleaseSmall` sizes, and guild icon `footer` |

Keep combined length around `3,500–4,500` characters so cards stay airy on both desktop and mobile Discord clients.

## 3. Discussion Wednesday Thread & Scheduled Event Blueprint

Post in `#discussion-wednesdays` (`1573232152378867832`):

```python
thread_payload = {
    "name": "🗓️ Discussion Wednesday #N (MMM DD): <Focused Question>",
    "applied_tags": [
        "1573232152378867833",  # 🗓️ Weekly Thread
        "1573232152378867835",  # e.g. 🗺️ Roadmap & RFC
    ],
    "message": {
        "embeds": [{
            "title": "🗓️ Discussion Wednesday #N — MMM DD, YYYY",
            "color": 3900150,
            "description": "<2-sentence context linking recent release/PR/RFC>",
            "fields": [
                {
                    "name": "🗳️ Quick Vote",
                    "value": "1️⃣ Option A\n2️⃣ Option B\n3️⃣ Option C\n4️⃣ Option D",
                    "inline": False,
                },
                {
                    "name": "💬 Open Discussion Prompts",
                    "value": "• What blocked or slowed you down this week?\n• Which platform/feature should we benchmark next?",
                    "inline": False,
                },
            ],
            "footer": {"text": "Async all day Wed · Optional live drop-in in #Pairing & Hangout @ 14:00 UTC"},
        }]
    },
}
```

Then add `1️⃣`, `2️⃣`, `3️⃣`, `4️⃣` reactions (`time.sleep(0.45)` between each `PUT` to `/channels/{tid}/messages/{tid}/reactions/{enc}/@me`).

Recurring Voice Event (`POST /guilds/1566720297040879660/scheduled-events`) uses `"channel_id": "1566720297946587232"`, `"entity_type": 2`, `"privacy_level": 2`, `"scheduled_start_time": "YYYY-MM-DDT14:00:00+00:00"`, and `"recurrence_rule": {"start": "...", "frequency": 2, "interval": 1, "by_weekday": [2]}`.

## 4. Weekly Community Cadence & Growth Habits

- **Mon/Tue — Prep:** Pick the next Wednesday prompt from GitHub PRs/issues or `💡 Topic Pitch` (`1573232152378867834`). Keep one clear decision or benchmark question per week.
- **Wednesday — Thread + Optional Voice:** Open the weekly thread in the morning UTC so Asia/Europe/Americas can participate asynchronously; host an optional 30–60m live session in `#Pairing & Hangout` at `14:00 UTC` (`22:00 SGT` / `15:00 CET` / `09:00 EST`).
- **Thursday — Close the Loop:** Reply inside the thread with a 3-bullet recap, convert agreed priorities into GitHub issues, and reflect updates in `#roadmap`.
- **Daily Hygiene:**
  - Mark resolved `#help` threads `✅ Solved` (`1571387281384800375`) and link fixes/tests (`docs/`, `src/ui/tests.zig`).
  - Nudge builders in `#general` or `#apps` to drop `nui snapshot` PNGs and `--nanoui-play` clips into `#showcase`.
  - Keep channel count minimal at `<100` members so conversations stay visible rather than fragmented.
