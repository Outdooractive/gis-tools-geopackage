import Foundation
import GISTools

extension GeoPackage {

    /// Reads a media table from a GeoPackage.
    public static func readMediaTable(
        from url: URL,
        table: String
    ) throws -> MediaTable {
        let db = try SQLiteDB(path: url.path)
        defer { db.close() }
        return try readMediaTable(from: db, table: table)
    }

    /// Reads media rows filtered by a specific row ID.
    public static func readMediaRows(
        from url: URL,
        table: String,
        rowId: Int
    ) throws -> [MediaRow] {
        let db = try SQLiteDB(path: url.path)
        defer { db.close() }
        return try readMediaRows(from: db, table: table, rowId: rowId)
    }

    /// Writes a media table to a GeoPackage and optionally creates a
    /// relationship to a feature table.
    public static func writeMediaTable(
        _ mediaTable: MediaTable,
        to url: URL,
        relationship: RelationRow? = nil
    ) throws {
        let db = try SQLiteDB(path: url.path)
        defer { db.close() }

        try writeMediaTable(mediaTable, in: db)

        if let rel = relationship {
            try GeoPackage.registerRelatedTablesExtension(in: db)
            try GeoPackage.writeRelation(rel, in: db)
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
        let quotedTable = GeoPackage.sanitizeIdentifier(table)
        let tableInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        let allColumns: [String] = tableInfo.compactMap { $0["name"] as? String }
        let userColumns = allColumns.filter {
            $0 != "id" && $0 != "data" && $0 != "content_type"
        }

        let whereClause = rowId.map { " WHERE id = \($0)" } ?? ""
        let rows: [[String: Sendable]] = try db.query(
            "SELECT * FROM \(quotedTable)\(whereClause) ORDER BY id;")

        var rowIds: [Int64] = []
        var data: [Data] = []
        var contentTypes: [String] = []
        var properties: [[String: Sendable]] = []

        for row in rows {
            guard let rid = row["id"] as? Int,
                  let blob = row["data"] as? Data,
                  let ct = row["content_type"] as? String
            else { continue }

            rowIds.append(Int64(rid))
            data.append(blob)
            contentTypes.append(ct)

            var props: [String: Sendable] = [:]
            for col in userColumns {
                if let value = row[col] {
                    if let d = value as? Data {
                        props[col] = d.base64EncodedString()
                    }
                    else {
                        props[col] = value
                    }
                }
            }
            properties.append(props)
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
        let quotedTable = GeoPackage.sanitizeIdentifier(table)
        let tableInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        let allColumns: [String] = tableInfo.compactMap { $0["name"] as? String }
        let userColumns = allColumns.filter {
            $0 != "id" && $0 != "data" && $0 != "content_type"
        }

        let rows: [[String: Sendable]] = try db.query(
            "SELECT * FROM \(quotedTable) WHERE id = \(rowId) ORDER BY id;")

        return rows.compactMap { row in
            guard let rid = row["id"] as? Int,
                  let blob = row["data"] as? Data,
                  let ct = row["content_type"] as? String
            else { return nil }

            var props: [String: Sendable] = [:]
            for col in userColumns {
                if let value = row[col] {
                    if let d = value as? Data {
                        props[col] = d.base64EncodedString()
                    }
                    else {
                        props[col] = value
                    }
                }
            }
            return MediaRow(id: rid, data: blob, contentType: ct, properties: props)
        }
    }

    static func writeMediaTable(
        _ table: MediaTable,
        in db: SQLiteDB
    ) throws {
        let quotedTable = GeoPackage.sanitizeIdentifier(table.tableName)
        let escapedTable = GeoPackage.sanitizeStringLiteral(table.tableName)

        let userCols: [String]
        if let first = table.properties.first {
            userCols = first.keys.sorted()
        }
        else {
            userCols = []
        }

        let userColSQL = userCols.map { col in
            "\(GeoPackage.sanitizeIdentifier(col)) TEXT"
        }.joined(separator: ", ")
        let extraCols = userColSQL.isEmpty ? "" : ", \(userColSQL)"

        try db.execute("""
            CREATE TABLE IF NOT EXISTS \(quotedTable) (
                id INTEGER PRIMARY KEY,
                data BLOB NOT NULL,
                content_type TEXT NOT NULL\(extraCols)
            );
            """)

        try db.execute("""
            INSERT OR REPLACE INTO gpkg_contents
            (table_name, data_type, identifier)
            VALUES (\(escapedTable), 'attributes', \(escapedTable));
            """)

        for i in 0 ..< table.count {
            let rowId = table.rowIds[i]
            let blobHex = table.data[i].map { String(format: "%02X", $0) }.joined()
            let ctEsc = table.contentTypes[i]
                .replacingOccurrences(of: "'", with: "''")

            var userParts: [String] = []
            let props = i < table.properties.count ? table.properties[i] : [:]
            for col in userCols {
                if let v = props[col] as? String {
                    let esc = v.replacingOccurrences(of: "'", with: "''")
                    userParts.append("'\(esc)'")
                }
                else {
                    userParts.append("NULL")
                }
            }
            let userStr = userParts.isEmpty ? "" : ", " + userParts.joined(separator: ", ")

            try db.execute("""
                INSERT INTO \(quotedTable) (id, data, content_type\(userCols.isEmpty ? "" : ", " + userCols.map { GeoPackage.sanitizeIdentifier($0) }.joined(separator: ", ")))
                VALUES (\(rowId), X'\(blobHex)', '\(ctEsc)'\(userStr));
                """)
        }
    }

}
