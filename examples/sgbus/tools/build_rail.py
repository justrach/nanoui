"""Builds examples/sgbus/data/rail.min.json from cheeaun/sgraildata
(data/v1/sg-rail.geojson: stations and exits from LTA DataMall / data.gov.sg,
line geometry from CityMapper and OSM). Hop km is measured along each
line's geometry between the stations' projections."""
import json, math, re, sys

g = json.load(open(sys.argv[1]))
F = g["features"]
R = 6371000.0

def m(a, b):  # (lat, lng)
    r = math.pi / 180
    x = (b[1] - a[1]) * r * math.cos((a[0] + b[0]) / 2 * r)
    y = (b[0] - a[0]) * r
    return R * math.hypot(x, y)

stations = []
key_of = {}  # code -> station index
for f in F:
    p = f["properties"]
    if p.get("stop_type") != "station":
        continue
    lng, lat = f["geometry"]["coordinates"][:2]
    codes = p["station_codes"].split("-")
    i = len(stations)
    stations.append({"name": p["name"], "key": p["station_codes"], "codes": codes, "at": (lat, lng), "exits": []})
    for c in codes:
        key_of[c] = i
for f in F:
    p = f["properties"]
    if p.get("stop_type") != "entrance":
        continue
    lng, lat = f["geometry"]["coordinates"][:2]
    stations[key_of[p["station_codes"].split("-")[0]]]["exits"].append((round(lat, 5), round(lng, 5)))

def num(prefix):
    out = []
    for c, i in key_of.items():
        mm = re.fullmatch(prefix + r"(\d+)", c)
        if mm:
            out.append((int(mm.group(1)), i))
    return [i for _, i in sorted(out)]

geoms = {}
for f in F:
    p = f["properties"]
    if f["geometry"]["type"] in ("LineString", "MultiLineString") and "line_color" in p:
        parts = f["geometry"]["coordinates"]
        if f["geometry"]["type"] == "LineString":
            parts = [parts]
        geoms[p["name"]] = [[(c[1], c[0]) for c in part] for part in parts]

def along(name, a, b):
    """km between stations a and b along the line's geometry (best part), else straight x 1.1."""
    best = None
    for part in geoms.get(name, []):
        cum = [0.0]
        for u, v in zip(part, part[1:]):
            cum.append(cum[-1] + m(u, v))
        def proj(pt):
            bi, bd = 0, 1e18
            for k, q in enumerate(part):
                dd = m(q, pt)
                if dd < bd:
                    bi, bd = k, dd
            return bi, bd
        ia, da = proj(stations[a]["at"])
        ib, db = proj(stations[b]["at"])
        if da > 400 or db > 400:
            continue
        d = abs(cum[ib] - cum[ia])
        straight = m(stations[a]["at"], stations[b]["at"])
        if d < straight * 0.95 or d > straight * 2.5:  # wrong part or a loop the other way
            continue
        if best is None or d < best:
            best = d
    if best is None:
        best = m(stations[a]["at"], stations[b]["at"]) * 1.1
    return round(best / 1000, 3)

S = lambda c: key_of[c]
NS = num("NS"); EW = num("EW"); NE = num("NE"); DT = num("DT"); TE = num("TE"); CC = num("CC")
BP = num("BP"); SE = num("SE"); SW = num("SW"); PE = num("PE"); PW = num("PW")
STC, PTC = S("STC"), S("PTC")
cc_main = [i for i in CC]  # CC1..CC34, CC18 not open
# Circle line: Dhoby Ghaut .. HarbourFront .. (CCL6) .. Marina Bay, Bayfront, then on to Promenade.
cc_loop = cc_main + [S("CC4")] if S("CC34") in cc_main else cc_main

def both(seq):
    return [seq, seq[::-1]]

lines = [
    ("NSL", "North South Line", "North South Line", "D42E12", 80, both(NS)),
    ("EWL", "East West Line", "East West Line", "009645", 80, both(EW)),
    ("CGL", "EWL Changi Airport branch", "East West Line", "009645", 80, both([S("EW4"), S("CG1"), S("CG2")])),
    ("NEL", "North East Line", "North East Line", "9900AA", 90, both(NE)),
    ("CCL", "Circle Line", "Circle Line", "FA9E0D", 78, both(cc_loop)),
    ("DTL", "Downtown Line", "Downtown Line", "005EC4", 90, both(DT)),
    ("TEL", "Thomson-East Coast Line", "Thomson-East Coast Line", "9D5B25", 90, both(TE)),
    # Bukit Panjang LRT: Choa Chu Kang to Bukit Panjang, then round the loop either way.
    ("BPL", "Bukit Panjang LRT", "Bukit Panjang LRT", "748477", 55,
     [BP[:6] + BP[6:], BP[:6] + BP[6:][::-1], (BP[:6] + BP[6:])[::-1], (BP[:6] + BP[6:][::-1])[::-1]]),
    ("SKE", "Sengkang LRT East", "Sengkang LRT (East Loop)", "748477", 50, [[STC] + SE + [STC], [STC] + SE[::-1] + [STC]]),
    ("SKW", "Sengkang LRT West", "Sengkang LRT (West Loop)", "748477", 50, [[STC] + SW + [STC], [STC] + SW[::-1] + [STC]]),
    ("PGE", "Punggol LRT East", "Punggol LRT (East Loop)", "748477", 50, [[PTC] + PE + [PTC], [PTC] + PE[::-1] + [PTC]]),
    ("PGW", "Punggol LRT West", "Punggol LRT (West Loop)", "748477", 50, [[PTC] + PW + [PTC], [PTC] + PW[::-1] + [PTC]]),
]
out_lines = []
for lid, name, geo, color, vmax, dirs in lines:
    km = [[along(geo, a, b) for a, b in zip(d, d[1:])] for d in dirs]
    out_lines.append({"id": lid, "name": name, "color": color, "vmax": vmax, "dirs": dirs, "km": km})
    print(lid, [len(d) for d in dirs], "km", [round(sum(k), 1) for k in km], file=sys.stderr)
out = {
    "source": "cheeaun/sgraildata data/v1/sg-rail.geojson (LTA DataMall, data.gov.sg, CityMapper, OSM)",
    "stations": [[s["name"], " ".join(s["codes"]), round(s["at"][0], 5), round(s["at"][1], 5), [list(e) for e in s["exits"]]] for s in stations],
    "lines": out_lines,
}
json.dump(out, open(sys.argv[2], "w"), separators=(",", ":"), ensure_ascii=False)
