# Connections, streaming and tiles

Reuse one connection for many operations, stream large tables with bounded
memory and write validated tile pyramids.

## The connection actor

``GeoPackageConnection`` serialises access to one SQLite file and keeps the
handle open between operations.

```swift
let gpkg = try await GeoPackageConnection(url: url)
defer { await gpkg.close() }

let tables = try await gpkg.featureTables()
let page = try await gpkg.readFeatures(table: "places", limit: 100)
```

Use ``GeoPackageConnection/init(url:skipValidation:readOnly:)`` with
`readOnly: true` for read-only workflows. Missing files then throw instead of
being created. ``GeoPackageConnection/close()`` is idempotent; operations after
closing throw ``GeoPackageError``.

Inspection helpers:

- ``GeoPackageConnection/readContents()``
- ``GeoPackageConnection/featureTables()``
- ``GeoPackageConnection/tileTables()``
- ``GeoPackageConnection/hasRTreeIndex(for:column:)``

## Streaming

``FeatureStream`` is an `AsyncSequence` backed by bounded chunks. It shares row
decoding with ``GeoPackageConnection/readFeatures(table:boundingBox:)``, so
identifiers, properties, unlocated features and projections behave identically.

```swift
for try await feature in gpkg.features(table: "places") {
    print(feature.id as Any)
}
```

Limit and offset apply to the filtered result set:

```swift
for try await feature in gpkg.features(
    table: "places",
    boundingBox: bbox,
    limit: 500,
    offset: 1_000)
{
    // ...
}
```

``FeatureStream`` also has a public initializer for a standalone read-only
stream: ``FeatureStream/init(url:table:boundingBox:limit:offset:)``.

Malformed geometry blobs throw instead of silently dropping rows. A stream
created from a connection can be used concurrently with other streams; each
database call is serialised by the connection.

## Tile tables

Tiles are addressed by ``TileKey`` in TMS convention (row `0` at the bottom).
`MapTile` uses the XYZ convention (`0` at the top); the connection converts it
using the matrix height.

```swift
let data = try await gpkg.readTile(
    for: TileKey(zoom: 5, column: 12, row: 8),
    from: "tiles")

let xyz = try await gpkg.readTile(
    for: MapTile(x: 12, y: 20, z: 5),
    matrixHeight: 32,
    from: "tiles")
```

## Writing a tile pyramid

```swift
let matrices = [
    TileMatrix(
        tableName: "tiles",
        zoomLevel: 0,
        matrixWidth: 1,
        matrixHeight: 1,
        pixelXSize: 156_543.0,
        pixelYSize: 156_543.0),
]

try await gpkg.writeTilePyramid(
    tiles: tiles,
    to: "tiles",
    srsId: 3857,
    matrixSetBounds: bounds,
    matrices: matrices,
    identifier: "basemap",
    description: "Web Mercator tiles")
```

The writer validates that:

- every tile's zoom has a matrix,
- every tile column and row lies inside its matrix,
- matrix dimensions and pixel sizes are positive and finite,
- matrix table names match the destination table,
- `matrixSetBounds` uses the CRS identified by `srsId`.

The whole pyramid is written in one transaction, and it replaces the table's
previous tiles and matrix rows. A validation or insert error rolls back the
table, metadata rows and SRS entry.

``GeoPackageConnection/readTileTable(_:)`` returns a ``TileTable`` with the
matrix set, matrices and all tile blobs.

## Reading matrices

- ``GeoPackageConnection/readTileMatrixSet(for:)``
- ``GeoPackageConnection/readTileMatrices(for:)``
- ``GeoPackageConnection/readAllTiles(from:)``

Tile matrix set bounds are returned with the SRS projection attached, so a
Web Mercator pyramid reports metres, not degrees.

## See also

- <doc:FeatureTables>
- <doc:ValidationAndRelationships>
