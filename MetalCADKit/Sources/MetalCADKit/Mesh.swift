import Foundation

/// A triangle mesh — the v1 kernel's currency (tessellated solids).
public struct Mesh: Equatable {
    public var vertices: [Vec3] = []
    public var indices: [UInt32] = []   // triples
    public init() {}
    public init(vertices: [Vec3], indices: [UInt32]) {
        self.vertices = vertices; self.indices = indices
    }
    public var triangleCount: Int { indices.count / 3 }
    public var bounds: BoundingBox {
        var b = BoundingBox.empty
        for v in vertices { b.include(v) }
        return b
    }
    /// Signed volume via the divergence theorem. Positive = outward normals
    /// for a closed mesh.
    public var signedVolume: Double {
        var vol = 0.0
        for t in 0..<triangleCount {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            vol += a.dot(b.cross(c)) / 6.0
        }
        return vol
    }
    public var volume: Double { abs(signedVolume) }
    /// Count edges used by exactly one triangle (boundary/open edges).
    public var openEdgeCount: Int {
        var counts: [UInt64: Int] = [:]
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
        var map: [String: UInt32] = [:]
        var verts: [Vec3] = []
        var remap: [UInt32] = []
        for v in vertices {
            let key = "\(Int((v.x / tolerance).rounded())),\(Int((v.y / tolerance).rounded())),\(Int((v.z / tolerance).rounded()))"
            if let i = map[key] { remap.append(i) } else {
                let i = UInt32(verts.count)
                map[key] = i; verts.append(v); remap.append(i)
            }
        }
        return Mesh(vertices: verts, indices: indices.map { remap[Int($0)] })
    }
    public func translated(by d: Vec3) -> Mesh {
        Mesh(vertices: vertices.map { $0 + d }, indices: indices)
    }
    public mutating func append(_ other: Mesh) {
        let base = UInt32(vertices.count)
        vertices += other.vertices
        indices += other.indices.map { $0 + base }
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
public struct MeshBuilder {
    public var mesh = Mesh()
    public init() {}
    @discardableResult
    public mutating func vertex(_ v: Vec3) -> UInt32 {
        mesh.vertices.append(v)
        return UInt32(mesh.vertices.count - 1)
    }
    public mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        mesh.indices += [a, b, c]
    }
    /// Quad as two triangles; corners must be CCW seen from outside.
    public mutating func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
        triangle(a, b, c); triangle(a, c, d)
    }
    public mutating func addMesh(_ m: Mesh) { mesh.append(m) }
}
