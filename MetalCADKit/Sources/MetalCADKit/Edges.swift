import Foundation

/// A straight edge where two planar faces of a solid meet — the unit that
/// fillet and chamfer operate on (like a real CAD kernel's edges).
public struct SolidEdge {
    public var start: Vec3
    public var end: Vec3
    public var isConvex: Bool
    public var faceA: PlanarFace
    public var faceB: PlanarFace
    /// Centroids of the two mesh triangles adjacent to this edge — the
    /// LOCAL geometry. Face centroids lie (frames with holes put the
    /// centroid across the void, which flips both the surface direction
    /// and the convex/concave call; the adjacent triangles never lie.
    public var triA: Vec3
    public var triB: Vec3
    public var length: Double { start.distance(to: end) }
    public var mid: Vec3 { (start + end) * 0.5 }
    public var direction: Vec3 { (end - start).normalized }
}

public enum SolidEdgeExtractor {
    /// All sharp edges between distinct planar faces. Boundary segments
    /// shared by the same face pair are chained into maximal straight runs.
    public static func edges(of meshIn: Mesh, sharpAngleDegrees: Double = 25) -> [SolidEdge] {
        let (faces, faceTris, mesh) = FaceExtractor.groupedFaces(of: meshIn, minArea: 0)
        guard !faces.isEmpty else { return [] }
        // Triangle -> face index.
        var triFace: [Int: Int] = [:]
        for (fi, tris) in faceTris.enumerated() { for t in tris { triFace[t] = fi } }
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            (UInt64(max(a, b)) << 32) | UInt64(min(a, b))
        }
        // Mesh edge -> faces on each side, with each side's triangle.
        var segments: [(UInt32, UInt32, Int, Int, Vec3, Vec3)] = []
        var seen: [UInt64: (Int, Int)] = [:]  // edge -> (tri, face) first seen
        func triCentroid(_ t: Int) -> Vec3 {
            (mesh.vertices[Int(mesh.indices[t * 3])] + mesh.vertices[Int(mesh.indices[t * 3 + 1])]
                + mesh.vertices[Int(mesh.indices[t * 3 + 2])]) * (1.0 / 3.0)
        }
        for t in 0..<mesh.triangleCount {
            guard let f = triFace[t] else { continue }
            for k in 0..<3 {
                let a = mesh.indices[t * 3 + k], b = mesh.indices[t * 3 + (k + 1) % 3]
                let kk = key(a, b)
                if let (t0, f0) = seen[kk] {
                    if f0 != f {
                        segments.append((a, b, f0, f, triCentroid(t0), triCentroid(t)))
                    }
                } else {
                    seen[kk] = (t, f)
                }
            }
        }
        let cosSharp = cos(sharpAngleDegrees * .pi / 180)
        // Group segments by face pair, chain collinear runs.
        var byPair: [String: [(UInt32, UInt32, Vec3, Vec3)]] = [:]
        var pairFaces: [String: (Int, Int)] = [:]
        for (a, b, fa, fb, ca, cb) in segments {
            let na = faces[fa].plane.normal, nb = faces[fb].plane.normal
            if na.dot(nb) > cosSharp { continue }  // not sharp
            let lo = min(fa, fb), hi = max(fa, fb)
            let pk = "\(lo)-\(hi)"
            // Keep triangle centroids aligned with the lo/hi face order.
            byPair[pk, default: []].append(fa == lo ? (a, b, ca, cb) : (a, b, cb, ca))
            pairFaces[pk] = (lo, hi)
        }
        var result: [SolidEdge] = []
        for (pk, segs) in byPair {
            let (fa, fb) = pairFaces[pk]!
            let triA = segs[0].2, triB = segs[0].3
            // Chain segments into runs.
            var pool = segs.map { ($0.0, $0.1) }
            while !pool.isEmpty {
                var run: [UInt32] = [pool[0].0, pool[0].1]
                pool.removeFirst()
                var grew = true
                while grew {
                    grew = false
                    for i in pool.indices {
                        let (a, b) = pool[i]
                        let head = run.first!, tail = run.last!
                        func collinear(_ p: Vec3, _ q: Vec3, _ r: Vec3) -> Bool {
                            let d1 = (q - p).normalized, d2 = (r - q).normalized
                            return d1.dot(d2) > 0.9994  // within ~2 degrees
                        }
                        if a == tail && collinear(mesh.vertices[Int(run[run.count - 2])], mesh.vertices[Int(tail)], mesh.vertices[Int(b)]) {
                            run.append(b); pool.remove(at: i); grew = true; break
                        }
                        if b == tail && collinear(mesh.vertices[Int(run[run.count - 2])], mesh.vertices[Int(tail)], mesh.vertices[Int(a)]) {
                            run.append(a); pool.remove(at: i); grew = true; break
                        }
                        if b == head && collinear(mesh.vertices[Int(a)], mesh.vertices[Int(head)], mesh.vertices[Int(run[1])]) {
                            run.insert(a, at: 0); pool.remove(at: i); grew = true; break
                        }
                        if a == head && collinear(mesh.vertices[Int(b)], mesh.vertices[Int(head)], mesh.vertices[Int(run[1])]) {
                            run.insert(b, at: 0); pool.remove(at: i); grew = true; break
                        }
                    }
                }
                let start = mesh.vertices[Int(run.first!)]
                let end = mesh.vertices[Int(run.last!)]
                if start.distance(to: end) < 1e-9 { continue }
                // Convexity from the LOCAL triangles: both adjacent
                // triangles on the inner side of the other face's plane
                // means the edge bulges out of the material (convex).
                let fA = faces[fa], fB = faces[fb]
                let dA = fA.plane.normal.dot(triB - triA)
                let dB = fB.plane.normal.dot(triA - triB)
                let convex = (dA + dB) < 0
                result.append(SolidEdge(start: start, end: end, isConvex: convex, faceA: fA, faceB: fB, triA: triA, triB: triB))
            }
        }
        // Deterministic order (dictionary iteration above is not) so CSG
        // sequences — and therefore results — are reproducible run to run.
        return result.sorted {
            ($0.start.x, $0.start.y, $0.start.z, $0.end.x, $0.end.y, $0.end.z)
                < ($1.start.x, $1.start.y, $1.start.z, $1.end.x, $1.end.y, $1.end.z)
        }
    }
}

/// Fillet, chamfer and shell built on CSG edge cutters. Straight edges
/// between planar faces are finished exactly in cross-section; the cutter
/// prisms are unioned and cut (or added) in one boolean.
public enum EdgeFinisher {

    struct Section {
        var u: Vec3, v: Vec3, w: Vec3  // section frame at edge mid; w = edge dir
        var origin: Vec3               // edge mid
        var s2: Vec2                   // face B surface direction in 2D
        var pin: Vec2                  // interior direction in 2D
        var valid: Bool
    }

    static func section(for edge: SolidEdge) -> Section {
        let w = edge.direction
        let m = edge.mid
        func surfDir(_ triCentroid: Vec3) -> Vec3? {
            var d = triCentroid - m
            d = d - w * d.dot(w)
            return d.length > 1e-9 ? d.normalized : nil
        }
        guard let s1 = surfDir(edge.triA), var s2v = surfDir(edge.triB) else {
            return Section(u: .zero, v: .zero, w: w, origin: m, s2: .zero, pin: .zero, valid: false)
        }
        _ = s2v
        let u = s1
        var v = w.cross(u).normalized
        var s2 = Vec2(s2v.dot(u), s2v.dot(v))
        if s2.y < 0 {  // keep s2 in the upper half-plane
            v = v * -1
            s2 = Vec2(s2.x, -s2.y)
        }
        let nSum = edge.faceA.plane.normal + edge.faceB.plane.normal
        let pin = Vec2(-nSum.dot(u), -nSum.dot(v))
        return Section(u: u, v: v, w: w, origin: m, s2: s2, pin: pin, valid: s2.y > 0.05 && pin.length > 1e-6)
    }

    static func to3D(_ sec: Section, _ p: Vec2, along: Double) -> Vec3 {
        sec.origin + sec.u * p.x + sec.v * p.y + sec.w * along
    }

    /// Point-in-face test at a 3D location against a face's outline.
    /// The query is nudged a hair toward the face centroid so points lying
    /// exactly on the outline (tangent points at an edge's end) count as in.
    static func insideFace(_ face: PlanarFace, _ p: Vec3) -> Bool {
        let d = p - face.plane.origin
        let q = Vec2(d.dot(face.plane.xAxis), d.dot(face.plane.yAxis)) * (1 - 1e-6)
        return pointInPolygon(q, face.outline2D)
    }

    /// Tangent/offset points for an edge treatment.
    /// mode: fillet (arc) or chamfer (flat). Returns the 2D region polygon
    /// (section coords) to extrude along the edge, or throws the coded error.
    static func region(edge: SolidEdge, value: Double, isFillet: Bool, valueB: Double = -1) throws -> [Vec2] {
        let sec = section(for: edge)
        guard sec.valid else {
            throw isFillet ? CADError.filletFailed("edge is not between two usable faces")
                           : CADError.chamferInvalid("edge is not between two usable faces")
        }
        func cross2(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.y - a.y * b.x }
        let s1 = Vec2(1, 0), s2 = sec.s2
        let O = Vec2.zero
        let tA: Vec2, tB: Vec2
        var arc: [Vec2] = []
        var arcCenter: Vec2? = nil
        if isFillet {
            // Solve for the arc center at signed distance value from both
            // face lines: material side for convex, void side for concave.
            let sideA = cross2(s1, sec.pin) >= 0 ? 1.0 : -1.0
            let sideB = cross2(s2, sec.pin) >= 0 ? 1.0 : -1.0
            let sign = edge.isConvex ? 1.0 : -1.0
            let r1 = sign * sideA * value
            let r2 = sign * sideB * value
            // Cramer: cross2(s1, C) = r1 ; cross2(s2, C) = r2
            let det = cross2(s1, s2)
            guard abs(det) > 1e-9 else { throw CADError.filletFailed("faces are parallel at this edge") }
            // Solve [-s1.y  s1.x ; -s2.y  s2.x] * C = [r1 ; r2] (Cramer).
            let a11 = -s1.y, a12 = s1.x, a21 = -s2.y, a22 = s2.x
            let d2 = a11 * a22 - a12 * a21
            let C = Vec2((r1 * a22 - a12 * r2) / d2, (a11 * r2 - r1 * a21) / d2)
            arcCenter = C
            func perp(_ a: Vec2) -> Vec2 { Vec2(-a.y, a.x) }
            let TA = C - perp(s1) * cross2(s1, C)
            let TB = C - perp(s2) * cross2(s2, C)
            tA = TA; tB = TB
            // Arc from TA to TB passing closest to the corner O.
            let aA = atan2(TA.y - C.y, TA.x - C.x)
            let aB = atan2(TB.y - C.y, TB.x - C.x)
            func arcPoints(_ from: Double, _ to: Double, _ cw: Bool) -> [Vec2] {
                var sweep = to - from
                if cw { while sweep > 0 { sweep -= 2 * Double.pi } } else { while sweep < 0 { sweep += 2 * Double.pi } }
                let steps = max(3, Int(abs(sweep) / (Double.pi / 12)))
                return (0...steps).map { i in
                    let a = from + sweep * Double(i) / Double(steps)
                    return C + Vec2(cos(a), sin(a)) * value
                }
            }
            let ccw = arcPoints(aA, aB, false)
            let cw = arcPoints(aA, aB, true)
            func midDist(_ pts: [Vec2]) -> Double { pts[pts.count / 2].distance(to: O) }
            arc = midDist(ccw) <= midDist(cw) ? ccw : cw
        } else {
            tA = s1 * value
            tB = s2 * (valueB >= 0 ? valueB : value)
        }
        // Validate tangent points sit on their faces (mid + both ends),
        // and that the treatment's strip fits the face: the face outline
        // offset inward by the strip width must survive (catches radii
        // whose fillets from opposite edges would meet or cross).
        for (t, face, other) in [(tA, edge.faceA, edge.faceB), (tB, edge.faceB, edge.faceA)] {
            _ = other
            for along in [-edge.length / 2, 0.0, edge.length / 2] {
                let p = to3D(sec, t, along: along)
                if !face.outline2D.isEmpty && !insideFace(face, p) {
                    throw isFillet ? CADError.filletRadiusTooLarge(requested: value, maxFeasible: 0)
                                   : CADError.chamferInvalid("distance \(value) runs off a face")
                }
            }
            if !face.outline2D.isEmpty && Tessellation.offsetPolygon(face.outline2D, by: -t.length) == nil {
                throw isFillet ? CADError.filletRadiusTooLarge(requested: value, maxFeasible: 0)
                               : CADError.chamferInvalid("distance \(value) is too large for a face")
            }
        }
        if isFillet {
            return edge.isConvex ? [O, tA] + arc.dropFirst().dropLast() + [tB]
                                 : [tA, O, tB] + arc.dropFirst().dropLast().reversed()
        }
        return [O, tA, tB]
    }

    /// Extrude a 2D section polygon along the edge into a prism mesh.
    static func prism(edge: SolidEdge, region: [Vec2], overshoot: Double) -> Mesh {
        let sec = section(for: edge)
        let half = edge.length / 2 + overshoot
        let a = region.map { to3D(sec, $0, along: -half) }
        let b = region.map { to3D(sec, $0, along: half) }
        var builder = MeshBuilder()
        let centroidA = a.reduce(Vec3.zero) { $0 + $1 } * (1.0 / Double(a.count))
        let centroidB = b.reduce(Vec3.zero) { $0 + $1 } * (1.0 / Double(b.count))
        let ca = builder.vertex(centroidA), cb = builder.vertex(centroidB)
        let av = a.map { builder.vertex($0) }
        let bv = b.map { builder.vertex($0) }
        for i in region.indices {
            let j = (i + 1) % region.count
            builder.triangle(ca, av[j], av[i])
            builder.triangle(cb, bv[i], bv[j])
            builder.quad(av[i], av[j], bv[j], bv[i])
        }
        var mesh = builder.mesh
        if mesh.signedVolume < 0 {  // restore outward winding
            var idx: [UInt32] = []
            for t in 0..<mesh.triangleCount {
                idx += [mesh.indices[t * 3], mesh.indices[t * 3 + 2], mesh.indices[t * 3 + 1]]
            }
            mesh = Mesh(vertices: mesh.vertices, indices: idx)
        }
        return mesh
    }

    static func unionAll(_ meshes: [Mesh]) throws -> Mesh {
        var out = Mesh()
        for m in meshes { out = out.triangleCount == 0 ? m : try CSG.union(out, m) }
        return out
    }

    static func finish(body: Mesh, value: Double, isFillet: Bool, valueB: Double = -1,
                       onlyMidpoints: [Vec3]? = nil) throws -> Mesh {
        guard value > 0 else {
            throw isFillet ? CADError.filletFailed("radius must be > 0")
                           : CADError.chamferInvalid("distance must be > 0")
        }
        // valueB == 0 is NOT the unset sentinel (-1 is): a zero second
        // distance collapses the section region to a degenerate
        // polygon whose prism made CSG subtract the ENTIRE body —
        // chamfer2(2, 0) returned an empty mesh as success
        // (2026-10-26 sweep). Sub-1e-9 values are the same class
        // (distanceAngle at 90° produces ~1e-16).
        guard valueB < 0 || valueB >= 1e-9 else {
            throw CADError.chamferInvalid("second distance must be > 0")
        }
        let vmax = max(value, valueB)
        let allEdges = SolidEdgeExtractor.edges(of: body).filter { $0.length >= 0.5 }
        // Skip edges touching a face too small to hold the treatment —
        // CSG output can carry sliver faces that no real edge finish
        // could ever land on.
        var edges = allEdges.filter { min($0.faceA.area, $0.faceB.area) >= vmax * vmax }
        if let targets = onlyMidpoints {
            edges = edges.filter { e in targets.contains { $0.distance(to: e.mid) < 0.05 } }
            guard !edges.isEmpty else {
                throw isFillet ? CADError.filletFailed("the picked edge is gone — the part changed above it")
                               : CADError.chamferInvalid("the picked edge is gone — the part changed above it")
            }
        } else if edges.isEmpty {
            // Silent no-op guard (2026-10-26 sweep): with no picked
            // edges, an empty working set used to sail through the
            // ladder below (zero regions, zero cutters) and report
            // SUCCESS with the body untouched — fillet r=100 on a
            // 20×20×10 block "worked". Two distinct cases:
            if allEdges.isEmpty {
                // Nothing to finish at all (e.g. a sphere).
                throw isFillet ? CADError.filletFailed("there are no sharp edges to round on this part")
                               : CADError.chamferInvalid("there are no sharp edges to chamfer on this part")
            }
            // Every edge was rejected by the face-size filter alone:
            // restore the full set and let region() decide — an
            // oversize value now errors (FT408 with the feasible max)
            // instead of silently doing nothing.
            edges = allEdges
        }
        guard edges.count <= 240 else {
            throw isFillet ? CADError.filletFailed("\(edges.count) sharp edges — too many to finish at once")
                           : CADError.chamferInvalid("\(edges.count) sharp edges — too many to finish at once")
        }
        // Feasibility ladder: try the requested value, then hair-smaller
        // retries (at most 5% under — invisible). At EXACT tangency
        // (radius = half the stock thickness, say) the region checks
        // fail on a zero-width offset strip, not on real geometry:
        // radius 2.0 on a 4 mm plate reported FT408 "largest that fits
        // is 1.9750776…" while 1.98 mm rounds it perfectly well. Only
        // when even the smallest retry fails is the value genuinely
        // too big, and the error path below runs.
        let ladder = [1.0, 0.999, 0.995, 0.99, 0.98, 0.95]
        var regions: [[Vec2]]? = nil
        var usedValue = value
        var firstError: CADError? = nil
        for f in ladder {
            let v = value * f
            let vB = valueB >= 0 ? valueB * f : valueB
            var rs: [[Vec2]] = []
            var failed: CADError? = nil
            for e in edges {
                do { rs.append(try self.region(edge: e, value: v, isFillet: isFillet, valueB: vB)) }
                catch let err as CADError { failed = err; break }
            }
            if let failed {
                if firstError == nil { firstError = failed }
                continue
            }
            regions = rs
            usedValue = v
            break
        }
        guard let regions else {
            let err = firstError ?? (isFillet ? CADError.filletFailed("no usable edges")
                                              : CADError.chamferInvalid("no usable edges"))
            // Find the largest value that fits every edge, so the error
            // can name a radius/distance that would have worked.
            if isFillet, case .filletRadiusTooLarge = err {
                var lo = 0.0, hi = value
                for _ in 0..<24 {
                    let mid = (lo + hi) / 2
                    var ok = true
                    for e2 in edges {
                        do { _ = try self.region(edge: e2, value: mid, isFillet: true) }
                        catch { ok = false; break }
                    }
                    if ok { lo = mid } else { hi = mid }
                }
                throw CADError.filletRadiusTooLarge(requested: value, maxFeasible: lo)
            }
            throw err
        }
        var cutters: [Mesh] = [], adders: [Mesh] = []
        for (e, region) in zip(edges, regions) {
            // Cutters overshoot past the edge ends so the cut clears
            // the corners. ADDERS get NO overshoot: the added wedge
            // must stop at the edge's ends — past an open end (a slot
            // floor edge meeting the part's side face) an overshooting
            // wedge floats OUTSIDE the silhouette (bounds grew by the
            // full distance on device parts, 2026-10-26).
            let p = prism(edge: e, region: region, overshoot: e.isConvex ? vmax : 0)
            if e.isConvex { cutters.append(p) } else { adders.append(p) }
        }
        var result = body
        if !cutters.isEmpty { result = try CSG.subtract(result, unionAll(cutters)) }
        if !adders.isEmpty { result = try CSG.union(result, unionAll(adders)) }
        return result
    }

    public static func fillet(body: Mesh, radius: Double) throws -> Mesh {
        try finish(body: body, value: radius, isFillet: true)
    }

    /// Fillet only the edges whose midpoints are given (v4.1: the app
    /// passes the edge the user tapped in the 3D view).
    public static func fillet(body: Mesh, radius: Double, onlyMidpoints: [Vec3]) throws -> Mesh {
        try finish(body: body, value: radius, isFillet: true, onlyMidpoints: onlyMidpoints)
    }

    /// Chamfer only the edges whose midpoints are given.
    public static func chamfer(body: Mesh, distance: Double, onlyMidpoints: [Vec3]) throws -> Mesh {
        try finish(body: body, value: distance, isFillet: false, onlyMidpoints: onlyMidpoints)
    }

    public static func chamfer(body: Mesh, distance: Double) throws -> Mesh {
        try finish(body: body, value: distance, isFillet: false)
    }

    /// The largest fillet radius / chamfer distance whose SECTION
    /// REGIONS fit every target edge — region checks only, no CSG,
    /// so it is cheap enough to run when a panel opens. This is the
    /// same binary search `finish` runs on its FT408 error path,
    /// exposed so the app can PREFILL and CLAMP from the selection's
    /// real measured geometry instead of inventing a value the
    /// kernel then rejects. `onlyMidpoints` nil = every sharp edge
    /// of the body. Returns nil when the body has no target edges,
    /// and 0 when no positive value fits at all.
    public static func maxFeasibleValue(body: Mesh, isFillet: Bool,
                                        onlyMidpoints: [Vec3]? = nil) -> Double? {
        var edges = SolidEdgeExtractor.edges(of: body).filter { $0.length >= 0.5 }
        if let targets = onlyMidpoints {
            edges = edges.filter { e in targets.contains { $0.distance(to: e.mid) < 0.05 } }
        }
        guard !edges.isEmpty else { return nil }
        func fits(_ v: Double) -> Bool {
            for e in edges {
                do { _ = try self.region(edge: e, value: v, isFillet: isFillet) }
                catch { return false }
            }
            return true
        }
        guard fits(0.01) else { return 0 }
        // Grow an upper bound that fails (capped — no real part
        // takes a 200 mm edge finish), then bisect on the region
        // checks exactly like the FT408 path in finish().
        var lo = 0.01, hi = 0.02
        while fits(hi), hi < 200 { lo = hi; hi *= 2 }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Chamfer with per-face distances (v4 modes). Pre-validates every
    /// edge region (cheap); if the pair runs off a face, binary searches
    /// a uniform scale over the region checks only, so the thrown error
    /// can name a pair that fits.
    public static func chamfer2(body: Mesh, distanceA: Double, distanceB: Double) throws -> Mesh {
        let edges = SolidEdgeExtractor.edges(of: body).filter { $0.length >= 0.5 }
        func fits(_ a: Double, _ b: Double) -> Bool {
            for e in edges {
                do { _ = try region(edge: e, value: a, isFillet: false, valueB: b) }
                catch { return false }
            }
            return true
        }
        if !edges.isEmpty && !fits(distanceA, distanceB) {
            var lo = 0.0, hi = 1.0
            for _ in 0..<20 {
                let mid = (lo + hi) / 2
                if fits(distanceA * mid, distanceB * mid) { lo = mid } else { hi = mid }
            }
            if lo > 0.01 {
                throw CADError.chamferInvalid(
                    "too large for the faces — largest that fits ≈ " +
                    "\(String(format: "%.2f", distanceA * lo)) / \(String(format: "%.2f", distanceB * lo)) mm")
            }
            throw CADError.chamferInvalid("distances run off a face at any scale")
        }
        return try finish(body: body, value: distanceA, isFillet: false, valueB: distanceB)
    }

    /// Hollow the body with a uniform wall. The cutter is the body offset
    /// inward along per-vertex smooth normals.
    public static func shell(body: Mesh, thickness: Double) throws -> Mesh {
        guard thickness > 0 else { throw CADError.shellFailed("wall thickness must be > 0") }
        let m = body.welded()
        guard m.triangleCount > 0 else { throw CADError.shellFailed("nothing to shell") }
        let faceN = m.faceNormals()
        var normals = [Vec3](repeating: .zero, count: m.vertices.count)
        for t in 0..<m.triangleCount {
            for k in 0..<3 {
                let vi = Int(m.indices[t * 3 + k])
                normals[vi] = normals[vi] + faceN[t]
            }
        }
        for i in normals.indices {
            guard normals[i].length > 1e-9 else { throw CADError.shellFailed("degenerate geometry") }
            normals[i] = normals[i].normalized
        }
        // Wall-thickness correction: moving a vertex straight along
        // its averaged normal by t moves each adjacent FACE plane
        // by only t·(n̂·n̂face). At a box corner n̂ is the diagonal,
        // so the walls came out t/√3 ≈ 0.58·t — a 2 mm shell
        // measured ≈1.2 mm at the face (2026-10-26 sweep). Where
        // exactly three distinct planes meet at a vertex, solve for
        // the displacement whose component along EVERY plane's
        // normal is exactly t (reciprocal basis / Cramer). Vertices
        // on curved or multi-plane regions keep the averaged-normal
        // step — there n̂·n̂face ≈ 1 and it was already right.
        var planesAt: [Int: [Vec3]] = [:]
        for t in 0..<m.triangleCount {
            for k in 0..<3 {
                let vi = Int(m.indices[t * 3 + k])
                let n = faceN[t]
                if let existing = planesAt[vi],
                   existing.contains(where: { $0.dot(n) > 1 - 1e-9 }) { continue }
                planesAt[vi, default: []].append(n)
            }
        }
        let cutterVerts = m.vertices.enumerated().map { (i, v) -> Vec3 in
            if let ps = planesAt[i], ps.count == 3 {
                let (a, b, c) = (ps[0], ps[1], ps[2])
                let det = a.dot(b.cross(c))
                if abs(det) > 1e-6 {
                    // o = M⁻¹ r for M = [a; b; c], r = (−t, −t, −t):
                    // the reciprocal basis — o is the combination
                    // r₁(b×c) + r₂(c×a) + r₃(a×b), all over det.
                    let r = Vec3(-thickness, -thickness, -thickness)
                    let o = (b.cross(c) * r.x + c.cross(a) * r.y + a.cross(b) * r.z) * (1 / det)
                    if o.length <= 3 * thickness { return v + o }
                }
            }
            return v - normals[i] * thickness
        }
        // Keep the original winding: CSG reads solid insides from polygon
        // orientation, so the cutter must be an ordinary outward solid.
        let cutter = Mesh(vertices: cutterVerts, indices: m.indices)
        guard abs(cutter.volume) < m.volume * 0.995, abs(cutter.volume) > 0 else {
            throw CADError.shellFailed("wall \(thickness) is too thick for this part")
        }
        let result = try CSG.subtract(m, cutter)
        guard result.volume > m.volume * 0.01, result.volume < m.volume else {
            throw CADError.shellFailed("shell collapsed the part — try a thinner wall")
        }
        // Wall sanity at the largest face: halfway through the requested
        // wall must still be material, and 1.5x past it must be void.
        // (Catches requests so thick the "void" never forms.)
        if let face = FaceExtractor.planarFaces(of: m).first {
            let c = face.centroid, n = face.plane.normal
            let inMat = result.contains(c - n * (thickness * 0.5))
            let inVoid = !result.contains(c - n * (thickness * 1.5))
            if !inMat || !inVoid {
                throw CADError.shellFailed("wall \(thickness) is too thick for this part")
            }
        }
        return result
    }
}
