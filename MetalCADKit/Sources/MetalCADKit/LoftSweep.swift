import Foundation

/// Loft (blend between two profile sketches) and sweep (profile carried
/// along a path sketch), plus profile loop helpers.
public enum ProfileLoop {
    /// Outer loop of a sketch's first closed profile, as world points.
    public static func worldLoop(sketch: Sketch) throws -> (points: [Vec3], plane: Plane3) {
        let (profiles, _) = try sketch.extractProfiles()
        guard let profile = profiles.first else { throw CADError.padNoProfile }
        let pts2 = profile.outer
        guard pts2.count >= 3 else { throw CADError.padNoProfile }
        return (pts2.map { sketch.plane.toWorld($0) }, sketch.plane)
    }

    /// Even arc-length resampling of a closed loop.
    public static func resampleClosed(_ points: [Vec3], count: Int) -> [Vec3] {
        guard points.count > 1, count > 0 else { return points }
        var segLens: [Double] = []
        var total = 0.0
        for i in points.indices {
            let l = points[i].distance(to: points[(i + 1) % points.count])
            segLens.append(l); total += l
        }
        guard total > 0 else { return points }
        var out: [Vec3] = []
        var seg = 0, segStart = 0.0
        for k in 0..<count {
            let target = total * Double(k) / Double(count)
            while seg < points.count - 1 && segStart + segLens[seg] < target {
                segStart += segLens[seg]; seg += 1
            }
            let l = segLens[seg]
            let f = l > 0 ? (target - segStart) / l : 0
            out.append(points[seg] + (points[(seg + 1) % points.count] - points[seg]) * f)
        }
        return out
    }

    /// Newell normal of a 3D loop.
    public static func loopNormal(_ points: [Vec3]) -> Vec3 {
        var n = Vec3.zero
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            n = n + Vec3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        return n.normalized
    }
}

public enum LoftTessellator {
    public static func loft(loopA: [Vec3], loopB: [Vec3], samples: Int = 96) throws -> Mesh {
        guard loopA.count >= 3, loopB.count >= 3 else { throw CADError.loftProfileMismatch }
        var a = ProfileLoop.resampleClosed(loopA, count: samples)
        var b = ProfileLoop.resampleClosed(loopB, count: samples)
        // resampleClosed returns its input unchanged for a degenerate
        // loop (zero total length — every point coincident), leaving
        // count != samples; the alignment loops below index up to
        // samples and trapped out of range (2026-10-26 sweep).
        guard a.count == samples, b.count == samples else { throw CADError.loftProfileMismatch }
        // Consistent winding: both loops should wind the same way around
        // their average normal direction.
        let nA = ProfileLoop.loopNormal(a), nB = ProfileLoop.loopNormal(b)
        if nA.dot(nB) < 0 { b.reverse() }
        // Rotate b to best align with a (minimize total squared distance).
        var bestShift = 0, bestCost = Double.greatestFiniteMagnitude
        for shift in 0..<samples {
            var cost = 0.0
            for i in 0..<samples { let d = a[i].distance(to: b[(i + shift) % samples]); cost += d * d }
            if cost < bestCost { bestCost = cost; bestShift = shift }
        }
        if bestShift != 0 { b = (0..<samples).map { b[($0 + bestShift) % samples] } }
        var builder = MeshBuilder()
        let av = a.map { builder.vertex($0) }
        let bv = b.map { builder.vertex($0) }
        for i in 0..<samples {
            let j = (i + 1) % samples
            builder.quad(av[i], av[j], bv[j], bv[i])
        }
        // Caps: centroid fans over the dense resampled loops.
        func cap(_ loop: [Vec3], _ verts: [UInt32], flip: Bool) {
            let c = builder.vertex(loop.reduce(Vec3.zero) { $0 + $1 } * (1.0 / Double(loop.count)))
            for i in 0..<samples {
                let j = (i + 1) % samples
                if flip { builder.triangle(c, verts[j], verts[i]) } else { builder.triangle(c, verts[i], verts[j]) }
            }
        }
        cap(a, av, flip: true)
        cap(b, bv, flip: false)
        var mesh = builder.mesh
        if mesh.signedVolume < 0 {
            var idx: [UInt32] = []
            for t in 0..<mesh.triangleCount {
                idx += [mesh.indices[t * 3], mesh.indices[t * 3 + 2], mesh.indices[t * 3 + 1]]
            }
            mesh = Mesh(vertices: mesh.vertices, indices: idx)
        }
        return mesh
    }
}

public enum SweepTessellator {
    /// Carry a profile loop along a polyline path. Segment prisms are
    /// unioned with CSG, so bends overlap cleanly.
    public static func sweep(profileLoop: [Vec3], profilePlane: Plane3, path: [Vec3]) throws -> Mesh {
        guard profileLoop.count >= 3 else { throw CADError.sweepPathInvalid("profile has no closed loop") }
        guard path.count >= 2 else { throw CADError.sweepPathInvalid("path needs at least 2 points") }
        let centroid = profileLoop.reduce(Vec3.zero) { $0 + $1 } * (1.0 / Double(profileLoop.count))
        let rel = profileLoop.map { $0 - centroid }  // in profile plane coords (pn component ~0)
        func frame(tangent: Vec3) -> (x: Vec3, y: Vec3) {
            let helper = abs(tangent.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
            let x = helper.cross(tangent).normalized
            return (x, tangent.cross(x).normalized)
        }
        func ring(at point: Vec3, tangent: Vec3) -> [Vec3] {
            let (fx, fy) = frame(tangent: tangent)
            // Express profile offsets in the profile basis, re-emit in the
            // path frame basis.
            return rel.map { d in
                point + fx * d.dot(profilePlane.xAxis) + fy * d.dot(profilePlane.yAxis)
            }
        }
        var result = Mesh()
        for s in 0..<(path.count - 1) {
            let tangent = (path[s + 1] - path[s]).normalized
            guard tangent.length > 0.5 else { continue }
            let r0 = ring(at: path[s], tangent: tangent)
            let r1 = ring(at: path[s + 1], tangent: tangent)
            var builder = MeshBuilder()
            let v0 = r0.map { builder.vertex($0) }
            let v1 = r1.map { builder.vertex($0) }
            for i in 0..<r0.count {
                let j = (i + 1) % r0.count
                builder.quad(v0[i], v0[j], v1[j], v1[i])
            }
            let c0 = builder.vertex(path[s]), c1 = builder.vertex(path[s + 1])
            for i in 0..<r0.count {
                let j = (i + 1) % r0.count
                builder.triangle(c0, v0[j], v0[i])
                builder.triangle(c1, v1[i], v1[j])
            }
            var seg = builder.mesh
            if seg.signedVolume < 0 {
                var idx: [UInt32] = []
                for t in 0..<seg.triangleCount {
                    idx += [seg.indices[t * 3], seg.indices[t * 3 + 2], seg.indices[t * 3 + 1]]
                }
                seg = Mesh(vertices: seg.vertices, indices: idx)
            }
            result = result.triangleCount == 0 ? seg : try CSG.union(result, seg)
        }
        guard result.triangleCount > 0 else { throw CADError.sweepPathInvalid("path produced no geometry") }
        return result
    }
}
