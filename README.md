[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FOutdooractive%2Fgis-tools-geopackage%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FOutdooractive%2Fgis-tools-geopackage%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage)
[![](https://img.shields.io/github/license/Outdooractive/gis-tools-geopackage)](https://github.com/Outdooractive/gis-tools-geopackage/blob/main/LICENSE)  
[![](https://img.shields.io/github/v/release/Outdooractive/gis-tools-geopackage?sort=semver&display_name=tag)](https://github.com/Outdooractive/gis-tools-geopackage/releases) [![](https://img.shields.io/github/release-date/Outdooractive/gis-tools-geopackage?display_date=published_at)](https://github.com/Outdooractive/gis-tools-geopackage/releases)  
[![](https://img.shields.io/github/issues/Outdooractive/gis-tools-geopackage)](https://github.com/Outdooractive/gis-tools-geopackage/issues) [![](https://img.shields.io/github/issues-pr/Outdooractive/gis-tools-geopackage)](https://github.com/Outdooractive/gis-tools-geopackage/pulls)

# GISToolsGeoPackage

OGC GeoPackage (.gpkg) read and write support for Swift, built on top of [**gis-tools**](https://github.com/Outdooractive/gis-tools).

## Features

- **Feature tables** — read/write vector features with full geometry and attribute support
- **Spatial index (rtree)** — accelerated bounding-box queries via `gpkg_rtree_index`
- **Tile pyramids** — read/write raster tile blobs (PNG/JPEG/WebP) at multiple zoom levels
- **Attribute tables** — non-spatial data with `data_type = "attributes"`
- **Media tables** — blob storage linked to features (Related Tables Extension)
- **Relationships** — `gpkgext_relations` for linking feature, attribute, and media tables
- **Schema validation** — `GeoPackage.validate(url:)` checks spec compliance
- **Async streaming** — `FeatureStream` yields features one at a time via `AsyncSequence`
- **Thread-safe connection** — `GeoPackageConnection` actor with paginated reads and incremental writes

## Requirements

Swift 6.1 or higher. Compiles on iOS (≥ iOS 15), macOS (≥ macOS 15), tvOS (≥ tvOS 15), watchOS (≥ watchOS 7), Linux, Android and Wasm. Requires `libsqlite3` (available by default on all supported platforms).

## Installation with Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Outdooractive/gis-tools-geopackage", from: "1.0.0"),
    .package(url: "https://github.com/Outdooractive/gis-tools", from: "2.0.0"),
],
targets: [
    .target(name: "MyTarget", dependencies: [
        .product(name: "GISToolsGeoPackage", package: "gis-tools-geopackage"),
        .product(name: "GISTools", package: "gis-tools"),
    ]),
]
```

## Usage

### Feature tables (convenience API)

```swift
import GISTools
import GISToolsGeoPackage

// Read all features:
let fc = try await FeatureCollection(geopackage: url, table: "features")

// Write features:
try await fc.writeGeopackage(to: url, table: "features")
```

### Feature tables (connection-based API)

```swift
let gpkg = try await GeoPackageConnection(url: url)
defer { await gpkg.close() }

// Paginated read:
let page = try await gpkg.readFeatures(table: "countries", limit: 100, offset: 0)

// Async stream:
for try await feature in gpkg.features(table: "countries") {
    // process one at a time
}

// Incremental write:
try await gpkg.createMetadata()
try await gpkg.write(features: batch1, to: "places")
try await gpkg.write(features: batch2, to: "places")
```

### Bounding-box queries

```swift
let bbox = BoundingBox(
    southWest: Coordinate3D(latitude: 35.0, longitude: -10.0),
    northEast: Coordinate3D(latitude: 60.0, longitude: 40.0))
let filtered = try await FeatureCollection(
    geopackage: url, table: "countries",
    boundingBox: bbox)
```

### Tile pyramids

```swift
// Read a single tile:
let data = try await gpkg.readTile(
    for: TileKey(zoom: 5, column: 12, row: 8),
    from: "tiles")

// Write a tile pyramid:
try await gpkg.writeTilePyramid(
    tiles: tileData, to: "tiles",
    matrixSetBounds: bounds, matrices: matrices)
```

### Attribute and media tables

```swift
// Read a non-spatial attribute table:
let attrs = try await gpkg.readAttributeTable(table: "station_info", rowId: 42)

// Read media rows:
let media = try await gpkg.readMediaRows(table: "photos", rowId: 1)
```

### Validation

```swift
let result = try GeoPackage.validate(url: url)
if result.isValid { /* conforms to spec */ }
```

### Relationships

When features are loaded from a GeoPackage, the row ID and table name are stored in `foreignMembers`:

```swift
let feature = fc.features[0]
print(feature.gpkgRowId)       // Int?
print(feature.gpkgTableName)   // String?

// Look up related data:
let related = try await feature.relatedAttributes(in: gpkg)
let media = try await feature.relatedMedia(in: gpkg)
```

### Schema inspection

```swift
let tables = try await gpkg.readContents()
let featureTables = try await gpkg.featureTables()
let tileTables = try await gpkg.tileTables()
```

## Property type mapping

| GeoPackage type | Swift type |
|---|---|
| `INTEGER` | `Int` |
| `REAL` | `Double` |
| `TEXT` | `String` |
| `BLOB` | `String` (Base64) |
| `BOOLEAN` | `Bool` |

## Contributing

Please [create an issue](https://github.com/Outdooractive/gis-tools-geopackage/issues) or [open a pull request](https://github.com/Outdooractive/gis-tools-geopackage/pulls) with a fix or enhancement.

## License

MIT

## Authors

Thomas Rasch, Outdooractive

Built on top of [**gis-tools**](https://github.com/Outdooractive/gis-tools).
