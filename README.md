# nomirevturbo

> Need a worldwide reverse geocoder but don't have a spare datacenter, a 256 GB server, or three days to wait for an import? Tired of babysitting PostgreSQL while it digests the planet? Just want coordinates in, address out, and maybe grab a coffee instead of a sleeping bag?
>
> **Full planet. Under an hour. On a machine your cat could sit on.**

A turbocharged, self-hosted **reverse geocoder** built from OpenStreetMap data. Nominatim-compatible API. No PostgreSQL, no PostGIS, no multi-day imports. Just a single binary, 20 GB of index files, and sub-millisecond answers for anywhere on Earth.

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
| `--tmpdir DIR` | (in-memory) | Switch to file-backed mode and place `node_locations.tmp` on the specified filesystem. By default, the builder stores node locations in RAM (25 GB peak for planet). Use `--tmpdir` only on machines with very limited RAM -- it creates a temp file (~18 GB for planet with node filtering) and is significantly slower due to random I/O. Place on NVMe, not spinning disk. |
| `--max-vertices N` | 50000 | Maximum vertices per admin boundary polygon after Douglas-Peucker simplification. Higher values preserve more coastline detail but increase index size. Capped at 65535 (uint16_t). The upstream default of 500 destroys polygon topology and should never be used. |
| `--verbose` | off | Per-polygon diagnostic output, pipeline summary counters, memory stats at each build phase, and per-phase timing breakdown. Recommended for monitoring large builds. |
| `--debug` | off | Enable osmium assembler problem reporting. Very noisy output, useful only for diagnosing specific polygon assembly failures. Implies `--verbose`. |
| `--street-level N` | 17 | S2 cell level for street/address spatial index. Higher values = finer granularity, more cells, larger index. Level 17 corresponds to ~150m cells. |
| `--admin-level N` | 10 | S2 cell level for admin boundary spatial index. Level 10 corresponds to ~10km cells. |

### Memory and disk requirements

| Extract | PBF Size | Index Size | Build time | Peak RAM |
|---------|----------|------------|------------|----------|
| Belgium | 765 MB | ~200 MB | 29s | 2 GB |
| France | 4.7 GB | ~1 GB | ~5 min | 8 GB |
| Italy | 2.1 GB | ~500 MB | ~3 min | 5 GB |
| Europe | 32 GB | ~7 GB | 17 min | 11 GB |
| Planet | 86 GB | ~20 GB | ~57 min | 25 GB |

Build times measured on: Belgium/France/Italy/Europe on a Proxmox VM (32 GB RAM, 8 vCPUs, ZFS storage). Planet on a dedicated machine (94 GB RAM, 4 vCPUs, NVMe storage).

Node locations are stored **in memory by default**. Node filtering (Pass 1.5) automatically reduces the node location index from ~134 GB to ~11 GB for planet. The full planet build peaks at 25 GB. Any machine with 32+ GB of RAM can build the entire planet.

For machines with less RAM, `--tmpdir` switches to file-backed mode and creates a `node_locations.tmp` file (~18 GB for planet). This is significantly slower due to random I/O -- place the temp file on NVMe, not spinning disk.

**Disk space for index output:** The output directory needs ~20 GB for planet, ~7 GB for Europe. This can be on any filesystem -- writes are sequential and not performance-critical.

### Storage layout recommendations

For builds using `--tmpdir` (file-backed mode), separate your storage by access pattern:

| Data | Access pattern | Recommended storage |
|------|---------------|-------------------|
| PBF input file | Sequential read | Any (NVMe, SSD, even HDD) |
| Node temp file (`--tmpdir`) | Heavy random I/O | **NVMe required** for large builds |
| Index output directory | Sequential write | Any (written once, read at startup) |

With the default in-memory mode, no temp file is created and storage choice only matters for the PBF input and index output.

### Examples

```bash
# Planet build (in-memory by default, ~25 GB peak RAM, ~57 min)
./build-index /data/index planet-latest.osm.pbf --verbose

# Europe with diagnostics
./build-index /data/index europe-latest.osm.pbf --verbose

# Multiple PBFs (merged into single index)
./build-index /data/index france.osm.pbf germany.osm.pbf

# Low-RAM machine: file-backed mode, temp file on local NVMe
./build-index /data/index europe-latest.osm.pbf --tmpdir /mnt/nvme/tmp --verbose

# Custom simplification limit (preserve more coastline detail)
./build-index /data/index planet-latest.osm.pbf --max-vertices 65535
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
| `--search-distance N` | 75 | Maximum search distance in meters. Converted internally to radians via `m / 111_320`. The equirectangular approximation is conservative at all latitudes (sub-meter error even at 85N). |

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

## Ansible Deployment

A standalone Ansible role is included for deploying to Debian 13 (Trixie) servers. It handles the full lifecycle: building S2 geometry and Rust from source, compiling the builder and server, downloading the PBF, building the index (with `--verbose` output logged to `build.log`), provisioning the auth database, configuring a systemd service, and setting up nginx as a reverse proxy with rate limiting.

A playbook and test inventory are included:

```bash
# Deploy to a server (update ansible_host in inventory first)
ansible-playbook -i ansible/inventory/test.yml ansible/playbook.yml
```

The playbook handles prerequisites (tileserver user/group, data disk mount, nginx) before running the geocoder role. At the end, it displays the build log and clickable endpoint URLs.

```
ansible/
  ansible.cfg             # pipelining, sensible defaults
  playbook.yml            # pre-tasks + geocoder role
  inventory/test.yml      # generated by Terraform, or edit manually
  roles/geocoder/
    tasks/                # packages, directories, build, auth, service, nginx, cron, summary
    templates/            # systemd unit, nginx config, test page, rebuild script
    defaults/             # configurable variables (paths, ports, PBF URL, auth DB)
    handlers/             # systemd reload, service restart, nginx reload
```

Key variables (set in your inventory or `host_vars`):

| Variable | Default | Description |
|----------|---------|-------------|
| `geocoder_enabled` | `false` | Enable the role |
| `geocoder_port` | `3000` | Server listen port |
| `geocoder_bind` | `127.0.0.1` | Server bind address |
| `geocoder_index_dir` | `/data/geocoder/index` | Index file location |
| `geocoder_build_dir` | `/var/tmp/geocoder-build` | Scratch dir for building |
| `geocoder_api_key` | `testkey123` | API key for the test page |
| `geocoder_europe_pbf_url` | Geofabrik Europe | PBF download URL |
| `geocoder_auth_db` | test user + key | Auth database (JSON, deployed if missing) |

The role deploys an interactive test page at `/testgeocode` (served by nginx) that lets you click a map to reverse-geocode any location. Uses OpenStreetMap tiles. The build log is available at `{{ geocoder_data_dir }}/build.log` for monitoring long builds.

## Terraform (Test VM)

A Terraform configuration is included for spinning up a Debian 13 test VM on Proxmox. It uses the Debian cloud image with cloud-init for fully headless provisioning -- no manual OS install needed. The cloud image is downloaded once to Proxmox storage and reused for future VMs.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Proxmox API token

terraform init
terraform apply        # creates VM, generates Ansible inventory
```

After `terraform apply`, the Ansible inventory at `ansible/inventory/test.yml` is automatically populated with the VM's IP address. Run the playbook to deploy:

```bash
ansible-playbook -i ansible/inventory/test.yml ansible/playbook.yml
```

Default VM spec: 8 cores, 32 GB RAM, 50 GB OS disk, 300 GB data disk. Handles a full Europe build in ~17 minutes. See [terraform/README.md](terraform/README.md) for details.

## Known Limitations

When building from continent or regional PBF extracts (e.g., `europe-latest.osm.pbf`), countries with overseas territories outside the extract boundary will have incomplete `admin_level=2` boundary relations. The libosmium assembler cannot form closed polygon rings when member ways are missing.

The server's **country-boundaries fallback** compensates for this at query time using an embedded global boundary dataset (~1 MB). This is enabled by default and covers all affected countries (France, Spain, Netherlands, and others with overseas territories). Disable it with `--no-country-fallback` when using a planet PBF.

See [docs/builder-polygon-repair-findings.md](docs/builder-polygon-repair-findings.md) for a detailed analysis.

**Bridge/tunnel disambiguation:** The server currently geocodes in 2D only -- a vehicle on an overpass may be matched to the road below. A design for Z-level awareness using OSM `layer`/`bridge`/`tunnel` tags is documented in [docs/zlevel-design.md](docs/zlevel-design.md).

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
| `SEARCH_DISTANCE` | Max search distance in meters | `75` |

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
