import Foundation

// MARK: - BSP CSG (after Evan Wallace's csg.js, reimplemented in Swift)
//
// Solid geometry on watertight meshes. Polygons are convex (triangles from
// our meshes; splits produce convex fans which we re-triangulate).

struct CSGPlane {
    var normal: Vec3
    var w: Double  // normal · p = w for points on the plane
    static let eps = 1e-5

    init(normal: Vec3, w: Double) { self.normal = normal; self.w = w }
    init(a: Vec3, b: Vec3, c: Vec3) {
        let n = (b - a).cross(c - a).normalized
        self.normal = n
        self.w = n.dot(a)
    }
    func flipped() -> CSGPlane { CSGPlane(normal: normal * -1, w: -w) }
    func signedDistance(_ p: Vec3) -> Double { normal.dot(p) - w }

    /// Split a convex polygon by this plane.
    /// Returns (front, back, coplanarFront, coplanarBack) vertex lists.
    func splitPolygon(_ poly: [Vec3]) -> (front: [Vec3]?, back: [Vec3]?, coFront: [Vec3]?, coBack: [Vec3]?) {
        let COPLANAR = 0, FRONT = 1, BACK = 2, SPANNING = 3
        var polygonType = 0
        var types: [Int] = []
        for v in poly {
            let d = signedDistance(v)
            let t = abs(d) < CSGPlane.eps ? COPLANAR : (d > 0 ? FRONT : BACK)
            types.append(t)
            polygonType |= t
        }
        switch polygonType {
        case COPLANAR:
            return normal.dot(CSGPlane(a: poly[0], b: poly[1], c: poly[2]).normal) > 0
                ? (nil, nil, poly, nil) : (nil, nil, nil, poly)
        case FRONT: return (poly, nil, nil, nil)
        case BACK: return (nil, poly, nil, nil)
        default:
            var f: [Vec3] = [], b: [Vec3] = []
            for i in poly.indices {
                let j = (i + 1) % poly.count
                let ti = types[i], tj = types[j]
                let vi = poly[i], vj = poly[j]
                if ti != BACK { f.append(vi) }
                if ti != FRONT { b.append(vi) }
                if (ti | tj) == SPANNING {
                    let denom = normal.dot(vj - vi)
                    if abs(denom) > 1e-12 {
                        let t = (w - normal.dot(vi)) / denom
                        let v = vi + (vj - vi) * t
                        f.append(v); b.append(v)
                    }
                    // Near-parallel crossing: skip the interpolated point
                    // rather than emitting a wild one (huge t) that makes
                    // BSP builds re-span the same plane forever.
                }
            }
            return (f.count >= 3 ? f : nil, b.count >= 3 ? b : nil, nil, nil)
        }
    }
}

final class CSGNode {
    var plane: CSGPlane?
    var front: CSGNode?
    var back: CSGNode?
    var polygons: [[Vec3]] = []

    init(polygons: [[Vec3]] = []) { build(polygons) }

    func clone() -> CSGNode {
        let n = CSGNode()
        n.plane = plane
        n.front = front?.clone()
        n.back = back?.clone()
        n.polygons = polygons
        return n
    }

    func invert() {
        // Reversing each polygon's vertex order flips its winding/normal.
        for i in polygons.indices { polygons[i].reverse() }
        plane = plane?.flipped()
        front?.invert()
        back?.invert()
        swap(&front, &back)
    }

    func clipPolygons(_ input: [[Vec3]]) -> [[Vec3]] {
        guard let plane else { return input }
        var frontPolys: [[Vec3]] = []
        var backPolys: [[Vec3]] = []
        for poly in input {
            let r = plane.splitPolygon(poly)
            if let f = r.front { frontPolys.append(f) }
            if let cf = r.coFront { frontPolys.append(cf) }
            if let b = r.back { backPolys.append(b) }
            if let cb = r.coBack { backPolys.append(cb) }
        }
        if let front { frontPolys = front.clipPolygons(frontPolys) }
        if let back { backPolys = back.clipPolygons(backPolys) } else { backPolys = [] }
        return frontPolys + backPolys
    }

    func clipTo(_ other: CSGNode) {
        polygons = other.clipPolygons(polygons)
        front?.clipTo(other)
        back?.clipTo(other)
    }

    func allPolygons() -> [[Vec3]] {
        var out = polygons
        if let front { out += front.allPolygons() }
        if let back { out += back.allPolygons() }
        return out
    }

    func build(_ input: [[Vec3]]) { build(input, depth: 0) }

    private func build(_ input: [[Vec3]], depth: Int) {
        guard !input.isEmpty else { return }
        // Drop slivers: zero-area pieces poison plane math and make the
        // recursion re-span forever.
        let input = input.filter { poly in
            poly.count >= 3 && (poly[1] - poly[0]).cross(poly[2] - poly[0]).length > 1e-12
        }
        guard !input.isEmpty else { return }
        if depth > 512 {
            // Pathological input: store rather than recurse forever.
            // Clipping stays conservative (may keep extra fragments)
            // instead of crashing.
            polygons += input
            return
        }
        if plane == nil {
            let p = input[0]
            plane = CSGPlane(a: p[0], b: p[1], c: p[2])
        }
        var frontPolys: [[Vec3]] = []
        var backPolys: [[Vec3]] = []
        for poly in input {
            let r = plane!.splitPolygon(poly)
            if let f = r.front { frontPolys.append(f) }
            if let cf = r.coFront { polygons.append(cf) }
            if let cb = r.coBack { polygons.append(cb) }
            if let b = r.back { backPolys.append(b) }
        }
        if !frontPolys.isEmpty {
            if front == nil { front = CSGNode() }
            front!.build(frontPolys, depth: depth + 1)
        }
        if !backPolys.isEmpty {
            if back == nil { back = CSGNode() }
            back!.build(backPolys, depth: depth + 1)
        }
    }
}

/// Boolean operations on meshes. Operands are welded first; results are
/// welded triangle meshes. Throws FT405/FT406/KN codes per ERRORS.md.
public enum CSG {
    static let maxTriangles = 300_000

    static func polygons(of mesh: Mesh) -> [[Vec3]] {
        let m = mesh.welded()
        var out: [[Vec3]] = []
        for t in 0..<m.triangleCount {
            out.append([m.vertices[Int(m.indices[t * 3])],
                        m.vertices[Int(m.indices[t * 3 + 1])],
                        m.vertices[Int(m.indices[t * 3 + 2])]])
        }
        return out
    }

    static func mesh(from polygons: [[Vec3]]) -> Mesh {
        var b = MeshBuilder()
        for poly in polygons where poly.count >= 3 {
            // Fan triangulation (polygons from BSP splits are convex).
            let v0 = b.vertex(poly[0])
            var prev = b.vertex(poly[1])
            for i in 2..<poly.count {
                let cur = b.vertex(poly[i])
                b.triangle(v0, prev, cur)
                prev = cur
            }
        }
        return b.mesh.welded().stitched()
    }

    static func checked(_ m: Mesh, _ op: String) throws {
        if m.hasNaN { throw CADError.kernelShapeInvalid("\(op): NaN vertices") }
        guard m.triangleCount <= maxTriangles else {
            throw CADError.booleanFailed("\(op): \(m.triangleCount) triangles exceeds the \(maxTriangles) limit")
        }
    }

    /// BSP classification uses an ABSOLUTE epsilon (1e-5) and the
    /// weld/stitch passes absolute tolerances, so booleans on parts
    /// far below that scale dissolve: two overlapping 1e-4 mm boxes
    /// unioned to 47% wrong volume (2026-10-26 sweep). When BOTH
    /// operands are tiny, run the op in a normalized space
    /// (characteristic length → 1) and scale the result back. Normal-
    /// scale parts take the exact code path they always did.
    private static func tinyNormalization(_ a: Mesh, _ b: Mesh) -> Double? {
        func diag(_ m: Mesh) -> Double { m.bounds.size.length }
        let d = max(diag(a), diag(b))
        guard d > 0, d < 0.01 else { return nil }
        return 1.0 / d
    }

    private static func scaledUniform(_ m: Mesh, by s: Double) -> Mesh {
        Mesh(vertices: m.vertices.map { $0 * s }, indices: m.indices)
    }

    public static func union(_ a: Mesh, _ b: Mesh) throws -> Mesh {
        try checked(a, "union"); try checked(b, "union")
        if a.triangleCount == 0 { return b }
        if b.triangleCount == 0 { return a }
        if let s = tinyNormalization(a, b) {
            return scaledUniform(try unionImpl(scaledUniform(a, by: s), scaledUniform(b, by: s)), by: 1 / s)
        }
        return try unionImpl(a, b)
    }

    private static func unionImpl(_ a: Mesh, _ b: Mesh) throws -> Mesh {
        let na = CSGNode(polygons: polygons(of: a))
        let nb = CSGNode(polygons: polygons(of: b))
        na.clipTo(nb)
        nb.clipTo(na)
        nb.invert()
        nb.clipTo(na)
        nb.invert()
        na.build(nb.allPolygons())
        return mesh(from: na.allPolygons())
    }

    public static func subtract(_ a: Mesh, _ b: Mesh) throws -> Mesh {
        try checked(a, "cut"); try checked(b, "cut")
        if a.triangleCount == 0 || b.triangleCount == 0 { return a }
        if let s = tinyNormalization(a, b) {
            return scaledUniform(try subtractImpl(scaledUniform(a, by: s), scaledUniform(b, by: s)), by: 1 / s)
        }
        return try subtractImpl(a, b)
    }

    private static func subtractImpl(_ a: Mesh, _ b: Mesh) throws -> Mesh {
        let na = CSGNode(polygons: polygons(of: a))
        let nb = CSGNode(polygons: polygons(of: b))
        na.invert()
        na.clipTo(nb)
        nb.clipTo(na)
        nb.invert()
        nb.clipTo(na)
        nb.invert()
        na.build(nb.allPolygons())
        na.invert()
        let result = mesh(from: na.allPolygons())
        return result
    }

    public static func intersect(_ a: Mesh, _ b: Mesh) throws -> Mesh {
        try checked(a, "intersect"); try checked(b, "intersect")
        if a.triangleCount == 0 || b.triangleCount == 0 { return Mesh() }
        if let s = tinyNormalization(a, b) {
            return scaledUniform(try intersectImpl(scaledUniform(a, by: s), scaledUniform(b, by: s)), by: 1 / s)
        }
        return try intersectImpl(a, b)
    }

    private static func intersectImpl(_ a: Mesh, _ b: Mesh) throws -> Mesh {
        let na = CSGNode(polygons: polygons(of: a))
        let nb = CSGNode(polygons: polygons(of: b))
        na.invert()
        nb.clipTo(na)
        nb.invert()
        na.clipTo(nb)
        nb.clipTo(na)
        na.build(nb.allPolygons())
        na.invert()
        return mesh(from: na.allPolygons())
    }
}

public extension Mesh {
    /// Section view helper: keep only the half of the mesh on the side the
    /// normal points to, cut exactly at the plane through `through`.
    func sectioned(normal nIn: Vec3, through: Vec3, size: Double = 2000) throws -> Mesh {
        let n = nIn.normalized
        let helper = abs(n.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
        let x = helper.cross(n).normalized
        let y = n.cross(x).normalized
        let c = through + n * (size / 2)
        let s = size / 2
        func corner(_ sx: Double, _ sy: Double, _ sz: Double) -> Vec3 {
            c + x * (sx * s) + y * (sy * s) + n * (sz * s)
        }
        // Cube corners: (±1, ±1, ±1); faces chosen so the -n face sits on
        // the section plane.
        let v: [Vec3] = [
            corner(-1, -1, -1), corner(1, -1, -1), corner(1, 1, -1), corner(-1, 1, -1),
            corner(-1, -1, 1), corner(1, -1, 1), corner(1, 1, 1), corner(-1, 1, 1),
        ]
        let faces: [[Int]] = [
            [0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7],
        ]
        var b = MeshBuilder()
        let idx = v.map { b.vertex($0) }
        for f in faces { b.quad(idx[f[0]], idx[f[1]], idx[f[2]], idx[f[3]]) }
        var cube = b.mesh
        if cube.signedVolume < 0 {
            var ii: [UInt32] = []
            for t in 0..<cube.triangleCount {
                ii += [cube.indices[t * 3], cube.indices[t * 3 + 2], cube.indices[t * 3 + 1]]
            }
            cube = Mesh(vertices: cube.vertices, indices: ii)
        }
        return try CSG.intersect(self, cube)
    }
}
