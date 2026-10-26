import Foundation
@testable import GISTools
@testable import GISToolsGeoPackage
import Testing

struct GeoPackageConnectionTests {

    private func makePackage(at url: URL) async throws {
        try await FeatureCollection([
            Feature(Point(Coordinate3D(latitude: 1.0, longitude: 2.0))),
        ]).writeGeopackage(to: url, createSpatialIndex: true)
    }

    @Test
    func featureAndTileTableLists() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makePackage(at: url)

        let gpkg = try GeoPackageConnection(url: url)
        let featureTables = try await gpkg.featureTables()
        let tileTables = try await gpkg.tileTables()
        let hasIndex = try await gpkg.hasRTreeIndex(
            for: "features",
            column: "geom")
        await gpkg.close()

        #expect(featureTables.map(\.tableName) == ["features"])
        #expect(tileTables.isEmpty)
        #expect(hasIndex)
    }

    @Test
    func readOnlyConnectionRejectsWrites() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makePackage(at: url)

        let gpkg = try GeoPackageConnection(url: url, readOnly: true)
        await #expect(throws: GeoPackageError.self) {
            try await gpkg.write(
                features: FeatureCollection([
                    Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
                ]),
                to: "features")
        }
        await gpkg.close()
    }

    @Test
    func readOnlyConnectionDoesNotCreateMissingFile() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        #expect(throws: GeoPackageError.self) {
            _ = try GeoPackageConnection(url: url, readOnly: true)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func closeIsIdempotentAndOperationsAfterCloseThrow() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makePackage(at: url)

        let gpkg = try GeoPackageConnection(url: url)
        await gpkg.close()
        await gpkg.close()

        await #expect(throws: GeoPackageError.self) {
            _ = try await gpkg.readFeatures(table: "features")
        }
    }

    @Test
    func createMetadataIsIdempotentAndSRSRowsAreStable() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let gpkg = try GeoPackageConnection(url: url, skipValidation: true)
        try await gpkg.createMetadata()
        try await gpkg.createMetadata()
        let validation = try await gpkg.validate()
        await gpkg.close()

        #expect(validation.isValid)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let counts = try db.query(
            "SELECT srs_id, count(*) AS cnt FROM gpkg_spatial_ref_sys"
                + " GROUP BY srs_id HAVING cnt > 1;")
        #expect(counts.isEmpty)

        for srsId in [4326, 3857, 4978, 0, -1] {
            let count = try TestSupport.scalar(
                "SELECT count(*) FROM gpkg_spatial_ref_sys WHERE srs_id = ?;",
                from: db,
                values: [srsId]) as? Int
            #expect(count == 1)
        }
    }

    @Test
    func createdSchemaMatchesGeoPackage12() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)

        let applicationId = try TestSupport.scalar(
            "PRAGMA application_id;",
            from: db) as? Int
        #expect(applicationId == Int(GeoPackage.applicationIdGPKG))

        let srsInfo = try db.query("PRAGMA table_info(gpkg_spatial_ref_sys);")
        let srsColumns = srsInfo.compactMap { $0["name"] as? String }
        #expect(
            !srsColumns.contains("srs_type"),
            "GeoPackage 1.2 has no srs_type column",
        )

        let contentsInfo = try db.query("PRAGMA table_info(gpkg_contents);")
        let identifier = contentsInfo.first {
            $0["name"] as? String == "identifier"
        }
        #expect(identifier != nil)

        // identifier is UNIQUE per the specification.
        #expect(throws: GeoPackageError.self) {
            try db.execute("""
            INSERT INTO gpkg_contents (table_name, data_type, identifier)
            VALUES ('a', 'attributes', 'same');
            """)
            try db.execute("""
            INSERT INTO gpkg_contents (table_name, data_type, identifier)
            VALUES ('b', 'attributes', 'same');
            """)
        }
        db.close()
    }

    @Test
    func legacySRSTypeSchemaIsStillWritable() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        // Reproduce the schema created by earlier versions of this library.
        try db.execute("""
        CREATE TABLE gpkg_spatial_ref_sys (
            srs_id INTEGER PRIMARY KEY,
            srs_name TEXT NOT NULL,
            srs_type TEXT NOT NULL,
            organization TEXT NOT NULL,
            organization_coordsys_id INTEGER NOT NULL,
            definition TEXT NOT NULL,
            description TEXT
        );
        """)
        try GeoPackage.createMetadata(in: db)
        try GeoPackage.ensureSrsRow(32632, in: db)

        let rows = try db.query(
            "SELECT count(*) AS cnt FROM gpkg_spatial_ref_sys;")
        #expect((rows.first?["cnt"] as? Int ?? 0) >= 5)
        db.close()
    }

    @Test
    func pathBasedConnectionWorks() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makePackage(at: url)

        let gpkg = try GeoPackageConnection(path: url.path)
        let contents = try await gpkg.readContents()
        await gpkg.close()
        #expect(contents.count == 1)
    }

    @Test
    func writeAttributeAndMediaTablesThroughConnection() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let gpkg = try GeoPackageConnection(url: url, skipValidation: true)
        try await gpkg.createMetadata()

        let attribute = AttributeTable(
            tableName: "info",
            columns: ["label"],
            rows: [["label": "one"]],
            rowIds: [1])
        try await gpkg.write(attributeTable: attribute)

        let media = MediaTable(
            tableName: "photos",
            rowIds: [1],
            data: [Data([1, 2, 3])],
            contentTypes: ["application/octet-stream"],
            properties: [["caption": "picture"]])
        try await gpkg.write(mediaTable: media)

        let readAttribute = try await gpkg.readAttributeTable(table: "info")
        let readMedia = try await gpkg.readMediaTable(table: "photos")
        await gpkg.close()

        #expect(readAttribute.rows.first?["label"] as? String == "one")
        #expect(readMedia.data.first == Data([1, 2, 3]))
        #expect(readMedia.properties.first?["caption"] as? String == "picture")
    }

    @Test
    func tileMapTileOverloadsMatchTileKey() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let gpkg = try GeoPackageConnection(url: url, skipValidation: true)
        try await gpkg.createMetadata()
        try await gpkg.createTileTable("tiles")

        let data = Data([9, 8, 7])
        let mapTile = MapTile(x: 1, y: 0, z: 2)
        try await gpkg.write(
            tileData: data,
            for: mapTile,
            matrixHeight: 4,
            to: "tiles")

        let byMapTile = try await gpkg.readTile(
            for: mapTile,
            matrixHeight: 4,
            from: "tiles")
        let byKey = try await gpkg.readTile(
            for: TileKey(zoom: 2, column: 1, row: 3),
            from: "tiles")
        await gpkg.close()

        #expect(byMapTile == data)
        #expect(byKey == data)
    }

}
