# SG Bus

Singapore bus arrivals in nanoui: Zig, Metal and UIKit, no Swift.

- **Nearby**: a map of the stops around you (yellow code chips) above
  their cards. Each card has a row per service with the minutes to its
  next bus, rolling as they change, then the two after it, how full the
  bus is (green, orange or red bars) and what kind of bus it is. Tap a
  stop's name and the map moves to it. Pull down to refresh. Times also
  refresh every 20 seconds.
- **Route**: tap a service to see its line, with its next three buses
  where LTA last saw them, and the stops before yours with each bus
  marked.
- **Starred**: star a stop and it is kept here between launches
  (`nanoui.kv`).
- **Journey**: To searches OneMap's places and the bundled stop names.
  You then get up to three ways there, and a way's legs on the map with a
  Go button. With a OneMap token they are OneMap's, bus and MRT, with MRT
  lines in their colours and live waits for the buses. Without one, or
  when OneMap fails, they are planned on the phone, by bus.
- **About**: the credits that the data's licences ask for.
- **Foldables** (`ui.panes`): folded, the map sits above the list. Open
  flat or held like a book, the map is in one pane and the times in the
  other. Held like a laptop, the map is on top.

```sh
zig build $(sh tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator run-sgbus
```

## Data

- Live arrivals come from [arrivelah](https://arrivelah2.busrouter.sg/?id=83139),
  which passes through LTA DataMall's Bus Arrival API.
- Stops, services and route lines come from
  [data.busrouter.sg/v1](https://data.busrouter.sg/v1/), compiled from LTA
  DataMall. They are bundled in `data/` (about 860 kB).
- Both contain information from LTA DataMall, made available under the
  terms of the Singapore Open Data Licence version 1.0.
- Place search is [OneMap](https://www.onemap.gov.sg/apidocs/)'s, from
  the Singapore Land Authority. It answers without a token today, but
  says that one will be needed.

## Before shipping

- **Get our own LTA DataMall account key.** arrivelah is a community
  proxy on someone else's key and quota, fine for a demo but not for an
  app in the store. Ship with a small server of ours that holds the
  `AccountKey`, calls DataMall's `BusArrivalv2`, and caches each stop for
  about 15 seconds. The app then calls that server, so the key never
  ships in the app.
- **Routing.** The ways there are planned on the phone (`router.zig`),
  buses only: one bus, or two with a walk between. The stop lists have no
  timetable, so a ride's time is an estimate: its length at 20 km/h plus
  24 seconds a stop. Waits are live when LTA has them. OneMap's routing
  (`routingsvc`, transit with MRT, `onemap.zig`) needs an account token.
  For a test run, the app reads `ONEMAP_TOKEN` from its environment at
  launch (on the simulator, `SIMCTL_CHILD_ONEMAP_TOKEN`) and keeps it in
  memory only; it is never in the repo or the bundle. Like the DataMall
  key, a shipped app's token belongs on our server, not in the app.
- `SGBUS_FRESH=1` starts with no starred stops, for a scripted run.
- `SGBUS_ONEMAP_SAMPLE=1` shows OneMap's documented sample answer
  (`fixtures/onemap-docs-sample.json`, Farrer Park to Labrador Park by NE
  and CC) for any destination, labelled as a sample on screen, so the MRT
  views can be seen without a token. It is trimmed from OneMap's docs, not
  a recording.
- **First launch.** `needsOnboarding` in `main.zig` holds the place for a
  welcome and the location ask. It is not designed yet, so it is never
  shown.
