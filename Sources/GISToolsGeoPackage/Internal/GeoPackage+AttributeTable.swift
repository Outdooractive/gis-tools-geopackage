import Foundation
import CSQLite
import GISTools

extension GeoPackage {

    /// Reads a non-spatial attribute table from a GeoPackage.
    public static func readAttributeTable(
        from url: URL,
        table: String,
        rowId: Int? = nil
    ) throws -> AttributeTable {
        let db = try SQLiteDB(path: url.path)
        defer { db.close() }

        return try readAttributeTable(
            from: db,
            table: table,
            rowId: rowId)
    }

    /// Writes an attribute table to a GeoPackage.
    ///
    /// Creates the table with `data_type = "attributes"`, registers it
    /// in `gpkg_contents`, and inserts all rows.
    public static func writeAttributeTable(
        _ table: AttributeTable,
        to url: URL,
        relationship: RelationRow? = nil
    ) throws {
        let db = try SQLiteDB(path: url.path)
        defer { db.close() }

        try writeAttributeTable(table, in: db)

        if let rel = relationship {
            try GeoPackage.registerRelatedTablesExtension(in: db)
            try GeoPackage.writeRelation(rel, in: db)
        }
    }

    static func readAttributeTable(
        from db: SQLiteDB,
        table: String,
        rowId: Int? = nil
    ) throws -> AttributeTable {
        let quotedTable = GeoPackage.sanitizeIdentifier(table)

        let tableInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        let columnNames: [String] = tableInfo.compactMap {
            $0["name"] as? String
        }.filter { $0 != "id" }

        let whereClause = rowId.map { " WHERE id = \($0)" } ?? ""
        let rows: [[String: Sendable]] = try db.query(
            "SELECT * FROM \(quotedTable)\(whereClause) ORDER BY id;")
        var rowIds: [Int64] = []
        var dataRows: [[String: Sendable]] = []

        for row in rows {
            guard let rid = row["id"] as? Int else { continue }

            rowIds.append(Int64(rid))

            var dataRow: [String: Sendable] = [:]
            for col in columnNames {
                if let value = row[col] {
                    if let data = value as? Data {
                        dataRow[col] = data.base64EncodedString()
                    }
                    else {
                        dataRow[col] = value
                    }
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
        let quotedTable = GeoPackage.sanitizeIdentifier(table.tableName)
        let escapedTable = GeoPackage.sanitizeStringLiteral(table.tableName)

        let sampleRow = table.rows.first ?? [:]
        let colDefs: [(String, String)] = table.columns.map { col in
            (col, sqliteType(for: sampleRow[col]))
        }

        let columnsSQL = colDefs.map { (name, type) in
            "\(GeoPackage.sanitizeIdentifier(name)) \(type)"
        }.joined(separator: ", ")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS \(quotedTable) (
                id INTEGER PRIMARY KEY,
                \(columnsSQL)
            );
            """)

        try db.execute("""
            INSERT OR REPLACE INTO gpkg_contents
            (table_name, data_type, identifier)
            VALUES (\(escapedTable), 'attributes', \(escapedTable));
            """)

        for (index, row) in table.rows.enumerated() {
            let rowId = index < table.rowIds.count ? table.rowIds[index] : Int64(index + 1)
            var values: [String] = ["\(rowId)"]
            for col in table.columns {
                if let v = row[col] {
                    switch v {
                    case let i as Int: values.append("\(i)")
                    case let d as Double: values.append("\(d)")
                    case let s as String:
                        let esc = s.replacingOccurrences(of: "'", with: "''")
                        values.append("'\(esc)'")
                    default: values.append("NULL")
                    }
                }
                else {
                    values.append("NULL")
                }
            }

            let colList = table.columns
                .map { GeoPackage.sanitizeIdentifier($0) }
                .joined(separator: ", ")
            let colPart = colList.isEmpty ? "" : ", \(colList)"
            let valPart = values.joined(separator: ", ")
            try db.execute("""
                INSERT OR REPLACE INTO \(quotedTable) (id\(colPart)) VALUES (\(valPart));
                """)
        }
    }

    private static func sqliteType(for value: Any?) -> String {
        guard let value else { return "TEXT" }

        return switch value {
        case is Bool: "BOOLEAN"
        case is Int, is Int64: "INTEGER"
        case is Double, is Float: "REAL"
        default: "TEXT"
        }
    }

}
