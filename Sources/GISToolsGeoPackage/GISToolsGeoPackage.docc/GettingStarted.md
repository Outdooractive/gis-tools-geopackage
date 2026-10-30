# Getting started

Install `GISToolsGeoPackage`, read a feature table and write it back with a
spatial index.

## Installation

Add the package and its GISTools dependency to your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/Outdooractive/gis-tools-geopackage",
        from: "3.0.0"),
    .package(
        url: "https://github.com/Outdooractive/gis-tools",
        from: "3.0.0"),
],
targets: [
    .target(name: "MyTarget", dependencies: [
        .product(name: "GISToolsGeoPackage", package: "gis-tools-geopackage"),
        .product(name: "GISTools", package: "gis-tools"),
    ]),
]
```

The [GIS tools](https://github.com/Outdooractive/gis-tools) dependency
provides `Point`, `FeatureCollection`, bounding boxes and the geometry
algorithms used in the examples.

| Requirement | Version |
|---|---|
| Swift | 6.1 or newer |
| iOS | 15.0 or newer |
| macOS | 15.0 or newer |
| tvOS | 15.0 or newer |
| watchOS | 7.0 or newer |
| Linux | Swift 6.1 toolchain with `libsqlite3-dev` |

The package links the system SQLite library. On Debian and Ubuntu install it
with `sudo apt-get install libsqlite3-dev`; it ships with Apple platforms.

## Read a feature table

Use ``GeoPackageCoder`` for a synchronous one-shot read:

```swift
import GISTools
import GISToolsGeoPackage

let collection = try GeoPackageCoder.read(
    from: url,
    table: "countries")
```

The asynchronous convenience initializer is equivalent:

```swift
let collection = try await FeatureCollection(
    geopackage: url,
    table: "countries")
```

Both entry points open the file read-only, validate the GeoPackage structure
and throw ``GeoPackageError`` when the file is missing, invalid or the table is
not a feature table.

## Write a feature table

```swift
var collection = FeatureCollection([
    Feature(
        Point(Coordinate3D(latitude: 48.1372, longitude: 11.5756)),
        id: .string("munich"),
        properties: ["name": "Munich"]),
])

try await collection.writeGeopackage(
    to: outputURL,
    table: "places",
    createSpatialIndex: true)
```

Or synchronously:

```swift
try GeoPackageCoder.write(
    collection,
    to: outputURL,
    table: "places",
    createSpatialIndex: true)
```

The write creates the mandatory GeoPackage metadata tables when needed.
Writing to an existing feature table appends rows, adds new property columns
and extends the table bounds.

## Filter by bounding box

```swift
let bavaria = BoundingBox(
    southWest: Coordinate3D(latitude: 47.0, longitude: 9.0),
    northEast: Coordinate3D(latitude: 50.5, longitude: 13.5))

let nearby = try GeoPackageCoder.read(
    from: url,
    table: "places",
    boundingBox: bavaria)
```

Bounding boxes are projected into the table CRS automatically. An R-tree index
is used when present; otherwise the filter is applied after decoding.

## See also

- [Feature tables and queries][featuretables]
- [Connections, streaming and tiles][connectionsandtiles]
- [Validation, attribute tables and relationships][validationandrelationships]

[featuretables]: https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage/documentation/gistoolsgeopackage/featuretables
[connectionsandtiles]: https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage/documentation/gistoolsgeopackage/connectionsandtiles
[validationandrelationships]: https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage/documentation/gistoolsgeopackage/validationandrelationships
