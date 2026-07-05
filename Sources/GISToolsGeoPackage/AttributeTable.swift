import Foundation

/// A non-spatial attribute table as defined by the GeoPackage spec.
/// Attribute tables have `data_type = "attributes"` and contain an
/// `INTEGER PRIMARY KEY` plus user-defined columns, but no geometry.
public struct AttributeTable: Sendable {

    /// The table name in the GeoPackage.
    public let tableName: String

    /// The column names (excluding `"id"`).
    public let columns: [String]

    /// The rows, each represented as a column-name→value dictionary
    /// without the `"id"` column (use `rowIds` for that).
    public let rows: [[String: Sendable]]

    /// The primary key values for each row, in the same order as `rows`.
    public let rowIds: [Int64]

    /// Creates an attribute table descriptor.
    /// - Parameters:
    ///   - tableName: The table name in the GeoPackage.
    ///   - columns: The user-defined column names (excluding `"id"`).
    ///   - rows: The row data, one dictionary per row.
    ///   - rowIds: The primary key values for each row.
    public init(
        tableName: String,
        columns: [String],
        rows: [[String: Sendable]],
        rowIds: [Int64]
    ) {
        self.tableName = tableName
        self.columns = columns
        self.rows = rows
        self.rowIds = rowIds
    }

}
