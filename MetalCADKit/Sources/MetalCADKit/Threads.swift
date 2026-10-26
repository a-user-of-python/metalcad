import Foundation

public enum ThreadHand: String, Codable { case right, left }
public enum ThreadKind: String, Codable { case external, `internal` }
public enum ThreadStandard: String, Codable { case isoMetric, unc, npt, custom }

/// A fully-customizable thread definition (DESIGN.md §8).
public struct ThreadSpec: Codable, Equatable {
    public var standard: ThreadStandard = .isoMetric
    public var kind: ThreadKind = .external
    public var hand: ThreadHand = .right
    public var starts: Int = 1
    public var majorDiameter: Double = 10      // mm
    public var pitch: Double = 1.5             // mm
    public var profileAngleDegrees: Double = 60
    public var taperDegrees: Double = 0        // NPT: 1.7899
    public var length: Double = 20             // mm of thread
    public var clearance: Double = 0           // fit offset added to the gap
    public var modeled: Bool = true            // false = cosmetic (v1: noted only)

    public init() {}

    /// ISO/UNC external thread depth (sharp-V approximation factor).
    public var threadDepth: Double { 0.61343 * pitch * (profileAngleDegrees == 60 ? 1 : tan(profileAngleDegrees * .pi / 360) / tan(30 * .pi / 180)) }
    public var minorDiameter: Double { majorDiameter - 2 * threadDepth }
    public var pitchDiameter: Double { majorDiameter - 0.64952 * pitch }
    public var lead: Double { pitch * Double(starts) }

    /// Named presets. Throws TH509 for unknown names.
    public static func preset(_ name: String) throws -> ThreadSpec {
        var s = ThreadSpec()
        let n = name.uppercased().replacingOccurrences(of: " ", with: "")
        let metric: [String: (Double, Double)] = [
            "M3": (3, 0.5), "M4": (4, 0.7), "M5": (5, 0.8), "M6": (6, 1.0),
            "M8": (8, 1.25), "M10": (10, 1.5), "M12": (12, 1.75), "M16": (16, 2.0), "M20": (20, 2.5),
        ]
        if let (d, p) = metric[n] { s.majorDiameter = d; s.pitch = p; return s }
        let uncTable: [String: (Double, Double)] = [   // name: (major mm, pitch mm)
            "1/4-20": (6.35, 25.4 / 20), "5/16-18": (7.938, 25.4 / 18),
            "3/8-16": (9.525, 25.4 / 16), "1/2-13": (12.7, 25.4 / 13),
        ]
        if let (d, p) = uncTable[n] { s.standard = .unc; s.majorDiameter = d; s.pitch = p; return s }
        if n.hasPrefix("NPT") {
            s.standard = .npt; s.taperDegrees = 1.7899
            if n.contains("1/2") { s.majorDiameter = 21.34; s.pitch = 25.4 / 14; return s }
            if n.contains("1/4") { s.majorDiameter = 13.72; s.pitch = 25.4 / 18; return s }
            if n.contains("3/8") { s.majorDiameter = 17.06; s.pitch = 25.4 / 18; return s }
        }
        throw CADError.threadPresetUnknown(name)
    }

    /// Validate; returns the spec, possibly with clamped values announced
    /// as warnings. Throws the TH errors on hard violations.
    public func validated(shaftLength: Double? = nil) throws -> (spec: ThreadSpec, warnings: [CADError]) {
        var s = self
        var warnings: [CADError] = []
        guard pitch > 0, pitch < majorDiameter else { throw CADError.threadPitchInvalid(pitch) }
        guard length > 0 else { throw CADError.threadProfileInvalid("thread length must be > 0") }
        guard majorDiameter > 0, minorDiameter > 0 else {
            throw CADError.threadDiameterInvalid(major: majorDiameter, minor: minorDiameter)
        }
        guard profileAngleDegrees >= 5, profileAngleDegrees <= 175 else {
            throw CADError.threadProfileInvalid("angle \(profileAngleDegrees)° outside 5–175")
        }
        guard starts >= 1, starts <= 4 else { throw CADError.threadStartsInvalid(starts) }
        guard taperDegrees >= 0, taperDegrees < 10 else { throw CADError.threadTaperInvalid(taperDegrees) }
        if taperDegrees > 0 {
            let endMajor = majorDiameter - 2 * tan(taperDegrees * .pi / 180) * length
            guard endMajor > minorDiameter else { throw CADError.threadTaperInvalid(taperDegrees) }
        }
        if let shaft = shaftLength, length > shaft {
            warnings.append(.threadTooLong(requested: length, clamped: shaft))
            s.length = shaft
        }
        // The ridge must not fold into itself: pitch must exceed depth * 0.8 per start.
        if pitch < threadDepth * 0.8 {
            throw CADError.threadSweepFailed("pitch \(pitch) too fine for depth \(threadDepth)")
        }
        if abs(clearance) > pitch * 0.25 {
            let clamped = (pitch * 0.25) * (clearance < 0 ? -1 : 1)
            warnings.append(.threadFitOutOfRange(clamped: clamped))
            s.clearance = clamped
        }
        return (s, warnings)
    }
}

/// Tessellates a modeled thread over a cylindrical shaft segment.
/// The shaft runs along +Z from z=0. Returns the thread ridge mesh
/// only. NOTE: never CSG-union the raw ridge into a body — BSP clip
/// dices any large face crossing the helix (a plate + M10 shaft went
/// 7.8k → 169k triangles that way). DocumentEngine merges threads by
/// unioning the plain core cylinder and APPENDING the ridge trimmed
/// at the body's surface (see the .threadShaft rebuild branch).
public enum ThreadTessellator {
    public static func ridgeMesh(spec s: ThreadSpec, baseZ: Double = 0,
                                 segmentsPerTurn: Int = 48) throws -> Mesh {
        let (spec, _) = try s.validated()
        let rOut = spec.majorDiameter / 2
        let rIn = spec.minorDiameter / 2
        let taper = tan(spec.taperDegrees * .pi / 180)
        // Trapezoid profile in (radial, axial) space, one pitch wide.
        // Fractions of pitch: root flat 1/4, crest flat 1/8 (ISO-ish).
        let p = spec.pitch
        let prof: [(r: Double, z: Double)] = [
            (rIn, -0.375 * p), (rOut, -0.0625 * p), (rOut, 0.0625 * p), (rIn, 0.375 * p),
        ]
        let totalTurns = spec.length / spec.lead
        let steps = max(4, Int(ceil(totalTurns * Double(segmentsPerTurn))))
        // Nothing capped the step count: length 300 m at pitch 1.5
        // asked for ~10M rings / 40M vertices and the tessellation
        // ran until the process died (2026-10-26 sweep). A million
        // steps is ~20k turns — metres of thread on any real pitch.
        guard steps <= 1_000_000 else {
            throw CADError.threadSweepFailed("thread is too long or too fine to tessellate (\(steps) steps)")
        }
        let handSign = spec.hand == .right ? 1.0 : -1.0
        var builder = MeshBuilder()
        // For each start, sweep the profile along the helix.
        for start in 0..<spec.starts {
            let phase = 2 * Double.pi * Double(start) / Double(spec.starts)
            var rings: [[UInt32]] = []
            for i in 0...steps {
                let t = Double(i) / Double(segmentsPerTurn)  // turns
                let ang = phase + handSign * t * 2 * Double.pi
                let zc = baseZ + t * spec.lead
                let shrink = taper * (zc - baseZ)
                var ring: [UInt32] = []
                for (pr, pz) in prof {
                    let r = pr - shrink + (spec.kind == .internal ? spec.clearance : -spec.clearance) * 0
                    let z = zc + pz
                    if z < baseZ - 1e-9 || z > baseZ + spec.length + 1e-9 { ring.append(UInt32.max); continue }
                    ring.append(builder.vertex(Vec3(cos(ang) * r, sin(ang) * r, z)))
                }
                rings.append(ring)
            }
            for i in 0..<(rings.count - 1) {
                for j in prof.indices {
                    let j2 = (j + 1) % prof.count
                    let a = rings[i][j], b = rings[i][j2], c = rings[i + 1][j2], d = rings[i + 1][j]
                    if [a, b, c, d].contains(UInt32.max) { continue }
                    if spec.kind == .external {
                        builder.quad(a, d, c, b)
                    } else {
                        builder.quad(a, b, c, d)  // inward-facing
                    }
                }
            }
        }
        if builder.mesh.hasNaN { throw CADError.threadSweepFailed("NaN in tessellation") }
        return builder.mesh
    }

    /// Full threaded shaft: plain cylinder (root diameter) + ridge.
    public static func threadedShaft(spec s: ThreadSpec, baseZ: Double = 0) throws -> Mesh {
        let (spec, _) = try s.validated()
        var m = try Tessellation.cylinder(radius: spec.minorDiameter / 2, height: spec.length,
                                          baseZ: baseZ, taperDegrees: spec.taperDegrees)
        m.append(try ridgeMesh(spec: spec, baseZ: baseZ))
        return m
    }
}
