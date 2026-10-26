import Foundation
import GISTools

/// Writes tile (raster) data to a GeoPackage database.
enum TileWriter {

    /// Creates a tile user table with the standard GeoPackage schema.
    ///
    /// - Parameters:
    ///   - tableName: The name for the new tile table.
    ///   - db: An open SQLite database handle.
    static func createTileTable(
        _ tableName: String,
        in db: SQLiteDB
    ) throws {
        let sanitized = GeoPackage.sanitizeIdentifier(tableName)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS \(sanitized) (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                zoom_level INTEGER NOT NULL,
                tile_column INTEGER NOT NULL,
                tile_row INTEGER NOT NULL,
                tile_data BLOB NOT NULL,
                UNIQUE (zoom_level, tile_column, tile_row)
            );
            """)
    }

    /// Writes a single tile blob to a tile table.
    ///
    /// - Parameters:
    ///   - tileData: The raw PNG / JPEG / WebP tile data.
    ///   - key: The tile key (zoom, column, row in TMS convention).
    ///   - tableName: The target tile table name.
    ///   - db: An open SQLite database handle.
    static func write(
        tileData: Data,
        for key: TileKey,
        to tableName: String,
        in db: SQLiteDB
    ) throws {
        let sanitized = GeoPackage.sanitizeIdentifier(tableName)
        try db.execute(
            """
            INSERT OR REPLACE INTO \(sanitized)
            (zoom_level, tile_column, tile_row, tile_data)
            VALUES (?, ?, ?, ?);
            """,
            values: [key.zoom, key.column, key.row, tileData])
    }

    /// Writes a single tile blob using a MapTile (XYZ convention).
    ///
    /// The y-coordinate is converted from XYZ (0 = top) to TMS
    /// (0 = bottom) using the given matrix height.
    ///
    /// - Parameters:
    ///   - tileData: The raw PNG / JPEG / WebP tile data.
    ///   - mapTile: The tile in XYZ convention.
    ///   - matrixHeight: The total number of tile rows at the tile's
    ///     zoom level.
    ///   - tableName: The target tile table name.
    ///   - db: An open SQLite database handle.
    static func write(
        tileData: Data,
        for mapTile: MapTile,
        matrixHeight: Int,
        to tableName: String,
        in db: SQLiteDB
    ) throws {
        let key = TileKey(from: mapTile, matrixHeight: matrixHeight)
        try write(tileData: tileData, for: key, to: tableName, in: db)
    }

    /// Writes a complete tile pyramid including metadata.
    ///
    /// Creates the tile table, inserts all tile blobs, and writes
    /// `gpkg_contents`, `gpkg_tile_matrix_set` and `gpkg_tile_matrix`
    /// metadata rows inside one transaction. Existing rows and matrix entries
    /// for the table are replaced. Invalid matrix or tile references leave
    /// the database unchanged.
    ///
    /// - Parameters:
    ///   - tiles: Tile blobs keyed by (zoom, column, row) in TMS convention.
    ///   - tableName: The name for the new tile table.
    ///   - srsId: The spatial reference system identifier (e.g. 3857).
    ///   - matrixSetBounds: The spatial extent in CRS units.
    ///   - matrices: One entry per zoom level describing the tile grid.
    ///   - identifier: An optional human-readable identifier.
    ///   - description: An optional table description.
    ///   - db: An open SQLite database handle.
    static func writeTilePyramid(
        tiles: [TileKey: Data],
        to tableName: String,
        srsId: Int = 3857,
        matrixSetBounds: BoundingBox,
        matrices: [TileMatrix],
        identifier: String? = nil,
        description: String? = nil,
        in db: SQLiteDB
    ) throws {
        try GeoPackage.validateTableName(tableName)
        try GeoPackage.ensureContentsDataType(
            "tiles", for: tableName, in: db)

        guard !tiles.isEmpty else {
            throw GeoPackageError.invalidGeoPackage(
                detail: "Tile pyramid must contain at least one tile")
        }
        guard !matrices.isEmpty else {
            throw GeoPackageError.invalidGeoPackage(
                detail: "Tile pyramid must contain at least one tile matrix")
        }
        let expectedProjection = GeoPackage.projection(for: srsId)
        if matrixSetBounds.projection != .noSRID,
           matrixSetBounds.projection != expectedProjection
        {
            throw GeoPackageError.invalidArgument(
                detail: """
                    Tile matrix set bounds use \(matrixSetBounds.projection), \
                    but srsId \(srsId) resolves to \(expectedProjection)
                    """)
        }

        try validate(
            tiles: tiles,
            matrices: matrices,
            tableName: tableName,
            bounds: matrixSetBounds)

        let ident = identifier ?? tableName
        let desc = description ?? "tile table"
        let bounds = matrixSetBounds

        try db.withTransaction {
            try GeoPackage.ensureSrsRow(srsId, in: db)
            try createTileTable(tableName, in: db)

            // A pyramid write replaces the table's previous contents and
            // matrix rows so removed tiles/zoom levels do not linger.
            try db.execute(
                "DELETE FROM \(GeoPackage.sanitizeIdentifier(tableName));")
            try db.execute(
                "DELETE FROM gpkg_tile_matrix WHERE table_name = ?;",
                values: [tableName])

            for (key, data) in tiles {
                try write(
                    tileData: data,
                    for: key,
                    to: tableName,
                    in: db)
            }

            try db.execute(
                """
                INSERT OR REPLACE INTO gpkg_contents
                (table_name, data_type, identifier, description,
                 last_change, min_x, min_y, max_x, max_y, srs_id)
                VALUES (?, 'tiles', ?, ?,
                 strftime('%Y-%m-%dT%H:%M:%fZ','now'), ?, ?, ?, ?, ?);
                """,
                values: [
                    tableName,
                    ident,
                    desc,
                    bounds.southWest.longitude,
                    bounds.southWest.latitude,
                    bounds.northEast.longitude,
                    bounds.northEast.latitude,
                    srsId,
                ])

            try db.execute(
                """
                INSERT OR REPLACE INTO gpkg_tile_matrix_set
                (table_name, srs_id, min_x, min_y, max_x, max_y)
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                values: [
                    tableName,
                    srsId,
                    bounds.southWest.longitude,
                    bounds.southWest.latitude,
                    bounds.northEast.longitude,
                    bounds.northEast.latitude,
                ])

            for matrix in matrices {
                try db.execute(
                    """
                    INSERT OR REPLACE INTO gpkg_tile_matrix
                    (table_name, zoom_level, matrix_width, matrix_height,
                     tile_width, tile_height, pixel_x_size, pixel_y_size)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    values: [
                        tableName,
                        matrix.zoomLevel,
                        matrix.matrixWidth,
                        matrix.matrixHeight,
                        matrix.tileWidth,
                        matrix.tileHeight,
                        matrix.pixelXSize,
                        matrix.pixelYSize,
                    ])
            }
        }
    }

    // MARK: - Validation

    private static func validate(
        tiles: [TileKey: Data],
        matrices: [TileMatrix],
        tableName: String,
        bounds: BoundingBox
    ) throws {
        guard bounds.southWest.longitude.isFinite,
              bounds.southWest.latitude.isFinite,
              bounds.northEast.longitude.isFinite,
              bounds.northEast.latitude.isFinite
        else {
            throw GeoPackageError.invalidArgument(
                detail: "Tile matrix set bounds must be finite")
        }

        var matrixByZoom: [Int: TileMatrix] = [:]
        for matrix in matrices {
            guard matrix.tableName == tableName else {
                throw GeoPackageError.invalidArgument(
                    detail: """
                        Tile matrix for zoom \(matrix.zoomLevel) belongs to \
                        '\(matrix.tableName)', not '\(tableName)'
                        """)
            }
            guard matrixByZoom[matrix.zoomLevel] == nil else {
                throw GeoPackageError.invalidArgument(
                    detail: "Duplicate tile matrix for zoom \(matrix.zoomLevel)")
            }
            guard matrix.zoomLevel >= 0,
                  matrix.matrixWidth > 0,
                  matrix.matrixHeight > 0,
                  matrix.tileWidth > 0,
                  matrix.tileHeight > 0,
                  matrix.pixelXSize > 0,
                  matrix.pixelYSize > 0,
                  matrix.pixelXSize.isFinite,
                  matrix.pixelYSize.isFinite
            else {
                throw GeoPackageError.invalidArgument(
                    detail: """
                        Tile matrix for zoom \(matrix.zoomLevel) has invalid \
                        dimensions or pixel sizes
                        """)
            }
            matrixByZoom[matrix.zoomLevel] = matrix
        }

        for key in tiles.keys {
            guard let matrix = matrixByZoom[key.zoom] else {
                throw GeoPackageError.invalidArgument(
                    detail: "Tile zoom \(key.zoom) has no tile matrix")
            }
            guard key.column >= 0, key.column < matrix.matrixWidth,
                  key.row >= 0, key.row < matrix.matrixHeight
            else {
                throw GeoPackageError.invalidArgument(
                    detail: """
                        Tile \(key.zoom)/\(key.column)/\(key.row) is outside \
                        the \(matrix.matrixWidth)x\(matrix.matrixHeight) matrix
                        """)
            }
        }
    }

}
