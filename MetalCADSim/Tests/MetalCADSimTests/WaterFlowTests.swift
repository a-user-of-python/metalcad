import XCTest
import MetalCADKit
@testable import MetalCADSim

final class WaterFlowTests: XCTestCase {

    /// The grouped face of `mesh` whose outward normal matches.
    private func face(of mesh: Mesh, normal: Vec3,
                      file: StaticString = #filePath, line: UInt = #line) throws -> PlanarFace {
        let faces = FaceExtractor.groupedFaces(of: mesh).faces
        let found = faces.first { $0.plane.normal.dot(normal) > 0.9999 }
        guard let found else {
            XCTFail("no face with normal \(normal)", file: file, line: line)
            throw SimError.emptyMesh
        }
        return found
    }

    /// The grouped face with the given normal whose centroid sits
    /// at (about) the given z — disambiguates coplanar-direction
    /// faces at different heights (cup rim vs cup floor).
    private func face(of mesh: Mesh, normal: Vec3, centroidZ: Double,
                      file: StaticString = #filePath, line: UInt = #line) throws -> PlanarFace {
        let faces = FaceExtractor.groupedFaces(of: mesh).faces
        let found = faces.first {
            $0.plane.normal.dot(normal) > 0.9999 && abs($0.centroid.z - centroidZ) < 0.5
        }
        guard let found else {
            XCTFail("no face with normal \(normal) at z≈\(centroidZ)", file: file, line: line)
            throw SimError.emptyMesh
        }
        return found
    }

    private func flat(of grid: VoxelGrid, at point: Vec3) throws -> Int {
        guard let idx = grid.gridIndex(containing: point) else {
            throw SimError.emptyMesh
        }
        return grid.flatIndex(x: idx.x, y: idx.y, z: idx.z)
    }

    // MARK: 1. Through-hole along Z — fill, bottleneck, drain

    func testThroughHole() throws {
        // 36 mm cube with a vertical r=6 hole through it.
        let block = try Tessellation.box(width: 36, depth: 36, height: 36)
        let hole = try Tessellation.cylinder(radius: 6, height: 48, baseZ: -4)
        let mesh = try CSG.subtract(block, hole)
        let bottom = try face(of: mesh, normal: Vec3(0, 0, -1))
        let top = try face(of: mesh, normal: Vec3(0, 0, 1))

        var config = WaterFlowConfig()
        config.cellSize = 2
        config.inletFaces = [bottom]
        // The bottom face doubles as a drain opening (open it and
        // the column drains straight back down).
        config.outletFaces = [top, bottom]
        config.pressureHeadMM = 100
        let result = try WaterFlow.run(mesh: mesh, config: config)

        XCTAssertTrue(result.reachedOutlet)
        XCTAssertEqual(result.fillFractionOfVoid, 1, accuracy: 1e-9)
        XCTAssertTrue(result.pockets.isEmpty, "pockets: \(result.pockets)")
        // Bottleneck ≈ the hole's cross-section π·6² ≈ 113 mm².
        XCTAssertEqual(result.bottleneckAreaMM2, Double.pi * 36, accuracy: Double.pi * 36 * 0.30,
                       "bottleneck \(result.bottleneckAreaMM2) mm² vs πr² ≈ 113")
        // Vertical hole + bottom outlet: drains completely.
        XCTAssertEqual(result.residualCellCount, 0)
        XCTAssertEqual(result.residualVolumeML, 0)
        // Snapshots: 10 deciles, monotone, ending at the full count.
        XCTAssertEqual(result.heightSnapshots.count, 10)
        XCTAssertEqual(result.heightSnapshots.last?.filledCellCount, result.filledCellCount)
        for (a, b) in zip(result.heightSnapshots, result.heightSnapshots.dropFirst()) {
            XCTAssertLessThanOrEqual(a.filledCellCount, b.filledCellCount)
        }
    }

    // MARK: 2. Sealed cavity — pocket reported, never filled

    func testSealedCavity() throws {
        // 40 mm cube with a fully enclosed 16 mm cube cavity, plus a
        // shallow blind hole on top (the inlet port — it does not
        // reach the cavity).
        var mesh = try Tessellation.box(width: 40, depth: 40, height: 40)
        let cavity = try Tessellation.box(width: 16, depth: 16, height: 16)
            .translated(by: Vec3(0, 0, 12))
        mesh = try CSG.subtract(mesh, cavity)
        let blind = try Tessellation.cylinder(radius: 3, height: 12)
            .translated(by: Vec3(14, 14, 33))
        mesh = try CSG.subtract(mesh, blind)
        let top = try face(of: mesh, normal: Vec3(0, 0, 1))

        var config = WaterFlowConfig()
        config.cellSize = 2
        config.inletFaces = [top]
        let result = try WaterFlow.run(mesh: mesh, config: config)

        // The cavity center is an enclosed void cell.
        let cavityCell = try flat(of: result.grid, at: Vec3(0, 0, 20))
        XCTAssertEqual(result.grid.kind(at: cavityCell), .void)
        XCTAssertFalse(result.filledCells[cavityCell], "sealed cavity must not fill")

        // Exactly the cavity is reported, as .sealed, at its volume
        // 16³ = 4096 mm³ = 4.096 mL (±15%).
        let sealed = result.pockets.filter { $0.kind == .sealed }
        XCTAssertEqual(sealed.count, 1, "pockets: \(result.pockets.map { $0.kind })")
        XCTAssertEqual(sealed[0].volumeML, 4.096, accuracy: 4.096 * 0.15,
                       "sealed volume \(sealed[0].volumeML) mL vs 4.096")
        XCTAssertTrue(sealed[0].cells.contains(cavityCell))
        // The blind inlet hole did take water.
        XCTAssertGreaterThan(result.filledCellCount, 0)
        XCTAssertFalse(result.reachedOutlet)
    }

    // MARK: 3. U-trap — residual stays in the U

    private func uTrapMesh() throws -> Mesh {
        var mesh = try Tessellation.box(width: 44, depth: 24, height: 40)
        let legL = try Tessellation.box(width: 8, depth: 16, height: 34)
            .translated(by: Vec3(-12, 0, 12))
        let legR = try Tessellation.box(width: 8, depth: 16, height: 34)
            .translated(by: Vec3(12, 0, 12))
        let link = try Tessellation.box(width: 32, depth: 16, height: 8)
            .translated(by: Vec3(0, 0, 8))
        mesh = try CSG.subtract(mesh, legL)
        mesh = try CSG.subtract(mesh, legR)
        mesh = try CSG.subtract(mesh, link)
        return mesh
    }

    func testUTrapNoOutlet() throws {
        // Channel void below the rim: legs 2×(8·16·28) + connector
        // 32·16·8 − overlaps 2×(8·16·4) = 10240 mm³ = 10.24 mL.
        let mesh = try uTrapMesh()
        let top = try face(of: mesh, normal: Vec3(0, 0, 1))
        var config = WaterFlowConfig()
        config.cellSize = 2
        config.inletFaces = [top]
        // No outlet faces: the top opening is the only way in or out.
        let result = try WaterFlow.run(mesh: mesh, config: config)

        XCTAssertFalse(result.reachedOutlet, "no second opening → no outlet to reach")
        XCTAssertEqual(result.filledVolumeML, 10.24, accuracy: 10.24 * 0.35,
                       "filled \(result.filledVolumeML) mL vs U volume 10.24")
        // Nothing can drain: the whole U content is residual.
        XCTAssertGreaterThan(result.residualVolumeML, 0)
        XCTAssertEqual(result.residualVolumeML, 10.24, accuracy: 10.24 * 0.35,
                       "residual \(result.residualVolumeML) mL vs U volume 10.24")
    }

    func testUTrapDrainFromTopOpening() throws {
        let mesh = try uTrapMesh()
        let top = try face(of: mesh, normal: Vec3(0, 0, 1))
        var config = WaterFlowConfig()
        config.cellSize = 2
        config.inletFaces = [top]
        config.outletFaces = [top]   // drain back out the same opening
        let result = try WaterFlow.run(mesh: mesh, config: config)

        XCTAssertTrue(result.reachedOutlet)
        // Water below the rim cannot climb the legs to get out:
        // nearly everything stays trapped in the U.
        XCTAssertGreaterThan(result.residualVolumeML, 0.5 * result.filledVolumeML,
                             "residual \(result.residualVolumeML) of filled \(result.filledVolumeML)")
        XCTAssertEqual(result.residualVolumeML, 10.24, accuracy: 10.24 * 0.35,
                       "residual \(result.residualVolumeML) mL vs U volume 10.24")
    }

    // MARK: 4. Open cup — fills to the rim, drains from the bottom

    private func cupMesh() throws -> Mesh {
        let outer = try Tessellation.box(width: 40, depth: 40, height: 36)
        let inner = try Tessellation.box(width: 32, depth: 32, height: 30)
            .translated(by: Vec3(0, 0, 10))
        return try CSG.subtract(outer, inner)
    }

    func testOpenCupFill() throws {
        // Interior: 32·32·(36−10) = 26624 mm³ = 26.624 mL.
        let mesh = try cupMesh()
        let rim = try face(of: mesh, normal: Vec3(0, 0, 1), centroidZ: 36)
        var config = WaterFlowConfig()
        config.cellSize = 2
        config.inletFaces = [rim]
        let result = try WaterFlow.run(mesh: mesh, config: config)

        XCTAssertEqual(result.filledVolumeML, 26.624, accuracy: 26.624 * 0.10,
                       "filled \(result.filledVolumeML) mL vs cup interior 26.624")
        XCTAssertEqual(result.fillFractionOfVoid, 1, accuracy: 1e-9)
        XCTAssertTrue(result.pockets.isEmpty, "pockets: \(result.pockets.map { $0.kind })")
    }

    func testOpenCupDrainFromBottom() throws {
        let mesh = try cupMesh()
        let rim = try face(of: mesh, normal: Vec3(0, 0, 1), centroidZ: 36)
        let floor = try face(of: mesh, normal: Vec3(0, 0, 1), centroidZ: 10)
        var config = WaterFlowConfig()
        config.cellSize = 2
        config.inletFaces = [rim]
        config.outletFaces = [floor]
        let result = try WaterFlow.run(mesh: mesh, config: config)

        XCTAssertGreaterThan(result.filledVolumeML, 20)
        XCTAssertEqual(result.residualVolumeML, 0, accuracy: 0.3,
                       "residual \(result.residualVolumeML) mL after bottom drain")
    }

    // MARK: 5. Air bell — trapsAir keeps the dome's air

    func testAirBell() throws {
        // 40 mm cube with a 16×16×24 cavity opening at the BOTTOM
        // face only: an inverted cup. Water pushed in from below
        // (pressure head 100 mm) would fill it solid in the
        // untrapped model; with air trapping the dome keeps its air.
        let block = try Tessellation.box(width: 40, depth: 40, height: 40)
        let dome = try Tessellation.box(width: 16, depth: 16, height: 26)
            .translated(by: Vec3(0, 0, -2))
        let mesh = try CSG.subtract(block, dome)
        let bottom = try face(of: mesh, normal: Vec3(0, 0, -1))

        func run(trapsAir: Bool) throws -> WaterFlowResult {
            var config = WaterFlowConfig()
            config.cellSize = 2
            config.inletFaces = [bottom]
            config.pressureHeadMM = 100
            config.trapsAir = trapsAir
            config.runDrainPhase = false
            return try WaterFlow.run(mesh: mesh, config: config)
        }

        let open = try run(trapsAir: false)
        let topCell = try flat(of: open.grid, at: Vec3(0, 0, 23))
        XCTAssertTrue(open.filledCells[topCell], "untrapped: dome fills to the top")
        XCTAssertTrue(open.pockets.isEmpty, "pockets: \(open.pockets.map { $0.kind })")

        let trapped = try run(trapsAir: true)
        let topCell2 = try flat(of: trapped.grid, at: Vec3(0, 0, 23))
        XCTAssertFalse(trapped.filledCells[topCell2], "trapped: dome top keeps its air")
        // Water does sit at the dome's entrance (bottom layer).
        let mouthCell = try flat(of: trapped.grid, at: Vec3(0, 0, 1))
        XCTAssertTrue(trapped.filledCells[mouthCell])
        let locks = trapped.pockets.filter { $0.kind == .airLock }
        XCTAssertEqual(locks.count, 1, "pockets: \(trapped.pockets.map { $0.kind })")
        // Dome is 16·16·24 = 6144 mm³ = 6.144 mL; the reported air
        // body is the part above the entrance layer — most of it.
        XCTAssertGreaterThan(locks[0].volumeML, 3.0,
                             "air lock volume \(locks[0].volumeML) mL")
        XCTAssertTrue(locks[0].cells.contains(topCell2))
    }

    // MARK: 6. Errors

    func testNoInletThrows() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let config = WaterFlowConfig()
        XCTAssertThrowsError(try WaterFlow.run(mesh: mesh, config: config)) { error in
            guard let e = error as? SimError else { return XCTFail("expected SimError, got \(error)") }
            XCTAssertEqual(e.code, "MSIM-CF001")
        }
    }

    func testForeignFaceThrows() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let other = mesh.translated(by: Vec3(1000, 0, 0))
        let foreign = try face(of: other, normal: Vec3(0, 0, 1))
        var config = WaterFlowConfig()
        config.cellSize = 2
        config.inletFaces = [foreign]
        XCTAssertThrowsError(try WaterFlow.run(mesh: mesh, config: config)) { error in
            guard let e = error as? SimError else { return XCTFail("expected SimError, got \(error)") }
            XCTAssertEqual(e.code, "MSIM-IN004")
        }
    }
}
