import Foundation
@testable import GISTools
@testable import GISToolsGeoPackage
import Testing

struct GeoPackagePropertyMappingTests {

    private func writeAndRead(
        _ features: [Feature],
        url: URL,
    ) async throws -> [Feature] {
        try await FeatureCollection(features).writeGeopackage(to: url)
        return try await FeatureCollection(geopackage: url).features
    }

    @Test
    func base64LookingTextStaysText() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        // "Test", "1234", "name" and "YWJj" are all valid Base64 strings.
        // They must be stored as TEXT, not silently converted to BLOBs.
        let values = ["Test", "1234", "name", "YWJj", "abcd"]
        let features = values.enumerated().map { index, value in
            Feature(
                Point(Coordinate3D(latitude: Double(index), longitude: 0.0)),
                properties: ["text": value])
        }
        let read = try await writeAndRead(features, url: url)
        #expect(read.map { $0.properties["text"] as? String } == values)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let info = try db.query("PRAGMA table_info(features);")
        let textColumn = info.first { $0["name"] as? String == "text" }
        #expect((textColumn?["type"] as? String)?.uppercased() == "TEXT")

        let actualBase64 = try db.query("SELECT typeof(text) AS kind FROM features;")
        #expect(actualBase64.allSatisfy { $0["kind"] as? String == "text" })
    }

    @Test
    func scalarPropertyTypesRoundTrip() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let feature = Feature(
            Point(Coordinate3D(latitude: 1.0, longitude: 2.0)),
            properties: [
                "string": "hello",
                "integer": 42,
                "negative": -7,
                "double": 3.25,
                "boolean": true,
                "falseBoolean": false,
                "emptyString": "",
                "unicode": "Grüße 🌍",
            ])
        let features = try await writeAndRead([feature], url: url)
        let read = try #require(features.first)
        let props = read.properties

        #expect(props["string"] as? String == "hello")
        #expect(props["integer"] as? Int == 42)
        #expect(props["negative"] as? Int == -7)
        #expect(abs((props["double"] as? Double ?? 0.0) - 3.25) < 0.000001)
        #expect(props["boolean"] as? Bool == true)
        #expect(props["falseBoolean"] as? Bool == false)
        #expect(props["emptyString"] as? String == "")
        #expect(props["unicode"] as? String == "Grüße 🌍")
    }

    @Test
    func unsignedIntegerPropertyRoundTrips() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let feature = Feature(
            Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
            properties: ["small": UInt(5), "large": UInt64(UInt32.max)])
        let features = try await writeAndRead([feature], url: url)
        let read = try #require(features.first)

        #expect(read.properties["small"] as? Int == 5)
        #expect(read.properties["large"] as? Int == Int(UInt32.max))
    }

    @Test
    func dataPropertyIsStoredAsBlobAndReadAsBase64() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let binary = Data([0x00, 0x01, 0x02, 0xFF])
        let feature = Feature(
            Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
            properties: ["payload": binary])
        let features = try await writeAndRead([feature], url: url)
        let read = try #require(features.first)

        #expect(read.properties["payload"] as? String == binary.base64EncodedString())

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let info = try db.query("PRAGMA table_info(features);")
        let payloadColumn = info.first { $0["name"] as? String == "payload" }
        #expect((payloadColumn?["type"] as? String)?.uppercased() == "BLOB")
        let kind = try TestSupport.scalar(
            "SELECT typeof(payload) FROM features;",
            from: db) as? String
        #expect(kind == "blob")
    }

    @Test
    func emptyDataPropertyRoundTrips() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let feature = Feature(
            Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
            properties: ["empty": Data()])
        let features = try await writeAndRead([feature], url: url)
        let read = try #require(features.first)
        #expect(read.properties["empty"] as? String == "")
    }

    @Test
    func mixedNumericPropertiesUseRealColumn() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let features = [
            Feature(
                Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
                properties: ["value": 1]),
            Feature(
                Point(Coordinate3D(latitude: 1.0, longitude: 1.0)),
                properties: ["value": 2.5]),
        ]
        let read = try await writeAndRead(features, url: url)
        #expect(read.compactMap { $0.properties["value"] as? Double } == [1.0, 2.5])

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let info = try db.query("PRAGMA table_info(features);")
        let column = info.first { $0["name"] as? String == "value" }
        #expect((column?["type"] as? String)?.uppercased() == "REAL")
    }

    @Test
    func missingPropertyIsOmittedOnRead() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let features = [
            Feature(
                Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
                properties: ["present": "yes"]),
            Feature(
                Point(Coordinate3D(latitude: 1.0, longitude: 1.0)),
                properties: ["present": "also", "optional": 7]),
        ]
        let read = try await writeAndRead(features, url: url)
        #expect(read[0].properties["optional"] == nil)
        #expect(read[1].properties["optional"] as? Int == 7)
    }

    @Test
    func reservedPropertyNamesThrow() async throws {
        for key in ["id", "fid", "geom", "ID", "Fid", "GEOM"] {
            let url = TestSupport.temporaryURL()
            defer { TestSupport.remove(url) }

            let feature = Feature(
                Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
                properties: [key: "value"])
            await #expect(throws: GeoPackageError.self) {
                try await FeatureCollection([feature]).writeGeopackage(to: url)
            }
        }
    }

    @Test
    func caseInsensitivePropertyCollisionThrows() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let features = [
            Feature(
                Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
                properties: ["Name": "first"]),
            Feature(
                Point(Coordinate3D(latitude: 1.0, longitude: 1.0)),
                properties: ["name": "second"]),
        ]
        await #expect(throws: GeoPackageError.self) {
            try await FeatureCollection(features).writeGeopackage(to: url)
        }
    }

    @Test
    func nestedPropertyValueThrowsInsteadOfSilentCorruption() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let feature = Feature(
            Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
            properties: ["tags": ["a", "b"]])
        await #expect(throws: GeoPackageError.self) {
            try await FeatureCollection([feature]).writeGeopackage(to: url)
        }
    }

    @Test
    func largeUnsignedIdentifierFallsBackToTextColumn() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        let feature = Feature(
            Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
            id: .uint(UInt.max))
        try await FeatureCollection([feature]).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        defer { db.close() }
        let info = try db.query("PRAGMA table_info(features);")
        let idColumn = info.first { $0["name"] as? String == "id" }
        #expect((idColumn?["type"] as? String)?.uppercased() == "TEXT")

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.first?.id == .string(String(UInt.max)))
    }

    @Test
    func idColumnDetectionIsCaseInsensitive() async throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }

        try await FeatureCollection([
            Feature(
                Point(Coordinate3D(latitude: 0.0, longitude: 0.0)),
                properties: ["name": "x"]),
        ]).writeGeopackage(to: url)

        let db = try TestSupport.database(at: url)
        try db.execute("ALTER TABLE features RENAME COLUMN id TO ID;")

        let read = try await FeatureCollection(geopackage: url)
        #expect(read.features.first?.properties["name"] as? String == "x")
        #expect(read.features.first?.properties["ID"] == nil)
        db.close()
    }

}
