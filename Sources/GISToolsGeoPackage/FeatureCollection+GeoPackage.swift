import Foundation
import GISTools

// MARK: - FeatureCollection convenience

extension FeatureCollection {

    /// Creates a FeatureCollection from a GeoPackage (.gpkg) file.
    ///
    /// - Parameters:
    ///   - geopackage: The file URL of a GeoPackage database.
    ///   - table: The name of the feature table to read (default `"features"`).
    ///   - boundingBox: An optional bounding box to filter features. When
    ///     set and the GeoPackage has a spatial (rtree) index, only
    ///     features within or intersecting the bounding box are returned.
    /// - Throws: A ``GeoPackageError`` if the file cannot be read or is invalid.
    public init(
        geopackage url: URL,
        table: String = "features",
        boundingBox: BoundingBox? = nil
    ) async throws {
        let conn = try GeoPackageConnection(url: url, skipValidation: true)
        try await conn.validate()
        let features = try await conn.readFeatures(table: table, boundingBox: boundingBox)
        self.init(features)
    }

    /// Writes the FeatureCollection to a GeoPackage (.gpkg) file.
    ///
    /// - Parameters:
    ///   - url: The file URL to write to.
    ///   - table: The name of the feature table to create (default `"features"`).
    ///   - createSpatialIndex: If `true`, creates a `gpkg_rtree_index` spatial
    ///     index for faster bounding-box queries (default `false`).
    /// - Throws: A ``GeoPackageError`` if the file cannot be written.
    public func writeGeopackage(
        to url: URL,
        table: String = "features",
        createSpatialIndex: Bool = false
    ) async throws {
        let conn = try GeoPackageConnection(url: url, skipValidation: true)
        try await writeGeopackage(into: conn, table: table, createSpatialIndex: createSpatialIndex)
        await conn.close()
    }

    /// Writes the FeatureCollection into an existing GeoPackage
    /// connection so the same connection can be reused for reads.
    ///
    /// ```swift
    /// let gpkg = try await GeoPackageConnection(url: url, skipValidation: true)
    /// try await fc.writeGeopackage(into: gpkg)
    /// let features = try await gpkg.readFeatures(table: "features")
    /// ```
    ///
    /// - Parameters:
    ///   - conn: An open GeoPackage connection.
    ///   - table: The name of the feature table to create (default `"features"`).
    ///   - createSpatialIndex: If `true`, creates a `gpkg_rtree_index` spatial
    ///     index for faster bounding-box queries (default `false`).
    /// - Throws: A ``GeoPackageError`` if the file cannot be written.
    public func writeGeopackage(
        into conn: GeoPackageConnection,
        table: String = "features",
        createSpatialIndex: Bool = false
    ) async throws {
        try await conn.createMetadata()
        try await conn.write(features: self, to: table, createSpatialIndex: createSpatialIndex)
    }

}
