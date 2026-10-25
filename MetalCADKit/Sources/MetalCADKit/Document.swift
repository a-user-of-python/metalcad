import Foundation

public enum PrimitiveKind: String, Codable, CaseIterable {
    case box, cylinder, sphere, cone, torus
}

public enum FeatureKind: Codable, Equatable {
    case pad(sketchID: String, length: Double)
    case pocket(sketchID: String, depth: Double)
    case revolve(sketchID: String, axisEntityID: Int, angleDegrees: Double)
    case primitive(kind: PrimitiveKind, params: [String: Double])
    case threadShaft(spec: ThreadSpec)
    case linearPattern(count: Int, spacing: Vec3)
    case fillet(radius: Double)
    case booleanCutPlaceholder
}

public struct Feature: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: FeatureKind
    public var suppressed: Bool = false
    public init(id: String = UUID().uuidString, name: String, kind: FeatureKind) {
        self.id = id; self.name = name; self.kind = kind
    }
}

public struct Part: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var sketches: [Sketch] = []
    public var features: [Feature] = []
    public init(id: String = UUID().uuidString, name: String) {
        self.id = id; self.name = name
    }
    public func sketch(_ id: String) -> Sketch? { sketches.first { $0.id == id } }
}

public struct CADDocument: Codable, Equatable, Identifiable {
    public static let currentFormatVersion = 1
    public var formatVersion: Int = CADDocument.currentFormatVersion
    public var id: String
    public var name: String
    public var parts: [Part] = []
    public var parameters: [String: Double] = [:]
    public init(id: String = UUID().uuidString, name: String) {
        self.id = id; self.name = name
    }
}

/// Per-feature outcome of a rebuild.
public struct FeatureStatus: Equatable {
    public var featureID: String
    public var ok: Bool
    public var errorCode: String?
    public var message: String?
}

public struct RebuildResult {
    public var mesh: Mesh
    public var statuses: [FeatureStatus]
    public var warnings: [CADError]
    public var firstError: CADError?
}

public enum DocumentEngine {

    /// Evaluate a part's feature tree into one accumulated mesh (v1: additive
    /// mesh accumulation; exact boolean cut/fillet/shell return their codes).
    /// Stops after the first failing feature, per ERRORS.md DC107.
    public static func rebuild(part: Part, logger: MCLog = .shared) -> RebuildResult {
        let start = Date()
        var body = Mesh()
        var statuses: [FeatureStatus] = []
        var warnings: [CADError] = []
        var firstError: CADError? = nil
        logger.debug(.feature, "rebuild start", context: ["part": part.name, "features": "\(part.features.count)"])

        for feature in part.features {
            if firstError != nil {
                statuses.append(FeatureStatus(featureID: feature.id, ok: false, errorCode: nil, message: "paused"))
                continue
            }
            if feature.suppressed {
                statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: "suppressed"))
                continue
            }
            do {
                var m: Mesh
                if case .linearPattern(let count, let spacing) = feature.kind {
                    // Pattern operates on the body built so far.
                    m = try DocumentEngine.applyPattern(mesh: body, count: count, spacing: spacing)
                    body = Mesh()
                    body.append(m)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "pattern ok", context: ["feature": feature.name, "count": "\(count)"])
                    continue
                }
                m = try evaluate(feature: feature, part: part, warnings: &warnings)
                body.append(m)
                statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                logger.debug(.feature, "feature ok", context: ["feature": feature.name, "tris": "\(m.triangleCount)"])
            } catch let e as CADError {
                let wrapped = CADError.featureRebuildFailed(feature: feature.name, underlyingCode: e.code)
                logger.log(error: e, category: .feature, context: ["feature": feature.name])
                logger.log(error: wrapped, category: .document, context: ["underlying": e.code])
                statuses.append(FeatureStatus(featureID: feature.id, ok: false, errorCode: e.code, message: e.userMessage))
                firstError = e
            } catch {
                let e = CADError.unknown("\(error)")
                logger.log(error: e, category: .feature, context: ["feature": feature.name])
                statuses.append(FeatureStatus(featureID: feature.id, ok: false, errorCode: e.code, message: e.userMessage))
                firstError = e
            }
        }
        logger.info(.perf, "rebuild done", context: [
            "ms": String(format: "%.1f", Date().timeIntervalSince(start) * 1000),
            "tris": "\(body.triangleCount)",
            "ok": firstError == nil ? "1" : "0",
        ])
        return RebuildResult(mesh: body, statuses: statuses, warnings: warnings, firstError: firstError)
    }

    static func evaluate(feature: Feature, part: Part, warnings: inout [CADError]) throws -> Mesh {
        switch feature.kind {
        case .pad(let sketchID, let length):
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            let (profiles, w) = try sketch.extractProfiles()
            warnings += w
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            return try Tessellation.extrude(profile: profile, plane: sketch.plane, length: length)
        case .pocket:
            throw CADError.booleanFailed("exact cut arrives with the OCCT kernel bridge")
        case .revolve(let sketchID, let axisEntityID, let angle):
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            guard let axisEnt = sketch.entity(axisEntityID),
                  case .line(_, let a, let b, _) = axisEnt else { throw CADError.revolveAxisMissing }
            let (profiles, w) = try sketch.extractProfiles()
            warnings += w
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            return try Tessellation.revolve(profile: profile, plane: sketch.plane,
                                             axisPoint: a, axisDirection: b - a, angleDegrees: angle)
        case .primitive(let kind, let p):
            switch kind {
            case .box:
                return try Tessellation.box(width: p["width"] ?? 10, depth: p["depth"] ?? 10, height: p["height"] ?? 10)
            case .cylinder:
                return try Tessellation.cylinder(radius: (p["diameter"] ?? 10) / 2, height: p["height"] ?? 10)
            case .sphere:
                return try Tessellation.sphere(radius: (p["diameter"] ?? 10) / 2)
            case .cone:
                return try Tessellation.cone(radius: (p["diameter"] ?? 10) / 2, height: p["height"] ?? 10)
            case .torus:
                return try Tessellation.torus(ringRadius: p["ringRadius"] ?? 15, tubeRadius: p["tubeRadius"] ?? 5)
            }
        case .threadShaft(let spec):
            return try ThreadTessellator.threadedShaft(spec: spec)
        case .linearPattern:
            throw CADError.invariantBroken("pattern must be handled by rebuild, not evaluate")
        case .fillet(let radius):
            throw CADError.filletFailed("radius \(radius): exact fillet arrives with the OCCT kernel bridge")
        case .booleanCutPlaceholder:
            throw CADError.booleanFailed("exact boolean arrives with the OCCT kernel bridge")
        }
    }

    /// Pattern needs the running body, so rebuild handles it specially:
    /// this helper is used by the app/tests to expand a mesh.
    public static func applyPattern(mesh: Mesh, count: Int, spacing: Vec3) throws -> Mesh {
        guard count >= 1, spacing.length > 0 else { throw CADError.patternCountInvalid(count) }
        var out = Mesh()
        for i in 0..<count { out.append(mesh.translated(by: spacing * Double(i))) }
        return out
    }
}

/// Formula evaluator for dimension equations: numbers, names, + - * / ^,
/// parentheses, sqrt/abs/min/max, pi. Throws DC111/DC112.
public enum EquationEvaluator {
    public static func evaluate(_ expr: String, variables: [String: Double]) throws -> Double {
        var parser = Parser(expr: expr, variables: variables)
        return try parser.parse()
    }

    struct Parser {
        let chars: [Character]
        var pos = 0
        let variables: [String: Double]
        init(expr: String, variables: [String: Double]) {
            self.chars = Array(expr)
            self.variables = variables
        }
        mutating func parse() throws -> Double {
            let v = try parseExpr()
            skipSpaces()
            guard pos >= chars.count else { throw CADError.equationParseError("trailing characters", position: pos) }
            guard v.isFinite else { throw CADError.equationEvalError("non-finite result") }
            return v
        }
        mutating func skipSpaces() { while pos < chars.count && chars[pos] == " " { pos += 1 } }
        mutating func parseExpr() throws -> Double {
            var v = try parseTerm()
            while true {
                skipSpaces()
                guard pos < chars.count else { return v }
                if chars[pos] == "+" { pos += 1; v += try parseTerm() }
                else if chars[pos] == "-" { pos += 1; v -= try parseTerm() }
                else { return v }
            }
        }
        mutating func parseTerm() throws -> Double {
            var v = try parseFactor()
            while true {
                skipSpaces()
                guard pos < chars.count else { return v }
                if chars[pos] == "*" { pos += 1; v *= try parseFactor() }
                else if chars[pos] == "/" {
                    pos += 1
                    let d = try parseFactor()
                    guard d != 0 else { throw CADError.equationEvalError("divide by zero") }
                    v /= d
                } else { return v }
            }
        }
        mutating func parseFactor() throws -> Double {
            var base = try parseAtom()
            skipSpaces()
            if pos < chars.count && chars[pos] == "^" {
                pos += 1
                let exp = try parseFactor()
                base = pow(base, exp)
            }
            return base
        }
        mutating func parseAtom() throws -> Double {
            skipSpaces()
            guard pos < chars.count else { throw CADError.equationParseError("unexpected end", position: pos) }
            let c = chars[pos]
            if c == "(" {
                pos += 1
                let v = try parseExpr()
                skipSpaces()
                guard pos < chars.count && chars[pos] == ")" else {
                    throw CADError.equationParseError("missing )", position: pos)
                }
                pos += 1
                return v
            }
            if c == "-" { pos += 1; return -(try parseAtom()) }
            if c.isNumber || c == "." {
                var s = ""
                while pos < chars.count && (chars[pos].isNumber || chars[pos] == ".") { s.append(chars[pos]); pos += 1 }
                guard let v = Double(s) else { throw CADError.equationParseError("bad number", position: pos) }
                return v
            }
            if c.isLetter || c == "_" {
                var s = ""
                while pos < chars.count && (chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_") { s.append(chars[pos]); pos += 1 }
                skipSpaces()
                if pos < chars.count && chars[pos] == "(" {
                    pos += 1
                    var args: [Double] = [try parseExpr()]
                    skipSpaces()
                    while pos < chars.count && chars[pos] == "," {
                        pos += 1; args.append(try parseExpr()); skipSpaces()
                    }
                    guard pos < chars.count && chars[pos] == ")" else {
                        throw CADError.equationParseError("missing )", position: pos)
                    }
                    pos += 1
                    switch s {
                    case "sqrt": guard args[0] >= 0 else { throw CADError.equationEvalError("sqrt of negative") }; return sqrt(args[0])
                    case "abs": return abs(args[0])
                    case "min": return args.min()!
                    case "max": return args.max()!
                    case "sin": return sin(args[0] * .pi / 180)
                    case "cos": return cos(args[0] * .pi / 180)
                    default: throw CADError.equationEvalError("unknown function \(s)")
                    }
                }
                if s == "pi" { return .pi }
                guard let v = variables[s] else { throw CADError.equationEvalError("unknown name \(s)") }
                return v
            }
            throw CADError.equationParseError("unexpected \(c)", position: pos)
        }
    }
}
