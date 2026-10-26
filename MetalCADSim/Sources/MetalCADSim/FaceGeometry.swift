import Foundation
import MetalCADKit

/// Shared geometry helpers for the face-based sims (Structural,
/// WaterFlow, Thermal): resolving a kit `PlanarFace` to mesh
/// triangles and measuring point-to-triangle distance. Internal —
/// the sims expose their own result types; this is the single home
/// for logic they used to duplicate.
enum FaceGeometry {

    /// Distance from point `p` to the triangle (a, b, c) — closest
    /// point on the triangle (Ericson, *Real-Time Collision
    /// Detection* §5.1.5), returning the distance to it.
    static func pointTriangleDistance(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = ab.dot(ap), d2 = ac.dot(ap)
        if d1 <= 0, d2 <= 0 { return ap.length }                       // vertex a region
        let bp = p - b
        let d3 = ab.dot(bp), d4 = ac.dot(bp)
        if d3 >= 0, d4 <= d3 { return bp.length }                      // vertex b region
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {                                 // edge ab region
            let v = d1 / (d1 - d3)
            return (p - (a + ab * v)).length
        }
        let cp = p - c
        let d5 = ab.dot(cp), d6 = ac.dot(cp)
        if d6 >= 0, d5 <= d6 { return cp.length }                      // vertex c region
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {                                 // edge ac region
            let w = d2 / (d2 - d6)
            return (p - (a + ac * w)).length
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0, (d4 - d3) >= 0, (d5 - d6) >= 0 {                   // edge bc region
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return (p - (b + (c - b) * w)).length
        }
        // Inside the face region: perpendicular distance to the plane.
        let n = ab.cross(ac)
        return abs((p - a).dot(n)) / n.length
    }

    /// Resolve a `PlanarFace` to its triangles (vertex positions in
    /// the welded grouped mesh) in `FaceExtractor.groupedFaces`
    /// output. Resolution rule: an exact `Equatable` match first;
    /// else the nearest geometric match — centroid within one cell
    /// (`h`), plane normals within cos⁻¹(0.99), area within 5% —
    /// choosing the smallest centroid distance. Returns nil when no
    /// grouped face matches either way (the face is not a planar
    /// face of this mesh).
    static func faceTriangles(
        of face: PlanarFace,
        in grouped: (faces: [PlanarFace], triangles: [[Int]], mesh: Mesh),
        cellSize h: Double
    ) -> [(Vec3, Vec3, Vec3)]? {
        var tris: [Int]? = nil
        if let idx = grouped.faces.firstIndex(of: face) {
            tris = grouped.triangles[idx]
        } else {
            var best: (score: Double, tris: [Int])? = nil
            for (fi, candidate) in grouped.faces.enumerated() {
                let centroidDist = candidate.centroid.distance(to: face.centroid)
                let normalDot = candidate.plane.normal.dot(face.plane.normal)
                let areaRel = abs(candidate.area - face.area) / max(face.area, 1e-12)
                if centroidDist < h, normalDot > 0.99, areaRel < 0.05 {
                    if best == nil || centroidDist < best!.score {
                        best = (centroidDist, grouped.triangles[fi])
                    }
                }
            }
            tris = best?.tris
        }
        guard let faceTris = tris else { return nil }
        return faceTris.map { t in
            (grouped.mesh.vertices[Int(grouped.mesh.indices[t * 3])],
             grouped.mesh.vertices[Int(grouped.mesh.indices[t * 3 + 1])],
             grouped.mesh.vertices[Int(grouped.mesh.indices[t * 3 + 2])])
        }
    }
}
