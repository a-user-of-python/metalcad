import Foundation
import MetalCADKit

/// Buoyancy / hydrostatics study (DESIGN.md §6) — **mesh-exact**, no
/// voxel grid. Every mesh triangle is clipped against the waterline
/// plane and the clipped pieces are summed as signed tetrahedra, so
/// submerged volume and the center of buoyancy are exact for the
/// tessellation (a box cut at mid-height is exact to float dust).
///
/// Conventions (read before trusting a sign):
/// - The waterline plane is `waterlinePoint` + unit `waterlineNormal`
///   n̂, which points **up, out of the water**. A point p is submerged
///   iff (p − point)·n̂ < 0.
/// - The part's center of mass G is the full-mesh signed-volume
///   centroid (uniform density from `SimMaterial`).
/// - The tilt axis t̂ is the config axis **projected into the
///   waterplane** (and normalised); m̂ = n̂ × t̂ completes the frame.
/// - Stability is evaluated with the **fixed-trim approximation**:
///   for each tilt angle the mesh is rotated about the axis line
///   through G and re-clipped at the *same world-fixed waterline* —
///   the part does **not** heave (sink/rise) to re-balance its
///   displacement as a freely floating body would. GZ therefore
///   answers "which way does buoyancy push, and how hard, if the
///   part is held at this waterline and tilted", which is the right
///   question for comparing shapes at a design draft.
/// - GM is the classical section-based metacentric height at θ = 0:
///   GM = KB + BM − KG with BM = I / V_submerged, I the waterplane
///   section's second moment of area about the tilt axis through the
///   section centroid, and KB / KG measured along n̂ from the part's
///   lowest point (the vertex with the smallest (p − point)·n̂).
///   The reference cancels: GM = (B − G)·n̂ + I / V_submerged.
///
/// Units: kit millimetres throughout (volumes mm³, arms mm), with
/// m³ / kg conversions on the result. Densities are kg/m³.

// MARK: - Configuration

public struct BuoyancyConfig {
    /// Any point on the waterplane, mm. Must be finite.
    public var waterlinePoint: Vec3 = Vec3(0, 0, 0)
    /// Waterplane normal, pointing up out of the water (need not be
    /// unit — it is normalised). Zero-length is
    /// `SimError.zeroDirection`.
    public var waterlineNormal: Vec3 = Vec3(0, 0, 1)
    /// Fluid density, kg/m³. Must be > 0 and finite. 1000 = fresh
    /// water; see `seawater(material:)` for the 1025 preset.
    public var fluidDensityKgM3: Double = 1000
    /// The part's material (uniform density). Required — buoyancy is
    /// meaningless without a part density.
    public var material: SimMaterial
    /// Tilt axis: the part is rolled about the axis through its
    /// center of mass in this direction. It is projected into the
    /// waterplane before use; an axis parallel to the waterline
    /// normal (nothing left after projection) is
    /// `SimError.zeroDirection`.
    public var tiltAxis: Vec3 = Vec3(1, 0, 0)
    /// Tilt angles for the righting-arm sweep, degrees. May be empty
    /// (no sweep) and may hold negative angles.
    public var tiltAnglesDegrees: [Double] = [5, 10]

    public init(material: SimMaterial) {
        self.material = material
    }

    /// Fresh-water config (1000 kg/m³).
    public static func freshWater(material: SimMaterial) -> BuoyancyConfig {
        BuoyancyConfig(material: material)
    }

    /// Seawater preset: fluid density 1025 kg/m³.
    public static func seawater(material: SimMaterial) -> BuoyancyConfig {
        var c = BuoyancyConfig(material: material)
        c.fluidDensityKgM3 = 1025
        return c
    }
}

// MARK: - Results

/// Float/sink verdict from comparing the part's mass against the
/// mass of fluid it displaces at **full** submersion.
public enum FloatVerdict: Equatable {
    /// Part density < fluid density: it floats. `reserveFraction`
    /// is the fraction of the part's volume that stays above the
    /// water at equilibrium (= 1 − partMass / fullDisplacementMass).
    case floats(reserveFraction: Double)
    /// Densities equal (within 1e-9 relative): neutrally buoyant,
    /// awash at full submersion.
    case floatsAwash
    /// Part density > fluid density: it sinks.
    case sinks
}

/// Righting arm at one imposed tilt angle.
public struct BuoyancyRightingArm: Equatable {
    /// The imposed tilt, degrees (as configured).
    public var degrees: Double
    /// Righting arm GZ, mm: the offset of the center of buoyancy
    /// from the center of mass's vertical (n̂) line, measured along
    /// −m̂, so that for a positive tilt a **positive GZ pushes the
    /// part back upright** (the buoyancy resultant acts on the
    /// immersed side of G). For small angles GZ ≈ GM · sin θ.
    public var gzMM: Double
    /// True when the buoyancy moment opposes the imposed tilt
    /// (GZ has the same sign as the tilt). Tilt angles whose rotated
    /// part is entirely out of the water have no center of buoyancy
    /// and are **omitted** from the result's `rightingArms`.
    public var restoring: Bool

    public init(degrees: Double, gzMM: Double, restoring: Bool) {
        self.degrees = degrees
        self.gzMM = gzMM
        self.restoring = restoring
    }
}

public struct BuoyancyResult {
    /// Volume below the waterline, mm³ (mesh-exact clipped sum).
    public var submergedVolumeMM3: Double
    /// Same, m³.
    public var submergedVolumeM3: Double
    /// submergedVolume / full volume, 0...1.
    public var submergedFraction: Double
    /// Mass of fluid displaced by the submerged part, kg.
    public var displacedMassKg: Double
    /// Mass of the whole part, kg (uniform material density).
    public var partMassKg: Double
    /// Float/sink verdict (full-submersion comparison — returned
    /// even when the configured waterline leaves the part dry).
    public var verdict: FloatVerdict
    /// Center of buoyancy B, mm (mesh space) — the centroid of the
    /// submerged volume. nil when nothing is submerged.
    public var centerOfBuoyancy: Vec3?
    /// Center of mass G, mm (mesh space).
    public var centerOfMass: Vec3
    /// Metacentric height GM at θ = 0, mm (see the type docs for the
    /// convention). Positive = stable at small angles. nil when
    /// nothing is submerged (BM undefined).
    public var metacentricHeightMM: Double?
    /// Righting arms at the configured tilt angles (angles whose
    /// tilted part is fully dry are omitted — see
    /// `BuoyancyRightingArm.restoring`).
    public var rightingArms: [BuoyancyRightingArm]
    /// Area of the mesh's section by the waterplane, mm². Exact for
    /// simply-connected sections; sections with holes use the
    /// even–odd rule (nested loops subtract). 0 when the waterline
    /// misses the part or is fully submerged.
    public var waterplaneAreaMM2: Double
    /// Second moment of the waterplane section about the tilt axis
    /// through the section centroid, mm⁴ — the I in BM = I / V.
    public var waterplaneSecondMomentMM4: Double
}

// MARK: - Study

public enum Buoyancy {

    public static func analyze(mesh: Mesh, config: BuoyancyConfig) throws -> BuoyancyResult {
        // MARK: Validation
        guard mesh.triangleCount > 0 else { throw SimError.emptyMesh }
        // The kit's `hasNaN` tests `isFinite()` per vertex, so it
        // rejects infinities as well as NaNs.
        guard !mesh.hasNaN else { throw SimError.nonFiniteValue(parameter: "mesh vertices") }
        let rawNormal = config.waterlineNormal
        guard rawNormal.isFinite() else {
            throw SimError.nonFiniteValue(parameter: "waterlineNormal")
        }
        guard rawNormal.length > 1e-12 else {
            throw SimError.zeroDirection(context: "waterline normal")
        }
        guard config.waterlinePoint.isFinite() else {
            throw SimError.nonFiniteValue(parameter: "waterlinePoint")
        }
        let rhoF = config.fluidDensityKgM3
        guard rhoF.isFinite else {
            throw SimError.nonFiniteValue(parameter: "fluidDensityKgM3")
        }
        guard rhoF > 0 else {
            throw SimError.invalidValue(parameter: "fluidDensityKgM3",
                                        detail: "must be > 0, got \(rhoF)")
        }
        let rhoP = config.material.densityKgM3
        guard rhoP.isFinite, rhoP > 0 else {
            throw SimError.invalidValue(parameter: "material density",
                                        detail: "must be > 0, got \(rhoP)")
        }
        for a in config.tiltAnglesDegrees where !a.isFinite {
            throw SimError.nonFiniteValue(parameter: "tiltAnglesDegrees")
        }

        let n = rawNormal.normalized
        let planePoint = config.waterlinePoint

        // Tilt axis projected into the waterplane.
        let rawAxis = config.tiltAxis
        guard rawAxis.isFinite() else {
            throw SimError.nonFiniteValue(parameter: "tiltAxis")
        }
        let projected = rawAxis - n * rawAxis.dot(n)
        guard projected.length > 1e-12 else {
            throw SimError.zeroDirection(context: "tilt axis")
        }
        let t = projected.normalized
        let m = n.cross(t)   // in-plane, ⊥ t̂; t̂ × m̂ = n̂

        // MARK: Full-mesh volume + center of mass
        let (fullSigned, com) = signedVolumeAndCentroid(mesh: mesh,
                                                        apex: mesh.bounds.center)
        guard abs(fullSigned) > 1e-9 else {
            throw SimError.invalidValue(parameter: "mesh",
                                        detail: "zero-volume mesh — buoyancy needs a closed solid")
        }
        let winding: Double = fullSigned < 0 ? -1 : 1
        let fullVolume = abs(fullSigned)

        // MARK: Submerged volume + center of buoyancy at θ = 0
        let base = clippedVolume(mesh: mesh, planePoint: planePoint, normal: n)
        let submergedVolume = max(0, base.signedVolume * winding)
        let submergedThreshold = fullVolume * 1e-12
        let cob: Vec3? = (submergedVolume > submergedThreshold) ? base.centroid : nil

        // MARK: Waterplane section (θ = 0)
        let section = waterplaneSection(mesh: mesh, planePoint: planePoint,
                                        normal: n, axisU: t, axisW: m)

        // MARK: GM = KB + BM − KG (reference = part's lowest point)
        var gm: Double? = nil
        if let b = cob {
            let lowest = mesh.vertices.map { ($0 - planePoint).dot(n) }.min() ?? 0
            let kb = (b - planePoint).dot(n) - lowest
            let kg = (com - planePoint).dot(n) - lowest
            let bm = section.secondMoment / submergedVolume
            gm = kb + bm - kg
        }

        // MARK: Tilt sweep — fixed waterline, no heave (see docs)
        var arms: [BuoyancyRightingArm] = []
        for degrees in config.tiltAnglesDegrees {
            let theta = degrees * Double.pi / 180
            let rotated = rotatedVertices(mesh: mesh, about: com, axis: t, radians: theta)
            let clip = clippedVolume(vertices: rotated, indices: mesh.indices,
                                     planePoint: planePoint, normal: n)
            let vol = clip.signedVolume * winding
            guard vol > submergedThreshold, let b = clip.centroid else { continue }
            // Positive when B moves toward the immersed side (−m̂
            // for a positive tilt about +t̂), i.e. restoring.
            let gz = -(b - com).dot(m)
            arms.append(BuoyancyRightingArm(degrees: degrees, gzMM: gz,
                                            restoring: gz * sin(theta) > 1e-9))
        }

        // MARK: Masses + verdict (full-submersion comparison)
        let partMass = rhoP * fullVolume * 1e-9            // mm³ → m³
        let displacedMass = rhoF * submergedVolume * 1e-9
        let fullDisplacementMass = rhoF * fullVolume * 1e-9
        let ratio = partMass / fullDisplacementMass       // = ρp / ρf
        let verdict: FloatVerdict
        if ratio < 1 - 1e-9 {
            verdict = .floats(reserveFraction: 1 - ratio)
        } else if ratio > 1 + 1e-9 {
            verdict = .sinks
        } else {
            verdict = .floatsAwash
        }

        return BuoyancyResult(
            submergedVolumeMM3: submergedVolume,
            submergedVolumeM3: submergedVolume * 1e-9,
            submergedFraction: submergedVolume / fullVolume,
            displacedMassKg: displacedMass,
            partMassKg: partMass,
            verdict: verdict,
            centerOfBuoyancy: cob,
            centerOfMass: com,
            metacentricHeightMM: gm,
            rightingArms: arms,
            waterplaneAreaMM2: section.area,
            waterplaneSecondMomentMM4: section.secondMoment)
    }

    // MARK: - Signed volume + centroid (divergence theorem)

    /// Signed volume and centroid of a closed mesh from tetrahedra
    /// (apex, a, b, c). The centroid is winding-sign invariant (both
    /// sums flip together); the volume keeps the mesh's sign.
    private static func signedVolumeAndCentroid(mesh: Mesh, apex: Vec3)
        -> (signedVolume: Double, centroid: Vec3) {
        var v = 0.0
        var moment = Vec3.zero
        let idx = mesh.indices, verts = mesh.vertices
        for tri in stride(from: 0, to: idx.count, by: 3) {
            let a = verts[Int(idx[tri])], b = verts[Int(idx[tri + 1])], c = verts[Int(idx[tri + 2])]
            accumulate(a: a, b: b, c: c, apex: apex, volume: &v, moment: &moment)
        }
        return (v, v != 0 ? moment * (1 / v) : apex)
    }

    private static func accumulate(a: Vec3, b: Vec3, c: Vec3, apex: Vec3,
                                   volume: inout Double, moment: inout Vec3) {
        let tet = (a - apex).dot((b - apex).cross(c - apex)) / 6
        volume += tet
        moment = moment + (apex + a + b + c) * (tet / 4)
    }

    // MARK: - Clipping against the waterline half-space

    /// Volume + centroid of the part of the mesh on the submerged
    /// side (d ≤ 0). Tetrahedra are taken about the waterline point
    /// itself, which lies *in* the plane — the waterplane cap that
    /// closes the clipped solid is coplanar with the apex, so its
    /// tetrahedra have zero volume and never need building.
    private static func clippedVolume(mesh: Mesh, planePoint: Vec3, normal: Vec3)
        -> (signedVolume: Double, centroid: Vec3?) {
        clippedVolume(vertices: mesh.vertices, indices: mesh.indices,
                      planePoint: planePoint, normal: normal)
    }

    private static func clippedVolume(vertices: [Vec3], indices: [UInt32],
                                      planePoint: Vec3, normal: Vec3)
        -> (signedVolume: Double, centroid: Vec3?) {
        var v = 0.0
        var moment = Vec3.zero
        for tri in stride(from: 0, to: indices.count, by: 3) {
            let a = vertices[Int(indices[tri])]
            let b = vertices[Int(indices[tri + 1])]
            let c = vertices[Int(indices[tri + 2])]
            let poly = clipPolygon([a, b, c], planePoint: planePoint, normal: normal)
            guard poly.count >= 3 else { continue }
            for i in 1..<(poly.count - 1) {
                accumulate(a: poly[0], b: poly[i], c: poly[i + 1],
                           apex: planePoint, volume: &v, moment: &moment)
            }
        }
        return (v, v != 0 ? moment * (1 / v) : nil)
    }

    /// Sutherland–Hodgman clip of one polygon against d(p) ≤ 0,
    /// d(p) = (p − planePoint)·normal. Boundary points (d == 0)
    /// count as inside; their cap tetrahedra vanish anyway (see
    /// `clippedVolume`).
    private static func clipPolygon(_ poly: [Vec3], planePoint: Vec3, normal: Vec3) -> [Vec3] {
        func d(_ p: Vec3) -> Double { (p - planePoint).dot(normal) }
        var out: [Vec3] = []
        guard let first = poly.last else { return out }
        var s = first, ds = d(s)
        for e in poly {
            let de = d(e)
            if de <= 0 {                       // e inside
                if ds > 0 {                    // entering: crossing first
                    out.append(s + (e - s) * (ds / (ds - de)))
                }
                out.append(e)
            } else if ds <= 0 {                // leaving: crossing only
                out.append(s + (e - s) * (ds / (ds - de)))
            }
            s = e; ds = de
        }
        return out
    }

    // MARK: - Rotation (Rodrigues, about an axis through `center`)

    private static func rotatedVertices(mesh: Mesh, about center: Vec3,
                                        axis t: Vec3, radians theta: Double) -> [Vec3] {
        let cosT = cos(theta), sinT = sin(theta)
        return mesh.vertices.map { v in
            let r = v - center
            return center + r * cosT + t.cross(r) * sinT + t * (t.dot(r) * (1 - cosT))
        }
    }

    // MARK: - Waterplane section

    /// The section of the mesh by the waterplane: area, centroid
    /// (internal), and second moment of area about the tilt axis
    /// through the section centroid. Loops are chained from
    /// per-triangle intersection segments in a fixed sorted order
    /// (deterministic); nested loops apply the even–odd rule.
    private struct Section {
        var area: Double = 0
        var secondMoment: Double = 0
    }

    private struct PointKey: Hashable, Comparable {
        var x: Int64, y: Int64, z: Int64
        static func < (a: PointKey, b: PointKey) -> Bool {
            (a.x, a.y, a.z) < (b.x, b.y, b.z)
        }
    }

    /// Endpoint identity at 1e-6 mm — far above float dust from
    /// shared-edge intersection math, far below any real feature.
    private static func key(of p: Vec3) -> PointKey {
        PointKey(x: Int64((p.x * 1e6).rounded()),
                 y: Int64((p.y * 1e6).rounded()),
                 z: Int64((p.z * 1e6).rounded()))
    }

    private static func waterplaneSection(mesh: Mesh, planePoint: Vec3, normal n: Vec3,
                                          axisU t: Vec3, axisW m: Vec3) -> Section {
        func d(_ p: Vec3) -> Double { (p - planePoint).dot(n) }

        // 1. One segment per straddling triangle (endpoints deduped
        //    by key, so a vertex lying exactly on the plane is one
        //    point, not two).
        struct Seg { var a: Vec3, b: Vec3, ka: PointKey, kb: PointKey }
        var segs: [Seg] = []
        let idx = mesh.indices, verts = mesh.vertices
        for tri in stride(from: 0, to: idx.count, by: 3) {
            let tri3 = [verts[Int(idx[tri])], verts[Int(idx[tri + 1])], verts[Int(idx[tri + 2])]]
            var pts: [Vec3] = []
            var seen = Set<PointKey>()
            for e in 0..<3 {
                let a = tri3[e], b = tri3[(e + 1) % 3]
                let da = d(a), db = d(b)
                guard (da < 0) != (db < 0) || da == 0 || db == 0 else { continue }
                // Crossing point; when an endpoint is on the plane
                // the crossing is that endpoint.
                let p: Vec3
                if da == 0 { p = a }
                else if db == 0 { p = b }
                else if (da < 0) != (db < 0) { p = a + (b - a) * (da / (da - db)) }
                else { continue }
                let k = key(of: p)
                if seen.insert(k).inserted { pts.append(p) }
            }
            guard pts.count == 2 else { continue }
            var ka = key(of: pts[0]), kb = key(of: pts[1])
            guard ka != kb else { continue }   // degenerate stub
            var a = pts[0], b = pts[1]
            if kb < ka { swap(&ka, &kb); swap(&a, &b) }   // canonical order
            segs.append(Seg(a: a, b: b, ka: ka, kb: kb))
        }
        guard !segs.isEmpty else { return Section() }
        segs.sort { ($0.ka, $0.kb) < ($1.ka, $1.kb) }

        // 2. Chain segments into loops (adjacency in sorted order —
        //    deterministic even at ambiguous junctions).
        var byEndpoint: [PointKey: [Int]] = [:]
        for (i, s) in segs.enumerated() {
            byEndpoint[s.ka, default: []].append(i)
            byEndpoint[s.kb, default: []].append(i)
        }
        var used = [Bool](repeating: false, count: segs.count)
        var loops: [[Vec3]] = []
        for start in segs.indices where !used[start] {
            used[start] = true
            var points = [segs[start].a, segs[start].b]
            let startKey = segs[start].ka
            var currentKey = segs[start].kb
            var closed = false
            while currentKey != startKey {
                guard let candidates = byEndpoint[currentKey],
                      let next = candidates.first(where: { !used[$0] }) else { break }
                used[next] = true
                let s = segs[next]
                let other = (s.ka == currentKey) ? s.b : s.a
                let otherKey = (s.ka == currentKey) ? s.kb : s.ka
                points.append(other)
                currentKey = otherKey
                if currentKey == startKey { closed = true }
            }
            if closed, points.count >= 3 {
                points.removeLast()   // last point repeats the start
                loops.append(points)
            }
        }
        guard !loops.isEmpty else { return Section() }

        // 3. Per-loop area / centroid / own-axis second moment in
        //    the plane basis (s along t̂, w along m̂, origin at the
        //    waterline point).
        struct Loop { var area: Double; var cs: Double; var cw: Double; var iOwn: Double; var poly2: [(Double, Double)] }
        var loopData: [Loop] = []
        for loop in loops {
            let p2: [(Double, Double)] = loop.map { p in
                let r = p - planePoint
                return (r.dot(t), r.dot(m))
            }
            var crossSum = 0.0, cxSum = 0.0, cySum = 0.0
            for i in p2.indices {
                let (x0, y0) = p2[i], (x1, y1) = p2[(i + 1) % p2.count]
                let cr = x0 * y1 - x1 * y0
                crossSum += cr
                cxSum += (x0 + x1) * cr
                cySum += (y0 + y1) * cr
            }
            let signedArea = 0.5 * crossSum
            guard abs(signedArea) > 1e-9 else { continue }
            let cs = cxSum / (6 * signedArea)
            let cw = cySum / (6 * signedArea)
            // Second moment about the axis through the loop's own
            // centroid, parallel to t̂: I = ∫∫ (w − cw)² dA.
            var iSum = 0.0
            for i in p2.indices {
                let (x0, y0) = (p2[i].0, p2[i].1 - cw), (x1, y1) = (p2[(i + 1) % p2.count].0, p2[(i + 1) % p2.count].1 - cw)
                let cr = x0 * y1 - x1 * y0
                iSum += cr * (y0 * y0 + y0 * y1 + y1 * y1)
            }
            loopData.append(Loop(area: abs(signedArea), cs: cs, cw: cw,
                                 iOwn: abs(iSum) / 12, poly2: p2))
        }
        guard !loopData.isEmpty else { return Section() }

        // 4. Even–odd nesting: a loop inside an odd number of other
        //    loops is a hole and subtracts.
        func contains(_ poly: [(Double, Double)], _ pt: (Double, Double)) -> Bool {
            var inside = false
            for i in poly.indices {
                let (x0, y0) = poly[i], (x1, y1) = poly[(i + 1) % poly.count]
                if (y0 > pt.1) != (y1 > pt.1) {
                    let xInt = x0 + (pt.1 - y0) * (x1 - x0) / (y1 - y0)
                    if pt.0 < xInt { inside.toggle() }
                }
            }
            return inside
        }
        var signs: [Double] = []
        for (j, lj) in loopData.enumerated() {
            var depth = 0
            for (k, lk) in loopData.enumerated() where k != j {
                if contains(lk.poly2, lj.poly2[0]) { depth += 1 }
            }
            signs.append(depth % 2 == 0 ? 1 : -1)
        }

        var totalArea = 0.0, csAcc = 0.0, cwAcc = 0.0
        for (j, lj) in loopData.enumerated() {
            totalArea += signs[j] * lj.area
            csAcc += signs[j] * lj.area * lj.cs
            cwAcc += signs[j] * lj.area * lj.cw
        }
        guard totalArea > 1e-9 else { return Section() }
        let cwTotal = cwAcc / totalArea
        var iTotal = 0.0
        for (j, lj) in loopData.enumerated() {
            let dw = lj.cw - cwTotal
            iTotal += signs[j] * (lj.iOwn + lj.area * dw * dw)
        }
        _ = csAcc   // centroid along t̂ is not needed by any consumer
        return Section(area: totalArea, secondMoment: max(0, iTotal))
    }
}
