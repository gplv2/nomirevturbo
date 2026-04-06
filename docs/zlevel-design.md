# Z-Level / Layer Awareness Design

## Problem

A vehicle on a highway overpass gets geocoded to the road below. A vehicle in a
tunnel gets geocoded to the surface street above. The current server has no
concept of vertical separation -- it picks the nearest road in 2D.

For fleet GPS tracking, this produces incorrect road names in multi-level road
situations (highway interchanges, bridges over local roads, tunnel entrances).

## OSM data available

| Tag | Values | Coverage |
|-----|--------|----------|
| `layer` | integer, default 0 (bridge: +1/+2, tunnel: -1/-2) | Good in Europe, variable globally |
| `bridge` | yes/no | Well-tagged on highways |
| `tunnel` | yes/no | Well-tagged on highways |
| `level` | integer (indoor mapping) | Not relevant for roads |

## GPS altitude

GPS receivers report altitude (meters above WGS84 ellipsoid), but accuracy is
poor: +/-10-30m in urban canyons, +/-5m in open areas. This makes hard exclusion
by altitude unreliable. A soft preference (penalty multiplier) is appropriate.

## Query API extension

Add optional `alt` parameter (backward compatible):

```
/reverse?lat=48.8566&lon=2.3522&alt=35&key=...
```

When `alt` is absent, behavior is unchanged (no z-level preference). When present,
the server uses altitude to estimate which layer the query point is on.

## Builder changes

### Option A: Parallel file (recommended)

Add a new file `street_flags.bin` alongside existing index files:

```c
struct WayFlags {
    int8_t layer;    // OSM layer tag, default 0
    uint8_t flags;   // bit 0: bridge, bit 1: tunnel
};
// 2 bytes per way, indexed by way ID (same as street_ways.bin)
```

**Advantages:**
- Backward compatible: old indexes (without `street_flags.bin`) work with new server
- No change to `WayHeader` struct or any existing `.bin` file
- Server detects presence of the file at startup and enables z-level scoring

**Disadvantages:**
- Extra file to manage (14 files becomes 15)
- Extra mmap at startup

### Option B: Extend WayHeader

Add `layer: i8` and `flags: u8` to `WayHeader`. Struct grows from 9 to 11 bytes.

**Advantages:**
- Cleaner data model, single struct per way

**Disadvantages:**
- Breaks binary compatibility: ALL existing indexes must be rebuilt
- Planet rebuild takes 55 minutes
- Old server cannot read new indexes; new server cannot read old indexes

### Recommendation: Option A

Backward compatibility matters more than struct elegance. The parallel file approach
lets users upgrade the server binary without rebuilding their index. Once they
rebuild with a new builder version, z-level scoring activates automatically.

## Server scoring algorithm

When `alt` is provided and `street_flags.bin` is loaded:

1. **Estimate query layer from altitude:**
   - `alt < 5m` -> layer 0 (ground level) or -1 (tunnel, if alt < -5m)
   - `alt > 15m` -> layer +1 (bridge/overpass)
   - `5m <= alt <= 15m` -> layer 0 (ambiguous, no preference)
   - These thresholds should be configurable via server flags

2. **Apply layer penalty to distance:**
   ```rust
   let layer_penalty = if way_layer == estimated_layer {
       1.0  // same layer: no penalty
   } else {
       1.5  // different layer: 50% distance penalty
   };
   let effective_dist = actual_dist * layer_penalty;
   ```

3. **Comparison uses effective_dist** for ranking, but the `max_distance_sq` gate
   uses the original distance (a mismatched-layer street at 30m is still a valid
   result, just ranked lower than a same-layer street at 40m).

### Default penalty: 1.5x

A same-layer street at 75m beats a different-layer street at 50m. This is
intentionally conservative -- GPS altitude error means we cannot be certain about
the layer, so we prefer the closer road unless the layer signal is strong.

Configurable via `--layer-penalty <float>` server flag (default 1.5).

## Graceful degradation

| Scenario | Behavior |
|----------|----------|
| Old index + new server | No `street_flags.bin` -> z-level disabled, no change |
| New index + old server | Extra file ignored, no change |
| New index + new server, no `alt` param | Z-level available but not used |
| New index + new server, `alt` provided | Full z-level scoring |
| Way without `layer` tag in OSM | Builder writes layer=0, flags=0 (no bridge/tunnel) |

## Builder implementation notes

In `build_index.cpp`, extract tags in the way handler:

```cpp
// In BuildHandler::way() or WayNodeCollector, after highway filter:
int8_t layer = 0;
uint8_t flags = 0;
const char* layer_tag = way.tags()["layer"];
if (layer_tag) layer = static_cast<int8_t>(std::atoi(layer_tag));
if (way.tags()["bridge"] && std::strcmp(way.tags()["bridge"], "yes") == 0) flags |= 0x01;
if (way.tags()["tunnel"] && std::strcmp(way.tags()["tunnel"], "yes") == 0) flags |= 0x02;
```

Write `street_flags.bin` as a flat array indexed by way ID, written in the same
order as `street_ways.bin`.

## Tests needed

- Unit test: layer estimation from altitude values
- Unit test: penalty scoring with same/different layers
- Unit test: graceful fallback when `street_flags.bin` is absent
- Integration test: query with `alt` parameter returns correct response format
- Regression test: existing queries without `alt` produce identical results

## Not in scope

- 3D routing or navigation
- Indoor positioning (`level` tag)
- Multi-story parking structures
- Altitude correction (geoid vs ellipsoid)
