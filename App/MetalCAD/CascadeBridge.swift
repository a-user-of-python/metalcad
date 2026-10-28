import Foundation

/// The Cascade implant (2026-10-28): Open CASCADE (OCCT 8.0.1)
/// linked into MetalCAD as the CascadeKit static library, reached
/// through the thin C façade (`occt_facade.h`, bridging header).
///
/// Division of labour, as everywhere in this project: Swift drives,
/// Cascade computes. The kit stays pure Swift — at launch the app
/// registers `DocumentEngine.cascadePadEvaluator`, and every
/// `.cascadePad` feature in a document is then built by OCCT:
/// sketch → face (`mc_face_from_sketch`) → prism (`mc_prism_face`),
/// measured with `mc_volume`, tessellated with `mc_tessellate` and
/// handed back as a kit `Mesh` for the normal render path.
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

    /// Called once from the app entry point.
    static func register() {
        DocumentEngine.cascadePadEvaluator = { sketch, length in
            try evaluate(sketch: sketch, length: length)
        }
        MCLog.shared.info(.kernel, "Cascade (OCCT) evaluator registered",
                          context: ["occt": String(cString: mc_occt_version())])
    }

    /// The app rebuilds on the main thread AND a background draft
    /// queue; the façade keeps a global last-error string, so all
    /// bridge calls are serialised through this lock.
    private static let gate = NSLock()

    /// Build one cascade pad: the sketch's closed profiles extruded
    /// `length` mm along the sketch plane normal, entirely by OCCT.
    /// Returns the tessellation (kit mesh) and OCCT's own volume.
    static func evaluate(sketch: Sketch, length: Double) throws -> (mesh: Mesh, volume: Double) {
        gate.lock()
        defer { gate.unlock() }
        let solid = try buildSolid(sketch: sketch, length: length)
        defer { mc_free_shape(solid) }

        var err: Int32 = 0
        let volume = mc_volume(solid, &err)
        guard err == MC_OK.rawValue else {
            throw CADError.kernelOperationFailed(lastError())
        }

        var fmesh = MCFacadeMesh()
        let rc = mc_tessellate(solid, 0.1, &fmesh, &err)
        guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
            throw CADError.kernelTessellationFailed(lastError())
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
        return (Mesh(vertices: vertices, indices: indices), volume)
    }

    private static func lastError() -> String {
        String(cString: mc_last_error())
    }

    /// Sketch → OCCT solid handle (caller owns it). Ported from the
    /// CascadeDemo engine, where this exact conversion is verified
    /// on-device; the only change is the prism distance arriving as
    /// the feature's `length` instead of the demo's fixed 10 mm.
    private static func buildSolid(sketch: Sketch, length: Double) throws -> UnsafeMutablePointer<MCFacadeShape> {
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
        var result: UnsafeMutablePointer<MCFacadeShape>?
        for i in profiles.indices {
            guard let outer = outers[i], !outer.isEmpty else {
                if let r = result { mc_free_shape(r) }
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
                if let r = result { mc_free_shape(r) }
                throw CADError.kernelOperationFailed(lastError())
            }
            let solid = mc_prism_face(face, normal, length, &err)
            mc_free_shape(face)
            guard let solid else {
                if let r = result { mc_free_shape(r) }
                throw CADError.kernelOperationFailed(lastError())
            }
            if let r = result {
                let united = mc_unite(r, solid, &err)
                mc_free_shape(r)
                mc_free_shape(solid)
                guard let united else { throw CADError.kernelOperationFailed(lastError()) }
                result = united
            } else {
                result = solid
            }
        }
        guard let final = result else {
            throw CADError.kernelOperationFailed("Nothing to extrude.")
        }
        return final
    }

    private static func endpoints(of e: SketchEntity) -> [Vec2] {
        switch e {
        case .line(_, let a, let b, _): return [a, b]
        case .arc: return [e.resolve(.start), e.resolve(.end)].compactMap { $0 }
        default: return []
        }
    }

    private static func samplePoints(of group: [SketchEntity]) -> [Vec2] {
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
    private static func appendEntity(_ e: SketchEntity, types: inout [Int32], data: inout [Double]) {
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
