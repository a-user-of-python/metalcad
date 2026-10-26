import Foundation
import MetalCADKit

/// Aerodynamics study: Newtonian impact theory over a lattice of
/// parallel rays cast at the part (the DESIGN.md §1 model).
///
/// For every ray travelling along the unit wind vector `w` (the
/// direction the flow travels), the first surface hit with unit
/// outward normal `n` sees
///
///     cosθ = -(w · n)                     (windward iff cosθ > 0)
///     Cp   = 2·cos²θ                       (pressure coefficient)
///     dA   = rayCellArea / cosθ           (surface patch per ray)
///     dF   = -Cp · q · dA · n             (force on the body)
///     q    = ½ · ρ · v²                   (dynamic pressure)
///
/// summed over all contributing hits. Drag is the force component
/// along `w`, side force the perpendicular remainder, and the drag
/// coefficient is drag / (q · referenceArea).
///
/// Units: the kit works in **millimetres**, so hit points, areas and
/// the center of pressure are mm / mm². Wind speed is m/s and air
/// density kg/m³, so q is in pascals and — with panel areas converted
/// mm² → m² by ×1e-6 — every force comes out in **newtons**.
///
/// Honest limit (from the design): this is an attached-flow impact
/// model. It knows nothing about viscous separation, stall, or
/// turbulence, so Cd is an estimate — good for comparing shapes and
/// finding the pressure centroid, not wind-tunnel data.

// MARK: - Configuration

public struct AeroConfig {
    /// Direction the wind travels (need not be unit — it is
    /// normalised). Zero-length is `SimError.zeroDirection`.
    public var windDirection: Vec3 = Vec3(1, 0, 0)
    /// Wind speed, m/s. Must be ≥ 0 and finite.
    public var windSpeed: Double = 10
    /// Air density, kg/m³. Must be > 0 and finite.
    public var airDensity: Double = 1.225
    /// Ray lattice pitch, mm. When set it wins over the ray counts.
    /// When neither is set, a pitch of (largest bounds dimension / 100)
    /// is used. Must be > 0 and finite.
    public var raySpacing: Double? = nil
    /// Ray counts across the lattice's u / v axes. Used only when
    /// `raySpacing` is nil. Each must be ≥ 1.
    public var raysAcrossU: Int? = nil
    public var raysAcrossV: Int? = nil
    /// Reference area for the drag coefficient, mm². nil (the
    /// default) = the measured frontal area of this run.
    public var referenceArea: Double? = nil
    /// Point the center of pressure is reported relative to (the
    /// resultant acts on the wind-axis line through this point).
    /// nil = the mesh bounds center.
    public var referencePoint: Vec3? = nil
    /// Lee-side rule. Newtonian theory puts shadowed surfaces at
    /// Cp = 0; with `false` (default) only each ray's FIRST hit can
    /// contribute, which is exactly that rule for convex parts.
    /// With `true`, every surface crossing along the ray is examined
    /// and any crossing whose outward normal faces the wind
    /// (cosθ > 0) contributes by the same formula — a free-molecular
    /// style approximation that lets re-entrant (concave) surfaces
    /// past the first wall add their share. It does NOT model one
    /// surface shadowing another beyond the first hit.
    public var includeLeeSide: Bool = false
    /// Hard cap on lattice size; a finer request throws
    /// `SimError.invalidValue` instead of running forever.
    public var maxRays: Int = 4_000_000

    public init() {}
}

// MARK: - Results

/// One contributing ray hit, for a heat-map overlay.
public struct AeroSample: Equatable {
    /// Hit point, mm (mesh space).
    public var point: Vec3
    /// Unit outward surface normal at the hit.
    public var normal: Vec3
    /// Local pressure coefficient Cp = 2·cos²θ (dimensionless).
    public var pressureCoefficient: Double
    /// Force this panel applies to the body, N.
    public var force: Vec3

    public init(point: Vec3, normal: Vec3, pressureCoefficient: Double, force: Vec3) {
        self.point = point
        self.normal = normal
        self.pressureCoefficient = pressureCoefficient
        self.force = force
    }
}

public struct AeroResult {
    /// Total aerodynamic force on the body, N.
    public var totalForce: Vec3
    /// Component of the force along the wind direction, N (positive
    /// = pushed downstream). Divide by q·referenceArea for Cd.
    public var dragForce: Double
    /// Force perpendicular to the wind (lift + side), N.
    public var sideForce: Vec3
    /// dragForce / (q · referenceArea); 0 when that denominator is 0.
    public var dragCoefficient: Double
    /// Measured frontal (silhouette) area: rays that hit anything ×
    /// ray cell area, mm².
    public var frontalArea: Double
    /// Center of pressure, mm: the point on the wind-axis line
    /// through the reference point where the resultant force acts —
    /// precisely, the point on that line closest to the resultant's
    /// line of action (least-squares over the offset along the wind
    /// axis), which reduces to the reference point when the force is
    /// ~zero or acts exactly through it. Defined in `analyze`'s docs
    /// by construction; the moment component parallel to the force
    /// (a pure rolling moment) has no center of pressure and is not
    /// represented.
    public var centerOfPressure: Vec3
    /// Lattice rays cast / rays that hit the part at least once.
    public var raysCast: Int
    public var raysHit: Int
    /// Every contributing hit, row-major over the lattice (v rows,
    /// then u columns), for heat-map overlays.
    public var samples: [AeroSample]

    public init(totalForce: Vec3, dragForce: Double, sideForce: Vec3,
                dragCoefficient: Double, frontalArea: Double,
                centerOfPressure: Vec3, raysCast: Int, raysHit: Int,
                samples: [AeroSample]) {
        self.totalForce = totalForce
        self.dragForce = dragForce
        self.sideForce = sideForce
        self.dragCoefficient = dragCoefficient
        self.frontalArea = frontalArea
        self.centerOfPressure = centerOfPressure
        self.raysCast = raysCast
        self.raysHit = raysHit
        self.samples = samples
    }
}

/// One sweep direction's summary (an `AeroResult` without samples).
public struct AeroSweepEntry {
    public var yawDegrees: Double
    public var pitchDegrees: Double
    public var dragCoefficient: Double
    public var dragForce: Double
    public var totalForce: Vec3
    public var centerOfPressure: Vec3

    public init(yawDegrees: Double, pitchDegrees: Double, dragCoefficient: Double,
                dragForce: Double, totalForce: Vec3, centerOfPressure: Vec3) {
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.dragCoefficient = dragCoefficient
        self.dragForce = dragForce
        self.totalForce = totalForce
        self.centerOfPressure = centerOfPressure
    }
}

// MARK: - Study

public enum Aerodynamics {

    /// Run one wind direction over the mesh.
    /// - Throws: `SimError.emptyMesh`, `.zeroDirection`,
    ///   `.nonFiniteValue`, `.invalidValue` for bad config values.
    public static func analyze(mesh: Mesh, config: AeroConfig = AeroConfig()) throws -> AeroResult {
        let (w, refPoint) = try validated(mesh: mesh, config: config)
        let caster = RayCaster(mesh: mesh)
        return try run(mesh: mesh, caster: caster, config: config, w: w,
                       referencePoint: refPoint, collectSamples: true)
    }

    /// Vary the wind direction around `config.windDirection` and
    /// summarise each direction. Yaw rotates about the world +Z axis
    /// (the kit's up); pitch then rotates about the yawed lateral
    /// axis `normalize(w × up)` so positive pitch tilts the wind
    /// upward, toward +Z. Both ranges include their endpoints exactly
    /// (the step is adjusted by <1 step to land on the far endpoint).
    /// Entries are ordered yaw-major, then pitch.
    public static func sweep(mesh: Mesh, config: AeroConfig = AeroConfig(),
                             yawRange: ClosedRange<Double> = -90...90, yawStep: Double = 15,
                             pitchRange: ClosedRange<Double>? = nil,
                             pitchStep: Double = 15) throws -> [AeroSweepEntry] {
        let (w0, refPoint) = try validated(mesh: mesh, config: config)
        let yaws = try sweepValues(range: yawRange, step: yawStep, parameter: "yawStep")
        let pitches = try pitchRange.map { try sweepValues(range: $0, step: pitchStep, parameter: "pitchStep") } ?? [0.0]
        let caster = RayCaster(mesh: mesh)
        let up = Vec3(0, 0, 1)
        var entries: [AeroSweepEntry] = []
        entries.reserveCapacity(yaws.count * pitches.count)
        for yaw in yaws {
            let yawed = rotate(w0, axis: up, degrees: yaw)
            for pitch in pitches {
                var dir = yawed
                if pitch != 0 {
                    var axis = yawed.cross(up)
                    if axis.length < 1e-9 { axis = Vec3(1, 0, 0) }  // wind ∥ up: documented fallback
                    dir = rotate(yawed, axis: axis.normalized, degrees: pitch)
                }
                let r = try run(mesh: mesh, caster: caster, config: config, w: dir,
                                referencePoint: refPoint, collectSamples: false)
                entries.append(AeroSweepEntry(yawDegrees: yaw, pitchDegrees: pitch,
                                              dragCoefficient: r.dragCoefficient,
                                              dragForce: r.dragForce,
                                              totalForce: r.totalForce,
                                              centerOfPressure: r.centerOfPressure))
            }
        }
        return entries
    }

    // MARK: Validation

    /// Checks the config + mesh and returns the unit wind vector and
    /// the effective reference point.
    private static func validated(mesh: Mesh, config: AeroConfig) throws -> (w: Vec3, referencePoint: Vec3) {
        guard mesh.triangleCount > 0 else { throw SimError.emptyMesh }
        guard config.windDirection.isFinite() else { throw SimError.nonFiniteValue(parameter: "windDirection") }
        guard config.windDirection.length > 1e-12 else { throw SimError.zeroDirection(context: "wind") }
        guard config.windSpeed.isFinite else { throw SimError.nonFiniteValue(parameter: "windSpeed") }
        guard config.windSpeed >= 0 else {
            throw SimError.invalidValue(parameter: "windSpeed", detail: "speed must be ≥ 0 m/s")
        }
        guard config.airDensity.isFinite else { throw SimError.nonFiniteValue(parameter: "airDensity") }
        guard config.airDensity > 0 else {
            throw SimError.invalidValue(parameter: "airDensity", detail: "density must be > 0 kg/m³")
        }
        if let s = config.raySpacing {
            guard s.isFinite else { throw SimError.nonFiniteValue(parameter: "raySpacing") }
            guard s > 0 else { throw SimError.invalidValue(parameter: "raySpacing", detail: "spacing must be > 0 mm") }
        }
        if let n = config.raysAcrossU, n < 1 {
            throw SimError.invalidValue(parameter: "raysAcrossU", detail: "count must be ≥ 1")
        }
        if let n = config.raysAcrossV, n < 1 {
            throw SimError.invalidValue(parameter: "raysAcrossV", detail: "count must be ≥ 1")
        }
        if let a = config.referenceArea {
            guard a.isFinite else { throw SimError.nonFiniteValue(parameter: "referenceArea") }
            guard a > 0 else { throw SimError.invalidValue(parameter: "referenceArea", detail: "area must be > 0 mm²") }
        }
        if let p = config.referencePoint, !p.isFinite() {
            throw SimError.nonFiniteValue(parameter: "referencePoint")
        }
        guard config.maxRays >= 1 else {
            throw SimError.invalidValue(parameter: "maxRays", detail: "cap must be ≥ 1")
        }
        return (config.windDirection.normalized, config.referencePoint ?? mesh.bounds.center)
    }

    private static func sweepValues(range: ClosedRange<Double>, step: Double,
                                    parameter: String) throws -> [Double] {
        guard range.lowerBound.isFinite, range.upperBound.isFinite else {
            throw SimError.nonFiniteValue(parameter: parameter)
        }
        guard step.isFinite else { throw SimError.nonFiniteValue(parameter: parameter) }
        guard step > 0 else { throw SimError.invalidValue(parameter: parameter, detail: "step must be > 0°") }
        let span = range.upperBound - range.lowerBound
        if span == 0 { return [range.lowerBound] }
        let intervals = max(1, Int((span / step).rounded()))
        return (0...intervals).map { range.lowerBound + span * Double($0) / Double(intervals) }
    }

    /// Rodrigues rotation of `v` about a unit axis.
    private static func rotate(_ v: Vec3, axis k: Vec3, degrees: Double) -> Vec3 {
        let a = degrees * .pi / 180
        let c = cos(a), s = sin(a)
        return v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c))
    }

    // MARK: Core

    private static func run(mesh: Mesh, caster: RayCaster, config: AeroConfig,
                            w: Vec3, referencePoint: Vec3, collectSamples: Bool) throws -> AeroResult {
        let bounds = mesh.bounds
        let center = bounds.center

        // Lattice basis: u, v span the plane ⊥ w (u × v = w).
        let helper = abs(w.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
        let u = helper.cross(w).normalized
        let v = w.cross(u)

        // Projected footprint of the bounds corners on (u, v).
        var minU = Double.infinity, maxU = -Double.infinity
        var minV = Double.infinity, maxV = -Double.infinity
        for cx in [bounds.min.x, bounds.max.x] {
            for cy in [bounds.min.y, bounds.max.y] {
                for cz in [bounds.min.z, bounds.max.z] {
                    let rel = Vec3(cx, cy, cz) - center
                    let du = rel.dot(u), dv = rel.dot(v)
                    minU = min(minU, du); maxU = max(maxU, du)
                    minV = min(minV, dv); maxV = max(maxV, dv)
                }
            }
        }
        let spanU = maxU - minU, spanV = maxV - minV

        // Lattice resolution (spacing wins over counts; default pitch
        // = largest bounds dimension / 100). Counts are estimated in
        // Double and budget-checked before any Int conversion, so a
        // subnormal spacing throws instead of trapping.
        let size = bounds.size
        let defaultSpacing = max(size.x, size.y, size.z) / 100
        func axisCount(span: Double, explicit: Int?) throws -> Int {
            if let s = config.raySpacing { return try gridCount(span: span, spacing: s) }
            if let n = explicit { return n }
            return try gridCount(span: span, spacing: defaultSpacing)
        }
        let nU = try axisCount(span: spanU, explicit: config.raysAcrossU)
        let nV = try axisCount(span: spanV, explicit: config.raysAcrossV)
        guard Double(nU) * Double(nV) <= Double(config.maxRays) else {
            throw SimError.invalidValue(parameter: "raySpacing",
                                        detail: "lattice would need \(nU)×\(nV) rays, over the \(config.maxRays) cap")
        }
        // Cell pitch actually used (span split evenly, cell-centred rays).
        let cellU = nU > 0 ? spanU / Double(nU) : 0
        let cellV = nV > 0 ? spanV / Double(nV) : 0
        let cellArea = cellU * cellV   // mm²

        // Rays start half the bounds diagonal upstream of the center,
        // plus 1 mm — outside the part for any orientation.
        let startDistance = bounds.size.length / 2 + 1

        let q = 0.5 * config.airDensity * config.windSpeed * config.windSpeed  // Pa
        var totalForce = Vec3.zero
        var moment = Vec3.zero          // about referencePoint, N·mm
        var raysHit = 0
        var samples: [AeroSample] = []
        if collectSamples { samples.reserveCapacity(min(nU * nV, 1 << 20)) }

        for j in 0..<nV {
            let dv = minV + (Double(j) + 0.5) * cellV
            for i in 0..<nU {
                let du = minU + (Double(i) + 0.5) * cellU
                let planePoint = center + u * du + v * dv
                let origin = planePoint - w * startDistance
                var hitSomething = false
                var originCursor = origin
                // First hit always; further crossings only under the
                // lee-side rule (see AeroConfig.includeLeeSide). The
                // crossing cap only guards pathological geometry.
                var crossings = 0
                while crossings < 64 {
                    crossings += 1
                    guard let hit = caster.closestHit(origin: originCursor, direction: w) else { break }
                    hitSomething = true
                    let n = hit.normal
                    let cosT = -(w.dot(n))
                    if cosT > 1e-12, n.length > 0 {
                        let cp = 2 * cosT * cosT
                        let dA = cellArea / max(cosT, 1e-6)          // mm²
                        // -Cp·q·dA·n, with dA converted mm² → m².
                        let dF = n * (-cp * q * dA * 1e-6)
                        totalForce = totalForce + dF
                        moment = moment + (hit.point - referencePoint).cross(dF)
                        if collectSamples {
                            samples.append(AeroSample(point: hit.point, normal: n,
                                                      pressureCoefficient: cp, force: dF))
                        }
                    }
                    if !config.includeLeeSide { break }
                    originCursor = hit.point + w * 1e-6   // step past this wall
                }
                if hitSomething { raysHit += 1 }
            }
        }

        let raysCast = nU * nV
        let frontalArea = Double(raysHit) * cellArea   // mm²
        let drag = totalForce.dot(w)
        let side = totalForce - w * drag
        let refArea = config.referenceArea ?? frontalArea   // mm²
        let denom = q * refArea * 1e-6                      // N per unit Cd
        let cd = denom > 0 ? drag / denom : 0

        return AeroResult(totalForce: totalForce,
                          dragForce: drag,
                          sideForce: side,
                          dragCoefficient: cd,
                          frontalArea: frontalArea,
                          centerOfPressure: centerOfPressure(force: totalForce, moment: moment,
                                                             w: w, referencePoint: referencePoint),
                          raysCast: raysCast, raysHit: raysHit,
                          samples: collectSamples ? samples : [])
    }

    /// Cells needed to cover `span` at `spacing` (≥ 1). The estimate
    /// is formed in Double so an absurdly fine spacing throws
    /// `invalidValue` instead of trapping on Int conversion.
    private static func gridCount(span: Double, spacing: Double) throws -> Int {
        let est = span / spacing
        guard est < 1e8 else {
            throw SimError.invalidValue(parameter: "raySpacing",
                                        detail: "spacing \(spacing) mm is far too fine for this part")
        }
        return max(1, Int(est.rounded(.up)))
    }

    /// The point on the wind-axis line through `r` (direction `w`)
    /// where the resultant acts: least-squares closest point between
    /// that line and the resultant's line of action, whose closest
    /// point to `r` is x₀ = r + (F × M)/|F|² (the component of M
    /// parallel to F is a pure couple and drops out). When F ∥ w the
    /// offset along the axis is indeterminate from moments, so x₀'s
    /// projection on the axis is used. F ≈ 0 ⇒ the reference point.
    private static func centerOfPressure(force f: Vec3, moment m: Vec3,
                                         w: Vec3, referencePoint r: Vec3) -> Vec3 {
        let f2 = f.dot(f)
        guard f2 > 1e-24 else { return r }
        let x0 = r + f.cross(m) * (1 / f2)
        let fHat = f * (1 / f2.squareRoot())
        let c = w.dot(fHat)
        let denom = 1 - c * c
        let d = x0 - r
        let s: Double
        if denom > 1e-9 {
            s = (w.dot(d) - c * fHat.dot(d)) / denom
        } else {
            s = d.dot(w)
        }
        return r + w * s
    }
}
