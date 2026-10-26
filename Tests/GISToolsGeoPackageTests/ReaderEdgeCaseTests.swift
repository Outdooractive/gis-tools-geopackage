import Foundation
@testable import GISTools
@testable import GISToolsGeoPackage
import Testing

struct GeoPackageReaderEdgeCaseTests {

    @Test
    func unlocatedFeatureRoundTrip() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let feature = Feature(
            id: .string("unlocated"),
            properties: ["name": "no geometry"])
        try await FeatureCollection([feature]).writeGeopackage(to: url)

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.count == 1)
        let result = try #require(read.features.first)
        #expect(result.geometry == nil)
        #expect(result.id == .string("unlocated"))
        #expect(result.properties["name"] as? String == "no geometry")
        #expect(result.gpkgRowId == 1)
        #expect(result.gpkgTableName == "features")

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        #expect(try TestSupport.scalar(
            "SELECT srs_id FROM gpkg_contents WHERE table_name = 'features';",
            from: db) as? Int == 0)
        #expect(try TestSupport.scalar(
            "SELECT min_x FROM gpkg_contents WHERE table_name = 'features';",
            from: db) == nil)
        #expect(try TestSupport.scalar(
            "SELECT geometry_type_name FROM gpkg_geometry_columns"
                + " WHERE table_name = 'features';",
            from: db) as? String == "GEOMETRY")
    }

    @Test
    func rtreeSkipsUnlocatedFeatures() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let features = [
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
            Feature(id: .int(2), properties: ["name": "null geometry"]),
            Feature(Point(Coordinate3D(latitude: 10.0, longitude: 10.0))),
        ]
        try await FeatureCollection(features)
            .writeGeopackage(to: url, createSpatialIndex: true)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let fids = try db.query("SELECT fid FROM features ORDER BY fid;")
            .compactMap { $0["fid"] as? Int }
        let rtreeIds = try db.query(
            "SELECT id FROM \"rtree_features_geom\" ORDER BY id;")
            .compactMap { $0["id"] as? Int }
        #expect(fids == [1, 2, 3])
        #expect(rtreeIds == [1, 3])

        let all = try await FeatureCollection(geopackage: url)
        #expect(all.features.count == 3)
        #expect(all.features[1].geometry == nil)
    }

    @Test
    func boundingBoxWithoutMatchesReturnsEmptyEvenWithRTree() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
        ]).writeGeopackage(to: url, createSpatialIndex: true)

        let farAway = BoundingBox(
            southWest: Coordinate3D(latitude: 80.0, longitude: 170.0),
            northEast: Coordinate3D(latitude: 85.0, longitude: 175.0))
        let read = try await FeatureCollection(
            geopackage: url,
            boundingBox: farAway)
        #expect(read.features.isEmpty)
    }

    @Test
    func boundingBoxWithoutIndexStillPaginatesFilteredResults() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        // Every second point is inside the box. Without an index the filter
        // must be applied before LIMIT/OFFSET.
        var features: [Feature] = []
        for index in 0 ..< 10 {
            let latitude = index.isMultiple(of: 2) ? 0.5 : 50.0
            features.append(Feature(Point(Coordinate3D(
                latitude: latitude,
                longitude: Double(index)))))
        }
        try await FeatureCollection(features)
            .writeGeopackage(to: url, createSpatialIndex: false)

        let box = BoundingBox(
            southWest: Coordinate3D(latitude: 0.0, longitude: -1.0),
            northEast: Coordinate3D(latitude: 1.0, longitude: 100.0))

        let db = try SQLiteDB(path: url.path)
        let firstPage = try GeoPackageReader.readFeatures(
            from: db,
            table: "features",
            boundingBox: box,
            limit: 2,
            offset: 0)
        let secondPage = try GeoPackageReader.readFeatures(
            from: db,
            table: "features",
            boundingBox: box,
            limit: 2,
            offset: 2)
        db.close()

        #expect(firstPage.count == 2)
        #expect(secondPage.count == 2)
        #expect(firstPage.map(\.gpkgRowId) == [1, 3])
        #expect(secondPage.map(\.gpkgRowId) == [5, 7])
    }

    @Test
    func paginationIsStableAndOrderedByRowID() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let features = (0 ..< 5).map { index in
            Feature(Point(Coordinate3D(
                latitude: Double(index),
                longitude: Double(index))))
        }
        try await FeatureCollection(features).writeGeopackage(to: url)

        let gpkg = try GeoPackageConnection(url: url)
        let page1 = try await gpkg.readFeatures(table: "features", limit: 2)
        let page2 = try await gpkg.readFeatures(
            table: "features",
            limit: 2,
            offset: 2)
        let page3 = try await gpkg.readFeatures(
            table: "features",
            limit: 2,
            offset: 4)
        await gpkg.close()

        #expect(page1.compactMap(\.gpkgRowId) == [1, 2])
        #expect(page2.compactMap(\.gpkgRowId) == [3, 4])
        #expect(page3.compactMap(\.gpkgRowId) == [5])
    }

    @Test
    func invalidPaginationArgumentsThrow() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await FeatureCollection([
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
        ]).writeGeopackage(to: url)

        let gpkg = try GeoPackageConnection(url: url)
        await #expect(throws: GeoPackageError.self) {
            try await gpkg.readFeatures(table: "features", limit: -1)
        }
        await #expect(throws: GeoPackageError.self) {
            try await gpkg.readFeatures(
                table: "features",
                limit: 1,
                offset: -1)
        }
        await gpkg.close()
    }

    @Test
    func malformedGeometryBlobThrows() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
        ]).writeGeopackage(to: url)

        let db = try SQLiteDB(path: url.path)
        try db.execute(
            "UPDATE features SET geom = ?;",
            values: [Data([0x47, 0x50, 0x00, 0x02, 0x00])])
        db.close()

        await #expect(throws: GeoPackageError.self) {
            try await FeatureCollection(geopackage: url)
        }
    }

    @Test
    func missingTableThrowsTableNotFound() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
        ]).writeGeopackage(to: url)

        let gpkg = try GeoPackageConnection(url: url)
        await #expect(throws: GeoPackageError.self) {
            try await gpkg.readFeatures(table: "does_not_exist")
        }
        await gpkg.close()
    }

    @Test
    func readingMissingFileDoesNotCreateIt() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))

        await #expect(throws: GeoPackageError.self) {
            try await FeatureCollection(geopackage: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))

        #expect(throws: GeoPackageError.self) {
            _ = try GeoPackage.validate(url: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func emptyDatabaseIsReportedAsInvalid() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        db.close()

        let validation = try GeoPackage.validate(url: url)
        #expect(!validation.isValid)
        #expect(validation.errors.contains(.invalidApplicationId))
        #expect(validation.errors.contains(
            .missingMandatoryTable("gpkg_spatial_ref_sys")))

        await #expect(throws: GeoPackageError.self) {
            try await FeatureCollection(geopackage: url)
        }
    }

    @Test
    func nonSQLiteFileThrowsInsteadOfCrashing() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try Data("not a database".utf8).write(to: url)

        #expect(throws: GeoPackageError.self) {
            _ = try GeoPackage.validate(url: url)
        }
    }

    @Test
    func metadataOnlyPackageIsValidButEmpty() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        db.close()

        let validation = try GeoPackage.validate(url: url)
        #expect(validation.isValid)
        #expect(validation.warnings.contains(.emptyContentsTable))

        let contents = try GeoPackage.readContents(from: url)
        #expect(contents.isEmpty)
    }

    @Test
    func malformedSRSStructureIsReportedWithoutThrowing() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        try db.execute("DROP TABLE gpkg_spatial_ref_sys;")
        try db.execute("""
        CREATE TABLE gpkg_spatial_ref_sys (
            srs_name TEXT NOT NULL,
            organization TEXT NOT NULL
        );
        """)
        db.close()

        let validation = try GeoPackage.validate(url: url)
        #expect(!validation.isValid)
        #expect(validation.errors.contains(
            .missingRequiredColumn("gpkg_spatial_ref_sys", "srs_id")))
    }

    @Test
    func contentsBoundsPreserveProjection() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(Point(Coordinate3D.epsg3857(
                x: 1_288_000.0,
                y: 6_120_000.0))),
        ]).writeGeopackage(to: url)

        let tables = try GeoPackage.readContents(from: url)
        let table = try #require(tables.first)
        #expect(table.srsId == 3857)
        #expect(table.bounds?.projection == .epsg3857)
        #expect(abs((table.bounds?.southWest.x ?? 0.0) - 1_288_000.0) < 0.001)
    }

    @Test
    func featureExposesRowIDAndTableName() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(
                Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
                id: .string("a")),
            Feature(
                Point(Coordinate3D(latitude: 1.0, longitude: 1.0)),
                id: .string("b")),
        ]).writeGeopackage(to: url)

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.map(\.gpkgRowId) == [1, 2])
        #expect(read.features.map(\.gpkgTableName) == ["features", "features"])
        #expect(read.features.map(\.id) == [.string("a"), .string("b")])
    }

}

// MARK: - WKB header

struct WKBHeaderTests {

    @Test
    func prependAndParseRoundTrip() throws {
        let point = Point(Coordinate3D(latitude: 1.5, longitude: 2.5))
        let wkb = try #require(WKBCoder.encode(
            geometry: point,
            targetProjection: .epsg3857))
        let envelope = BoundingBox(
            southWest: Coordinate3D.epsg3857(x: 1.0, y: 2.0),
            northEast: Coordinate3D.epsg3857(x: 3.0, y: 4.0))

        let blob = WKBHeader.prependHeader(
            to: wkb,
            srid: 3857,
            envelope: envelope)
        let parsed = try WKBHeader.parse(blob)

        #expect(parsed.srid == 3857)
        #expect(parsed.isEmpty == false)
        #expect(parsed.envelope?.projection == .epsg3857)
        #expect(parsed.envelope?.southWest.x == 1.0)
        #expect(parsed.envelope?.northEast.y == 4.0)
    }

    @Test
    func emptyFlagIsIndependentOfEnvelope() throws {
        let wkb = try #require(WKBCoder.encode(
            geometry: Point(Coordinate3D(latitude: 0.0, longitude: 0.0))))
        let blob = WKBHeader.prependHeader(
            to: wkb,
            srid: 4326,
            envelope: nil,
            isEmpty: true)

        #expect(blob[3] & 0x01 == 0x01, "Little-endian header")
        #expect(blob[3] & 0x10 == 0x10, "Empty flag")
        #expect((blob[3] >> 1) & 0x07 == 0)
        #expect(try WKBHeader.parse(blob).isEmpty)
    }

    @Test
    func parsesBigEndianHeader() throws {
        let point = Point(Coordinate3D(latitude: 1.0, longitude: 2.0))
        let wkb = try #require(WKBCoder.encode(
            geometry: point,
            targetProjection: .epsg4326))

        // byte order 0 (big endian), envelope indicator 1.
        var blob = Data([0x47, 0x50, 0x00, 0x02])
        blob.append(contentsOf: [0x00, 0x00, 0x0F, 0x11]) // 3857
        for value in [2.0, 2.0, 1.0, 1.0] { // minx, maxx, miny, maxy
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { blob.append(contentsOf: $0) }
        }
        blob.append(wkb)

        let parsed = try WKBHeader.parse(blob)
        #expect(parsed.srid == 3857)
        #expect(parsed.envelope?.southWest.longitude == 2.0)
        #expect(parsed.envelope?.southWest.latitude == 1.0)
    }

    @Test
    func detectsZAndMFromWKBType() throws {
        let coordinate = Coordinate3D(
            latitude: 1.0,
            longitude: 2.0,
            altitude: 100.0,
            m: 5.0)
        let point = Point(coordinate)
        let wkb = try #require(WKBCoder.encode(
            geometry: point,
            targetProjection: .epsg4326))
        let blob = WKBHeader.prependHeader(to: wkb, srid: 4326, envelope: nil)
        let parsed = try WKBHeader.parse(blob)
        #expect(parsed.hasZ)
        #expect(parsed.hasM)
    }

    @Test
    func rejectsInvalidMagicAndTruncatedData() {
        #expect(throws: GeoPackageError.self) {
            try WKBHeader.parse(Data([0x00, 0x00, 0x00, 0x00]))
        }
        #expect(throws: GeoPackageError.self) {
            try WKBHeader.parse(Data([
                0x47,
                0x50,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
            ]))
        }
        #expect(throws: GeoPackageError.self) {
            try WKBHeader.parse(Data([
                0x47,
                0x50,
                0x00,
                0x02,
                0x00,
                0x00,
                0x00,
                0x00,
            ]))
        }
    }

}
