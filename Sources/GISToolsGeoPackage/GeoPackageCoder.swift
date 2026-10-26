import Foundation
import GISTools

/// Synchronous read and write entry points for OGC GeoPackage files.
///
/// The API mirrors the other `GISTools*` coders:
///
/// ```swift
/// let collection = try GeoPackageCoder.read(from: url, table: "countries")
/// try GeoPackageCoder.write(collection, to: outputURL, table: "countries")
/// ```
///
/// Use ``GeoPackageConnection`` when multiple operations should share one
/// connection, when pagination or streaming is required, or when writing
/// incrementally. The asynchronous
/// `FeatureCollection(geopackage:table:boundingBox:)` and
/// `FeatureCollection.writeGeopackage(to:table:createSpatialIndex:)`
/// convenience APIs remain available.
public enum GeoPackageCoder {

    /// Reads a feature table from a GeoPackage file.
    ///
    /// The file is opened read-only and validated before reading. Missing
    /// files throw instead of being created.
    ///
    /// - Parameters:
    ///   - url: The GeoPackage file URL.
    ///   - table: The feature table name (default `"features"`).
    ///   - boundingBox: An optional bounding box in any projection.
    ///   - limit: An optional maximum number of features.
    ///   - offset: The number of matching features to skip.
    /// - Returns: A `FeatureCollection` containing the table's features.
    /// - Throws: ``GeoPackageError`` if the file is invalid or cannot be read.
    public static func read(
        from url: URL,
        table: String = "features",
        boundingBox: BoundingBox? = nil,
        limit: Int? = nil,
        offset: Int = 0,
    ) throws -> FeatureCollection {
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
            boundingBox: boundingBox,
            limit: limit,
            offset: offset)
        return FeatureCollection(features)
    }

    /// Writes a feature collection to a GeoPackage file.
    ///
    /// Creates the metadata tables when needed. Existing feature tables are
    /// appended to.
    ///
    /// - Parameters:
    ///   - featureCollection: The features to write.
    ///   - url: The destination file URL.
    ///   - table: The feature table name (default `"features"`).
    ///   - createSpatialIndex: Whether to create an R-tree index when the
    ///     table does not have one.
    /// - Throws: ``GeoPackageError`` if the file cannot be written.
    public static func write(
        _ featureCollection: FeatureCollection,
        to url: URL,
        table: String = "features",
        createSpatialIndex: Bool = false,
    ) throws {
        let db = try SQLiteDB(path: url.path)
        defer { db.close() }

        // Both metadata creation and the feature rows are atomic.
        try db.withTransaction {
            try GeoPackage.createMetadata(in: db)
            try GeoPackageWriter.writeFeatures(
                featureCollection,
                to: db,
                table: table,
                createSpatialIndex: createSpatialIndex)
        }
    }

}
