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
            return Mesh(vertices: vertices, indices: indices)
        }
    }

    func exportSTEP(_ s: Int, path: String) throws {
        try locked {
            var err: Int32 = 0
            let rc = mc_export_step(try shape(s), path, &err)
            guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
                throw CADError.kernelOperationFailed(Self.lastError())
            }
        }
    }

    func importSTEP(path: String) throws -> Int {
        try locked {
            var err: Int32 = 0
            var solids: Int32 = 0
            return try own(mc_import_step(path, &solids, &err))
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

        // Group the non-construction entities into loops: a circle
        // is a loop by itself; lines and arcs group by shared
        // endpoints. Points and construction geometry never bound a
        // profile (extractProfiles ignores them too).
        var groups: [[SketchEntity]] = []
        var chained: [SketchEntity] = []
        for e in sketch.entities where !e.isConstruction {
            switch e {
            case .circle: groups.append([e])
            case .line, .arc: chained.append(e)
            case .point: break
            }
        }
        var rest = chained
        while !rest.isEmpty {
            var group = [rest.removeFirst()]
            var grew = true
            while grew {
                grew = false
                let ends = group.flatMap { endpoints(of: $0) }
                var i = 0
                while i < rest.count {
                    let other = endpoints(of: rest[i])
                    if ends.contains(where: { a in other.contains { $0.distance(to: a) <= 1e-6 } }) {
                        group.append(rest.remove(at: i))
                        grew = true
                    } else {
                        i += 1
                    }
                }
            }
            groups.append(group)
        }

        // Assign each group to a kit profile loop (outer or hole) by
        // matching a group vertex against the loop's points — the
        // kit loops are the same entities' flattened polylines, so
        // entity endpoints appear in them exactly.
        struct KitLoop { var profile: Int; var isHole: Bool; var points: [Vec2] }
        var kitLoops: [KitLoop] = []
        for (i, p) in profiles.enumerated() {
            kitLoops.append(KitLoop(profile: i, isHole: false, points: p.outer))
            for h in p.holes { kitLoops.append(KitLoop(profile: i, isHole: true, points: h)) }
        }
        var outers: [Int: [SketchEntity]] = [:]
        var holes: [Int: [[SketchEntity]]] = [:]
        for group in groups {
            let samples = samplePoints(of: group)
            guard let loop = kitLoops.first(where: { kl in
                kl.points.contains { p in samples.contains { $0.distance(to: p) <= 1e-4 } }
            }) else {
                throw CADError.kernelOperationFailed("One outline couldn't be matched to a closed profile. Check for gaps or duplicate lines.")
            }
            if loop.isHole {
                holes[loop.profile, default: []].append(group)
            } else {
                outers[loop.profile, default: []].append(contentsOf: group)
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
            for e in outer { appendEntity(e, types: &types, data: &data) }
            starts.append(Int32(types.count))
            for hole in holes[i] ?? [] {
                for e in hole { appendEntity(e, types: &types, data: &data) }
                starts.append(Int32(types.count))
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

    private func samplePoints(of group: [SketchEntity]) -> [Vec2] {
        var pts: [Vec2] = []
        for e in group {
            pts += endpoints(of: e)
            if case .circle(_, let c, let r, _) = e { pts.append(c + Vec2(r, 0)) }
        }
        return pts
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
