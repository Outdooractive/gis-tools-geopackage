import Testing
import Foundation
@testable import GISTools
@testable import GISToolsGeoPackage

struct GeoPackageFeatureTests {

    private let tmpDir = URL(fileURLWithPath: "/tmp")

    private func testUrl(_ name: String = #function) -> URL {
        let cleanName = name.hasSuffix("()") ? String(name.dropLast(2)) : name
        return tmpDir.appendingPathComponent("gpkg_\(cleanName).gpkg")
    }

    @Test
    func roundTripPoint() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let feature = Feature(Point(Coordinate3D(latitude: 45.0, longitude: 10.0)))
        let fc = FeatureCollection([feature])
        try await fc.writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        let readGeo = read.features[0].geometry
        #expect(readGeo is Point)
        let point = readGeo as! Point
        #expect(abs(point.coordinate.latitude - 45.0) < 0.000001)
        #expect(abs(point.coordinate.longitude - 10.0) < 0.000001)
    }

    @Test
    func roundTripLineString() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let ls = try #require(LineString([
            Coordinate3D(latitude: 0.0, longitude: 0.0),
            Coordinate3D(latitude: 10.0, longitude: 10.0),
        ]))
        let feature = Feature(ls)
        let fc = FeatureCollection([feature])
        try await fc.writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        #expect(read.features[0].geometry is LineString)
    }

    @Test
    func roundTripPolygon() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let poly = try #require(Polygon([[
            Coordinate3D(latitude: 0.0, longitude: 0.0),
            Coordinate3D(latitude: 10.0, longitude: 0.0),
            Coordinate3D(latitude: 10.0, longitude: 10.0),
            Coordinate3D(latitude: 0.0, longitude: 10.0),
            Coordinate3D(latitude: 0.0, longitude: 0.0),
        ]]))
        let feature = Feature(poly)
        let fc = FeatureCollection([feature])
        try await fc.writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        #expect(read.features[0].geometry is Polygon)
    }

    @Test
    func roundTripWithProperties() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let feature = Feature(
            Point(Coordinate3D(latitude: 45.0, longitude: 10.0)),
            properties: ["name": "Test", "value": 42, "ratio": 3.14])
        let fc = FeatureCollection([feature])
        try await fc.writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        let props = read.features[0].properties
        #expect(props["name"] as? String == "Test")
        #expect(props["value"] as? Int == 42)
        #expect(abs((props["ratio"] as? Double ?? 0.0) - 3.14) < 0.001)
    }

    @Test
    func emptyCollectionThrows() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let fc = FeatureCollection([Feature]())
        do {
            try await fc.writeGeopackage(to: dbUrl)
            Issue.record("Expected GeoPackageError to be thrown")
        }
        catch is GeoPackageError {
            // Expected
        }
    }

    @Test
    func mixedGeometryTypesAccepted() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let point = Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0)))
        let poly = try #require(Polygon([[
            Coordinate3D(latitude: 0.0, longitude: 0.0),
            Coordinate3D(latitude: 1.0, longitude: 0.0),
            Coordinate3D(latitude: 1.0, longitude: 1.0),
            Coordinate3D(latitude: 0.0, longitude: 1.0),
            Coordinate3D(latitude: 0.0, longitude: 0.0),
        ]]))
        let fc = FeatureCollection([point, Feature(poly)])
        try await fc.writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 2)
    }

    @Test
    func nonExistentFileThrows() async throws {
        do {
            let _ = try await FeatureCollection(geopackage: URL(fileURLWithPath: "/tmp/does_not_exist.gpkg"))
            Issue.record("Expected GeoPackageError to be thrown")
        }
        catch is GeoPackageError {
            // Expected
        }
    }

    @Test
    func roundTripMultiPoint() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let multiPoint = try #require(MultiPoint([
            Coordinate3D(latitude: 0.0, longitude: 0.0),
            Coordinate3D(latitude: 10.0, longitude: 10.0),
        ]))
        let feature = Feature(multiPoint)
        let fc = FeatureCollection([feature])
        try await fc.writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        #expect(read.features[0].geometry is MultiPoint)
    }

    @Test
    func naturalEarthCountries() async throws {
        let url = testFixture("ne_110m_admin_0_countries_from_geojson.gpkg")
        let fc = try await FeatureCollection(geopackage: url, table: "ne_110m_admin_0_countries")
        #expect(fc.features.count == 177)
        #expect(fc.features.first?.properties["name"] as? String == "Afghanistan")
    }

    @Test
    func naturalEarthFromGeoJSON() async throws {
        let url = testFixture("ne_110m_admin_0_countries_from_geojson.gpkg")
        let fc = try await FeatureCollection(geopackage: url, table: "ne_110m_admin_0_countries")
        #expect(fc.features.count == 177)
    }

    @Test
    func naturalEarthFromShapefile() async throws {
        let url = testFixture("ne_110m_admin_0_countries_from_shp.gpkg")
        let fc = try await FeatureCollection(geopackage: url, table: "ne_110m_admin_0_countries")
        #expect(fc.features.count == 177)
    }

    // MARK: - Feature.id round-trip

    @Test
    func roundTripWithStringId() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let feature = Feature(
            Point(Coordinate3D(latitude: 45.0, longitude: 10.0)),
            id: .string("abc-123"),
            properties: ["name": "Test"])
        try await FeatureCollection([feature]).writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        #expect(read.features[0].id == .string("abc-123"))
        #expect(read.features[0].gpkgRowId != nil)
        #expect(read.features[0].properties["name"] as? String == "Test")
    }

    @Test
    func roundTripWithIntId() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let feature = Feature(
            Point(Coordinate3D(latitude: 45.0, longitude: 10.0)),
            id: .int(42))
        try await FeatureCollection([feature]).writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        // Uniform integer ids produce an INTEGER column, so the value
        // round-trips as .int rather than .string.
        #expect(read.features[0].id == .int(42))
        #expect(read.features[0].gpkgRowId != nil)
    }

    @Test
    func roundTripWithDoubleId() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let feature = Feature(
            Point(Coordinate3D(latitude: 45.0, longitude: 10.0)),
            id: .double(3.14))
        try await FeatureCollection([feature]).writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        #expect(read.features[0].id == .double(3.14))
    }

    @Test
    func roundTripWithMixedIdTypesFallsBackToText() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let features = [
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0)), id: .int(1)),
            Feature(Point(Coordinate3D(latitude: 1.0, longitude: 1.0)), id: .string("two")),
        ]
        try await FeatureCollection(features).writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 2)
        // Mixed id types fall back to a TEXT column, so both come back as
        // .string.
        #expect(read.features[0].id == .string("1"))
        #expect(read.features[1].id == .string("two"))
    }

    @Test
    func roundTripWithNilId() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let feature = Feature(Point(Coordinate3D(latitude: 45.0, longitude: 10.0)))
        try await FeatureCollection([feature]).writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        #expect(read.features[0].id == nil)
        #expect(read.features[0].gpkgRowId != nil)
    }

    @Test
    func idColumnNotLeakedIntoProperties() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        let feature = Feature(
            Point(Coordinate3D(latitude: 45.0, longitude: 10.0)),
            id: .string("abc"),
            properties: ["name": "Test"])
        try await FeatureCollection([feature]).writeGeopackage(to: dbUrl)

        let read = try await FeatureCollection(geopackage: dbUrl, table: "features")
        #expect(read.features.count == 1)
        // The id/fid columns must not appear as properties.
        #expect(read.features[0].properties["id"] == nil)
        #expect(read.features[0].properties["fid"] == nil)
    }

    // MARK: - rtree spatial index id correctness

    @Test
    func rtreeIdsMatchFeatureRowids() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        // Include a feature with no computable envelope to exercise the
        // previous bug where the rtree id counter desynced from the table
        // rowid. All features here have envelopes, so this primarily checks
        // that rtree ids equal the actual fid values (not a 1..N counter).
        let features = [
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0)), id: .int(100)),
            Feature(Point(Coordinate3D(latitude: 10.0, longitude: 10.0)), id: .int(200)),
            Feature(Point(Coordinate3D(latitude: 20.0, longitude: 20.0)), id: .int(300)),
        ]
        try await FeatureCollection(features).writeGeopackage(to: dbUrl, createSpatialIndex: true)

        let db = try SQLiteDB(path: dbUrl.path)
        defer { db.close() }

        // The feature table fid values must match the rtree ids.
        let fids = try db.query("SELECT fid FROM features ORDER BY fid;")
        let rtreeIds = try db.query("SELECT id FROM \"rtree_features_geom\" ORDER BY id;")

        let fidValues = fids.compactMap { $0["fid"] as? Int }
        let rtreeIdValues = rtreeIds.compactMap { $0["id"] as? Int }

        #expect(fidValues.count == 3)
        #expect(rtreeIdValues.count == 3)
        #expect(fidValues == rtreeIdValues)
    }

    @Test
    func rtreeIdsMatchRowidsWhenSkippingFeatures() async throws {
        let dbUrl = testUrl()
        try? FileManager.default.removeItem(at: dbUrl)

        // First feature has an envelope and gets inserted; it must also get an
        // rtree row with a matching rowid. (The point geometry always has a
        // bounding box, so this verifies the rowid is sourced from
        // last_insert_rowid() rather than a counter.)
        let features = [
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0)), id: .int(1)),
            Feature(Point(Coordinate3D(latitude: 10.0, longitude: 10.0)), id: .int(2)),
        ]
        try await FeatureCollection(features).writeGeopackage(to: dbUrl, createSpatialIndex: true)

        let db = try SQLiteDB(path: dbUrl.path)
        defer { db.close() }

        let fids = try db.query("SELECT fid FROM features ORDER BY fid;")
            .compactMap { $0["fid"] as? Int }
        let rtreeIds = try db.query("SELECT id FROM \"rtree_features_geom\" ORDER BY id;")
            .compactMap { $0["id"] as? Int }

        #expect(fids == rtreeIds)
        #expect(fids == [1, 2])
    }

}
