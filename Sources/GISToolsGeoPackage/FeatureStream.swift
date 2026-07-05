import Foundation
import CSQLite
import GISTools

/// An `AsyncSequence` that yields features from a GeoPackage feature
/// table one at a time without loading the entire result set into memory.
public struct FeatureStream: AsyncSequence {

    public typealias Element = Feature
    private let db: SQLiteDB
    private let table: String
    private let boundingBox: BoundingBox?

    init(db: SQLiteDB,
         table: String,
         boundingBox: BoundingBox? = nil
    ) {
        self.db = db
        self.table = table
        self.boundingBox = boundingBox
    }

    /// Creates the async iterator for the feature stream.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(db: db, table: table, boundingBox: boundingBox)
    }

    /// An async iterator that yields features one at a time.
    /// Created by ``FeatureStream.makeAsyncIterator()``.
    public struct AsyncIterator: AsyncIteratorProtocol {

        private let db: SQLiteDB
        private let table: String
        private let boundingBox: BoundingBox?
        private var stmt: OpaquePointer?
        private var geomColumnName: String = "geom"
        private var srsId: Int = 4326
        private var columnNames: [String] = []
        private var started = false
        private var finished = false

        init(db: SQLiteDB,
             table: String,
             boundingBox: BoundingBox?
        ) {
            self.db = db
            self.table = table
            self.boundingBox = boundingBox
        }

        public mutating func next() async throws -> Feature? {
            if finished { return nil }
            if !started {
                try start()
                started = true
            }
            return fetchNext()
        }

        private mutating func start() throws {
            let escapedTable = GeoPackage.sanitizeStringLiteral(table)
            let quotedTable = GeoPackage.sanitizeIdentifier(table)

            let geomCols = try db.query(
                "SELECT column_name, geometry_type_name, srs_id, z, m FROM gpkg_geometry_columns WHERE table_name = \(escapedTable);")

            guard let geomMeta = geomCols.first else {
                throw GeoPackageError.invalidGeoPackage(detail: "Table '\(table)' not found in gpkg_geometry_columns")
            }
            guard geomCols.count == 1 else {
                throw GeoPackageError.mixedGeometryTypes(detail: "Table '\(table)' has multiple geometry columns")
            }

            geomColumnName = geomMeta["column_name"] as? String ?? "geom"
            srsId = geomMeta["srs_id"] as? Int ?? 4326

            let tableInfo = try db.query("PRAGMA table_info(\(quotedTable));")
            columnNames = tableInfo.compactMap { $0["name"] as? String }
            guard !columnNames.isEmpty else {
                throw GeoPackageError.invalidGeoPackage(detail: "Table '\(table)' has no columns")
            }

            let rtreeAvailable = try GeoPackage.hasRTreeIndex(for: table, column: geomColumnName, in: db)

            let selectSQL = "SELECT rowid, *"
            let rtreeJoinSQL: String
            if let bbox = boundingBox, rtreeAvailable {
                let rtreeName = GeoPackage.rTreeTableName(for: table, column: geomColumnName)
                let minX = bbox.southWest.longitude
                let minY = bbox.southWest.latitude
                let maxX = bbox.northEast.longitude
                let maxY = bbox.northEast.latitude
                rtreeJoinSQL = " INNER JOIN \(rtreeName) ON rowid = \(rtreeName).id WHERE \(rtreeName).minx <= \(maxX) AND \(rtreeName).maxx >= \(minX) AND \(rtreeName).miny <= \(maxY) AND \(rtreeName).maxy >= \(minY)"
            }
            else {
                rtreeJoinSQL = ""
            }

            let sql = "\(selectSQL) FROM \(quotedTable)\(rtreeJoinSQL);"
            stmt = try db.prepare(sql)
        }

        private mutating func fetchNext() -> Feature? {
            guard let stmt else { return nil }

            while true {
                let rc = sqlite3_step(stmt)
                guard rc == SQLITE_ROW else {
                    sqlite3_finalize(stmt)
                    self.stmt = nil
                    finished = true
                    return nil
                }

                let colCount = sqlite3_column_count(stmt)
                var row: [String: Sendable] = [:]
                for i in 0 ..< colCount {
                    guard let name = sqlite3_column_name(stmt, i).map({ String(cString: $0) }) else { continue }
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER:
                        row[name] = Int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT:
                        row[name] = sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT:
                        if let text = sqlite3_column_text(stmt, i) {
                            row[name] = String(cString: text)
                        }
                    case SQLITE_BLOB:
                        if let bytes = sqlite3_column_blob(stmt, i) {
                            let length = Int(sqlite3_column_bytes(stmt, i))
                            row[name] = Data(bytes: bytes, count: length)
                        }
                    default:
                        break
                    }
                }

                guard let wkbData = row[geomColumnName] as? Data,
                      let header = try? WKBHeader.parse(wkbData),
                      let geoJson = try? WKBCoder.decode(wkb: header.wkbData, sourceSrid: header.srid)
                else { continue }

                let projection = GeoPackage.projection(for: srsId)
                let projectedGeoJson = geoJson.projected(to: projection)

                let gpkgRowId = row["rowid"] as? Int

                var properties: [String: Sendable] = [:]
                for col in columnNames where col != geomColumnName {
                    guard let value = row[col] else { continue }
                    if let data = value as? Data {
                        properties[col] = data.base64EncodedString()
                    }
                    else {
                        properties[col] = value
                    }
                }

                var feature = Feature(projectedGeoJson, properties: properties)
                feature.gpkgTableName = table
                feature.gpkgRowId = gpkgRowId

                // In-memory bbox filter fallback for when rtree is unavailable
                if let bbox = boundingBox, !feature.intersects(bbox) {
                    continue
                }

                return feature
            }
        }
    }

}
