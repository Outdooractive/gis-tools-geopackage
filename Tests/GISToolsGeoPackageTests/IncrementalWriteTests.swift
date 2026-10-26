import Foundation
@testable import GISTools
@testable import GISToolsGeoPackage
import Testing

struct GeoPackageIncrementalWriteTests {

    private func point(
        _ latitude: Double,
        _ longitude: Double,
        id: Feature.Identifier? = nil,
        properties: [String: Sendable] = [:],
    ) -> Feature {
        Feature(
            Point(Coordinate3D(latitude: latitude, longitude: longitude)),
            id: id,
            properties: properties)
    }

    @Test
    func appendingFeaturesKeepsSingleTableAndUpdatesBounds() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            point(0.0, 0.0, id: .int(1), properties: ["name": "a"]),
            point(1.0, 1.0, id: .int(2), properties: ["name": "b"]),
        ]).writeGeopackage(to: url, createSpatialIndex: true)

        try await FeatureCollection([
            point(10.0, 10.0, id: .int(3), properties: ["name": "c"]),
            point(-5.0, -5.0, id: .int(4), properties: ["name": "d"]),
        ]).writeGeopackage(to: url)

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.count == 4)
        #expect(read.features.compactMap(\.id) == [.int(1), .int(2), .int(3), .int(4)])

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let bounds = try db.query(
            "SELECT min_x, min_y, max_x, max_y FROM gpkg_contents"
                + " WHERE table_name = 'features';")
        let row = try #require(bounds.first)
        #expect(row["min_x"] as? Double == -5.0)
        #expect(row["min_y"] as? Double == -5.0)
        #expect(row["max_x"] as? Double == 10.0)
        #expect(row["max_y"] as? Double == 10.0)

        let rtreeIds = try db.query(
            "SELECT id FROM \"rtree_features_geom\" ORDER BY id;")
            .compactMap { $0["id"] as? Int }
        #expect(rtreeIds == [1, 2, 3, 4])
    }

    @Test
    func appendingAddsNewPropertyColumns() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            point(0.0, 0.0, properties: ["name": "first"]),
        ]).writeGeopackage(to: url)

        try await FeatureCollection([
            point(1.0, 1.0, properties: ["name": "second", "elevation": 1200]),
        ]).writeGeopackage(to: url)

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.count == 2)
        #expect(read.features[0].properties["elevation"] == nil)
        #expect(read.features[1].properties["elevation"] as? Int == 1200)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let info = try db.query("PRAGMA table_info(features);")
        let names = info.compactMap { $0["name"] as? String }
        #expect(names.contains("elevation"))
    }

    @Test
    func appendingMaintainsAnExistingRTreeEvenWhenNotRequested() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            point(0.0, 0.0),
        ]).writeGeopackage(to: url, createSpatialIndex: true)

        // createSpatialIndex is false, but the existing index must not go
        // stale.
        try await FeatureCollection([
            point(10.0, 10.0),
        ]).writeGeopackage(to: url, createSpatialIndex: false)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let rtreeIds = try db.query(
            "SELECT id FROM \"rtree_features_geom\" ORDER BY id;")
            .compactMap { $0["id"] as? Int }
        #expect(rtreeIds == [1, 2])
    }

    @Test
    func creatingAnIndexOnAnExistingTableIndexesExistingRows() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            point(0.0, 0.0),
        ]).writeGeopackage(to: url, createSpatialIndex: false)

        try await FeatureCollection([
            point(10.0, 10.0),
        ]).writeGeopackage(to: url, createSpatialIndex: true)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let rtreeIds = try db.query(
            "SELECT id FROM \"rtree_features_geom\" ORDER BY id;")
            .compactMap { $0["id"] as? Int }
        #expect(rtreeIds == [1, 2])
    }

    @Test
    func geometryTypeMismatchOnAppendRollsBack() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            point(0.0, 0.0),
        ]).writeGeopackage(to: url)

        let polygon = try #require(Polygon([[
            Coordinate3D(latitude: 0.0, longitude: 0.0),
            Coordinate3D(latitude: 1.0, longitude: 0.0),
            Coordinate3D(latitude: 1.0, longitude: 1.0),
            Coordinate3D(latitude: 0.0, longitude: 0.0),
        ]]))

        await #expect(throws: GeoPackageError.self) {
            try await FeatureCollection([Feature(polygon)])
                .writeGeopackage(to: url)
        }

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.count == 1)
    }

    @Test
    func appendingDifferentProjectionReprojectsIntoTableCRS() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let origin = Coordinate3D(latitude: 0.0, longitude: 0.0)
        try await FeatureCollection([
            Feature(Point(origin)),
        ]).writeGeopackage(to: url)

        // Roughly 1000 m east of the origin in Web Mercator.
        let projected = Feature(
            Point(Coordinate3D.epsg3857(x: 1000.0, y: 0.0)))
        try await FeatureCollection([projected]).writeGeopackage(to: url)

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.count == 2)
        let point = try #require(read.features[1].geometry as? Point)
        #expect(point.projection == .epsg4326)
        #expect(point.coordinate.longitude > 0.0)
        #expect(abs(point.coordinate.latitude) < 0.000001)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        #expect(try TestSupport.scalar(
            "SELECT srs_id FROM gpkg_contents WHERE table_name = 'features';",
            from: db) as? Int == 4326)
    }

    @Test
    func appendingUnlocatedFeaturePreservesBounds() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            point(2.0, 3.0),
        ]).writeGeopackage(to: url)

        try await FeatureCollection([
            Feature(id: .string("none"), properties: ["name": "none"]),
        ]).writeGeopackage(to: url)

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.count == 2)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let row = try #require(try db.query(
            "SELECT min_x, max_x FROM gpkg_contents WHERE table_name = 'features';")
            .first)
        #expect(row["min_x"] as? Double == 3.0)
        #expect(row["max_x"] as? Double == 3.0)
    }

    @Test
    func appendingToTableWithoutExplicitIDColumnAddsOneWhenNeeded() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        try db.execute("""
        CREATE TABLE external (
            fid INTEGER PRIMARY KEY AUTOINCREMENT,
            geom POINT
        );
        """)
        try db.execute("""
        INSERT INTO gpkg_contents
        (table_name, data_type, identifier, srs_id)
        VALUES ('external', 'features', 'external', 4326);
        """)
        try db.execute("""
        INSERT INTO gpkg_geometry_columns
        (table_name, column_name, geometry_type_name, srs_id, z, m)
        VALUES ('external', 'geom', 'POINT', 4326, 0, 0);
        """)
        db.close()

        let connection = try GeoPackageConnection(url: url)
        try await connection.write(
            features: FeatureCollection([
                point(0.0, 0.0, id: .string("new-id")),
            ]),
            to: "external")
        await connection.close()

        let read = try await FeatureCollection(
            geopackage: url,
            table: "external")
        let feature = try #require(read.features.first)
        #expect(read.features.count == 1)
        #expect(feature.id == .string("new-id"))
    }

    @Test
    func synchronousCoderAppendsToExistingFile() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try GeoPackageCoder.write(
            FeatureCollection([point(0.0, 0.0, id: .int(1))]),
            to: url)
        try GeoPackageCoder.write(
            FeatureCollection([point(1.0, 1.0, id: .int(2))]),
            to: url)

        let collection = try GeoPackageCoder.read(from: url)
        #expect(collection.features.count == 2)
        #expect(collection.features.compactMap(\.id) == [.int(1), .int(2)])
    }

    @Test
    func reservedTableNamesAreRejected() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        for table in ["gpkg_contents", "gpkg_geometry_columns", "GPKG_EXTENSIONS"] {
            await #expect(throws: GeoPackageError.self) {
                try await FeatureCollection([point(0.0, 0.0)])
                    .writeGeopackage(to: url, table: table)
            }
        }
    }

}
