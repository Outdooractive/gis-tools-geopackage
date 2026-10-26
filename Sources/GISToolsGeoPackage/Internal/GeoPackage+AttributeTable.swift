import Foundation
import GISTools

extension GeoPackage {

    /// Reads a non-spatial attribute table from a GeoPackage.
    ///
    /// - Parameters:
    ///   - url: The GeoPackage file URL.
    ///   - table: The attribute table name.
    ///   - rowId: An optional primary key to filter by.
    /// - Returns: The attribute rows.
    public static func readAttributeTable(
        from url: URL,
        table: String,
        rowId: Int? = nil
    ) throws -> AttributeTable {
        let db = try SQLiteDB(path: url.path, readOnly: true)
        defer { db.close() }

        return try readAttributeTable(
            from: db,
            table: table,
            rowId: rowId)
    }

    /// Writes an attribute table to a GeoPackage.
    ///
    /// Creates the table with `data_type = "attributes"`, registers it in
    /// `gpkg_contents`, and inserts all rows in one transaction. Existing
    /// tables are updated; missing columns are added and previous rows are
    /// replaced.
    ///
    /// - Parameters:
    ///   - table: The attribute table to write.
    ///   - url: The GeoPackage file URL.
    ///   - relationship: An optional relationship to register.
    public static func writeAttributeTable(
        _ table: AttributeTable,
        to url: URL,
        relationship: RelationRow? = nil
    ) throws {
        let db = try SQLiteDB(path: url.path)
        defer { db.close() }

        try db.withTransaction {
            if try !hasMetadataTables(in: db) {
                try createMetadata(in: db)
            }
            try writeAttributeTable(table, in: db)

            if let relationship {
                try registerRelatedTablesExtension(in: db)
                try writeRelation(relationship, in: db)
            }
        }
    }

    static func readAttributeTable(
        from db: SQLiteDB,
        table: String,
        rowId: Int? = nil
    ) throws -> AttributeTable {
        let quotedTable = sanitizeIdentifier(table)
        let tableInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        guard !tableInfo.isEmpty else {
            throw GeoPackageError.tableNotFound(name: table)
        }

        let allColumnNames: [String] = tableInfo.compactMap {
            $0["name"] as? String
        }
        guard let idColumnName = allColumnNames.first(where: {
            $0.caseInsensitiveCompare("id") == .orderedSame
        }) else {
            throw GeoPackageError.invalidGeoPackage(
                detail: "Attribute table '\(table)' has no id column")
        }

        let columnNames = allColumnNames.filter {
            $0.caseInsensitiveCompare("id") != .orderedSame
        }
        let quotedId = sanitizeIdentifier(idColumnName)

        var sql = "SELECT * FROM \(quotedTable)"
        var values: [Any?] = []
        if let rowId {
            sql += " WHERE \(quotedId) = ?"
            values.append(rowId)
        }
        sql += " ORDER BY \(quotedId);"

        let rows: [[String: Sendable]] = try db.query(sql, values: values)
        var rowIds: [Int64] = []
        var dataRows: [[String: Sendable]] = []

        for row in rows {
            guard let rowIdValue = int64Value(row[idColumnName]) else {
                continue
            }
            rowIds.append(rowIdValue)

            var dataRow: [String: Sendable] = [:]
            for column in columnNames {
                guard let value = row[column] else { continue }
                if let data = value as? Data {
                    dataRow[column] = data.base64EncodedString()
                }
                else {
                    dataRow[column] = value
                }
            }
            dataRows.append(dataRow)
        }

        return AttributeTable(
            tableName: table,
            columns: columnNames,
            rows: dataRows,
            rowIds: rowIds)
    }

    static func writeAttributeTable(
        _ table: AttributeTable,
        in db: SQLiteDB
    ) throws {
        try validateTableName(table.tableName)
        try ensureContentsDataType(
            "attributes", for: table.tableName, in: db)

        let quotedTable = sanitizeIdentifier(table.tableName)
        let existingInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        let existingColumns = existingInfo.compactMap { $0["name"] as? String }

        var seenLowerCase = Set<String>()
        for column in table.columns {
            let lowercase = column.lowercased()
            if lowercase == "id" {
                throw GeoPackageError.invalidArgument(
                    detail: """
                        Attribute column 'id' is reserved for the primary key
                        """)
            }
            guard seenLowerCase.insert(lowercase).inserted else {
                throw GeoPackageError.invalidArgument(
                    detail: """
                        Attribute column '\(column)' collides with another \
                        column case-insensitively
                        """)
            }
        }

        if existingColumns.isEmpty {
            let columnSQL = table.columns.map { column in
                "\(sanitizeIdentifier(column)) \(inferredType(for: column, in: table))"
            }
            let suffix = columnSQL.isEmpty ? "" : ", " + columnSQL.joined(separator: ", ")
            try db.execute("""
                CREATE TABLE \(quotedTable) (
                    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL\(suffix)
                );
                """)
        }
        else {
            for column in table.columns where !existingColumns.contains(where: {
                $0.caseInsensitiveCompare(column) == .orderedSame
            }) {
                try db.execute(
                    """
                    ALTER TABLE \(quotedTable)
                    ADD COLUMN \(sanitizeIdentifier(column)) \
                    \(inferredType(for: column, in: table));
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

        // An AttributeTable describes the complete table. Rows that are no
        // longer present must not linger from a previous write.
        try db.execute("DELETE FROM \(quotedTable);")

        let columnList = table.columns.map {
            sanitizeIdentifier($0)
        }.joined(separator: ", ")
        let columnPart = table.columns.isEmpty ? "" : ", \(columnList)"
        let placeholderPart = table.columns.isEmpty
            ? ""
            : ", " + table.columns.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            INSERT OR REPLACE INTO \(quotedTable)
            (id\(columnPart)) VALUES (?\(placeholderPart));
            """

        for (index, row) in table.rows.enumerated() {
            let rowId = index < table.rowIds.count
                ? table.rowIds[index]
                : Int64(index + 1)

            var values: [Any?] = [rowId]
            for column in table.columns {
                let value = row[column]
                if value == nil || value is NSNull {
                    values.append(nil)
                }
                else if let value, isSupported(value) {
                    values.append(value)
                }
                else {
                    throw GeoPackageError.invalidArgument(
                        detail: """
                            Unsupported value for attribute '\(column)' \
                            (\(String(describing: value.map { type(of: $0) }))); \
                            only Bool, integers, floating-point numbers, \
                            String and Data can be stored
                            """)
                }
            }
            try db.execute(sql, values: values)
        }
    }

    // MARK: - Helpers

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

    private static func inferredType(
        for column: String,
        in table: AttributeTable
    ) -> String {
        var kinds = Set<ValueKind>()

        for row in table.rows {
            guard let value = row[column], !(value is NSNull) else { continue }
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

    private static func isSupported(_ value: Sendable) -> Bool {
        ValueKind(value: value) != nil
    }

}
