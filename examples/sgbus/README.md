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
- **Welcome** (first launch only): four cards that turn like pages
  about a ring on their left edge (`Style.turn`, a spring, a light tap
  of haptics): live times, every stop, the fare, and then the real
  location ask, with "Not now". Your answer is kept (`nanoui.kv`,
  `onboarded`). Open flat, the words are left of the fold and the card
  right of it. The card pictures in `assets/` were generated for the
  mockups, not photos.
- **Journey**: To searches OneMap's places and the bundled stop names.
  You then get the ways there, tagged Fastest, Fewest changes and Least
  walking, with the arrival, live wait, walk and fare, and a way's legs
  on the map with a Go button. The bus and MRT/LRT ways are planned on
  the phone (below); train legs carry their line's colour. With a OneMap token its bus and MRT ways join the same list,
  ranked the same way.
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
- MRT/LRT stations, exits and line order come from
  [sgraildata](https://github.com/cheeaun/sgraildata) (`data/v1`), which
  compiles LTA DataMall's Train Station Exit Point, data.gov.sg's MRT
  station exits, CityMapper routes and OpenStreetMap lines.
  `tools/build_rail.py sg-rail.geojson data/rail.min.json` turns it into
  `data/rail.min.json` (25 kB): 184 stations, 12 lines (the EWL's Changi
  branch and each LRT loop are their own), each hop's km along the
  track. sgraildata declares no licence of its own; before shipping,
  rebuild from DataMall's TrainStation/TrainStationExit directly.
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
- **Routing.** The bus ways are planned on the phone (`raptor.zig`,
  `raptor_plan.zig`) with RAPTOR: rounds of up to three buses (four rides with trains), from every
  stop within 450 m of you, with walks of up to 300 m between stops (so
  the stop across the road counts), to every stop within 450 m of where
  you're going. The stop lists have no timetable, so:
  - a ride's time is each stretch's length at a speed for its length
    (18 to 45 km/h, so expressways are quicker) plus 20 s a stop, then
    scaled by how fast that service's buses are really going, worked out
    from where LTA last saw them;
  - a wait is the live time when the stop's board has the service,
    else about 3.5 min at peak or 5 off it; a service missing from a
    live board isn't boarded; express (`e`) and City Direct (6xx) run
    only at weekday peaks unless a live board shows them;
  - each change adds a minute's slack; ways are ranked by arrival plus
    5 min a change and half a minute a minute walked, and only ways not
    beaten on all of arrival, changes and walking are kept;
  - fares are LTA's adult card distance fares (from 27 Dec 2025), over
    the whole journey, $1 more on an express. City Direct shows none.
  Walking is a straight line times 1.3 at 80 m a minute, with no
  footpath map. `zig build test-sgbus` plans three real trips, then the
  16 eval trips (`tests_rail.zig`) bus only and with trains.
- **Trains** (`rail.zig`) are more stops and services in the same
  rounds (up to four rides now, for bus, train, train, bus; four buses
  are not shown):
  - a station is reached at its nearest exit, up to 800 m on foot, plus
    2 min from gates to platform (1.5 min out); exits link to bus stops
    within 300 m; a change of line inside a station is 3 min;
  - a hop's time is its track length run at 85% of the line's top speed
    (80 km/h NSL/EWL, 78 CCL, 90 NEL/DTL/TEL, 50 to 55 LRT) with 0.8 m/s²
    to speed up and slow down, plus 45 s at each station (20 s LRT),
    fitted to TransitLink's SimplyGo eGuide times (mean error 1.1 min
    over 14 trips);
  - the wait is half the headway: 2.5 min apart at weekday peaks, 5
    off-peak (TEL 3/6, LRT 3.5/6, the Changi branch 5/8), from LTA's
    figures; no trains from 23:45 to 5:30;
  - one distance fare over the bus and train rides together (LTA's
    table is the same for both); a train trip, tap in to tap out,
    counts the shortest track km between the two stations, whichever
    way it went, as LTA charges. 50 cents off a train-only trip tapped
    in before 7:45 on a weekday. Against SimplyGo's fares for 25
    station pairs, 15 match and the rest are one step out (up to 10
    cents), from our track lengths.
  OneMap's routing (`routingsvc`, transit with MRT, `onemap.zig`) needs
  an account token.
  For a test run, the app reads `ONEMAP_TOKEN` from its environment at
  launch (on the simulator, `SIMCTL_CHILD_ONEMAP_TOKEN`) and keeps it in
  memory only; it is never in the repo or the bundle. Like the DataMall
  key, a shipped app's token belongs on our server, not in the app.
- `SGBUS_FRESH=1` starts as a first launch: no starred stops, and the
  welcome again.
- `SGBUS_ONEMAP_SAMPLE=1` shows OneMap's documented sample answer
  (`fixtures/onemap-docs-sample.json`, Farrer Park to Labrador Park by NE
  and CC) for any destination, labelled as a sample on screen, so the MRT
  views can be seen without a token. It is trimmed from OneMap's docs, not
  a recording.
