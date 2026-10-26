# Feature tables and queries

Store GeoJSON features with typed identifiers, properties and projection-aware
geometry blobs, and query them with stable pagination or bounding boxes.

## Identifiers and row IDs

GeoPackage and GeoJSON both have an "id", but they mean different things.
Every feature table created by this package has:

| Column | SQL type | Meaning |
|---|---|---|
| `fid` | `INTEGER PRIMARY KEY AUTOINCREMENT` | GeoPackage row ID |
| `id` | `INTEGER`, `REAL` or `TEXT` | GeoJSON `Feature.id` |
| `geom` | geometry type name | GeoPackage geometry blob |

`Feature.gpkgRowId` exposes the `fid` value and `Feature.gpkgTableName`
exposes the table name. Both are set by the reader and stored in the feature's
foreign members.

```swift
let feature = collection.features[0]
print(feature.id as Any)          // GeoJSON identifier
print(feature.gpkgRowId as Any)   // SQLite rowid
print(feature.gpkgTableName as Any)
```

The `id` column type is inferred from the collection:

| `Feature.id` values | `id` column | Read-back value |
|---|---|---|
| all `.int` / `.uint` | `INTEGER` | `.int` |
| all `.double` | `REAL` | `.double` |
| all `.string` | `TEXT` | `.string` |
| mixed types or none | `TEXT` | `.string` for scalar values |

Values above `Int64.max` fall back to a `TEXT` column.

When reading a third-party GeoPackage that has no `id` column, the `fid`
column is promoted to `Feature.id` (in addition to populating
`Feature.gpkgRowId`). When both columns exist, `id` wins.

## Properties

Property columns are created from the union of keys across all features. Types
are inferred across every non-null value:

| Swift value | Declared column | Read-back value |
|---|---|---|
| `Bool` | `BOOLEAN` | `Bool` |
| integers | `INTEGER` | `Int` |
| integers and doubles | `REAL` | `Double` |
| `Double` only | `REAL` | `Double` |
| `String` | `TEXT` | `String` |
| `Data` | `BLOB` | Base64 `String` |
| mixed | `TEXT` | SQLite affinity result |

Text is **always** stored as text. A string that happens to look like Base64
(such as `"Test"` or `"1234"`) is not converted to a BLOB.

> Important: `id`, `fid` and `geom` are reserved. A property with one of those
> names (case-insensitively) throws ``GeoPackageError`` instead of being
> silently dropped. Nested arrays and dictionaries are not supported as column
> values and also throw; flatten them to scalar properties first.

## Unlocated features

RFC 7946 allows a feature without geometry. The writer stores `NULL` in the
geometry column and the reader returns a feature whose geometry is `nil`.
Unlocated features keep their identifier and properties, participate in
streaming, and are skipped by bounding-box queries and the R-tree.

```swift
let feature = Feature(
    id: .string("note"),
    properties: ["text": "No geometry"])
```

## Pagination

Rows are returned in ascending `rowid` order, making pages stable as long as
the table is not modified between calls.

```swift
let page = try await connection.readFeatures(
    table: "places",
    limit: 100,
    offset: 200)
```

Negative `limit` or `offset` values throw ``GeoPackageError/invalidArgument(detail:)``.

## Bounding-box queries

```swift
let filtered = try await connection.readFeatures(
    table: "places",
    boundingBox: bbox)
```

The bounding box is projected to the table CRS. If an R-tree index exists the
query uses it; otherwise the reader decodes the table and filters in memory
before applying `limit`/`offset`, so pagination stays correct. Create a spatial
index (`createSpatialIndex: true`) for large tables.

Bounding boxes crossing the antimeridian cannot be expressed by the R-tree's
raw coordinate comparison. Those queries automatically use the in-memory
fallback.

## Appending rows

Writing to an existing feature table appends rows. Missing property columns are
added, bounds are extended and an existing spatial index is maintained even if
`createSpatialIndex` is `false`.

```swift
try await connection.write(features: firstBatch, to: "places")
try await connection.write(features: secondBatch, to: "places")
```

All rows of one call are written in a transaction. Geometry type conflicts
(for example appending polygons to a `POINT` table) throw
``GeoPackageError/mixedGeometryTypes(detail:)`` and leave the table unchanged.

## See also

- <doc:ConnectionsAndTiles>
- <doc:ValidationAndRelationships>
