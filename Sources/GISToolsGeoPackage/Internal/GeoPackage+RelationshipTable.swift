import Foundation
import GISTools

extension GeoPackage {

    /// Reads all relationship rows from a GeoPackage file.
    ///
    /// - Parameter url: The GeoPackage file URL.
    /// - Returns: The registered relationships, or an empty array when the
    ///   Related Tables Extension is not present.
    public static func readRelations(from url: URL) throws -> [RelationRow] {
        let db = try SQLiteDB(path: url.path, readOnly: true)
        defer { db.close() }
        return try readRelations(in: db)
    }

    /// Returns all relationship rows from `gpkgext_relations`.
    ///
    /// The Related Tables Extension is optional. A GeoPackage without the
    /// extension table has no relationships and returns an empty array rather
    /// than an SQLite error.
    static func readRelations(in db: SQLiteDB) throws -> [RelationRow] {
        guard try tableExists("gpkgext_relations", in: db) else {
            return []
        }

        let rows = try db.query(
            "SELECT id, table_name, column_name, related_table_name,"
            + " related_column_name, relation_name, mapping_table_name"
            + " FROM gpkgext_relations;")

        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let tableName = row["table_name"] as? String,
                  let columnName = row["column_name"] as? String,
                  let relatedTable = row["related_table_name"] as? String,
                  let relatedCol = row["related_column_name"] as? String,
                  let relationRaw = row["relation_name"] as? String,
                  let relationName = RelationshipType(rawValue: relationRaw)
            else { return nil }

            return RelationRow(
                id: id,
                tableName: tableName,
                columnName: columnName,
                relatedTableName: relatedTable,
                relatedColumnName: relatedCol,
                relationName: relationName,
                mappingTableName: row["mapping_table_name"] as? String)
        }
    }

    /// Inserts a relation row into `gpkgext_relations`.
    static func writeRelation(
        _ relation: RelationRow,
        in db: SQLiteDB
    ) throws {
        try createRelationsTableIfNeeded(in: db)
        try db.execute(
            """
            INSERT OR REPLACE INTO gpkgext_relations
            (id, table_name, column_name, related_table_name,
             related_column_name, relation_name, mapping_table_name)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            values: [
                relation.id,
                relation.tableName,
                relation.columnName,
                relation.relatedTableName,
                relation.relatedColumnName,
                relation.relationName.rawValue,
                relation.mappingTableName,
            ])
    }

    /// Registers the Related Tables Extension in `gpkg_extensions`.
    ///
    /// Registration is idempotent. `gpkg_extensions` has a UNIQUE constraint
    /// that includes nullable columns, and SQLite treats `NULL`s as distinct,
    /// so `INSERT OR IGNORE` alone would insert a new row on every call.
    static func registerRelatedTablesExtension(in db: SQLiteDB) throws {
        try createRelationsTableIfNeeded(in: db)

        let existing = try db.query(
            """
            SELECT 1 FROM gpkg_extensions
            WHERE extension_name = 'gpkgext_relations'
              AND table_name IS NULL
              AND column_name IS NULL
            LIMIT 1;
            """)
        guard existing.isEmpty else { return }

        try db.execute("""
            INSERT INTO gpkg_extensions
            (table_name, column_name, extension_name, definition, scope)
            VALUES (NULL, NULL,
            'gpkgext_relations',
            'http://www.geopackage.org/18-000.html',
            'read-write');
            """)
    }

    /// Creates `gpkgext_relations` when it is missing from an existing
    /// GeoPackage. `createMetadata(in:)` creates it for packages written by
    /// this library, but third-party packages may omit the optional extension
    /// table.
    private static func createRelationsTableIfNeeded(in db: SQLiteDB) throws {
        guard try !tableExists("gpkgext_relations", in: db) else { return }

        try db.execute("""
            CREATE TABLE gpkgext_relations (
                id TEXT NOT NULL PRIMARY KEY,
                table_name TEXT NOT NULL,
                column_name TEXT NOT NULL,
                related_table_name TEXT NOT NULL,
                related_column_name TEXT NOT NULL,
                relation_name TEXT NOT NULL,
                mapping_table_name TEXT
            );
            """)
    }

}
