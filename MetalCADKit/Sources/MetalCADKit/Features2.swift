import Foundation

// MARK: - v4 mesh transforms

extension Mesh {
    /// Rotate around a world axis (0=X, 1=Y, 2=Z) through `center`.
    public func rotatedAround(axis: Int, degrees: Double, center: Vec3) -> Mesh {
        let a = degrees * Double.pi / 180
        let c = cos(a), s = sin(a)
        func rot(_ p: Vec3) -> Vec3 {
            let q = p - center
            let r: Vec3
            switch axis {
            case 0: r = Vec3(q.x, q.y * c - q.z * s, q.y * s + q.z * c)
            case 1: r = Vec3(q.x * c + q.z * s, q.y, -q.x * s + q.z * c)
            default: r = Vec3(q.x * c - q.y * s, q.x * s + q.y * c, q.z)
            }
            return center + r
        }
        return Mesh(vertices: vertices.map(rot), indices: indices)
    }

    /// Non-uniform scale about `center`.
    public func scaled(by f: Vec3, center: Vec3) -> Mesh {
        Mesh(vertices: vertices.map { v in
            let q = v - center
            return center + Vec3(q.x * f.x, q.y * f.y, q.z * f.z)
        }, indices: indices)
    }

    /// Concatenate meshes (multi-body display/export mesh).
    public func concatenated(with other: Mesh) -> Mesh {
        var m = self
        m.append(other)
        return m
    }
}

// MARK: - v4 feature geometry

extension DocumentEngine {

    /// Helical coil (spring) around +Z through the origin. Built as a
    /// direct tube mesh — rings transported along the helix with a
    /// parallel-transport frame — NOT via CSG sweeps (a long chain of
    /// boolean unions blows the triangle budget).
    static func coilMesh(radius: Double, pitch: Double, turns: Double, wireRadius: Double) throws -> Mesh {
        guard radius > wireRadius, wireRadius > 0, pitch > 0, turns > 0.25 else {
            throw CADError.primitiveParamInvalid("coil needs radius > wire radius, pitch > 0, turns > 0.25")
        }
        let stepsPerTurn = 16
        let total = min(160, max(8, Int(turns * Double(stepsPerTurn))))
        let sides = 14
        var centers: [Vec3] = []
        var tangents: [Vec3] = []
        for i in 0...total {
            let th = Double(i) / Double(stepsPerTurn) * 2 * Double.pi
            centers.append(Vec3(radius * cos(th), radius * sin(th), pitch * th / (2 * Double.pi)))
            tangents.append(Vec3(-radius * sin(th), radius * cos(th), pitch / (2 * Double.pi)).normalized)
        }
        // Parallel transport: start with (radial, axis) frame and rotate
        // it by the rotation taking each tangent to the next.
        var u = Vec3(1, 0, 0)
        var v = Vec3(0, 0, 1)
        var builder = MeshBuilder()
        var rings: [[UInt32]] = []
        for i in 0...total {
            if i > 0 {
                let axis = tangents[i - 1].cross(tangents[i])
                if axis.length > 1e-9 {
                    let ax = axis.normalized
                    let ang = acos(max(-1, min(1, tangents[i - 1].dot(tangents[i]))))
                    func rot(_ p: Vec3) -> Vec3 {
                        p * cos(ang) + ax.cross(p) * sin(ang) + ax * ax.dot(p) * (1 - cos(ang))
                    }
                    u = rot(u); v = rot(v)
                }
            }
            var ring: [UInt32] = []
            for j in 0..<sides {
                let a = Double(j) / Double(sides) * 2 * Double.pi
                let p = centers[i] + u * (wireRadius * cos(a)) + v * (wireRadius * sin(a))
                ring.append(builder.vertex(p))
            }
            rings.append(ring)
        }
        for i in 0..<total {
            for j in 0..<sides {
                let j1 = (j + 1) % sides
                builder.quad(rings[i][j], rings[i][j1], rings[i + 1][j1], rings[i + 1][j])
            }
        }
        // End caps (fans).
        let c0 = builder.vertex(centers[0]), c1 = builder.vertex(centers[total])
        for j in 0..<sides {
            let j1 = (j + 1) % sides
            builder.triangle(c0, rings[0][j1], rings[0][j])
            builder.triangle(c1, rings[total][j], rings[total][j1])
        }
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

    /// Pipe: a circular profile swept along a sketch path — the profile
    /// is generated automatically, perpendicular to the path start.
    static func pipeMesh(part: Part, pathSketchID: String, radius: Double) throws -> Mesh {
        guard radius > 0 else { throw CADError.primitiveParamInvalid("pipe radius must be > 0") }
        guard let sketch = part.sketch(pathSketchID) else { throw CADError.nameNotFound("sketch") }
        let path = try pathPoints(sketch: sketch)
        guard path.count >= 2 else { throw CADError.sweepPathInvalid("pipe path needs at least 2 points") }
        let start = path[0]
        let tangent = (path[1] - path[0]).normalized
        let helper = abs(tangent.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
        let u = helper.cross(tangent).normalized
        let v = tangent.cross(u).normalized
        let plane = Plane3(origin: start, xAxis: u, yAxis: v)
        var loop: [Vec3] = []
        for i in 0..<32 {
            let a = Double(i) / 32 * 2 * Double.pi
            loop.append(start + u * (radius * cos(a)) + v * (radius * sin(a)))
        }
        return try SweepTessellator.sweep(profileLoop: loop, profilePlane: plane, path: path)
    }

    /// Rib: a thin wall grown from an open sketch profile. The wall's
    /// shape lives in the sketch plane: from the profile line it
    /// extends in-plane by `depth` toward the body (the extension
    /// direction is the in-plane perpendicular that points at the
    /// body's center), with `thickness` along the sketch normal.
    /// The result is trimmed to a loose region around the body (an
    /// oriented box) and unioned — exact for the common prismatic
    /// cavity case, approximate at curved silhouettes.
    static func ribMesh(part: Part, sketchID: String, thickness: Double, depth: Double, body: Mesh) throws -> Mesh {
        guard thickness > 0, depth > 0 else {
            throw CADError.primitiveParamInvalid("rib needs thickness > 0 and depth > 0")
        }
        guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
        guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
        let pts = try pathPoints(sketch: sketch)
        guard pts.count >= 2 else { throw CADError.padNoProfile }
        let n = sketch.plane.normal
        // Extension direction: in-plane perpendicular to the first
        // segment, pointing toward the body center.
        let seg0 = (pts[1] - pts[0]).normalized
        let mid = pts.reduce(Vec3.zero) { $0 + $1 } * (1.0 / Double(pts.count))
        let toBody = body.bounds.center - mid
        let e1 = n.cross(seg0).normalized
        let e = e1.dot(toBody) >= 0 ? e1 : e1 * -1
        let half = n * (thickness / 2)
        let ext = e * (depth + 1)  // 1 mm of buried overshoot into the body
        var builder = MeshBuilder()
        // Per segment, an oriented box chunk: axes are (along segment,
        // thickness along the normal, extension e). Built from the
        // canonical cube template so winding is consistent; a global
        // signed-volume flip below restores outward normals.
        func corner(_ base: Vec3, _ j: Int, _ k: Int) -> Vec3 {
            base + (j == 1 ? half : half * -1) + (k == 1 ? ext : Vec3.zero)
        }
        let faces: [[(Int, Int, Int)]] = [
            [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)],
            [(0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0)],
            [(0, 0, 0), (0, 1, 0), (1, 1, 0), (1, 0, 0)],
            [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)],
            [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)],
            [(1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)],
        ]
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            for face in faces {
                let vs = face.map { (ii, j, k) in builder.vertex(corner(ii == 1 ? b : a, j, k)) }
                builder.quad(vs[0], vs[1], vs[2], vs[3])
            }
        }
        var wall = builder.mesh
        if wall.signedVolume < 0 {
            var idx: [UInt32] = []
            for t in 0..<wall.triangleCount {
                idx += [wall.indices[t * 3], wall.indices[t * 3 + 2], wall.indices[t * 3 + 1]]
            }
            wall = Mesh(vertices: wall.vertices, indices: idx)
        }
        // Trim overshoot on the FAR side of the body only: the clip is
        // an oriented box aligned to e, covering the body's bounds and
        // extending (depth + 2) beyond them on the profile side — a rib
        // standing proud of the current silhouette survives, while a
        // wall poking through the far face is cut at the bounds.
        let bb = body.bounds
        let diag = bb.size.length
        let wAxis = e
        let helper = abs(wAxis.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
        let uAxis = helper.cross(wAxis).normalized
        let vAxis = wAxis.cross(uAxis).normalized
        let center = bb.center - wAxis * ((depth + 2) / 2)
        let hu = diag, hv = diag, hw = (diag + depth + 2) / 2
        func cpt(_ i: Int, _ j: Int, _ k: Int) -> Vec3 {
            center + uAxis * (i == 1 ? hu : -hu) + vAxis * (j == 1 ? hv : -hv) + wAxis * (k == 1 ? hw : -hw)
        }
        var clipBuilder = MeshBuilder()
        let clipFaces: [[(Int, Int, Int)]] = [
            [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)],
            [(0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0)],
            [(0, 0, 0), (0, 1, 0), (1, 1, 0), (1, 0, 0)],
            [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)],
            [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)],
            [(1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)],
        ]
        for face in clipFaces {
            let vs = face.map { clipBuilder.vertex(cpt($0.0, $0.1, $0.2)) }
            clipBuilder.quad(vs[0], vs[1], vs[2], vs[3])
        }
        var clip = clipBuilder.mesh
        if clip.signedVolume < 0 {
            var idx: [UInt32] = []
            for t in 0..<clip.triangleCount {
                idx += [clip.indices[t * 3], clip.indices[t * 3 + 2], clip.indices[t * 3 + 1]]
            }
            clip = Mesh(vertices: clip.vertices, indices: idx)
        }
        let trimmed = try CSG.intersect(wall, clip)
        guard trimmed.triangleCount > 0 else {
            throw CADError.booleanFailed("the rib wall misses the body entirely")
        }
        return try CSG.union(body, trimmed)
    }

    /// Draft: taper the body's side faces for mold release. Each vertex
    /// moves radially (in the plane perpendicular to the pull axis,
    /// measured from the axis through the bounds center) by
    /// -tan(angle) * height above the neutral (min) plane — a positive
    /// angle narrows the part toward the top. Exact for prismatic
    /// parts; a close morph for others.
    static func draftMesh(body: Mesh, angleDegrees: Double, pullAxis: Int) throws -> Mesh {
        guard abs(angleDegrees) > 1e-9, abs(angleDegrees) < 30 else {
            throw CADError.transformInvalid("draft angle must be between -30 and 30 degrees")
        }
        let b = body.bounds
        let t = tan(angleDegrees * Double.pi / 180)
        let center = b.center
        func comp(_ v: Vec3, _ axis: Int) -> Double { axis == 0 ? v.x : axis == 1 ? v.y : v.z }
        let neutral = comp(b.min, pullAxis)
        let verts = body.vertices.map { v -> Vec3 in
            let h = comp(v, pullAxis) - neutral
            var radial = v - center
            switch pullAxis {
            case 0: radial = Vec3(0, radial.y, radial.z)
            case 1: radial = Vec3(radial.x, 0, radial.z)
            default: radial = Vec3(radial.x, radial.y, 0)
            }
            guard radial.length > 1e-9 else { return v }
            return v - radial.normalized * (t * h)
        }
        return Mesh(vertices: verts, indices: body.indices)
    }

    /// Split the body with an axis plane at `offset` (world coordinate
    /// along the axis). Returns (kept, other) halves.
    static func splitMesh(body: Mesh, axis: Int, offset: Double) throws -> (Mesh, Mesh) {
        let b = body.bounds
        let size = b.size
        func halfBox(from lo: Double, to hi: Double) throws -> Mesh {
            var ext = [size.x, size.y, size.z]
            ext[axis] = hi - lo
            var box = try Tessellation.box(width: ext[0] + 0.002, depth: ext[1] + 0.002, height: ext[2] + 0.002)
            // The native box spans x/y centered and z from 0; place it so
            // its long axis covers [lo, hi] along the split axis.
            switch axis {
            case 2:
                box = box.translated(by: Vec3(b.center.x, b.center.y, lo - 0.001))
            case 0:
                // Native: x = split span (centered), y = size.y (centered),
                // z = size.z (from 0).
                let src = box
                let mapped = src.vertices.map {
                    Vec3($0.x + lo + (hi - lo) / 2, $0.y + b.center.y, $0.z + b.min.z - 0.001)
                }
                box = Mesh(vertices: mapped, indices: src.indices)
            default:
                // Native: x = size.x (centered), y = split span (centered),
                // z = size.z (from 0).
                let src = box
                let mapped = src.vertices.map {
                    Vec3($0.x + b.center.x, $0.y + lo + (hi - lo) / 2, $0.z + b.min.z - 0.001)
                }
                box = Mesh(vertices: mapped, indices: src.indices)
            }
            return box
        }
        let lo = axis == 0 ? b.min.x : axis == 1 ? b.min.y : b.min.z
        let hi = axis == 0 ? b.max.x : axis == 1 ? b.max.y : b.max.z
        guard offset > lo + 1e-6, offset < hi - 1e-6 else {
            throw CADError.booleanFailed("the split plane misses the body")
        }
        let h1 = try CSG.intersect(body, halfBox(from: lo, to: offset))
        let h2 = try CSG.intersect(body, halfBox(from: offset, to: hi))
        guard h1.triangleCount > 0, h2.triangleCount > 0 else {
            throw CADError.booleanFailed("the split plane misses the body")
        }
        return (h1, h2)
    }
}

// MARK: - Project geometry (3D -> sketch)
/// Project the body's sharp edges or a face's outline onto a sketch
/// plane, returning 2D segments in the plane's coordinates — the app
/// turns these into construction (reference) sketch entities.
public enum ProjectGeometry {
    public static func edgeSegments(body: Mesh, onto plane: Plane3) -> [(Vec2, Vec2)] {
        func proj(_ p: Vec3) -> Vec2 {
            let d = p - plane.origin
            return Vec2(d.dot(plane.xAxis), d.dot(plane.yAxis))
        }
        return SolidEdgeExtractor.edges(of: body).map { (proj($0.start), proj($0.end)) }
    }

    public static func faceOutlineSegments(face: PlanarFace, onto plane: Plane3) -> [(Vec2, Vec2)] {
        func proj(_ p: Vec3) -> Vec2 {
            let d = p - plane.origin
            return Vec2(d.dot(plane.xAxis), d.dot(plane.yAxis))
        }
        let pts = face.outline2D.map { face.plane.toWorld($0) }
        guard pts.count >= 2 else { return [] }
        var out: [(Vec2, Vec2)] = []
        for i in 0..<pts.count {
            out.append((proj(pts[i]), proj(pts[(i + 1) % pts.count])))
        }
        return out
    }
}

extension DocumentEngine {
    /// Extrude with an end condition resolved against the CURRENT body
    /// (through-all / up-to-face need the body, so rebuild calls this
    /// instead of evaluate). Returns the tool/prism mesh; the caller
    /// applies the BodyOperation.
    static func extrude2Mesh(part: Part, sketchID: String, distance: Double,
                             taper: Double, mode: ExtrudeMode, end: ExtrudeEnd,
                             body: Mesh, warnings: inout [CADError]) throws -> Mesh {
        guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
        let (profiles, w) = try sketch.extractProfiles()
        warnings += w
        guard let profile = profiles.first else { throw CADError.padNoProfile }
        let n = sketch.plane.normal
        var dist = distance
        switch end {
        case .dimension:
            guard distance > 0 else { throw CADError.padLengthInvalid(distance) }
        case .throughAll:
            dist = body.triangleCount == 0 ? 1000 : body.bounds.size.length + 100
        case .upToFace(let faceIndex):
            let faces = FaceExtractor.planarFaces(of: body)
            guard faceIndex >= 0, faceIndex < faces.count else {
                throw CADError.booleanFailed("the target face no longer exists — pick another")
            }
            let d = (faces[faceIndex].centroid - sketch.plane.origin).dot(n)
            guard d > 0.01 else {
                throw CADError.booleanFailed("the target face is behind the sketch plane")
            }
            dist = d
        }
        switch mode {
        case .one:
            return try Tessellation.extrudeTapered(profile: profile, plane: sketch.plane, length: dist, taperDegrees: taper)
        case .symmetric:
            let shifted = Plane3(origin: sketch.plane.origin - n * (dist / 2),
                                 xAxis: sketch.plane.xAxis, yAxis: sketch.plane.yAxis)
            return try Tessellation.extrudeTapered(profile: profile, plane: shifted, length: dist, taperDegrees: taper)
        case .twoSided(let second):
            guard second > 0 else { throw CADError.padLengthInvalid(second) }
            var m = try Tessellation.extrudeTapered(profile: profile, plane: sketch.plane, length: dist, taperDegrees: taper)
            let backPlane = Plane3(origin: sketch.plane.origin - n * second,
                                   xAxis: sketch.plane.xAxis, yAxis: sketch.plane.yAxis)
            let back = try Tessellation.extrudeTapered(profile: profile, plane: backPlane, length: second, taperDegrees: taper)
            m.append(back)
            return m
        }
    }
}

extension Mesh {
    /// Keep only triangles whose centroid is at or above `z` (used to
    /// trim a thread ridge where it dives into the body).
    public func keepingTriangles(aboveZ z: Double) -> Mesh {
        var idx: [UInt32] = []
        for t in 0..<triangleCount {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            if (a.z + b.z + c.z) / 3 >= z {
                idx += [indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]]
            }
        }
        return Mesh(vertices: vertices, indices: idx)
    }
}

// MARK: - Cylinder fitting (tap a pillar -> thread it)

/// A fitted cylinder: a point on its axis at the low end, the unit
/// axis, radius, axial height, and whether the surface is a hole wall
/// (normals pointing at the axis) rather than a shaft.
public struct CylinderFit: Equatable {
    public var origin: Vec3
    public var axis: Vec3
    public var radius: Double
    public var height: Double
    public var isInternal: Bool
}

public enum CylinderFitter {
    /// Region-grow a smooth patch from a seed triangle of the welded
    /// mesh and fit a cylinder to it. Returns nil when the patch is
    /// not cylindrical (a flat face, a sphere, too small...).
    public static func fit(mesh: Mesh, seedTriangle: Int) -> CylinderFit? {
        let m = mesh.welded()
        guard seedTriangle >= 0, seedTriangle < m.triangleCount else { return nil }
        let normals = m.faceNormals()
        // Triangle adjacency through shared welded edges.
        var edgeTris: [String: [Int]] = [:]
        func key(_ a: Int, _ b: Int) -> String { a < b ? "\(a)-\(b)" : "\(b)-\(a)" }
        for t in 0..<m.triangleCount {
            let v = [Int(m.indices[t * 3]), Int(m.indices[t * 3 + 1]), Int(m.indices[t * 3 + 2])]
            for i in 0..<3 {
                edgeTris[key(v[i], v[(i + 1) % 3]), default: []].append(t)
            }
        }
        // Grow across edges whose normals differ by < 25 degrees.
        var patch = Set<Int>([seedTriangle])
        var frontier = [seedTriangle]
        while let t = frontier.popLast() {
            let v = [Int(m.indices[t * 3]), Int(m.indices[t * 3 + 1]), Int(m.indices[t * 3 + 2])]
            for i in 0..<3 {
                for nb in edgeTris[key(v[i], v[(i + 1) % 3])] ?? [] where !patch.contains(nb) {
                    if normals[t].dot(normals[nb]) > cos(25 * Double.pi / 180) {
                        patch.insert(nb)
                        frontier.append(nb)
                    }
                }
            }
        }
        guard patch.count >= 8 else { return nil }
        // Axis: the direction every patch normal is perpendicular to.
        // Deterministic search over normal cross products.
        let ns = patch.map { normals[$0] }
        var axis: Vec3? = nil
        outer: for i in 0..<min(ns.count, 24) {
            for j in (i + 1)..<min(ns.count, 24) {
                let c = ns[i].cross(ns[j])
                if c.length > 0.2 {
                    let cand = c.normalized
                    if ns.allSatisfy({ abs($0.dot(cand)) < 0.25 }) { axis = cand; break outer }
                }
            }
        }
        guard let ax = axis else { return nil }
        // Patch centroid + radial distances.
        var verts = Set<Int>()
        for t in patch { for k in 0..<3 { verts.insert(Int(m.indices[t * 3 + k])) } }
        var centroid = Vec3.zero
        for vi in verts { centroid = centroid + m.vertices[vi] }
        centroid = centroid * (1.0 / Double(verts.count))
        var rSum = 0.0, rMax = 0.0
        var hMin = Double.infinity, hMax = -Double.infinity
        for vi in verts {
            let d = m.vertices[vi] - centroid
            let along = d.dot(ax)
            let radial = (d - ax * along).length
            rSum += radial
            rMax = max(rMax, abs(radial))
            hMin = min(hMin, along); hMax = max(hMax, along)
        }
        let radius = rSum / Double(verts.count)
        guard radius > 0.05 else { return nil }
        // Residual check: every vertex must hug the cylinder.
        for vi in verts {
            let d = m.vertices[vi] - centroid
            let radial = (d - ax * d.dot(ax)).length
            if abs(radial - radius) > max(0.06, 0.03 * radius) { return nil }
        }
        // Angular coverage: a fillet is a true cylinder section too,
        // but it wraps only ~90 degrees, while a shaft or hole wall
        // wraps the full turn. Bin the patch vertices' angles around
        // the axis (10-degree bins, around the axis point nearest the
        // patch centroid — the fit's axis line passes through the
        // centroid) and reject partial wraps so a fillet never
        // masquerades as a shaft.
        let helper = abs(ax.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(ax).normalized
        let w = ax.cross(u)
        var bins = Set<Int>()
        for vi in verts {
            let d = m.vertices[vi] - centroid
            let radialVec = d - ax * d.dot(ax)
            guard radialVec.length > radius * 0.5 else { continue }
            var angle = atan2(radialVec.dot(w), radialVec.dot(u))
            if angle < 0 { angle += 2 * Double.pi }
            bins.insert(Int(angle / (10 * Double.pi / 180)))
        }
        guard Double(bins.count) * 10 >= 150 else { return nil }
        let origin = centroid + ax * hMin
        // Internal if a patch normal points TOWARD the axis.
        let t0 = patch.first!
        let tc = (m.vertices[Int(m.indices[t0 * 3])] + m.vertices[Int(m.indices[t0 * 3 + 1])] + m.vertices[Int(m.indices[t0 * 3 + 2])]) * (1.0 / 3)
        let radialDir = (tc - (origin + ax * (tc - origin).dot(ax)))
        let isInternal = normals[t0].dot(radialDir) < 0
        _ = rMax
        return CylinderFit(origin: origin, axis: ax, radius: radius,
                           height: hMax - hMin, isInternal: isInternal)
    }
}

extension Mesh {
    /// Rigid placement: local +Z becomes `axis`, local origin lands on
    /// `origin` (a proper rotation via an orthonormal basis).
    public func placed(axis: Vec3, origin: Vec3) -> Mesh {
        let ax = axis.normalized
        let helper = abs(ax.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(ax).normalized
        let v = ax.cross(u).normalized
        return Mesh(vertices: vertices.map { origin + u * $0.x + v * $0.y + ax * $0.z },
                    indices: indices)
    }

    /// Keep triangles whose centroid's coordinate along `axis` from
    /// `origin` lies in [lo, hi].
    public func keepingTriangles(axis origin: Vec3, axis: Vec3, between lo: Double, and hi: Double) -> Mesh {
        var idx: [UInt32] = []
        for t in 0..<triangleCount {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            let cen = (a + b + c) * (1.0 / 3)
            let s = (cen - origin).dot(axis)
            if s >= lo && s <= hi {
                idx += [indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]]
            }
        }
        return Mesh(vertices: vertices, indices: idx)
    }
}
