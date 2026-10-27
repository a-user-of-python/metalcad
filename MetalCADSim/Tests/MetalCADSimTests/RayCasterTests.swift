import XCTest
import MetalCADKit
@testable import MetalCADSim

/// Deterministic pseudo-random source (64-bit LCG) — tests must not
/// depend on system randomness.
private struct LCG {
    var state: UInt64
    mutating func nextDouble() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / 9007199254740992.0  // 2^53
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * nextDouble()
    }
}

/// Reference Möller–Trumbore scan over every triangle (the definition
/// the BVH has to agree with).
private func bruteForceClosestT(mesh: Mesh, origin: Vec3, direction: Vec3) -> Double? {
    var best: Double? = nil
    for t in 0..<mesh.triangleCount {
        let a = mesh.vertices[Int(mesh.indices[t * 3])]
        let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])]
        let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
        let e1 = b - a, e2 = c - a
        let pv = direction.cross(e2)
        let det = e1.dot(pv)
        if abs(det) < 1e-12 { continue }
        let inv = 1 / det
        let tv = origin - a
        let u = tv.dot(pv) * inv
        if u < -1e-9 || u > 1 + 1e-9 { continue }
        let qv = tv.cross(e1)
        let v = direction.dot(qv) * inv
        if v < -1e-9 || u + v > 1 + 1e-9 { continue }
        let dist = e2.dot(qv) * inv
        if dist <= 1e-9 { continue }
        if best == nil || dist < best! { best = dist }
    }
    return best
}

final class RayCasterTests: XCTestCase {

    func testBoxAllHitsSortedAndEdgeMerged() throws {
        // Box 10×10×10 sits on z=0, x/y centered. The ray at (0,0)
        // runs exactly along the triangulation diagonal of the top
        // and bottom faces — the shared-edge double hit must merge
        // into a single crossing per face.
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let caster = RayCaster(mesh: mesh)
        let hits = caster.allHits(origin: Vec3(0, 0, -5), direction: Vec3(0, 0, 1))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0], 5, accuracy: 1e-9)
        XCTAssertEqual(hits[1], 15, accuracy: 1e-9)
    }

    func testBoxClosestHitPointAndNormal() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let caster = RayCaster(mesh: mesh)
        let hit = caster.closestHit(origin: Vec3(0, 0, -5), direction: Vec3(0, 0, 1))
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!.t, 5, accuracy: 1e-9)
        XCTAssertEqual(hit!.point.z, 0, accuracy: 1e-9)
        XCTAssertEqual(hit!.normal.z, -1, accuracy: 1e-9, "bottom face normal points down")
        // A ray that misses entirely.
        XCTAssertNil(caster.closestHit(origin: Vec3(100, 0, -5), direction: Vec3(0, 0, 1)))
        XCTAssertTrue(caster.allHits(origin: Vec3(100, 0, -5), direction: Vec3(0, 0, 1)).isEmpty)
    }

    func testTorusHoleAndTubeAllHits() throws {
        let mesh = try Tessellation.torus(ringRadius: 20, tubeRadius: 8)
        let caster = RayCaster(mesh: mesh)
        // Straight through the center hole: no crossings.
        XCTAssertTrue(caster.allHits(origin: Vec3(0, 0, -50), direction: Vec3(0, 0, 1)).isEmpty)
        // Through the tube at (20, 0): enter z=-8, exit z=+8.
        let hits = caster.allHits(origin: Vec3(20, 0, -50), direction: Vec3(0, 0, 1))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0], 42, accuracy: 1e-6)
        XCTAssertEqual(hits[1], 58, accuracy: 1e-6)
    }

    func testEmptyMeshAndZeroDirection() {
        let caster = RayCaster(mesh: Mesh())
        XCTAssertNil(caster.closestHit(origin: .zero, direction: Vec3(0, 0, 1)))
        XCTAssertTrue(caster.allHits(origin: .zero, direction: Vec3(0, 0, 1)).isEmpty)
    }

    /// The BVH must agree with a brute-force scan on hit/miss and on
    /// distance, over ≥200 deterministic pseudo-random rays.
    func testBVHAgreesWithBruteForce() throws {
        let mesh = try Tessellation.torus(ringRadius: 20, tubeRadius: 8,
                                          segments: 96, sides: 48)
        let caster = RayCaster(mesh: mesh)
        var rng = LCG(state: 0x2545F4914F6CDD1D)
        var hitsSeen = 0
        var missesSeen = 0
        for _ in 0..<240 {
            // Origin on a sphere of radius 60 around the torus.
            let theta = rng.range(0, 2 * Double.pi)
            let z = rng.range(-1, 1)
            let r = (1 - z * z).squareRoot()
            let origin = Vec3(60 * r * cos(theta), 60 * r * sin(theta), 60 * z)
            let target = Vec3(rng.range(-15, 15), rng.range(-15, 15), rng.range(-8, 8))
            let direction = (target - origin).normalized
            let brute = bruteForceClosestT(mesh: mesh, origin: origin, direction: direction)
            let fast = caster.closestHit(origin: origin, direction: direction)
            switch (brute, fast) {
            case (nil, nil):
                missesSeen += 1
            case let (b?, f?):
                hitsSeen += 1
                XCTAssertEqual(f.t, b, accuracy: 1e-9 * max(1, b),
                               "BVH/brute-force distance mismatch")
                XCTAssertEqual(f.point.distance(to: origin + direction * b), 0,
                               accuracy: 1e-6, "hit point must lie on the ray")
            default:
                XCTFail("BVH/brute-force hit disagreement: brute=\(String(describing: brute)), bvh=\(String(describing: fast))")
            }
        }
        XCTAssertGreaterThan(hitsSeen, 100, "test should exercise plenty of hits")
        XCTAssertGreaterThan(missesSeen, 0, "test should exercise some misses")
    }
}
