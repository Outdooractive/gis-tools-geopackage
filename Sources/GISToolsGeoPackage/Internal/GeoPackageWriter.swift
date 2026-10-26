import Foundation
import GISTools

// MARK: - Writer

/// Writes feature tables into a GeoPackage.
///
/// The writer is responsible for:
/// - creating the feature table and its `fid` / `id` / geometry columns,
/// - projecting every geometry into the table CRS,
/// - writing the GeoPackage geometry header (SRS ID and envelope),
/// - maintaining `gpkg_contents`, `gpkg_geometry_columns` and the R-tree,
/// - appending to existing feature tables, including schema evolution for
///   newly introduced properties.
enum GeoPackageWriter {

    /// The geometry column name used for tables created by this library.
    static let geometryColumnName = "geom"

    /// Writes features to a table.
    ///
    /// If the table does not exist it is created. If it already exists the
    /// features are appended; missing property columns are added with
    /// `ALTER TABLE` and the spatial index is kept in sync.
    ///
    /// - Parameters:
    ///   - fc: The feature collection to write. Must not be empty.
    ///   - db: An open database handle.
    ///   - table: The destination table name.
    ///   - createSpatialIndex: When `true`, creates an R-tree index if the
    ///     table does not have one yet. Existing indexes are always maintained.
    static func writeFeatures(
        _ fc: FeatureCollection,
        to db: SQLiteDB,
        table: String,
        createSpatialIndex: Bool = false
    ) throws {
        let features = fc.features
        guard !features.isEmpty else {
            throw GeoPackageError.invalidGeoPackage(
                detail: "Cannot write empty FeatureCollection")
        }
        try GeoPackage.validateTableName(table)

        let propertyKeys = try validatedPropertyKeys(from: features)
        let featureProjection = features.lazy.compactMap {
            $0.geometry?.projection
        }.first ?? .noSRID
        let featureSrsId = GeoPackage.srsId(for: featureProjection)

        try db.withTransaction {
            if try !GeoPackage.hasMetadataTables(in: db) {
                try GeoPackage.createMetadata(in: db)
            }

            if let existing = try FeatureTableMetadata.loadIfExists(
                table: table, in: db)
            {
                try GeoPackage.ensureContentsDataType(
                    "features", for: table, in: db)
                // The table CRS is authoritative. Append data from any
                // projection by projecting it into the table CRS, matching
                // the mixed-projection handling used for new tables.
                try GeoPackage.ensureSrsRow(existing.srsId, in: db)
                try appendFeatures(
                    features,
                    propertyKeys: propertyKeys,
                    metadata: existing,
                    createSpatialIndex: createSpatialIndex,
                    db: db)
            }
            else {
                try GeoPackage.ensureSrsRow(featureSrsId, in: db)
                try createFeatures(
                    features,
                    propertyKeys: propertyKeys,
                    projection: featureProjection,
                    srsId: featureSrsId,
                    table: table,
                    createSpatialIndex: createSpatialIndex,
                    db: db)
            }
        }
    }

    // MARK: - New table

    private static func createFeatures(
        _ features: [Feature],
        propertyKeys: [String],
        projection: Projection,
        srsId: Int,
        table: String,
        createSpatialIndex: Bool,
        db: SQLiteDB
    ) throws {
        let geometryType = geometryTypeName(for: features)
        let idColumnType = inferIdColumnType(from: features)
        let propertySchema = propertyKeys.map { key in
            (name: key, type: inferredColumnType(for: key, in: features))
        }

        var columnDefs: [(name: String, sqlType: String)] = [
            ("fid", "INTEGER PRIMARY KEY AUTOINCREMENT"),
            ("id", idColumnType),
            (geometryColumnName, geometryType),
        ]
        columnDefs.append(contentsOf: propertySchema.map {
            (name: $0.name, sqlType: $0.type)
        })

        let quotedTable = GeoPackage.sanitizeIdentifier(table)
        let columnsSQL = columnDefs.map {
            "\(GeoPackage.sanitizeIdentifier($0.name)) \($0.sqlType)"
        }.joined(separator: ", ")

        try db.execute(
            "CREATE TABLE \(quotedTable) (\(columnsSQL));")

        let insertColumns = ["id", geometryColumnName] + propertyKeys
        let insertSQL = insertSQL(
            table: quotedTable,
            columns: insertColumns)

        var bounds: BoundingBox?
        var indexEntries: [(rowId: Int64, envelope: BoundingBox)] = []
        indexEntries.reserveCapacity(features.count)

        for feature in features {
            let prepared = try prepareRow(
                feature,
                projection: projection,
                srsId: srsId,
                propertyKeys: propertyKeys)
            try db.execute(insertSQL, values: prepared.values)

            let rowId = db.lastInsertRowId()
            bounds = union(bounds, prepared.envelope)
            if let envelope = prepared.envelope {
                indexEntries.append((rowId, envelope))
            }
        }

        try writeContentsMetadata(
            db: db,
            table: table,
            srsId: srsId,
            bounds: bounds)
        let dimensions = coordinateDimensions(of: features)
        try writeGeometryColumnsMetadata(
            db: db,
            table: table,
            geomColumnName: geometryColumnName,
            geometryTypeName: geometryType,
            srsId: srsId,
            z: dimensions.z,
            m: dimensions.m)

        if createSpatialIndex {
            try createRTree(
                table: table,
                geomColumnName: geometryColumnName,
                entries: indexEntries,
                db: db)
        }
    }

    // MARK: - Append

    private static func appendFeatures(
        _ features: [Feature],
        propertyKeys: [String],
        metadata: FeatureTableMetadata,
        createSpatialIndex: Bool,
        db: SQLiteDB
    ) throws {
        let projection = metadata.projection
        let srsId = metadata.srsId

        try validateGeometryTypes(features, against: metadata)

        let quotedTable = metadata.quotedTable
        let existingColumns = metadata.columnNames

        func existingColumn(for key: String) -> String? {
            existingColumns.first {
                $0.caseInsensitiveCompare(key) == .orderedSame
            }
        }

        // Add missing property columns.
        var propertyColumnsByKey: [String: String] = [:]
        for key in propertyKeys {
            if let column = existingColumn(for: key) {
                propertyColumnsByKey[key] = column
                continue
            }

            let type = inferredColumnType(for: key, in: features)
            try db.execute(
                """
                ALTER TABLE \(quotedTable)
                ADD COLUMN \(GeoPackage.sanitizeIdentifier(key)) \(type);
                """)
            propertyColumnsByKey[key] = key
        }

        // Only add an explicit `id` column when identifiers need to be
        // stored. Tables that use `fid` as their only identifier keep their
        // current read-back behaviour when no new identifiers are present.
        let explicitIdColumn = existingColumn(for: "id")
        let hasFeatureIds = features.contains { $0.id != nil }
        let idColumn: String?
        if let explicitIdColumn {
            idColumn = explicitIdColumn
        }
        else if hasFeatureIds {
            let type = inferIdColumnType(from: features)
            try db.execute(
                """
                ALTER TABLE \(quotedTable)
                ADD COLUMN "id" \(type);
                """)
            idColumn = "id"
        }
        else {
            idColumn = nil
        }

        var insertColumns: [String] = []
        if let idColumn {
            insertColumns.append(idColumn)
        }
        insertColumns.append(metadata.geomColumnName)
        insertColumns.append(contentsOf: propertyKeys.compactMap {
            propertyColumnsByKey[$0]
        })

        let sql = insertSQL(table: quotedTable, columns: insertColumns)
        var bounds = try readContentsBounds(table: metadata.tableName, db: db)
        var indexEntries: [(rowId: Int64, envelope: BoundingBox)] = []
        indexEntries.reserveCapacity(features.count)

        for feature in features {
            let prepared = try prepareRow(
                feature,
                projection: projection,
                srsId: srsId,
                includeId: idColumn != nil,
                propertyKeys: propertyKeys)
            try db.execute(sql, values: prepared.values)

            let rowId = db.lastInsertRowId()
            bounds = union(bounds, prepared.envelope)
            if let envelope = prepared.envelope {
                indexEntries.append((rowId, envelope))
            }
        }

        try updateContentsBounds(
            db: db,
            table: metadata.tableName,
            bounds: bounds)

        let newDimensions = coordinateDimensions(of: features)
        let mergedZ = mergeDimension(existing: metadata.z, new: newDimensions.z)
        let mergedM = mergeDimension(existing: metadata.m, new: newDimensions.m)
        if mergedZ != metadata.z || mergedM != metadata.m {
            try db.execute(
                """
                UPDATE gpkg_geometry_columns
                SET z = ?, m = ?
                WHERE table_name = ?;
                """,
                values: [mergedZ, mergedM, metadata.tableName])
        }

        let hasRTree = try GeoPackage.hasRTreeIndex(
            for: metadata.tableName,
            column: metadata.geomColumnName,
            in: db)

        if hasRTree {
            try insertRTreeRows(
                entries: indexEntries,
                table: metadata.tableName,
                geomColumnName: metadata.geomColumnName,
                db: db)
        }
        else if createSpatialIndex {
            let allFeatures = try GeoPackageReader.readFeatures(
                from: db, table: metadata.tableName)
            let allEntries = allFeatures.compactMap { feature -> (Int64, BoundingBox)? in
                guard let rowId = feature.gpkgRowId,
                      let envelope = feature.boundingBox
                        ?? feature.calculateBoundingBox()
                else { return nil }
                return (Int64(rowId), envelope)
            }
            try createRTree(
                table: metadata.tableName,
                geomColumnName: metadata.geomColumnName,
                entries: allEntries,
                db: db)
        }
    }

    // MARK: - Row preparation and insertion

    private struct PreparedRow {
        let values: [Any?]
        let envelope: BoundingBox?
    }

    /// Builds one row's bind values in the same order as the INSERT columns:
    /// optional `id`, geometry, then properties in `propertyKeys` order.
    private static func prepareRow(
        _ feature: Feature,
        projection: Projection,
        srsId: Int,
        includeId: Bool = true,
        propertyKeys: [String]
    ) throws -> PreparedRow {
        var values: [Any?] = []
        if includeId {
            values.append(idValue(feature.id))
        }

        let geometry = feature.geometry?.projected(to: projection)
        let envelope = geometry?.boundingBox ?? geometry?.calculateBoundingBox()

        if let geometry {
            guard let wkb = WKBCoder.encode(
                geometry: geometry,
                byteOrder: .littleEndian,
                targetProjection: projection)
            else {
                throw GeoPackageError.invalidWKB(
                    detail: "Could not encode geometry of feature "
                        + "\(feature.id?.description ?? "<no id>")")
            }

            if let envelope, !isFinite(envelope) {
                throw GeoPackageError.invalidArgument(
                    detail: "Geometry has a non-finite bounding box")
            }

            values.append(WKBHeader.prependHeader(
                to: wkb,
                srid: srsId,
                envelope: envelope,
                isEmpty: geometry.allCoordinates.isEmpty))
        }
        else {
            values.append(nil)
        }

        for key in propertyKeys {
            values.append(feature.properties[key])
        }

        return PreparedRow(values: values, envelope: envelope)
    }

    private static func isFinite(_ boundingBox: BoundingBox) -> Bool {
        boundingBox.southWest.longitude.isFinite
            && boundingBox.southWest.latitude.isFinite
            && boundingBox.northEast.longitude.isFinite
            && boundingBox.northEast.latitude.isFinite
    }

    private static func insertSQL(
        table: String,
        columns: [String]
    ) -> String {
        let names = columns.map {
            GeoPackage.sanitizeIdentifier($0)
        }.joined(separator: ", ")
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        return "INSERT INTO \(table) (\(names)) VALUES (\(placeholders));"
    }

    // MARK: - Metadata

    private static func writeContentsMetadata(
        db: SQLiteDB,
        table: String,
        srsId: Int,
        bounds: BoundingBox?
    ) throws {
        try db.execute(
            """
            INSERT INTO gpkg_contents
            (table_name, data_type, identifier, description,
             last_change, min_x, min_y, max_x, max_y, srs_id)
            VALUES (?, 'features', ?, '',
             strftime('%Y-%m-%dT%H:%M:%fZ','now'), ?, ?, ?, ?, ?);
            """,
            values: [
                table,
                table,
                bounds?.southWest.longitude,
                bounds?.southWest.latitude,
                bounds?.northEast.longitude,
                bounds?.northEast.latitude,
                srsId,
            ])
    }

    private static func updateContentsBounds(
        db: SQLiteDB,
        table: String,
        bounds: BoundingBox?
    ) throws {
        if let bounds {
            try db.execute(
                """
                UPDATE gpkg_contents
                SET min_x = ?, min_y = ?, max_x = ?, max_y = ?,
                    last_change = strftime('%Y-%m-%dT%H:%M:%fZ','now')
                WHERE table_name = ?;
                """,
                values: [
                    bounds.southWest.longitude,
                    bounds.southWest.latitude,
                    bounds.northEast.longitude,
                    bounds.northEast.latitude,
                    table,
                ])
        }
        else {
            // Keep any existing bounds when only unlocated features were
            // appended; erasing them would lose the table extent.
            try db.execute(
                """
                UPDATE gpkg_contents
                SET last_change = strftime('%Y-%m-%dT%H:%M:%fZ','now')
                WHERE table_name = ?;
                """,
                values: [table])
        }
    }

    private static func readContentsBounds(
        table: String,
        db: SQLiteDB
    ) throws -> BoundingBox? {
        let rows = try db.query(
            """
            SELECT min_x, min_y, max_x, max_y, srs_id
            FROM gpkg_contents WHERE table_name = ?;
            """,
            values: [table])
        guard let row = rows.first,
              let minX = row["min_x"] as? Double,
              let minY = row["min_y"] as? Double,
              let maxX = row["max_x"] as? Double,
              let maxY = row["max_y"] as? Double
        else { return nil }

        return GeoPackage.boundingBox(
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            srsId: row["srs_id"] as? Int)
    }

    private static func writeGeometryColumnsMetadata(
        db: SQLiteDB,
        table: String,
        geomColumnName: String,
        geometryTypeName: String,
        srsId: Int,
        z: Int,
        m: Int
    ) throws {
        try db.execute(
            """
            INSERT INTO gpkg_geometry_columns
            (table_name, column_name, geometry_type_name, srs_id, z, m)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            values: [table, geomColumnName, geometryTypeName, srsId, z, m])
    }

    /// Infers the GeoPackage Z/M constraint codes from the geometries.
    ///
    /// `0` = prohibited, `1` = mandatory, `2` = optional.
    private static func coordinateDimensions(
        of features: [Feature]
    ) -> (z: Int, m: Int) {
        var hasCoordinates = false
        var anyZ = false
        var allZ = true
        var anyM = false
        var allM = true

        for feature in features {
            guard let geometry = feature.geometry else { continue }
            for coordinate in geometry.allCoordinates {
                hasCoordinates = true
                if coordinate.altitude == nil {
                    allZ = false
                }
                else {
                    anyZ = true
                }
                if coordinate.m == nil {
                    allM = false
                }
                else {
                    anyM = true
                }
            }
        }

        guard hasCoordinates else { return (0, 0) }
        let z = anyZ ? (allZ ? 1 : 2) : 0
        let m = anyM ? (allM ? 1 : 2) : 0
        return (z, m)
    }

    /// Merges an existing dimension constraint with a new batch.
    ///
    /// Adding optional or mandatory coordinates to a prohibited column (or
    /// vice versa) widens the column to optional (`2`).
    private static func mergeDimension(existing: Int, new: Int) -> Int {
        existing == new ? existing : 2
    }

    // MARK: - Spatial index

    private static func createRTree(
        table: String,
        geomColumnName: String,
        entries: [(rowId: Int64, envelope: BoundingBox)],
        db: SQLiteDB
    ) throws {
        let rtreeName = GeoPackage.rTreeTableName(
            for: table, column: geomColumnName)

        try db.execute("""
            CREATE VIRTUAL TABLE \(rtreeName)
            USING rtree("id", "minx", "maxx", "miny", "maxy");
            """)

        try insertRTreeRows(
            entries: entries,
            table: table,
            geomColumnName: geomColumnName,
            db: db)

        try db.execute(
            """
            INSERT OR IGNORE INTO gpkg_extensions
            (table_name, column_name, extension_name, definition, scope)
            VALUES (?, ?, 'gpkg_rtree_index',
                    'http://www.geopackage.org/spec120/#extension_rtree',
                    'write-only');
            """,
            values: [table, geomColumnName])
    }

    private static func insertRTreeRows(
        entries: [(rowId: Int64, envelope: BoundingBox)],
        table: String,
        geomColumnName: String,
        db: SQLiteDB
    ) throws {
        guard !entries.isEmpty else { return }

        let rtreeName = GeoPackage.rTreeTableName(
            for: table, column: geomColumnName)
        let sql = """
            INSERT OR REPLACE INTO \(rtreeName)
            (id, minx, maxx, miny, maxy) VALUES (?, ?, ?, ?, ?);
            """

        for entry in entries {
            try db.execute(
                sql,
                values: [
                    entry.rowId,
                    entry.envelope.southWest.longitude,
                    entry.envelope.northEast.longitude,
                    entry.envelope.southWest.latitude,
                    entry.envelope.northEast.latitude,
                ])
        }
    }

    // MARK: - Schema inference

    private static func geometryTypeName(for features: [Feature]) -> String {
        let types = Set(features.compactMap { $0.geometry?.type })
        guard types.count == 1, let type = types.first else {
            return "GEOMETRY"
        }
        return GeoPackage.geometryTypeName(for: type)
    }

    private static func validateGeometryTypes(
        _ features: [Feature],
        against metadata: FeatureTableMetadata
    ) throws {
        let existing = metadata.geometryTypeName.uppercased()
        let newTypes = Set(features.compactMap { $0.geometry?.type })
        guard !newTypes.isEmpty else { return }
        if existing == "GEOMETRY" { return }

        guard newTypes.count == 1, let newType = newTypes.first else {
            throw GeoPackageError.mixedGeometryTypes(
                detail: """
                    Cannot append mixed geometry types to \
                    '\(metadata.tableName)' with geometry type \(existing)
                    """)
        }
        let allowed = GeoPackage.geometryTypeName(for: newType)
        guard allowed == existing else {
            throw GeoPackageError.mixedGeometryTypes(
                detail: """
                    Cannot append \(newTypes.map(\.rawValue).sorted()) to \
                    '\(metadata.tableName)' with geometry type \(existing)
                    """)
        }
    }

    private static func validatedPropertyKeys(
        from features: [Feature]
    ) throws -> [String] {
        var seenLowercase: [String: String] = [:]
        var keys = Set<String>()

        for feature in features {
            for (key, value) in feature.properties {
                let lowercase = key.lowercased()
                if let existing = seenLowercase[lowercase], existing != key {
                    throw GeoPackageError.invalidArgument(
                        detail: """
                            Property key '\(key)' collides with '\(existing)'
                            case-insensitively; SQLite column names are
                            case-insensitive
                            """)
                }
                seenLowercase[lowercase] = key

                if key.caseInsensitiveCompare("fid") == .orderedSame
                    || key.caseInsensitiveCompare("id") == .orderedSame
                    || key.caseInsensitiveCompare(geometryColumnName) == .orderedSame
                {
                    throw GeoPackageError.invalidArgument(
                        detail: """
                            Property key '\(key)' conflicts with the reserved \
                            GeoPackage column; rename the property
                            """)
                }

                if value is NSNull {
                    continue
                }
                if !isSupportedPropertyValue(value) {
                    throw GeoPackageError.invalidArgument(
                        detail: """
                            Unsupported property value for '\(key)' \
                            (\(type(of: value))); only Bool, integers, \
                            floating-point numbers, String and Data can be \
                            stored
                            """)
                }
                keys.insert(key)
            }
        }

        return keys.sorted()
    }

    private static func inferredColumnType(
        for key: String,
        in features: [Feature]
    ) -> String {
        var kinds = Set<ValueKind>()

        for feature in features {
            guard let value = feature.properties[key] else { continue }
            if let kind = ValueKind(value: value) {
                kinds.insert(kind)
            }
        }

        if kinds.isEmpty { return "TEXT" }
        if kinds == [.boolean] { return "BOOLEAN" }
        if kinds == [.integer] { return "INTEGER" }
        if kinds.isSubset(of: [.integer, .double]) {
            return "REAL"
        }
        if kinds == [.text] { return "TEXT" }
        if kinds == [.blob] { return "BLOB" }
        return "TEXT"
    }

    private enum ValueKind: Hashable {
        case boolean
        case integer
        case double
        case text
        case blob

        init?(value: Sendable) {
            switch value {
            case is Bool: self = .boolean
            case is any BinaryInteger: self = .integer
            case is any BinaryFloatingPoint: self = .double
            case is String: self = .text
            case is Data: self = .blob
            default: return nil
            }
        }
    }

    private static func isSupportedPropertyValue(_ value: Sendable) -> Bool {
        ValueKind(value: value) != nil
    }

    private static func inferIdColumnType(from features: [Feature]) -> String {
        var seenInt = false
        var seenDouble = false
        var seenString = false
        var seenLargeUInt = false

        for feature in features {
            switch feature.id {
            case .int:
                seenInt = true
            case .uint(let value):
                if Int64(exactly: value) == nil {
                    seenLargeUInt = true
                }
                else {
                    seenInt = true
                }
            case .double:
                seenDouble = true
            case .string:
                seenString = true
            case nil:
                continue
            }
        }

        let activeKinds = [seenInt, seenDouble, seenString].filter { $0 }.count
        if seenLargeUInt || activeKinds == 0 || activeKinds > 1 {
            return "TEXT"
        }
        if seenInt { return "INTEGER" }
        if seenDouble { return "REAL" }
        return "TEXT"
    }

    private static func idValue(_ id: Feature.Identifier?) -> Any? {
        guard let id else { return nil }
        switch id {
        case .int(let value):
            return value
        case .uint(let value):
            if let int = Int64(exactly: value) {
                return int
            }
            return String(value)
        case .double(let value):
            return value
        case .string(let value):
            return value
        }
    }

    // MARK: - Bounds

    private static func union(
        _ lhs: BoundingBox?,
        _ rhs: BoundingBox?
    ) -> BoundingBox? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }

        let projection = lhs.projection
        let other = rhs.projected(to: projection)
        return BoundingBox(
            southWest: Coordinate3D(
                x: min(lhs.southWest.longitude, other.southWest.longitude),
                y: min(lhs.southWest.latitude, other.southWest.latitude),
                projection: projection),
            northEast: Coordinate3D(
                x: max(lhs.northEast.longitude, other.northEast.longitude),
                y: max(lhs.northEast.latitude, other.northEast.latitude),
                projection: projection))
    }

}
