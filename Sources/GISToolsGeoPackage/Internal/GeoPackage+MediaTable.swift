import Foundation
import GISTools

extension GeoPackage {

    /// Reads a media table from a GeoPackage.
    ///
    /// - Parameters:
    ///   - url: The GeoPackage file URL.
    ///   - table: The media table name.
    /// - Returns: The media table.
    public static func readMediaTable(
        from url: URL,
        table: String
    ) throws -> MediaTable {
        let db = try SQLiteDB(path: url.path, readOnly: true)
        defer { db.close() }
        return try readMediaTable(from: db, table: table)
    }

    /// Reads media rows filtered by a specific row ID.
    ///
    /// - Parameters:
    ///   - url: The GeoPackage file URL.
    ///   - table: The media table name.
    ///   - rowId: The primary key value to filter by.
    /// - Returns: The matching media rows.
    public static func readMediaRows(
        from url: URL,
        table: String,
        rowId: Int
    ) throws -> [MediaRow] {
        let db = try SQLiteDB(path: url.path, readOnly: true)
        defer { db.close() }
        return try readMediaRows(from: db, table: table, rowId: rowId)
    }

    /// Writes a media table to a GeoPackage and optionally creates a
    /// relationship to a feature table. Existing rows are replaced.
    ///
    /// - Parameters:
    ///   - mediaTable: The media table to write.
    ///   - url: The GeoPackage file URL.
    ///   - relationship: An optional relationship to register.
    public static func writeMediaTable(
        _ mediaTable: MediaTable,
        to url: URL,
        relationship: RelationRow? = nil
    ) throws {
        let db = try SQLiteDB(path: url.path)
        defer { db.close() }

        try db.withTransaction {
            if try !hasMetadataTables(in: db) {
                try createMetadata(in: db)
            }
            try writeMediaTable(mediaTable, in: db)

            if let relationship {
                try registerRelatedTablesExtension(in: db)
                try writeRelation(relationship, in: db)
            }
        }
    }

    static func readMediaTable(
        from db: SQLiteDB,
        table: String
    ) throws -> MediaTable {
        try readMediaTable(from: db, table: table, rowId: nil)
    }

    static func readMediaTable(
        from db: SQLiteDB,
        table: String,
        rowId: Int?
    ) throws -> MediaTable {
        let quotedTable = sanitizeIdentifier(table)
        let tableInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        guard !tableInfo.isEmpty else {
            throw GeoPackageError.tableNotFound(name: table)
        }

        let allColumns = tableInfo.compactMap { $0["name"] as? String }
        try validateMediaColumns(allColumns, table: table)
        let idColumn = try mediaColumn("id", in: allColumns, table: table)
        let dataColumn = try mediaColumn("data", in: allColumns, table: table)
        let contentTypeColumn = try mediaColumn(
            "content_type", in: allColumns, table: table)
        let quotedId = sanitizeIdentifier(idColumn)

        var sql = "SELECT * FROM \(quotedTable)"
        var values: [Any?] = []
        if let rowId {
            sql += " WHERE \(quotedId) = ?"
            values.append(rowId)
        }
        sql += " ORDER BY \(quotedId);"

        let rows: [[String: Sendable]] = try db.query(sql, values: values)
        var rowIds: [Int64] = []
        var data: [Data] = []
        var contentTypes: [String] = []
        var properties: [[String: Sendable]] = []

        for row in rows {
            guard let rid = int64Value(row[idColumn]),
                  let blob = row[dataColumn] as? Data,
                  let contentType = row[contentTypeColumn] as? String
            else {
                throw GeoPackageError.invalidGeoPackage(
                    detail: """
                        Media table '\(table)' contains a row with a missing \
                        id, data blob or content_type
                        """)
            }

            rowIds.append(rid)
            data.append(blob)
            contentTypes.append(contentType)
            properties.append(
                decodeProperties(
                    row,
                    columns: allColumns.filter {
                        !isMediaMetadataColumn($0)
                    }))
        }

        return MediaTable(
            tableName: table,
            rowIds: rowIds,
            data: data,
            contentTypes: contentTypes,
            properties: properties)
    }

    static func readMediaRows(
        from db: SQLiteDB,
        table: String,
        rowId: Int
    ) throws -> [MediaRow] {
        let quotedTable = sanitizeIdentifier(table)
        let tableInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        guard !tableInfo.isEmpty else {
            throw GeoPackageError.tableNotFound(name: table)
        }

        let allColumns = tableInfo.compactMap { $0["name"] as? String }
        try validateMediaColumns(allColumns, table: table)
        let idColumn = try mediaColumn("id", in: allColumns, table: table)
        let dataColumn = try mediaColumn("data", in: allColumns, table: table)
        let contentTypeColumn = try mediaColumn(
            "content_type", in: allColumns, table: table)
        let quotedId = sanitizeIdentifier(idColumn)

        let rows: [[String: Sendable]] = try db.query(
            """
            SELECT * FROM \(quotedTable)
            WHERE \(quotedId) = ? ORDER BY \(quotedId);
            """,
            values: [rowId])

        return try rows.map { row in
            guard let rid = intValue(row[idColumn]),
                  let blob = row[dataColumn] as? Data,
                  let contentType = row[contentTypeColumn] as? String
            else {
                throw GeoPackageError.invalidGeoPackage(
                    detail: """
                        Media table '\(table)' contains a row with a missing \
                        id, data blob or content_type
                        """)
            }

            return MediaRow(
                id: rid,
                data: blob,
                contentType: contentType,
                properties: decodeProperties(
                    row,
                    columns: allColumns.filter {
                        !isMediaMetadataColumn($0)
                    }))
        }
    }

    static func writeMediaTable(
        _ table: MediaTable,
        in db: SQLiteDB
    ) throws {
        try validateTableName(table.tableName)
        try ensureContentsDataType(
            "attributes", for: table.tableName, in: db)

        guard table.rowIds.count == table.data.count,
              table.data.count == table.contentTypes.count
        else {
            throw GeoPackageError.invalidArgument(
                detail: """
                    MediaTable '\(table.tableName)' has \(table.rowIds.count) \
                    row IDs, \(table.data.count) blobs and \
                    \(table.contentTypes.count) content types; these must match
                    """)
        }

        let rows = table.count
        let quotedTable = sanitizeIdentifier(table.tableName)
        let existingInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        let existingColumns = existingInfo.compactMap { $0["name"] as? String }

        let propertyKeys = try validatedPropertyKeys(in: table)
        var seenLowerCase = Set<String>()
        for key in propertyKeys {
            guard seenLowerCase.insert(key.lowercased()).inserted else {
                throw GeoPackageError.invalidArgument(
                    detail: """
                        Media property '\(key)' collides with another property \
                        case-insensitively
                        """)
            }
        }

        if existingColumns.isEmpty {
            let extraSQL = propertyKeys.map {
                "\(sanitizeIdentifier($0)) \(inferredType(for: $0, in: table))"
            }.joined(separator: ", ")
            let extraPart = extraSQL.isEmpty ? "" : ", \(extraSQL)"
            try db.execute("""
                CREATE TABLE \(quotedTable) (
                    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    data BLOB NOT NULL,
                    content_type TEXT NOT NULL\(extraPart)
                );
                """)
        }
        else {
            try validateMediaColumns(existingColumns, table: table.tableName)
            for key in propertyKeys where !existingColumns.contains(where: {
                $0.caseInsensitiveCompare(key) == .orderedSame
            }) {
                try db.execute(
                    """
                    ALTER TABLE \(quotedTable)
                    ADD COLUMN \(sanitizeIdentifier(key)) \
                    \(inferredType(for: key, in: table));
                    """)
            }
        }

        try db.execute(
            """
            INSERT OR REPLACE INTO gpkg_contents
            (table_name, data_type, identifier, last_change, srs_id)
            VALUES (?, 'attributes', ?,
                    strftime('%Y-%m-%dT%H:%M:%fZ','now'), NULL);
            """,
            values: [table.tableName, table.tableName])

        // A MediaTable describes the complete table. Rows that are no longer
        // present must not linger from a previous write.
        try db.execute("DELETE FROM \(quotedTable);")

        let propertyColumnList = propertyKeys.map {
            sanitizeIdentifier($0)
        }.joined(separator: ", ")
        let propertyColumnPart = propertyKeys.isEmpty
            ? ""
            : ", \(propertyColumnList)"
        let propertyPlaceholders = propertyKeys.isEmpty
            ? ""
            : ", " + propertyKeys.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            INSERT OR REPLACE INTO \(quotedTable)
            (id, data, content_type\(propertyColumnPart))
            VALUES (?, ?, ?\(propertyPlaceholders));
            """

        for index in 0 ..< rows {
            let properties = index < table.properties.count
                ? table.properties[index]
                : [:]

            var values: [Any?] = [
                table.rowIds[index],
                table.data[index],
                table.contentTypes[index],
            ]
            for key in propertyKeys {
                let value = properties[key]
                if value == nil || value is NSNull {
                    values.append(nil)
                }
                else if let value, isSupportedProperty(value) {
                    values.append(value)
                }
                else {
                    throw GeoPackageError.invalidArgument(
                        detail: """
                            Unsupported media property '\(key)' \
                            (\(String(describing: value.map { type(of: $0) })))
                            """)
                }
            }
            try db.execute(sql, values: values)
        }
    }

    // MARK: - Media helpers

    private static func isMediaMetadataColumn(_ column: String) -> Bool {
        column.caseInsensitiveCompare("id") == .orderedSame
            || column.caseInsensitiveCompare("data") == .orderedSame
            || column.caseInsensitiveCompare("content_type") == .orderedSame
    }

    private static func mediaColumn(
        _ name: String,
        in columns: [String],
        table: String
    ) throws -> String {
        guard let column = columns.first(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw GeoPackageError.invalidGeoPackage(
                detail: "Media table '\(table)' is missing '\(name)'")
        }
        return column
    }

    private static func validateMediaColumns(
        _ columns: [String],
        table: String
    ) throws {
        let lowercase = Set(columns.map { $0.lowercased() })
        for required in ["id", "data", "content_type"] {
            guard lowercase.contains(required) else {
                throw GeoPackageError.invalidGeoPackage(
                    detail: """
                        Media table '\(table)' is missing required column \
                        '\(required)'
                        """)
            }
        }
    }

    private static func validatedPropertyKeys(
        in table: MediaTable
    ) throws -> [String] {
        var keys = Set<String>()
        for row in table.properties {
            for (key, value) in row {
                if isMediaMetadataColumn(key) {
                    throw GeoPackageError.invalidArgument(
                        detail: """
                            Media property '\(key)' conflicts with a reserved \
                            media table column
                            """)
                }
                if value is NSNull {
                    continue
                }
                guard isSupportedProperty(value) else {
                    throw GeoPackageError.invalidArgument(
                        detail: """
                            Unsupported media property value for '\(key)' \
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

    private static func decodeProperties(
        _ row: [String: Sendable],
        columns: [String]
    ) -> [String: Sendable] {
        var properties: [String: Sendable] = [:]
        for column in columns {
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

    private static func inferredType(
        for key: String,
        in table: MediaTable
    ) -> String {
        var kinds = Set<ValueKind>()

        for row in table.properties {
            guard let value = row[key], !(value is NSNull) else { continue }
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

    private static func isSupportedProperty(_ value: Sendable) -> Bool {
        ValueKind(value: value) != nil
    }

    private static func intValue(_ value: (any Sendable)?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let int64 as Int64:
            return Int(exactly: int64)
        default:
            return nil
        }
    }

    private static func int64Value(_ value: (any Sendable)?) -> Int64? {
        switch value {
        case let int as Int:
            return Int64(int)
        case let int64 as Int64:
            return int64
        default:
            return nil
        }
    }

}
