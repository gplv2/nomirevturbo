# nomirevturbo

A turbocharged, self-hosted **reverse geocoder** built from OpenStreetMap data. Nominatim-compatible API. No PostgreSQL, no PostGIS, no multi-day imports.

This is a **reverse geocoder only**. It resolves coordinates to addresses. It does not do forward geocoding (address to coordinates).

## Why nomirevturbo

| | Nominatim (reverse-only) | nomirevturbo |
|---|---|---|
| Full planet build | 14-62 hours | **under 1 hour** |
| Peak RAM (planet) | 64-256 GB | **25 GB** |
| Disk (planet index) | 500-900 GB (PostgreSQL) | **20 GB** (flat binary files) |
| Dependencies | PostgreSQL, PostGIS, osm2pgsql | **none** (single binary + index files) |
| Query latency | 5-90 ms | **sub-millisecond** |
| API compatibility | native | **Nominatim /reverse endpoint** |

Drop-in replacement for any application using Nominatim's reverse geocoding endpoint. Same request format, same response format.

## What it does

Given latitude and longitude coordinates, returns the nearest street address:

```bash
curl "http://localhost:3000/reverse?lat=48.8566&lon=2.3522&key=YOUR_KEY"
```

```json
{
  "display_name": "Rue de Rivoli 1, 75001 Paris, France",
  "address": {
    "house_number": "1",
    "road": "Rue de Rivoli",
    "city": "Paris",
    "state": "Ile-de-France",
    "county": "Paris",
    "postcode": "75001",
    "country": "France",
    "country_code": "FR"
  }
}
```

Address fields include: house number, street name, city, state, county, postcode, country, and country code. Fields are omitted when not available. The `display_name` is formatted according to the country's addressing convention (number after street in Europe, before street in the US).

## Architecture

Two components, one shared binary index format:

- **Builder** (`builder/src/build_index.cpp`) -- C++17, single file. Reads OSM PBF files in three passes, builds a compact binary index using S2 geometry cells. Includes a three-tier polygon repair pipeline (S2Loop > S2Builder > bounding-box fallback) that recovers invalid admin boundaries instead of silently dropping them.
- **Server** (`server/`) -- Rust (axum). Memory-maps the index files and serves reverse geocoding queries over HTTP/HTTPS with sub-millisecond latency. Includes an embedded country-boundaries fallback for when continent extracts have incomplete national boundaries.

The index format uses fixed-size C structs written directly to disk. The server mmaps them and casts pointers. Both sides must agree on struct layout. Index files are portable between x86_64 and aarch64 (little-endian, IEEE 754 floats).

## Building from Source

### Builder (C++)

**Dependencies** (Debian/Ubuntu):

```bash
apt install build-essential cmake libosmium2-dev libprotozero-dev \
  libs2-dev zlib1g-dev libbz2-dev libexpat1-dev liblz4-dev
```

**Build:**

```bash
cd builder
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

This produces a single binary: `build-index`.

### Server (Rust)

**Dependencies:** Rust toolchain (stable).

```bash
cd server
cargo build --release
```

This produces: `target/release/query-server`.

## Builder Reference

```
build-index <output-dir> <input.osm.pbf> [input2.osm.pbf ...] [options]
```

The builder reads one or more OSM PBF files and produces 14 binary index files in the output directory.

### Build process

The builder runs three passes over each PBF file:

1. **Pass 1** -- Scans relations to prepare multipolygon assembly (admin boundaries, postal codes)
2. **Pass 1.5** -- Scans ways to identify which node IDs are needed. Builds a bitmap (~1.5 GB for planet) that filters out ~89% of nodes not referenced by any street, address, or admin boundary
3. **Pass 2** -- Reads all entities. Only stores locations for needed nodes (via the bitmap from Pass 1.5). Processes highways, addresses, interpolation ways, and assembles admin boundary polygons

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--in-memory` | off | Store node locations in RAM instead of a disk-backed temp file. **Recommended for all builds.** With node filtering, even a full planet fits in 25 GB. Without this flag, node locations are written to a `node_locations.tmp` file that can reach 134 GB for planet. |
| `--tmpdir DIR` | output dir | Place `node_locations.tmp` on a different filesystem. Only relevant in file-backed mode (without `--in-memory`). Use this to put the temp file on fast local NVMe when the output directory is on slower storage. Ignored when `--in-memory` is used. |
| `--max-vertices N` | 50000 | Maximum vertices per admin boundary polygon after Douglas-Peucker simplification. Higher values preserve more coastline detail but increase index size. Capped at 65535 (uint16_t). The upstream default of 500 destroys polygon topology and should never be used. |
| `--verbose` | off | Per-polygon diagnostic output, pipeline summary counters, memory stats at each build phase, and per-phase timing breakdown. Recommended for monitoring large builds. |
| `--debug` | off | Enable osmium assembler problem reporting. Very noisy output, useful only for diagnosing specific polygon assembly failures. Implies `--verbose`. |
| `--street-level N` | 17 | S2 cell level for street/address spatial index. Higher values = finer granularity, more cells, larger index. Level 17 corresponds to ~150m cells. |
| `--admin-level N` | 10 | S2 cell level for admin boundary spatial index. Level 10 corresponds to ~10km cells. |

### Memory and disk requirements

| Extract | PBF Size | Index Size | Build time | Peak RAM (`--in-memory`) |
|---------|----------|------------|------------|--------------------------|
| Belgium | 765 MB | ~200 MB | 29s | 2 GB |
| France | 4.7 GB | ~1 GB | ~5 min | 8 GB |
| Italy | 2.1 GB | ~500 MB | ~3 min | 5 GB |
| Europe | 32 GB | ~7 GB | 22 min | 11 GB |
| Planet | 86 GB | ~20 GB | ~57 min | 25 GB |

Build times measured on a single machine (94 GB RAM, 4 vCPUs, NVMe storage).

**Recommendation: always use `--in-memory`.** Node filtering (Pass 1.5) automatically reduces the node location index from ~134 GB to ~11 GB for planet. Even the full planet build peaks at 25 GB. Any machine with 32+ GB of RAM can build the planet.

**File-backed mode** (without `--in-memory`) creates a `node_locations.tmp` file for node locations. Node filtering (Pass 1.5) applies here too, so the temp file is ~18 GB for planet (only needed nodes), not the full 134 GB it would be without filtering. Still, `--in-memory` is faster because it eliminates all temp file I/O:
- Place the temp file on NVMe, not spinning disk (`--tmpdir /fast/nvme/tmp`)
- The output directory can be on slower storage since index writes are sequential

**Disk space for index output:** The output directory needs ~20 GB for planet, ~7 GB for Europe. This can be on any filesystem -- writes are sequential and not performance-critical.

### Storage layout recommendations

For best performance, separate your storage by access pattern:

| Data | Access pattern | Recommended storage |
|------|---------------|-------------------|
| PBF input file | Sequential read | Any (NVMe, SSD, even HDD) |
| Node temp file (`--tmpdir`) | Heavy random I/O | **NVMe required** for large builds |
| Index output directory | Sequential write | Any (written once, read at startup) |

For `--in-memory` builds (recommended), the temp file is not created and storage choice doesn't matter beyond the PBF input.

### Examples

```bash
# Recommended: planet build with in-memory node index
./build-index /data/index planet-latest.osm.pbf --in-memory --verbose

# Europe with diagnostics
./build-index /data/index europe-latest.osm.pbf --in-memory --verbose

# Multiple PBFs (merged into single index)
./build-index /data/index france.osm.pbf germany.osm.pbf --in-memory

# File-backed: temp file on local NVMe, output to network storage
./build-index /mnt/nfs/index europe-latest.osm.pbf --tmpdir /mnt/nvme/tmp --verbose

# Custom simplification limit (preserve more coastline detail)
./build-index /data/index planet-latest.osm.pbf --in-memory --max-vertices 65535
```

### Index output

The builder produces 14 binary files:

| File | Description |
|------|-------------|
| `geo_cells.bin` | Merged S2 cell index for streets, addresses, and interpolations |
| `street_entries.bin` | Street way IDs per cell |
| `street_ways.bin` | Street way headers (node offset, name) |
| `street_nodes.bin` | Street node coordinates |
| `addr_entries.bin` | Address point IDs per cell |
| `addr_points.bin` | Address point data (coordinates, house number, street) |
| `interp_entries.bin` | Interpolation way IDs per cell |
| `interp_ways.bin` | Interpolation way headers |
| `interp_nodes.bin` | Interpolation node coordinates |
| `admin_cells.bin` | S2 cell index for admin boundaries |
| `admin_entries.bin` | Admin polygon IDs per cell (high bit marks interior cells) |
| `admin_polygons.bin` | Admin polygon metadata (name, level, area, country code) |
| `admin_vertices.bin` | Admin polygon vertices for point-in-polygon tests |
| `strings.bin` | Deduplicated string pool |

## Server Reference

```
query-server <index-dir> [bind-address] [options]
```

The server memory-maps all 14 index files and serves reverse geocoding queries over HTTP or HTTPS.

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--no-country-fallback` | fallback enabled | Disable the embedded country boundary fallback. Use this when building from a planet PBF where all boundary relations are complete. For continent/regional extracts, keep the fallback enabled -- it compensates for countries with overseas territories outside the extract boundary (France, Spain, Netherlands). |
| `--domain DOMAIN` | disabled | Enable automatic HTTPS via Let's Encrypt ACME. The server will obtain and renew TLS certificates automatically. |
| `--cache DIR` | `acme-cache` | Directory for ACME certificate cache. |
| `--street-level N` | 17 | Must match the value used during building. |
| `--admin-level N` | 10 | Must match the value used during building. |
| `--search-distance N` | 0.002 | Maximum search distance in degrees (~220m at the equator). |

### Examples

```bash
# Basic HTTP server on port 3000
./query-server /data/index 0.0.0.0:3000

# With automatic HTTPS
./query-server /data/index --domain geocoder.example.com

# Planet build (all boundaries complete, disable fallback)
./query-server /data/index 0.0.0.0:3000 --no-country-fallback
```

## Nominatim API Compatibility

The server implements the [Nominatim reverse geocoding endpoint](https://nominatim.org/release-docs/latest/api/Reverse/) format:

**Request:** `GET /reverse?lat={lat}&lon={lon}&key={apikey}`

**Response:** JSON with `display_name` and `address` object containing `house_number`, `road`, `city`, `state`, `county`, `postcode`, `country`, `country_code`.

Any application that calls Nominatim's `/reverse` endpoint can switch to nomirevturbo by changing the base URL. No other code changes required.

**Status codes:**
- `200` -- success (application/json)
- `400` -- invalid coordinates (NaN, infinity, or out of range)
- `401` -- missing or invalid API key
- `429` -- rate limit exceeded

### Authentication

The server uses token-based authentication. The auth database is a JSON file at `<index-dir>/geocoder.json`.

Quick test setup:
```json
{"users":{"test":{"password_hash":"dummy","admin":true,"rate_per_second":100,"rate_per_day":100000,"rate_by_ip":false}},"tokens":{"testkey123":"test"}}
```

Rate limits are per-user. Setting `rate_per_second` or `rate_per_day` to `0` means unlimited. To revoke access, remove the user's token from the tokens map.

## Known Limitations

When building from continent or regional PBF extracts (e.g., `europe-latest.osm.pbf`), countries with overseas territories outside the extract boundary will have incomplete `admin_level=2` boundary relations. The libosmium assembler cannot form closed polygon rings when member ways are missing.

The server's **country-boundaries fallback** compensates for this at query time using an embedded global boundary dataset (~1 MB). This is enabled by default and covers all affected countries (France, Spain, Netherlands, and others with overseas territories). Disable it with `--no-country-fallback` when using a planet PBF.

See [docs/builder-polygon-repair-findings.md](docs/builder-polygon-repair-findings.md) for a detailed analysis.

## Docker

For containerized deployments, a Docker image is available with automatic PBF download, index building, and serving.

### Docker Compose

```yaml
services:
  geocoder:
    image: gplv2/nomirevturbo
    environment:
      - PBF_URLS=https://download.geofabrik.de/europe/monaco-latest.osm.pbf
    ports:
      - "3000:3000"
    volumes:
      - nomirevturbo-data:/data

volumes:
  nomirevturbo-data:
```

### Docker CLI

```bash
# All-in-one: download, build index, and serve
docker run -e PBF_URLS="https://download.geofabrik.de/europe-latest.osm.pbf" \
  -v nomirevturbo-data:/data -p 3000:3000 gplv2/nomirevturbo

# Build index only
docker run -e PBF_URLS="https://download.geofabrik.de/europe-latest.osm.pbf" \
  -v nomirevturbo-data:/data gplv2/nomirevturbo build

# Serve only (from pre-built index)
docker run -v nomirevturbo-data:/data -p 3000:3000 gplv2/nomirevturbo serve

# With automatic HTTPS
docker run -e PBF_URLS="https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf" \
  -e DOMAIN=geocoder.example.com \
  -v nomirevturbo-data:/data -p 443:443 gplv2/nomirevturbo
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PBF_URLS` | Space-separated list of PBF download URLs | (required for auto/build) |
| `DOMAIN` | Domain name for automatic HTTPS via Let's Encrypt | (disabled) |
| `BIND_ADDR` | HTTP bind address | `0.0.0.0:3000` |
| `DATA_DIR` | Data directory for PBF files and index | `/data` |
| `CACHE_DIR` | ACME certificate cache directory | `acme-cache` |
| `STREET_LEVEL` | S2 cell level for streets | `17` |
| `ADMIN_LEVEL` | S2 cell level for admin boundaries | `10` |
| `SEARCH_DISTANCE` | Max search distance in degrees | `0.002` |

PBF files can be downloaded from [Geofabrik](https://download.geofabrik.de/) or [planet.openstreetmap.org](https://planet.openstreetmap.org/pbf/).

## License

    Apache License, Version 2.0

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
