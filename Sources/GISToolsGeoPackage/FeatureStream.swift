import Foundation
import GISTools

/// An `AsyncSequence` that yields features from a GeoPackage feature table.
///
/// Features are fetched in bounded chunks, so the whole result set is never
/// loaded into memory. Row decoding is shared with
/// ``GeoPackageConnection/readFeatures(table:boundingBox:)``, which keeps
/// identifiers, properties and projection handling consistent between the
/// synchronous and streaming APIs.
///
/// ```swift
/// let gpkg = try await GeoPackageConnection(url: url)
/// for try await feature in gpkg.features(table: "countries") {
///     print(feature.id as Any)
/// }
/// ```
public struct FeatureStream: AsyncSequence, Sendable {

    public typealias Element = Feature

    /// Number of raw rows fetched per database round trip.
    private static let chunkSize = 500

    private let database: Database
    private let table: String
    private let boundingBox: BoundingBox?
    private let limit: Int?
    private let offset: Int

    /// Creates a stream backed by an existing database handle.
    ///
    /// Internal because ``GeoPackageConnection`` owns the connection.
    init(
        db: SQLiteDB,
        table: String,
        boundingBox: BoundingBox? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) {
        self.database = Database(db: db)
        self.table = table
        self.boundingBox = boundingBox
        self.limit = limit
        self.offset = offset
    }

    /// Creates a stream that opens its own read-only connection.
    ///
    /// The connection is closed when the stream (and all of its copies) are
    /// deallocated. Prefer
    /// ``GeoPackageConnection/features(table:boundingBox:limit:offset:)``
    /// when an existing connection should be reused.
    ///
    /// - Parameters:
    ///   - url: The GeoPackage file URL.
    ///   - table: The feature table name.
    ///   - boundingBox: An optional bounding box in any projection.
    ///   - limit: An optional maximum number of features.
    ///   - offset: The number of matching features to skip.
    /// - Throws: ``GeoPackageError`` if the file cannot be opened.
    public init(
        url: URL,
        table: String,
        boundingBox: BoundingBox? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws {
        self.database = try Database(url: url)
        self.table = table
        self.boundingBox = boundingBox
        self.limit = limit
        self.offset = offset
    }

    /// Creates the async iterator for the feature stream.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            database: database,
            table: table,
            boundingBox: boundingBox,
            limit: limit,
            offset: offset)
    }

    // MARK: - Connection owner

    /// Keeps an optionally owned connection alive for the lifetime of the
    /// stream. A struct cannot have a `deinit`, so the owner is a class.
    fileprivate final class Database: @unchecked Sendable {

        let db: SQLiteDB
        private let ownsConnection: Bool

        init(db: SQLiteDB) {
            self.db = db
            self.ownsConnection = false
        }

        init(url: URL) throws {
            self.db = try SQLiteDB(path: url.path, readOnly: true)
            self.ownsConnection = true
        }

        deinit {
            if ownsConnection {
                db.close()
            }
        }

    }

    // MARK: - Iterator

    /// An async iterator that yields features one at a time.
    /// Created by ``FeatureStream/makeAsyncIterator()``.
    public struct AsyncIterator: AsyncIteratorProtocol {

        private let database: Database
        private let table: String
        private let boundingBox: BoundingBox?
        private let limit: Int?
        private var skipRemaining: Int

        private var metadata: FeatureTableMetadata?
        private var useRTree = false
        private var fetchOffset = 0
        private var emitRemaining: Int?
        private var buffered: [Feature] = []
        private var bufferIndex = 0
        private var endReached = false
        private var started = false
        private var finished = false

        fileprivate init(
            database: Database,
            table: String,
            boundingBox: BoundingBox?,
            limit: Int?,
            offset: Int
        ) {
            self.database = database
            self.table = table
            self.boundingBox = boundingBox
            self.limit = limit
            self.skipRemaining = offset
        }

        public mutating func next() async throws -> Feature? {
            if finished { return nil }

            do {
                if !started {
                    try start()
                    started = true
                }
                if finished { return nil }
                return try nextFeature()
            }
            catch {
                finished = true
                throw error
            }
        }

        private mutating func start() throws {
            if let limit, limit < 0 {
                throw GeoPackageError.invalidArgument(
                    detail: "limit must not be negative")
            }
            guard skipRemaining >= 0 else {
                throw GeoPackageError.invalidArgument(
                    detail: "offset must not be negative")
            }

            let metadata = try FeatureTableMetadata.load(
                table: table, in: database.db)
            self.metadata = metadata
            if let boundingBox,
               !GeoPackage.crossesAntimeridian(boundingBox)
            {
                self.useRTree = try GeoPackage.hasRTreeIndex(
                    for: table,
                    column: metadata.geomColumnName,
                    in: database.db)
            }
            else {
                self.useRTree = false
            }
            self.emitRemaining = limit
            if limit == 0 {
                finished = true
            }
        }

        private mutating func nextFeature() throws -> Feature? {
            guard let metadata else { return nil }

            while true {
                if bufferIndex < buffered.count {
                    let feature = buffered[bufferIndex]
                    bufferIndex += 1

                    if self.boundingBox != nil, feature.geometry == nil {
                        continue
                    }
                    if let boundingBox, !feature.intersects(boundingBox) {
                        continue
                    }
                    if skipRemaining > 0 {
                        skipRemaining -= 1
                        continue
                    }
                    if let remaining = emitRemaining {
                        guard remaining > 0 else {
                            finished = true
                            return nil
                        }
                        emitRemaining = remaining - 1
                    }
                    return feature
                }

                if endReached {
                    finished = true
                    return nil
                }

                // Buffer exhausted: fetch the next chunk of raw rows.
                let query = metadata.selectSQL(
                    boundingBox: boundingBox,
                    useRTree: useRTree,
                    limit: FeatureStream.chunkSize,
                    offset: fetchOffset)
                let rows = try database.db.query(
                    query.sql, values: query.values)

                fetchOffset += rows.count
                buffered = try rows.map {
                    try metadata.feature(from: $0)
                }
                bufferIndex = 0

                if rows.isEmpty {
                    finished = true
                    return nil
                }
                if rows.count < FeatureStream.chunkSize {
                    // The next fetch would be empty. Drain this chunk and
                    // finish without an extra database round trip.
                    endReached = true
                }
            }
        }

    }

}
