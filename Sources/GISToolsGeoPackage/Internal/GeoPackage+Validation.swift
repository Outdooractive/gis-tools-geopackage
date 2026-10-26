import Foundation
import GISTools

extension GeoPackage {

    /// Validates a `.gpkg` file against the OGC GeoPackage 1.2 specification.
    ///
    /// - Parameter url: The file URL of a GeoPackage database.
    /// - Returns: A ``GeoPackageValidation`` result listing errors and warnings.
    public static func validate(url: URL) throws -> GeoPackageValidation {
        let db = try SQLiteDB(path: url.path, readOnly: true)
        defer { db.close() }
        return try validate(in: db)
    }

    static func validate(in db: SQLiteDB) throws -> GeoPackageValidation {
        var errors: [GeoPackageValidationIssue] = []
        var warnings: [GeoPackageValidationIssue] = []

        try validateApplicationId(db, errors: &errors)
        try validateUserVersion(db, errors: &errors)

        let allTables = try collectTableNames(db)
        validateCoreTables(allTables, errors: &errors, warnings: &warnings)
        try validateSrsTable(db, allTables: allTables, errors: &errors, warnings: &warnings)

        // Reading gpkg_contents is only safe when its required columns exist.
        // Malformed schemas are reported as structural errors instead of
        // leaking an SQLite error.
        let contentsReadable = try validateRequiredColumns(
            "gpkg_contents",
            columns: [
                "table_name", "data_type", "identifier", "description",
                "last_change", "min_x", "min_y", "max_x", "max_y", "srs_id",
            ],
            in: db,
            errors: &errors)
        let contentsRows = contentsReadable
            ? try readContentsRows(db, allTables: allTables)
            : []
        try validateContentsTable(
            db,
            contentsRows: contentsRows,
            allTables: allTables,
            errors: &errors,
            warnings: &warnings)

        let geometryColumnsReadable = try validateRequiredColumns(
            "gpkg_geometry_columns",
            columns: [
                "table_name", "column_name", "geometry_type_name",
                "srs_id", "z", "m",
            ],
            in: db,
            errors: &errors)
        if geometryColumnsReadable {
            try validateGeometryColumns(
                db,
                contentsRows: contentsRows,
                errors: &errors,
                warnings: &warnings)
        }

        let tileTables = contentsRows.filter { $0.dataType == "tiles" }
        if !tileTables.isEmpty {
            try validateTileMetadata(db, tileTables: tileTables, allTables: allTables, errors: &errors, warnings: &warnings)
        }

        if allTables.contains("gpkg_extensions") {
            try validateExtensions(db, errors: &errors, warnings: &warnings)
        }

        return GeoPackageValidation(errors: errors, warnings: warnings)
    }

    // MARK: - Private helpers

    private static func collectTableNames(_ db: SQLiteDB) throws -> Set<String> {
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type='table';")
        return Set(rows.compactMap { $0["name"] as? String })
    }

    /// Verifies that a table exists and contains all required columns.
    ///
    /// - Returns: `true` when the table exists and every required column is
    ///   present, `false` otherwise.
    private static func validateRequiredColumns(
        _ table: String,
        columns: [String],
        in db: SQLiteDB,
        errors: inout [GeoPackageValidationIssue]
    ) throws -> Bool {
        guard try GeoPackage.tableExists(table, in: db) else {
            return false
        }

        let info = try db.query(
            "PRAGMA table_info(\(GeoPackage.sanitizeIdentifier(table)));")
        let existing = Set(info.compactMap {
            ($0["name"] as? String)?.lowercased()
        })

        var valid = true
        for column in columns where !existing.contains(column.lowercased()) {
            errors.append(.missingRequiredColumn(table, column))
            valid = false
        }
        return valid
    }

    /// Whether `gpkg_spatial_ref_sys.srs_id` can be queried safely.
    ///
    /// Structural errors in the SRS table are reported once by
    /// ``validateSrsTable(_:allTables:errors:warnings:)``; reference checks
    /// are skipped so validation returns diagnostics instead of an SQLite
    /// error.
    private static func srsTableIsReadable(_ db: SQLiteDB) throws -> Bool {
        guard try GeoPackage.tableExists("gpkg_spatial_ref_sys", in: db) else {
            return false
        }
        let info = try db.query("PRAGMA table_info(gpkg_spatial_ref_sys);")
        return info.contains {
            ($0["name"] as? String)?.caseInsensitiveCompare("srs_id")
                == .orderedSame
        }
    }

    private static func readContentsRows(_ db: SQLiteDB, allTables: Set<String>) throws -> [ContentsRow] {
        guard allTables.contains("gpkg_contents") else { return [] }
        let rows = try db.query(
            "SELECT table_name, data_type, identifier, srs_id FROM gpkg_contents;")
        return rows.compactMap { row in
            guard let name = row["table_name"] as? String,
                  let type = row["data_type"] as? String else { return nil }
            return ContentsRow(
                tableName: name,
                dataType: type,
                identifier: row["identifier"] as? String,
                srsId: row["srs_id"] as? Int)
        }
    }

    private struct ContentsRow: Sendable {
        let tableName: String
        let dataType: String
        let identifier: String?
        let srsId: Int?
    }

    // MARK: - Checks

    private static func validateApplicationId(_ db: SQLiteDB, errors: inout [GeoPackageValidationIssue]) throws {
        let appId = try db.query("PRAGMA application_id;")
        guard let first = appId.first,
              let raw = first["application_id"] as? Int,
              raw == Int(GeoPackage.applicationIdGP10)
                || raw == Int(GeoPackage.applicationIdGPKG)
        else {
            errors.append(.invalidApplicationId)
            return
        }
    }

    private static func validateUserVersion(_ db: SQLiteDB, errors: inout [GeoPackageValidationIssue]) throws {
        let uv = try db.query("PRAGMA user_version;")
        guard let first = uv.first,
              let raw = first["user_version"] as? Int,
              raw >= GeoPackage.userVersion
        else {
            errors.append(.invalidUserVersion)
            return
        }
    }

    private static func validateCoreTables(
        _ allTables: Set<String>,
        errors: inout [GeoPackageValidationIssue],
        warnings: inout [GeoPackageValidationIssue]
    ) {
        for name in [
            "gpkg_spatial_ref_sys",
            "gpkg_contents",
            "gpkg_geometry_columns",
        ] where !allTables.contains(name) {
            errors.append(.missingMandatoryTable(name))
        }

        if !allTables.contains("gpkg_extensions") {
            warnings.append(.missingRecommendedTable("gpkg_extensions"))
        }
    }

    private static func validateSrsTable(
        _ db: SQLiteDB,
        allTables: Set<String>,
        errors: inout [GeoPackageValidationIssue],
        warnings: inout [GeoPackageValidationIssue]
    ) throws {
        guard allTables.contains("gpkg_spatial_ref_sys") else { return }

        let readable = try validateRequiredColumns(
            "gpkg_spatial_ref_sys",
            columns: [
                "srs_id", "srs_name", "organization",
                "organization_coordsys_id", "definition",
            ],
            in: db,
            errors: &errors)
        guard readable else { return }

        let count = try db.query("SELECT count(*) as cnt FROM gpkg_spatial_ref_sys;")
        if let first = count.first, (first["cnt"] as? Int ?? 0) == 0 {
            warnings.append(.emptySrsTable)
            return
        }

        // Requirement 11 mandates these three rows. Missing rows are a
        // warning rather than an error so older packages that predate the
        // requirement can still be read and reported on.
        for srsId in [4326, 0, -1] {
            let rows = try db.query(
                "SELECT 1 FROM gpkg_spatial_ref_sys WHERE srs_id = ? LIMIT 1;",
                values: [srsId])
            if rows.isEmpty {
                warnings.append(.missingSrsEntry(srsId))
            }
        }
    }

    private static func validateContentsTable(
        _ db: SQLiteDB,
        contentsRows: [ContentsRow],
        allTables: Set<String>,
        errors: inout [GeoPackageValidationIssue],
        warnings: inout [GeoPackageValidationIssue]
    ) throws {
        guard allTables.contains("gpkg_contents") else { return }

        if contentsRows.isEmpty {
            warnings.append(.emptyContentsTable)
            return
        }

        let validDataTypes: Set<String> = [
            "features", "tiles", "2d-gridded-coverage", "attributes",
        ]

        for row in contentsRows {
            if !validDataTypes.contains(row.dataType) {
                warnings.append(.unknownDataType(row.tableName, row.dataType))
            }
            if !allTables.contains(row.tableName) {
                errors.append(.missingReferencedTable(row.tableName))
            }
            if let srsId = row.srsId,
               try srsTableIsReadable(db)
            {
                let srsCheck = try db.query(
                    "SELECT 1 FROM gpkg_spatial_ref_sys WHERE srs_id = ? LIMIT 1;",
                    values: [srsId])
                if srsCheck.isEmpty {
                    errors.append(.invalidSrsReference(row.tableName, srsId))
                }
            }
        }
    }

    private static func validateGeometryColumns(
        _ db: SQLiteDB,
        contentsRows: [ContentsRow],
        errors: inout [GeoPackageValidationIssue],
        warnings: inout [GeoPackageValidationIssue]
    ) throws {
        let geomCols = try db.query("SELECT * FROM gpkg_geometry_columns;")

        let validGeoTypes: Set<String> = [
            "GEOMETRY", "POINT", "LINESTRING", "POLYGON",
            "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON",
            "GEOMETRYCOLLECTION",
        ]

        for col in geomCols {
            guard let table = col["table_name"] as? String,
                  let geoType = col["geometry_type_name"] as? String,
                  let srsId = col["srs_id"] as? Int,
                  let z = col["z"] as? Int,
                  let m = col["m"] as? Int
            else {
                errors.append(.invalidStructure("gpkg_geometry_columns"))
                continue
            }

            if !validGeoTypes.contains(geoType) {
                warnings.append(.invalidGeometryType(table, geoType))
            }
            if ![0, 1, 2].contains(z) {
                warnings.append(.invalidZValue(table, z))
            }
            if ![0, 1, 2].contains(m) {
                warnings.append(.invalidMValue(table, m))
            }

            if try srsTableIsReadable(db) {
                let srsCheck = try db.query(
                    "SELECT 1 FROM gpkg_spatial_ref_sys WHERE srs_id = ? LIMIT 1;",
                    values: [srsId])
                if srsCheck.isEmpty {
                    errors.append(.invalidSrsReference(
                        "gpkg_geometry_columns/\(table)", srsId))
                }
            }

            if !contentsRows.contains(where: {
                $0.tableName == table && $0.dataType == "features"
            }) {
                errors.append(.invalidStructure(
                    "gpkg_geometry_columns/\(table) not in gpkg_contents"))
            }

            let columnName = col["column_name"] as? String ?? ""
            let tableInfo = try db.query(
                "PRAGMA table_info(\(GeoPackage.sanitizeIdentifier(table)));")
            let tableColumns = Set(tableInfo.compactMap {
                ($0["name"] as? String)?.lowercased()
            })
            if !tableColumns.contains(columnName.lowercased()) {
                errors.append(.invalidStructure(
                    "gpkg_geometry_columns/\(table).\(columnName) does not exist"))
            }
        }

        let featureTables = contentsRows.filter { $0.dataType == "features" }
        if !featureTables.isEmpty, geomCols.isEmpty {
            errors.append(.missingGeometryColumnsForFeatures)
        }
    }

    private static func validateTileMetadata(
        _ db: SQLiteDB,
        tileTables: [ContentsRow],
        allTables: Set<String>,
        errors: inout [GeoPackageValidationIssue],
        warnings: inout [GeoPackageValidationIssue]
    ) throws {
        if !allTables.contains("gpkg_tile_matrix_set") {
            errors.append(.missingTileMatrixSet)
        }
        if !allTables.contains("gpkg_tile_matrix") {
            errors.append(.missingTileMatrix)
        }

        guard try validateRequiredColumns(
            "gpkg_tile_matrix_set",
            columns: ["table_name", "srs_id", "min_x", "min_y", "max_x", "max_y"],
            in: db,
            errors: &errors)
        else { return }
        guard try validateRequiredColumns(
            "gpkg_tile_matrix",
            columns: [
                "table_name", "zoom_level", "matrix_width", "matrix_height",
                "tile_width", "tile_height", "pixel_x_size", "pixel_y_size",
            ],
            in: db,
            errors: &errors)
        else { return }

        let tmsRows = try db.query("SELECT table_name, srs_id FROM gpkg_tile_matrix_set;")
        let tmsTables = Set(tmsRows.compactMap { $0["table_name"] as? String })

        for row in tmsRows {
            guard let name = row["table_name"] as? String,
                  let srsId = row["srs_id"] as? Int
            else { continue }
            if try srsTableIsReadable(db) {
                let srsCheck = try db.query(
                    "SELECT 1 FROM gpkg_spatial_ref_sys WHERE srs_id = ? LIMIT 1;",
                    values: [srsId])
                if srsCheck.isEmpty {
                    errors.append(.invalidSrsReference(
                        "tile_matrix_set/\(name)", srsId))
                }
            }
        }

        for tileTable in tileTables {
            if !tmsTables.contains(tileTable.tableName) {
                errors.append(.missingTileMatrixEntry(tileTable.tableName))
            }
            if let srsId = tileTable.srsId,
               try srsTableIsReadable(db)
            {
                let srsCheck = try db.query(
                    "SELECT 1 FROM gpkg_spatial_ref_sys WHERE srs_id = ? LIMIT 1;",
                    values: [srsId])
                if srsCheck.isEmpty {
                    errors.append(.invalidSrsReference(
                        "tile/\(tileTable.tableName)", srsId))
                }
            }

            // Every tile table needs at least one gpkg_tile_matrix row.
            let matrices = try db.query(
                "SELECT 1 FROM gpkg_tile_matrix WHERE table_name = ? LIMIT 1;",
                values: [tileTable.tableName])
            if matrices.isEmpty {
                warnings.append(.invalidStructure(
                    "gpkg_tile_matrix has no rows for '\(tileTable.tableName)'"))
            }
        }
    }

    private static func validateExtensions(
        _ db: SQLiteDB,
        errors: inout [GeoPackageValidationIssue],
        warnings: inout [GeoPackageValidationIssue]
    ) throws {
        guard try validateRequiredColumns(
            "gpkg_extensions",
            columns: ["extension_name", "scope"],
            in: db,
            errors: &errors)
        else { return }

        let validScopes: Set<String> = ["read-write", "write-only"]
        let rows = try db.query("SELECT extension_name, scope FROM gpkg_extensions;")

        for row in rows {
            guard let name = row["extension_name"] as? String,
                  let scope = row["scope"] as? String
            else {
                warnings.append(.invalidStructure("gpkg_extensions row"))
                continue
            }
            if !validScopes.contains(scope) {
                warnings.append(.invalidExtensionScope(name, scope))
            }
        }
    }

}
