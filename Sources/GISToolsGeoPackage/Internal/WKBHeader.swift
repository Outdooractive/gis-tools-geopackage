import Foundation
import GISTools

/// GeoPackage extends standard WKB with a binary header before each geometry.
///
/// Header format (GeoPackage 1.2, section 2.1.3):
/// - Magic: `"GP"` (2 bytes)
/// - Version: 1 byte (`0`)
/// - Flags: 1 byte — bit 0 header byte order (`1` = little endian),
///   bits 1…3 envelope indicator, bit 4 empty geometry, bit 5 extended type
/// - SRS ID: 4 bytes
/// - Envelope: 0, 4, 6 or 8 doubles depending on the indicator
///
/// Followed by standard Extended WKB.
enum WKBHeader {

    struct Header {
        let srid: Int
        let envelope: BoundingBox?
        let hasZ: Bool
        let hasM: Bool
        let isEmpty: Bool
        let wkbData: Data
    }

    /// Parse a GeoPackage WKB blob into its header and inner WKB payload.
    static func parse(_ data: Data) throws -> Header {
        // magic (2) + version (1) + flags (1) + srs_id (4)
        guard data.count >= 8 else {
            throw GeoPackageError.invalidWKB(
                detail: "Data too short for GeoPackage header")
        }

        var offset = 0

        guard data[offset] == 0x47, data[offset + 1] == 0x50 else {
            throw GeoPackageError.invalidWKB(
                detail: "Missing GeoPackage magic bytes")
        }
        offset += 2

        // Version byte. GeoPackage 1.2 uses 0; unknown versions are read
        // leniently so files from newer revisions remain accessible.
        offset += 1

        let flags = data[offset]
        offset += 1

        let headerIsLittleEndian = (flags & 0x01) != 0
        let isEmpty = (flags & 0x10) != 0
        let envelopeIndicator = Int((flags >> 1) & 0x07)

        guard envelopeIndicator <= 4 else {
            throw GeoPackageError.invalidWKB(
                detail: "Reserved envelope indicator \(envelopeIndicator)")
        }

        let srid = try readInt32(
            data, offset: &offset, bigEndian: !headerIsLittleEndian)

        var envelope: BoundingBox?
        if envelopeIndicator > 0 {
            let doubleCount: Int
            switch envelopeIndicator {
            case 1: doubleCount = 4 // minx, maxx, miny, maxy
            case 2: doubleCount = 6 // + minz, maxz
            case 3: doubleCount = 6 // + minm, maxm
            default: doubleCount = 8 // + minz, maxz, minm, maxm
            }

            guard data.count >= offset + (doubleCount * 8) else {
                throw GeoPackageError.invalidWKB(
                    detail: "Data too short for envelope")
            }

            let values = try (0 ..< doubleCount).map { _ in
                try readDouble(
                    data, offset: &offset, bigEndian: !headerIsLittleEndian)
            }

            envelope = GeoPackage.boundingBox(
                minX: values[0],
                minY: values[2],
                maxX: values[1],
                maxY: values[3],
                srsId: srid)
        }

        let wkbData = data.subdata(in: offset ..< data.count)
        guard wkbData.count >= 5 else {
            throw GeoPackageError.invalidWKB(
                detail: "Missing or truncated WKB geometry data")
        }

        let typeInfo = try parseWKBType(wkbData)

        return Header(
            srid: srid,
            envelope: envelope,
            hasZ: typeInfo.hasZ,
            hasM: typeInfo.hasM,
            isEmpty: isEmpty,
            wkbData: wkbData)
    }

    /// Prepend a GeoPackage header to a standard WKB payload.
    ///
    /// The header (SRS ID and envelope) is always written in little-endian
    /// byte order, matching the flags byte and the inner WKB encoder.
    ///
    /// - Parameters:
    ///   - wkb: The inner Extended WKB payload.
    ///   - srid: The SRS ID to store in the header.
    ///   - envelope: The optional 2D envelope.
    ///   - isEmpty: Whether the geometry is empty. This sets the header's
    ///     empty flag; it is **not** inferred from a missing envelope.
    static func prependHeader(
        to wkb: Data,
        srid: Int,
        envelope: BoundingBox?,
        isEmpty: Bool = false
    ) -> Data {
        var result = Data()

        result.append(contentsOf: [0x47, 0x50]) // "GP"
        result.append(0x00) // version

        // bit 0: header byte order (1 = little endian), bits 1…3: envelope
        // indicator (1 = 2D envelope), bit 4: empty geometry flag.
        var flags: UInt8 = 0x01
        if isEmpty {
            flags |= 0x10
        }
        if envelope != nil {
            flags |= 0x02
        }
        result.append(flags)

        appendInt32(&result, value: srid)

        if let envelope {
            appendDouble(&result, value: envelope.southWest.longitude) // minx
            appendDouble(&result, value: envelope.northEast.longitude) // maxx
            appendDouble(&result, value: envelope.southWest.latitude) // miny
            appendDouble(&result, value: envelope.northEast.latitude) // maxy
        }

        result.append(wkb)
        return result
    }

    // MARK: - Binary helpers

    private struct WKBType {
        let baseType: Int
        let hasZ: Bool
        let hasM: Bool
    }

    private static func parseWKBType(_ wkb: Data) throws -> WKBType {
        let typeEndianBig: Bool
        switch wkb[0] {
        case 0: typeEndianBig = true
        case 1: typeEndianBig = false
        default:
            throw GeoPackageError.invalidWKB(
                detail: "Invalid WKB byte-order marker \(wkb[0])")
        }

        guard wkb.count >= 5 else {
            throw GeoPackageError.invalidWKB(detail: "Truncated WKB type")
        }

        var raw = UInt32(0)
        for i in 0 ..< 4 {
            let byte = UInt32(wkb[1 + i])
            if typeEndianBig {
                raw = (raw << 8) | byte
            }
            else {
                raw |= byte << (8 * i)
            }
        }

        let ewkbZ = (raw & 0x8000_0000) != 0
        let ewkbM = (raw & 0x4000_0000) != 0
        var baseType = Int(raw & 0x0FFF_FFFF)

        // ISO WKB encodes Z/M dimensions by adding 1000/2000/3000.
        var isoZ = false
        var isoM = false
        if baseType >= 3000 {
            isoZ = true
            isoM = true
            baseType -= 3000
        }
        else if baseType >= 2000 {
            isoM = true
            baseType -= 2000
        }
        else if baseType >= 1000 {
            isoZ = true
            baseType -= 1000
        }

        return WKBType(
            baseType: baseType,
            hasZ: ewkbZ || isoZ,
            hasM: ewkbM || isoM)
    }

    private static func readInt32(
        _ data: Data,
        offset: inout Int,
        bigEndian: Bool
    ) throws -> Int {
        guard data.count >= offset + 4 else {
            throw GeoPackageError.invalidWKB(detail: "Truncated SRS ID")
        }

        var raw = UInt32(0)
        for i in 0 ..< 4 {
            let byte = UInt32(data[offset + i])
            if bigEndian {
                raw = (raw << 8) | byte
            }
            else {
                raw |= byte << (8 * i)
            }
        }
        offset += 4
        return Int(Int32(bitPattern: raw))
    }

    private static func readDouble(
        _ data: Data,
        offset: inout Int,
        bigEndian: Bool
    ) throws -> Double {
        guard data.count >= offset + 8 else {
            throw GeoPackageError.invalidWKB(detail: "Truncated envelope")
        }

        var raw = UInt64(0)
        for i in 0 ..< 8 {
            let byte = UInt64(data[offset + i])
            if bigEndian {
                raw = (raw << 8) | byte
            }
            else {
                raw |= byte << (8 * i)
            }
        }
        offset += 8
        return Double(bitPattern: raw)
    }

    private static func appendInt32(_ data: inout Data, value: Int) {
        let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        data.append(contentsOf: [
            UInt8(raw & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 24) & 0xFF),
        ])
    }

    private static func appendDouble(_ data: inout Data, value: Double) {
        let raw = value.bitPattern.littleEndian
        data.append(contentsOf: [
            UInt8(raw & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 32) & 0xFF),
            UInt8((raw >> 40) & 0xFF),
            UInt8((raw >> 48) & 0xFF),
            UInt8((raw >> 56) & 0xFF),
        ])
    }

}
