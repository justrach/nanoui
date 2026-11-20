---
name: nanoui-discord
description: >-
  Operate, format, and maintain the official nanoui Discord community cleanly via
  Discord REST API v10. Activate when updating #roadmap or #welcome cards after a
  release, launching or summarizing #discussion-wednesdays threads and scheduled
  events, verifying release.yml webhook announcements, reorganizing channels, or
  planning community engagement workflows.
---

# Running the nanoui Discord Community

Use this runbook when maintaining or automating the **nanoui** Discord server (`1566720297040879660`) through the `@nanobot` integration.

## Non-Negotiable Safety & API Rules

1. **Keep `.env` secrets out of output and git.**
   Load `DISCORD_BOT_TOKEN` and `DISCORD_GUILD_ID` from `.env` in memory inside Python (`pathlib.Path(".env")`), never print or echo token values, and never commit `.env` or secret literals.

2. **Avoid noisy pings and spam.**
   Never send `@everyone` or `@here` without explicit user approval, and avoid unrequested announcements in `#general` (`1566720297946587231`).

3. **Do not duplicate GitHub Release posts.**
   `.github/workflows/release.yml` automatically posts releases to `#announcements` (`1569192908026937545`) through the `nanoui Releases` webhook. Inspect `#announcements` timestamps first; only post a fallback message if the webhook failed or was skipped.

4. **Respect Discord REST v10 headers, rate limits, and embed budgets.**
   - Send `User-Agent: DiscordBot (https://nanoui.dev, 1.0)` on every request to `https://discord.com/api/v10`.
   - Validate embed limits before `POST` or `PATCH`: `title <= 256`, `description <= 4096`, `field.name <= 256`, `field.value <= 1024`, `fields <= 25`, `author.name <= 256`, `footer.text <= 2048`, and **combined characters across all embeds in one message `<= 6000`**.
   - Sleep `~0.45s` between reaction `PUT` calls on the same message to avoid per-route `429` throttling.
   - Note that `@nanobot` does not read other bots' or webhooks' `content`/`embeds` over REST (`MESSAGE_CONTENT` intent is not required for its own messages). Verify `nanoui Releases` webhook posts by `author.username` and UTC timestamp rather than `embeds` length.

## Brand Palette & Visual Style

Match the 4-color accent palette shared by `#welcome` and `#roadmap` (using guild icon `https://cdn.discordapp.com/icons/1566720297040879660/9777196fa75cb415f5c824645dd12080.png?size=256`):

- **Amber Gold** `16229405` (`0xF7A41D`): Overview, releases, guides (`#welcome` card 0, `#roadmap` card 1)
- **Sky Blue** `3900150` (`0x3B82F6`): Milestones, quickstarts, weekly topic threads
- **Emerald Green** `2278750` (`0x22C55E`): Inline `3x2` grids (`Apps Built on nanoui`, `Platform Support Matrix`)
- **Violet** `9133302` (`0x8B5CF6`): Channel directories, monospace benchmark tables & bars

## Core Runbooks

### 1. Sync `#roadmap` After a Release

1. Update and merge `docs/roadmap.md` and `docs/benchmarks.md` on `main` first so Discord numbers match git verbatim.
2. `PATCH /channels/1573183364758896743/messages/1573183368391036930` using the 4-card template in [templates-and-playbooks.md](references/templates-and-playbooks.md). Updating in place preserves the pin and avoids channel noise.
3. Verify HTTP `200`, `pinned=True`, and all 4 embed titles/colors.

### 2. Run Weekly **Discussion Wednesdays**

1. **Pick one focused topic** (from GitHub issues/PRs or a member's `💡 Topic Pitch` post in `#discussion-wednesdays`).
2. **Post the weekly forum thread** in `#discussion-wednesdays` (`1573232152378867832`) tagged `🗓️ Weekly Thread` plus 1–2 topic tags, using a `1️⃣`–`4️⃣` quick-vote field and 1–2 short open questions.
3. **Add starter reactions (`1️⃣`–`4️⃣`)** to the starter post (`message_id == thread_id` on forum threads) so members can weigh in with a single click.
4. **Confirm the recurring event** (`1573232242455609344`, Wednesdays `14:00 UTC` in `#Pairing & Hangout`) is scheduled for async + optional 30–60m live drop-in.
5. **Close the loop on Thursday:** Post a 3-bullet takeaway reply in the thread and link action items back to `#roadmap` or GitHub issues.

### 3. Verify `#announcements` After Tagging `v*`

1. Watch `.github/workflows/release.yml` finish and confirm the `nanoui Releases` webhook posted in `#announcements` (`1569192908026937545`) around the workflow completion timestamp.
2. Only post a `@nanobot` fallback embed (linking the GitHub release URL and `<#1573183364758896743>`) if the webhook step failed or no webhook message appeared.

### 4. Update `#welcome` Safely

1. `GET /channels/1569192906168860862/messages/1569192924439388307` and modify the returned `embeds` list in place rather than rebuilding from memory.
2. Edit Embed 2 (`Apps Built on nanoui`) or Embed 3 (`Where to Go & Community Guidelines`), assert combined length `<= 6000`, `PATCH`, and confirm `pinned=True`.

## Community Operating Techniques

- **Async-first Wednesdays:** Treat the forum thread as the primary event (all timezones, zero meeting pressure) and `#Pairing & Hangout` as an optional office hour.
- **Zero-friction voting (`1️⃣`–`4️⃣`):** Smaller communities (`~30` members) engage faster when every discussion opens with 1-click reaction choices before deep replies.
- **Turn `#help` answers into lasting fixes:** Tag solved threads `✅ Solved` (`1571387281384800375`), post a 2-line root-cause summary, and fold recurring pitfalls into `docs/` or `ui.Tester` cases.
- **Make `#showcase` visual:** Remind contributors that `nui snapshot --out shot.png` and `--nanoui-play` produce instant offscreen screenshots and videos.
- **Keep channels lean:** Do not add new channels until existing ones feel crowded; high signal-to-noise beats empty rooms.

## Quick Verification Check

After any Discord change, verify live state read-only (`GET /guilds/1566720297040879660/channels`, `GET /channels/{id}/messages/{pin_id}`, `GET /guilds/1566720297040879660/scheduled-events`) and confirm pins, channel positions, and reaction counts match expectations.

## References

- **[Server Map & API Quirks](references/server-map.md)** — Exact guild, category, channel, pinned-message, forum-tag, role IDs, and REST behaviors.
- **[Embed Templates & Playbooks](references/templates-and-playbooks.md)** — Safe `.env` Python helper, 4-card `#roadmap` blueprint, weekly cadence, and Discussion Wednesday payload.
