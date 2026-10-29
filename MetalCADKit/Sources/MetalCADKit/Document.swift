import Foundation

public enum PrimitiveKind: String, Codable, CaseIterable {
    case box, cylinder, sphere, cone, torus
}

public enum HoleKind: Codable, Equatable {
    case simple
    case counterbore(diameter: Double, depth: Double)
    case countersink(angleDegrees: Double)
}

public enum MirrorPlane: String, Codable, CaseIterable {
    case yz, xz, xy
    public var axis: Int { self == .yz ? 0 : (self == .xz ? 1 : 2) }
    public var displayName: String { rawValue.uppercased() + " plane" }
}

public enum ExtrudeMode: Codable, Equatable {
    case one
    case symmetric
    case twoSided(second: Double)
}

/// How an additive feature combines with the running body (v4).
public enum BodyOperation: String, Codable, Equatable {
    case join, cut, intersect, newBody
}

/// Where an extrude stops (v4).
public enum ExtrudeEnd: Codable, Equatable {
    case dimension
    case throughAll
    case upToFace(faceIndex: Int)
}

/// Chamfer sizing modes (v4).
public enum ChamferMode: Codable, Equatable {
    case equal(Double)
    case twoDistances(Double, Double)
    case distanceAngle(Double, Double)  // distance along face A, angle from face A
    public var distances: (Double, Double) {
        switch self {
        case .equal(let d): return (d, d)
        case .twoDistances(let a, let b): return (a, b)
        case .distanceAngle(let d, let deg):
            let t = tan(deg * Double.pi / 180)
            return (d, t > 1e-6 ? d / t : d * 1000)
        }
    }
}

public enum FeatureKind: Codable, Equatable {
    case pad(sketchID: String, length: Double)
    case pocket(sketchID: String, depth: Double)
    case revolve(sketchID: String, axisEntityID: Int, angleDegrees: Double)
    case primitive(kind: PrimitiveKind, params: [String: Double])
    case threadShaft(spec: ThreadSpec)
    case linearPattern(count: Int, spacing: Vec3)
    case hole(sketchID: String, diameter: Double, depth: Double, kind: HoleKind)
    case mirror(plane: MirrorPlane)
    case fillet(radius: Double)
    case chamfer(distance: Double)
    case shell(thickness: Double)
    case extrude(sketchID: String, distance: Double, taperDegrees: Double, mode: ExtrudeMode)
    case loft(sketchA: String, sketchB: String)
    case sweep(profileSketchID: String, pathSketchID: String)
    // v4 additions (appended — existing cases keep their encoding).
    case extrude2(sketchID: String, distance: Double, taperDegrees: Double, mode: ExtrudeMode, operation: BodyOperation, end: ExtrudeEnd)
    case chamfer2(mode: ChamferMode)
    case coil(radius: Double, pitch: Double, turns: Double, wireRadius: Double)
    case pipe(pathSketchID: String, radius: Double)
    case rib(sketchID: String, thickness: Double, depth: Double)
    case draftBody(angleDegrees: Double, pullAxis: Int)
    case scaleBody(factors: Vec3)
    case moveBody(translation: Vec3, rotationAxis: Int, rotationDegrees: Double)
    case splitBody(axis: Int, offset: Double)
    case circularPattern(count: Int, axis: Int, totalDegrees: Double)
    // v4.1 additions (appended — existing cases keep their encoding).
    case filletEdges(radius: Double, midpoints: [Vec3])
    case chamferEdges(distance: Double, midpoints: [Vec3])
    case threadOnShaft(spec: ThreadSpec, origin: Vec3, axis: Vec3)
    case booleanCutPlaceholder
    // Cascade implant (appended — existing cases keep their encoding).
    case cascadePad(sketchID: String, length: Double)
    // Full-OCCT migration (appended): the pocket counterpart of
    // cascadePad — a sketch prism cut by the engine.
    case cascadePocket(sketchID: String, depth: Double)
    // Stage 7 (appended): an imported STEP file as a base feature.
    // The STEP bytes travel inside the document (base64 in the
    // JSON) so the document stays a single self-contained file;
    // on rebuild the bytes are staged to a temp file and imported
    // through the engine. As the first feature it seeds the body;
    // appearing later it finishes the current body and starts a
    // new one (the `.newBody` rule every base feature follows).
    case importedSTEP(name: String, stepData: Data)
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
    public var materialID: String = MaterialLibrary.defaultMaterial.id
    public init(id: String = UUID().uuidString, name: String) {
        self.id = id; self.name = name
    }
    public func sketch(_ id: String) -> Sketch? { sketches.first { $0.id == id } }
    public var material: Material { MaterialLibrary.byID(materialID) ?? MaterialLibrary.defaultMaterial }
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
    /// All solid bodies (v4 multi-body); `mesh` is their concatenation.
    public var bodies: [Mesh] = []
    public var statuses: [FeatureStatus]
    public var warnings: [CADError]
    public var firstError: CADError?
    /// Mass in grams from the part's material density; nil if no material.
    public var massGrams: Double? = nil
    /// Stage 6: a retained reference to the final engine solid,
    /// present only when the rebuild ended on one and its display
    /// tessellation carried census face ranges. Sketch-on-face
    /// resolves picked triangles through it. Releasing the result
    /// releases the engine handle (the snapshot's deinit).
    public var engineBody: EngineBodySnapshot? = nil
    /// Stage 7b: STEP surface colours for bodies that came from an
    /// `.importedSTEP` feature and reached the output UNMODIFIED
    /// (the colours are census data of the imported handle; any
    /// feature that replaces the handle invalidates them, and the
    /// body then renders in the part material as usual).
    public var bodyFaceColors: [BodyFaceColors] = []
}

/// Stage 7b: one output body's imported STEP colours — the census
/// face of each of the body's triangles plus the colour table in
/// census order. Rebuild-time only; never persisted.
public struct BodyFaceColors: Equatable {
    /// Index into `RebuildResult.bodies`.
    public var bodyIndex: Int
    /// Census face index per triangle of that body (the body's own
    /// tessellation ranges, as in `EngineBodySnapshot`).
    public var faceOfTriangle: [Int]
    /// Colour per census face.
    public var faceColors: [CensusFaceColor]
    public init(bodyIndex: Int, faceOfTriangle: [Int], faceColors: [CensusFaceColor]) {
        self.bodyIndex = bodyIndex
        self.faceOfTriangle = faceOfTriangle
        self.faceColors = faceColors
    }
}

public enum DocumentEngine {

    /// Evaluator for `.cascadePad` features, registered by the app at
    /// launch (the Open CASCADE implant, 2026-10-28). The kit stays
    /// pure Swift: it hands the hook the sketch + length and receives
    /// the tessellated mesh plus the kernel's own volume (mm^3).
    /// Nil in kit-only contexts (unit tests register a stub) — a
    /// cascadePad with no hook fails MCAD-KN601, never silently.
    public static var cascadePadEvaluator: ((Sketch, Double) throws -> (mesh: Mesh, volume: Double))?

    /// The generalized Cascade kernel (full-OCCT migration,
    /// 2026-10-28): when the app registers a provider, every
    /// migrated feature rebuilds through OCCT and composition is
    /// exact. Nil in kit-only contexts — unmigrated and migrated
    /// features alike then use the legacy tessellation path, and a
    /// Cascade-only kind (`.cascadePocket`) fails MCAD-KN601.
    public static var cascadeProvider: (any CascadeKernelProvider)?

    /// Linear deflection (mm) used when an engine solid is
    /// tessellated for display during rebuild. Stage 7 took this
    /// from 0.1 to 0.02 (Sean's v1 fix list, item 6 — the preview
    /// must not show visible triangles): the preview is smooth-
    /// shaded (crease-averaged normals in the renderer) over this
    /// finer tessellation. STL/OBJ export is untouched — it still
    /// writes the welded rebuild mesh exactly as before.
    public static var previewDeflection: Double = 0.02

    /// Largest STEP payload an `.importedSTEP` feature may carry
    /// inside a document (Stage 7). The bytes live in the
    /// document's JSON, so an unbounded import would balloon every
    /// save; past the cap the import fails MCAD-IO702 in plain
    /// words instead.
    public static var maxImportedSTEPBytes: Int = 25 * 1024 * 1024

    /// The outcome of evaluating a part's feature list — the
    /// shared core of `rebuild` (tessellate + release) and
    /// `exportSTEP` (export + release). Stage 7 factored the walk
    /// out so the two consumers share exactly one implementation
    /// and can never drift. Engine handles in `engineBodies` /
    /// `runningSolid` are NOT released by the evaluation:
    /// ownership passes to the caller, which must release each
    /// exactly once (or transfer the running solid to an
    /// `EngineBodySnapshot`, which releases it on deinit).
    struct FeatureEvaluation {
        var statuses: [FeatureStatus] = []
        var warnings: [CADError] = []
        var firstError: CADError? = nil
        /// Bodies completed as meshes during the walk (bodies the
        /// engine no longer holds — see `meshBlocker`).
        var meshBodies: [Mesh] = []
        /// Completed engine body handles, in body order.
        var engineBodies: [Int] = []
        /// The final running body when it is an engine solid.
        var runningSolid: Int? = nil
        /// The final running body when it is a mesh.
        var runningMesh = Mesh()
        /// Cached display tessellation of `runningSolid` (filled
        /// only when something asked for the mesh mid-walk), with
        /// its census face ranges.
        var runningSolidMesh: Mesh? = nil
        var runningFaceOfTriangle: [Int] = []
        /// STEP colours by engine handle, for handles that came
        /// from `.importedSTEP` (Stage 7b). A body's colours are
        /// valid only while that exact handle reaches the output
        /// unmodified — any op replaces the handle, which retires
        /// the entry by key mismatch.
        var faceColorsByHandle: [Int: [CensusFaceColor]] = [:]
        /// Name of the first feature that forced the running body
        /// out of the engine into a mesh, if any — STEP export
        /// names it in its refusal.
        var meshBlocker: String? = nil
    }

    /// Walk a part's features once, stopping after the first
    /// failing feature, per ERRORS.md DC107.
    static func evaluateFeatures(part: Part, logger: MCLog) -> FeatureEvaluation {
        var body = Mesh()
        var bodies: [Mesh] = []  // completed bodies (v4 multi-body)
        var statuses: [FeatureStatus] = []
        var warnings: [CADError] = []
        var firstError: CADError? = nil
        logger.debug(.feature, "rebuild start", context: ["part": part.name, "features": "\(part.features.count)"])

        // Full-OCCT migration state. When a kernel provider is
        // registered, the running body may live in the engine as an
        // opaque handle (`solid`); `body` then holds its tessellation
        // only after something mesh-side asks for it. Composition is
        // exact (engine booleans) while both sides are solids. A
        // feature kind that has no engine path yet materialises the
        // body back to a mesh first (releasing the handle), so legacy
        // behaviour is preserved bit-for-bit in mixed chains.
        let provider = DocumentEngine.cascadeProvider
        var solid: Int? = nil
        var solidMesh: Mesh? = nil     // tessellation cache for `solid`
        var solidFaceOfTriangle: [Int] = []  // census ranges paired with `solidMesh`
        var solidBodies: [Int] = []    // completed engine bodies
        var engineFaceColors: [Int: [CensusFaceColor]] = [:]  // Stage 7b, by handle
        var meshBlocker: String? = nil  // first feature that materialised the body

        /// The running body as a mesh (tessellating the engine
        /// solid on first ask). The tessellation is taken WITH its
        /// census face ranges: the pair is only ever filled here,
        /// together, so the ranges always describe `solidMesh` —
        /// Stage 6's end-of-rebuild snapshot relies on that.
        func currentMesh() throws -> Mesh {
            if let h = solid {
                if solidMesh == nil {
                    let t = try provider!.tessellateWithFaceRanges(h, deflection: DocumentEngine.previewDeflection)
                    solidMesh = t.mesh
                    solidFaceOfTriangle = t.faceOfTriangle
                }
                return solidMesh!
            }
            return body
        }
        /// Degrade the running body to its mesh (legacy features).
        func materializeBody() throws {
            if let h = solid {
                body = try currentMesh()
                provider?.release(h)
                solid = nil
                solidMesh = nil
            }
        }
        /// Boolean-combine the running body with a tool SOLID.
        /// Empty-body rules mirror the legacy mesh code: join adopts
        /// the tool, cut/intersect on an empty body throw
        /// booleanEmptyResult, newBody finishes the current body.
        func booleanWithSolid(_ tool: Int, _ op: BodyOperation) throws {
            guard let p = provider else { throw CADError.kernelUnavailable }
            switch op {
            case .newBody:
                if let h = solid { solidBodies.append(h); solid = nil; solidMesh = nil }
                else if body.triangleCount > 0 { bodies.append(body); body = Mesh() }
                solid = tool
                solidMesh = nil
            case .join:
                if let h = solid {
                    let r = try p.unite(h, tool)
                    p.release(h); p.release(tool)
                    solid = r; solidMesh = nil
                } else if body.triangleCount > 0 {
                    let tm = try p.tessellate(tool, deflection: DocumentEngine.previewDeflection)
                    p.release(tool)
                    body = try CSG.union(body, tm)
                } else {
                    solid = tool; solidMesh = nil
                }
            case .cut:
                if let h = solid {
                    let r = try p.subtract(h, tool)
                    p.release(h); p.release(tool)
                    solid = r; solidMesh = nil
                } else if body.triangleCount > 0 {
                    let tm = try p.tessellate(tool, deflection: DocumentEngine.previewDeflection)
                    p.release(tool)
                    body = try CSG.subtract(body, tm)
                } else {
                    p.release(tool)
                    throw CADError.booleanEmptyResult
                }
            case .intersect:
                if let h = solid {
                    let r = try p.intersect(h, tool)
                    p.release(h); p.release(tool)
                    solid = r; solidMesh = nil
                } else if body.triangleCount > 0 {
                    let tm = try p.tessellate(tool, deflection: DocumentEngine.previewDeflection)
                    p.release(tool)
                    body = try CSG.intersect(body, tm)
                } else {
                    p.release(tool)
                    throw CADError.booleanEmptyResult
                }
            }
        }
        /// Feature kinds whose rebuild branch is engine-aware at
        /// this migration stage; everything else materialises the
        /// body to a mesh before its legacy branch runs.
        func kindIsSolidAware(_ kind: FeatureKind) -> Bool {
            switch kind {
            case .cascadePad, .cascadePocket, .importedSTEP,
                 .pad, .pocket, .revolve, .primitive, .extrude, .extrude2,
                 .fillet, .chamfer, .shell, .chamfer2, .filletEdges, .chamferEdges,
                 .draftBody, .rib, .splitBody,
                 .loft, .sweep, .hole, .coil, .pipe, .threadShaft, .threadOnShaft,
                 .linearPattern, .circularPattern, .mirror, .scaleBody, .moveBody:
                return true
            default: return false
            }
        }

        /// Extrude span (offset, along) along the sketch normal for
        /// an extrude mode, mirroring the legacy mesh construction:
        /// `.one` = [0, d], `.symmetric` = centred on the plane,
        /// `.twoSided` = [−second, d] as ONE prism (the legacy path
        /// built two meshes and appended them; the solid is the
        /// same).
        func extrudeSpan(_ mode: ExtrudeMode, _ distance: Double) throws -> (offset: Double, along: Double) {
            switch mode {
            case .one: return (0, distance)
            case .symmetric: return (-distance / 2, distance)
            case .twoSided(let second):
                guard second > 0 else { throw CADError.padLengthInvalid(second) }
                return (-second, distance + second)
            }
        }

        /// A sketch-extrude tool solid, drafted when the feature
        /// tapers. The tapered form is built as one drafted segment
        /// per legacy mesh segment, each drafted about its OWN base
        /// plane — the legacy construction exactly (a two-sided
        /// taper keeps the cross-section step it always had at the
        /// sketch plane; a single draft over the whole span would
        /// widen below the plane instead).
        func extrudeTool(_ p: any CascadeKernelProvider, sketch: Sketch,
                         mode: ExtrudeMode, distance: Double, taper: Double) throws -> Int {
            if abs(taper) < 1e-9 {
                let (offset, along) = try extrudeSpan(mode, distance)
                return try p.prismFromSketch(sketch, offset: offset, along: along)
            }
            var segments: [(offset: Double, along: Double)] = []
            switch mode {
            case .one: segments = [(0, distance)]
            case .symmetric: segments = [(-distance / 2, distance)]
            case .twoSided(let second):
                guard second > 0 else { throw CADError.padLengthInvalid(second) }
                segments = [(0, distance), (-second, second)]
            }
            let n = sketch.plane.normal
            var tool: Int? = nil
            for seg in segments {
                let s = try p.prismFromSketch(sketch, offset: seg.offset, along: seg.along)
                let d = try p.draftGeneral(s, pullDirection: n, angleDegrees: taper,
                                           neutralPoint: sketch.plane.origin + n * seg.offset)
                p.release(s)
                if let t = tool {
                    let u = try p.unite(t, d)
                    p.release(t); p.release(d)
                    tool = u
                } else {
                    tool = d
                }
            }
            return tool!
        }

        // ---- Stage 3 helpers (engine body operations) ----

        /// Replace the running engine solid with a derived one
        /// (the old handle is released exactly once).
        func adoptSolid(_ p: any CascadeKernelProvider, _ new: Int) {
            if let old = solid { p.release(old) }
            solid = new
            solidMesh = nil
        }

        /// Census indices of the body's straight edges at least
        /// 0.5 mm long — the edge set the legacy finisher worked
        /// on (it only ever finished straight edges; circle edges
        /// such as hole rims are excluded by the line filter).
        func lineEdgeIndices(_ p: any CascadeKernelProvider, _ h: Int) throws -> [Int] {
            try p.edgeInfos(h).enumerated()
                .filter { $0.element.curveType == 0 && $0.element.length >= 0.5 }
                .map { $0.offset }
        }

        /// Census indices of the edges whose midpoint matches one
        /// of the user's picked midpoints (0.05 mm, the legacy
        /// tolerance) — selection-driven ops act on the selection's
        /// real edges, never a guessed set.
        func midpointEdgeIndices(_ p: any CascadeKernelProvider, _ h: Int,
                                 _ midpoints: [Vec3]) throws -> [Int] {
            var out: [Int] = []
            for (i, e) in try p.edgeInfos(h).enumerated()
            where midpoints.contains(where: { $0.distance(to: e.midPoint) < 0.05 }) {
                out.append(i)
            }
            return out
        }

        /// Row-major 3x4 for the provider's transform: the local
        /// axes (u, v, w) map to the COLUMNS, so a local point
        /// (x, y, z) lands at u*x + v*y + w*z + t.
        func basisMatrix(_ u: Vec3, _ v: Vec3, _ w: Vec3, _ t: Vec3) -> [Double] {
            [u.x, v.x, w.x, t.x,
             u.y, v.y, w.y, t.y,
             u.z, v.z, w.z, t.z]
        }

        /// A proper rotation (det +1 — a reflection would flip a
        /// thread's hand) whose local +Z lands on the unit `axis`,
        /// with the local origin at `origin`.
        func axisPlacement(axis: Vec3, origin: Vec3) -> [Double] {
            let a = axis.normalized
            // Identity fast path: a +Z shaft needs no rotation at
            // all. Routing the tool through an unnecessary
            // re-parameterising transform can make the boolean
            // classifier treat a helical tool as disjoint from
            // the wall it cuts (host-proven at M10x1.5 internal,
            // hardening 2026-10-29: the transformed tool's cut
            // removed exactly nothing; the raw tool cut fine).
            if a.z > 1 - 1e-12 {
                return basisMatrix(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), origin)
            }
            let helper = abs(a.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
            let u = (helper - a * helper.dot(a)).normalized
            let v = a.cross(u)
            return basisMatrix(u, v, a, origin)
        }

        /// An engine cylinder placed on a sketch plane: axis on
        /// the plane normal through `center`, spanning the axial
        /// positions [above − height, above] — the legacy hole
        /// tool's exact placement.
        func holeCylinder(_ p: any CascadeKernelProvider, plane: Plane3, center: Vec3,
                          diameter: Double, height: Double, above: Double) throws -> Int {
            let raw = try p.primitive(kind: .cylinder,
                                      params: ["diameter": diameter, "height": height])
            let m = basisMatrix(plane.xAxis, plane.yAxis, plane.normal,
                                center + plane.normal * (above - height))
            let moved = try p.transform(raw, matrix: m)
            p.release(raw)
            return moved
        }

        /// The running body's axial span within a cylinder column
        /// around (origin, axis): every triangle lying WHOLLY
        /// inside the column votes with its axial extent — the
        /// measurement the legacy thread-on-shaft used (a
        /// neighbouring hole's wall or a plate corner, whose
        /// triangles only partly enter the column, cannot stretch
        /// the span). Seeds [0, minSpan] like the legacy code.
        func columnSpan(mesh: Mesh, origin: Vec3, axis: Vec3,
                        radius: Double, minSpan: Double) -> (lo: Double, hi: Double) {
            var lo = 0.0
            var hi = minSpan
            for t in 0..<mesh.triangleCount {
                var sMin = Double.infinity
                var sMax = -Double.infinity
                var inside = true
                for k in 0..<3 {
                    let v = mesh.vertices[Int(mesh.indices[t * 3 + k])]
                    let d = v - origin
                    let s = d.dot(axis)
                    if (d - axis * s).length > radius { inside = false; break }
                    sMin = min(sMin, s)
                    sMax = max(sMax, s)
                }
                if inside {
                    lo = min(lo, sMin)
                    hi = max(hi, sMax)
                }
            }
            return (lo, hi)
        }

        /// An axis-aligned engine box with its min corner at `mn`
        /// (the provider's box is XY-centred with z from 0, so it
        /// is translated into place).
        func boxSolid(_ p: any CascadeKernelProvider, min mn: Vec3, size sz: Vec3) throws -> Int {
            let raw = try p.primitive(kind: .box,
                                      params: ["width": sz.x, "depth": sz.y, "height": sz.z])
            let m: [Double] = [1, 0, 0, mn.x + sz.x / 2,
                               0, 1, 0, mn.y + sz.y / 2,
                               0, 0, 1, mn.z]
            let moved = try p.transform(raw, matrix: m)
            p.release(raw)
            return moved
        }

        // ---- Stage 5 helpers (transforms + verified fusion) ----

        /// Row-major 3x4 rotation about the world axis (0=X, 1=Y,
        /// 2=Z) line through `center`, right-hand rule — the exact
        /// map the legacy mesh kernel's rotatedAround applies.
        func rotationMatrix(axis: Int, degrees: Double, center: Vec3) -> [Double] {
            let a = degrees * Double.pi / 180
            let c = cos(a), s = sin(a)
            let r: [Double]
            switch axis {
            case 0: r = [1, 0, 0, 0, c, -s, 0, s, c]
            case 1: r = [c, 0, s, 0, 1, 0, -s, 0, c]
            default: r = [c, -s, 0, s, c, 0, 0, 0, 1]
            }
            let tx = center.x - (r[0] * center.x + r[1] * center.y + r[2] * center.z)
            let ty = center.y - (r[3] * center.x + r[4] * center.y + r[5] * center.z)
            let tz = center.z - (r[6] * center.x + r[7] * center.y + r[8] * center.z)
            return [r[0], r[1], r[2], tx,
                    r[3], r[4], r[5], ty,
                    r[6], r[7], r[8], tz]
        }

        /// Apply a row-major 3x4 (the provider transform's
        /// convention) to a point.
        func applyMatrix(_ m: [Double], _ v: Vec3) -> Vec3 {
            Vec3(m[0] * v.x + m[1] * v.y + m[2] * v.z + m[3],
                 m[4] * v.x + m[5] * v.y + m[6] * v.z + m[7],
                 m[8] * v.x + m[9] * v.y + m[10] * v.z + m[11])
        }

        /// Tolerance for equality-class volume checks (transform
        /// preservation, exact addition): 1e-6 relative — two
        /// orders of magnitude tighter than any failure signature
        /// Stage 4 recorded (a dropped solid loses whole percent),
        /// loose enough for GProp integration noise.
        func volumeTol(_ v: Double) -> Double { max(1e-6, abs(v) * 1e-6) }

        /// A point PROVEN strictly inside solid `h` — a material
        /// witness for verify-then-accept — or nil when no point
        /// can be proven: the bounds centre when it classifies in,
        /// else the largest planar faces' centres stepped inward
        /// along their outward normals (2% of the smallest bounds
        /// dimension, up to 8 faces tried). A face census the
        /// provider cannot answer (a test stub) also yields nil.
        /// A nil witness never fails a feature — the volume
        /// envelope still applies — it only means this body
        /// offered no provable interior point.
        func interiorWitness(_ p: any CascadeKernelProvider, _ h: Int) throws -> Vec3? {
            let b = try p.bounds(h)
            let center = (b.min + b.max) * 0.5
            if try p.contains(h, point: center) { return center }
            let size = b.max - b.min
            let minDim = min(size.x, min(size.y, size.z))
            guard minDim > 0 else { return nil }
            do {
                let census = try p.census(h)
                var faces: [(area: Double, center: Vec3, normal: Vec3)] = []
                for i in 0..<census.faces {
                    let f = try p.faceInfo(h, index: i)
                    if f.isPlanar, f.area > 0 {
                        faces.append((area: f.area, center: f.center, normal: f.normal))
                    }
                }
                faces.sort { $0.area > $1.area }
                let step = minDim * 0.02
                for f in faces.prefix(8) {
                    let candidate = f.center - f.normal * step
                    if try p.contains(h, point: candidate) { return candidate }
                }
            } catch {
                return nil
            }
            return nil
        }

        /// The axis on which two bounding boxes are disjoint
        /// (intervals separated or just touching) and the gap's
        /// midpoint coordinate on it — nil when the boxes overlap
        /// on every axis. Copies disjoint from the accumulated
        /// body must fuse to exactly the summed volume, and a
        /// point on the gap's mid-plane is provably outside both.
        func disjointAxis(_ a: (min: Vec3, max: Vec3),
                          _ b: (min: Vec3, max: Vec3)) -> (axis: Int, mid: Double)? {
            let amin = [a.min.x, a.min.y, a.min.z], amax = [a.max.x, a.max.y, a.max.z]
            let bmin = [b.min.x, b.min.y, b.min.z], bmax = [b.max.x, b.max.y, b.max.z]
            for k in 0..<3 {
                if bmin[k] >= amax[k] { return (axis: k, mid: (amax[k] + bmin[k]) / 2) }
                if amin[k] >= bmax[k] { return (axis: k, mid: (bmax[k] + amin[k]) / 2) }
            }
            return nil
        }

        /// Fuse ONE transformed copy of `source` into `acc`,
        /// verify-then-accept — the Stage 5 discipline, mirroring
        /// mc_thread's verified fallback candidates (Stage 4 found
        /// this OCCT build's boolean classifier unreliable per
        /// configuration against transformed solids, so no fused
        /// result is adopted on faith):
        ///  - the copy alone must measure the source's volume (a
        ///    transform that corrupts geometry is caught before
        ///    it can poison the body);
        ///  - the material witness, transported by the same
        ///    matrix, must classify IN the copy and IN the result;
        ///  - the fused volume must lie inside
        ///    [max(acc, copy), acc + copy] — a fuse that drops or
        ///    invents material is rejected, never adopted;
        ///  - when the copy's bounds are disjoint from the
        ///    accumulated bounds, the volumes must ADD (1e-5) and
        ///    the gap-mid witness must classify OUT of the result.
        /// Any failed check throws kernelShapeInvalid (KN603:
        /// "the previous solid is kept" — it is; `acc` and
        /// `source` are NOT released here, on success or failure;
        /// the caller owns them and adopts the returned handle).
        /// The copy is released in all paths; `accVolume` and
        /// `accBounds` are updated on success only.
        func fuseVerifiedCopy(_ p: any CascadeKernelProvider, source: Int,
                              matrix: [Double], acc: Int,
                              accVolume: inout Double,
                              accBounds: inout (min: Vec3, max: Vec3),
                              unitVolume: Double, witness: Vec3?,
                              what: String) throws -> Int {
            let copy = try p.transform(source, matrix: matrix)
            do {
                let copyVolume = try p.volume(copy)
                guard abs(copyVolume - unitVolume) <= volumeTol(unitVolume) else {
                    throw CADError.kernelShapeInvalid("\(what): a copied piece measured \(String(format: "%.3f", copyVolume)) mm³ instead of \(String(format: "%.3f", unitVolume)) mm³")
                }
                var witnessCopy: Vec3? = nil
                if let w = witness {
                    let t = applyMatrix(matrix, w)
                    guard try p.contains(copy, point: t) else {
                        throw CADError.kernelShapeInvalid("\(what): a copied piece is missing material it should hold")
                    }
                    witnessCopy = t
                }
                let copyBounds = try p.bounds(copy)
                let gap = disjointAxis(accBounds, copyBounds)
                let fused = try p.unite(acc, copy)
                do {
                    let fusedVolume = try p.volume(fused)
                    let sum = accVolume + copyVolume
                    guard fusedVolume >= max(accVolume, copyVolume) - volumeTol(sum),
                          fusedVolume <= sum + volumeTol(sum) else {
                        throw CADError.kernelShapeInvalid("\(what): combining the pieces measured \(String(format: "%.3f", fusedVolume)) mm³, outside the possible range \(String(format: "%.3f", max(accVolume, copyVolume)))–\(String(format: "%.3f", sum)) mm³")
                    }
                    if let g = gap {
                        guard abs(fusedVolume - sum) <= max(1e-5, sum * 1e-5) else {
                            throw CADError.kernelShapeInvalid("\(what): separated pieces should add to \(String(format: "%.3f", sum)) mm³ but measured \(String(format: "%.3f", fusedVolume)) mm³")
                        }
                        var outPoint = (accBounds.min + accBounds.max) * 0.5
                        switch g.axis {
                        case 0: outPoint = Vec3(g.mid, outPoint.y, outPoint.z)
                        case 1: outPoint = Vec3(outPoint.x, g.mid, outPoint.z)
                        default: outPoint = Vec3(outPoint.x, outPoint.y, g.mid)
                        }
                        guard try !p.contains(fused, point: outPoint) else {
                            throw CADError.kernelShapeInvalid("\(what): the empty gap between pieces measured as solid")
                        }
                    }
                    if let t = witnessCopy {
                        guard try p.contains(fused, point: t) else {
                            throw CADError.kernelShapeInvalid("\(what): a combined piece lost material it should hold")
                        }
                    }
                    accVolume = fusedVolume
                    accBounds = try p.bounds(fused)
                    p.release(copy)
                    return fused
                } catch {
                    p.release(fused)
                    throw error
                }
            } catch {
                p.release(copy)
                throw error
            }
        }

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
                if solid != nil && !kindIsSolidAware(feature.kind) {
                    // This feature has no engine path: the body
                    // leaves the engine here, and STEP export will
                    // name this feature as its blocker.
                    if meshBlocker == nil { meshBlocker = feature.name }
                    try materializeBody()
                }
                if case .linearPattern(let count, let spacing) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 5): each copy is
                        // transformed from the ORIGINAL solid and
                        // fused in under verify-then-accept (see
                        // fuseVerifiedCopy) — the legacy path
                        // APPENDED translated copies without
                        // combining them, so overlapping copies
                        // double-counted their overlap; the engine
                        // fuses, and the overlap is counted once.
                        // The guard mirrors applyPattern's exactly.
                        guard count >= 1, spacing.length > 0 else { throw CADError.patternCountInvalid(count) }
                        let unit = try p.volume(h)
                        let witness = try interiorWitness(p, h)
                        var acc = h
                        var accVolume = unit
                        var accBounds = try p.bounds(h)
                        do {
                            for i in 1..<count {
                                let t = spacing * Double(i)
                                let next = try fuseVerifiedCopy(
                                    p, source: h,
                                    matrix: [1, 0, 0, t.x, 0, 1, 0, t.y, 0, 0, 1, t.z],
                                    acc: acc, accVolume: &accVolume, accBounds: &accBounds,
                                    unitVolume: unit, witness: witness, what: "the pattern")
                                let old = acc
                                acc = next
                                if old != h { p.release(old) }
                            }
                        } catch {
                            if acc != h { p.release(acc) }
                            throw error
                        }
                        if acc != h { p.release(h) }
                        solid = acc
                        solidMesh = nil
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "pattern ok (engine)", context: ["feature": feature.name, "count": "\(count)"])
                        continue
                    }
                    body = try DocumentEngine.applyPattern(mesh: body, count: count, spacing: spacing)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "pattern ok", context: ["feature": feature.name, "count": "\(count)"])
                    continue
                }
                if case .mirror(let plane) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 5): the mirrored copy
                        // across the ORIGIN plane — the legacy
                        // semantics (Mesh.mirrored negates one
                        // coordinate about zero, it does NOT mirror
                        // about the body's own centre) — fused
                        // under verify-then-accept.
                        var m: [Double] = [1, 0, 0, 0,
                                           0, 1, 0, 0,
                                           0, 0, 1, 0]
                        switch plane.axis {
                        case 0: m[0] = -1
                        case 1: m[5] = -1
                        default: m[10] = -1
                        }
                        let unit = try p.volume(h)
                        let witness = try interiorWitness(p, h)
                        var accVolume = unit
                        var accBounds = try p.bounds(h)
                        let fused = try fuseVerifiedCopy(
                            p, source: h, matrix: m, acc: h,
                            accVolume: &accVolume, accBounds: &accBounds,
                            unitVolume: unit, witness: witness, what: "the mirror")
                        p.release(h)
                        solid = fused
                        solidMesh = nil
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "mirror ok (engine)", context: ["feature": feature.name, "plane": plane.rawValue])
                        continue
                    }
                    if body.triangleCount > 0 {
                        body = try CSG.union(body, body.mirrored(axis: plane.axis))
                    }
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "mirror ok", context: ["feature": feature.name, "plane": plane.rawValue])
                    continue
                }
                if case .fillet(let radius) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 3): exact OCCT fillet
                        // on the body's straight census edges. The
                        // legacy finisher silently shrank the radius
                        // (a 5% ladder) and capped the edge count;
                        // the engine applies the requested radius
                        // exactly or fails with a coded error.
                        guard radius > 0 else { throw CADError.filletFailed("radius must be > 0") }
                        let edges = try lineEdgeIndices(p, h)
                        if !edges.isEmpty {
                            adoptSolid(p, try p.fillet(h, radius: radius, edgeIndices: edges))
                        }
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "fillet ok (engine)", context: ["feature": feature.name, "radius": "\(radius)"])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.filletFailed("no solid to fillet yet") }
                    body = try EdgeFinisher.fillet(body: body, radius: radius)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "fillet ok", context: ["feature": feature.name, "radius": "\(radius)"])
                    continue
                }
                if case .chamfer(let distance) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 3): exact OCCT chamfer
                        // on the straight census edges (see fillet).
                        guard distance > 0 else { throw CADError.chamferInvalid("distance must be > 0") }
                        let edges = try lineEdgeIndices(p, h)
                        if !edges.isEmpty {
                            adoptSolid(p, try p.chamfer(h, distance: distance, edgeIndices: edges))
                        }
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "chamfer ok (engine)", context: ["feature": feature.name, "distance": "\(distance)"])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.chamferInvalid("no solid to chamfer yet") }
                    body = try EdgeFinisher.chamfer(body: body, distance: distance)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "chamfer ok", context: ["feature": feature.name, "distance": "\(distance)"])
                    continue
                }
                if case .shell(let thickness) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 3): mc_shell — closed
                        // hollow, exact offset (the legacy shell was
                        // a vertex-normal approximation).
                        guard thickness > 0 else { throw CADError.shellFailed("wall thickness must be > 0") }
                        adoptSolid(p, try p.shell(h, thickness: thickness))
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "shell ok (engine)", context: ["feature": feature.name, "wall": "\(thickness)"])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.shellFailed("no solid to shell yet") }
                    body = try EdgeFinisher.shell(body: body, thickness: thickness)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "shell ok", context: ["feature": feature.name, "wall": "\(thickness)"])
                    continue
                }
                if case .extrude2(let sketchID, let distance, let taper, let mode, let op, let end) = feature.kind {
                    if let p = provider {
                        // Engine path (Stage 2): end conditions
                        // resolve exactly as the legacy helper
                        // resolves them — dimension / through-all
                        // from the running bounds, up-to-face in the
                        // legacy planar-face index space (that is
                        // the space stored documents refer to) — but
                        // the tool is an engine prism and composition
                        // is exact.
                        guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
                        let (profiles, w) = try sketch.extractProfiles()
                        warnings += w
                        guard !profiles.isEmpty else { throw CADError.padNoProfile }
                        let n = sketch.plane.normal
                        var dist = distance
                        switch end {
                        case .dimension:
                            guard distance > 0 else { throw CADError.padLengthInvalid(distance) }
                        case .throughAll:
                            if let h = solid {
                                let b = try p.bounds(h)
                                dist = (b.max - b.min).length + 100
                            } else {
                                dist = body.triangleCount == 0 ? 1000 : body.bounds.size.length + 100
                            }
                        case .upToFace(let faceIndex):
                            let faces = FaceExtractor.planarFaces(of: try currentMesh())
                            guard faceIndex >= 0, faceIndex < faces.count else {
                                throw CADError.booleanFailed("the target face no longer exists — pick another")
                            }
                            let d = (faces[faceIndex].centroid - sketch.plane.origin).dot(n)
                            guard d > 0.01 else {
                                throw CADError.booleanFailed("the target face is behind the sketch plane")
                            }
                            dist = d
                        }
                        let tool = try extrudeTool(p, sketch: sketch, mode: mode, distance: dist, taper: taper)
                        try booleanWithSolid(tool, op)
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "extrude2 ok (engine)", context: ["feature": feature.name, "op": op.rawValue])
                        continue
                    }
                    let tool = try DocumentEngine.extrude2Mesh(part: part, sketchID: sketchID, distance: distance, taper: taper, mode: mode, end: end, body: body, warnings: &warnings)
                    switch op {
                    case .join:
                        body = body.triangleCount == 0 ? tool : try CSG.union(body, tool)
                    case .cut:
                        guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                        body = try CSG.subtract(body, tool)
                    case .intersect:
                        guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                        body = try CSG.intersect(body, tool)
                    case .newBody:
                        if body.triangleCount > 0 { bodies.append(body) }
                        body = tool
                    }
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "extrude2 ok", context: ["feature": feature.name, "op": op.rawValue])
                    continue
                }
                if case .rib(let sketchID, let thickness, let depth) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 3): the legacy rib
                        // construction rebuilt from engine solids —
                        // one oriented box chunk per path segment
                        // (segment x thickness along the sketch
                        // normal x depth+1 along the extension
                        // direction, 1 mm buried overshoot), trimmed
                        // by the same oriented clip box, joined
                        // exactly. Guards mirror ribMesh's order.
                        guard thickness > 0, depth > 0 else {
                            throw CADError.primitiveParamInvalid("rib needs thickness > 0 and depth > 0")
                        }
                        guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
                        let pts = try DocumentEngine.pathPoints(sketch: sketch)
                        guard pts.count >= 2 else { throw CADError.padNoProfile }
                        let bnd = try p.bounds(h)
                        let bbCenter = (bnd.min + bnd.max) * 0.5
                        let diag = (bnd.max - bnd.min).length
                        let n = sketch.plane.normal
                        let seg0 = (pts[1] - pts[0]).normalized
                        let mid = pts.reduce(Vec3.zero) { $0 + $1 } * (1.0 / Double(pts.count))
                        let e1 = n.cross(seg0).normalized
                        let e = e1.dot(bbCenter - mid) >= 0 ? e1 : e1 * -1
                        var wall: Int? = nil
                        for i in 0..<(pts.count - 1) {
                            let a = pts[i], b = pts[i + 1]
                            let seg = b - a
                            let len = seg.length
                            guard len > 1e-9 else { continue }
                            let sd = seg * (1 / len)
                            var nn = n
                            // Keep the basis right-handed (the box
                            // is symmetric in thickness, so flipping
                            // the normal changes nothing else).
                            if sd.dot(nn.cross(e)) < 0 { nn = nn * -1 }
                            let raw = try p.primitive(kind: .box, params: ["width": len, "depth": thickness, "height": depth + 1])
                            let c = (a + b) * 0.5
                            let m: [Double] = [sd.x, nn.x, e.x, c.x,
                                               sd.y, nn.y, e.y, c.y,
                                               sd.z, nn.z, e.z, c.z]
                            let chunk = try p.transform(raw, matrix: m)
                            p.release(raw)
                            if let w = wall {
                                let u2 = try p.unite(w, chunk)
                                p.release(w); p.release(chunk)
                                wall = u2
                            } else {
                                wall = chunk
                            }
                        }
                        guard let wallH = wall else { throw CADError.padNoProfile }
                        let helper = abs(e.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
                        let u = helper.cross(e).normalized
                        let v = e.cross(u).normalized
                        let hw = (diag + depth + 2) / 2
                        let cc = bbCenter - e * ((depth + 2) / 2) - e * hw
                        let rawClip = try p.primitive(kind: .box, params: ["width": 2 * diag, "depth": 2 * diag, "height": 2 * hw])
                        let cm: [Double] = [u.x, v.x, e.x, cc.x,
                                            u.y, v.y, e.y, cc.y,
                                            u.z, v.z, e.z, cc.z]
                        let clip = try p.transform(rawClip, matrix: cm)
                        p.release(rawClip)
                        let trimmed = try p.intersect(wallH, clip)
                        p.release(wallH); p.release(clip)
                        guard try p.volume(trimmed) > 1e-9 else {
                            p.release(trimmed)
                            throw CADError.booleanFailed("the rib wall misses the body entirely")
                        }
                        try booleanWithSolid(trimmed, .join)
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "rib ok (engine)", context: ["feature": feature.name])
                        continue
                    }
                    body = try DocumentEngine.ribMesh(part: part, sketchID: sketchID, thickness: thickness, depth: depth, body: body)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "rib ok", context: ["feature": feature.name])
                    continue
                }
                if case .chamfer2(let mode) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 3): two-distance
                        // chamfer via mc_chamfer2 — distanceA along
                        // the lower-census-index adjacent face (the
                        // fixed face-A convention; a document stores
                        // no other face reference). Equal distances
                        // take the symmetric path. The legacy
                        // binary-search "largest that fits" message
                        // is not replicated: an impossible chamfer
                        // fails with the engine's coded error.
                        let (dA, dB) = mode.distances
                        guard dA > 0, dB > 0 else { throw CADError.chamferInvalid("distances must be > 0") }
                        let edges = try lineEdgeIndices(p, h)
                        if !edges.isEmpty {
                            if dA == dB {
                                adoptSolid(p, try p.chamfer(h, distance: dA, edgeIndices: edges))
                            } else {
                                adoptSolid(p, try p.chamfer2(h, distanceA: dA, distanceB: dB, edgeIndices: edges))
                            }
                        }
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "chamfer2 ok (engine)", context: ["feature": feature.name])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.chamferInvalid("no solid to chamfer yet") }
                    let (dA, dB) = mode.distances
                    body = try EdgeFinisher.chamfer2(body: body, distanceA: dA, distanceB: dB)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "chamfer2 ok", context: ["feature": feature.name])
                    continue
                }
                if case .draftBody(let angle, let axis) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 3): mc_draft rotates
                        // the real side faces about the neutral
                        // plane at the body's minimum along the
                        // pull axis — identical to the legacy morph
                        // on prismatic parts (the legacy morph
                        // displaced vertices radially from the
                        // bounds centre on other shapes).
                        guard abs(angle) > 1e-9, abs(angle) < 30 else {
                            throw CADError.transformInvalid("draft angle must be between -30 and 30 degrees")
                        }
                        adoptSolid(p, try p.draft(h, angleDegrees: angle, pullAxis: axis))
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "draft ok (engine)", context: ["feature": feature.name])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.transformInvalid("no solid to draft yet") }
                    body = try DocumentEngine.draftMesh(body: body, angleDegrees: angle, pullAxis: axis)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "draft ok", context: ["feature": feature.name])
                    continue
                }
                if case .scaleBody(let f) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 5): a GTrsf scale
                        // about the bounds centre — the legacy
                        // centre (the engine's bounds are the true
                        // B-rep bounds; the legacy centre came from
                        // the tessellation's bounds) — verified
                        // against the factor-product volume law
                        // before the result is adopted. The law is
                        // checked at 2%, not exactly: a NON-uniform
                        // scale is the one transform whose curved
                        // surfaces the engine converts to BSplines,
                        // and its volume reading over those faces
                        // drifts (+0.86% measured on a cylinder,
                        // harness §13) even though the solid itself
                        // is exact (bounds- and cut-verified there).
                        // A uniform scale takes the exact path and
                        // measures to 1e-6 — 2% still catches any
                        // real factor error many times over. (The
                        // matrix's axis placement itself is pinned
                        // exactly by the kit's stub tests.)
                        guard f.x > 0, f.y > 0, f.z > 0 else { throw CADError.transformInvalid("scale factors must be > 0") }
                        let b = try p.bounds(h)
                        let c = (b.min + b.max) * 0.5
                        let m: [Double] = [f.x, 0, 0, c.x * (1 - f.x),
                                           0, f.y, 0, c.y * (1 - f.y),
                                           0, 0, f.z, c.z * (1 - f.z)]
                        let r = try p.transform(h, matrix: m)
                        let v0 = try p.volume(h)
                        let v1 = try p.volume(r)
                        let want = v0 * f.x * f.y * f.z
                        guard abs(v1 - want) <= max(1e-4, want * 0.02) else {
                            p.release(r)
                            throw CADError.kernelShapeInvalid("scaling the body measured \(String(format: "%.3f", v1)) mm³ instead of the expected \(String(format: "%.3f", want)) mm³")
                        }
                        adoptSolid(p, r)
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "scale ok (engine)", context: ["feature": feature.name])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.transformInvalid("no solid to scale yet") }
                    guard f.x > 0, f.y > 0, f.z > 0 else { throw CADError.transformInvalid("scale factors must be > 0") }
                    body = body.scaled(by: f, center: body.bounds.center)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "scale ok", context: ["feature": feature.name])
                    continue
                }
                if case .moveBody(let t, let axis, let deg) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 5): ONE GTrsf — rotate
                        // about the bounds-centre axis, then
                        // translate (the legacy order) — verified
                        // volume-preserving before adoption (a rigid
                        // map must conserve volume exactly).
                        let b = try p.bounds(h)
                        let center = (b.min + b.max) * 0.5
                        var m = rotationMatrix(axis: axis, degrees: deg, center: center)
                        m[3] += t.x
                        m[7] += t.y
                        m[11] += t.z
                        let r = try p.transform(h, matrix: m)
                        let v0 = try p.volume(h)
                        let v1 = try p.volume(r)
                        guard abs(v1 - v0) <= volumeTol(v0) else {
                            p.release(r)
                            throw CADError.kernelShapeInvalid("moving the body measured \(String(format: "%.3f", v1)) mm³ instead of \(String(format: "%.3f", v0)) mm³")
                        }
                        adoptSolid(p, r)
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "move ok (engine)", context: ["feature": feature.name])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.transformInvalid("no solid to move yet") }
                    if abs(deg) > 1e-9 { body = body.rotatedAround(axis: axis, degrees: deg, center: body.bounds.center) }
                    body = body.translated(by: t)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "move ok", context: ["feature": feature.name])
                    continue
                }
                if case .splitBody(let axis, let offset) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 3): exact intersect
                        // with two half-boxes meeting AT the split
                        // plane. (The legacy half-boxes overshot
                        // the plane by 0.001 on both sides, so its
                        // halves overlapped in a 0.002 slab; the
                        // engine split is exact and conserves
                        // volume.) Guards mirror splitMesh.
                        let bnd = try p.bounds(h)
                        let lo = axis == 0 ? bnd.min.x : axis == 1 ? bnd.min.y : bnd.min.z
                        let hi = axis == 0 ? bnd.max.x : axis == 1 ? bnd.max.y : bnd.max.z
                        guard offset > lo + 1e-6, offset < hi - 1e-6 else {
                            throw CADError.booleanFailed("the split plane misses the body")
                        }
                        var mn1 = bnd.min - Vec3(1, 1, 1)
                        var mx1 = bnd.max + Vec3(1, 1, 1)
                        var mn2 = mn1
                        var mx2 = mx1
                        switch axis {
                        case 0: mx1.x = offset; mn2.x = offset
                        case 1: mx1.y = offset; mn2.y = offset
                        default: mx1.z = offset; mn2.z = offset
                        }
                        let box1 = try boxSolid(p, min: mn1, size: mx1 - mn1)
                        let half1 = try p.intersect(h, box1)
                        p.release(box1)
                        let box2 = try boxSolid(p, min: mn2, size: mx2 - mn2)
                        let half2 = try p.intersect(h, box2)
                        p.release(box2)
                        guard try p.volume(half1) > 1e-9, try p.volume(half2) > 1e-9 else {
                            p.release(half1); p.release(half2)
                            throw CADError.booleanFailed("the split plane misses the body")
                        }
                        p.release(h)
                        solidBodies.append(half2)
                        solid = half1
                        solidMesh = nil
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "split ok (engine)", context: ["feature": feature.name])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.booleanFailed("no solid to split yet") }
                    let (h1, h2) = try DocumentEngine.splitMesh(body: body, axis: axis, offset: offset)
                    bodies.append(h2)
                    body = h1
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "split ok", context: ["feature": feature.name])
                    continue
                }
                if case .circularPattern(let count, let axis, let total) = feature.kind {
                    guard count >= 2 else { throw CADError.patternCountInvalid(count) }
                    if let p = provider, let h = solid {
                        // Engine path (Stage 5): copies rotated
                        // about the bounds-centre axis — the legacy
                        // centre (engine bounds are the true B-rep
                        // bounds) — each transformed from the
                        // ORIGINAL and fused under verify-then-
                        // accept. The angle ladder mirrors legacy
                        // exactly: a full circle divides by count,
                        // a partial arc divides by count - 1 so the
                        // last copy lands on the total.
                        let b = try p.bounds(h)
                        let center = (b.min + b.max) * 0.5
                        let full = total >= 359.999
                        let unit = try p.volume(h)
                        let witness = try interiorWitness(p, h)
                        var acc = h
                        var accVolume = unit
                        var accBounds = b
                        do {
                            for i in 1..<count {
                                let a = full ? total * Double(i) / Double(count)
                                             : total * Double(i) / Double(count - 1)
                                let next = try fuseVerifiedCopy(
                                    p, source: h,
                                    matrix: rotationMatrix(axis: axis, degrees: a, center: center),
                                    acc: acc, accVolume: &accVolume, accBounds: &accBounds,
                                    unitVolume: unit, witness: witness, what: "the circular pattern")
                                let old = acc
                                acc = next
                                if old != h { p.release(old) }
                            }
                        } catch {
                            if acc != h { p.release(acc) }
                            throw error
                        }
                        if acc != h { p.release(h) }
                        solid = acc
                        solidMesh = nil
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "circular pattern ok (engine)", context: ["feature": feature.name, "count": "\(count)"])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                    let center = body.bounds.center
                    let full = total >= 359.999
                    var acc = body
                    for i in 1..<count {
                        let a = full ? total * Double(i) / Double(count)
                                     : total * Double(i) / Double(count - 1)
                        acc = try CSG.union(acc, body.rotatedAround(axis: axis, degrees: a, center: center))
                    }
                    body = acc
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "circular pattern ok", context: ["feature": feature.name, "count": "\(count)"])
                    continue
                }
                if case .threadShaft(let spec) = feature.kind {
                    if let p = provider {
                        // Engine path (Stage 4): a MODELED thread is
                        // the engine's real helical segment (mc_thread),
                        // composed exactly. A COSMETIC spec (the
                        // user's own choice in the editor — never a
                        // silent default) builds a plain shaft and
                        // says so in its status.
                        let (vspec, tw) = try spec.validated()
                        warnings += tw
                        if !vspec.modeled {
                            let d = vspec.kind == .external ? vspec.majorDiameter : vspec.minorDiameter
                            let cyl = try p.primitive(kind: .cylinder,
                                                      params: ["diameter": d, "height": vspec.length])
                            try booleanWithSolid(cyl, .join)
                            statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil,
                                                          message: "Cosmetic thread — plain shaft, no thread geometry (your choice in the editor)."))
                            logger.debug(.feature, "thread shaft ok (cosmetic)", context: ["feature": feature.name])
                            continue
                        }
                        if vspec.kind == .external {
                            let seg = try p.thread(spec: vspec)
                            try booleanWithSolid(seg, .join)
                        } else {
                            // Internal: a threaded sleeve — a
                            // major-diameter blank bored at the
                            // minor diameter, minus the engine's
                            // groove tool. (The legacy mesh path
                            // never built a real internal solid:
                            // it appended inward ridge triangles
                            // to a minor-diameter cylinder.)
                            let blank = try p.primitive(kind: .cylinder,
                                                        params: ["diameter": vspec.majorDiameter, "height": vspec.length])
                            let boreRaw = try p.primitive(kind: .cylinder,
                                                          params: ["diameter": vspec.minorDiameter, "height": vspec.length + 2])
                            let bore = try p.transform(boreRaw, matrix: basisMatrix(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(0, 0, -1)))
                            p.release(boreRaw)
                            let bored = try p.subtract(blank, bore)
                            p.release(blank); p.release(bore)
                            let tool = try p.thread(spec: vspec)
                            let sleeve = try p.subtract(bored, tool)
                            p.release(bored); p.release(tool)
                            try booleanWithSolid(sleeve, .join)
                        }
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "thread shaft ok (engine)", context: ["feature": feature.name])
                        continue
                    }
                    // Threads merge WITHOUT a raw CSG union of the ridge:
                    // BSP clipping dices body faces against the helix and
                    // explodes the triangle count (169k for one M10 shaft
                    // on a plate). Union only the plain core cylinder,
                    // then append the ridge trimmed where it dives below
                    // the body's surface along the shaft column.
                    let (vspec, tw) = try spec.validated()
                    warnings += tw
                    let core = try Tessellation.cylinder(radius: vspec.minorDiameter / 2,
                                                         height: vspec.length, baseZ: 0,
                                                         taperDegrees: vspec.taperDegrees)
                    var ridge = try ThreadTessellator.ridgeMesh(spec: vspec)
                    if body.triangleCount > 0 {
                        let rLim = vspec.majorDiameter / 2 + 0.5
                        var zTop = -Double.infinity
                        for v in body.vertices where v.x * v.x + v.y * v.y < rLim * rLim {
                            zTop = max(zTop, v.z)
                        }
                        if zTop.isFinite {
                            ridge = ridge.keepingTriangles(aboveZ: zTop - vspec.pitch * 0.5)
                        }
                        body = try CSG.union(body, core)
                        body.append(ridge)
                    } else {
                        body = core
                        body.append(ridge)
                    }
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "thread ok", context: ["feature": feature.name])
                    continue
                }
                if case .filletEdges(let radius, let midpoints) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 3): the user's picked
                        // midpoints are matched to census edges
                        // (0.05 mm, the legacy tolerance) and ONLY
                        // those edges are filleted, exactly.
                        guard radius > 0 else { throw CADError.filletFailed("radius must be > 0") }
                        let idx = try midpointEdgeIndices(p, h, midpoints)
                        guard !idx.isEmpty else {
                            throw CADError.filletFailed("the picked edge is gone — the part changed above it")
                        }
                        adoptSolid(p, try p.fillet(h, radius: radius, edgeIndices: idx))
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "fillet edges ok (engine)", context: ["feature": feature.name, "edges": "\(idx.count)"])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.filletFailed("no solid to fillet yet") }
                    body = try EdgeFinisher.fillet(body: body, radius: radius, onlyMidpoints: midpoints)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "fillet edges ok", context: ["feature": feature.name, "edges": "\(midpoints.count)"])
                    continue
                }
                if case .chamferEdges(let distance, let midpoints) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 3): see filletEdges.
                        guard distance > 0 else { throw CADError.chamferInvalid("distance must be > 0") }
                        let idx = try midpointEdgeIndices(p, h, midpoints)
                        guard !idx.isEmpty else {
                            throw CADError.chamferInvalid("the picked edge is gone — the part changed above it")
                        }
                        adoptSolid(p, try p.chamfer(h, distance: distance, edgeIndices: idx))
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "chamfer edges ok (engine)", context: ["feature": feature.name, "edges": "\(idx.count)"])
                        continue
                    }
                    guard body.triangleCount > 0 else { throw CADError.chamferInvalid("no solid to chamfer yet") }
                    body = try EdgeFinisher.chamfer(body: body, distance: distance, onlyMidpoints: midpoints)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "chamfer edges ok", context: ["feature": feature.name, "edges": "\(midpoints.count)"])
                    continue
                }
                if case .threadOnShaft(let spec, let origin, let axis) = feature.kind {
                    if let p = provider, let h = solid {
                        // Engine path (Stage 4): the span is measured
                        // from the body's own tessellation with the
                        // legacy column vote (the selection's actual
                        // geometry), then the work is exact solids:
                        // external = cut the plain cylinder out and
                        // unite the real threaded segment; internal
                        // = subtract the engine's groove tool (the
                        // hole-wall case the legacy path refuses).
                        let (vspec, tw) = try spec.validated()
                        warnings += tw
                        if !vspec.modeled {
                            statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil,
                                                          message: "Cosmetic thread — the shaft is unchanged; no thread geometry was cut (your choice in the editor)."))
                            logger.debug(.feature, "thread on shaft ok (cosmetic)", context: ["feature": feature.name])
                            continue
                        }
                        let ax = axis.normalized
                        let mesh = try currentMesh()
                        let rOut = vspec.majorDiameter / 2
                        let (lo, hi) = columnSpan(mesh: mesh, origin: origin, axis: ax,
                                                  radius: rOut + 0.5, minSpan: vspec.length)
                        var effSpec = vspec
                        effSpec.length = hi - lo
                        if effSpec.taperDegrees > 0 {
                            // Same guard as legacy: a longer span
                            // shrinks a tapered thread's far end
                            // further; keep it from closing past the
                            // minor diameter.
                            let maxLen = (effSpec.majorDiameter - effSpec.minorDiameter - 0.1)
                                / (2 * tan(effSpec.taperDegrees * .pi / 180))
                            effSpec.length = min(effSpec.length, max(maxLen, vspec.length))
                        }
                        let effOrigin = origin + ax * lo
                        let place = axisPlacement(axis: ax, origin: effOrigin)
                        if vspec.kind == .external {
                            // The cutter is a hair WIDER than the
                            // shaft (+0.05), exactly as legacy: a
                            // coincident cutter can leave smooth
                            // patches of the old wall in place.
                            let cutterRaw = try p.primitive(kind: .cylinder,
                                                            params: ["diameter": 2 * (rOut + 0.05), "height": effSpec.length + 2])
                            let cutter = try p.transform(cutterRaw, matrix: axisPlacement(axis: ax, origin: effOrigin - ax))
                            p.release(cutterRaw)
                            let rest = try p.subtract(h, cutter)
                            p.release(cutter)
                            let segRaw = try p.thread(spec: effSpec)
                            let seg = try p.transform(segRaw, matrix: place)
                            p.release(segRaw)
                            let joined = try p.unite(rest, seg)
                            p.release(rest); p.release(seg)
                            adoptSolid(p, joined)
                        } else {
                            let toolRaw = try p.thread(spec: effSpec)
                            let tool = try p.transform(toolRaw, matrix: place)
                            p.release(toolRaw)
                            let bodyVol = try p.volume(h)
                            var cut = try p.subtract(h, tool)
                            if try p.volume(cut) >= bodyVol - 1e-6 {
                                // Verify-then-accept (hardening
                                // 2026-10-29): the classifier
                                // called this helical tool disjoint
                                // and the cut removed nothing. Retry
                                // with the tool split at its axial
                                // mid-plane — the same point set in
                                // two cuts, a different classifier
                                // configuration. Still nothing ->
                                // KN603, never a silent fake thread.
                                p.release(cut)
                                let bigR = effSpec.majorDiameter / 2 + 2
                                let midW = effSpec.length / 2
                                func frameBox(_ w0: Double, _ w1: Double) throws -> Int {
                                    let raw = try p.primitive(kind: .box, params: [
                                        "width": bigR * 2, "depth": bigR * 2, "height": w1 - w0])
                                    // Local: box x/y centred, z from
                                    // 0 -> shift to w0, then the
                                    // placement frame (place ∘ L).
                                    let L: [Double] = [1, 0, 0, 0,
                                                       0, 1, 0, 0,
                                                       0, 0, 1, w0]
                                    var M = [Double](repeating: 0, count: 12)
                                    for i in 0..<3 {
                                        for j in 0..<3 {
                                            M[i * 4 + j] = place[i * 4] * L[j] + place[i * 4 + 1] * L[4 + j] + place[i * 4 + 2] * L[8 + j]
                                        }
                                        M[i * 4 + 3] = place[i * 4] * L[3] + place[i * 4 + 1] * L[7] + place[i * 4 + 2] * L[11] + place[i * 4 + 3]
                                    }
                                    let moved = try p.transform(raw, matrix: M)
                                    p.release(raw)
                                    return moved
                                }
                                var acc = h
                                var accOwned = false
                                for (w0, w1) in [(-2.0, midW), (midW, effSpec.length + 2)] {
                                    let fb = try frameBox(w0, w1)
                                    let half = try p.intersect(tool, fb)
                                    p.release(fb)
                                    if try p.volume(half) > 1e-9 {
                                        let next = try p.subtract(acc, half)
                                        if accOwned { p.release(acc) }
                                        acc = next; accOwned = true
                                    }
                                    p.release(half)
                                }
                                guard accOwned, try p.volume(acc) < bodyVol - 1e-6 else {
                                    if accOwned { p.release(acc) }
                                    p.release(tool)
                                    throw CADError.kernelShapeInvalid("the internal thread cut removed no material")
                                }
                                cut = acc
                            }
                            p.release(tool)
                            adoptSolid(p, cut)
                        }
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                        logger.debug(.feature, "thread on shaft ok (engine)", context: ["feature": feature.name])
                        continue
                    }
                    // Thread an EXISTING shaft (fitted by the app from a
                    // tapped pillar): cut the plain cylinder out, union
                    // the threaded core, append the ridge trimmed to
                    // the shaft's span — the same low-triangle merge as
                    // .threadShaft (never raw-union a ridge).
                    guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                    guard spec.kind == .external else {
                        throw CADError.threadProfileInvalid("threading a hole wall is not supported yet — pick an outside shaft")
                    }
                    let (vspec, tw) = try spec.validated()
                    warnings += tw
                    let ax = axis.normalized
                    let rOut = vspec.majorDiameter / 2
                    // Measure the shaft's TRUE extent along its axis
                    // from the body itself. The spec's length comes
                    // from the app's fitted patch, which stops at
                    // seams, fillet runouts and junctions and can
                    // understate the shaft — on device, threads ended
                    // short of the pillar's end (2026-10-26). Every
                    // triangle lying wholly inside the shaft column
                    // (radius major/2 + 0.5 around the axis line)
                    // votes with its axial span; the thread covers
                    // that whole span, or spec.length when longer.
                    // (The triangle-whole test keeps stray in-column
                    // vertices — a neighbouring hole's wall, a plate
                    // corner — from stretching the span.)
                    var lo = 0.0
                    var hi = vspec.length
                    for t in 0..<body.triangleCount {
                        var sMin = Double.infinity
                        var sMax = -Double.infinity
                        var inside = true
                        for k in 0..<3 {
                            let v = body.vertices[Int(body.indices[t * 3 + k])]
                            let d = v - origin
                            let s = d.dot(ax)
                            if (d - ax * s).length > rOut + 0.5 { inside = false; break }
                            sMin = min(sMin, s)
                            sMax = max(sMax, s)
                        }
                        if inside {
                            lo = min(lo, sMin)
                            hi = max(hi, sMax)
                        }
                    }
                    var effSpec = vspec
                    effSpec.length = hi - lo
                    if effSpec.taperDegrees > 0 {
                        // A longer span shrinks a tapered thread's far
                        // end further; keep it from closing past the
                        // minor diameter (validated() checked the
                        // requested length, not the measured one).
                        let maxLen = (effSpec.majorDiameter - effSpec.minorDiameter - 0.1)
                            / (2 * tan(effSpec.taperDegrees * .pi / 180))
                        effSpec.length = min(effSpec.length, max(maxLen, vspec.length))
                    }
                    let effOrigin = origin + ax * lo
                    // The cutter is a hair WIDER than the shaft
                    // (+0.05): a cutter exactly the shaft's radius is
                    // coincident with the wall it must remove, and BSP
                    // classification of coincident surfaces can leave
                    // smooth patches of the old wall interrupting the
                    // thread. The ridge crest defines the outside.
                    var cutter = try Tessellation.cylinder(radius: rOut + 0.05, height: effSpec.length + 2, baseZ: -1)
                    cutter = cutter.placed(axis: ax, origin: effOrigin)
                    var rest = try CSG.subtract(body, cutter)
                    let core = try Tessellation.cylinder(radius: effSpec.minorDiameter / 2,
                                                         height: effSpec.length, baseZ: 0,
                                                         taperDegrees: effSpec.taperDegrees)
                        .placed(axis: ax, origin: effOrigin)
                    rest = try CSG.union(rest, core)
                    var ridge = try ThreadTessellator.ridgeMesh(spec: effSpec)
                    ridge = ridge.placed(axis: ax, origin: effOrigin)
                    ridge = ridge.keepingTriangles(axis: effOrigin, axis: ax,
                                                   between: -effSpec.pitch * 0.5,
                                                   and: effSpec.length + effSpec.pitch * 0.5)
                    rest.append(ridge)
                    body = rest
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "thread on shaft ok", context: ["feature": feature.name])
                    continue
                }
                if case .cascadePad(let sketchID, let length) = feature.kind {
                    guard length > 0 else { throw CADError.padLengthInvalid(length) }
                    guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
                    // Surface the sketch's own profile warnings
                    // (SK213 gap heals) — the bridge extracts again
                    // internally and cannot return them.
                    let (padProfiles, padW) = try sketch.extractProfiles()
                    warnings += padW
                    guard !padProfiles.isEmpty else { throw CADError.padNoProfile }
                    if let p = provider {
                        // Engine path: prism + exact composition.
                        let tool = try p.prismFromSketch(sketch, offset: 0, along: length)
                        try booleanWithSolid(tool, .join)
                        let volume = try p.volume(solid!)
                        statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil,
                                                      message: String(format: "Cascade (OCCT) volume %.2f mm³", volume)))
                        logger.debug(.feature, "cascade pad ok", context: ["feature": feature.name, "volume": "\(volume)"])
                        continue
                    }
                    guard let evaluator = DocumentEngine.cascadePadEvaluator else { throw CADError.kernelUnavailable }
                    let (tool, volume) = try evaluator(sketch, length)
                    body = body.triangleCount == 0 ? tool : try CSG.union(body, tool)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil,
                                                  message: String(format: "Cascade (OCCT) volume %.2f mm³", volume)))
                    logger.debug(.feature, "cascade pad ok", context: ["feature": feature.name, "volume": "\(volume)"])
                    continue
                }
                if case .cascadePocket(let sketchID, let depth) = feature.kind {
                    guard depth > 0 else { throw CADError.holeSpecInvalid("pocket depth must be > 0") }
                    guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
                    // Surface the sketch's own profile warnings
                    // (SK213 gap heals) — the bridge extracts again
                    // internally and cannot return them.
                    let (pocketProfiles, pocketW) = try sketch.extractProfiles()
                    warnings += pocketW
                    guard !pocketProfiles.isEmpty else { throw CADError.padNoProfile }
                    guard let p = provider else { throw CADError.kernelUnavailable }
                    // Tool span mirrors the legacy pocket prism:
                    // from `depth` below the sketch plane to 1 mm
                    // above it, cut exactly by the engine.
                    let tool = try p.prismFromSketch(sketch, offset: -depth, along: depth + 1)
                    try booleanWithSolid(tool, .cut)
                    let volume = try p.volume(solid!)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil,
                                                  message: String(format: "Cascade (OCCT) volume %.2f mm³", volume)))
                    logger.debug(.feature, "cascade pocket ok", context: ["feature": feature.name, "volume": "\(volume)"])
                    continue
                }
                if case .importedSTEP(let name, let stepData) = feature.kind {
                    // Stage 7: a STEP file as a base feature. The
                    // bytes live in the document; they are staged
                    // to a temp file because the façade imports by
                    // path. Base-feature semantics: `.newBody` —
                    // first feature = the body; later = finish the
                    // current body and start a new one with the
                    // import. Engine-only (no provider → KN601).
                    guard let p = provider else { throw CADError.kernelUnavailable }
                    guard stepData.count <= DocumentEngine.maxImportedSTEPBytes else {
                        throw CADError.importFileUnreadable(
                            "that STEP file is \(stepData.count / (1024 * 1024)) MB — too large to keep inside a document (the limit is \(DocumentEngine.maxImportedSTEPBytes / (1024 * 1024)) MB)")
                    }
                    let staging = FileManager.default.temporaryDirectory
                        .appendingPathComponent("metalcad-import-\(feature.id).step")
                    do {
                        try stepData.write(to: staging)
                    } catch {
                        throw CADError.importFileUnreadable("the imported STEP data could not be staged for reading")
                    }
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let imported = try p.importSTEP(path: staging.path)
                    try booleanWithSolid(imported.handle, .newBody)
                    let volume = try p.volume(solid!)
                    // Stage 7b: keep the file's per-face colours
                    // against the adopted handle. Any later feature
                    // replaces the handle, retiring this entry.
                    if let colors = try? p.faceColors(imported.handle),
                       colors.contains(where: { $0.hasColor }) {
                        engineFaceColors[imported.handle] = colors
                    }
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil,
                                                  message: "Imported STEP '\(name)' — \(imported.solidCount) solid\(imported.solidCount == 1 ? "" : "s"), OCCT volume \(String(format: "%.1f", volume)) mm³"))
                    logger.debug(.feature, "imported STEP ok", context: [
                        "feature": feature.name, "solids": "\(imported.solidCount)",
                        "volume": "\(volume)"])
                    continue
                }
                if case .pad(let sketchID, let length) = feature.kind, let p = provider {
                    // Engine path (Stage 2). Validation mirrors the
                    // legacy order (sketch, profiles, length). The
                    // tool is a prism of ALL the sketch's profiles —
                    // the cascadePad behaviour; the legacy pad used
                    // only the first profile.
                    guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
                    let (profiles, w) = try sketch.extractProfiles()
                    warnings += w
                    guard !profiles.isEmpty else { throw CADError.padNoProfile }
                    guard length > 0 else { throw CADError.padLengthInvalid(length) }
                    let tool = try p.prismFromSketch(sketch, offset: 0, along: length)
                    try booleanWithSolid(tool, .join)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "pad ok (engine)", context: ["feature": feature.name])
                    continue
                }
                if case .pocket(let sketchID, let depth) = feature.kind, let p = provider {
                    // Engine path (Stage 2): the same tool span the
                    // legacy pocket prism used (depth below the
                    // sketch plane to 1 mm above it), cut exactly.
                    guard depth > 0 else { throw CADError.holeSpecInvalid("pocket depth must be > 0") }
                    guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
                    let (profiles, w) = try sketch.extractProfiles()
                    warnings += w
                    guard !profiles.isEmpty else { throw CADError.padNoProfile }
                    let tool = try p.prismFromSketch(sketch, offset: -depth, along: depth + 1)
                    try booleanWithSolid(tool, .cut)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "pocket ok (engine)", context: ["feature": feature.name])
                    continue
                }
                if case .revolve(let sketchID, let axisEntityID, let angle) = feature.kind, let p = provider {
                    // Engine path (Stage 2): outer profile revolved
                    // by the engine; each hole loop revolved and
                    // subtracted (the façade revolves one loop at a
                    // time). Validation mirrors the legacy order.
                    guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
                    guard let axisEnt = sketch.entity(axisEntityID),
                          case .line(_, let a, let b, _) = axisEnt else { throw CADError.revolveAxisMissing }
                    let (profiles, w) = try sketch.extractProfiles()
                    warnings += w
                    guard let profile = profiles.first else { throw CADError.padNoProfile }
                    guard angle > 0, angle <= 360 else {
                        throw CADError.transformInvalid("revolve angle \(angle) outside 0–360")
                    }
                    let dir = b - a
                    guard dir.length > 1e-12 else { throw CADError.revolveAxisMissing }
                    let dnorm = dir.normalized
                    var signs = Set<Int>()
                    for pt in profile.outer {
                        let d = (pt - a).cross(dnorm)
                        if abs(d) > 1e-9 { signs.insert(d > 0 ? 1 : -1) }
                    }
                    if signs.count > 1 { throw CADError.revolveProfileCrossesAxis }
                    var result = try p.revolveFromSketch(sketch, axisPoint: a, axisDirection: dir, angleDegrees: angle)
                    for hole in profile.holes {
                        let h = try p.revolveFromProfile(hole, plane: sketch.plane,
                                                         axisPoint: a, axisDirection: dir, angleDegrees: angle)
                        let r = try p.subtract(result, h)
                        p.release(result); p.release(h)
                        result = r
                    }
                    try booleanWithSolid(result, .join)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "revolve ok (engine)", context: ["feature": feature.name])
                    continue
                }
                if case .primitive(let kind, let params) = feature.kind, let p = provider {
                    // Engine path (Stage 2): native OCCT primitive,
                    // placed where the legacy kernel placed it (the
                    // provider's placement contract).
                    let h = try p.primitive(kind: kind, params: params)
                    try booleanWithSolid(h, .join)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "primitive ok (engine)", context: ["feature": feature.name])
                    continue
                }
                if case .extrude(let sketchID, let distance, let taper, let mode) = feature.kind, let p = provider {
                    // Engine path (Stage 2): prism (+ per-segment
                    // draft when tapered), composed exactly.
                    guard distance > 0 else { throw CADError.padLengthInvalid(distance) }
                    guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
                    let (profiles, w) = try sketch.extractProfiles()
                    warnings += w
                    guard !profiles.isEmpty else { throw CADError.padNoProfile }
                    let tool = try extrudeTool(p, sketch: sketch, mode: mode, distance: distance, taper: taper)
                    try booleanWithSolid(tool, .join)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "extrude ok (engine)", context: ["feature": feature.name])
                    continue
                }
                if case .loft(let idA, let idB) = feature.kind, let p = provider {
                    // Engine path (Stage 4): a ruled loft through
                    // the two sketches' first-profile outer loops —
                    // the legacy loft's straight interpolation, on
                    // the engine's real surfaces.
                    guard let skA = part.sketch(idA), let skB = part.sketch(idB) else { throw CADError.nameNotFound("sketch") }
                    let (profilesA, wA) = try skA.extractProfiles()
                    warnings += wA
                    guard let profA = profilesA.first, profA.outer.count >= 3 else { throw CADError.padNoProfile }
                    let (profilesB, wB) = try skB.extractProfiles()
                    warnings += wB
                    guard let profB = profilesB.first, profB.outer.count >= 3 else { throw CADError.padNoProfile }
                    let h = try p.loft(profiles: [(plane: skA.plane, points: profA.outer),
                                                  (plane: skB.plane, points: profB.outer)], ruled: true)
                    try booleanWithSolid(h, .join)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "loft ok (engine)", context: ["feature": feature.name])
                    continue
                }
                if case .sweep(let profileID, let pathID) = feature.kind, let p = provider {
                    // Engine path (Stage 4): the profile loop is
                    // re-centred onto the path start in the legacy
                    // first-segment frame (centroid ON the path, 2D
                    // coordinates preserved), then the engine
                    // sweeps it along the path polyline.
                    guard let skP = part.sketch(profileID), let skPath = part.sketch(pathID) else { throw CADError.nameNotFound("sketch") }
                    let loop = try ProfileLoop.worldLoop(sketch: skP)
                    let path = try DocumentEngine.pathPoints(sketch: skPath)
                    guard path.count >= 2 else { throw CADError.sweepPathInvalid("path needs at least 2 points") }
                    let centroid = loop.points.reduce(Vec3.zero) { $0 + $1 } * (1.0 / Double(loop.points.count))
                    let profile2: [Vec2] = loop.points.map { w in
                        let d = w - centroid
                        return Vec2(d.dot(skP.plane.xAxis), d.dot(skP.plane.yAxis))
                    }
                    let tangent = (path[1] - path[0]).normalized
                    let helper = abs(tangent.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
                    let fx = helper.cross(tangent).normalized
                    let fy = tangent.cross(fx).normalized
                    let frame = Plane3(origin: path[0], xAxis: fx, yAxis: fy)
                    let h = try p.sweep(profilePlane: frame, profile: profile2, path: path)
                    try booleanWithSolid(h, .join)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "sweep ok (engine)", context: ["feature": feature.name])
                    continue
                }
                if case .pipe(let pathSketchID, let radius) = feature.kind, let p = provider {
                    // Engine path (Stage 4): the legacy
                    // construction — a circular profile
                    // perpendicular to the path start, swept along
                    // the path — as ONE engine solid instead of
                    // CSG-unioned segment prisms. The profile is a
                    // 64-gon (legacy tessellated 32).
                    guard radius > 0 else { throw CADError.primitiveParamInvalid("pipe radius must be > 0") }
                    guard let sketch = part.sketch(pathSketchID) else { throw CADError.nameNotFound("sketch") }
                    let path = try DocumentEngine.pathPoints(sketch: sketch)
                    guard path.count >= 2 else { throw CADError.sweepPathInvalid("pipe path needs at least 2 points") }
                    let tangent = (path[1] - path[0]).normalized
                    let helper = abs(tangent.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
                    let u = helper.cross(tangent).normalized
                    let v = tangent.cross(u).normalized
                    let plane = Plane3(origin: path[0], xAxis: u, yAxis: v)
                    var profile: [Vec2] = []
                    for i in 0..<64 {
                        let a = Double(i) / 64 * 2 * Double.pi
                        profile.append(Vec2(radius * cos(a), radius * sin(a)))
                    }
                    let h = try p.sweep(profilePlane: plane, profile: profile, path: path)
                    try booleanWithSolid(h, .join)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "pipe ok (engine)", context: ["feature": feature.name])
                    continue
                }
                if case .coil(let radius, let pitch, let turns, let wireRadius) = feature.kind, let p = provider {
                    // Engine path (Stage 4): the wire profile
                    // swept by the engine along a sampled helix —
                    // one solid instead of a transported-ring mesh.
                    // 16 spine points per turn (the legacy coil's
                    // own ring density), capped at 1024 points.
                    guard radius > wireRadius, wireRadius > 0, pitch > 0, turns > 0.25 else {
                        throw CADError.primitiveParamInvalid("coil needs radius > wire radius, pitch > 0, turns > 0.25")
                    }
                    let totalSteps = min(1024, max(16, Int(ceil(turns * 16))))
                    var path: [Vec3] = []
                    path.reserveCapacity(totalSteps + 1)
                    for i in 0...totalSteps {
                        let th = Double(i) / Double(totalSteps) * turns * 2 * Double.pi
                        path.append(Vec3(radius * cos(th), radius * sin(th), pitch * th / (2 * Double.pi)))
                    }
                    let t0 = Vec3(0, radius, pitch / (2 * Double.pi)).normalized
                    let u = Vec3(1, 0, 0).cross(t0).normalized
                    let v = t0.cross(u).normalized
                    let plane = Plane3(origin: path[0], xAxis: u, yAxis: v)
                    var profile: [Vec2] = []
                    for i in 0..<32 {
                        let a = Double(i) / 32 * 2 * Double.pi
                        profile.append(Vec2(wireRadius * cos(a), wireRadius * sin(a)))
                    }
                    let h = try p.sweep(profilePlane: plane, profile: profile, path: path)
                    try booleanWithSolid(h, .join)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "coil ok (engine)", context: ["feature": feature.name])
                    continue
                }
                if case .hole(let sketchID, let diameter, let depth, let kind) = feature.kind, let p = provider {
                    // Engine path (Stage 4): the legacy drill tool
                    // rebuilt as exact solids — one cylinder per
                    // site (points drill at the feature diameter,
                    // circles at their own), plus the counterbore
                    // cylinder / countersink cone where the kind
                    // asks — united and cut exactly. Validation
                    // order and tool placement mirror evaluate().
                    guard diameter > 0 else { throw CADError.holeSpecInvalid("diameter must be > 0") }
                    guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
                    var sites: [(center: Vec2, diameter: Double)] = []
                    for e in sketch.entities where !e.isConstruction {
                        switch e {
                        case .point(_, let at, _):
                            sites.append((at, diameter))
                        case .circle(_, let c, let r, _):
                            sites.append((c, r > 0 ? 2 * r : diameter))
                        default: break
                        }
                    }
                    guard !sites.isEmpty else { throw CADError.holeSpecInvalid("the hole sketch needs a point or circle center") }
                    let through = depth <= 0
                    let cutDepth = through ? 10_000.0 : depth
                    let toolHeight = through ? 2 * cutDepth : cutDepth + 1
                    let toolAbove = through ? cutDepth : 1.0
                    // Kind guards hoisted: they depend only on the
                    // feature (legacy threw them from the first
                    // site's iteration — same error, same code).
                    switch kind {
                    case .simple: break
                    case .counterbore(let cbD, let cbDepth):
                        guard cbD > diameter, cbDepth > 0, cbDepth < cutDepth else {
                            throw CADError.holeSpecInvalid("counterbore must be wider and shallower than the hole")
                        }
                    case .countersink(let angle):
                        guard angle > 0, angle < 180 else { throw CADError.holeSpecInvalid("countersink angle 0-180") }
                    }
                    var tool: Int? = nil
                    func addTool(_ hTool: Int) throws {
                        if let t = tool {
                            let u2 = try p.unite(t, hTool)
                            p.release(t); p.release(hTool)
                            tool = u2
                        } else {
                            tool = hTool
                        }
                    }
                    for site in sites {
                        let center3 = sketch.plane.toWorld(site.center)
                        try addTool(try holeCylinder(p, plane: sketch.plane, center: center3,
                                                     diameter: site.diameter, height: toolHeight, above: toolAbove))
                        switch kind {
                        case .simple: break
                        case .counterbore(let cbD, let cbDepth):
                            if site.diameter < cbD {
                                try addTool(try holeCylinder(p, plane: sketch.plane, center: center3,
                                                             diameter: cbD, height: cbDepth + 1, above: 1))
                            }
                        case .countersink(let angle):
                            // The sink is the frustum from
                            // 2x the hole diameter at the surface
                            // narrowing to the hole diameter at
                            // depth coneH — the full cone of apex
                            // angle `angle` whose tip sits at
                            // 2*coneH. (Hardening 2026-10-29: the
                            // old tool was a cone of the HOLE's
                            // diameter parked over the surface —
                            // it lay entirely inside the drilled
                            // cylinder and removed nothing at all,
                            // on both kernels.) A 1 mm cap cylinder
                            // of the surface diameter keeps the
                            // cut's top face off the body surface.
                            let coneH = (site.diameter / 2) / tan(angle / 2 * .pi / 180)
                            let coneRaw = try p.primitive(kind: .cone, params: ["diameter": site.diameter * 2, "height": coneH * 2])
                            // The legacy cone (wide ring at local
                            // z = 0, apex at z = coneH) mapped by
                            // orientCylinder: local z lands at
                            // (1 − z) along the normal — a proper
                            // rotation (the y flip is invisible on
                            // a surface of revolution). Here the
                            // base ring lands ON the surface and
                            // the apex at depth 2*coneH.
                            let m = basisMatrix(sketch.plane.xAxis, sketch.plane.yAxis * -1,
                                                sketch.plane.normal * -1,
                                                center3)
                            let cone = try p.transform(coneRaw, matrix: m)
                            p.release(coneRaw)
                            try addTool(cone)
                            try addTool(try holeCylinder(p, plane: sketch.plane, center: center3,
                                                         diameter: site.diameter * 2, height: 1, above: 1))
                        }
                    }
                    guard let toolSolid = tool else { throw CADError.holeSpecInvalid("the hole sketch needs a point or circle center") }
                    try booleanWithSolid(toolSolid, .cut)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "hole ok (engine)", context: ["feature": feature.name])
                    continue
                }
                let m = try evaluate(feature: feature, part: part, warnings: &warnings)
                switch feature.kind {
                case .pocket, .hole:
                    guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                    body = try CSG.subtract(body, m)
                default:
                    body = body.triangleCount == 0 ? m : try CSG.union(body, m)
                }
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
        return FeatureEvaluation(
            statuses: statuses, warnings: warnings, firstError: firstError,
            meshBodies: bodies, engineBodies: solidBodies,
            runningSolid: solid, runningMesh: body,
            runningSolidMesh: solidMesh, runningFaceOfTriangle: solidFaceOfTriangle,
            faceColorsByHandle: engineFaceColors, meshBlocker: meshBlocker)
    }

    /// Evaluate a part's feature tree into one accumulated mesh.
    /// Stops after the first failing feature, per ERRORS.md DC107.
    public static func rebuild(part: Part, logger: MCLog = .shared) -> RebuildResult {
        let start = Date()
        let ev = evaluateFeatures(part: part, logger: logger)
        var firstError = ev.firstError
        var allBodies = ev.meshBodies
        var engineBody: EngineBodySnapshot? = nil
        var bodyFaceColors: [BodyFaceColors] = []
        // Exact engine volume across the output bodies (Stage 7:
        // mass from mc_volume, not from the tessellation). Set
        // only when EVERY output body is an engine solid; a single
        // mesh body retires it to nil and the tessellation-volume
        // mass below stays the fallback (mesh-only and mixed
        // parts — the pre-Stage-7 behaviour).
        var engineVolume: Double? = nil
        // Engine bodies join the output through tessellation; every
        // handle is released exactly once, here or in materialize —
        // except the final running body's, whose ownership passes
        // to the result's Stage 6 snapshot when its tessellation
        // carried census face ranges (the snapshot releases it).
        if let p = cascadeProvider {
            do {
                var volumeSum = 0.0
                var allEngine = ev.meshBodies.isEmpty
                for h in ev.engineBodies {
                    volumeSum += try p.volume(h)
                    if let colors = ev.faceColorsByHandle[h] {
                        // A completed imported body (Stage 7b):
                        // tessellate WITH ranges so its colours
                        // stay mapped to its triangles.
                        let t = try p.tessellateWithFaceRanges(h, deflection: DocumentEngine.previewDeflection)
                        if t.faceOfTriangle.count == t.mesh.triangleCount, !t.faceOfTriangle.isEmpty {
                            bodyFaceColors.append(BodyFaceColors(
                                bodyIndex: allBodies.count, faceOfTriangle: t.faceOfTriangle,
                                faceColors: colors))
                        }
                        allBodies.append(t.mesh)
                    } else {
                        allBodies.append(try p.tessellate(h, deflection: DocumentEngine.previewDeflection))
                    }
                    p.release(h)
                }
                if let h = ev.runningSolid {
                    volumeSum += try p.volume(h)
                    let offset = allBodies.reduce(0) { $0 + $1.triangleCount }
                    let finalMesh: Mesh
                    let faceOfTriangle: [Int]
                    if let cached = ev.runningSolidMesh {
                        finalMesh = cached
                        faceOfTriangle = ev.runningFaceOfTriangle
                    } else {
                        let t = try p.tessellateWithFaceRanges(h, deflection: DocumentEngine.previewDeflection)
                        finalMesh = t.mesh
                        faceOfTriangle = t.faceOfTriangle
                    }
                    allBodies.append(finalMesh)
                    if faceOfTriangle.count == finalMesh.triangleCount,
                       !faceOfTriangle.isEmpty {
                        engineBody = EngineBodySnapshot(
                            provider: p, handle: h, mesh: finalMesh,
                            triangleOffset: offset, faceOfTriangle: faceOfTriangle)
                        if let colors = ev.faceColorsByHandle[h] {
                            bodyFaceColors.append(BodyFaceColors(
                                bodyIndex: allBodies.count - 1, faceOfTriangle: faceOfTriangle,
                                faceColors: colors))
                        }
                    } else {
                        p.release(h)
                    }
                } else if ev.runningMesh.triangleCount > 0 {
                    allBodies.append(ev.runningMesh)
                    allEngine = false
                }
                if allEngine && (!ev.engineBodies.isEmpty || ev.runningSolid != nil) {
                    engineVolume = volumeSum
                }
            } catch let e as CADError {
                for h in ev.engineBodies { p.release(h) }
                if let h = ev.runningSolid { p.release(h) }
                if firstError == nil { firstError = e }
                if ev.runningMesh.triangleCount > 0 { allBodies.append(ev.runningMesh) }
                engineVolume = nil
                bodyFaceColors = []
            } catch {
                for h in ev.engineBodies { p.release(h) }
                if let h = ev.runningSolid { p.release(h) }
                engineVolume = nil
                bodyFaceColors = []
            }
        } else if ev.runningMesh.triangleCount > 0 {
            allBodies.append(ev.runningMesh)
        }
        var combined = Mesh()
        for b in allBodies { combined.append(b) }
        let massVolume = engineVolume ?? combined.volume
        let mass = massVolume / 1000.0 * part.material.density  // mm^3 -> cm^3 * g/cm^3
        logger.info(.perf, "rebuild done", context: [
            "ms": String(format: "%.1f", Date().timeIntervalSince(start) * 1000),
            "tris": "\(combined.triangleCount)",
            "bodies": "\(allBodies.count)",
            "ok": firstError == nil ? "1" : "0",
        ])
        return RebuildResult(mesh: combined, bodies: allBodies, statuses: ev.statuses, warnings: ev.warnings,
                             firstError: firstError, massGrams: mass, engineBody: engineBody,
                             bodyFaceColors: bodyFaceColors)
    }

    /// The result of a STEP export: the file written, the exact
    /// engine volume of each exported body (in body order), and
    /// whether the file carries the part's material colour (the
    /// XDE write) or fell back to the plain compound writer.
    public struct STEPExportResult {
        public var url: URL
        public var bodyVolumes: [Double]
        public var carriesColor: Bool
    }

    /// Export a part as ONE STEP file through the engine
    /// (Stage 7). Runs the shared `evaluateFeatures` walk and ends
    /// it with the bodies' handles in hand instead of
    /// tessellations: all bodies go into the file as a compound of
    /// solids, each solid carrying the part's material colour
    /// through the XDE writer (the plain compound writer is the
    /// no-colour fallback if the XDE write is refused).
    ///
    /// Failures, honestly: no provider → MCAD-KN601; a feature
    /// that fails to rebuild → that feature's own error; a body
    /// the engine no longer holds (a feature with no engine path
    /// materialised it) → MCAD-IO706 naming that feature; an empty
    /// part → MCAD-IO706; a façade write refusal → MCAD-IO706 from
    /// the bridge. Units are millimetres end to end; the file's
    /// product name is the part name. Names and assembly structure
    /// are NOT recoverable on re-import (the façade's §10 limit).
    public static func exportSTEP(part: Part, to url: URL, logger: MCLog = .shared) throws -> STEPExportResult {
        guard let p = cascadeProvider else { throw CADError.kernelUnavailable }
        let ev = evaluateFeatures(part: part, logger: logger)
        var handles = ev.engineBodies
        if let h = ev.runningSolid { handles.append(h) }
        defer { for h in handles { p.release(h) } }
        if let e = ev.firstError { throw e }
        if !ev.meshBodies.isEmpty || ev.runningMesh.triangleCount > 0 {
            let blocker = ev.meshBlocker ?? "one of its features"
            throw CADError.stepWriteFailed(
                "\(blocker) builds a plain mesh, not an engine solid, and STEP export writes the part's exact solid — that feature has no engine path yet")
        }
        guard !handles.isEmpty else {
            throw CADError.stepWriteFailed("there is no solid to export yet — the part is empty")
        }
        var volumes: [Double] = []
        for h in handles {
            do {
                volumes.append(try p.volume(h))
            } catch {
                throw CADError.stepWriteFailed("the engine could not measure a body for export")
            }
        }
        let m = part.material
        let colors = handles.map { _ in
            CensusFaceColor(red: m.red, green: m.green, blue: m.blue, hasColor: true)
        }
        do {
            try p.exportSTEPXDE(handles, colors: colors, name: part.name, path: url.path)
            logger.info(.io, "STEP exported (XDE, with material colour)", context: [
                "part": part.name, "bodies": "\(handles.count)", "file": url.lastPathComponent])
            return STEPExportResult(url: url, bodyVolumes: volumes, carriesColor: true)
        } catch let xdeError {
            logger.warn(.io, "XDE STEP export failed; retrying without colour",
                        code: (xdeError as? CADError)?.code, context: ["part": part.name])
            do {
                try p.exportSTEPBodies(handles, path: url.path)
            } catch {
                throw xdeError
            }
            logger.info(.io, "STEP exported (plain compound, no colour)", context: [
                "part": part.name, "bodies": "\(handles.count)", "file": url.lastPathComponent])
            return STEPExportResult(url: url, bodyVolumes: volumes, carriesColor: false)
        }
    }

    /// Chain a sketch's line entities into an ordered world-space polyline
    /// (the sweep path).
    static func pathPoints(sketch: Sketch) throws -> [Vec3] {
        var segments: [(Vec2, Vec2)] = []
        for e in sketch.entities where !e.isConstruction {
            if case .line(_, let a, let b, _) = e { segments.append((a, b)) }
        }
        guard !segments.isEmpty else { throw CADError.sweepPathInvalid("the path sketch needs connected lines") }
        var chain: [Vec2] = [segments[0].0, segments[0].1]
        var pool = Array(segments.dropFirst())
        // Two tiers, like profile extraction: exact joints first,
        // then sewn joints at the sketch sewing tolerance — a
        // hand-drawn path corner that missed its mate by a hair
        // still chains (the joint is the chain's vertex).
        for tol in [1e-6, Sketch.sewTolerance] {
            var grew = true
            while grew {
                grew = false
                for i in pool.indices {
                    let (a, b) = pool[i]
                    if a.distance(to: chain.last!) < tol { chain.append(b); pool.remove(at: i); grew = true; break }
                    if b.distance(to: chain.last!) < tol { chain.append(a); pool.remove(at: i); grew = true; break }
                    if a.distance(to: chain.first!) < tol { chain.insert(b, at: 0); pool.remove(at: i); grew = true; break }
                    if b.distance(to: chain.first!) < tol { chain.insert(a, at: 0); pool.remove(at: i); grew = true; break }
                }
            }
        }
        guard chain.count >= 2 else { throw CADError.sweepPathInvalid("path lines do not connect") }
        return chain.map { sketch.plane.toWorld($0) }
    }

    /// Map a +Z-built tool mesh (z: 0…height) onto a sketch plane so it
    /// starts `above` mm over the surface point and reaches into the part
    /// along −normal.
    static func orientCylinder(_ m: Mesh, plane: Plane3, center: Vec3, above: Double, depth: Double) -> Mesh {
        let n = plane.normal
        let verts = m.vertices.map { v in
            center + plane.xAxis * v.x + plane.yAxis * v.y + n * (above - v.z)
        }
        _ = depth
        // The z -> (above - z) map is a reflection: flip winding to restore
        // outward normals, or CSG will treat the tool as inside-out.
        var idx: [UInt32] = []
        for t in 0..<m.triangleCount {
            idx += [m.indices[t * 3], m.indices[t * 3 + 2], m.indices[t * 3 + 1]]
        }
        return Mesh(vertices: verts, indices: idx)
    }

    static func evaluate(feature: Feature, part: Part, warnings: inout [CADError]) throws -> Mesh {
        switch feature.kind {
        case .pad(let sketchID, let length):
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            let (profiles, w) = try sketch.extractProfiles()
            warnings += w
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            return try Tessellation.extrude(profile: profile, plane: sketch.plane, length: length)
        case .pocket(let sketchID, let depth):
            guard depth > 0 else { throw CADError.holeSpecInvalid("pocket depth must be > 0") }
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            let (profiles, w) = try sketch.extractProfiles()
            warnings += w
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            // Prism spanning from 1 mm above the sketch plane to `depth`
            // below it; rebuild subtracts it from the body.
            let prism = try Tessellation.extrude(profile: profile, plane: sketch.plane, length: depth + 1)
            return prism.translated(by: sketch.plane.normal * -depth)
        case .hole(let sketchID, let diameter, let depth, let kind):
            guard diameter > 0 else { throw CADError.holeSpecInvalid("diameter must be > 0") }
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            // Drill sites: sketch points drill at the feature's
            // diameter; sketch circles drill at their OWN diameter
            // (2 x radius) — a sketched circle is the hole's profile,
            // not just a center marker. (Device bug, 2026-10-26: a
            // big circle + Hole produced a small hole at its center,
            // drilled at the panel diameter.)
            var sites: [(center: Vec2, diameter: Double)] = []
            for e in sketch.entities where !e.isConstruction {
                switch e {
                case .point(_, let at, _):
                    sites.append((at, diameter))
                case .circle(_, let c, let r, _):
                    sites.append((c, r > 0 ? 2 * r : diameter))
                default: break
                }
            }
            guard !sites.isEmpty else { throw CADError.holeSpecInvalid("the hole sketch needs a point or circle center") }
            // Depth 0 = through: the cutter is a full column along the
            // axis (cutDepth each way from the sketch plane), so the
            // hole really passes through everything on that axis —
            // including material piled over the sketch plane (the demo
            // part's boss sits on the very face its sketch came from,
            // and a plane-anchored cutter left its top half uncut,
            // i.e. the "through" hole was blind from that side).
            // A blind hole (depth > 0) starts at the sketch plane and
            // reaches `depth` into the part, as before.
            let through = depth <= 0
            let cutDepth = through ? 10_000.0 : depth
            let toolHeight = through ? 2 * cutDepth : cutDepth + 1
            let toolAbove = through ? cutDepth : 1.0
            var tool = Mesh()
            for site in sites {
                let center3 = sketch.plane.toWorld(site.center)
                var cyl = try Tessellation.cylinder(radius: site.diameter / 2, height: toolHeight, segments: 48)
                // Cylinder is built along +Z from z=0; orient it along -normal
                // starting 1 mm above the plane.
                cyl = orientCylinder(cyl, plane: sketch.plane, center: center3, above: toolAbove, depth: toolHeight)
                tool.append(cyl)
                switch kind {
                case .simple: break
                case .counterbore(let cbD, let cbDepth):
                    guard cbD > diameter, cbDepth > 0, cbDepth < cutDepth else {
                        throw CADError.holeSpecInvalid("counterbore must be wider and shallower than the hole")
                    }
                    // The bore keeps the panel's size, measured from
                    // the sketch plane. Where a circle site is already
                    // wider than the bore, the bore cutter would be
                    // buried inside the hole and cut nothing — skip it
                    // for that site (and never error over it).
                    if site.diameter < cbD {
                        var cb = try Tessellation.cylinder(radius: cbD / 2, height: cbDepth + 1, segments: 48)
                        cb = orientCylinder(cb, plane: sketch.plane, center: center3, above: 1, depth: cbDepth + 1)
                        tool.append(cb)
                    }
                case .countersink(let angle):
                    guard angle > 0, angle < 180 else { throw CADError.holeSpecInvalid("countersink angle 0-180") }
                    // Same frustum as the engine path: full
                    // cone of diameter 2x the hole, base ring ON
                    // the surface, apex at depth 2*coneH, plus
                    // the 1 mm cap cylinder (see the engine
                    // branch; the old cone removed nothing).
                    let coneH = (site.diameter / 2) / tan(angle / 2 * .pi / 180)
                    var cone = try Tessellation.cone(radius: site.diameter, height: coneH * 2, segments: 48)
                    cone = orientCylinder(cone, plane: sketch.plane, center: center3, above: 0, depth: coneH * 2)
                    tool.append(cone)
                    var cap = try Tessellation.cylinder(radius: site.diameter, height: 1, segments: 48)
                    cap = orientCylinder(cap, plane: sketch.plane, center: center3, above: 1, depth: 1)
                    tool.append(cap)
                }
            }
            return tool
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
        case .threadShaft:
            throw CADError.invariantBroken("thread shafts must be handled by rebuild, not evaluate")
        case .linearPattern:
            throw CADError.invariantBroken("pattern must be handled by rebuild, not evaluate")
        case .mirror:
            throw CADError.invariantBroken("mirror must be handled by rebuild, not evaluate")
        case .fillet, .chamfer, .shell, .chamfer2, .extrude2, .rib, .draftBody, .scaleBody, .moveBody, .splitBody, .circularPattern, .filletEdges, .chamferEdges, .threadOnShaft:
            throw CADError.invariantBroken("body-dependent feature must be handled by rebuild, not evaluate")
        case .coil(let radius, let pitch, let turns, let wireRadius):
            return try coilMesh(radius: radius, pitch: pitch, turns: turns, wireRadius: wireRadius)
        case .pipe(let pathSketchID, let radius):
            return try pipeMesh(part: part, pathSketchID: pathSketchID, radius: radius)
        case .extrude(let sketchID, let distance, let taper, let mode):
            guard distance > 0 else { throw CADError.padLengthInvalid(distance) }
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            let (profiles, w) = try sketch.extractProfiles()
            warnings += w
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            switch mode {
            case .one:
                return try Tessellation.extrudeTapered(profile: profile, plane: sketch.plane, length: distance, taperDegrees: taper)
            case .symmetric:
                let shifted = Plane3(origin: sketch.plane.origin - sketch.plane.normal * (distance / 2),
                                     xAxis: sketch.plane.xAxis, yAxis: sketch.plane.yAxis)
                return try Tessellation.extrudeTapered(profile: profile, plane: shifted, length: distance, taperDegrees: taper)
            case .twoSided(let second):
                guard second > 0 else { throw CADError.padLengthInvalid(second) }
                var m = try Tessellation.extrudeTapered(profile: profile, plane: sketch.plane, length: distance, taperDegrees: taper)
                let backPlane = Plane3(origin: sketch.plane.origin - sketch.plane.normal * second,
                                       xAxis: sketch.plane.xAxis, yAxis: sketch.plane.yAxis)
                let back = try Tessellation.extrudeTapered(profile: profile, plane: backPlane, length: second, taperDegrees: taper)
                m.append(back)
                return m
            }
        case .loft(let idA, let idB):
            guard let skA = part.sketch(idA), let skB = part.sketch(idB) else { throw CADError.nameNotFound("sketch") }
            let loopA = try ProfileLoop.worldLoop(sketch: skA)
            let loopB = try ProfileLoop.worldLoop(sketch: skB)
            return try LoftTessellator.loft(loopA: loopA.points, loopB: loopB.points)
        case .sweep(let profileID, let pathID):
            guard let skP = part.sketch(profileID), let skPath = part.sketch(pathID) else { throw CADError.nameNotFound("sketch") }
            let loop = try ProfileLoop.worldLoop(sketch: skP)
            let path = try DocumentEngine.pathPoints(sketch: skPath)
            return try SweepTessellator.sweep(profileLoop: loop.points, profilePlane: skP.plane, path: path)
        case .booleanCutPlaceholder:
            throw CADError.booleanFailed("exact boolean arrives with the OCCT kernel bridge")
        case .cascadePad:
            throw CADError.invariantBroken("cascade pad must be handled by rebuild, not evaluate")
        case .cascadePocket:
            throw CADError.invariantBroken("cascade pocket must be handled by rebuild, not evaluate")
        case .importedSTEP:
            throw CADError.invariantBroken("imported STEP must be handled by rebuild, not evaluate")
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
