import Foundation

// MARK: - Validation result

/// The result of validating a GeoPackage file against the OGC GeoPackage 1.2 specification.
public struct GeoPackageValidation: Sendable {

    /// Whether the file passed all validation checks.
    public let isValid: Bool

    /// Fatal issues that violate the spec.
    public let errors: [GeoPackageValidationIssue]

    /// Non-fatal issues that may indicate problems.
    public let warnings: [GeoPackageValidationIssue]

    /// Creates a validation result.
    /// - Parameters:
    ///   - errors: Fatal spec violations.
    ///   - warnings: Non-fatal issues.
    public init(
        errors: [GeoPackageValidationIssue] = [],
        warnings: [GeoPackageValidationIssue] = []
    ) {
        self.errors = errors
        self.warnings = warnings
        self.isValid = errors.isEmpty
    }

}

/// A GeoPackage spec violation.  Each case carries the relevant context
/// and can produce a human-readable ``message``.
public enum GeoPackageValidationIssue: Sendable {

    /// The `application_id` PRAGMA is not `GP10` or `GPKG`.
    case invalidApplicationId

    /// The `user_version` PRAGMA is below 10200 (1.2.0).
    case invalidUserVersion

    /// A table required by the GeoPackage specification is missing.
    case missingMandatoryTable(_ table: String)

    /// A recommended but not mandatory table is missing.
    case missingRecommendedTable(_ table: String)

    /// A required column is missing from a metadata table.
    case missingRequiredColumn(_ table: String, _ column: String)

    /// `gpkg_spatial_ref_sys` exists but contains no entries.
    case emptySrsTable

    /// A `gpkg_contents` entry has a `data_type` value that is not one
    /// of the recognised types: `"features"`, `"tiles"`,
    /// `"2d-gridded-coverage"`, or `"attributes"`.
    case unknownDataType(_ table: String, _ type: String)

    /// A table referenced in `gpkg_contents` does not exist in the database.
    case missingReferencedTable(_ table: String)

    /// An SRS identifier referenced by a table does not exist in
    /// `gpkg_spatial_ref_sys`.
    case invalidSrsReference(_ context: String, _ srsId: Int)

    /// A `geometry_type_name` in `gpkg_geometry_columns` is not a
    /// recognised GeoPackage geometry type.
    case invalidGeometryType(_ table: String, _ type: String)

    /// The `z` column in `gpkg_geometry_columns` is not 0, 1, or 2.
    case invalidZValue(_ table: String, _ value: Int)

    /// The `m` column in `gpkg_geometry_columns` is not 0, 1, or 2.
    case invalidMValue(_ table: String, _ value: Int)

    /// A metadata table has an unexpected column structure.
    case invalidStructure(_ detail: String)

    /// `gpkg_tile_matrix_set` is missing while tile tables are registered
    /// in `gpkg_contents`.
    case missingTileMatrixSet

    /// `gpkg_tile_matrix` is missing while tile tables are registered
    /// in `gpkg_contents`.
    case missingTileMatrix

    /// A tile table listed in `gpkg_contents` has no corresponding
    /// entry in `gpkg_tile_matrix_set`.
    case missingTileMatrixEntry(_ table: String)

    /// An extension in `gpkg_extensions` has a `scope` other than
    /// `"read-write"` or `"write-only"`.
    case invalidExtensionScope(_ name: String, _ scope: String)

    /// Feature tables exist in `gpkg_contents` but
    /// `gpkg_geometry_columns` is empty.
    case missingGeometryColumnsForFeatures

    /// A human-readable message describing the issue.
    public var message: String {
        switch self {
        case .invalidApplicationId:
            "Invalid application_id — expected GP10 or GPKG"
        case .invalidUserVersion:
            "Invalid or missing user_version — expected >= 10200 (1.2.0)"
        case .missingMandatoryTable(let name):
            "Missing mandatory table: \(name)"
        case .missingRecommendedTable(let name):
            "Missing recommended table: \(name)"
        case .missingRequiredColumn(let table, let column):
            "\(table) missing required column: \(column)"
        case .emptySrsTable:
            "gpkg_spatial_ref_sys is empty — no SRS entries"
        case .unknownDataType(let table, let type):
            "gpkg_contents: '\(table)' has unknown data_type '\(type)'"
        case .missingReferencedTable(let table):
            "gpkg_contents: table '\(table)' does not exist"
        case .invalidSrsReference(let context, let id):
            "'\(context)' references non-existent srs_id \(id)"
        case .invalidGeometryType(let table, let type):
            "gpkg_geometry_columns: '\(table)' has invalid geometry_type '\(type)'"
        case .invalidZValue(let table, let value):
            "gpkg_geometry_columns: '\(table)' has invalid z value \(value)"
        case .invalidMValue(let table, let value):
            "gpkg_geometry_columns: '\(table)' has invalid m value \(value)"
        case .invalidStructure(let detail):
            "Invalid table structure: \(detail)"
        case .missingTileMatrixSet:
            "Missing gpkg_tile_matrix_set — required when tile tables exist"
        case .missingTileMatrix:
            "Missing gpkg_tile_matrix — required when tile tables exist"
        case .missingTileMatrixEntry(let table):
            "gpkg_tile_matrix_set: missing entry for tile table '\(table)'"
        case .invalidExtensionScope(let name, let scope):
            "gpkg_extensions: '\(name)' has invalid scope '\(scope)'"
        case .missingGeometryColumnsForFeatures:
            "gpkg_contents has feature tables but gpkg_geometry_columns is empty"
        }
    }

}
