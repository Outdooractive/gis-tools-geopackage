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
        // Open read-only: reading a missing path must throw instead of
        // silently creating an empty database file.
        let db = try SQLiteDB(path: url.path, readOnly: true)
        defer { db.close() }

        let validation = try GeoPackage.validate(in: db)
        guard validation.isValid else {
            throw GeoPackageError.invalidGeoPackage(
                detail: validation.errors.map(\.message).joined(separator: "; "))
        }

        let features = try GeoPackageReader.readFeatures(
            from: db,
            table: table,
            boundingBox: boundingBox)
        self.init(features)
    }

    /// Writes the FeatureCollection to a GeoPackage (.gpkg) file.
    ///
    /// - Parameters:
    ///   - url: The file URL to write to.
    ///   - table: The feature table to create or append to (default
    ///     `"features"`).
    ///   - createSpatialIndex: If `true`, creates a `gpkg_rtree_index` spatial
    ///     index when the table does not have one (default `false`).
    /// - Throws: A ``GeoPackageError`` if the file cannot be written.
    public func writeGeopackage(
        to url: URL,
        table: String = "features",
        createSpatialIndex: Bool = false
    ) async throws {
        let conn = try GeoPackageConnection(url: url, skipValidation: true)
        do {
            try await writeGeopackage(
                into: conn,
                table: table,
                createSpatialIndex: createSpatialIndex)
        }
        catch {
            // Close explicitly on every path; relying on deinit would keep
            // the SQLite handle (and WAL/journal files) alive longer than
            // necessary when a write fails halfway through.
            await conn.close()
            throw error
        }
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
    ///   - table: The feature table to create or append to (default
    ///     `"features"`).
    ///   - createSpatialIndex: If `true`, creates a `gpkg_rtree_index` spatial
    ///     index when the table does not have one (default `false`).
    /// - Throws: A ``GeoPackageError`` if the file cannot be written.
    public func writeGeopackage(
        into conn: GeoPackageConnection,
        table: String = "features",
        createSpatialIndex: Bool = false
    ) async throws {
        // The writer creates missing metadata tables inside the same
        // transaction as the feature rows.
        try await conn.write(
            features: self,
            to: table,
            createSpatialIndex: createSpatialIndex)
    }

}
