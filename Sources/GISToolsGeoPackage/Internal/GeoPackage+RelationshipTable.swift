import Foundation
import GISTools

extension GeoPackage {

    /// Returns all relationship rows from `gpkgext_relations`.
    static func readRelations(in db: SQLiteDB) throws -> [RelationRow] {
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
        let escapedId = GeoPackage.sanitizeStringLiteral(relation.id)
        let escapedTable = GeoPackage.sanitizeStringLiteral(relation.tableName)
        let escapedCol = GeoPackage.sanitizeStringLiteral(relation.columnName)
        let escapedRelated = GeoPackage.sanitizeStringLiteral(relation.relatedTableName)
        let escapedRelCol = GeoPackage.sanitizeStringLiteral(relation.relatedColumnName)
        let escapedRelName = GeoPackage.sanitizeStringLiteral(relation.relationName.rawValue)
        let mapping = relation.mappingTableName.map {
            GeoPackage.sanitizeStringLiteral($0)
        } ?? "NULL"

        try db.execute("""
            INSERT INTO gpkgext_relations
            (id, table_name, column_name, related_table_name,
             related_column_name, relation_name, mapping_table_name)
            VALUES (\(escapedId), \(escapedTable), \(escapedCol),
            \(escapedRelated), \(escapedRelCol), \(escapedRelName), \(mapping));
            """)
    }

    /// Registers the Related Tables Extension in `gpkg_extensions`.
    static func registerRelatedTablesExtension(in db: SQLiteDB) throws {
        try db.execute("""
            INSERT OR IGNORE INTO gpkg_extensions
            (table_name, column_name, extension_name, definition, scope)
            VALUES (NULL, NULL,
            'gpkgext_relations',
            'http://www.geopackage.org/spec/related_tables',
            'read-write');
            """)
    }

}
