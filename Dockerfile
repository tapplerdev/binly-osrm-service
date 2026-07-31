# Binly OSRM routing service.
#
# Serves the distance/duration matrix the OR-Tools optimizer reasons over, plus
# GPS map-matching and route polylines, for EVERY Binly tenant. Six call sites in
# ropacal-backend depend on it (see that repo's CLAUDE.md -> "Service topology").
#
# ── WHY THE MAP IS MERGED ─────────────────────────────────────────────────────
# OSRM serves exactly one dataset. This image previously carried California only,
# which is fine until a tenant operates elsewhere — and that failure is SILENT,
# not loud. A Toronto coordinate does not error: it snaps to the nearest road
# OSRM happens to know (measured: "Riverside Drive", 3,185 km away) and /table
# answers `code: Ok` with 0.0 km. The optimizer then receives an all-zeros matrix
# and emits a confident, wrong route, with nothing in any log.
#
# So EVERY region a tenant operates in must be in this file before they go live.
# Adding one = add its Geofabrik URL below + add it to the `osmium merge` line.
#
# ── REGIONS SERVED ────────────────────────────────────────────────────────────
#   California (~1.26 GB)  — Ropacal, Bay Area
#   Ontario    (~0.92 GB)  — GTA tenant
#
# ── AFTER CHANGING THIS FILE ──────────────────────────────────────────────────
# Verify with REAL DISTANCES in every served metro, never status codes — the
# broken California-only build returned HTTP 200 for Toronto all day.

# ── Stage 1: merge the regional extracts ─────────────────────────────────────
# A separate Debian stage purely because osmium-tool is packaged there (the OSRM
# runtime image is Alpine). It also keeps the merge tooling and ~2.2 GB of raw
# PBF out of the shipped image.
FROM debian:bookworm-slim AS merger

RUN apt-get update && \
    apt-get install -y --no-install-recommends osmium-tool wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /data

# Geofabrik regenerates these daily and nothing here is pinned, so every rebuild
# also refreshes the road data. (The previous image sat on February 2026 data for
# five months, which is why its distances drifted ~3% from current OSM.)
#
# osmium merge requires inputs sorted nodes->ways->relations; Geofabrik ships them
# that way. Duplicate-node trouble is a SHARED-BORDER phenomenon — California and
# Ontario are ~3,000 km apart and share none, so there is nothing to overlap.
# Adding an ADJACENT pair later would need more care here.
RUN set -eux; \
    wget -q https://download.geofabrik.de/north-america/us/california-latest.osm.pbf; \
    wget -q https://download.geofabrik.de/north-america/canada/ontario-latest.osm.pbf; \
    ls -la *.osm.pbf; \
    osmium merge california-latest.osm.pbf ontario-latest.osm.pbf -o binly-merged.osm.pbf; \
    rm -f california-latest.osm.pbf ontario-latest.osm.pbf; \
    ls -la binly-merged.osm.pbf

# ── Stage 2: build the routing graph and serve it ────────────────────────────
# PINNED BY DIGEST, not :latest. The sister Centrifugo service ran on a floating
# tag and silently self-upgraded 6.6.0 -> 6.9.1 with no commit; this avoids the
# same trap. Digest is the multi-arch index for :latest as of 2026-07-31
# (OSRM v26.7.x, Alpine). To upgrade deliberately:
#   docker buildx imagetools inspect ghcr.io/project-osrm/osrm-backend:latest
FROM ghcr.io/project-osrm/osrm-backend@sha256:a7091038e39a73659767f34ef2d389909b42ea80b09bd2bdca482dce2991cbad

WORKDIR /data

COPY --from=merger /data/binly-merged.osm.pbf /data/binly-merged.osm.pbf

# extract -> partition -> customize is the MLD pipeline. MLD rather than CH is
# deliberate: lower peak memory, and osrm-routed below MUST then be started with
# a matching --algorithm mld or it refuses to load these files.
RUN set -eux; \
    osrm-extract -p /opt/car.lua /data/binly-merged.osm.pbf; \
    osrm-partition /data/binly-merged.osrm; \
    osrm-customize /data/binly-merged.osrm; \
    rm -f /data/binly-merged.osm.pbf; \
    ls -la /data/

ARG PORT=5000
ENV PORT=$PORT
EXPOSE $PORT

# Shell form so ${PORT} expands. Railway requires 0.0.0.0.
# --max-matching-size 5000 is what /match (GPS snapping) needs for long traces.
CMD osrm-routed \
    --algorithm mld \
    --max-matching-size 5000 \
    --ip 0.0.0.0 \
    --port ${PORT:-5000} \
    /data/binly-merged.osrm
