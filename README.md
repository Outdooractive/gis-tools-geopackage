[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FOutdooractive%2Fgis-tools-geopackage%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FOutdooractive%2Fgis-tools-geopackage%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage)
[![](https://img.shields.io/github/license/Outdooractive/gis-tools-geopackage)](https://github.com/Outdooractive/gis-tools-geopackage/blob/main/LICENSE)  
[![](https://img.shields.io/github/v/release/Outdooractive/gis-tools-geopackage?sort=semver&display_name=tag)](https://github.com/Outdooractive/gis-tools-geopackage/releases) [![](https://img.shields.io/github/release-date/Outdooractive/gis-tools-geopackage?display_date=published_at)](https://github.com/Outdooractive/gis-tools-geopackage/releases)  
[![](https://img.shields.io/github/issues/Outdooractive/gis-tools-geopackage)](https://github.com/Outdooractive/gis-tools-geopackage/issues) [![](https://img.shields.io/github/issues-pr/Outdooractive/gis-tools-geopackage)](https://github.com/Outdooractive/gis-tools-geopackage/pulls)

# GISToolsGeoPackage

OGC GeoPackage (`.gpkg`) read and write support for Swift, built on top of [**gis-tools**](https://github.com/Outdooractive/gis-tools).

## Features

- **Feature tables** — read/write vector features with geometry, typed properties and GeoJSON identifiers
- **Projection aware** — WGS 84, Web Mercator, ECEF and `noSRID`, with per-table SRS metadata
- **Spatial index (R-tree)** — `gpkg_rtree_index` creation, maintenance and bounding-box queries
- **Tile pyramids** — raster tile blobs (PNG/JPEG/WebP) with validated tile matrix metadata
- **Attribute tables** — non-spatial data with `data_type = "attributes"`
- **Media tables** — blob storage linked to features (Related Tables Extension)
- **Relationships** — `gpkgext_relations` registration and feature-level lookups
- **Schema validation** — `GeoPackage.validate(url:)` checks GeoPackage 1.2 compliance
- **Async streaming** — `FeatureStream` yields features in bounded chunks
- **Thread-safe connection** — `GeoPackageConnection` actor with pagination and incremental writes
- **Transactions** — feature, tile, attribute and media writes roll back on error

## Requirements

Swift 6.1 or higher. The package declares iOS 15+, macOS 15+, tvOS 15+,
watchOS 7+ and builds on Linux; other Swift platforms work when `libsqlite3`
is available. It links the system SQLite library:
`libsqlite3` ships with Apple platforms; on Debian/Ubuntu install
`libsqlite3-dev`.

## Installation with Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Outdooractive/gis-tools-geopackage", from: "1.0.0"),
    .package(url: "https://github.com/Outdooractive/gis-tools", exact: "3.0.0-beta.5"),
],
targets: [
    .target(name: "MyTarget", dependencies: [
        .product(name: "GISToolsGeoPackage", package: "gis-tools-geopackage"),
        .product(name: "GISTools", package: "gis-tools"),
    ]),
]
```

The package pins the matching `gis-tools` version so geometry, projection and
identifier behaviour stays in sync.

## Usage

### Feature tables (synchronous coder)

```swift
import GISTools
import GISToolsGeoPackage

let collection = try GeoPackageCoder.read(from: url, table: "countries")

try GeoPackageCoder.write(
    collection,
    to: outputURL,
    table: "countries",
    createSpatialIndex: true)
```

### Feature tables (asynchronous convenience API)

```swift
let fc = try await FeatureCollection(geopackage: url, table: "features")
try await fc.writeGeopackage(to: outputURL, table: "features")
```

Both read entry points open the file **read-only**, validate the GeoPackage
and throw `GeoPackageError` for missing files or invalid tables. Reading a
missing path no longer creates an empty database.

### Connection-based API

```swift
let gpkg = try await GeoPackageConnection(url: url)
defer { await gpkg.close() }

// Paginated read (rows are ordered by rowid):
let page = try await gpkg.readFeatures(table: "countries", limit: 100, offset: 0)

// Schema inspection:
let featureTables = try await gpkg.featureTables()
let tileTables = try await gpkg.tileTables()

// Incremental write (appends to an existing table):
try await gpkg.write(features: batch1, to: "places")
try await gpkg.write(features: batch2, to: "places")
```

`write(features:to:)` appends when the table exists, adds new property columns,
extends the metadata bounds and keeps an existing R-tree index in sync. All
rows of one call are written in a transaction.

Open with `readOnly: true` for read-only workflows:

```swift
let gpkg = try await GeoPackageConnection(url: url, readOnly: true)
```

### Streaming

```swift
for try await feature in gpkg.features(table: "countries") {
    // process one feature at a time
}
```

The stream fetches bounded chunks, supports `boundingBox`, `limit` and `offset`,
and throws on malformed geometry data instead of silently skipping rows.
`FeatureStream(url:table:boundingBox:limit:offset:)` creates a standalone
read-only stream.

### Bounding-box queries

```swift
let bbox = BoundingBox(
    southWest: Coordinate3D(latitude: 35.0, longitude: -10.0),
    northEast: Coordinate3D(latitude: 60.0, longitude: 40.0))

let filtered = try await FeatureCollection(
    geopackage: url,
    table: "countries",
    boundingBox: bbox)
```

The bounding box is projected to the table CRS. The R-tree is used when
present; otherwise the table is decoded and filtered in memory before
pagination. Antimeridian-crossing boxes automatically use the in-memory
fallback. Create a spatial index for large tables.

### Tile pyramids

```swift
// Read a single tile:
let data = try await gpkg.readTile(
    for: TileKey(zoom: 5, column: 12, row: 8),
    from: "tiles")

// XYZ coordinates are converted to TMS using the matrix height:
let xyz = try await gpkg.readTile(
    for: MapTile(x: 12, y: 20, z: 5),
    matrixHeight: 32,
    from: "tiles")

// Write a tile pyramid:
try await gpkg.writeTilePyramid(
    tiles: tileData,
    to: "tiles",
    srsId: 3857,
    matrixSetBounds: bounds,
    matrices: matrices)
```

The pyramid writer validates matrix dimensions, zoom levels, tile references,
table names and that `matrixSetBounds` uses the CRS identified by `srsId`. It
creates the SRS row when needed, writes everything in one transaction and
replaces the table's previous tiles and matrix rows.

### Attribute and media tables

```swift
// Non-spatial attribute table:
let attrs = try await gpkg.readAttributeTable(table: "station_info", rowId: 42)

// Media rows:
let media = try await gpkg.readMediaRows(table: "photos", rowId: 1)
```

The static `GeoPackage` entry points work without a connection:

```swift
let table = try GeoPackage.readAttributeTable(from: url, table: "station_info")
try GeoPackage.writeMediaTable(mediaTable, to: url)
```

### Validation

```swift
let result = try GeoPackage.validate(url: url)
if result.isValid {
    // conforms to the checked GeoPackage 1.2 requirements
}
```

Validation is read-only and reports errors and warnings separately
(`GeoPackageValidation.errors` / `.warnings`).

### Relationships

When features are loaded from a GeoPackage, the row ID and table name are
stored in `foreignMembers`:

```swift
let feature = fc.features[0]
print(feature.gpkgRowId)       // Int?
print(feature.gpkgTableName)   // String?

let related = try await feature.relatedAttributes(in: gpkg)
let media = try await feature.relatedMedia(in: gpkg)
```

Relationships without a matching extension or relation return an empty array.

## Feature identifiers

GeoPackage feature tables distinguish two identifiers. This library writes
both:

| Column | SQL type | Meaning |
|---|---|---|
| `fid` | `INTEGER PRIMARY KEY AUTOINCREMENT` | SQLite rowid / GeoPackage row ID |
| `id` | `INTEGER`, `REAL` or `TEXT` | GeoJSON `Feature.id` |

The `id` column type is inferred from the collection:

| `Feature.id` values | `id` column type | Read-back `Feature.id` |
|---|---|---|
| all `.int` / `.uint` | `INTEGER` | `.int` |
| all `.double` | `REAL` | `.double` |
| all `.string` | `TEXT` | `.string` |
| mixed types (or none) | `TEXT` | `.string` fallback |

Values above `Int64.max` fall back to `TEXT`. `feature.gpkgRowId` always
reflects the `fid` primary key and is the value used to resolve related rows.
On read-back the `id`/`fid` value is promoted to `Feature.id` based on the
runtime SQLite cell type; `id`/`fid`/geometry columns are never leaked into
`feature.properties`.

## Property type mapping

Feature properties, attribute columns and media properties map as follows:

| GeoPackage type | Swift type |
|---|---|
| `INTEGER` | `Int` |
| `REAL` | `Double` |
| `TEXT` | `String` |
| `BLOB` | `String` (Base64) |
| `BOOLEAN` | `Bool` |

Writing rules:

- `String` values are **always** stored as `TEXT`. Base64-looking text such as
  `"Test"` or `"1234"` is not converted to a BLOB.
- Pass `Data` to store a BLOB; read it back as a Base64 `String`.
- `id`, `fid` and `geom` are reserved property names and throw instead of
  being silently dropped.
- Nested arrays/dictionaries are not supported as column values; flatten them
  first.

## Projections and SRS IDs

Each feature table stores one CRS. Features written with a different projection
are reprojected into the table CRS. `noSRID` coordinates use GeoPackage's
undefined geographic SRS (`srs_id = 0`) and read back as `Projection.noSRID`.
Unknown non-EPSG SRS IDs also read back as `noSRID` without pretending the data
is EPSG:4326.

The metadata SRS rows mandated by GeoPackage 1.2 (`4326`, `0`, `-1`) are
created automatically, along with `3857` and `4978`.

## Schema notes

Created metadata tables follow GeoPackage 1.2: `gpkg_spatial_ref_sys` has no
`srs_type` column, `gpkg_contents.identifier` is `UNIQUE`, and timestamps use
the `%fZ` format. Legacy packages created by earlier versions of this library
(with an `srs_type` column) remain writable.

## Limitations

- One geometry column and one CRS per feature table.
- `2d-gridded-coverage` tables are not supported.
- R-tree entries are maintained for rows written through this library. The
  standard SQLite `ST_MinX` trigger set is not installed, so external SQL
  updates to geometry blobs do not update the index automatically.
- Related Tables mapping tables for many-to-many relationships are represented
  but not created/queried automatically.
- No GeoPackage 1.3 features, encryption or `WITHOUT ROWID` feature tables.
- Antimeridian-crossing bounding boxes use an in-memory filter.

## Development

```sh
swift test
swift test --enable-code-coverage
python3 scripts/coverage_summary.py --minimum 85
python3 scripts/check_documentation.py
```

CI runs the test suite with coverage on macOS and Linux and builds the DocC
catalog. The coverage gate is 85% line coverage for
`Sources/GISToolsGeoPackage`.

## Contributing

Please [create an issue](https://github.com/Outdooractive/gis-tools-geopackage/issues) or [open a pull request](https://github.com/Outdooractive/gis-tools-geopackage/pulls) with a fix or enhancement.

## License

MIT

## Authors

Thomas Rasch, Outdooractive

Built on top of [**gis-tools**](https://github.com/Outdooractive/gis-tools).
