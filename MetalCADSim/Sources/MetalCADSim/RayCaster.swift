import Foundation
import MetalCADKit

/// One ray/triangle intersection. `t` is measured in units of the
/// direction vector's length (with a unit direction, `t` is the
/// distance from the origin, in mm).
public struct RayHit: Equatable {
    public var t: Double
    public var point: Vec3
    /// The triangle's geometric normal (mesh winding orientation),
    /// unit length; `.zero` for a degenerate triangle.
    public var normal: Vec3
    public var triangleIndex: Int

    public init(t: Double, point: Vec3, normal: Vec3, triangleIndex: Int) {
        self.t = t
        self.point = point
        self.normal = normal
        self.triangleIndex = triangleIndex
    }
}

/// Ray queries against a kit `Mesh`, accelerated by an AABB BVH built
/// once at init. Intersection is Möller–Trumbore, double-sided (no
/// back-face culling — matching the kit's `Mesh.contains`), with the
/// same epsilon discipline: barycentric coordinates may overshoot by
/// 1e-9, hits must have t > 1e-9.
///
/// Determinism: the BVH is built by median splits with triangle-index
/// tie-breaking, and queries test triangles in a fixed order, so
/// identical inputs give bit-identical results.
public struct RayCaster {
    private let vertices: [Vec3]
    private let indices: [UInt32]
    private var triOrder: [Int] = []
    private var nodes: [Node] = []

    /// Intersections closer together than this (in t units) are merged
    /// into one by `allHits` — a ray crossing exactly on a shared edge
    /// registers on both adjacent triangles at (numerically) the same
    /// t, and parity counting must see one crossing, not two.
    public static let hitMergeTolerance = 1e-7

    private struct Node {
        var min: Vec3
        var max: Vec3
        var left: Int = -1    // child node index, -1 = leaf
        var right: Int = -1
        var start: Int = 0    // leaf: range in triOrder
        var count: Int = 0
        var isLeaf: Bool { left < 0 }
    }

    public init(mesh: Mesh) {
        vertices = mesh.vertices
        indices = mesh.indices
        let n = mesh.triangleCount
        guard n > 0 else { return }
        triOrder = Array(0..<n)
        // Triangle bounds + centroids for the build.
        var triMin = [Vec3](repeating: .zero, count: n)
        var triMax = [Vec3](repeating: .zero, count: n)
        var centroid = [Vec3](repeating: .zero, count: n)
        for t in 0..<n {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            let lo = Vec3(min(a.x, b.x, c.x), min(a.y, b.y, c.y), min(a.z, b.z, c.z))
            let hi = Vec3(max(a.x, b.x, c.x), max(a.y, b.y, c.y), max(a.z, b.z, c.z))
            triMin[t] = lo
            triMax[t] = hi
            centroid[t] = (a + b + c) * (1.0 / 3.0)
        }
        nodes.reserveCapacity(2 * n)
        _ = build(range: 0..<n, triMin: triMin, triMax: triMax, centroid: centroid)
    }

    private mutating func build(range: Range<Int>, triMin: [Vec3], triMax: [Vec3],
                                centroid: [Vec3]) -> Int {
        var lo = Vec3(.infinity, .infinity, .infinity)
        var hi = Vec3(-.infinity, -.infinity, -.infinity)
        var cLo = Vec3(.infinity, .infinity, .infinity)
        var cHi = Vec3(-.infinity, -.infinity, -.infinity)
        for i in range {
            let t = triOrder[i]
            lo = Vec3(min(lo.x, triMin[t].x), min(lo.y, triMin[t].y), min(lo.z, triMin[t].z))
            hi = Vec3(max(hi.x, triMax[t].x), max(hi.y, triMax[t].y), max(hi.z, triMax[t].z))
            let c = centroid[t]
            cLo = Vec3(min(cLo.x, c.x), min(cLo.y, c.y), min(cLo.z, c.z))
            cHi = Vec3(max(cHi.x, c.x), max(cHi.y, c.y), max(cHi.z, c.z))
        }
        let nodeIndex = nodes.count
        nodes.append(Node(min: lo, max: hi, start: range.lowerBound, count: range.count))
        let leafSize = 8
        if range.count <= leafSize { return nodeIndex }
        // Split at the median along the longest centroid axis.
        let ext = cHi - cLo
        let axis = (ext.x >= ext.y && ext.x >= ext.z) ? 0 : (ext.y >= ext.z ? 1 : 2)
        func key(_ t: Int) -> Double {
            let c = centroid[t]
            return axis == 0 ? c.x : (axis == 1 ? c.y : c.z)
        }
        let sorted = range.map { triOrder[$0] }.sorted {
            let ka = key($0), kb = key($1)
            return ka != kb ? ka < kb : $0 < $1
        }
        for (offset, t) in sorted.enumerated() { triOrder[range.lowerBound + offset] = t }
        let mid = range.lowerBound + range.count / 2
        let left = build(range: range.lowerBound..<mid, triMin: triMin, triMax: triMax, centroid: centroid)
        let right = build(range: mid..<range.upperBound, triMin: triMin, triMax: triMax, centroid: centroid)
        nodes[nodeIndex].left = left
        nodes[nodeIndex].right = right
        nodes[nodeIndex].count = 0
        return nodeIndex
    }

    // MARK: Queries

    /// The nearest intersection with t > 1e-9, or nil. A zero
    /// direction hits nothing.
    public func closestHit(origin: Vec3, direction: Vec3) -> RayHit? {
        guard !nodes.isEmpty, direction.length > 0 else { return nil }
        var bestT = Double.infinity
        var bestTri = -1
        var stack = [0]
        while let ni = stack.popLast() {
            let node = nodes[ni]
            guard let tNear = rayBoxTNear(origin: origin, direction: direction,
                                          min: node.min, max: node.max),
                  tNear <= bestT else { continue }
            if node.isLeaf {
                for i in node.start..<(node.start + node.count) {
                    let t = triOrder[i]
                    if let hit = intersect(origin: origin, direction: direction, triangle: t),
                       hit < bestT {
                        bestT = hit
                        bestTri = t
                    }
                }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        guard bestTri >= 0 else { return nil }
        let a = vertices[Int(indices[bestTri * 3])]
        let b = vertices[Int(indices[bestTri * 3 + 1])]
        let c = vertices[Int(indices[bestTri * 3 + 2])]
        return RayHit(t: bestT,
                      point: origin + direction * bestT,
                      normal: (b - a).cross(c - a).normalized,
                      triangleIndex: bestTri)
    }

    /// All intersection distances along the ray, sorted ascending,
    /// with hits closer than `hitMergeTolerance` merged into one (see
    /// the tolerance's docs — this is what makes parity counting on
    /// the result correct across shared edges).
    public func allHits(origin: Vec3, direction: Vec3) -> [Double] {
        guard !nodes.isEmpty, direction.length > 0 else { return [] }
        var ts: [Double] = []
        var stack = [0]
        while let ni = stack.popLast() {
            let node = nodes[ni]
            guard rayBoxTNear(origin: origin, direction: direction,
                              min: node.min, max: node.max) != nil else { continue }
            if node.isLeaf {
                for i in node.start..<(node.start + node.count) {
                    if let hit = intersect(origin: origin, direction: direction, triangle: triOrder[i]) {
                        ts.append(hit)
                    }
                }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        ts.sort()
        var merged: [Double] = []
        merged.reserveCapacity(ts.count)
        for t in ts {
            if let last = merged.last, t - last <= Self.hitMergeTolerance { continue }
            merged.append(t)
        }
        return merged
    }

    // MARK: Intersection primitives

    /// Möller–Trumbore, double-sided. Returns t (> 1e-9) or nil.
    private func intersect(origin: Vec3, direction: Vec3, triangle t: Int) -> Double? {
        let a = vertices[Int(indices[t * 3])]
        let b = vertices[Int(indices[t * 3 + 1])]
        let c = vertices[Int(indices[t * 3 + 2])]
        let e1 = b - a
        let e2 = c - a
        let pv = direction.cross(e2)
        let det = e1.dot(pv)
        if abs(det) < 1e-12 { return nil }
        let inv = 1 / det
        let tv = origin - a
        let u = tv.dot(pv) * inv
        if u < -1e-9 || u > 1 + 1e-9 { return nil }
        let qv = tv.cross(e1)
        let v = direction.dot(qv) * inv
        if v < -1e-9 || u + v > 1 + 1e-9 { return nil }
        let dist = e2.dot(qv) * inv
        if dist <= 1e-9 { return nil }
        return dist
    }

    /// Slab test: the ray's entry distance into the box, if the box is
    /// intersected at any t ≥ 0 (entry distance is 0 when the origin
    /// is inside). nil = miss.
    private func rayBoxTNear(origin: Vec3, direction: Vec3, min lo: Vec3, max hi: Vec3) -> Double? {
        var tNear = 0.0
        var tFar = Double.infinity
        for axis in 0..<3 {
            let o = axis == 0 ? origin.x : (axis == 1 ? origin.y : origin.z)
            let d = axis == 0 ? direction.x : (axis == 1 ? direction.y : direction.z)
            let mn = axis == 0 ? lo.x : (axis == 1 ? lo.y : lo.z)
            let mx = axis == 0 ? hi.x : (axis == 1 ? hi.y : hi.z)
            if abs(d) < 1e-300 {
                if o < mn || o > mx { return nil }
                continue
            }
            var t0 = (mn - o) / d
            var t1 = (mx - o) / d
            if t0 > t1 { swap(&t0, &t1) }
            tNear = max(tNear, t0)
            tFar = min(tFar, t1)
            if tNear > tFar { return nil }
        }
        return tNear
    }
}
