import Foundation
import GISTools
@testable import GISToolsGeoPackage

/// Returns the URL of a test fixture in the `TestData` directory.
func testFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("TestData/\(name)")
}

/// Shared helpers for temporary GeoPackage files.
enum TestSupport {

    /// A unique temporary `.gpkg` URL.
    static func temporaryURL(_ name: String = #function) -> URL {
        let cleanName = name
            .replacing("()", with: "")
            .replacing("/", with: "_")
        return FileManager.default
            .temporaryDirectory
            .appendingPathComponent("gpkg_\(cleanName)_\(UUID().uuidString).gpkg")
    }

    /// Removes a file if it exists.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Opens a database for assertions in tests.
    static func database(at url: URL) throws -> SQLiteDB {
        try SQLiteDB(path: url.path)
    }

    /// A full Web Mercator world bounding box in metres.
    static var webMercatorWorld: BoundingBox {
        let extent = 20_037_508.342789244
        return BoundingBox(
            southWest: Coordinate3D.epsg3857(x: -extent, y: -extent),
            northEast: Coordinate3D.epsg3857(x: extent, y: extent))
    }

    /// Reads a single scalar value from a query.
    static func scalar(
        _ sql: String,
        from db: SQLiteDB,
        values: [Any?] = [],
    ) throws -> (any Sendable)? {
        try db.query(sql, values: values).first?.values.first ?? nil
    }

}
