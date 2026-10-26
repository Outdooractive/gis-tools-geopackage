import Foundation
import GISTools

// MARK: - Errors

/// Errors related to GeoPackage file operations.
///
/// These errors are thrown by the GeoPackage reader, writer, tile
/// reader/writer, and validation APIs when the file cannot be opened,
/// the data violates the GeoPackage specification, or an unexpected
/// SQLite error occurs.
public enum GeoPackageError: LocalizedError, Equatable, Sendable {

    /// The GeoPackage database file could not be opened.
    /// - Parameter path: The file path.
    /// - Parameter detail: The underlying SQLite error message.
    case couldNotOpenDatabase(path: String, detail: String)

    /// An SQLite operation returned an unexpected error.
    /// - Parameter detail: The error message from SQLite.
    case sqliteError(detail: String)

    /// The file is not a valid GeoPackage or violates the spec.
    /// - Parameter detail: A description of the violation.
    case invalidGeoPackage(detail: String)

    /// A feature table has more than one geometry column, which is not supported.
    /// - Parameter detail: A description of the conflict.
    case mixedGeometryTypes(detail: String)

    /// The stored WKB geometry data could not be parsed.
    /// - Parameter detail: A description of the parsing failure.
    case invalidWKB(detail: String)

    /// A geometry type used in the file is not supported by this library.
    /// - Parameter type: The unsupported type name.
    case unsupportedGeometryType(type: String)

    /// A requested table does not exist or is not registered with the
    /// expected GeoPackage data type.
    /// - Parameter name: The table name.
    case tableNotFound(name: String)

    /// An argument is outside the range accepted by the API.
    /// - Parameter detail: A description of the invalid argument.
    case invalidArgument(detail: String)

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .couldNotOpenDatabase(let path, let detail):
            "Could not open GeoPackage database at \(path): \(detail)"
        case .sqliteError(let detail):
            "SQLite error: \(detail)"
        case .invalidGeoPackage(let detail):
            "Invalid GeoPackage: \(detail)"
        case .mixedGeometryTypes(let detail):
            "Mixed geometry types: \(detail)"
        case .invalidWKB(let detail):
            "Invalid WKB geometry: \(detail)"
        case .unsupportedGeometryType(let detail):
            "Unsupported geometry type: \(detail)"
        case .tableNotFound(let name):
            "Table not found: \(name)"
        case .invalidArgument(let detail):
            "Invalid argument: \(detail)"
        }
    }
}

// MARK: - GeoPackage metadata

/// Namespace for GeoPackage validation, inspection and extension table
/// helpers.
///
/// The type is intentionally stateless. Use ``GeoPackageConnection`` for
/// long-lived, reusable connections, or the static helpers here for one-shot
/// reads of validation, attribute, media and relationship data.
public enum GeoPackage {

    // MARK: - SQL constants

    /// `"GPKG"` — the application ID required by GeoPackage 1.2.
    static let applicationIdGPKG: Int32 = 1196444487
    /// `"GP10"` — legacy application ID written by earlier versions.
    static let applicationIdGP10: Int32 = 1196437808
    static let userVersion: Int32 = 10200  // 1.2.0

    /// SQL to create the mandatory GeoPackage metadata tables.
    static let createMetadataSQL = """
        CREATE TABLE IF NOT EXISTS gpkg_spatial_ref_sys (
            srs_name TEXT NOT NULL,
            srs_id INTEGER NOT NULL PRIMARY KEY,
            organization TEXT NOT NULL,
            organization_coordsys_id INTEGER NOT NULL,
            definition TEXT NOT NULL,
            description TEXT
        );

        CREATE TABLE IF NOT EXISTS gpkg_contents (
            table_name TEXT NOT NULL PRIMARY KEY,
            data_type TEXT NOT NULL,
            identifier TEXT UNIQUE,
            description TEXT DEFAULT '',
            last_change DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
            min_x DOUBLE,
            min_y DOUBLE,
            max_x DOUBLE,
            max_y DOUBLE,
            srs_id INTEGER,
            CONSTRAINT fk_gc_srs FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys(srs_id)
        );

        CREATE TABLE IF NOT EXISTS gpkg_geometry_columns (
            table_name TEXT NOT NULL,
            column_name TEXT NOT NULL,
            geometry_type_name TEXT NOT NULL,
            srs_id INTEGER NOT NULL,
            z TINYINT NOT NULL,
            m TINYINT NOT NULL,
            CONSTRAINT pk_geom_cols PRIMARY KEY (table_name, column_name),
            CONSTRAINT fk_gc_table FOREIGN KEY (table_name) REFERENCES gpkg_contents(table_name),
            CONSTRAINT fk_gc_srs FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys(srs_id)
        );

        CREATE TABLE IF NOT EXISTS gpkg_extensions (
            table_name TEXT,
            column_name TEXT,
            extension_name TEXT NOT NULL,
            definition TEXT NOT NULL,
            scope TEXT NOT NULL,
            CONSTRAINT ge_tce UNIQUE (table_name, column_name, extension_name)
        );

        CREATE TABLE IF NOT EXISTS gpkg_tile_matrix_set (
            table_name TEXT NOT NULL PRIMARY KEY,
            srs_id INTEGER NOT NULL,
            min_x DOUBLE NOT NULL,
            min_y DOUBLE NOT NULL,
            max_x DOUBLE NOT NULL,
            max_y DOUBLE NOT NULL,
            CONSTRAINT fk_gtms_table FOREIGN KEY (table_name) REFERENCES gpkg_contents(table_name),
            CONSTRAINT fk_gtms_srs FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys(srs_id)
        );

        CREATE TABLE IF NOT EXISTS gpkg_tile_matrix (
            table_name TEXT NOT NULL,
            zoom_level INTEGER NOT NULL,
            matrix_width INTEGER NOT NULL,
            matrix_height INTEGER NOT NULL,
            tile_width INTEGER NOT NULL,
            tile_height INTEGER NOT NULL,
            pixel_x_size DOUBLE NOT NULL,
            pixel_y_size DOUBLE NOT NULL,
            CONSTRAINT pk_ttm PRIMARY KEY (table_name, zoom_level),
            CONSTRAINT fk_ttm_table FOREIGN KEY (table_name) REFERENCES gpkg_contents(table_name)
        );

        CREATE TABLE IF NOT EXISTS gpkg_data_columns (
            table_name TEXT NOT NULL,
            column_name TEXT NOT NULL,
            name TEXT,
            title TEXT,
            description TEXT,
            mime_type TEXT,
            constraint_name TEXT,
            CONSTRAINT pk_data_columns PRIMARY KEY (table_name, column_name),
            CONSTRAINT fk_dc_table FOREIGN KEY (table_name) REFERENCES gpkg_contents(table_name)
        );

        CREATE TABLE IF NOT EXISTS gpkg_data_column_constraints (
            constraint_name TEXT NOT NULL,
            constraint_type TEXT NOT NULL,
            value TEXT,
            min_value DOUBLE,
            min_value_inclusive BOOLEAN,
            max_value DOUBLE,
            max_value_inclusive BOOLEAN,
            description TEXT,
            CONSTRAINT pk_data_col_constr PRIMARY KEY (constraint_name, constraint_type, value)
        );

        CREATE TABLE IF NOT EXISTS gpkgext_relations (
            id TEXT NOT NULL PRIMARY KEY,
            table_name TEXT NOT NULL,
            column_name TEXT NOT NULL,
            related_table_name TEXT NOT NULL,
            related_column_name TEXT NOT NULL,
            relation_name TEXT NOT NULL,
            mapping_table_name TEXT
        );
        """

    /// SQL to drop metadata tables (for cleanup).
    static let dropMetadataSQL = """
        DROP TABLE IF EXISTS gpkg_spatial_ref_sys;
        DROP TABLE IF EXISTS gpkg_contents;
        DROP TABLE IF EXISTS gpkg_geometry_columns;
        DROP TABLE IF EXISTS gpkg_extensions;
        DROP TABLE IF EXISTS gpkg_tile_matrix;
        DROP TABLE IF EXISTS gpkg_tile_matrix_set;
        DROP TABLE IF EXISTS gpkg_data_columns;
        DROP TABLE IF EXISTS gpkg_data_column_constraints;
        DROP TABLE IF EXISTS gpkgext_relations;
        """

    // MARK: - Schema setup

    /// Initialize a GeoPackage database with the mandatory metadata tables.
    static func createMetadata(in db: SQLiteDB) throws {
        // Set application ID and user version for GeoPackage identification
        try db.execute("PRAGMA application_id = \(applicationIdGPKG);")
        try db.execute("PRAGMA user_version = \(userVersion);")
        try db.execute(createMetadataSQL)
        try insertDefaultSRS(db)
    }

    /// Validate that an existing database is a valid GeoPackage.
    static func validateMetadata(in db: SQLiteDB) throws {
        let appId = try db.query("PRAGMA application_id;")
        guard let first = appId.first,
              let raw = first["application_id"] as? Int,
              raw == Int(applicationIdGP10) || raw == Int(applicationIdGPKG)
        else {
            throw GeoPackageError.invalidGeoPackage(detail: "Not a GeoPackage file (invalid application_id)")
        }

        // Verify mandatory tables exist
        let tables = try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN"
            + " ('gpkg_spatial_ref_sys','gpkg_contents','gpkg_geometry_columns');")
        let tableNames = tables.compactMap { $0["name"] as? String }
        for required in ["gpkg_spatial_ref_sys", "gpkg_contents", "gpkg_geometry_columns"] {
            guard tableNames.contains(required) else {
                throw GeoPackageError.invalidGeoPackage(detail: "Missing mandatory table: \(required)")
            }
        }
    }

    // MARK: - Default SRS

    /// Insert the mandatory and built-in Spatial Reference Systems.
    ///
    /// GeoPackage requirement 11 mandates rows for EPSG:4326, `-1`
    /// (undefined Cartesian) and `0` (undefined geographic). Rows already
    /// present are left untouched, so this is safe to call on an existing
    /// package.
    static func insertDefaultSRS(_ db: SQLiteDB) throws {
        let srs: [(srsId: Int, name: String, type: String, org: String, orgId: Int, def: String, desc: String?)] = [
            (4326, "WGS 84 geodetic", "geographic", "EPSG", 4326,
             "GEOGCS[\"WGS 84\",DATUM[\"WGS_1984\",SPHEROID[\"WGS 84\",6378137,298.257223563,AUTHORITY[\"EPSG\",\"7030\"]],AUTHORITY[\"EPSG\",\"6326\"]],PRIMEM[\"Greenwich\",0,AUTHORITY[\"EPSG\",\"8901\"]],UNIT[\"degree\",0.0174532925199433,AUTHORITY[\"EPSG\",\"9122\"]],AUTHORITY[\"EPSG\",\"4326\"]]",
             "WGS 84"),
            (3857, "WGS 84 / Pseudo-Mercator", "projected", "EPSG", 3857,
             "PROJCS[\"WGS 84 / Pseudo-Mercator\",GEOGCS[\"WGS 84\",DATUM[\"WGS_1984\",SPHEROID[\"WGS 84\",6378137,298.257223563,AUTHORITY[\"EPSG\",\"7030\"]],AUTHORITY[\"EPSG\",\"6326\"]],PRIMEM[\"Greenwich\",0,AUTHORITY[\"EPSG\",\"8901\"]],UNIT[\"degree\",0.0174532925199433,AUTHORITY[\"EPSG\",\"9122\"]],AUTHORITY[\"EPSG\",\"4326\"]],PROJECTION[\"Mercator_1SP\"],PARAMETER[\"central_meridian\",0],PARAMETER[\"scale_factor\",1],PARAMETER[\"false_easting\",0],PARAMETER[\"false_northing\",0],UNIT[\"metre\",1,AUTHORITY[\"EPSG\",\"9001\"]],AXIS[\"Easting\",EAST],AXIS[\"Northing\",NORTH],AUTHORITY[\"EPSG\",\"3857\"]]",
             "WGS 84 / Pseudo-Mercator"),
            (4978, "WGS 84 / ECEF", "geocentric", "EPSG", 4978,
             "GEOCCS[\"WGS 84\",DATUM[\"WGS_1984\",SPHEROID[\"WGS 84\",6378137,298.257223563,AUTHORITY[\"EPSG\",\"7030\"]],AUTHORITY[\"EPSG\",\"6326\"]],PRIMEM[\"Greenwich\",0,AUTHORITY[\"EPSG\",\"8901\"]],UNIT[\"metre\",1,AUTHORITY[\"EPSG\",\"9001\"]],AXIS[\"Geocentric X\",OTHER],AXIS[\"Geocentric Y\",OTHER],AXIS[\"Geocentric Z\",OTHER],AUTHORITY[\"EPSG\",\"4978\"]]",
             "WGS 84 / ECEF"),
            (0, "Undefined geographic SRS", "undefined", "NONE", 0,
             "undefined", "undefined geographic coordinate reference system"),
            (-1, "Undefined Cartesian SRS", "undefined", "NONE", -1,
             "undefined", "undefined Cartesian coordinate reference system"),
        ]

        // GeoPackage 1.2 does not define an `srs_type` column. Older
        // versions of this library created one, so keep writing to it only
        // when opening such a legacy package.
        let hasSRSType = try spatialRefSysHasSRSType(in: db)

        for srsRow in srs {
            if hasSRSType {
                try db.execute(
                    """
                    INSERT OR IGNORE INTO gpkg_spatial_ref_sys
                    (srs_id, srs_name, srs_type, organization,
                     organization_coordsys_id, definition, description)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                    """,
                    values: [
                        srsRow.srsId,
                        srsRow.name,
                        srsRow.type,
                        srsRow.org,
                        srsRow.orgId,
                        srsRow.def,
                        srsRow.desc,
                    ])
            }
            else {
                try db.execute(
                    """
                    INSERT OR IGNORE INTO gpkg_spatial_ref_sys
                    (srs_id, srs_name, organization,
                     organization_coordsys_id, definition, description)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """,
                    values: [
                        srsRow.srsId,
                        srsRow.name,
                        srsRow.org,
                        srsRow.orgId,
                        srsRow.def,
                        srsRow.desc,
                    ])
            }
        }
    }

    /// Returns whether a legacy `srs_type` column exists.
    static func spatialRefSysHasSRSType(in db: SQLiteDB) throws -> Bool {
        guard try tableExists("gpkg_spatial_ref_sys", in: db) else {
            return false
        }
        let columns = try db.query(
            "PRAGMA table_info(gpkg_spatial_ref_sys);")
        return columns.contains {
            ($0["name"] as? String)?.caseInsensitiveCompare("srs_type")
                == .orderedSame
        }
    }

    // MARK: - SRS lookup

    /// Map a Projection to the corresponding GeoPackage SRS ID.
    ///
    /// GeoPackage SRS IDs are EPSG codes for EPSG-registered projections.
    /// Coordinates without an SRID use `0` ("undefined geographic"), which is
    /// the GeoPackage-defined representation for an unknown CRS. Previously
    /// they were silently written as EPSG:4326.
    static func srsId(for projection: Projection) -> Int {
        projection.hasSRID ? projection.srid : 0
    }

    /// Ensure a `gpkg_spatial_ref_sys` row exists for the given SRS ID.
    ///
    /// The default SRS rows (4326/3857/4978/0/-1) are pre-inserted by
    /// ``createMetadata(in:)``. Any other projection gets a row with an
    /// `undefined` definition, as allowed by the GeoPackage spec (see
    /// requirement 8 / appendix E.1).
    ///
    /// - Parameter srsId: The SRS ID to ensure, e.g. from ``srsId(for:)``.
    static func ensureSrsRow(_ srsId: Int, in db: SQLiteDB) throws {
        let existing = try db.query(
            "SELECT 1 FROM gpkg_spatial_ref_sys WHERE srs_id = ? LIMIT 1;",
            values: [srsId])
        if !existing.isEmpty {
            return
        }

        if try spatialRefSysHasSRSType(in: db) {
            try db.execute(
                """
                INSERT INTO gpkg_spatial_ref_sys
                (srs_id, srs_name, srs_type, organization,
                 organization_coordsys_id, definition, description)
                VALUES (?, ?, 'undefined', 'EPSG', ?, 'undefined', NULL);
                """,
                values: [srsId, "EPSG:\(srsId)", srsId])
        }
        else {
            try db.execute(
                """
                INSERT INTO gpkg_spatial_ref_sys
                (srs_id, srs_name, organization,
                 organization_coordsys_id, definition, description)
                VALUES (?, ?, 'EPSG', ?, 'undefined', NULL);
                """,
                values: [srsId, "EPSG:\(srsId)", srsId])
        }
    }

    /// Map a GeoPackage SRS ID to the library's Projection.
    ///
    /// `0` and `-1` are the GeoPackage definitions for undefined geographic
    /// and Cartesian systems and map to ``Projection/noSRID``. Unknown
    /// SRIDs also map to ``Projection/noSRID`` instead of pretending the data
    /// is EPSG:4326; this keeps coordinates verbatim and makes the missing
    /// CRS explicit to callers.
    static func projection(for srsId: Int) -> Projection {
        if srsId == 0 || srsId == -1 {
            return .noSRID
        }
        return Projection(srid: srsId) ?? .noSRID
    }

    /// Creates a bounding box using the projection identified by `srsId`.
    ///
    /// GeoPackage metadata stores raw CRS coordinates, so the projection must
    /// be attached explicitly; otherwise the default EPSG:4326 would be
    /// assumed for projected (for example Web Mercator) values.
    static func boundingBox(
        minX: Double,
        minY: Double,
        maxX: Double,
        maxY: Double,
        srsId: Int?
    ) -> BoundingBox {
        let projection = projection(for: srsId ?? 4326)
        return BoundingBox(
            southWest: Coordinate3D(
                x: minX, y: minY, projection: projection),
            northEast: Coordinate3D(
                x: maxX, y: maxY, projection: projection))
    }

    /// Returns whether a bounding box crosses the antimeridian.
    ///
    /// Crossing boxes are represented with a west edge east of the east edge
    /// (`minX > maxX`). An R-tree query compares raw coordinates and cannot
    /// express the wrap-around, so callers fall back to filtering those boxes
    /// in memory.
    static func crossesAntimeridian(_ boundingBox: BoundingBox) -> Bool {
        boundingBox.southWest.longitude > boundingBox.northEast.longitude
    }

    /// Sanitize a SQL identifier (table name, column name) to prevent SQL injection.
    /// Wraps the name in double quotes and escapes embedded quotes.
    static func sanitizeIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// Map a GeoJson geometry type to a GeoPackage geometry type name.
    static func geometryTypeName(for type: GeoJsonType) -> String {
        switch type {
        case .point: return "POINT"
        case .multiPoint: return "MULTIPOINT"
        case .lineString: return "LINESTRING"
        case .multiLineString: return "MULTILINESTRING"
        case .polygon: return "POLYGON"
        case .multiPolygon: return "MULTIPOLYGON"
        case .geometryCollection: return "GEOMETRYCOLLECTION"
        default: return "GEOMETRY"
        }
    }

    /// Reads the `gpkg_contents` table and returns a list of available
    /// tables with their type and metadata.
    ///
    /// - Parameter db: An open SQLite database handle.
    /// - Returns: An array of ``GeoPackageTable`` entries.
    static func readContents(from db: SQLiteDB) throws -> [GeoPackageTable] {
        try db.query(
            "SELECT table_name, data_type, identifier, description,"
            + " min_x, min_y, max_x, max_y, srs_id"
            + " FROM gpkg_contents ORDER BY table_name;"
        ).compactMap { row in
            guard let tableName = row["table_name"] as? String,
                  let dataType = row["data_type"] as? String
            else { return nil }

            let identifier = row["identifier"] as? String
            let description = row["description"] as? String
            let srsId = row["srs_id"] as? Int
            let bounds: BoundingBox?
            if let minX = row["min_x"] as? Double,
               let minY = row["min_y"] as? Double,
               let maxX = row["max_x"] as? Double,
               let maxY = row["max_y"] as? Double
            {
                bounds = GeoPackage.boundingBox(
                    minX: minX,
                    minY: minY,
                    maxX: maxX,
                    maxY: maxY,
                    srsId: srsId)
            }
            else {
                bounds = nil
            }

            return GeoPackageTable(
                tableName: tableName,
                dataType: dataType,
                identifier: identifier,
                description: description,
                srsId: srsId,
                bounds: bounds)
        }
    }

    /// Opens a GeoPackage file and reads the `gpkg_contents` table.
    ///
    /// - Parameter url: The file URL of a GeoPackage database.
    /// - Returns: An array of ``GeoPackageTable`` entries.
    public static func readContents(from url: URL) throws -> [GeoPackageTable] {
        let db = try SQLiteDB(path: url.path, readOnly: true)
        defer { db.close() }
        return try GeoPackage.readContents(from: db)
    }

    // MARK: - Schema helpers

    /// Table names owned by the GeoPackage specification and this library.
    static let reservedTableNames: Set<String> = [
        "gpkg_spatial_ref_sys",
        "gpkg_contents",
        "gpkg_geometry_columns",
        "gpkg_extensions",
        "gpkg_tile_matrix_set",
        "gpkg_tile_matrix",
        "gpkg_data_columns",
        "gpkg_data_column_constraints",
        "gpkgext_relations",
    ]

    /// Validates that a user table name is non-empty and does not collide
    /// with a mandatory GeoPackage metadata table.
    static func validateTableName(_ name: String) throws {
        guard !name.isEmpty else {
            throw GeoPackageError.invalidArgument(detail: "Table name is empty")
        }
        guard !reservedTableNames.contains(name.lowercased()) else {
            throw GeoPackageError.invalidArgument(
                detail: "'\(name)' is a reserved GeoPackage table name")
        }
    }

    /// Ensures that `gpkg_contents` either has no row for `table` or records
    /// the expected data type. Prevents a writer from silently converting a
    /// feature/tile table into an attribute table.
    static func ensureContentsDataType(
        _ expected: String,
        for table: String,
        in db: SQLiteDB
    ) throws {
        let rows = try db.query(
            "SELECT data_type FROM gpkg_contents WHERE table_name = ?;",
            values: [table])
        guard let type = rows.first?["data_type"] as? String else {
            return
        }
        guard type == expected else {
            throw GeoPackageError.invalidArgument(
                detail: """
                    Table '\(table)' is already registered as '\(type)', not \
                    '\(expected)'
                    """)
        }
    }

    /// Returns whether a table or view with the given name exists.
    static func tableExists(_ name: String, in db: SQLiteDB) throws -> Bool {
        let rows = try db.query(
            """
            SELECT 1 FROM sqlite_master
            WHERE type IN ('table', 'view') AND name = ?
            LIMIT 1;
            """,
            values: [name])
        return !rows.isEmpty
    }

    /// Returns whether the mandatory GeoPackage metadata tables are present.
    static func hasMetadataTables(in db: SQLiteDB) throws -> Bool {
        for table in [
            "gpkg_spatial_ref_sys",
            "gpkg_contents",
            "gpkg_geometry_columns",
            "gpkg_extensions",
        ] where try !tableExists(table, in: db) {
            return false
        }
        return true
    }

    // MARK: - Spatial index helpers

    /// Returns the SQL identifier of the rtree virtual table for a given
    /// feature table and geometry column.
    static func rTreeTableName(for table: String, column: String) -> String {
        GeoPackage.sanitizeIdentifier("rtree_\(table)_\(column)")
    }

    /// Checks whether a spatial (rtree) index exists for the given feature
    /// table and geometry column.
    ///
    /// Returns `true` if either `gpkg_extensions` registers a
    /// `gpkg_rtree_index` extension for the table/column pair, or the
    /// rtree virtual table exists in `sqlite_master`.
    static func hasRTreeIndex(
        for table: String,
        column: String,
        in db: SQLiteDB
    ) throws -> Bool {
        // The virtual table is authoritative: an extension row without the
        // backing table would make queries fail. Some real-world packages
        // contain the table without registering the extension, so the table
        // alone is still usable.
        let tableRows = try db.query("""
            SELECT 1 FROM sqlite_master
            WHERE type = 'table' AND name = ?
            LIMIT 1;
            """,
            values: ["rtree_\(table)_\(column)"])
        return !tableRows.isEmpty
    }

}
