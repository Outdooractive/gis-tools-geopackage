import Foundation
@testable import GISTools
@testable import GISToolsGeoPackage
import Testing

struct GeoPackageProjectionTests {

    @Test
    func roundTripEPSG4326() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let feature = Feature(
            Point(Coordinate3D(latitude: 48.1372, longitude: 11.5756)),
            properties: ["name": "Munich"])
        try await FeatureCollection([feature]).writeGeopackage(to: url)

        let read = try await FeatureCollection(geopackage: url)
        let point = try #require(read.features.first?.geometry as? Point)
        #expect(point.projection == .epsg4326)
        #expect(abs(point.coordinate.latitude - 48.1372) < 0.0000001)
        #expect(abs(point.coordinate.longitude - 11.5756) < 0.0000001)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        #expect(try TestSupport.scalar(
            "SELECT srs_id FROM gpkg_contents WHERE table_name = 'features';",
            from: db) as? Int == 4326)
        #expect(try TestSupport.scalar(
            "SELECT srs_id FROM gpkg_geometry_columns WHERE table_name = 'features';",
            from: db) as? Int == 4326)
    }

    @Test
    func roundTripEPSG3857() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let coordinate = Coordinate3D.epsg3857(x: 1_288_000.0, y: 6_120_000.0)
        try await FeatureCollection([
            Feature(Point(coordinate), properties: ["name": "projected"]),
        ]).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        defer { db.close() }

        #expect(try TestSupport.scalar(
            "SELECT srs_id FROM gpkg_contents WHERE table_name = 'features';",
            from: db) as? Int == 3857)
        let minX = try TestSupport.scalar(
            "SELECT min_x FROM gpkg_contents WHERE table_name = 'features';",
            from: db) as? Double
        #expect(minX != nil)
        // The bounds must be in Web Mercator metres, not degrees.
        #expect(abs((minX ?? 0.0) - 1_288_000.0) < 0.001)

        let read = try await FeatureCollection(geopackage: url)
        let point = try #require(read.features.first?.geometry as? Point)
        #expect(point.projection == .epsg3857)
        #expect(abs(point.coordinate.x - 1_288_000.0) < 0.001)
        #expect(abs(point.coordinate.y - 6_120_000.0) < 0.001)
    }

    @Test
    func roundTripEPSG4978() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let coordinate = Coordinate3D.epsg4978(
            x: 4_190_000.0,
            y: 800_000.0,
            z: 4_800_000.0)
        try await FeatureCollection([
            Feature(Point(coordinate)),
        ]).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        #expect(try TestSupport.scalar(
            "SELECT srs_id FROM gpkg_geometry_columns WHERE table_name = 'features';",
            from: db) as? Int == 4978)

        let read = try await FeatureCollection(geopackage: url)
        let point = try #require(read.features.first?.geometry as? Point)
        #expect(point.projection == .epsg4978)
        #expect(abs(point.coordinate.x - 4_190_000.0) < 0.001)
        #expect(abs(point.coordinate.y - 800_000.0) < 0.001)
        #expect(abs((point.coordinate.z ?? 0.0) - 4_800_000.0) < 0.001)
    }

    @Test
    func roundTripNoSRIDUsesUndefinedSRSZero() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let coordinate = Coordinate3D.noSRID(x: 12.5, y: -3.25)
        try await FeatureCollection([
            Feature(Point(coordinate)),
        ]).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        #expect(try TestSupport.scalar(
            "SELECT srs_id FROM gpkg_contents WHERE table_name = 'features';",
            from: db) as? Int == 0)
        #expect(try TestSupport.scalar(
            "SELECT count(*) FROM gpkg_spatial_ref_sys WHERE srs_id = 0;",
            from: db) as? Int == 1)

        let read = try await FeatureCollection(geopackage: url)
        let point = try #require(read.features.first?.geometry as? Point)
        #expect(point.projection == .noSRID)
        #expect(abs(point.coordinate.x - 12.5) < 0.0000001)
        #expect(abs(point.coordinate.y + 3.25) < 0.0000001)
    }

    @Test
    func roundTripRegisteredNonWebMercatorProjection() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let projection = try #require(Projection(srid: 32632))
        let coordinate = Coordinate3D(
            x: 691_000.0,
            y: 5_336_000.0,
            projection: projection)
        try await FeatureCollection([
            Feature(Point(coordinate)),
        ]).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        #expect(try TestSupport.scalar(
            "SELECT srs_id FROM gpkg_contents WHERE table_name = 'features';",
            from: db) as? Int == 32632)
        #expect(try TestSupport.scalar(
            "SELECT count(*) FROM gpkg_spatial_ref_sys WHERE srs_id = 32632;",
            from: db) as? Int == 1)

        let read = try await FeatureCollection(geopackage: url)
        let point = try #require(read.features.first?.geometry as? Point)
        #expect(point.projection.srid == 32632)
    }

    @Test
    func geometryDimensionsAreDeclaredInGeometryColumns() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let features = [
            Feature(Point(Coordinate3D(
                latitude: 0.0,
                longitude: 0.0,
                altitude: 100.0))),
            Feature(Point(Coordinate3D(
                latitude: 1.0,
                longitude: 1.0,
                altitude: 200.0))),
        ]
        try await FeatureCollection(features).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let row = try #require(try db.query(
            "SELECT z, m FROM gpkg_geometry_columns"
                + " WHERE table_name = 'features';")
            .first)
        #expect(row["z"] as? Int == 1)
        #expect(row["m"] as? Int == 0)
    }

    @Test
    func mixedDimensionsBecomeOptional() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let features = [
            Feature(Point(Coordinate3D(
                latitude: 0.0,
                longitude: 0.0,
                altitude: 100.0,
                m: 1.0))),
            Feature(Point(Coordinate3D(latitude: 1.0, longitude: 1.0))),
        ]
        try await FeatureCollection(features).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let row = try #require(try db.query(
            "SELECT z, m FROM gpkg_geometry_columns"
                + " WHERE table_name = 'features';")
            .first)
        #expect(row["z"] as? Int == 2)
        #expect(row["m"] as? Int == 2)
    }

    @Test
    func appending3DDataWidensExistingColumnToOptional() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
        ]).writeGeopackage(to: url)

        try await FeatureCollection([
            Feature(Point(Coordinate3D(
                latitude: 1.0,
                longitude: 1.0,
                altitude: 50.0))),
        ]).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let row = try #require(try db.query(
            "SELECT z FROM gpkg_geometry_columns"
                + " WHERE table_name = 'features';")
            .first)
        #expect(row["z"] as? Int == 2)
    }

    @Test
    func mixedProjectionsAreReprojectedIntoTheFirstProjection() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let geographic = Feature(
            Point(Coordinate3D(latitude: 48.1372, longitude: 11.5756)))
        let projected = geographic.projected(to: .epsg3857)
        // Put the 4326 feature first so the table uses EPSG:4326.
        try await FeatureCollection([geographic, projected])
            .writeGeopackage(to: url)

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.count == 2)
        for feature in read.features {
            let point = try #require(feature.geometry as? Point)
            #expect(point.projection == .epsg4326)
            #expect(abs(point.coordinate.latitude - 48.1372) < 0.000001)
            #expect(abs(point.coordinate.longitude - 11.5756) < 0.000001)
        }
    }

    @Test
    func boundingBoxInDifferentProjectionThanTable() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let features = [
            Feature(Point(Coordinate3D(latitude: 48.1372, longitude: 11.5756))),
            Feature(Point(Coordinate3D(latitude: 40.7128, longitude: -74.0060))),
        ]
        try await FeatureCollection(features)
            .writeGeopackage(to: url, createSpatialIndex: true)

        let munich = BoundingBox(
            southWest: Coordinate3D(latitude: 47.0, longitude: 10.0),
            northEast: Coordinate3D(latitude: 49.0, longitude: 12.0))
        let filtered = try await FeatureCollection(
            geopackage: url,
            boundingBox: munich)
        #expect(filtered.features.count == 1)
    }

    @Test
    func boundingBoxCrossingAntimeridian() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let features = [
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 179.5))),
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: -179.5))),
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
        ]
        try await FeatureCollection(features)
            .writeGeopackage(to: url, createSpatialIndex: true)

        let crossing = BoundingBox(
            southWest: Coordinate3D(latitude: -1.0, longitude: 179.0),
            northEast: Coordinate3D(latitude: 1.0, longitude: -179.0))
        #expect(GeoPackage.crossesAntimeridian(crossing))

        let filtered = try await FeatureCollection(
            geopackage: url,
            boundingBox: crossing)
        #expect(filtered.features.count == 2)
    }

    @Test
    func geometryHeaderStoresSRSAndEnvelope() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(Point(Coordinate3D.epsg3857(
                x: 1_288_000.0,
                y: 6_120_000.0))),
        ]).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let rows = try db.query("SELECT geom FROM features;")
        let blob = try #require(rows.first?["geom"] as? Data)

        #expect(blob[0] == 0x47)
        #expect(blob[1] == 0x50)
        let flags = blob[3]
        #expect(flags & 0x01 == 0x01, "Header must be little-endian")
        #expect((flags >> 1) & 0x07 == 1, "Expected a 2D envelope")
        #expect(flags & 0x10 == 0, "Non-empty geometry must not set the empty flag")

        let header = try WKBHeader.parse(blob)
        #expect(header.srid == 3857)
        #expect(header.isEmpty == false)
        let envelope = try #require(header.envelope)
        #expect(abs(envelope.southWest.longitude - 1_288_000.0) < 0.001)
    }

}
