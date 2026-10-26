import Foundation
import GISTools

/// Resolved metadata for a GeoPackage feature table.
///
/// Shared by the synchronous reader and ``FeatureStream`` so both paths use
/// exactly the same column detection, SRS handling and row decoding.
struct FeatureTableMetadata {

    /// The table name as stored in `gpkg_geometry_columns`.
    let tableName: String

    /// The quoted table identifier, safe for interpolation into SQL.
    let quotedTable: String

    /// The geometry column name.
    let geomColumnName: String

    /// The SRS ID from `gpkg_geometry_columns`.
    let srsId: Int

    /// The projection corresponding to ``srsId``.
    let projection: Projection

    /// The geometry type name from `gpkg_geometry_columns`.
    let geometryTypeName: String

    /// The `z` constraint from `gpkg_geometry_columns` (0, 1 or 2).
    let z: Int

    /// The `m` constraint from `gpkg_geometry_columns` (0, 1 or 2).
    let m: Int

    /// All column names in the feature table.
    let columnNames: [String]

    /// The column that carries the GeoJSON ``Feature/id``, if any.
    let idColumnName: String?

    /// The single-column `INTEGER PRIMARY KEY` column, if any.
    let pkColumnName: String?

    /// Column names that are stored as feature properties.
    let propertyColumnNames: [String]

    /// Alias used for the SQLite `rowid` in result rows.
    let rowIdAlias: String

    /// Loads the metadata for a feature table.
    ///
    /// - Throws: ``GeoPackageError/tableNotFound(name:)`` when the table is
    ///   not registered in `gpkg_geometry_columns`, and
    ///   ``GeoPackageError/mixedGeometryTypes(detail:)`` when it has more than
    ///   one geometry column.
    static func load(
        table: String,
        in db: SQLiteDB,
    ) throws -> FeatureTableMetadata {
        let geomColumns = try db.query(
            """
            SELECT column_name, geometry_type_name, srs_id, z, m
            FROM gpkg_geometry_columns
            WHERE table_name = ?;
            """,
            values: [table])

        guard let geomMeta = geomColumns.first else {
            throw GeoPackageError.tableNotFound(name: table)
        }
        guard geomColumns.count == 1 else {
            throw GeoPackageError.mixedGeometryTypes(
                detail: "Table '\(table)' has multiple geometry columns")
        }

        let geomColumnName = geomMeta["column_name"] as? String ?? "geom"
        let srsId = intValue(geomMeta["srs_id"]) ?? 4326
        let geometryTypeName = geomMeta["geometry_type_name"] as? String
            ?? "GEOMETRY"
        let z = intValue(geomMeta["z"]) ?? 0
        let m = intValue(geomMeta["m"]) ?? 0
        let projection = GeoPackage.projection(for: srsId)

        let quotedTable = GeoPackage.sanitizeIdentifier(table)
        let tableInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        let columnNames: [String] = tableInfo.compactMap {
            $0["name"] as? String
        }

        guard !columnNames.isEmpty else {
            throw GeoPackageError.tableNotFound(name: table)
        }

        // SQL identifiers are case-insensitive in SQLite. Match the GeoJSON
        // id/fid conventions case-insensitively so packages produced by other
        // tools (for example `ID` or `FID`) are read correctly.
        let idColumnName: String? = {
            if let id = columnNames.first(where: {
                $0.caseInsensitiveCompare("id") == .orderedSame
            }) {
                return id
            }
            return columnNames.first {
                $0.caseInsensitiveCompare("fid") == .orderedSame
            }
        }()

        let pkColumnName: String? = tableInfo.first { column in
            let isPrimaryKey = (intValue(column["pk"]) ?? 0) > 0
            let type = (column["type"] as? String ?? "").lowercased()
            return isPrimaryKey && type.contains("integer")
        }
        .flatMap { $0["name"] as? String }

        let excluded = Set(
            [geomColumnName, idColumnName, pkColumnName]
                .compactMap { $0?.lowercased() })
        let propertyColumnNames = columnNames.filter {
            !excluded.contains($0.lowercased())
        }

        // `SELECT rowid AS __gpkg_rowid, *` gives the rowid a stable name even
        // when an INTEGER PRIMARY KEY column would otherwise rename it to the
        // PK column name. Pick a non-colliding alias if a user column happens
        // to use the default name.
        var rowIdAlias = "__gpkg_rowid"
        while columnNames.contains(where: {
            $0.caseInsensitiveCompare(rowIdAlias) == .orderedSame
        }) {
            rowIdAlias += "_"
        }

        return FeatureTableMetadata(
            tableName: table,
            quotedTable: quotedTable,
            geomColumnName: geomColumnName,
            srsId: srsId,
            projection: projection,
            geometryTypeName: geometryTypeName,
            z: z,
            m: m,
            columnNames: columnNames,
            idColumnName: idColumnName,
            pkColumnName: pkColumnName,
            propertyColumnNames: propertyColumnNames,
            rowIdAlias: rowIdAlias)
    }

    /// Returns the metadata if the table is a registered feature table,
    /// otherwise `nil`.
    static func loadIfExists(
        table: String,
        in db: SQLiteDB,
    ) throws -> FeatureTableMetadata? {
        let tableRows = try db.query(
            """
            SELECT 1 FROM sqlite_master
            WHERE type = 'table' AND name = ?
            LIMIT 1;
            """,
            values: [table])
        guard !tableRows.isEmpty else { return nil }

        return try load(table: table, in: db)
    }

    // MARK: - Query building

    /// Builds the SELECT statement used by both the reader and the stream.
    ///
    /// - Parameters:
    ///   - boundingBox: An optional bounding box in any projection. It is
    ///     projected into the table's CRS before being compared with the
    ///     R-tree, whose bounds are stored in CRS units.
    ///   - useRTree: Whether a spatial index join should be used.
    ///   - limit: An optional row limit.
    ///   - offset: A row offset.
    /// - Returns: The SQL text and its bind values.
    func selectSQL(
        boundingBox: BoundingBox?,
        useRTree: Bool,
        limit: Int?,
        offset: Int,
    ) -> (sql: String, values: [Any?]) {
        // Select the table's columns explicitly. `SELECT t.*` in a JOIN also
        // returns the R-tree columns (including a second `id`), which would
        // overwrite the feature table's `id` value in the row dictionary.
        let selectedColumns = columnNames.lazy
            .map {
                "\(quotedTable).\(GeoPackage.sanitizeIdentifier($0))"
            }
            .joined(separator: ", ")

        var sql = """
        SELECT \(quotedTable).rowid AS \(GeoPackage.sanitizeIdentifier(rowIdAlias)), \(selectedColumns)
        FROM \(quotedTable)
        """
        var values: [Any?] = []

        if let boundingBox, useRTree {
            let queryBox = boundingBox.projected(to: projection)
            let rtreeName = GeoPackage.rTreeTableName(
                for: tableName,
                column: geomColumnName)

            sql += """
             INNER JOIN \(rtreeName)
             ON \(quotedTable).rowid = \(rtreeName).id
             WHERE \(rtreeName).minx <= ?
               AND \(rtreeName).maxx >= ?
               AND \(rtreeName).miny <= ?
               AND \(rtreeName).maxy >= ?
            """
            values.append(queryBox.northEast.longitude)
            values.append(queryBox.southWest.longitude)
            values.append(queryBox.northEast.latitude)
            values.append(queryBox.southWest.latitude)
        }

        sql += " ORDER BY \(quotedTable).rowid"

        if let limit {
            sql += " LIMIT ? OFFSET ?;"
            values.append(limit)
            values.append(offset)
        }
        else if offset > 0 {
            sql += " LIMIT -1 OFFSET ?;"
            values.append(offset)
        }
        else {
            sql += ";"
        }

        return (sql, values)
    }

    // MARK: - Row decoding

    /// Decodes one SQLite row into a ``Feature``.
    ///
    /// Rows with a `NULL` geometry produce an unlocated feature, which is
    /// valid GeoJSON and valid in a GeoPackage geometry column. Malformed
    /// geometry blobs throw instead of being silently dropped.
    func feature(from row: [String: Sendable]) throws -> Feature {
        let properties = decodedProperties(from: row)
        let featureId = decodedId(from: row)
        let rowId = intValue(row[rowIdAlias])

        var feature: Feature
        if let blob = row[geomColumnName] as? Data {
            let header = try WKBHeader.parse(blob)
            let sourceProjection = Projection(srid: header.srid) ?? .noSRID
            let geometry = try WKBCoder.decode(
                wkb: header.wkbData,
                sourceProjection: sourceProjection,
                targetProjection: projection)
            feature = Feature(
                geometry,
                id: featureId,
                properties: properties)
        }
        else {
            feature = Feature(
                id: featureId,
                properties: properties)
        }

        feature.gpkgTableName = tableName
        feature.gpkgRowId = rowId
        return feature
    }

    private func decodedId(from row: [String: Sendable]) -> Feature.Identifier? {
        guard let idColumnName, let raw = row[idColumnName] else {
            return nil
        }

        switch raw {
        case let int as Int:
            return .int(int)
        case let int64 as Int64:
            return Int(exactly: int64).map { .int($0) }
        case let double as Double:
            return .double(double)
        case let string as String:
            return .string(string)
        default:
            return .string(String(describing: raw))
        }
    }

    private func decodedProperties(
        from row: [String: Sendable],
    ) -> [String: Sendable] {
        var properties: [String: Sendable] = [:]
        properties.reserveCapacity(propertyColumnNames.count)

        for column in propertyColumnNames {
            guard let value = row[column] else { continue }

            if let data = value as? Data {
                properties[column] = data.base64EncodedString()
            }
            else {
                properties[column] = value
            }
        }
        return properties
    }

    // MARK: - Helpers

    private static func intValue(_ value: (any Sendable)?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let int64 as Int64:
            Int(exactly: int64)
        case let double as Double:
            Int(exactly: double)
        default:
            nil
        }
    }

    func intValue(_ value: (any Sendable)?) -> Int? {
        Self.intValue(value)
    }

}
