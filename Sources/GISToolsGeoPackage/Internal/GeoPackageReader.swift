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

            let gpkgRowId = row["rowid"] as? Int ?? row["id"] as? Int

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

            var feature = Feature(geometry, properties: properties)
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
