import XCTest
import MetalCADKit
@testable import MetalCADSim

/// Cross-sim integration: ONE part and ONE material, resolved the way
/// the app will do it — a kit `Material` from `MaterialLibrary`,
/// turned into a `SimMaterial` via `forKitMaterial(_:)` — run through
/// every sim in the package. The point is the shared flow: the same
/// kit `Mesh` and the same kit faces feed all six studies, untouched.
///
/// The part: a 36 mm cube with a vertical Ø12 through-hole (kit CSG
/// difference), so it has an internal channel for the water sims, an
/// annulus top/bottom for face-based loads and BCs, and a constant
/// cross-section along Z (which makes the buoyancy fraction at
/// mid-height exactly 0.5).
final class IntegrationTests: XCTestCase {

    /// The shared part + material, built once per test.
    private func makePart() throws -> (mesh: Mesh, material: SimMaterial) {
        let block = try Tessellation.box(width: 36, depth: 36, height: 36)
        let hole = try Tessellation.cylinder(radius: 6, height: 48, baseZ: -4)
        let mesh = try CSG.subtract(block, hole)
        let kitMaterial = try XCTUnwrap(MaterialLibrary.byID("aluminum-6061"))
        let material = try XCTUnwrap(SimMaterial.forKitMaterial(kitMaterial))
        return (mesh, material)
    }

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

    // MARK: All six sims over the one part

    func testAllSimsShareOnePartAndMaterial() throws {
        let (mesh, material) = try makePart()
        let bounds = mesh.bounds
        let bottom = try face(of: mesh, normal: Vec3(0, 0, -1))
        let top = try face(of: mesh, normal: Vec3(0, 0, 1))

        // Aerodynamics — bluff block in a +X wind: real drag, sane Cd.
        let aero = try Aerodynamics.analyze(mesh: mesh, config: AeroConfig())
        XCTAssertGreaterThan(aero.dragForce, 0)
        XCTAssertGreaterThan(aero.dragCoefficient, 0.1)
        XCTAssertLessThan(aero.dragCoefficient, 4)
        XCTAssertGreaterThan(aero.raysHit, 0)

        // Structural — bottom fixed, 500 N pressed onto the top face.
        var structural = StructuralConfig(material: material)
        structural.cellSize = 3
        structural.fixedFaces = [bottom]
        structural.loads = [FaceLoad(face: top, force: 500, direction: Vec3(0, 0, -1))]
        let stress = try Structural.solve(mesh: mesh, config: structural)
        XCTAssertGreaterThan(stress.maxVonMisesMPa, 0)
        XCTAssertTrue(stress.safetyFactor.isFinite)
        XCTAssertGreaterThan(stress.safetyFactor, 0)
        XCTAssertGreaterThan(stress.maxDisplacementMM, 0)

        // Thermal — bottom held at 100 °C, top at 0 °C, steady state:
        // layer means must fall monotonically (within solver slack)
        // from the hot face to the cold one.
        var thermal = ThermalConfig(material: material)
        thermal.cellSize = 3
        thermal.faceBCs = [
            ThermalFaceBC(face: bottom, kind: .fixedTemperature(celsius: 100)),
            ThermalFaceBC(face: top, kind: .fixedTemperature(celsius: 0)),
        ]
        let heat = try ThermalSimulation.run(mesh: mesh, config: thermal)
        XCTAssertGreaterThan(heat.maxC, 90)
        XCTAssertLessThan(heat.minC, 10)
        let grid = heat.grid
        var layerMeans: [Double] = []
        for k in 0..<grid.nz {
            var sum = 0.0, count = 0
            for j in 0..<grid.ny {
                for i in 0..<grid.nx where grid.isSolid(x: i, y: j, z: k) {
                    let t = heat.temperaturePerCell[grid.flatIndex(x: i, y: j, z: k)]
                    if t.isFinite { sum += t; count += 1 }
                }
            }
            if count > 0 { layerMeans.append(sum / Double(count)) }
        }
        XCTAssertEqual(layerMeans.count, grid.nz)
        for idx in 1..<layerMeans.count {
            XCTAssertLessThanOrEqual(layerMeans[idx], layerMeans[idx - 1] + 1.0,
                                     "layer \(idx) mean \(layerMeans[idx]) rises above layer \(idx - 1) mean \(layerMeans[idx - 1])")
        }
        XCTAssertGreaterThan(layerMeans.first!, layerMeans.last! + 20)

        // WaterFlow — in at the bottom face, out the top: the hole
        // is a straight vertical channel, so the outlet is reached.
        var flow = WaterFlowConfig()
        flow.cellSize = 3
        flow.inletFaces = [bottom]
        flow.outletFaces = [top]
        flow.pressureHeadMM = 100
        let water = try WaterFlow.run(mesh: mesh, config: flow)
        XCTAssertTrue(water.reachedOutlet)

        // Buoyancy — waterline through mid-height. The cross-section
        // is constant along Z, so exactly half the volume is under.
        var buoyancy = BuoyancyConfig.freshWater(material: material)
        buoyancy.waterlinePoint = Vec3(0, 0, bounds.center.z)
        buoyancy.waterlineNormal = Vec3(0, 0, 1)
        let floats = try Buoyancy.analyze(mesh: mesh, config: buoyancy)
        XCTAssertEqual(floats.submergedFraction, 0.5, accuracy: 0.05)

        // WaterErosion — zero flow speed erodes nothing, but the run
        // still produces the (unchanged) eroded shape as a kit Mesh.
        var erosion = ErosionConfig(material: material)
        erosion.cellSize = 3
        erosion.flowDirection = Vec3(0, 0, -1)
        erosion.flowSpeed = 0
        let eroded = try WaterErosion.run(mesh: mesh, config: erosion)
        XCTAssertEqual(eroded.cellsRemoved, 0)
        XCTAssertEqual(eroded.massLossGrams, 0)
        XCTAssertEqual(eroded.erodedSolidVolumeMM3, eroded.originalSolidVolumeMM3)
        XCTAssertGreaterThan(eroded.erodedMesh.triangleCount, 0)
    }

    // MARK: Determinism — identical inputs, identical headline numbers

    /// The solvers are built on fixed iteration order and claim
    /// bit-exact determinism: two runs over identical inputs must
    /// produce *exactly* equal headline numbers, not just close ones.
    func testDeterminismStructuralAndAero() throws {
        let (mesh, material) = try makePart()
        let bottom = try face(of: mesh, normal: Vec3(0, 0, -1))
        let top = try face(of: mesh, normal: Vec3(0, 0, 1))

        var structural = StructuralConfig(material: material)
        structural.cellSize = 3
        structural.fixedFaces = [bottom]
        structural.loads = [FaceLoad(face: top, force: 500, direction: Vec3(0, 0, -1))]
        let s1 = try Structural.solve(mesh: mesh, config: structural)
        let s2 = try Structural.solve(mesh: mesh, config: structural)
        XCTAssertEqual(s1.maxVonMisesMPa, s2.maxVonMisesMPa)
        XCTAssertEqual(s1.iterations, s2.iterations)
        XCTAssertEqual(s1.maxDisplacementMM, s2.maxDisplacementMM)

        let aeroConfig = AeroConfig()
        let a1 = try Aerodynamics.analyze(mesh: mesh, config: aeroConfig)
        let a2 = try Aerodynamics.analyze(mesh: mesh, config: aeroConfig)
        XCTAssertEqual(a1.dragCoefficient, a2.dragCoefficient)
        XCTAssertEqual(a1.dragForce, a2.dragForce)
        XCTAssertEqual(a1.totalForce, a2.totalForce)
    }
}
