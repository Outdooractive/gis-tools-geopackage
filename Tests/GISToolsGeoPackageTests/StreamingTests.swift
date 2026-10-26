import Foundation
@testable import GISTools
@testable import GISToolsGeoPackage
import Testing

struct GeoPackageStreamingTests {

    private func makeCollection(count: Int) -> FeatureCollection {
        let features = (0 ..< count).map { index in
            Feature(
                Point(Coordinate3D(
                    latitude: Double(index % 90),
                    longitude: Double(index % 180))),
                id: .int(index),
                properties: ["index": index])
        }
        return FeatureCollection(features)
    }

    @Test
    func streamYieldsEveryFeatureAcrossChunks() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let expected = makeCollection(count: 1200)
        try await expected.writeGeopackage(to: url)

        let gpkg = try GeoPackageConnection(url: url)
        var values: [Feature] = []
        for try await feature in gpkg.features(table: "features") {
            values.append(feature)
        }
        await gpkg.close()

        #expect(values.count == expected.features.count)
        #expect(values.compactMap(\.id) == expected.features.compactMap(\.id))
        #expect(values.map { $0.properties["index"] as? Int }
            == expected.features.map { $0.properties["index"] as? Int })
    }

    @Test
    func streamLimitAndOffsetMatchReader() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makeCollection(count: 20).writeGeopackage(to: url)

        let gpkg = try GeoPackageConnection(url: url)
        let read = try await gpkg.readFeatures(
            table: "features",
            limit: 5,
            offset: 7)
        var streamed: [Feature] = []
        for try await feature in gpkg.features(
            table: "features",
            limit: 5,
            offset: 7)
        {
            streamed.append(feature)
        }
        await gpkg.close()

        #expect(streamed.compactMap(\.gpkgRowId) == read.compactMap(\.gpkgRowId))
        #expect(streamed.compactMap(\.id) == read.compactMap(\.id))
    }

    @Test
    func streamBoundingBoxWithAndWithoutRTree() async throws {
        for createIndex in [false, true] {
            let url = TestSupport.temporaryURL()
            defer { TestSupport.remove(url) }

            let features = [
                Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
                Feature(Point(Coordinate3D(latitude: 50.0, longitude: 50.0))),
            ]
            try await FeatureCollection(features)
                .writeGeopackage(to: url, createSpatialIndex: createIndex)

            let box = BoundingBox(
                southWest: Coordinate3D(latitude: -1.0, longitude: -1.0),
                northEast: Coordinate3D(latitude: 1.0, longitude: 1.0))

            let gpkg = try GeoPackageConnection(url: url)
            var streamed: [Feature] = []
            for try await feature in gpkg.features(
                table: "features",
                boundingBox: box)
            {
                streamed.append(feature)
            }
            await gpkg.close()

            #expect(streamed.count == 1, "createIndex=\(createIndex)")
        }
    }

    @Test
    func streamBoundingBoxIsProjectedIntoTableCRS() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let geographic = Feature(
            Point(Coordinate3D(latitude: 48.1372, longitude: 11.5756)))
        try await FeatureCollection([
            geographic.projected(to: .epsg3857),
        ]).writeGeopackage(to: url, createSpatialIndex: true)

        let box = BoundingBox(
            southWest: Coordinate3D(latitude: 47.0, longitude: 10.0),
            northEast: Coordinate3D(latitude: 49.0, longitude: 12.0))

        let gpkg = try GeoPackageConnection(url: url)
        var count = 0
        for try await _ in gpkg.features(table: "features", boundingBox: box) {
            count += 1
        }
        await gpkg.close()

        #expect(count == 1)
    }

    @Test
    func streamExcludesUnlocatedFeaturesWhenFilteringByBoundingBox() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(Point(Coordinate3D(latitude: 0.0, longitude: 0.0))),
            Feature(id: .int(2), properties: ["name": "unlocated"]),
        ]).writeGeopackage(to: url, createSpatialIndex: true)

        let gpkg = try GeoPackageConnection(url: url)
        let all = try await gpkg.readFeatures(table: "features")
        #expect(all.count == 2)

        let box = BoundingBox(
            southWest: Coordinate3D(latitude: -1.0, longitude: -1.0),
            northEast: Coordinate3D(latitude: 1.0, longitude: 1.0))
        var filtered: [Feature] = []
        for try await feature in gpkg.features(
            table: "features",
            boundingBox: box)
        {
            filtered.append(feature)
        }
        await gpkg.close()

        #expect(filtered.count == 1)
        #expect(filtered[0].geometry != nil)
    }

    @Test
    func publicStreamInitializerOpensReadOnlyConnection() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makeCollection(count: 3).writeGeopackage(to: url)

        let stream = try FeatureStream(url: url, table: "features")
        var count = 0
        for try await _ in stream {
            count += 1
        }
        #expect(count == 3)
    }

    @Test
    func streamWithZeroLimitYieldsNothing() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makeCollection(count: 2).writeGeopackage(to: url)

        let gpkg = try GeoPackageConnection(url: url)
        var count = 0
        for try await _ in gpkg.features(table: "features", limit: 0) {
            count += 1
        }
        await gpkg.close()
        #expect(count == 0)
    }

    @Test
    func streamThrowsForMissingTable() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makeCollection(count: 1).writeGeopackage(to: url)

        let gpkg = try GeoPackageConnection(url: url)
        await #expect(throws: GeoPackageError.self) {
            for try await _ in gpkg.features(table: "missing") {
                Issue.record("No feature should be yielded")
            }
        }
        await gpkg.close()
    }

    @Test
    func streamThrowsForMalformedGeometry() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makeCollection(count: 1).writeGeopackage(to: url)

        let db = try SQLiteDB(path: url.path)
        try db.execute(
            "UPDATE features SET geom = ?;",
            values: [Data([0x00, 0x00])])
        db.close()

        let gpkg = try GeoPackageConnection(url: url)
        await #expect(throws: GeoPackageError.self) {
            for try await _ in gpkg.features(table: "features") {
                Issue.record("Malformed geometry must not be yielded")
            }
        }
        await gpkg.close()
    }

    @Test
    func concurrentStreamsShareTheConnectionSafely() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        try await makeCollection(count: 50).writeGeopackage(to: url)

        let gpkg = try GeoPackageConnection(url: url)

        async let first = countFeatures(gpkg.features(table: "features"))
        async let second = countFeatures(gpkg.features(table: "features"))
        let counts = try await (first, second)
        await gpkg.close()

        #expect(counts == (50, 50))
    }

    private func countFeatures(_ stream: FeatureStream) async throws -> Int {
        var count = 0
        for try await _ in stream {
            count += 1
        }
        return count
    }

}
