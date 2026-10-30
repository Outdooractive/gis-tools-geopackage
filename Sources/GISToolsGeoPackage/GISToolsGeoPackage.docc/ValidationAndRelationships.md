# Validation, attribute tables and relationships

Inspect a GeoPackage against the 1.2 specification and work with the Related
Tables Extension.

## Validation

```swift
let validation = try GeoPackage.validate(url: url)

if !validation.isValid {
    for issue in validation.errors {
        print(issue.message)
    }
}
```

``GeoPackageValidation`` separates fatal `errors` from non-fatal `warnings`.
``GeoPackageValidationIssue`` is `Equatable`, which makes precise assertions in
tests straightforward.

The validator checks:

- the application ID and `user_version`,
- mandatory tables and their required columns,
- that SRS references resolve,
- geometry columns and their geometry type / Z / M values,
- tile matrix set and tile matrix metadata,
- extension scopes.

Validation opens the file read-only. A missing path throws
``GeoPackageError/couldNotOpenDatabase(path:detail:)`` instead of creating an
empty database.

The connection exposes the same result:
``GeoPackageConnection/validate()``.

## Attribute tables

``AttributeTable`` models a non-spatial table (`data_type = "attributes"`).

```swift
let table = AttributeTable(
    tableName: "station_info",
    columns: ["name", "elevation"],
    rows: [["name": "Summit", "elevation": 1_200]],
    rowIds: [1])

try GeoPackage.writeAttributeTable(table, to: url)

let read = try GeoPackage.readAttributeTable(
    from: url,
    table: "station_info")
```

The writer infers column types from all rows, supports `Bool`, integers,
`Double`, `String` and `Data`, adds missing columns on an existing table and
replaces the table's previous rows in one transaction. The `id` column is
reserved and managed by the library.

## Media tables

``MediaTable`` stores blobs with a MIME content type.

```swift
let media = MediaTable(
    tableName: "photos",
    rowIds: [1],
    data: [pngData],
    contentTypes: ["image/png"],
    properties: [["caption": "Summit"]])

try GeoPackage.writeMediaTable(media, to: url)
```

``GeoPackage/readMediaTable(from:table:)`` returns blobs as `Data`.
``GeoPackage/readMediaRows(from:table:rowId:)`` filters by primary key.

Binary property values are represented as Base64 strings when reading, and can
be supplied as `Data` when writing.

## Relationships

The Related Tables Extension links feature, attribute and media tables.
``RelationRow`` describes one row of `gpkgext_relations`.

```swift
let relation = RelationRow(
    id: UUID().uuidString,
    tableName: "features",
    columnName: "geom",
    relatedTableName: "station_info",
    relatedColumnName: "id",
    relationName: .attributes)

try await gpkg.write(relation: relation)
```

Writing a relation registers `gpkgext_relations` in `gpkg_extensions`
idempotently. Reusing an existing relationship ID replaces that row.

Features loaded from a GeoPackage can resolve their related rows directly:

```swift
let attributes = try await feature.relatedAttributes(in: gpkg)
let media = try await feature.relatedMedia(in: gpkg)
```

The lookups use `Feature.gpkgRowId` and `Feature.gpkgTableName`. If the
extension or a matching relationship is absent they return an empty array.

## Limitations

- One geometry column and one CRS per feature table. Data in other projections
  is reprojected on write.
- `2d-gridded-coverage` tables are recognised by validation but not read or
  written.
- R-tree entries are maintained for rows written through this library. The
  standard SQLite trigger set (`ST_MinX`, ...) is **not** installed, so external
  SQL updates to a geometry blob do not update the index automatically.
- The Related Tables Extension mapping tables for many-to-many relationships
  are represented by ``RelationRow/mappingTableName`` but not created or
  queried automatically.
- Nested array/dictionary property values must be flattened before writing.
- Base64 is the in-memory representation of BLOBs. Writing a `String` always
  produces `TEXT`; pass `Data` to store a BLOB.
- There is no support for GeoPackage 1.3 features, encryption or
  `WITHOUT ROWID` feature tables.
- Antimeridian-crossing bounding boxes use an in-memory filter because the
  R-tree stores raw coordinates.

## See also

- [Getting started][gettingstarted]
- [Feature tables and queries][featuretables]
- [Connections, streaming and tiles][connectionsandtiles]

[gettingstarted]: https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage/documentation/gistoolsgeopackage/gettingstarted
[featuretables]: https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage/documentation/gistoolsgeopackage/featuretables
[connectionsandtiles]: https://swiftpackageindex.com/Outdooractive/gis-tools-geopackage/documentation/gistoolsgeopackage/connectionsandtiles
