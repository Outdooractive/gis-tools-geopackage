import Foundation
import GISTools
import GISToolsGeoPackage
import Testing

/// Compiles against the public API only, without `@testable`.
struct GeoPackagePublicAPITests {

    @Test
    func publicSurfaceIsUsable() async throws {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("gpkg_public_\(UUID().uuidString).gpkg")
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = FeatureCollection([
            Feature(
                Point(Coordinate3D(latitude: 48.1372, longitude: 11.5756)),
                id: .string("munich"),
                properties: ["name": "Munich"]),
        ])

        try GeoPackageCoder.write(
            collection,
            to: url,
            createSpatialIndex: true)

        let read = try GeoPackageCoder.read(from: url)
        #expect(read.features.count == 1)

        let validation = try GeoPackage.validate(url: url)
        #expect(validation.isValid)

        let contents = try GeoPackage.readContents(from: url)
        #expect(contents.count == 1)

        let connection = try GeoPackageConnection(url: url)
        let featureTables = try await connection.featureTables()
        let tileTables = try await connection.tileTables()
        let hasIndex = try await connection.hasRTreeIndex(
            for: "features",
            column: "geom")
        #expect(featureTables.count == 1)
        #expect(tileTables.isEmpty)
        #expect(hasIndex)

        let attribute = AttributeTable(
            tableName: "info",
            columns: ["label"],
            rows: [["label": "value"]],
            rowIds: [1])
        try GeoPackage.writeAttributeTable(attribute, to: url)

        let media = MediaTable(
            tableName: "photos",
            rowIds: [1],
            data: [Data([1, 2, 3])],
            contentTypes: ["image/png"])
        try GeoPackage.writeMediaTable(media, to: url)

        let mediaRows = try GeoPackage.readMediaRows(
            from: url,
            table: "photos",
            rowId: 1)
        #expect(mediaRows.count == 1)

        let relation = RelationRow(
            tableName: "features",
            relatedTableName: "info",
            relationName: .attributes)
        try await connection.write(relation: relation)

        let relations = try GeoPackage.readRelations(from: url)
        #expect(relations.count == 1)

        var streamed = 0
        let stream = try FeatureStream(url: url, table: "features")
        for try await _ in stream {
            streamed += 1
        }
        #expect(streamed == 1)
        await connection.close()
    }

}
