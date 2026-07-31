# binly-osrm-service

Self-hosted [OSRM](https://project-osrm.org/) routing engine for Binly.

**Deployed:** Railway project `osrm-routing-service` → service `binly-osrm-service`,
built from this repo's root `Dockerfile`.
**URL:** `https://binly-osrm-service-production.up.railway.app`

## What depends on this

`ropacal-backend` reaches it via `OSRM_SERVER_URL` from **six** call sites. It is
not a nice-to-have — it is what measures the world for the route optimizer:

| What | Endpoint | Breaks if this is down |
|---|---|---|
| Distance/duration matrix for the OR-Tools VRP solver | `/table` | **shift start + every re-optimize** |
| GPS map-matching (snap-to-road) | `/match` | live driver tracking accuracy |
| Manager map's driver→next-bin polyline | `/route` | line renders as a straight chord |
| Route-template distances, AI-recommender drive times | `/route` | those features |

OR-Tools decides the *order* of stops; this service supplies every distance and
duration it reasons over. If this lies, the optimizer is confidently wrong.

## Regions served

| Region | Extract | For |
|---|---|---|
| California | `us/california-latest.osm.pbf` (~1.26 GB) | Ropacal — Bay Area |
| Ontario | `canada/ontario-latest.osm.pbf` (~0.92 GB) | GTA tenant |

**Every region a tenant operates in must be in the Dockerfile before they go
live.** Adding one: add its Geofabrik URL and add it to the `osmium merge` line.
OSRM serves exactly one dataset, so regions are merged into a single file.

## ⚠ How this fails — read before verifying

**An unserved region does not produce an error.** It produces a confident wrong
answer. Measured against the California-only build:

```
/nearest  Yonge & Dundas, Toronto  → snapped to "Riverside Drive", 3,185 km away
/table    Toronto → Mississauga    → code: Ok, 0.0 km   (they are 28 km apart)
```

HTTP 200 throughout. A smoke test that checks status codes **passes on a
completely broken build**, and the optimizer downstream would receive an
all-zeros matrix and emit garbage routes with nothing in any log.

**So: always verify with real distances, in every served metro.**

```bash
OSRM=https://binly-osrm-service-production.up.railway.app

# Bay Area — expect ~25 km
curl -s "$OSRM/table/v1/driving/-122.0808,37.6688;-122.2712,37.8044?annotations=distance" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["distances"][0][1]/1000,"km")'

# Greater Toronto — expect ~28 km, NOT 0.0
curl -s "$OSRM/table/v1/driving/-79.3832,43.6532;-79.6441,43.5890?annotations=distance" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["distances"][0][1]/1000,"km")'

# Snapping must land within metres of the query, not thousands of km
curl -s "$OSRM/nearest/v1/driving/-79.3832,43.6532" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["waypoints"][0]["distance"],"m")'
```

## Deploying

Push to this repo's default branch — Railway rebuilds automatically. The build
downloads ~2.2 GB, merges, and runs the full MLD pipeline; Railway builders are
32 vCPU / 64 GB microVMs, against a 40-minute hard build timeout.

**Railway keeps the previous deployment serving until the new one is healthy**, so
a failed build does not take routing down.

If the build ever does run out of room, the fix is to clip instead of dropping a
region — `osmium extract --bbox` around the metros actually operated in gets the
same coverage in roughly a third of the data. Any route outside the box then
fails, so size the box to where you might plausibly operate.

## Testing a Dockerfile change locally first

A full local build pulls 2.2 GB. To rehearse the *pipeline* in about a minute,
substitute two tiny extracts and check that **both** regions route — a merged
dataset that only routes in the first file's area is a known OSRM failure report:

```bash
sed -e 's|us/california-latest|us/delaware-latest|' \
    -e 's|canada/ontario-latest|canada/prince-edward-island-latest|' \
    -e 's|california-latest|delaware-latest|g' \
    -e 's|ontario-latest|prince-edward-island-latest|g' Dockerfile > /tmp/D
docker build --platform linux/amd64 -t osrm-rehearsal -f /tmp/D /tmp
docker run -d --name r -p 5599:5000 -e PORT=5000 --platform linux/amd64 osrm-rehearsal

# region 1 ≈ 79 km, region 2 ≈ 63 km — both must answer
curl -s 'http://127.0.0.1:5599/table/v1/driving/-75.5484,39.7447;-75.5244,39.1582?annotations=distance'
curl -s 'http://127.0.0.1:5599/table/v1/driving/-63.1311,46.2382;-63.7890,46.3950?annotations=distance'
docker rm -f r
```

## Notes

- **Base image is pinned by digest**, not `:latest`. The sister Centrifugo service
  ran on a floating tag and silently self-upgraded with no commit.
- **Map data refreshes only on rebuild.** Geofabrik regenerates daily but nothing
  here pulls automatically — the image sat on February 2026 data for five months,
  drifting ~3% from current OSM. Rebuild periodically.
- **MLD pipeline** (`extract`→`partition`→`customize`). `osrm-routed` must then run
  with a matching `--algorithm mld` or it refuses to load the files.
- No `railway.json`, `.dockerignore`, or deployment guide exists in this repo,
  whatever older docs claimed — the root `Dockerfile` is the whole deployment.
