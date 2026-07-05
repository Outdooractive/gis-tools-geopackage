import Foundation

/// A media table as defined by the GeoPackage Related Tables Extension.
///
/// Each row stores a media blob (image, document, etc.) with its
/// content type, and optionally additional user-defined columns.
public struct MediaTable: Sendable {

    /// The table name in the GeoPackage.
    public let tableName: String

    /// The row IDs (primary keys).
    public let rowIds: [Int64]

    /// The raw media data for each row.
    public let data: [Data]

    /// The MIME content type for each row (e.g. `"image/png"`).
    public let contentTypes: [String]

    /// Optional user-defined column values per row.
    public let properties: [[String: Sendable]]

    /// Creates a media table descriptor.
    /// - Parameters:
    ///   - tableName: The table name in the GeoPackage.
    ///   - rowIds: The primary key values.
    ///   - data: The raw media data for each row.
    ///   - contentTypes: The MIME content type for each row.
    ///   - properties: Optional user-defined column values per row.
    public init(
        tableName: String,
        rowIds: [Int64],
        data: [Data],
        contentTypes: [String],
        properties: [[String: Sendable]] = []
    ) {
        self.tableName = tableName
        self.rowIds = rowIds
        self.data = data
        self.contentTypes = contentTypes
        self.properties = properties
    }

    /// The number of rows in the table.
    public var count: Int { rowIds.count }

}
