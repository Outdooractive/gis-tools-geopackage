import Foundation
@testable import GISTools
@testable import GISToolsGeoPackage
import Testing

struct GeoPackageAttributeTableTests {

    @Test
    func attributeValuesKeepTypes() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let table = AttributeTable(
            tableName: "values",
            columns: ["text", "integer", "double", "boolean", "base64ish", "blob"],
            rows: [[
                "text": "hello",
                "integer": 42,
                "double": 1.5,
                "boolean": true,
                "base64ish": "Test",
                "blob": Data([0x01, 0x02]),
            ]],
            rowIds: [1])
        try GeoPackage.writeAttributeTable(table, to: url)

        let read = try GeoPackage.readAttributeTable(from: url, table: "values")
        let row = try #require(read.rows.first)
        #expect(row["text"] as? String == "hello")
        #expect(row["integer"] as? Int == 42)
        #expect(row["double"] as? Double == 1.5)
        #expect(row["boolean"] as? Bool == true)
        #expect(row["base64ish"] as? String == "Test")
        #expect(row["blob"] as? String == Data([0x01, 0x02]).base64EncodedString())

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let info = try db.query("PRAGMA table_info(\"values\");")
        let pairs: [(String, String)] = info.compactMap { column in
            guard let name = column["name"] as? String,
                  let type = column["type"] as? String
            else { return nil }

            return (name, type.uppercased())
        }
        let types = Dictionary(uniqueKeysWithValues: pairs)
        #expect(types["integer"] == "INTEGER")
        #expect(types["double"] == "REAL")
        #expect(types["boolean"] == "BOOLEAN")
        #expect(types["blob"] == "BLOB")
    }

    @Test
    func attributeTableWithNoUserColumns() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let table = AttributeTable(
            tableName: "empty_columns",
            columns: [],
            rows: [[:], [:]],
            rowIds: [1, 2])
        try GeoPackage.writeAttributeTable(table, to: url)

        let read = try GeoPackage.readAttributeTable(
            from: url,
            table: "empty_columns")
        #expect(read.columns.isEmpty)
        #expect(read.rowIds == [1, 2])
        #expect(read.rows.count == 2)
    }

    @Test
    func attributeTableRewriteReplacesRowsAndAddsColumns() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try GeoPackage.writeAttributeTable(
            AttributeTable(
                tableName: "info",
                columns: ["label"],
                rows: [["label": "old"], ["label": "removed"]],
                rowIds: [1, 2]),
            to: url)

        try GeoPackage.writeAttributeTable(
            AttributeTable(
                tableName: "info",
                columns: ["label", "extra"],
                rows: [["label": "new", "extra": 7]],
                rowIds: [1]),
            to: url)

        let read = try GeoPackage.readAttributeTable(from: url, table: "info")
        #expect(read.rowIds == [1])
        #expect(read.rows.first?["label"] as? String == "new")
        #expect(read.rows.first?["extra"] as? Int == 7)
    }

    @Test
    func attributeTableFilteredByRowID() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try GeoPackage.writeAttributeTable(
            AttributeTable(
                tableName: "info",
                columns: ["label"],
                rows: [["label": "one"], ["label": "two"]],
                rowIds: [1, 2]),
            to: url)

        let read = try GeoPackage.readAttributeTable(
            from: url,
            table: "info",
            rowId: 2)
        #expect(read.rowIds == [2])
        #expect(read.rows.first?["label"] as? String == "two")
    }

    @Test
    func attributeReservedIDColumnThrows() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        #expect(throws: GeoPackageError.self) {
            try GeoPackage.writeAttributeTable(
                AttributeTable(
                    tableName: "info",
                    columns: ["id"],
                    rows: [["id": 1]],
                    rowIds: [1]),
                to: url)
        }
    }

    @Test
    func attributeCaseInsensitiveColumnsThrow() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        #expect(throws: GeoPackageError.self) {
            try GeoPackage.writeAttributeTable(
                AttributeTable(
                    tableName: "info",
                    columns: ["Name", "name"],
                    rows: [["Name": 1, "name": 2]],
                    rowIds: [1]),
                to: url)
        }
    }

    @Test
    func attributeIDColumnIsDetectedCaseInsensitively() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        try db.execute("""
        CREATE TABLE "upper" (
            "ID" INTEGER PRIMARY KEY AUTOINCREMENT,
            "label" TEXT
        );
        """)
        try db.execute("INSERT INTO \"upper\" (\"ID\", \"label\") VALUES (7, 'seven');")
        db.close()

        let read = try GeoPackage.readAttributeTable(from: url, table: "upper")
        #expect(read.rowIds == [7])
        #expect(read.rows.first?["label"] as? String == "seven")
        #expect(read.columns == ["label"])
    }

    @Test
    func readingMissingAttributeTableThrows() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        #expect(throws: GeoPackageError.self) {
            _ = try GeoPackage.readAttributeTable(from: url, table: "missing")
        }
    }

}

struct GeoPackageMediaTableTests {

    @Test
    func mediaRewriteReplacesRowsAndAddsColumns() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try GeoPackage.writeMediaTable(
            MediaTable(
                tableName: "photos",
                rowIds: [1, 2],
                data: [Data([1]), Data([2])],
                contentTypes: ["image/png", "image/jpeg"],
                properties: [["caption": "a"], ["caption": "b"]]),
            to: url)

        try GeoPackage.writeMediaTable(
            MediaTable(
                tableName: "photos",
                rowIds: [1],
                data: [Data([9])],
                contentTypes: ["image/webp"],
                properties: [["caption": "new", "width": 100]]),
            to: url)

        let read = try GeoPackage.readMediaTable(from: url, table: "photos")
        #expect(read.rowIds == [1])
        #expect(read.data == [Data([9])])
        #expect(read.contentTypes == ["image/webp"])
        #expect(read.properties.first?["caption"] as? String == "new")
        #expect(read.properties.first?["width"] as? Int == 100)
    }

    @Test
    func mediaArrayLengthMismatchThrows() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        #expect(throws: GeoPackageError.self) {
            try GeoPackage.writeMediaTable(
                MediaTable(
                    tableName: "photos",
                    rowIds: [1, 2],
                    data: [Data([1])],
                    contentTypes: ["image/png"]),
                to: url)
        }
    }

    @Test
    func emptyMediaTableIsCreated() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try GeoPackage.writeMediaTable(
            MediaTable(
                tableName: "photos",
                rowIds: [],
                data: [],
                contentTypes: []),
            to: url)

        let read = try GeoPackage.readMediaTable(from: url, table: "photos")
        #expect(read.isEmpty)
    }

    @Test
    func mediaMetadataColumnCollisionThrows() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        for key in ["id", "data", "content_type"] {
            #expect(throws: GeoPackageError.self) {
                try GeoPackage.writeMediaTable(
                    MediaTable(
                        tableName: "photos",
                        rowIds: [1],
                        data: [Data([1])],
                        contentTypes: ["image/png"],
                        properties: [[key: "value"]]),
                    to: url)
            }
        }
    }

    @Test
    func malformedMediaRowThrows() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        // The real schema has NOT NULL constraints; this deliberately broken
        // table reproduces a malformed third-party media table.
        try db.execute("""
        CREATE TABLE photos (
            id INTEGER PRIMARY KEY,
            data BLOB,
            content_type TEXT
        );
        """)
        try db.execute("""
        INSERT INTO photos (id, data, content_type)
        VALUES (1, NULL, 'image/png');
        """)
        db.close()

        #expect(throws: GeoPackageError.self) {
            _ = try GeoPackage.readMediaTable(from: url, table: "photos")
        }
    }

    @Test
    func mediaColumnsAreDetectedCaseInsensitively() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        try db.execute("""
        CREATE TABLE "upper_media" (
            "ID" INTEGER PRIMARY KEY AUTOINCREMENT,
            "DATA" BLOB,
            "CONTENT_TYPE" TEXT,
            "caption" TEXT
        );
        """)
        try db.execute("""
        INSERT INTO "upper_media" ("ID", "DATA", "CONTENT_TYPE", "caption")
        VALUES (3, X'0102', 'image/png', 'three');
        """)
        db.close()

        let read = try GeoPackage.readMediaTable(
            from: url,
            table: "upper_media")
        #expect(read.rowIds == [3])
        #expect(read.data == [Data([1, 2])])
        #expect(read.contentTypes == ["image/png"])
        #expect(read.properties.first?["caption"] as? String == "three")

        let rows = try GeoPackage.readMediaRows(
            from: url,
            table: "upper_media",
            rowId: 3)
        #expect(rows.count == 1)
    }

    @Test
    func missingMediaColumnsThrow() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        try db.execute("CREATE TABLE bad_media (id INTEGER PRIMARY KEY, x TEXT);")
        db.close()

        #expect(throws: GeoPackageError.self) {
            _ = try GeoPackage.readMediaTable(from: url, table: "bad_media")
        }
    }

}

struct GeoPackageRelationshipEdgeTests {

    @Test
    func registrationIsIdempotent() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        try GeoPackage.registerRelatedTablesExtension(in: db)
        try GeoPackage.registerRelatedTablesExtension(in: db)
        try GeoPackage.registerRelatedTablesExtension(in: db)

        let rows = try db.query(
            "SELECT count(*) AS cnt FROM gpkg_extensions"
                + " WHERE extension_name = 'gpkgext_relations';")
        #expect(rows.first?["cnt"] as? Int == 1)
        db.close()
    }

    @Test
    func writingSameRelationshipReplacesIt() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        try GeoPackage.writeRelation(
            RelationRow(
                id: "r1",
                tableName: "features",
                relatedTableName: "info",
                relationName: .attributes),
            in: db)
        try GeoPackage.writeRelation(
            RelationRow(
                id: "r1",
                tableName: "features",
                relatedTableName: "other_info",
                relationName: .media),
            in: db)

        let relations = try GeoPackage.readRelations(in: db)
        #expect(relations.count == 1)
        #expect(relations[0].relatedTableName == "other_info")
        #expect(relations[0].relationName == .media)
        db.close()
    }

    @Test
    func readingRelationsWithoutExtensionReturnsEmpty() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        try db.execute("DROP TABLE gpkgext_relations;")

        let relations = try GeoPackage.readRelations(in: db)
        #expect(relations.isEmpty)
        db.close()
    }

    @Test
    func writingRelationshipCreatesMissingExtensionTable() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        try db.execute("DROP TABLE gpkgext_relations;")
        db.close()

        let gpkg = try GeoPackageConnection(url: url)
        try await gpkg.write(relation: RelationRow(
            id: "r1",
            tableName: "features",
            relatedTableName: "info",
            relationName: .attributes))
        let relations = try await gpkg.readRelations()
        await gpkg.close()

        #expect(relations.map(\.id) == ["r1"])
    }

    @Test
    func relatedLookupsWithoutRelationshipReturnEmpty() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
        ]).writeGeopackage(to: url)

        let gpkg = try GeoPackageConnection(url: url)
        let collection = try await FeatureCollection(geopackage: url)
        let feature = try #require(collection.features.first)
        let attributes = try await feature.relatedAttributes(in: gpkg)
        let media = try await feature.relatedMedia(in: gpkg)
        await gpkg.close()

        #expect(attributes.isEmpty)
        #expect(media.isEmpty)
    }

}
