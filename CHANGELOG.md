# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
semantic versioning.

## Unreleased

## 3.0.0 - 2026-10-30

### Added

- Synchronous `GeoPackageCoder.read(from:)` / `GeoPackageCoder.write(_:to:)`
  entry points, matching the other `GISTools*` coders.
- `GeoPackageConnection.featureTables()` and `tileTables()` inspection helpers.
- MapTile (XYZ) tile read/write overloads on `GeoPackageConnection`.
- `FeatureStream` limit/offset support, a public URL initializer and bounded
  chunk fetching.
- `GeoPackage.readContents(from:)` is now public.
- Transactional feature, tile, attribute and media writes.
- Incremental feature writes: appending, new columns, bounds updates and R-tree
  maintenance.
- Unlocated (geometry-less) feature read/write support.
- `gpkg_geometry_columns.z`/`m` are inferred from the geometries and widened
  when appending 2D/3D/measured data.
- DocC catalog and documentation build check (`scripts/check_documentation.py`).
- Coverage report and 85% gate (`scripts/coverage_summary.py`).
- Linux CI job, coverage artifacts and a documentation job.

### Changed

- Updated `gis-tools` to 3.0.0.
- `noSRID` data is stored as GeoPackage SRS `0` instead of being silently
  labelled EPSG:4326. EPSG:4326 remains unchanged.
- Features from different projections are reprojected into the table CRS
  instead of writing coordinates in the wrong CRS.
- Reading and validation open files read-only; missing paths throw instead of
  creating an empty database.
- Attribute and media table writes replace the table's previous rows.
- GeoPackage 1.2 metadata schema: removed the non-standard `srs_type` column,
  made `gpkg_contents.identifier` unique, used the `%fZ` timestamp format and
  writes the required `GPKG` application ID. Legacy packages with `srs_type`
  or the old `GP10` application ID remain readable and writable.
- `GeoPackageValidationIssue` and `GeoPackageError` conform to `Equatable`.
- `GeoPackageError` conforms to `Sendable`.

### Fixed

- GeoPackage header flags were interpreted with the empty and byte-order bits
  swapped; non-empty little-endian geometries are now written and read
  correctly. Envelope endianness is honoured.
- Envelope indicator `3` was parsed as eight doubles instead of six.
- `WKBHeader.hasZ`/`hasM` always returned `false`.
- Ordinary text that looked like Base64 (for example `"Test"` or `"1234"`) was
  written as a BLOB.
- Bounding-box reads returned every row when an R-tree query matched nothing.
- Bounding-box queries compared degrees with projected R-tree coordinates.
- Pagination without an R-tree applied `LIMIT`/`OFFSET` before filtering, so
  pages could be empty or inconsistent.
- `FeatureStream` shared prepared statements and database rows with the
  connection actor without serialisation; it now uses bounded serialised
  queries. A join could also overwrite the feature `id` with the R-tree `id`.
- Appending a feature with an uncomputable geometry could desynchronise R-tree
  ids from feature rowids.
- R-tree ids could become stale when appending; existing indexes are now
  maintained even when `createSpatialIndex` is false.
- `gpkg_contents.identifier` stored a quoted SQL literal instead of the table
  name.
- Invalid SRS references, missing geometry columns and inconsistent tile
  metadata are reported more accurately; empty `gpkg_contents` no longer
  reports `emptySrsTable`.
- `registerRelatedTablesExtension` inserted a duplicate row on every call.
- Duplicate relationship ids now replace the existing relation.
- `readRelations` throws no longer when the optional extension table is absent.
- Attribute/media values such as `Bool`, `Data` and `Double` were silently
  written as `NULL` or text; they now use parameter binding and correct types.
- Media table array-length mismatches could crash the writer; they now throw.
- SQL identifiers are consistently quoted, including tables using reserved
  words.
- Writer rejects property/table names that would collide with reserved
  GeoPackage columns or tables instead of producing confusing SQL errors.

### Notes

- This release contains source-breaking additions to public enums
  (`GeoPackageError`, `GeoPackageValidationIssue`). Exhaustive switches in
  clients must add a `default` case.
- BLOB values are still read as Base64 strings. Writing a `String` always
  produces `TEXT`; pass `Data` to store a BLOB.
