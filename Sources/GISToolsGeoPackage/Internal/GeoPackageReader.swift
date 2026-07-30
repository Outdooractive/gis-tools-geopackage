import Foundation
import CSQLite
import GISTools

// MARK: - Reader

enum GeoPackageReader {

    static func readFeatures(
        from db: SQLiteDB,
        table: String,
        boundingBox: BoundingBox? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [Feature] {
        // Get geometry column metadata
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

        let geomColumnName = geomMeta["column_name"] as? String ?? "geom"
        let srsId = geomMeta["srs_id"] as? Int ?? 4326

        // Get all column info from the feature table
        let tableInfo = try db.query("PRAGMA table_info(\(quotedTable));")
        let columnNames: [String] = tableInfo.compactMap { $0["name"] as? String }

        guard !columnNames.isEmpty else {
            throw GeoPackageError.invalidGeoPackage(detail: "Table '\(table)' has no columns")
        }

        // Detect the GeoJSON id column: prefer an explicit `id` column, then
        // the common GeoPackage `fid` PK column. Values from this column are
        // promoted to `Feature.id` on read-back regardless of storage type.
        // Also detect the primary-key/rowid-alias column so it can be excluded
        // from properties and used as the source of `gpkgRowId`.
        let idColumnName: String? = {
            if columnNames.contains("id") { return "id" }
            if columnNames.contains("fid") { return "fid" }
            return nil
        }()
        // The INTEGER PRIMARY KEY column acts as the rowid alias. When present
        // it is excluded from `properties` and its value populates `gpkgRowId`.
        let pkColumnName: String? = {
            for col in tableInfo {
                // `pk` == 1 marks a single-column INTEGER PRIMARY KEY.
                if (col["pk"] as? Int ?? 0) > 0,
                   (col["type"] as? String ?? "").lowercased().contains("integer")
                {
                    return col["name"] as? String
                }
            }
            return nil
        }()

        // Resolve row IDs — use rtree index when available
        let rowIds: [Int]?
        if let bbox = boundingBox {
            if try GeoPackage.hasRTreeIndex(for: table, column: geomColumnName, in: db) {
                rowIds = try Self.readRowIdsFromRTree(
                    db: db,
                    table: table,
                    column: geomColumnName,
                    boundingBox: bbox)
            }
            else {
                rowIds = nil
            }
        }
        else {
            rowIds = nil
        }

        // Build the SQL query (include rowid for foreign key references)
        let selectSQL = "SELECT rowid, *"
        let limitSQL: String
        if let limit {
            limitSQL = " LIMIT \(limit) OFFSET \(offset)"
        }
        else {
            limitSQL = ""
        }

        let rows: [[String: Sendable]]
        if let rowIds,
           !rowIds.isEmpty,
           boundingBox != nil
        {
            let idList = rowIds.map(String.init).joined(separator: ", ")
            rows = try db.query("\(selectSQL) FROM \(quotedTable) WHERE rowid IN (\(idList))\(limitSQL);")
        }
        else {
            rows = try db.query("\(selectSQL) FROM \(quotedTable)\(limitSQL);")
        }

        var features: [Feature] = []
        for row in rows {
            guard let wkbData = row[geomColumnName] as? Data else {
                continue
            }

            let header = try WKBHeader.parse(wkbData)
            let geoJson = try WKBCoder.decode(wkb: header.wkbData, sourceSrid: header.srid)

            let projection = GeoPackage.projection(for: srsId)
            let projectedGeoJson = geoJson.projected(to: projection)
            let geometry = projectedGeoJson

            // Resolve the rowid / INTEGER PRIMARY KEY value. With
            // `SELECT rowid, *` on a table that has an INTEGER PRIMARY KEY
            // column (the spec-mandated `fid`), the first column is reported
            // with the PK column's name (e.g. "fid") rather than "rowid", so
            // look up several candidate keys. Prefer the explicit PK column,
            // then fall back to `rowid`, then to the `id` column.
            let gpkgRowId: Int? = {
                if let pk = pkColumnName, let v = row[pk] as? Int { return v }
                if let v = row["rowid"] as? Int { return v }
                if let v = row["id"] as? Int { return v }
                return nil
            }()

            // Promote the id/fid column value to the GeoJSON Feature.id based
            // on the runtime SQLite cell type, so typed columns round-trip with
            // type fidelity (INTEGER -> .int, REAL -> .double, TEXT -> .string).
            let featureId: Feature.Identifier?
            if let idColumnName, let raw = row[idColumnName] {
                switch raw {
                case let int as Int:
                    featureId = .int(int)
                case let int64 as Int64:
                    featureId = .int(Int(int64))
                case let double as Double:
                    featureId = .double(double)
                case let string as String:
                    featureId = .string(string)
                default:
                    featureId = .string("\(raw)")
                }
            }
            else {
                featureId = nil
            }

            var properties: [String: Sendable] = [:]
            for col in columnNames where col != geomColumnName
                                        && col != idColumnName
                                        && col != pkColumnName
            {
                guard let value = row[col] else { continue }
                if let data = value as? Data {
                    properties[col] = data.base64EncodedString()
                }
                else {
                    properties[col] = value
                }
            }

            var feature = Feature(geometry, id: featureId, properties: properties)
            feature.gpkgTableName = table
            feature.gpkgRowId = gpkgRowId
            features.append(feature)
        }

        // If we couldn't use rtree but a bounding box was requested,
        // filter in memory as a fallback
        if let bbox = boundingBox,
           rowIds == nil
        {
            features = features.filter { $0.intersects(bbox) }
        }

        return features
    }

    /// Queries the rtree virtual table for rowids intersecting a bounding box.
    private static func readRowIdsFromRTree(
        db: SQLiteDB,
        table: String,
        column: String,
        boundingBox: BoundingBox
    ) throws -> [Int]? {
        let rtreeName = GeoPackage.rTreeTableName(for: table, column: column)
        let minX = boundingBox.southWest.longitude
        let minY = boundingBox.southWest.latitude
        let maxX = boundingBox.northEast.longitude
        let maxY = boundingBox.northEast.latitude

        let rows = try db.query("""
            SELECT id FROM \(rtreeName)
            WHERE minx <= \(maxX)
              AND maxx >= \(minX)
              AND miny <= \(maxY)
              AND maxy >= \(minY);
            """)
        return rows.compactMap { $0["id"] as? Int }
    }

}
