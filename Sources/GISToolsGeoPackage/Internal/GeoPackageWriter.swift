import Foundation
import GISTools
import OACSQLite

// MARK: - Writer

enum GeoPackageWriter {

    static func writeFeatures(
        _ fc: FeatureCollection,
        to db: SQLiteDB,
        table: String,
        createSpatialIndex: Bool = false
    ) throws {
        let features = fc.features
        guard !features.isEmpty else {
            throw GeoPackageError.invalidGeoPackage(detail: "Cannot write empty FeatureCollection")
        }

        // Determine geometry type from the first feature
        let firstGeoType = features[0].geometry.type
        let geoTypeName: String
        let hasMixedTypes = features.contains { $0.geometry.type != firstGeoType }
        if hasMixedTypes {
            geoTypeName = "GEOMETRY"
        }
        else {
            geoTypeName = GeoPackage.geometryTypeName(for: firstGeoType)
        }

        let projection = features[0].projection
        let srsId = GeoPackage.srsId(for: projection)
        try GeoPackage.ensureSrsRow(srsId, in: db)

        // Collect all property keys with their inferred types
        let propertySchema = inferPropertySchema(from: features)
        // Infer the SQLite column type for the GeoJSON `id` column from the
        // actual `Feature.id` values. Uniform integer/double ids get a typed
        // column; mixed or string ids fall back to TEXT.
        let idColumnType = inferIdColumnType(from: features)

        // Create the feature table.
        // `fid` is the spec-mandated INTEGER PRIMARY KEY (rowid alias).
        // `id` stores the GeoJSON Feature.id with a type inferred from the data.
        var columnDefs: [(name: String, sqlType: String)] = []
        let geomColumnName = "geom"

        columnDefs.append(("fid", "INTEGER PRIMARY KEY AUTOINCREMENT"))
        columnDefs.append(("id", idColumnType))
        columnDefs.append((geomColumnName, geoTypeName))

        for (key, colType) in propertySchema {
            columnDefs.append((key, colType))
        }

        let createColumnsSQL = columnDefs.map { (name, sqlType) in
            "\(GeoPackage.sanitizeIdentifier(name)) \(sqlType)"
        }
        let quotedTable = GeoPackage.sanitizeIdentifier(table)
        let createSQL = "CREATE TABLE \(quotedTable) (\(createColumnsSQL.joined(separator: ", ")));"
        try db.execute(createSQL)

        // Compute bounding box
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        // Insert features. `fid` is auto-assigned by SQLite, so it is excluded
        // from the INSERT column list and bind values.
        let insertColumnDefs = columnDefs.filter { $0.name != "fid" }
        let colNamesQuoted = insertColumnDefs
            .map { GeoPackage.sanitizeIdentifier($0.name) }
            .joined(separator: ", ")
        let placeholders = insertColumnDefs.map { _ in "?" }.joined(separator: ", ")
        let insertSQL = "INSERT INTO \(quotedTable) (\(colNamesQuoted)) VALUES (\(placeholders));"

        // Capture the rowid assigned to each feature so the rtree spatial
        // index (if created) can reference the exact table rowid rather than a
        // hand-rolled counter that desyncs when features are skipped.
        var insertedRowIds: [Int64] = []
        insertedRowIds.reserveCapacity(features.count)

        for feature in features {
            let geometry = feature.geometry

            guard let wkb = WKBCoder.encode(
                geometry: geometry,
                byteOrder: .littleEndian,
                targetProjection: nil)
            else { continue }

            let envelope = geometry.boundingBox ?? geometry.calculateBoundingBox()
            let headerWkb = WKBHeader.prependHeader(to: wkb, srid: srsId, envelope: envelope)

            if let envelope {
                minX = min(minX, envelope.southWest.longitude)
                minY = min(minY, envelope.southWest.latitude)
                maxX = max(maxX, envelope.northEast.longitude)
                maxY = max(maxY, envelope.northEast.latitude)
            }

            // Bind order must match `insertColumnDefs`: id, geom, properties...
            // `Any?` is used (not `Any`) so that a nil id is bound as SQL NULL
            // rather than the string "nil" — `nil as Any` is a non-nil Any box.
            var values: [Any?] = [idValue(feature.id)]
            values.append(headerWkb as Any?)
            for (name, _) in insertColumnDefs.dropFirst(2) {
                values.append(feature.properties[name])
            }

            try insertRow(db: db, sql: insertSQL, values: values)
            insertedRowIds.append(db.lastInsertRowId())
        }

        // Write metadata
        try writeContentsMetadata(
            db: db,
            table: table,
            srsId: srsId,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            projection: projection)
        try writeGeometryColumnsMetadata(
            db: db,
            table: table,
            geomColumnName: geomColumnName,
            geoTypeName: geoTypeName,
            srsId: srsId)

        // Create spatial index (rtree) if requested
        if createSpatialIndex {
            try createSpatialIndexOnTable(
                table: table,
                geomColumnName: geomColumnName,
                srsId: srsId,
                for: features,
                rowIds: insertedRowIds,
                db: db)
        }
    }

    // MARK: - Spatial index

    private static func createSpatialIndexOnTable(
        table: String,
        geomColumnName: String,
        srsId: Int,
        for features: [Feature],
        rowIds: [Int64],
        db: SQLiteDB
    ) throws {
        let rtreeName = GeoPackage.rTreeTableName(for: table, column: geomColumnName)

        try db.execute("""
            CREATE VIRTUAL TABLE \(rtreeName)
            USING rtree("id", "minx", "maxx", "miny", "maxy");
            """)

        // `features` and `rowIds` are aligned: rowIds[i] is the rowid assigned
        // to features[i] by the preceding INSERT. Only features that were
        // actually inserted have an entry here, so the rtree ids always match
        // the feature-table rowids.
        for (feature, rowId) in zip(features, rowIds) {
            guard let envelope = feature.boundingBox ?? feature.calculateBoundingBox() else { continue }
            let minX = envelope.southWest.longitude
            let minY = envelope.southWest.latitude
            let maxX = envelope.northEast.longitude
            let maxY = envelope.northEast.latitude
            let sql = """
                INSERT INTO \(rtreeName) (id, minx, maxx, miny, maxy)
                VALUES (\(rowId), \(minX), \(maxX), \(minY), \(maxY));
                """
            try db.execute(sql)
        }

        let escapedTable = GeoPackage.sanitizeStringLiteral(table)
        let escapedCol = GeoPackage.sanitizeStringLiteral(geomColumnName)
        try db.execute("""
            INSERT INTO gpkg_extensions
            (table_name, column_name, extension_name, definition, scope)
            VALUES (\(escapedTable), \(escapedCol),
            'gpkg_rtree_index',
            'http://www.geopackage.org/spec120/#extension_rtree',
            'write-only');
            """)
    }

    // MARK: - Metadata

    private static func writeContentsMetadata(
        db: SQLiteDB,
        table: String,
        srsId: Int,
        minX: Double,
        minY: Double,
        maxX: Double,
        maxY: Double,
        projection: Projection
    ) throws {
        let escapedTable = GeoPackage.sanitizeStringLiteral(table)
        let identifier = escapedTable
        try db.execute(
            "INSERT INTO gpkg_contents (table_name, data_type, identifier, srs_id, min_x, min_y, max_x, max_y) VALUES (\(escapedTable), 'features', \(identifier), \(srsId), \(minX), \(minY), \(maxX), \(maxY));")
    }

    private static func writeGeometryColumnsMetadata(
        db: SQLiteDB,
        table: String,
        geomColumnName: String,
        geoTypeName: String,
        srsId: Int
    ) throws {
        let escapedTable = GeoPackage.sanitizeStringLiteral(table)
        try db.execute(
            "INSERT INTO gpkg_geometry_columns (table_name, column_name, geometry_type_name, srs_id, z, m) VALUES (\(escapedTable), 'geom', '\(geoTypeName)', \(srsId), 0, 0);")
    }

    // MARK: - Schema inference

    private static func inferPropertySchema(from features: [Feature]) -> [(String, String)] {
        var allKeys = Set<String>()
        for f in features {
            for key in f.properties.keys {
                allKeys.insert(key)
            }
        }

        var result: [(String, String)] = []
        for key in allKeys.sorted() {
            let sampleValue = features.compactMap { $0.properties[key] }.first
            let colType = sqliteType(for: sampleValue)
            result.append((key, colType))
        }
        return result
    }

    /// Infers the SQLite column type for the GeoJSON `Feature.id` from the
    /// actual identifier values in the collection.
    ///
    /// - Uniform integer ids (`.int` or `.uint`) produce an `INTEGER` column.
    /// - Uniform double ids produce a `REAL` column.
    /// - Uniform string ids produce a `TEXT` column.
    /// - Mixed types or no ids produce `TEXT` (the safe fallback that can hold
    ///   any value).
    private static func inferIdColumnType(from features: [Feature]) -> String {
        var seenInt = false
        var seenDouble = false
        var seenString = false

        for feature in features {
            switch feature.id {
            case .int, .uint:
                seenInt = true
            case .double:
                seenDouble = true
            case .string:
                seenString = true
            case nil:
                continue
            }
        }

        let activeKinds = [seenInt, seenDouble, seenString].filter { $0 }.count

        if activeKinds == 0 || activeKinds > 1 {
            return "TEXT"
        }
        if seenInt {
            return "INTEGER"
        }
        if seenDouble {
            return "REAL"
        }
        return "TEXT"
    }

    /// Converts a `Feature.Identifier` to the bind value used when writing the
    /// `id` column, matching the inferred column type.
    ///
    /// - Returns: `nil` for a missing identifier (stored as SQL NULL), an
    ///   `Int`/`Double`/`String` for the typed cases. UInt values that fit in
    ///   `Int` are bound as `Int`; the column type is `INTEGER`.
    private static func idValue(_ id: Feature.Identifier?) -> Any? {
        guard let id else { return nil }
        switch id {
        case .int(let value):
            return value
        case .uint(let value):
            // SQLite INTEGER is 64-bit signed; values that fit are bound as
            // Int, otherwise fall back to a string representation.
            if let int = Int(exactly: value) {
                return int
            }
            return String(value)
        case .double(let value):
            return value
        case .string(let value):
            return value
        }
    }

    private static func sqliteType(for value: Any?) -> String {
        guard let value else { return "TEXT" }
        switch value {
        case is Bool: return "BOOLEAN"
        case is Int, is Int64: return "INTEGER"
        case is Double, is Float: return "REAL"
        case is String: return "TEXT"
        default: return "TEXT"
        }
    }

    // MARK: - Row insertion

    private static func insertRow(
        db: SQLiteDB,
        sql: String,
        values: [Any?]
    ) throws {
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }

        for (i, value) in values.enumerated() {
            try SQLiteDB.bind(stmt, index: Int32(i + 1), value: value)
        }

        let stepRC = sqlite3_step(stmt)
        guard stepRC == 101 else {
            throw GeoPackageError.sqliteError(detail: "Failed to insert row: \(db.lastErrorMessage())")
        }
    }

}
