import Foundation
@testable import GISTools
@testable import GISToolsGeoPackage
import Testing

struct GeoTileValidationTests {

    private func pyramid(
        bounds: BoundingBox = TestSupport.webMercatorWorld,
        zoom: Int = 0,
        tableName: String = "tiles",
    ) -> [TileMatrix] {
        [
            TileMatrix(
                tableName: tableName,
                zoomLevel: zoom,
                matrixWidth: 1,
                matrixHeight: 1,
                pixelXSize: 156_543.0,
                pixelYSize: 156_543.0),
        ]
    }

    private func createDatabase(at url: URL) throws -> SQLiteDB {
        let db = try SQLiteDB(path: url.path)
        try GeoPackage.createMetadata(in: db)
        return db
    }

    @Test
    func tileMatrixSetBoundsKeepProjection() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        let bounds = BoundingBox(
            southWest: Coordinate3D.epsg3857(
                x: -20_037_508.0,
                y: -20_037_508.0),
            northEast: Coordinate3D.epsg3857(
                x: 20_037_508.0,
                y: 20_037_508.0))
        try TileWriter.writeTilePyramid(
            tiles: [TileKey(zoom: 0, column: 0, row: 0): Data([1])],
            to: "tiles",
            srsId: 3857,
            matrixSetBounds: bounds,
            matrices: pyramid(bounds: bounds),
            in: db)

        let set = try #require(try TileReader.readTileMatrixSet(
            for: "tiles",
            in: db))
        #expect(set.srsId == 3857)
        #expect(set.bounds.projection == .epsg3857)
        #expect(abs(set.bounds.southWest.x + 20_037_508.0) < 0.001)
    }

    @Test
    func customSRSRowIsCreatedForTilePyramid() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        let projection = try #require(Projection(srid: 32632))
        let bounds = BoundingBox(
            southWest: Coordinate3D(
                x: 200_000.0,
                y: 5_000_000.0,
                projection: projection),
            northEast: Coordinate3D(
                x: 800_000.0,
                y: 5_500_000.0,
                projection: projection))
        let matrices = [
            TileMatrix(
                tableName: "utm_tiles",
                zoomLevel: 0,
                matrixWidth: 1,
                matrixHeight: 1,
                pixelXSize: 1000.0,
                pixelYSize: 1000.0),
        ]

        try TileWriter.writeTilePyramid(
            tiles: [TileKey(zoom: 0, column: 0, row: 0): Data([1])],
            to: "utm_tiles",
            srsId: 32632,
            matrixSetBounds: bounds,
            matrices: matrices,
            in: db)

        let count = try db.query(
            "SELECT count(*) AS cnt FROM gpkg_spatial_ref_sys WHERE srs_id = 32632;")
        #expect(count.first?["cnt"] as? Int == 1)

        let validation = try GeoPackage.validate(url: url)
        #expect(
            validation.isValid,
            "errors=\(validation.errors.map(\.message))",
        )
    }

    @Test
    func boundsProjectionMustMatchSRSID() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        let degrees = BoundingBox(
            southWest: Coordinate3D(latitude: -85.0, longitude: -180.0),
            northEast: Coordinate3D(latitude: 85.0, longitude: 180.0))

        #expect(throws: GeoPackageError.self) {
            try TileWriter.writeTilePyramid(
                tiles: [TileKey(zoom: 0, column: 0, row: 0): Data([1])],
                to: "tiles",
                srsId: 3857,
                matrixSetBounds: degrees,
                matrices: pyramid(),
                in: db)
        }
    }

    @Test
    func invalidTileOutsideMatrixLeavesNoTrace() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        #expect(throws: GeoPackageError.self) {
            try TileWriter.writeTilePyramid(
                tiles: [TileKey(zoom: 0, column: 3, row: 0): Data([1])],
                to: "tiles",
                matrixSetBounds: TestSupport.webMercatorWorld,
                matrices: pyramid(),
                in: db)
        }

        let tables = try db.query(
            "SELECT name FROM sqlite_master WHERE name = 'tiles';")
        #expect(tables.isEmpty)
        let contents = try db.query(
            "SELECT count(*) AS cnt FROM gpkg_contents;")
        #expect(contents.first?["cnt"] as? Int == 0)
    }

    @Test
    func tileZoomWithoutMatrixThrows() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        #expect(throws: GeoPackageError.self) {
            try TileWriter.writeTilePyramid(
                tiles: [TileKey(zoom: 5, column: 0, row: 0): Data([1])],
                to: "tiles",
                matrixSetBounds: TestSupport.webMercatorWorld,
                matrices: pyramid(),
                in: db)
        }
    }

    @Test
    func mismatchedMatrixTableNameThrows() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        #expect(throws: GeoPackageError.self) {
            try TileWriter.writeTilePyramid(
                tiles: [TileKey(zoom: 0, column: 0, row: 0): Data([1])],
                to: "tiles",
                matrixSetBounds: TestSupport.webMercatorWorld,
                matrices: pyramid(tableName: "other"),
                in: db)
        }
    }

    @Test
    func duplicateZoomAndInvalidDimensionsThrow() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        let bounds = TestSupport.webMercatorWorld
        let duplicate = pyramid() + pyramid()

        #expect(throws: GeoPackageError.self) {
            try TileWriter.writeTilePyramid(
                tiles: [TileKey(zoom: 0, column: 0, row: 0): Data([1])],
                to: "tiles",
                matrixSetBounds: bounds,
                matrices: duplicate,
                in: db)
        }

        let invalid = [
            TileMatrix(
                tableName: "tiles",
                zoomLevel: 0,
                matrixWidth: 0,
                matrixHeight: 1,
                pixelXSize: 1.0,
                pixelYSize: 1.0),
        ]
        #expect(throws: GeoPackageError.self) {
            try TileWriter.writeTilePyramid(
                tiles: [TileKey(zoom: 0, column: 0, row: 0): Data([1])],
                to: "tiles",
                matrixSetBounds: bounds,
                matrices: invalid,
                in: db)
        }
    }

    @Test
    func emptyPyramidOrMatricesThrow() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        let bounds = TestSupport.webMercatorWorld

        #expect(throws: GeoPackageError.self) {
            try TileWriter.writeTilePyramid(
                tiles: [:],
                to: "tiles",
                matrixSetBounds: bounds,
                matrices: pyramid(),
                in: db)
        }
        #expect(throws: GeoPackageError.self) {
            try TileWriter.writeTilePyramid(
                tiles: [TileKey(zoom: 0, column: 0, row: 0): Data([1])],
                to: "tiles",
                matrixSetBounds: bounds,
                matrices: [],
                in: db)
        }
    }

    @Test
    func matrixTableIsOrderedByZoom() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        let bounds = TestSupport.webMercatorWorld
        let matrices = [
            TileMatrix(
                tableName: "tiles",
                zoomLevel: 2,
                matrixWidth: 4,
                matrixHeight: 4,
                pixelXSize: 39135.75,
                pixelYSize: 39135.75),
            TileMatrix(
                tableName: "tiles",
                zoomLevel: 0,
                matrixWidth: 1,
                matrixHeight: 1,
                pixelXSize: 156_543.0,
                pixelYSize: 156_543.0),
            TileMatrix(
                tableName: "tiles",
                zoomLevel: 1,
                matrixWidth: 2,
                matrixHeight: 2,
                pixelXSize: 78271.5,
                pixelYSize: 78271.5),
        ]
        try TileWriter.writeTilePyramid(
            tiles: [
                TileKey(zoom: 0, column: 0, row: 0): Data([0]),
                TileKey(zoom: 1, column: 1, row: 1): Data([1]),
                TileKey(zoom: 2, column: 3, row: 3): Data([2]),
            ],
            to: "tiles",
            matrixSetBounds: bounds,
            matrices: matrices,
            in: db)

        let read = try TileReader.readTileMatrices(for: "tiles", in: db)
        #expect(read.map(\.zoomLevel) == [0, 1, 2])
        #expect(try TileReader.readAllTiles(from: "tiles", in: db).count == 3)
    }

    @Test
    func writingPyramidReplacesOldTilesAndMatrices() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        let bounds = TestSupport.webMercatorWorld
        let twoZooms = [
            TileMatrix(
                tableName: "tiles",
                zoomLevel: 0,
                matrixWidth: 1,
                matrixHeight: 1,
                pixelXSize: 156_543.0,
                pixelYSize: 156_543.0),
            TileMatrix(
                tableName: "tiles",
                zoomLevel: 1,
                matrixWidth: 2,
                matrixHeight: 2,
                pixelXSize: 78271.5,
                pixelYSize: 78271.5),
        ]
        try TileWriter.writeTilePyramid(
            tiles: [
                TileKey(zoom: 0, column: 0, row: 0): Data([0]),
                TileKey(zoom: 1, column: 0, row: 0): Data([1]),
                TileKey(zoom: 1, column: 1, row: 1): Data([2]),
            ],
            to: "tiles",
            matrixSetBounds: bounds,
            matrices: twoZooms,
            in: db)

        try TileWriter.writeTilePyramid(
            tiles: [TileKey(zoom: 0, column: 0, row: 0): Data([9])],
            to: "tiles",
            matrixSetBounds: bounds,
            matrices: [twoZooms[0]],
            in: db)

        let tiles = try TileReader.readAllTiles(from: "tiles", in: db)
        #expect(tiles == [TileKey(zoom: 0, column: 0, row: 0): Data([9])])
        let matrices = try TileReader.readTileMatrices(for: "tiles", in: db)
        #expect(matrices.map(\.zoomLevel) == [0])
    }

    @Test
    func malformedTileMetadataThrows() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        try db.execute("DROP TABLE gpkg_tile_matrix;")
        try db.execute("""
        CREATE TABLE gpkg_tile_matrix (
            table_name TEXT,
            zoom_level INTEGER,
            matrix_width INTEGER,
            matrix_height INTEGER,
            tile_width INTEGER,
            tile_height INTEGER,
            pixel_x_size DOUBLE,
            pixel_y_size DOUBLE
        );
        """)
        try db.execute("""
        INSERT INTO gpkg_tile_matrix
        VALUES ('tiles', 0, NULL, 1, 256, 256, 1.0, 1.0);
        """)

        #expect(throws: GeoPackageError.self) {
            _ = try TileReader.readTileMatrices(for: "tiles", in: db)
        }
    }

    @Test
    func rewritesExistingTileBlob() throws {
        let url = TestSupport.temporaryURL()
        defer { TestSupport.remove(url) }
        let db = try createDatabase(at: url)
        defer { db.close() }

        try TileWriter.createTileTable("tiles", in: db)
        let key = TileKey(zoom: 1, column: 1, row: 1)
        try TileWriter.write(tileData: Data([1]), for: key, to: "tiles", in: db)
        try TileWriter.write(tileData: Data([2]), for: key, to: "tiles", in: db)

        let read = try TileReader.readTile(for: key, from: "tiles", in: db)
        #expect(read == Data([2]))
    }

}
