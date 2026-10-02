import Foundation

/// A parsed Adobe `.cube` **3D** LUT.
///
/// The format is the de-facto standard for colour-correction cubes (Adobe's
/// Cube LUT Specification 1.0). BetterDisplay 5 supports the same file type
/// and spells out the same restrictions, which this parser enforces:
///
/// - UTF-8 **text** `.cube` files only.
/// - `LUT_3D_SIZE` must be **2…128**.
/// - One-dimensional (`LUT_1D_SIZE`) and mixed files are rejected outright —
///   they are a different lookup, not a smaller version of this one.
///
/// Parsing is pure and total: every malformed input produces a specific
/// `LUTCubeError` rather than a crash or a partially-applied correction, which
/// matters because a `.cube` file is user-supplied input.
public struct LUTCube: Equatable, Sendable {
    /// Cube edge length (`LUT_3D_SIZE`).
    public let size: Int
    /// `size³` RGB triplets, each component normalised to 0…1, **red varying
    /// fastest** — the `.cube` ordering convention.
    public let values: [Float]
    /// Optional `TITLE` line.
    public let title: String?

    public init(size: Int, values: [Float], title: String? = nil) {
        self.size = size
        self.values = values
        self.title = title
    }

    /// Number of scalar components (`size³ × 3`).
    public var componentCount: Int { size * size * size * 3 }
}

/// Why a `.cube` file could not be used. `Equatable` so tests can assert the
/// exact failure, not just that something failed.
public enum LUTCubeError: Error, Equatable {
    case unreadable(String)
    case notUTF8
    case tooLarge(bytes: Int, limit: Int)
    case empty
    case unsupportedDimension(String)
    case missingSize
    case invalidSize(Int)
    case invalidDomain(String)
    case invalidValue(String)
    case wrongEntryCount(expected: Int, found: Int)
}

/// Parser for Adobe `.cube` 3D LUT files. See `LUTCube`.
public enum LUTCubeParser {
    public static let minSize = 2
    public static let maxSize = 128
    /// Refuse oversized files before parsing a single float — a huge cube is
    /// a memory hazard, not a colour correction.
    public static let maxBytes = 16 * 1024 * 1024

    /// Parse LUT data. Throws `LUTCubeError` on any malformed input.
    public static func parse(_ data: Data) throws -> LUTCube {
        guard data.count <= maxBytes else {
            throw LUTCubeError.tooLarge(bytes: data.count, limit: maxBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LUTCubeError.notUTF8
        }
        return try parse(text)
    }

    /// Read and parse a `.cube` file at `url`.
    public static func parse(contentsOf url: URL) throws -> LUTCube {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LUTCubeError.unreadable(error.localizedDescription)
        }
        return try parse(data)
    }

    /// Parse `.cube` text.
    public static func parse(_ text: String) throws -> LUTCube {
        var title: String?
        var size: Int?
        var domainMin = SIMD3<Double>(0, 0, 0)
        var domainMax = SIMD3<Double>(1, 1, 1)
        var values: [Float] = []
        var sawAnyDirective = false

        // Split on any newline kind (LF, CR, CRLF) rather than an explicit
        // separator, so a CRLF or classic-Mac-authored file parses the same.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = fields.first else { continue }

            switch keyword.uppercased() {
            case "TITLE":
                sawAnyDirective = true
                // TITLE is conventionally quoted; keep the body verbatim.
                let body = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                title = body.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                // A 1D or mixed cube is a different lookup — refuse it rather
                // than silently treating it as 3D.
                throw LUTCubeError.unsupportedDimension(keyword.uppercased())

            case "LUT_3D_SIZE":
                sawAnyDirective = true
                guard fields.count == 2, let parsed = Int(fields[1]) else {
                    throw LUTCubeError.missingSize
                }
                guard (minSize...maxSize).contains(parsed) else {
                    throw LUTCubeError.invalidSize(parsed)
                }
                size = parsed

            case "LUT_3D_INPUT_RANGE":
                // Same domain for all three channels: min max.
                sawAnyDirective = true
                guard fields.count == 3,
                      let low = Double(fields[1]), let high = Double(fields[2]) else {
                    throw LUTCubeError.invalidDomain(line)
                }
                domainMin = SIMD3<Double>(low, low, low)
                domainMax = SIMD3<Double>(high, high, high)

            case "DOMAIN_MIN", "DOMAIN_MAX":
                sawAnyDirective = true
                guard fields.count == 4,
                      let r = Double(fields[1]), let g = Double(fields[2]), let b = Double(fields[3]) else {
                    throw LUTCubeError.invalidDomain(line)
                }
                let triple = SIMD3<Double>(r, g, b)
                if keyword.uppercased() == "DOMAIN_MIN" { domainMin = triple } else { domainMax = triple }

            default:
                // Anything else must be a data row: three floats.
                guard fields.count == 3 else {
                    throw LUTCubeError.invalidValue(line)
                }
                var rgb: [Float] = []
                rgb.reserveCapacity(3)
                for field in fields {
                    guard let component = Double(field), component.isFinite else {
                        throw LUTCubeError.invalidValue(line)
                    }
                    rgb.append(Float(component))
                }
                values.append(contentsOf: rgb)
            }
        }

        guard let size else {
            // Distinguish "no LUT_3D_SIZE at all" from an empty file.
            throw sawAnyDirective ? LUTCubeError.missingSize : LUTCubeError.empty
        }

        // Normalise a non-unit domain into 0…1 so the shader can index the cube
        // directly.
        let span = domainMax - domainMin
        if span != SIMD3<Double>(1, 1, 1) || domainMin != SIMD3<Double>(0, 0, 0) {
            guard span.x != 0, span.y != 0, span.z != 0 else {
                throw LUTCubeError.invalidDomain("DOMAIN_MIN \(domainMin) == DOMAIN_MAX \(domainMax)")
            }
            for index in values.indices {
                let axis = index % 3
                let minValue = axis == 0 ? domainMin.x : (axis == 1 ? domainMin.y : domainMin.z)
                let spanValue = axis == 0 ? span.x : (axis == 1 ? span.y : span.z)
                values[index] = Float((Double(values[index]) - minValue) / spanValue)
            }
        }

        let expected = size * size * size
        let found = values.count / 3
        guard found == expected, values.count % 3 == 0 else {
            throw LUTCubeError.wrongEntryCount(expected: expected, found: found)
        }

        return LUTCube(size: size, values: values, title: title)
    }
}
