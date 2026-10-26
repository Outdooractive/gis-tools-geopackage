# ``GISToolsGeoPackage``

Read and write OGC GeoPackage (`.gpkg`) files with GISTools geometry and
feature types.

## Overview

`GISToolsGeoPackage` is the GeoPackage companion to
[GISTools](https://github.com/Outdooractive/gis-tools). It stores GeoJSON
features, tile pyramids, non-spatial attribute tables and Related Tables
Extension media in a single SQLite container.

The package covers:

- **Feature tables** — typed properties, GeoJSON identifiers, unlocated
  features, and projection-aware geometry blobs.
- **Spatial indexes** — `gpkg_rtree_index` creation and maintenance.
- **Queries** — stable pagination, bounding-box filtering and async streaming.
- **Tiles** — tile pyramids with validated `gpkg_tile_matrix` metadata.
- **Attribute and media tables** — including the Related Tables Extension.
- **Validation** — structural and metadata checks against GeoPackage 1.2.

> Important: GeoPackage stores one CRS per table. Features written with a
> different projection are reprojected into the table CRS. Coordinates without
> an SRID use the GeoPackage-defined undefined geographic SRS (`srs_id = 0`).

## Quick example

```swift
import GISTools
import GISToolsGeoPackage

let collection = try GeoPackageCoder.read(from: inputURL)

try GeoPackageCoder.write(
    collection,
    to: outputURL,
    createSpatialIndex: true)

let validation = try GeoPackage.validate(url: outputURL)
print(validation.isValid)
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:FeatureTables>

### Connections and raster data

- <doc:ConnectionsAndTiles>

### Validation and extension tables

- <doc:ValidationAndRelationships>
