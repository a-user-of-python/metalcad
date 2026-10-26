import Foundation

/// A triangle mesh — the v1 kernel's currency (tessellated solids).
///
/// `bounds` and `signedVolume` used to be full triangle scans on every
/// access, and they are read constantly (render keys, headers, guards).
/// They are now CACHED: computed once in `init(vertices:indices:)` (the
/// funnel every factory / transform / CSG result passes through) and
/// kept in sync by the paths that mutate a mesh in place. Direct writes
/// to `vertices`/`indices` mark the cache dirty via `didSet`; a dirty
/// cache falls back to the old scan-on-read, so any construction path
/// this file doesn't know about stays correct, just not accelerated.
public struct Mesh: Equatable {
    public var vertices: [Vec3] = [] { didSet { metadataDirty = true } }
    public var indices: [UInt32] = [] { didSet { metadataDirty = true } }   // triples

    private var cachedBounds: BoundingBox = .empty
    private var cachedSignedVolume: Double = 0
    private var metadataDirty = false

    public init() {}
    public init(vertices: [Vec3], indices: [UInt32]) {
        self.vertices = vertices; self.indices = indices
        // Observers don't fire during init; fill the cache directly.
        cachedBounds = Self.computeBounds(vertices)
        cachedSignedVolume = Self.computeSignedVolume(vertices: vertices, indices: indices)
        metadataDirty = false
    }
    /// Equality is geometric identity (vertex + index arrays) — the
    /// metadata cache must not leak into it (a clean and a dirty copy
    /// of the same mesh are the same mesh).
    public static func == (a: Mesh, b: Mesh) -> Bool {
        a.vertices == b.vertices && a.indices == b.indices
    }
    public var triangleCount: Int { indices.count / 3 }
    public var bounds: BoundingBox {
        metadataDirty ? Self.computeBounds(vertices) : cachedBounds
    }
    /// Signed volume via the divergence theorem. Positive = outward normals
    /// for a closed mesh.
    public var signedVolume: Double {
        metadataDirty
            ? Self.computeSignedVolume(vertices: vertices, indices: indices)
            : cachedSignedVolume
    }
    public var volume: Double { abs(signedVolume) }

    private static func computeBounds(_ vertices: [Vec3]) -> BoundingBox {
        var b = BoundingBox.empty
        for v in vertices { b.include(v) }
        return b
    }
    private static func computeSignedVolume(vertices: [Vec3], indices: [UInt32]) -> Double {
        var vol = 0.0
        let n = indices.count / 3
        for t in 0..<n {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            vol += a.dot(b.cross(c)) / 6.0
        }
        return vol
    }
    /// Count edges used by exactly one triangle (boundary/open edges).
    /// Close T-junctions left by BSP CSG: an edge used by exactly one
    /// triangle whose segment passes through another vertex gets split
    /// at that vertex. The surface was already geometrically closed;
    /// this makes it index-closed too. Passes repeat until no split
    /// applies. (Vertex SNAPPING was tried and removed: moving a shared
    /// vertex tears its other edges faster than it closes cracks.)
    public func stitched(tolerance: Double = 1e-4) -> Mesh {
        var mesh = welded(tolerance: tolerance)
        for _ in 0..<40 {
            if !splitOnePass(&mesh, tolerance: tolerance) { break }
        }
        return mesh
    }

    /// One pass of T-junction splitting over `mesh` (in place). Returns
    /// true if any triangle was split.
    private func splitOnePass(_ mesh: inout Mesh, tolerance: Double) -> Bool {
        var counts: [UInt64: Int] = [:]
        counts.reserveCapacity(mesh.triangleCount * 3)
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 { (UInt64(max(a, b)) << 32) | UInt64(min(a, b)) }
        for t in 0..<mesh.triangleCount {
            for k in 0..<3 { counts[key(mesh.indices[t * 3 + k], mesh.indices[t * 3 + (k + 1) % 3]), default: 0] += 1 }
        }
        let open = counts.filter { $0.value == 1 }
            .map { (UInt32($0.key >> 32), UInt32($0.key & 0xFFFF_FFFF)) }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        if open.isEmpty { return false }
        let cellSize = 0.25
        func gkey(_ x: Int, _ y: Int, _ z: Int) -> Int { (x &* 73856093) ^ (y &* 19349663) ^ (z &* 83492791) }
        var vgrid: [Int: [Int]] = [:]
        for (vi, v) in mesh.vertices.enumerated() {
            guard v.isFinite() else { continue }  // Int(floor(NaN)) traps
            vgrid[gkey(Int(floor(v.x / cellSize)), Int(floor(v.y / cellSize)), Int(floor(v.z / cellSize))), default: []].append(vi)
        }
        func candidates(near pa: Vec3, _ pb: Vec3) -> [Int] {
            let lo = Vec3(min(pa.x, pb.x) - tolerance, min(pa.y, pb.y) - tolerance, min(pa.z, pb.z) - tolerance)
            let hi = Vec3(max(pa.x, pb.x) + tolerance, max(pa.y, pb.y) + tolerance, max(pa.z, pb.z) + tolerance)
            var out: [Int] = []
            for gx in Int(floor(lo.x / cellSize))...Int(floor(hi.x / cellSize)) {
                for gy in Int(floor(lo.y / cellSize))...Int(floor(hi.y / cellSize)) {
                    for gz in Int(floor(lo.z / cellSize))...Int(floor(hi.z / cellSize)) {
                        out += vgrid[gkey(gx, gy, gz)] ?? []
                    }
                }
            }
            return out
        }
        var edgeTri: [UInt64: Int] = [:]
        edgeTri.reserveCapacity(mesh.triangleCount * 3)
        for t in 0..<mesh.triangleCount {
            for k in 0..<3 {
                let kk = key(mesh.indices[t * 3 + k], mesh.indices[t * 3 + (k + 1) % 3])
                if edgeTri[kk] == nil { edgeTri[kk] = t }
            }
        }
        var indices = mesh.indices
        var didSplit = false
        for (a, b) in open {
            let pa = mesh.vertices[Int(a)], pb = mesh.vertices[Int(b)]
            guard pa.isFinite(), pb.isFinite() else { continue }
            let ab = pb - pa
            let len2 = ab.dot(ab)
            if len2 < 1e-18 { continue }
            var splitVertex: UInt32? = nil
            for vi in candidates(near: pa, pb) where UInt32(vi) != a && UInt32(vi) != b {
                let v = mesh.vertices[vi]
                let t = (v - pa).dot(ab) / len2
                if t <= 1e-9 || t >= 1 - 1e-9 { continue }
                if (pa + ab * t).distance(to: v) < tolerance { splitVertex = UInt32(vi); break }
            }
            guard let v = splitVertex, let t = edgeTri[key(a, b)] else { continue }
            let tri = [indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]]
            guard let ea = tri.firstIndex(of: a), let eb = tri.firstIndex(of: b) else { continue }
            let c = tri[3 - ea - eb]
            if (ea + 1) % 3 == eb {
                indices[t * 3] = a; indices[t * 3 + 1] = v; indices[t * 3 + 2] = c
                indices += [v, b, c]
            } else {
                indices[t * 3] = b; indices[t * 3 + 1] = v; indices[t * 3 + 2] = c
                indices += [v, a, c]
            }
            didSplit = true
        }
        if didSplit { mesh = Mesh(vertices: mesh.vertices, indices: indices) }
        return didSplit
    }

    public var openEdgeCount: Int {
        var counts: [UInt64: Int] = [:]
        counts.reserveCapacity(triangleCount * 3)
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            let lo = UInt64(min(a, b)), hi = UInt64(max(a, b))
            return (hi << 32) | lo
        }
        for t in 0..<triangleCount {
            let i0 = indices[t * 3], i1 = indices[t * 3 + 1], i2 = indices[t * 3 + 2]
            counts[key(i0, i1), default: 0] += 1
            counts[key(i1, i2), default: 0] += 1
            counts[key(i2, i0), default: 0] += 1
        }
        return counts.values.filter { $0 == 1 }.count
    }
    public var isWatertight: Bool { openEdgeCount == 0 && triangleCount > 0 }
    public var hasNaN: Bool { vertices.contains { !$0.isFinite() } }
    /// Merge vertices that coincide (within tolerance), remapping indices.
    /// Tessellation stages emit duplicated seam vertices; welding produces
    /// the shared-index mesh used for watertight checks and export.
    public func welded(tolerance: Double = 1e-6) -> Mesh {
        // A zero/negative tolerance divides by zero in the cell math
        // below (floor(v / 0) = inf, and Int(inf) traps); clamp to a
        // hair above zero so degenerate input degrades to "merge
        // exact duplicates only" instead of crashing (2026-10-26
        // sweep). Non-finite vertices are carried through unmerged:
        // Int(floor(NaN)) traps the same way, and a NaN vertex must
        // poison the geometry, never the process — CSG rejects NaN
        // meshes up front, this keeps display/weld callers alive.
        let tolerance = max(tolerance, 1e-9)
        // Spatial hash over the 27 neighboring cells so points near a cell
        // boundary still merge (single-cell rounding splits them).
        var cells: [Int: [Int]] = [:]
        cells.reserveCapacity(vertices.count * 2)
        var verts: [Vec3] = []
        verts.reserveCapacity(vertices.count)
        var remap: [UInt32] = []
        remap.reserveCapacity(vertices.count)
        // Squared-distance compare: equivalent to distance <= tolerance
        // for tolerance >= 0, without a sqrt per candidate pair.
        let tolSq = tolerance * tolerance
        func cellKey(_ cx: Int, _ cy: Int, _ cz: Int) -> Int {
            (cx &* 73856093) ^ (cy &* 19349663) ^ (cz &* 83492791)
        }
        for v in vertices {
            if !v.isFinite() {
                let ci = verts.count
                verts.append(v)
                remap.append(UInt32(ci))
                continue
            }
            let gx = Int(floor(v.x / tolerance)), gy = Int(floor(v.y / tolerance)), gz = Int(floor(v.z / tolerance))
            var found: Int? = nil
            outer: for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        for ci in cells[cellKey(gx + dx, gy + dy, gz + dz)] ?? [] {
                            let d = verts[ci] - v
                            if tolerance >= 0 && d.x * d.x + d.y * d.y + d.z * d.z <= tolSq { found = ci; break outer }
                        }
                    }
                }
            }
            if let ci = found {
                remap.append(UInt32(ci))
            } else {
                let ci = verts.count
                verts.append(v)
                cells[cellKey(gx, gy, gz), default: []].append(ci)
                remap.append(UInt32(ci))
            }
        }
        return Mesh(vertices: verts, indices: indices.map { remap[Int($0)] })
    }
    public func translated(by d: Vec3) -> Mesh {
        Mesh(vertices: vertices.map { $0 + d }, indices: indices)
    }
    /// Mirror across a base plane (flips winding to stay outward).
    public func mirrored(axis: Int) -> Mesh {
        // axis: 0 = YZ plane (x -> -x), 1 = XZ, 2 = XY
        func m(_ v: Vec3) -> Vec3 {
            switch axis {
            case 0: return Vec3(-v.x, v.y, v.z)
            case 1: return Vec3(v.x, -v.y, v.z)
            default: return Vec3(v.x, v.y, -v.z)
            }
        }
        var idx: [UInt32] = []
        for t in 0..<triangleCount {
            idx += [indices[t * 3], indices[t * 3 + 2], indices[t * 3 + 1]]
        }
        return Mesh(vertices: vertices.map(m), indices: idx)
    }
    /// Expanded triangle soup with smooth normals for display: vertices are
    /// duplicated per corner, but normals are shared across faces whose
    /// dihedral angle is below `creaseDegrees` — curved surfaces shade
    /// smooth, sharp edges stay sharp. Triangles are only faceted at export.
    public func displaySoup(creaseDegrees: Double = 60) -> (positions: [Vec3], normals: [Vec3]) {
        let m = welded()
        let faceN = m.faceNormals()
        // Relative triangle areas (the cross product's length is
        // 2×area — the factor cancels in the normalized average).
        // The smoothed normal is AREA-WEIGHTED: a big facet speaks
        // louder than a tessellation sliver, so coarse fans and
        // uneven triangulation no longer tilt the shading.
        var faceW: [Double] = []
        faceW.reserveCapacity(m.triangleCount)
        for t in 0..<m.triangleCount {
            let a = m.vertices[Int(m.indices[t * 3])]
            let b = m.vertices[Int(m.indices[t * 3 + 1])]
            let c = m.vertices[Int(m.indices[t * 3 + 2])]
            faceW.append((b - a).cross(c - a).length)
        }
        let cosLimit = cos(creaseDegrees * .pi / 180)
        // For every (vertex, face) corner, the smoothed normal is the
        // average of face normals at that vertex whose angle to this
        // face is small. The default crease is 60°: gentle curvature
        // (fillets, large-radius curves, coarse tessellation steps)
        // blends fully smooth, while manufactured sharp edges — 90°
        // box corners, 67.5° octagon faces — stay crisp.
        var vertexFaces: [Int: [Int]] = [:]
        vertexFaces.reserveCapacity(m.vertices.count * 2)
        for t in 0..<m.triangleCount {
            for k in 0..<3 { vertexFaces[Int(m.indices[t * 3 + k]), default: []].append(t) }
        }
        var positions: [Vec3] = []
        var normals: [Vec3] = []
        positions.reserveCapacity(m.triangleCount * 3)
        normals.reserveCapacity(m.triangleCount * 3)
        for t in 0..<m.triangleCount {
            for k in 0..<3 {
                let vi = Int(m.indices[t * 3 + k])
                positions.append(m.vertices[vi])
                var sum = Vec3.zero
                for f in vertexFaces[vi] ?? [] where faceN[f].dot(faceN[t]) >= cosLimit {
                    sum = sum + faceN[f] * faceW[f]
                }
                // A degenerate (zero-area) face has no normal: its own
                // face normal is the zero vector, and emitting that
                // hands the renderer a non-unit normal (2026-10-26
                // sweep). Fall back to an arbitrary unit axis.
                if sum.length > 1e-12 { normals.append(sum.normalized) }
                else if faceN[t].length > 1e-12 { normals.append(faceN[t]) }
                else { normals.append(Vec3(0, 0, 1)) }
            }
        }
        return (positions, normals)
    }
    public mutating func append(_ other: Mesh) {
        // Keep the cache exact without a rescan when both sides are
        // clean: bounds union + signed-volume sum are O(1).
        let bothClean = !metadataDirty && !other.metadataDirty
        let otherBounds = other.cachedBounds
        let otherVolume = other.cachedSignedVolume
        let base = UInt32(vertices.count)
        vertices += other.vertices
        indices += other.indices.map { $0 + base }
        if bothClean {
            if !otherBounds.isEmpty {
                cachedBounds.include(otherBounds.min)
                cachedBounds.include(otherBounds.max)
            }
            cachedSignedVolume += otherVolume
            metadataDirty = false
        }
    }
    /// Per-face normals (flat shading).
    public func faceNormals() -> [Vec3] {
        (0..<triangleCount).map { t in
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            return (b - a).cross(c - a).normalized
        }
    }
}

/// Builds meshes with consistent outward winding (CCW seen from outside).
/// Accumulates into private arrays and vends the finished mesh through
/// `Mesh(vertices:indices:)` so its bounds/volume cache is populated.
public struct MeshBuilder {
    private var verts: [Vec3] = []
    private var idx: [UInt32] = []
    public init() {}
    public var mesh: Mesh { Mesh(vertices: verts, indices: idx) }
    @discardableResult
    public mutating func vertex(_ v: Vec3) -> UInt32 {
        verts.append(v)
        return UInt32(verts.count - 1)
    }
    public mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        idx += [a, b, c]
    }
    /// Quad as two triangles; corners must be CCW seen from outside.
    public mutating func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
        triangle(a, b, c); triangle(a, c, d)
    }
    public mutating func addMesh(_ m: Mesh) {
        let base = UInt32(verts.count)
        verts += m.vertices
        idx += m.indices.map { $0 + base }
    }
}

public extension Mesh {
    /// Point-in-solid test: cast a ray and count triangle crossings
    /// (odd = inside). The direction is deliberately off-axis so the ray
    /// does not run exactly along the diagonals/edges that box-like
    /// meshes are full of (a +Z ray through a box centre hits the top
    /// face's diagonal and double-counts). For closed meshes.
    func contains(_ point: Vec3) -> Bool {
        let dir = Vec3(0.123, 0.231, 1)
        var crossings = 0
        for t in 0..<triangleCount {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            // Moller-Trumbore.
            let e1 = b - a, e2 = c - a
            let pv = dir.cross(e2)
            let det = e1.dot(pv)
            if abs(det) < 1e-12 { continue }
            let inv = 1 / det
            let tv = point - a
            let u = tv.dot(pv) * inv
            if u < -1e-9 || u > 1 + 1e-9 { continue }
            let qv = tv.cross(e1)
            let v = dir.dot(qv) * inv
            if v < -1e-9 || u + v > 1 + 1e-9 { continue }
            let dist = e2.dot(qv) * inv
            if dist > 1e-9 { crossings += 1 }
        }
        return crossings % 2 == 1
    }
}
