import Foundation
import GISTools

// MARK: - Reader

/// Reads features from a GeoPackage feature table.
///
/// Row decoding is shared with ``FeatureStream`` through
/// ``FeatureTableMetadata``, so the synchronous and streaming APIs behave
/// identically for identifiers, properties, SRS handling and unlocated
/// features.
enum GeoPackageReader {

    /// Reads features from an open database.
    ///
    /// - Parameters:
    ///   - db: An open database handle.
    ///   - table: The feature table name.
    ///   - boundingBox: An optional bounding box in any projection.
    ///   - limit: An optional maximum number of features to return.
    ///   - offset: The number of matching rows to skip.
    /// - Returns: The features in ascending `rowid` order.
    static func readFeatures(
        from db: SQLiteDB,
        table: String,
        boundingBox: BoundingBox? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [Feature] {
        if let limit, limit < 0 {
            throw GeoPackageError.invalidArgument(
                detail: "limit must not be negative")
        }
        guard offset >= 0 else {
            throw GeoPackageError.invalidArgument(
                detail: "offset must not be negative")
        }

        let metadata = try FeatureTableMetadata.load(table: table, in: db)
        let useRTree: Bool
        if let boundingBox, !GeoPackage.crossesAntimeridian(boundingBox) {
            useRTree = try GeoPackage.hasRTreeIndex(
                for: table,
                column: metadata.geomColumnName,
                in: db)
        }
        else {
            useRTree = false
        }

        // Without a spatial index the bounding box has to be applied after
        // decoding. Apply LIMIT/OFFSET after that filter, otherwise a page
        // could contain fewer results than requested and offsets would refer
        // to unrelated rows.
        if boundingBox != nil, !useRTree {
            return try readFilteredFallback(
                from: db,
                metadata: metadata,
                boundingBox: boundingBox,
                limit: limit,
                offset: offset)
        }

        let query = metadata.selectSQL(
            boundingBox: boundingBox,
            useRTree: useRTree,
            limit: limit,
            offset: offset)
        let rows = try db.query(query.sql, values: query.values)
        return try rows.map { try metadata.feature(from: $0) }
    }

    /// Reads features from a GeoPackage file without modifying it.
    ///
    /// - Parameters:
    ///   - url: The GeoPackage file URL.
    ///   - table: The feature table name.
    ///   - boundingBox: An optional bounding box.
    ///   - limit: An optional row limit.
    ///   - offset: The number of matching rows to skip.
    static func readFeatures(
        from url: URL,
        table: String,
        boundingBox: BoundingBox? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [Feature] {
        let db = try SQLiteDB(path: url.path, readOnly: true)
        defer { db.close() }
        return try readFeatures(
            from: db,
            table: table,
            boundingBox: boundingBox,
            limit: limit,
            offset: offset)
    }

    // MARK: - Bounding-box fallback

    private static func readFilteredFallback(
        from db: SQLiteDB,
        metadata: FeatureTableMetadata,
        boundingBox: BoundingBox?,
        limit: Int?,
        offset: Int
    ) throws -> [Feature] {
        let query = metadata.selectSQL(
            boundingBox: nil,
            useRTree: false,
            limit: nil,
            offset: 0)
        let rows = try db.query(query.sql, values: query.values)

        var features = try rows.map { try metadata.feature(from: $0) }
        if let boundingBox {
            features = features.filter {
                $0.geometry != nil && $0.intersects(boundingBox)
            }
        }

        if offset > 0 {
            features = Array(features.dropFirst(offset))
        }
        if let limit {
            features = Array(features.prefix(limit))
        }
        return features
    }

}
