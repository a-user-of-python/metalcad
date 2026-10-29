import Foundation

/// The Cascade implant (2026-10-28): Open CASCADE (OCCT 8.0.1)
/// linked into MetalCAD as the CascadeKit static library, reached
/// through the thin C façade (`occt_facade.h`, bridging header).
///
/// Division of labour, as everywhere in this project: Swift drives,
/// Cascade computes. The kit stays pure Swift — at launch the app
/// registers a `CascadeKernelProvider` (the full-OCCT migration:
/// every migrated feature rebuilds through OCCT, composition is
/// exact) plus the original single-purpose `cascadePadEvaluator`
/// hook as a fallback for provider-less contexts.
///
/// Solids cross the boundary as opaque registry integers (the
/// kit-side convention); this file owns the MCFacadeShape handles.
///
/// Façade failures map onto the KN domain of the error taxonomy
/// (MCAD-KN602 operation refused / KN604 tessellation) — the
/// façade's own plain-words message is logged in full and carried
/// in the error detail, never shown raw beyond that.
///
/// LGPL: OCCT is LGPL 2.1 + the Open CASCADE exception; the licence
/// texts ship in the app bundle (Resources) and the attribution
/// lives in Settings and the README. OCCT sources are never
/// modified — the engine tree is the pinned cascade-ios checkout.
enum CascadeBridge {

    /// The shared provider instance (also backs the legacy hook).
    static let provider = CascadeKernelBridge()

    /// Called once from the app entry point.
    static func register() {
        DocumentEngine.cascadeProvider = provider
        DocumentEngine.cascadePadEvaluator = { sketch, length in
            let h = try provider.prismFromSketch(sketch, offset: 0, along: length)
            defer { provider.release(h) }
            return (try provider.tessellate(h, deflection: DocumentEngine.previewDeflection),
                    try provider.volume(h))
        }
        MCLog.shared.info(.kernel, "Cascade (OCCT) kernel registered",
                          context: ["occt": String(cString: mc_occt_version())])
    }
}

/// The OCCT-backed `CascadeKernelProvider`. All façade calls are
/// serialised through one lock (the app rebuilds on the main thread
/// AND a background draft queue; the façade keeps a global
/// last-error string).
final class CascadeKernelBridge: CascadeKernelProvider {

    private let gate = NSLock()
    private var shapes: [Int: UnsafeMutablePointer<MCFacadeShape>] = [:]
    private var nextID = 1

    // MARK: Handle registry (call with the gate held, except release)

    private func own(_ h: UnsafeMutablePointer<MCFacadeShape>?) throws -> Int {
        guard let h else { throw CADError.kernelOperationFailed(Self.lastError()) }
        let id = nextID
        nextID += 1
        shapes[id] = h
        return id
    }

    private func shape(_ id: Int) throws -> UnsafeMutablePointer<MCFacadeShape> {
        guard let h = shapes[id] else {
            throw CADError.kernelOperationFailed("That solid is no longer available.")
        }
        return h
    }

    func release(_ id: Int) {
        gate.lock()
        defer { gate.unlock() }
        if let h = shapes.removeValue(forKey: id) { mc_free_shape(h) }
    }

    private static func lastError() -> String {
        String(cString: mc_last_error())
    }

    /// Run `work` under the gate.
    private func locked<T>(_ work: () throws -> T) throws -> T {
        gate.lock()
        defer { gate.unlock() }
        return try work()
    }

    // MARK: Sketch-based solids

    func prismFromSketch(_ sketch: Sketch, offset: Double, along: Double) throws -> Int {
        try locked {
            guard along > 0 else {
                throw CADError.kernelOperationFailed("Extrusion length must be positive.")
            }
            let faces = try makeFaces(sketch: sketch)
            defer { faces.forEach { mc_free_shape($0) } }
            let n = sketch.plane.normal
            let dir: [Double] = [n.x, n.y, n.z]
            var err: Int32 = 0
            var result: UnsafeMutablePointer<MCFacadeShape>?
            for face in faces {
                guard let solid = mc_prism_face(face, dir, along, &err) else {
                    if let r = result { mc_free_shape(r) }
                    throw CADError.kernelOperationFailed(Self.lastError())
                }
                if let r = result {
                    let united = mc_unite(r, solid, &err)
                    mc_free_shape(r)
                    mc_free_shape(solid)
                    guard let united else { throw CADError.kernelOperationFailed(Self.lastError()) }
                    result = united
                } else {
                    result = solid
                }
            }
            guard let solid = result else {
                throw CADError.kernelOperationFailed("Nothing to extrude.")
            }
            var final = solid
            if offset != 0 {
                let moved = try transformRaw(solid, matrix: Self.translationMatrix(n * offset))
                mc_free_shape(solid)
                final = moved
            }
            return try own(final)
        }
    }

    func prismFromProfile(_ points: [Vec2], plane: Plane3, offset: Double, along: Double) throws -> Int {
        try locked {
            guard points.count >= 3, along > 0 else {
                throw CADError.kernelOperationFailed("A profile needs at least 3 points and a positive length.")
            }
            var xy: [Double] = []
            for p in points { xy += [p.x, p.y] }
            let origin: [Double] = [plane.origin.x, plane.origin.y, plane.origin.z]
            let xa: [Double] = [plane.xAxis.x, plane.xAxis.y, plane.xAxis.z]
            let ya: [Double] = [plane.yAxis.x, plane.yAxis.y, plane.yAxis.z]
            let n = plane.normal
            let dir: [Double] = [n.x, n.y, n.z]
            var err: Int32 = 0
            guard let solid = mc_prism(xy, Int32(points.count), origin, xa, ya, dir, along, &err) else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            var final = solid
            if offset != 0 {
                let moved = try transformRaw(solid, matrix: Self.translationMatrix(n * offset))
                mc_free_shape(solid)
                final = moved
            }
            return try own(final)
        }
    }

    func revolveFromSketch(_ sketch: Sketch, axisPoint: Vec2, axisDirection: Vec2,
                           angleDegrees: Double) throws -> Int {
        try locked {
            let (profiles, _) = try sketch.extractProfiles()
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            return try own(revolveRaw(points: profile.outer, plane: sketch.plane,
                                      axisPoint: axisPoint, axisDirection: axisDirection,
                                      angleDegrees: angleDegrees))
        }
    }

    func revolveFromProfile(_ points: [Vec2], plane: Plane3, axisPoint: Vec2,
                            axisDirection: Vec2, angleDegrees: Double) throws -> Int {
        try locked {
            guard points.count >= 3 else {
                throw CADError.kernelOperationFailed("A revolve profile needs at least 3 points.")
            }
            return try own(revolveRaw(points: points, plane: plane,
                                      axisPoint: axisPoint, axisDirection: axisDirection,
                                      angleDegrees: angleDegrees))
        }
    }

    /// mc_revolve on raw points (gate held). Caller owns the result.
    private func revolveRaw(points: [Vec2], plane: Plane3, axisPoint: Vec2,
                            axisDirection: Vec2, angleDegrees: Double) throws -> UnsafeMutablePointer<MCFacadeShape> {
        var xy: [Double] = []
        for p in points { xy += [p.x, p.y] }
        let origin: [Double] = [plane.origin.x, plane.origin.y, plane.origin.z]
        let xa: [Double] = [plane.xAxis.x, plane.xAxis.y, plane.xAxis.z]
        let ya: [Double] = [plane.yAxis.x, plane.yAxis.y, plane.yAxis.z]
        let ap = plane.toWorld(axisPoint)
        let ad = plane.xAxis * axisDirection.x + plane.yAxis * axisDirection.y
        let axisPoint3: [Double] = [ap.x, ap.y, ap.z]
        let axisDir3: [Double] = [ad.x, ad.y, ad.z]
        var err: Int32 = 0
        guard let solid = mc_revolve(xy, Int32(points.count), origin, xa, ya,
                                     axisPoint3, axisDir3, angleDegrees, &err) else {
            throw CADError.kernelOperationFailed(Self.lastError())
        }
        return solid
    }

    // MARK: Primitives

    func primitive(kind: PrimitiveKind, params p: [String: Double]) throws -> Int {
        try locked {
            var err: Int32 = 0
            switch kind {
            case .box:
                let w = p["width"] ?? 10, d = p["depth"] ?? 10, h = p["height"] ?? 10
                guard let s = mc_box(w, d, h, &err) else {
                    throw CADError.kernelOperationFailed(Self.lastError())
                }
                // The kit's box is XY-centred; mc_box corners at the
                // origin. Translate to the kit's placement.
                let moved = try transformRaw(s, matrix: Self.translationMatrix(Vec3(-w / 2, -d / 2, 0)))
                mc_free_shape(s)
                return try own(moved)
            case .cylinder:
                guard let s = mc_cylinder((p["diameter"] ?? 10) / 2, p["height"] ?? 10, &err) else {
                    throw CADError.kernelOperationFailed(Self.lastError())
                }
                return try own(s)
            case .sphere:
                guard let s = mc_sphere((p["diameter"] ?? 10) / 2, &err) else {
                    throw CADError.kernelOperationFailed(Self.lastError())
                }
                return try own(s)
            case .cone:
                guard let s = mc_cone((p["diameter"] ?? 10) / 2, 0, p["height"] ?? 10, &err) else {
                    throw CADError.kernelOperationFailed(Self.lastError())
                }
                return try own(s)
            case .torus:
                guard let s = mc_torus(p["ringRadius"] ?? 15, p["tubeRadius"] ?? 5, &err) else {
                    throw CADError.kernelOperationFailed(Self.lastError())
                }
                return try own(s)
            }
        }
    }

    // MARK: Loft / sweep

    func loft(profiles: [(plane: Plane3, points: [Vec2])], ruled: Bool) throws -> Int {
        try locked {
            guard profiles.count >= 2 else {
                throw CADError.kernelOperationFailed("A loft needs at least two profiles.")
            }
            var counts: [Int32] = profiles.map { Int32($0.points.count) }
            var origins: [Double] = []
            var xAxes: [Double] = []
            var yAxes: [Double] = []
            for prof in profiles {
                origins += [prof.plane.origin.x, prof.plane.origin.y, prof.plane.origin.z]
                xAxes += [prof.plane.xAxis.x, prof.plane.xAxis.y, prof.plane.xAxis.z]
                yAxes += [prof.plane.yAxis.x, prof.plane.yAxis.y, prof.plane.yAxis.z]
            }
            // mc_loft takes an array of per-profile point arrays:
            // allocate each one explicitly so every pointer stays
            // valid for the whole call.
            var allocations: [UnsafeMutableBufferPointer<Double>] = []
            var profilePtrs: [UnsafePointer<Double>?] = []
            for prof in profiles {
                let buf = UnsafeMutableBufferPointer<Double>.allocate(capacity: max(1, prof.points.count * 2))
                for (i, p) in prof.points.enumerated() {
                    buf[2 * i] = p.x
                    buf[2 * i + 1] = p.y
                }
                allocations.append(buf)
                profilePtrs.append(UnsafePointer(buf.baseAddress))
            }
            defer { allocations.forEach { $0.deallocate() } }
            var err: Int32 = 0
            guard let result = mc_loft(&profilePtrs, &counts, Int32(profiles.count),
                                       origins, xAxes, yAxes, ruled ? 1 : 0, &err) else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            return try own(result)
        }
    }

    func sweep(profilePlane: Plane3, profile: [Vec2], path: [Vec3]) throws -> Int {
        try locked {
            guard profile.count >= 3, path.count >= 2 else {
                throw CADError.kernelOperationFailed("A sweep needs a closed profile and a path.")
            }
            var xy: [Double] = []
            for p in profile { xy += [p.x, p.y] }
            var pts: [Double] = []
            for p in path { pts += [p.x, p.y, p.z] }
            let origin: [Double] = [profilePlane.origin.x, profilePlane.origin.y, profilePlane.origin.z]
            let xa: [Double] = [profilePlane.xAxis.x, profilePlane.xAxis.y, profilePlane.xAxis.z]
            let ya: [Double] = [profilePlane.yAxis.x, profilePlane.yAxis.y, profilePlane.yAxis.z]
            var err: Int32 = 0
            guard let solid = mc_sweep(xy, Int32(profile.count), origin, xa, ya,
                                       pts, Int32(path.count), &err) else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            return try own(solid)
        }
    }

    func thread(spec: ThreadSpec) throws -> Int {
        try locked {
            var err: Int32 = 0
            // Canonical placement (façade contract): axis +Z, base
            // at the origin, segment z in [0, length]. External →
            // the complete threaded segment; internal → the groove
            // TOOL the kit subtracts from a bored blank. The kit
            // passes the VALIDATED spec, so the façade's own
            // validation agrees by construction.
            guard let h = mc_thread(spec.majorDiameter, spec.pitch,
                                    spec.threadDepth,
                                    spec.profileAngleDegrees,
                                    Int32(spec.starts),
                                    spec.kind == .internal ? 1 : 0,
                                    spec.hand == .left ? 1 : 0,
                                    spec.taperDegrees, spec.clearance,
                                    spec.length, &err) else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            return try own(h)
        }
    }

    // MARK: Booleans / finishing / transforms

    func unite(_ a: Int, _ b: Int) throws -> Int {
        try locked {
            var err: Int32 = 0
            return try own(mc_unite(try shape(a), try shape(b), &err))
        }
    }

    func subtract(_ a: Int, _ b: Int) throws -> Int {
        try locked {
            var err: Int32 = 0
            return try own(mc_subtract(try shape(a), try shape(b), &err))
        }
    }

    func intersect(_ a: Int, _ b: Int) throws -> Int {
        try locked {
            var err: Int32 = 0
            return try own(mc_intersect(try shape(a), try shape(b), &err))
        }
    }

    func fillet(_ s: Int, radius: Double, edgeIndices: [Int]?) throws -> Int {
        try locked {
            var err: Int32 = 0
            let h = try shape(s)
            if let idx = edgeIndices {
                let list = idx.map { Int32($0) }
                return try own(mc_fillet(h, radius, list, Int32(list.count), &err))
            }
            return try own(mc_fillet(h, radius, nil, 0, &err))
        }
    }

    func chamfer(_ s: Int, distance: Double, edgeIndices: [Int]?) throws -> Int {
        try locked {
            var err: Int32 = 0
            let h = try shape(s)
            if let idx = edgeIndices {
                let list = idx.map { Int32($0) }
                return try own(mc_chamfer(h, distance, list, Int32(list.count), &err))
            }
            return try own(mc_chamfer(h, distance, nil, 0, &err))
        }
    }

    func chamfer2(_ s: Int, distanceA: Double, distanceB: Double, edgeIndices: [Int]?) throws -> Int {
        try locked {
            var err: Int32 = 0
            let h = try shape(s)
            if let idx = edgeIndices {
                let list = idx.map { Int32($0) }
                return try own(mc_chamfer2(h, distanceA, distanceB, list, Int32(list.count), &err))
            }
            return try own(mc_chamfer2(h, distanceA, distanceB, nil, 0, &err))
        }
    }

    func shell(_ s: Int, thickness: Double) throws -> Int {
        try locked {
            var err: Int32 = 0
            return try own(mc_shell(try shape(s), thickness, &err))
        }
    }

    func draft(_ s: Int, angleDegrees: Double, pullAxis: Int) throws -> Int {
        try locked {
            let h = try shape(s)
            var err: Int32 = 0
            var bb = [Double](repeating: 0, count: 6)
            guard mc_bbox(h, &bb, &err) == MC_OK.rawValue else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            // Neutral plane at the body's minimum along the pull
            // axis (the kit draft's convention).
            let axisVec: [Double] = pullAxis == 0 ? [1, 0, 0] : pullAxis == 1 ? [0, 1, 0] : [0, 0, 1]
            var neutral: [Double] = [bb[0], bb[1], bb[2]]
            neutral[pullAxis] = bb[pullAxis]
            return try own(mc_draft(h, axisVec, angleDegrees, neutral, &err))
        }
    }

    func draftGeneral(_ s: Int, pullDirection: Vec3, angleDegrees: Double, neutralPoint: Vec3) throws -> Int {
        try locked {
            let h = try shape(s)
            let dir: [Double] = [pullDirection.x, pullDirection.y, pullDirection.z]
            let neutral: [Double] = [neutralPoint.x, neutralPoint.y, neutralPoint.z]
            var err: Int32 = 0
            return try own(mc_draft(h, dir, angleDegrees, neutral, &err))
        }
    }

    func transform(_ s: Int, matrix: [Double]) throws -> Int {
        try locked {
            guard matrix.count == 12 else {
                throw CADError.kernelOperationFailed("A transform needs 12 numbers.")
            }
            return try own(transformRaw(try shape(s), matrix: matrix))
        }
    }

    /// mc_transform on a raw handle (gate held). Caller owns the
    /// result; the input is left unchanged.
    private func transformRaw(_ h: UnsafeMutablePointer<MCFacadeShape>,
                              matrix: [Double]) throws -> UnsafeMutablePointer<MCFacadeShape> {
        var err: Int32 = 0
        guard let r = mc_transform(h, matrix, &err) else {
            throw CADError.kernelOperationFailed(Self.lastError())
        }
        return r
    }

    static func translationMatrix(_ t: Vec3) -> [Double] {
        [1, 0, 0, t.x, 0, 1, 0, t.y, 0, 0, 1, t.z]
    }

    // MARK: Queries

    func volume(_ s: Int) throws -> Double {
        try locked {
            var err: Int32 = 0
            let v = mc_volume(try shape(s), &err)
            guard err == MC_OK.rawValue else { throw CADError.kernelOperationFailed(Self.lastError()) }
            return v
        }
    }

    func bounds(_ s: Int) throws -> (min: Vec3, max: Vec3) {
        try locked {
            var err: Int32 = 0
            var bb = [Double](repeating: 0, count: 6)
            guard mc_bbox(try shape(s), &bb, &err) == MC_OK.rawValue else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            return (Vec3(bb[0], bb[1], bb[2]), Vec3(bb[3], bb[4], bb[5]))
        }
    }

    func contains(_ s: Int, point: Vec3) throws -> Bool {
        try locked {
            var err: Int32 = 0
            let r = mc_contains(try shape(s), point.x, point.y, point.z, &err)
            guard err == MC_OK.rawValue else { throw CADError.kernelOperationFailed(Self.lastError()) }
            return r == 1
        }
    }

    func census(_ s: Int) throws -> (faces: Int, edges: Int, vertices: Int) {
        try locked {
            var err: Int32 = 0
            var f: Int32 = 0, e: Int32 = 0, v: Int32 = 0
            guard mc_shape_counts(try shape(s), &f, &e, &v, &err) == MC_OK.rawValue else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            return (Int(f), Int(e), Int(v))
        }
    }

    func faceInfo(_ s: Int, index: Int) throws -> (area: Double, center: Vec3, normal: Vec3, isPlanar: Bool) {
        try locked {
            var err: Int32 = 0
            var area: Double = 0
            var center = [Double](repeating: 0, count: 3)
            var normal = [Double](repeating: 0, count: 3)
            var planar: Int32 = 0
            guard mc_face_info(try shape(s), Int32(index), &area, &center, &normal, &planar, &err) == MC_OK.rawValue else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            return (area, Vec3(center[0], center[1], center[2]),
                    Vec3(normal[0], normal[1], normal[2]), planar != 0)
        }
    }

    func edgeInfos(_ s: Int) throws -> [CascadeEdgeInfo] {
        try locked {
            let h = try shape(s)
            var err: Int32 = 0
            var f: Int32 = 0, e: Int32 = 0, v: Int32 = 0
            guard mc_shape_counts(h, &f, &e, &v, &err) == MC_OK.rawValue else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            var out: [CascadeEdgeInfo] = []
            out.reserveCapacity(Int(e))
            for i in 0..<e {
                var type: Int32 = 0
                var length: Double = 0
                var start = [Double](repeating: 0, count: 3)
                var end = [Double](repeating: 0, count: 3)
                var center = [Double](repeating: 0, count: 3)
                var radius: Double = 0
                guard mc_edge_info(h, i, &type, &length, &start, &end, &center, &radius, &err) == MC_OK.rawValue else {
                    throw CADError.kernelOperationFailed(Self.lastError())
                }
                out.append(CascadeEdgeInfo(
                    curveType: Int(type), length: length,
                    start: Vec3(start[0], start[1], start[2]),
                    end: Vec3(end[0], end[1], end[2]),
                    center: Vec3(center[0], center[1], center[2]),
                    radius: radius))
            }
            return out
        }
    }

    // MARK: Tessellation / STEP

    func tessellate(_ s: Int, deflection: Double) throws -> Mesh {
        try tessellateWithFaceRanges(s, deflection: deflection).mesh
    }

    /// Tessellation WITH the census face index of every triangle
    /// (Stage 6): the façade mesh's per-face ranges, expanded.
    /// Vertices are duplicated per face in the façade output, so
    /// the ranges are exact — this mapping is what sketch-on-face
    /// picks through.
    func tessellateWithFaceRanges(_ s: Int, deflection: Double) throws -> (mesh: Mesh, faceOfTriangle: [Int]) {
        try locked {
            let h = try shape(s)
            var err: Int32 = 0
            var fmesh = MCFacadeMesh()
            let rc = mc_tessellate(h, deflection, &fmesh, &err)
            guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
                throw CADError.kernelTessellationFailed(Self.lastError())
            }
            defer { mc_free_mesh(&fmesh) }
            let vcount = Int(fmesh.vertexCount)
            let tcount = Int(fmesh.triangleCount)
            var vertices: [Vec3] = []
            vertices.reserveCapacity(vcount)
            for i in 0..<vcount {
                vertices.append(Vec3(Double(fmesh.positions[3 * i]),
                                     Double(fmesh.positions[3 * i + 1]),
                                     Double(fmesh.positions[3 * i + 2])))
            }
            var indices: [UInt32] = []
            indices.reserveCapacity(tcount * 3)
            for i in 0..<(tcount * 3) {
                indices.append(UInt32(fmesh.indices[i]))
            }
            // The façade appends triangles face by face (its
            // documented contract), so expanding the ranges is an
            // ordered fill: face f owns the next faceTriCount[f]
            // triangles.
            var faceOfTriangle: [Int] = []
            faceOfTriangle.reserveCapacity(tcount)
            if fmesh.faceCount > 0, fmesh.faceTriCount != nil {
                for f in 0..<Int(fmesh.faceCount) {
                    for _ in 0..<Int(fmesh.faceTriCount[f]) {
                        faceOfTriangle.append(f)
                    }
                }
            }
            if faceOfTriangle.count != tcount {
                // Ranges incomplete — report none rather than a
                // partial map (rebuild then offers no snapshot).
                faceOfTriangle = []
            }
            return (Mesh(vertices: vertices, indices: indices), faceOfTriangle)
        }
    }

    /// The exact sketch plane of a planar census face (façade
    /// `mc_face_plane`). A non-planar face is refused by the
    /// façade and surfaces here as KN602 with its plain words.
    func facePlane(_ s: Int, index: Int) throws -> Plane3 {
        try locked {
            var err: Int32 = 0
            var origin = [Double](repeating: 0, count: 3)
            var xDir = [Double](repeating: 0, count: 3)
            var yDir = [Double](repeating: 0, count: 3)
            guard mc_face_plane(try shape(s), Int32(index), &origin, &xDir, &yDir, &err) == MC_OK.rawValue else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            return Plane3(origin: Vec3(origin[0], origin[1], origin[2]),
                          xAxis: Vec3(xDir[0], xDir[1], xDir[2]),
                          yAxis: Vec3(yDir[0], yDir[1], yDir[2]))
        }
    }

    func exportSTEP(_ s: Int, path: String) throws {
        try locked {
            var err: Int32 = 0
            let rc = mc_export_step(try shape(s), path, &err)
            guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
                throw CADError.stepWriteFailed(Self.lastError())
            }
        }
    }

    func importSTEP(path: String) throws -> (handle: Int, solidCount: Int) {
        try locked {
            var err: Int32 = 0
            var solids: Int32 = 0
            let h = mc_import_step(path, &solids, &err)
            guard let h else {
                // The reader rejected the file (or found no shape
                // in it): an import failure, MCAD-IO702 — not a
                // kernel refusal.
                throw CADError.importFileUnreadable(Self.lastError())
            }
            return (try own(h), Int(solids))
        }
    }

    /// Multi-body STEP export (façade `mc_export_step_bodies`):
    /// all bodies into one file as a compound of solids. Write
    /// failures surface as MCAD-IO706 (the reserved STEP code),
    /// not KN602.
    func exportSTEPBodies(_ ids: [Int], path: String) throws {
        try locked {
            // Optional elements: the façade's `const *const *`
            // imports with a nullable inner pointer.
            let handles: [UnsafeMutablePointer<MCFacadeShape>?] = try ids.map { try shape($0) }
            var err: Int32 = 0
            let rc = mc_export_step_bodies(handles, Int32(ids.count), path, &err)
            guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
                throw CADError.stepWriteFailed(Self.lastError())
            }
        }
    }

    /// XDE STEP export (façade `mc_export_step_xde`): every solid
    /// carries its body's colour (the part material colour) and
    /// the document is labelled with the part name.
    func exportSTEPXDE(_ ids: [Int], colors: [CensusFaceColor], name: String, path: String) throws {
        try locked {
            let handles: [UnsafeMutablePointer<MCFacadeShape>?] = try ids.map { try shape($0) }
            var rgb: [Double] = []
            for c in colors { rgb += [c.red, c.green, c.blue] }
            var err: Int32 = 0
            let rc = mc_export_step_xde(handles, Int32(ids.count), rgb, name, path, &err)
            guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
                throw CADError.stepWriteFailed(Self.lastError())
            }
        }
    }

    /// Per-face STEP colours of a shape in census order (façade
    /// `mc_shape_face_colors`). Only import handles carry colours;
    /// anything else returns all-`hasColor == false`.
    func faceColors(_ s: Int) throws -> [CensusFaceColor] {
        try locked {
            let h = try shape(s)
            var faces: Int32 = 0
            var err: Int32 = 0
            guard mc_shape_counts(h, &faces, nil, nil, &err) == MC_OK.rawValue, faces > 0 else {
                return []
            }
            var rgb = [Double](repeating: 0, count: 3 * Int(faces))
            var has = [Int32](repeating: 0, count: Int(faces))
            let rc = mc_shape_face_colors(h, &rgb, &has, &err)
            guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            return (0..<Int(faces)).map { i in
                CensusFaceColor(red: rgb[3 * i], green: rgb[3 * i + 1], blue: rgb[3 * i + 2],
                                hasColor: has[i] != 0)
            }
        }
    }

    // MARK: Sketch -> faces (the device-proven conversion)

    /// One OCCT face handle per closed sketch profile (outer with
    /// its holes), in profile order. Ported from the CascadeDemo
    /// engine, where this exact conversion is verified on-device.
    /// Caller owns the returned handles.
    private func makeFaces(sketch: Sketch) throws -> [UnsafeMutablePointer<MCFacadeShape>] {
        let profiles: [Profile]
        do {
            profiles = try sketch.extractProfiles().profiles
        } catch let e as CADError {
            throw e
        }
        guard !profiles.isEmpty else { throw CADError.padNoProfile }

        // Group the non-construction entities into loops by
        // CHAINING — the same sewing discipline as extractProfiles:
        // a circle is a loop by itself; lines and arcs chain
        // end-to-end at the sketch sewing tolerance, nearest
        // attachment first. Chaining (not mere endpoint proximity)
        // keeps two loops that pass near each other in separate
        // groups, and yields each loop's entities IN ORDER with
        // their traversal direction, which the welded serialization
        // below relies on. Points and construction geometry never
        // bound a profile (extractProfiles ignores them too).
        struct Link {
            var entity: SketchEntity
            var flipped: Bool
            // Mutable weld state: a line's stored endpoints, an
            // arc's centre (its angles never change — a weld shifts
            // the whole circle, both endpoints together).
            var lineA: Vec2 = .zero
            var lineB: Vec2 = .zero
            var arcCenter: Vec2 = .zero
            var isLine: Bool { if case .line = entity { return true }; return false }
            var isArc: Bool { if case .arc = entity { return true }; return false }
            var entry: Vec2 {
                switch entity {
                case .line: return flipped ? lineB : lineA
                case .arc(_, _, let r, let a0, let a1, _):
                    let a = flipped ? a1 : a0
                    return arcCenter + Vec2(cos(a), sin(a)) * r
                default: return .zero
                }
            }
            var exit: Vec2 {
                switch entity {
                case .line: return flipped ? lineA : lineB
                case .arc(_, _, let r, let a0, let a1, _):
                    let a = flipped ? a0 : a1
                    return arcCenter + Vec2(cos(a), sin(a)) * r
                default: return .zero
                }
            }
            mutating func setEntry(_ p: Vec2) {  // lines only
                if flipped { lineB = p } else { lineA = p }
            }
            mutating func setExit(_ p: Vec2) {   // lines only
                if flipped { lineA = p } else { lineB = p }
            }
        }
        func makeLink(_ e: SketchEntity, flipped: Bool) -> Link {
            var link = Link(entity: e, flipped: flipped)
            switch e {
            case .line(_, let a, let b, _): link.lineA = a; link.lineB = b
            case .arc(_, let c, _, _, _, _): link.arcCenter = c
            default: break
            }
            return link
        }
        var groups: [[Link]] = []
        var rest: [SketchEntity] = []
        for e in sketch.entities where !e.isConstruction {
            switch e {
            case .circle: groups.append([makeLink(e, flipped: false)])
            case .line, .arc: rest.append(e)
            case .point: break
            }
        }
        while !rest.isEmpty {
            let first = rest.removeFirst()
            let fe = endpoints(of: first)
            var group = [makeLink(first, flipped: false)]
            var head = fe[0], tail = fe[1]
            while true {
                var best: (idx: Int, dist: Double, flipped: Bool, atHead: Bool)? = nil
                for (i, e) in rest.enumerated() {
                    let ep = endpoints(of: e)
                    let d0 = ep[0].distance(to: tail)
                    if d0 <= Sketch.sewTolerance, best == nil || d0 < best!.dist { best = (i, d0, false, false) }
                    let d1 = ep[1].distance(to: tail)
                    if d1 <= Sketch.sewTolerance, best == nil || d1 < best!.dist { best = (i, d1, true, false) }
                    let h0 = ep[0].distance(to: head)
                    if h0 <= Sketch.sewTolerance, best == nil || h0 < best!.dist { best = (i, h0, true, true) }
                    let h1 = ep[1].distance(to: head)
                    if h1 <= Sketch.sewTolerance, best == nil || h1 < best!.dist { best = (i, h1, false, true) }
                }
                guard let b = best else { break }
                let e = rest.remove(at: b.idx)
                let ep = endpoints(of: e)
                if b.atHead {
                    group.insert(makeLink(e, flipped: b.flipped), at: 0)
                    head = b.flipped ? ep[1] : ep[0]
                } else {
                    group.append(makeLink(e, flipped: b.flipped))
                    tail = b.flipped ? ep[0] : ep[1]
                }
            }
            groups.append(group)
        }

        // Assign each group to the kit profile loop (outer or hole)
        // it actually traces. The kit loops are the same entities'
        // flattened (and sewn) polylines, so a group's own flattened
        // curve lies on its kit loop (within the sewing tolerance at
        // welded joints, ~sagitta elsewhere). Matching is therefore
        // scored over the WHOLE curve — the worst distance from any
        // point of the group's polyline to the kit loop's polyline —
        // and assigned best-first, exclusively: each group claims
        // exactly one loop, each loop is claimed by exactly one
        // group.
        //
        // (1.24 device failure, 2026-10-29: the previous matcher
        // used ONE sample point per group — a circle contributed
        // only its angle-0 point — and took the FIRST loop within
        // sewTolerance. A hole circle whose wall to its outer was
        // <= 0.5 mm matched the OUTER loop first, so both circles
        // were serialized into one profile range and the façade
        // refused it: "a circle entity must be the only entity of
        // its profile" (KN602). Identical duplicate circles
        // collapsed the same way. Whole-curve scoring separates
        // them: the true loop scores ~0, a neighbour 0.3 mm away
        // scores 0.3.)
        struct KitLoop { var profile: Int; var isHole: Bool; var points: [Vec2] }
        var kitLoops: [KitLoop] = []
        for (i, p) in profiles.enumerated() {
            kitLoops.append(KitLoop(profile: i, isHole: false, points: p.outer))
            for h in p.holes { kitLoops.append(KitLoop(profile: i, isHole: true, points: h)) }
        }
        func loopScore(_ group: [Link], _ loopPoints: [Vec2]) -> Double {
            var worst = 0.0
            for link in group {
                for s in link.entity.polyline(sagitta: 0.02) {
                    var best = Double.greatestFiniteMagnitude
                    for p in loopPoints { best = min(best, s.distance(to: p)) }
                    if best > worst { worst = best }
                }
            }
            return worst
        }
        var candidates: [(score: Double, group: Int, loop: Int)] = []
        for (gi, group) in groups.enumerated() {
            for (li, kl) in kitLoops.enumerated() {
                let sc = loopScore(group, kl.points)
                if sc <= Sketch.sewTolerance { candidates.append((sc, gi, li)) }
            }
        }
        candidates.sort { $0.score < $1.score }
        var groupLoop: [Int: Int] = [:]
        var loopGroup: [Int: Int] = [:]
        for c in candidates where groupLoop[c.group] == nil && loopGroup[c.loop] == nil {
            groupLoop[c.group] = c.loop
            loopGroup[c.loop] = c.group
        }
        var outers: [Int: [Link]] = [:]
        var holes: [Int: [[Link]]] = [:]
        for (gi, group) in groups.enumerated() {
            guard let li = groupLoop[gi] else {
                // No kit loop claims this group: the kit's own
                // disposition dropped these entities from every
                // profile (a lone decoration line, an open chain).
                // They bound no profile — skip them, exactly as
                // extractProfiles did, instead of failing the whole
                // feature on geometry the kit already judged.
                continue
            }
            let loop = kitLoops[li]
            if loop.isHole {
                holes[loop.profile, default: []].append(group)
            } else {
                outers[loop.profile] = group
            }
        }

        // Serialize one chained loop with BIT-EXACT joints: the
        // façade chains wire edges at 1e-6, so a sewn joint must
        // arrive exact. Lines flex — either endpoint can be
        // rewritten to the joint. An arc's endpoints are pinned to
        // its circle, so at a line–arc joint the line is rewritten
        // to the arc's stored endpoint. At an arc–arc joint (not
        // producible from the sketch editor — its arcs are born in
        // slots, between lines) the later arc's centre shifts by
        // the residual, landing its entry exactly on the joint.
        func serializeLoop(_ group: [Link], types: inout [Int32], data: inout [Double]) {
            guard group.count > 1 else {
                if let e = group.first?.entity { appendEntity(e, types: &types, data: &data) }
                return
            }
            var links = group
            var joint = links[0].exit
            for i in 1..<links.count {
                let target = links[i].entry
                if target.distance(to: joint) > 1e-9 {
                    if links[i].isLine {
                        links[i].setEntry(joint)
                    } else if links[i].isArc && links[i - 1].isLine {
                        links[i - 1].setExit(target)
                    } else if links[i].isArc {
                        links[i].arcCenter = links[i].arcCenter + (joint - target)
                    }
                }
                joint = links[i].exit
            }
            let anchor = links[0].entry
            if joint.distance(to: anchor) > 1e-9 {
                if links[0].isLine {
                    links[0].setEntry(joint)
                } else if links[links.count - 1].isLine {
                    links[links.count - 1].setExit(anchor)
                } else {
                    links[0].arcCenter = links[0].arcCenter + (joint - anchor)
                }
            }
            for link in links {
                switch link.entity {
                case .line(let id, _, _, let cons):
                    appendEntity(.line(id: id, a: link.lineA, b: link.lineB, construction: cons),
                                 types: &types, data: &data)
                case .arc(let id, _, let r, let a0, let a1, let cons):
                    appendEntity(.arc(id: id, center: link.arcCenter, radius: r,
                                      startAngle: a0, endAngle: a1, construction: cons),
                                 types: &types, data: &data)
                case .circle(let id, let c, let r, let cons):
                    appendEntity(.circle(id: id, center: c, radius: r, construction: cons),
                                 types: &types, data: &data)
                case .point:
                    break
                }
            }
        }

        let plane = sketch.plane
        var err: Int32 = 0
        let origin: [Double] = [plane.origin.x, plane.origin.y, plane.origin.z]
        let normal: [Double] = [plane.normal.x, plane.normal.y, plane.normal.z]
        let xDir: [Double] = [plane.xAxis.x, plane.xAxis.y, plane.xAxis.z]
        var faces: [UnsafeMutablePointer<MCFacadeShape>] = []
        for i in profiles.indices {
            guard let outer = outers[i], !outer.isEmpty else {
                faces.forEach { mc_free_shape($0) }
                throw CADError.kernelOperationFailed("A closed profile had no matching sketch lines.")
            }
            var types: [Int32] = []
            var data: [Double] = []
            var starts: [Int32] = [0]
            serializeLoop(outer, types: &types, data: &data)
            starts.append(Int32(types.count))
            for hole in holes[i] ?? [] {
                serializeLoop(hole, types: &types, data: &data)
                starts.append(Int32(types.count))
            }
            if ProcessInfo.processInfo.environment["MC_DEBUG_WIRE"] != nil {
                print("WIRE types=\(types) starts=\(starts) origin=\(origin) normal=\(normal) xDir=\(xDir)")
                print("WIRE data=\(data)")
            }
            guard let face = mc_face_from_sketch(origin, normal, xDir,
                                                 types, data, Int32(types.count),
                                                 starts, Int32(starts.count - 1), &err) else {
                faces.forEach { mc_free_shape($0) }
                throw CADError.kernelOperationFailed(Self.lastError())
            }
            faces.append(face)
        }
        return faces
    }

    private func endpoints(of e: SketchEntity) -> [Vec2] {
        switch e {
        case .line(_, let a, let b, _): return [a, b]
        case .arc: return [e.resolve(.start), e.resolve(.end)].compactMap { $0 }
        default: return []
        }
    }

    /// One sketch entity -> one façade entity (6-double stride):
    /// line = type 0 (x1,y1,x2,y2), circle = type 1 (cx,cy,r),
    /// arc = type 2 (cx,cy,r,start,end radians CCW).
    private func appendEntity(_ e: SketchEntity, types: inout [Int32], data: inout [Double]) {
        switch e {
        case .line(_, let a, let b, _):
            types.append(0); data += [a.x, a.y, b.x, b.y, 0, 0]
        case .circle(_, let c, let r, _):
            types.append(1); data += [c.x, c.y, r, 0, 0, 0]
        case .arc(_, let c, let r, let a0, let a1, _):
            types.append(2); data += [c.x, c.y, r, a0, a1, 0]
        case .point:
            break
        }
    }
}
