import XCTest
import MetalCADKit
@testable import MetalCADSim

final class StructuralTests: XCTestCase {

    private var aluminum: SimMaterial { SimMaterial.forKitMaterial("Aluminum 6061")! }

    /// The grouped face of `mesh` whose outward normal matches.
    private func face(of mesh: Mesh, normal: Vec3, file: StaticString = #filePath, line: UInt = #line) throws -> PlanarFace {
        let faces = FaceExtractor.groupedFaces(of: mesh).faces
        let found = faces.first { $0.plane.normal.dot(normal) > 0.9999 }
        guard let found else {
            XCTFail("no face with normal \(normal)", file: file, line: line)
            throw SimError.emptyMesh
        }
        return found
    }

    // MARK: 1. Tension bar — σ = F/A, δ = FL/(AE), equilibrium

    func testTensionBar() throws {
        // Bar 100 (x) × 10 × 10 mm, fixed at −x, pulled at +x.
        let mesh = try Tessellation.box(width: 100, depth: 10, height: 10)
        let fixed = try face(of: mesh, normal: Vec3(-1, 0, 0))
        let pulled = try face(of: mesh, normal: Vec3(1, 0, 0))
        var config = StructuralConfig(material: aluminum)
        config.cellSize = 2.5
        config.fixedFaces = [fixed]
        config.loads = [FaceLoad(face: pulled, force: 10_000, direction: Vec3(1, 0, 0))]
        let result = try Structural.solve(mesh: mesh, config: config)

        // Average σxx over the middle band of cells (Saint-Venant:
        // away from the corner-loaded ends) vs F/A = 100 MPa.
        let grid = result.grid
        var sum = 0.0, count = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx where grid.isSolid(x: i, y: j, z: k) {
                    let c = grid.cellCenter(x: i, y: j, z: k)
                    if abs(c.x) <= 10 {
                        sum += result.stressPerCell[grid.flatIndex(x: i, y: j, z: k)].xx
                        count += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(count, 0)
        let avgSigma = sum / Double(count)
        XCTAssertEqual(avgSigma, 100.0, accuracy: 5.0,
                       "average σxx \(avgSigma) MPa vs F/A = 100 MPa")

        // Tip displacement: mean u_x of nodes on the +x end plane vs
        // δ = FL/(AE) = 10000·100/(100·68900) ≈ 0.14509 mm.
        var tipSum = 0.0, tipCount = 0
        for (pos, disp) in zip(result.nodePositions, result.nodalDisplacements) where abs(pos.x - 50) < 1e-9 {
            tipSum += disp.x; tipCount += 1
        }
        XCTAssertGreaterThan(tipCount, 0)
        let tip = tipSum / Double(tipCount)
        let analyticTip = 10_000.0 * 100.0 / (100.0 * 68_900.0)
        XCTAssertEqual(tip, analyticTip, accuracy: analyticTip * 0.10,
                       "tip displacement \(tip) mm vs FL/(AE) = \(analyticTip) mm")

        // Equilibrium: reactions balance the applied load within 1%.
        XCTAssertEqual(result.totalReaction.x, -10_000, accuracy: 100)
        XCTAssertEqual(result.totalReaction.y, 0, accuracy: 100)
        XCTAssertEqual(result.totalReaction.z, 0, accuracy: 100)

        // Displaced mesh plumbing: at scale 100 the tip plane must
        // have moved ≈ δ·100 mm in +x.
        let displaced = result.displacedMesh(scale: 100)
        XCTAssertEqual(displaced.bounds.max.x, 50 + tip * 100, accuracy: 1.0)
    }

    // MARK: 2. Cantilever — Euler–Bernoulli tip deflection + root stress

    func testCantilever() throws {
        // Beam 100 (x) × 10 (y) × 10 (z) mm, fixed at −x, tip load −z.
        let mesh = try Tessellation.box(width: 100, depth: 10, height: 10)
        let fixed = try face(of: mesh, normal: Vec3(-1, 0, 0))
        let tipFace = try face(of: mesh, normal: Vec3(1, 0, 0))
        var config = StructuralConfig(material: aluminum)
        config.cellSize = 2.0
        config.tolerance = 1e-7
        config.fixedFaces = [fixed]
        config.loads = [FaceLoad(face: tipFace, force: 100, direction: Vec3(0, 0, -1))]
        let result = try Structural.solve(mesh: mesh, config: config)

        let inertia = 10.0 * 1000.0 / 12.0          // b·H³/12 = 833.33 mm⁴
        let ebTip = 100.0 * 1_000_000.0 / (3.0 * 68_900.0 * inertia)  // ≈ 0.5806 mm

        var tipSum = 0.0, tipCount = 0
        for (pos, disp) in zip(result.nodePositions, result.nodalDisplacements) where abs(pos.x - 50) < 1e-9 {
            tipSum += disp.z; tipCount += 1
        }
        XCTAssertGreaterThan(tipCount, 0)
        let tip = -tipSum / Double(tipCount)
        XCTAssertEqual(tip, ebTip, accuracy: ebTip * 0.20,
                       "tip deflection \(tip) mm vs Euler–Bernoulli \(ebTip) mm")

        // Root stress: |σxx| in the root-adjacent top/bottom layer vs
        // Mc/I = F·L·c/I = 60 MPa, within 25% (element centroids sit
        // h/2 inside the surface, so the centroid stress is expected
        // somewhat under the surface value).
        let grid = result.grid
        var extremes: [Double] = []
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx where grid.isSolid(x: i, y: j, z: k) {
                    let c = grid.cellCenter(x: i, y: j, z: k)
                    if abs(c.x - (-49)) < 1e-9 && (abs(c.z - 9) < 1e-9 || abs(c.z - 1) < 1e-9) {
                        extremes.append(result.stressPerCell[grid.flatIndex(x: i, y: j, z: k)].xx)
                    }
                }
            }
        }
        XCTAssertFalse(extremes.isEmpty)
        let rootSigma = extremes.map { abs($0) }.max() ?? 0
        let mcOverI = 100.0 * 100.0 * 5.0 / inertia   // 60 MPa
        XCTAssertEqual(rootSigma, mcOverI, accuracy: mcOverI * 0.25,
                       "root σxx \(rootSigma) MPa vs Mc/I = \(mcOverI) MPa")
    }

    // MARK: 3. Self-weight column — base σ ≈ ρgH

    func testSelfWeightColumn() throws {
        // Column 10 × 10 × 100 (z) mm standing on its bottom face.
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 100)
        let base = try face(of: mesh, normal: Vec3(0, 0, -1))
        var config = StructuralConfig(material: aluminum)
        config.cellSize = 5
        config.fixedFaces = [base]
        config.includeSelfWeight = true
        let result = try Structural.solve(mesh: mesh, config: config)

        // Average σzz over the bottom layer vs ρgH (σ at the layer's
        // centroid carries the weight above it, ≈ ρg(H − h/2); the
        // assertion targets ρgH within 10%).
        let grid = result.grid
        var sum = 0.0, count = 0
        for j in 0..<grid.ny {
            for i in 0..<grid.nx where grid.isSolid(x: i, y: j, z: 0) {
                sum += result.stressPerCell[grid.flatIndex(x: i, y: j, z: 0)].zz
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        let rhoGH = 2700.0 * 9.81 * 0.1 / 1e6   // Pa → MPa ≈ 0.002649
        let avgSigma = sum / Double(count)
        XCTAssertEqual(avgSigma, -rhoGH, accuracy: rhoGH * 0.10,
                       "base σzz \(avgSigma) MPa vs −ρgH = \(-rhoGH) MPa")

        // Reaction carries the full weight: ρ·V·g = 2.6487 N.
        let weight = 2700.0 * (10.0 * 10.0 * 100.0 * 1e-9) * 9.81
        XCTAssertEqual(result.totalReaction.z, weight, accuracy: weight * 0.02)
    }

    // MARK: 4. Zero load — all-zero result, infinite safety factor

    func testZeroLoad() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let fixed = try face(of: mesh, normal: Vec3(-1, 0, 0))
        var config = StructuralConfig(material: aluminum)
        config.cellSize = 2.5
        config.fixedFaces = [fixed]
        let result = try Structural.solve(mesh: mesh, config: config)
        XCTAssertEqual(result.maxVonMisesMPa, 0)
        XCTAssertEqual(result.maxDisplacementMM, 0)
        XCTAssertTrue(result.vonMisesPerCell.allSatisfy { $0 == 0 })
        XCTAssertTrue(result.nodalDisplacements.allSatisfy { $0 == .zero })
        XCTAssertEqual(result.totalReaction, .zero)
        XCTAssertEqual(result.safetyFactor, .infinity)
    }

    // MARK: 5. Errors

    func testNoFixedFacesThrows() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let config = StructuralConfig(material: aluminum)
        XCTAssertThrowsError(try Structural.solve(mesh: mesh, config: config)) { error in
            guard let e = error as? SimError else { return XCTFail("expected SimError, got \(error)") }
            XCTAssertEqual(e.code, "MSIM-CF001")
        }
    }

    func testLoadFaceFromDifferentMeshThrows() throws {
        let mesh = try Tessellation.box(width: 100, depth: 10, height: 10)
        let fixed = try face(of: mesh, normal: Vec3(-1, 0, 0))
        // Same shape, moved 1000 mm in +x: its faces are not faces of
        // the study mesh and must match no grid nodes.
        let other = mesh.translated(by: Vec3(1000, 0, 0))
        let foreign = try face(of: other, normal: Vec3(1, 0, 0))
        var config = StructuralConfig(material: aluminum)
        config.cellSize = 2.5
        config.fixedFaces = [fixed]
        config.loads = [FaceLoad(face: foreign, force: 100, direction: Vec3(1, 0, 0))]
        XCTAssertThrowsError(try Structural.solve(mesh: mesh, config: config)) { error in
            guard let e = error as? SimError else { return XCTFail("expected SimError, got \(error)") }
            XCTAssertEqual(e.code, "MSIM-IN004")
        }
    }

    // MARK: 6. MeshExtraction — box surface is closed and exact

    func testMeshExtractionBox() throws {
        // One-cell grid over the box: the surface is the box itself —
        // 12 triangles, 8 welded corners, closed, exact volume.
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let grid = try VoxelGrid(mesh: mesh, cellSize: 10)
        let surface = MeshExtraction.surfaceMesh(of: grid)
        XCTAssertEqual(surface.triangleCount, 12)
        XCTAssertEqual(surface.openEdgeCount, 0)
        XCTAssertEqual(surface.volume, grid.solidVolume, accuracy: 1e-9)
        XCTAssertGreaterThan(surface.signedVolume, 0, "winding must give outward normals")
        // Welded by construction: 8 corners only.
        XCTAssertEqual(surface.vertices.count, 8)
    }

    func testMeshExtractionFineGrid() throws {
        // At h = 1 the voxel surface keeps one quad per surface cell:
        // 6 sides × 100 cells = 600 quads = 1200 triangles, still
        // closed and volume-exact.
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let grid = try VoxelGrid(mesh: mesh, cellSize: 1)
        let surface = MeshExtraction.surfaceMesh(of: grid)
        XCTAssertEqual(surface.triangleCount, 1200)
        XCTAssertEqual(surface.openEdgeCount, 0)
        XCTAssertEqual(surface.volume, grid.solidVolume, accuracy: 1e-9)
        XCTAssertGreaterThan(surface.signedVolume, 0)
    }

    func testMeshExtractionSingleCell() throws {
        let mesh = try Tessellation.box(width: 1, depth: 1, height: 1)
        let grid = try VoxelGrid(mesh: mesh, cellSize: 1)
        let surface = MeshExtraction.surfaceMesh(of: grid)
        XCTAssertEqual(surface.triangleCount, 12)
        XCTAssertEqual(surface.openEdgeCount, 0)
        XCTAssertEqual(surface.volume, 1, accuracy: 1e-9)
    }
}
