import XCTest
import MetalCADKit
@testable import MetalCADSim

/// Known-answer tests for the water-erosion sim. All grids are
/// ≤ 12×10×10 cells — the suite runs in well under a second.
final class WaterErosionTests: XCTestCase {

    /// Soft custom material (resistance 0.05): at 1 m/s with
    /// coefficient 1 the head-on rate is 1²/0.05 = 20 mm/s, so a
    /// 2 mm cell accumulates 1 mm per 0.05 s step on a facing cell.
    private func softMaterial(resistance: Double = 0.05) -> SimMaterial {
        SimMaterial(name: "Test soft", densityGCm3: 1.0, youngModulus: 1e9,
                    poissonRatio: 0.3, yieldStrength: 1e6,
                    thermalConductivity: 1, specificHeat: 1000,
                    erosionResistance: resistance)
    }

    /// Plate 6 (x) × 20 (y) × 20 (z) mm at cellSize 2 → 3×10×10 grid.
    /// Flow along +X meets the x-min face head-on.
    private func plateConfig(material: SimMaterial, duration: Double,
                             steps: Int) -> ErosionConfig {
        var c = ErosionConfig(material: material)
        c.flowDirection = Vec3(1, 0, 0)
        c.flowSpeed = 1
        c.erosionCoefficient = 1
        c.durationSeconds = duration
        c.stepCount = steps
        c.cellSize = 2
        return c
    }

    private func plate() throws -> Mesh {
        try Tessellation.box(width: 6, depth: 20, height: 20)
    }

    // MARK: (1) Zero speed ⇒ zero erosion

    func testZeroSpeedErodesNothing() throws {
        let mesh = try Tessellation.box(width: 12, depth: 8, height: 8)
        var config = ErosionConfig(material: SimMaterial.forKitMaterial("PLA plastic")!)
        config.flowSpeed = 0
        config.durationSeconds = 100
        config.stepCount = 5
        config.cellSize = 2

        let r = try WaterErosion.run(mesh: mesh, config: config)
        let grid = try VoxelGrid(mesh: mesh, cellSize: 2)

        XCTAssertEqual(r.cellsRemoved, 0)
        XCTAssertEqual(r.massLossGrams, 0)
        XCTAssertEqual(r.massLossPercent, 0)
        XCTAssertEqual(r.maxErosionDepthMM, 0)
        XCTAssertNil(r.maxErosionDepthLocation)
        XCTAssertTrue(r.depthPerCell.allSatisfy { $0 == 0 })
        XCTAssertEqual(r.depthPerCell.count, grid.cellCount)
        XCTAssertEqual(r.erodedSolidVolumeMM3, r.originalSolidVolumeMM3)
        XCTAssertEqual(r.erodedMesh.volume, grid.solidVolume, accuracy: 1e-6,
                       "uneroded mesh should carry the full voxel volume")
        XCTAssertEqual(r.erodedMesh.openEdgeCount, 0)
        XCTAssertEqual(r.steps.count, 6)   // t = 0 record + 5 steps
        XCTAssertTrue(r.steps.allSatisfy { $0.cellsRemovedCumulative == 0 && $0.massLossGrams == 0 })
    }

    // MARK: (2) Facing plate: front erodes, back is shielded

    func testPlateFrontErodesBackShielded() throws {
        let mesh = try plate()
        let r = try WaterErosion.run(mesh: mesh,
                                     config: plateConfig(material: softMaterial(),
                                                         duration: 0.15, steps: 3))
        // The whole front layer (10×10) peels; nothing behind it does
        // in 3 steps (the second layer only reaches half a cell).
        XCTAssertGreaterThanOrEqual(r.cellsRemoved, 90)
        XCTAssertLessThanOrEqual(r.cellsRemoved, 100)
        XCTAssertGreaterThan(r.massLossGrams, 0)
        XCTAssertGreaterThan(r.massLossPercent, 0)

        // Back layer (x index 2): every cell's depth is exactly 0 —
        // shielded by the material in front of it the whole run.
        for j in 0..<r.ny {
            for k in 0..<r.nz {
                let idx = r.flatIndex(x: 2, y: j, z: k)
                XCTAssertEqual(r.depthPerCell[idx], 0,
                               "back cell (2,\(j),\(k)) eroded")
                XCTAssertTrue(r.solidMask[idx], "back cell (2,\(j),\(k)) removed")
            }
        }
        // Front layer: gone, and the deepest reading sits there.
        for j in 0..<r.ny {
            for k in 0..<r.nz {
                XCTAssertFalse(r.solidMask[r.flatIndex(x: 0, y: j, z: k)])
            }
        }
        XCTAssertGreaterThanOrEqual(r.maxErosionDepthMM, 1.9)
        let loc = try XCTUnwrap(r.maxErosionDepthLocation)
        XCTAssertEqual(loc.x, -2, accuracy: 1.0,
                       "deepest erosion should be in the front layer (centre x = −2)")
    }

    // MARK: (3) Monotonicity in duration

    func testLongerDurationErodesAtLeastAsMuch() throws {
        let mesh = try plate()
        let short = try WaterErosion.run(mesh: mesh,
                                         config: plateConfig(material: softMaterial(),
                                                             duration: 0.1, steps: 2))
        let long = try WaterErosion.run(mesh: mesh,
                                        config: plateConfig(material: softMaterial(),
                                                            duration: 0.2, steps: 4))
        XCTAssertGreaterThanOrEqual(long.cellsRemoved, short.cellsRemoved)
        XCTAssertGreaterThanOrEqual(long.maxErosionDepthMM, short.maxErosionDepthMM)
        XCTAssertGreaterThanOrEqual(long.massLossGrams, short.massLossGrams)
        // The time series itself is non-decreasing.
        for series in [short.steps, long.steps] {
            for (a, b) in zip(series, series.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.cellsRemovedCumulative, a.cellsRemovedCumulative)
                XCTAssertGreaterThanOrEqual(b.massLossGrams, a.massLossGrams)
            }
        }
    }

    // MARK: (4) Harder material erodes strictly less

    func testHarderMaterialRemovesFewerCells() throws {
        let mesh = try plate()
        let soft = try WaterErosion.run(mesh: mesh,
                                        config: plateConfig(material: softMaterial(resistance: 0.05),
                                                            duration: 0.15, steps: 3))
        let hard = try WaterErosion.run(mesh: mesh,
                                        config: plateConfig(material: softMaterial(resistance: 0.95),
                                                            duration: 0.15, steps: 3))
        XCTAssertEqual(hard.cellsRemoved, 0,
                       "at resistance 0.95 the rate is ~1 mm/s — no 2 mm cell peels in 0.15 s")
        XCTAssertLessThan(hard.cellsRemoved, soft.cellsRemoved)
        XCTAssertLessThan(hard.maxErosionDepthMM, soft.maxErosionDepthMM)
        XCTAssertGreaterThan(hard.maxErosionDepthMM, 0,
                             "hard material still accumulates some depth — it just doesn't peel")
    }

    // MARK: (5) Eroded mesh is closed and between empty and original

    func testErodedMeshClosedAndSmaller() throws {
        let mesh = try plate()
        let r = try WaterErosion.run(mesh: mesh,
                                     config: plateConfig(material: softMaterial(),
                                                         duration: 0.15, steps: 3))
        XCTAssertEqual(r.erodedMesh.openEdgeCount, 0, "eroded mesh must be closed")
        XCTAssertLessThan(r.erodedMesh.volume, r.originalSolidVolumeMM3)
        XCTAssertGreaterThan(r.erodedMesh.volume, 0)
        XCTAssertEqual(r.erodedMesh.volume, r.erodedSolidVolumeMM3,
                       accuracy: r.erodedSolidVolumeMM3 * 1e-9 + 1e-9,
                       "mesh volume should equal the surviving voxel volume")
        // Surviving mask + removed count = original solid count.
        let surviving = r.solidMask.filter { $0 }.count
        let grid = try VoxelGrid(mesh: mesh, cellSize: 2)
        XCTAssertEqual(surviving + r.cellsRemoved, grid.solidCellCount)
    }

    // MARK: (6) Internal channel walls

    /// Box 24×16×16 with a Ø8 through-hole along X, built by CSG
    /// difference. Grid at cellSize 2 → 12×8×8.
    private func channelMesh() throws -> Mesh {
        let box = try Tessellation.box(width: 24, depth: 16, height: 16)
        // Cylinder along Z, rotated +90° about Y so its axis is +X:
        // (x, y, z) → (z, y, −x).
        let cyl = try Tessellation.cylinder(radius: 4, height: 30, segments: 48)
        let rotated = Mesh(vertices: cyl.vertices.map { Vec3($0.z, $0.y, -$0.x) },
                           indices: cyl.indices)
        let hole = rotated.translated(by: Vec3(-15, 0, 8))
        return try CSG.subtract(box, hole)
    }

    /// Solid cells deep inside the part (x index 2…9) that touch the
    /// channel void and nothing else non-solid — the hole's walls.
    private func channelWallCells(grid: VoxelGrid) -> [Int] {
        var out: [Int] = []
        let offsets = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 2..<(grid.nx - 2) where grid.isSolid(x: i, y: j, z: k) {
                    var touchesChannel = false
                    var touchesOtherVoid = false
                    for o in offsets {
                        let (a, b, c) = (i + o.0, j + o.1, k + o.2)
                        guard grid.isInBounds(x: a, y: b, z: c) else { continue }
                        guard !grid.isSolid(x: a, y: b, z: c) else { continue }
                        let centre = grid.cellCenter(x: a, y: b, z: c)
                        let radial = (centre.y * centre.y + (centre.z - 8) * (centre.z - 8)).squareRoot()
                        if radial < 4.5 { touchesChannel = true } else { touchesOtherVoid = true }
                    }
                    if touchesChannel && !touchesOtherVoid {
                        out.append(grid.flatIndex(x: i, y: j, z: k))
                    }
                }
            }
        }
        return out
    }

    func testInternalChannelWallsFollowToggle() throws {
        let mesh = try channelMesh()
        let grid = try VoxelGrid(mesh: mesh, cellSize: 2)
        let walls = channelWallCells(grid: grid)
        XCTAssertFalse(walls.isEmpty, "fixture should have identifiable channel-wall cells")

        func run(includeInternal: Bool) throws -> ErosionResult {
            var config = ErosionConfig(material: SimMaterial.forKitMaterial("PLA plastic")!)
            config.flowDirection = Vec3(1, 0, 0)
            config.flowSpeed = 1
            config.erosionCoefficient = 1
            config.durationSeconds = 1
            config.stepCount = 2
            config.cellSize = 2
            config.includeInternalSurfaces = includeInternal
            return try WaterErosion.run(mesh: mesh, config: config)
        }

        let withInternal = try run(includeInternal: true)
        XCTAssertTrue(walls.contains { withInternal.depthPerCell[$0] > 0 },
                      "with internal surfaces on, some channel-wall cell must erode")

        let withoutInternal = try run(includeInternal: false)
        for idx in walls {
            XCTAssertEqual(withoutInternal.depthPerCell[idx], 0,
                           "channel-wall cell \(idx) eroded with internal surfaces off")
        }
    }

    // MARK: (7) Validation

    func testValidation() throws {
        let mesh = try plate()
        func expectError(_ mutate: (inout ErosionConfig) -> Void,
                         code: String, _ label: String) {
            var config = ErosionConfig(material: softMaterial())
            config.cellSize = 2
            mutate(&config)
            XCTAssertThrowsError(try WaterErosion.run(mesh: mesh, config: config), label) { err in
                guard let simErr = err as? SimError else {
                    return XCTFail("\(label): expected SimError, got \(err)")
                }
                XCTAssertEqual(simErr.code, code, label)
            }
        }
        expectError({ $0.durationSeconds = 0 }, code: "MSIM-CF001", "zero duration")
        expectError({ $0.durationSeconds = -5 }, code: "MSIM-CF001", "negative duration")
        expectError({ $0.flowSpeed = -1 }, code: "MSIM-CF001", "negative speed")
        expectError({ $0.flowDirection = .zero }, code: "MSIM-IN003", "zero direction")
        expectError({ $0.stepCount = 0 }, code: "MSIM-CF001", "zero steps")
        expectError({ $0.glancingFactor = 1.5 }, code: "MSIM-CF001", "glancing > 1")
        expectError({ $0.flowSpeed = .nan }, code: "MSIM-CF002", "NaN speed")
    }

    // MARK: (8) Dynamic-pressure toggle

    func testDynamicPressureToggle() throws {
        let mesh = try plate()
        // For plain water (ρ = 1000) the toggle is an exact no-op:
        // ρv²/1000 with ρ = 1000 reproduces v² bit for bit.
        let plain = plateConfig(material: softMaterial(), duration: 0.15, steps: 3)
        var scaled = plain
        scaled.scaleByDynamicPressure = true
        let a = try WaterErosion.run(mesh: mesh, config: plain)
        let b = try WaterErosion.run(mesh: mesh, config: scaled)
        XCTAssertEqual(a.cellsRemoved, b.cellsRemoved)
        XCTAssertEqual(a.depthPerCell, b.depthPerCell)

        // Halving the density under the toggle halves every depth
        // (hard material, so nothing peels and depth stays linear).
        var full = plateConfig(material: softMaterial(resistance: 0.95),
                               duration: 0.3, steps: 3)
        full.scaleByDynamicPressure = true
        var half = full
        half.waterDensity = 500
        let c = try WaterErosion.run(mesh: mesh, config: full)
        let d = try WaterErosion.run(mesh: mesh, config: half)
        XCTAssertEqual(c.cellsRemoved, 0)
        XCTAssertEqual(d.cellsRemoved, 0)
        XCTAssertEqual(c.depthPerCell.count, d.depthPerCell.count)
        for i in c.depthPerCell.indices {
            XCTAssertEqual(d.depthPerCell[i], c.depthPerCell[i] / 2, accuracy: 1e-12,
                           "cell \(i): halved density should halve the depth")
        }
    }
}
