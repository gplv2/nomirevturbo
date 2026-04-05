# Changelog

All notable changes to this project will be documented in this file.

Originally forked from [traccar/traccar-geocoder](https://github.com/traccar/traccar-geocoder).
Changes below are relative to the upstream project.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

## [3.0.0] - 2026-04-05

Hard fork from traccar-geocoder. Rebranded to **nomirevturbo**.

### Performance

Full planet build: **44 hours 46 minutes down to 54 minutes 38 seconds** (49x faster). Peak RAM dropped from 94 GB + 64 GB swap to **25 GB with zero swap**.

Three optimizations stacked:

1. **Write phase overhaul** -- replaced `std::set` with sorted vectors, hash map offset tables with position-indexed vectors, added progressive memory release with `malloc_trim(0)`. Write phase for planet: 48 seconds.

2. **Flat pair vectors** -- replaced all four `unordered_map<uint64_t, vector<uint32_t>>` cell maps with packed 12-byte `CellEntry` vectors. Cell structure memory dropped from ~37 GB to ~5.5 GB. Reading throughput improved 24% (vector append vs hash lookup during PBF processing). Merge-scan writes replaced hash lookups.

3. **Node filtering (Pass 1.5)** -- new pre-scan pass identifies which of the 9 billion nodes are actually needed by streets, addresses, and admin boundaries. Only 1.1 billion nodes stored (89% filtered). Node location index dropped from ~134 GB to ~11 GB, making planet `--in-memory` possible on a 32 GB machine.

| Extract | Build time | Peak RAM |
|---------|-----------|----------|
| Belgium | 29s | 2 GB |
| Europe | 22 min | 11 GB |
| Planet | 57 min | 25 GB |

### Added

#### Builder
- Pass 1.5 node filtering with bitmap-based pre-scan (~1.5 GB bitmap for planet)
- `FilteredNodeLocationsForWays` handler replacing osmium's built-in handler
- `RelationWayCollector` to identify admin/postal boundary way members in Pass 1
- `WayNodeCollector` to mark needed node IDs by tag filtering in Pass 1.5
- `CellEntry` packed 12-byte struct replacing hash map cell storage
- `sort_and_dedup()` for flat pair vectors (replaces per-cell hash map iteration)
- Merge-scan `write_entries()` replacing hash lookup iteration
- Live memory diagnostics (`/proc/self/status` RSS/Swap/VM at each build phase)
- Per-phase build timers (data files, geo cell sort, entry writes, geo_cells.bin, admin index)
- `shrink_to_fit()` on all vectors before write phase to reclaim over-reserved capacity
- `malloc_trim(0)` after each major deallocation to return pages to OS
- `--max-vertices N` flag (default 50,000, was hardcoded 500 upstream)

#### Deployment
- Ansible role for Debian 13 with systemd service, nginx proxy, rate limiting, and interactive test page
- Test page at `/testgeocode` using OpenStreetMap tiles for click-to-geocode testing

#### Documentation
- `docs/write-phase-optimization.md`: write phase analysis with memory waterfalls
- `docs/flat-pairs-optimization.md`: hash map elimination analysis with planet results
- `docs/vertex-limit-case-study.md`: 500 vs 10K vs 50K comparison across Italy and France

### Changed
- **Default to in-memory mode** -- node filtering makes planet fit in 25 GB, no reason for file-backed default
- `--tmpdir` now implies file-backed mode (previously required `--in-memory` flag to opt in)
- `--in-memory` still accepted for backward compatibility
- Pre-allocation estimates updated for planet scale (street_nodes 4.5M to 6.5M/GB, admin_vertices 500K to 5M/GB, addr_points 7.5M to 3M/GB)
- Rebranded from traccar-geocoder to nomirevturbo
- NOTICE file updated with fork commit hash (`6feb14e`) and complete change list
- Removed upstream Traccar funding file and Docker Hub workflow

## [2.0.0] - 2026-04-02

### Added

#### Builder
- S2Builder polygon repair pipeline: three-tier recovery (S2Loop direct > S2Builder split_crossing_edges > bounding-box fallback) instead of silently dropping invalid polygons
- `--verbose` flag for per-polygon diagnostic output and pipeline summary counters
- `--debug` flag for osmium assembler problem reporting
- `--in-memory` flag for RAM-backed node location index (eliminates node_locations.tmp disk I/O)
- `--tmpdir DIR` flag to place temp file on a different filesystem
- Vector pre-allocation from PBF file size heuristics
- Reuse of S2RegionCoverer instances (was constructing millions per build)
- Skip PBF metadata parsing (`read_meta::no`) in both reader passes

#### Server
- Country-boundaries fallback for missing country data from continent/regional PBF extracts (France, Spain, Netherlands affected)
- `--no-country-fallback` flag to disable fallback for planet PBF builds
- 40-test suite covering format_address, auth, rate limiter, coordinate validation, country fallback
- Pre-push git hook running clippy, fmt, and audit on every push

#### Documentation
- `docs/builder-polygon-repair-findings.md`: full investigation report with root cause analysis, benchmark data, and geocoding verification across Italy, France, and Benelux
- `NOTICE` file for Apache 2.0 license compliance

### Changed

#### Builder
- Raised polygon simplification limit from 500 to 10,000 vertices (eliminates self-intersecting edges, often produces smaller index due to smoother S2 coverings)
- Enabled lenient multipolygon assembly (`ignore_invalid_locations`) on libosmium assembler
- Enabled `ignore_errors()` on node location handler for PBF extract tolerance
- Highway filter uses `unordered_set` for O(1) lookup instead of O(9) linear scan

#### Server
- Rewrote `format_address` to use single String buffer (fewer allocations)
- Precomputed mmap slice lengths at load time instead of per-query division
- Eliminated redundant Vec allocation in cell neighbor lookup
- Rate limiter: 0 means unlimited (convention for admin accounts), remove token to revoke access
- Applied rustfmt and clippy across all source files

### Fixed

#### Server
- Rate limiter race condition: replaced atomics with Mutex (#c846b2a)
- Street deduplication hash collisions in dense urban areas (#3d21563)
- Added bounds checking on all mmap slice accesses to prevent panics (#2faf0dd)
- Validate lat/lon parameters before querying index (reject NaN, infinity, out-of-bounds) (#c867333)
- `Db` deserialization crash on empty JSON `{}` (added `#[serde(default)]`)

#### Deployment
- Use positional parameters in entrypoint.sh for safe argument passing (#699b5ef)

### Security
- Updated aws-lc-sys 0.38.0 to 0.39.1 (RUSTSEC-2026-0044, RUSTSEC-2026-0048: X.509 name constraints bypass, CRL scope check, severity 7.4 high)
- Updated rustls-webpki 0.103.9 to 0.103.10 (RUSTSEC-2026-0049: CRL distribution point matching)

## [0.1.0] - 2026-04-01

Initial fork from [traccar/traccar-geocoder](https://github.com/traccar/traccar-geocoder) at commit `6feb14e`.

### Added
- Country-boundaries fallback for missing country data (later refined in 2.0.0)
- Worldwide country code to name mapping (~250 entries)
