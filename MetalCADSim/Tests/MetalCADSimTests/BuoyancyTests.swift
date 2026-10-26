import XCTest
import MetalCADKit
@testable import MetalCADSim

/// Known-answer tests for the mesh-exact hydrostatics. Boxes are the
/// exact case for triangle clipping: a waterline through a cube's
/// mid-plane must return exactly half the volume and the analytic
/// center of buoyancy, and the section-based GM must flip sign
/// between a wide raft (stable) and a tall narrow column (unstable)
/// exactly as the hand computation GM = KB + I/V − KG predicts.
final class BuoyancyTests: XCTestCase {

    /// A part material with an exact density (g/cm³) so verdict
    /// ratios are analytic.
    private func material(densityGCm3: Double, name: String = "Test") -> SimMaterial {
        SimMaterial(name: name, densityGCm3: densityGCm3, youngModulus: 1e9,
                    poissonRatio: 0.3, yieldStrength: 1e8, thermalConductivity: 1,
                    specificHeat: 1000, erosionResistance: 0.5)
    }

    private func config(material: SimMaterial, waterlineZ: Double) -> BuoyancyConfig {
        var c = BuoyancyConfig(material: material)
        c.waterlinePoint = Vec3(0, 0, waterlineZ)
        c.waterlineNormal = Vec3(0, 0, 1)
        return c
    }

    // MARK: (1) Cube at mid-draft — exact numbers

    func testCubeHalfSubmerged() throws {
        // 100 mm cube, z ∈ [0, 100]; waterline through its center.
        let cube = try Tessellation.box(width: 100, depth: 100, height: 100)
        let r = try Buoyancy.analyze(mesh: cube,
                                     config: config(material: material(densityGCm3: 0.5),
                                                    waterlineZ: 50))
        XCTAssertEqual(r.submergedVolumeMM3, 500_000, accuracy: 500_000 * 0.005)
        XCTAssertEqual(r.submergedVolumeM3, 5e-4, accuracy: 5e-7)
        XCTAssertEqual(r.submergedFraction, 0.5, accuracy: 0.005)
        // Centroid of the lower half: z = 25 abs, −25 rel. the center.
        let b = try XCTUnwrap(r.centerOfBuoyancy)
        XCTAssertEqual(b.x, 0, accuracy: 1e-6)
        XCTAssertEqual(b.y, 0, accuracy: 1e-6)
        XCTAssertEqual(b.z, 25, accuracy: 0.01)
        XCTAssertEqual(b.z - 50, -25, accuracy: 0.01)
        XCTAssertEqual(r.centerOfMass.z, 50, accuracy: 0.01)
        // Displaced: 5e-4 m³ × 1000 kg/m³ = 0.5 kg; part: 1e-3 × 500.
        XCTAssertEqual(r.displacedMassKg, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r.partMassKg, 0.5, accuracy: 1e-6)
    }

    // MARK: (2) Verdicts

    func testVerdicts() throws {
        let cube = try Tessellation.box(width: 100, depth: 100, height: 100)
        // Oak (0.72 g/cm³ from the kit table) in fresh water floats
        // with reserve 1 − 0.72 = 0.28.
        let oak = try XCTUnwrap(SimMaterial.forKitMaterial("Oak wood"))
        let ro = try Buoyancy.analyze(mesh: cube, config: config(material: oak, waterlineZ: 50))
        guard case .floats(let reserve) = ro.verdict else {
            return XCTFail("oak should float, got \(ro.verdict)")
        }
        XCTAssertEqual(reserve, 1 - oak.densityGCm3, accuracy: 1e-9)
        XCTAssertLessThan(ro.partMassKg, 1.0)   // full displacement = 1 kg

        // Steel (~7.85 g/cm³) sinks: its mass beats full displacement.
        let steel = try XCTUnwrap(SimMaterial.forKitMaterial("Steel (mild)"))
        let rs = try Buoyancy.analyze(mesh: cube, config: config(material: steel, waterlineZ: 50))
        XCTAssertEqual(rs.verdict, .sinks)
        XCTAssertGreaterThan(rs.partMassKg, 1.0)

        // Density exactly the fluid's → awash.
        let neutral = try Buoyancy.analyze(mesh: cube,
                                           config: config(material: material(densityGCm3: 1.0),
                                                          waterlineZ: 50))
        XCTAssertEqual(neutral.verdict, .floatsAwash)
    }

    // MARK: (3) Sphere fully submerged

    func testSphereFullySubmerged() throws {
        let sphere = try Tessellation.sphere(radius: 50, segments: 96, rings: 64)
        // Waterline above the top of the sphere (z = 50).
        let r = try Buoyancy.analyze(mesh: sphere,
                                     config: config(material: material(densityGCm3: 0.4),
                                                    waterlineZ: 60))
        XCTAssertEqual(r.submergedVolumeMM3, sphere.volume, accuracy: sphere.volume * 0.01)
        XCTAssertEqual(r.submergedFraction, 1.0, accuracy: 0.01)
        let b = try XCTUnwrap(r.centerOfBuoyancy)
        XCTAssertLessThan(b.distance(to: r.centerOfMass), 1.0)
        // No waterplane where the plane misses the part entirely.
        XCTAssertEqual(r.waterplaneAreaMM2, 0, accuracy: 1e-9)
    }

    // MARK: (4) Stability signs: raft vs column

    func testRaftIsStable() throws {
        // 200 × 200 × 20 raft, waterline at mid-height.
        let raft = try Tessellation.box(width: 200, depth: 200, height: 20)
        let r = try Buoyancy.analyze(mesh: raft,
                                     config: config(material: material(densityGCm3: 0.5),
                                                    waterlineZ: 10))
        // Hand check: I = 200⁴/12, V = 400 000 → BM = 333.3;
        // KB = 5, KG = 10 → GM ≈ +328.3 mm.
        let gm = try XCTUnwrap(r.metacentricHeightMM)
        XCTAssertEqual(gm, 5 + (pow(200.0, 4) / 12) / 400_000 - 10, accuracy: 1.0)
        XCTAssertGreaterThan(gm, 0)
        // Both default angles (5°, 10°) right the raft.
        XCTAssertEqual(r.rightingArms.count, 2)
        for arm in r.rightingArms {
            XCTAssertTrue(arm.restoring, "\(arm.degrees)° should restore, GZ \(arm.gzMM)")
            XCTAssertGreaterThan(arm.gzMM, 0)
        }
    }

    func testTallColumnIsUnstable() throws {
        // 30 × 30 × 200 column at half draft, density ½ water.
        let column = try Tessellation.box(width: 30, depth: 30, height: 200)
        let r = try Buoyancy.analyze(mesh: column,
                                     config: config(material: material(densityGCm3: 0.5),
                                                    waterlineZ: 100))
        // Hand check: I = 30⁴/12 = 67 500, V = 90 000 → BM = 0.75;
        // KB = 50, KG = 100 → GM = −49.25 mm: unstable.
        let gm = try XCTUnwrap(r.metacentricHeightMM)
        XCTAssertEqual(gm, 50 + 67_500.0 / 90_000.0 - 100, accuracy: 0.5)
        XCTAssertLessThan(gm, 0)
        // And the sweep agrees: tilting makes it worse, not better.
        XCTAssertFalse(r.rightingArms.isEmpty)
        for arm in r.rightingArms {
            XCTAssertFalse(arm.restoring, "\(arm.degrees)° should NOT restore, GZ \(arm.gzMM)")
            XCTAssertLessThan(arm.gzMM, 0)
        }
    }

    // MARK: (5) Waterplane area + second moment (cube / raft sections)

    func testWaterplaneSection() throws {
        let cube = try Tessellation.box(width: 100, depth: 100, height: 100)
        let rc = try Buoyancy.analyze(mesh: cube,
                                      config: config(material: material(densityGCm3: 0.5),
                                                     waterlineZ: 50))
        XCTAssertEqual(rc.waterplaneAreaMM2, 10_000, accuracy: 10_000 * 0.01)
        // I about the X axis for a 100 × 100 section: 100⁴/12.
        XCTAssertEqual(rc.waterplaneSecondMomentMM4, pow(100.0, 4) / 12,
                       accuracy: pow(100.0, 4) / 12 * 0.01)

        let raft = try Tessellation.box(width: 200, depth: 200, height: 20)
        let rr = try Buoyancy.analyze(mesh: raft,
                                      config: config(material: material(densityGCm3: 0.5),
                                                     waterlineZ: 10))
        XCTAssertEqual(rr.waterplaneAreaMM2, 40_000, accuracy: 40_000 * 0.01)
        XCTAssertEqual(rr.waterplaneSecondMomentMM4, pow(200.0, 4) / 12,
                       accuracy: pow(200.0, 4) / 12 * 0.01)
    }

    // MARK: (6) Dry + fully submerged edge cases

    func testDryPart() throws {
        let cube = try Tessellation.box(width: 100, depth: 100, height: 100)
        // Waterline below the part (cube sits at z ∈ [0, 100]).
        let r = try Buoyancy.analyze(mesh: cube,
                                     config: config(material: material(densityGCm3: 0.5),
                                                    waterlineZ: -10))
        XCTAssertEqual(r.submergedVolumeMM3, 0, accuracy: 1e-9)
        XCTAssertEqual(r.submergedFraction, 0, accuracy: 1e-12)
        XCTAssertNil(r.centerOfBuoyancy)
        XCTAssertNil(r.metacentricHeightMM)
        XCTAssertEqual(r.displacedMassKg, 0, accuracy: 1e-12)
        // Verdict still comes from the full-submersion comparison.
        guard case .floats = r.verdict else {
            return XCTFail("dry half-density cube should still verdict floats, got \(r.verdict)")
        }
    }

    func testFullySubmergedCube() throws {
        let cube = try Tessellation.box(width: 100, depth: 100, height: 100)
        let r = try Buoyancy.analyze(mesh: cube,
                                     config: config(material: material(densityGCm3: 0.5),
                                                    waterlineZ: 150))
        XCTAssertEqual(r.submergedFraction, 1.0, accuracy: 1e-9)
        let b = try XCTUnwrap(r.centerOfBuoyancy)
        XCTAssertLessThan(b.distance(to: r.centerOfMass), 1e-6)
        XCTAssertEqual(r.waterplaneAreaMM2, 0, accuracy: 1e-9)
        // Fully submerged: BM = 0 (no waterplane), B sits on G → GM 0.
        XCTAssertEqual(try XCTUnwrap(r.metacentricHeightMM), 0, accuracy: 1e-6)
    }

    // MARK: (7) Validation errors

    func testValidation() throws {
        let cube = try Tessellation.box(width: 100, depth: 100, height: 100)
        let mat = material(densityGCm3: 0.5)

        var zeroNormal = config(material: mat, waterlineZ: 50)
        zeroNormal.waterlineNormal = .zero
        XCTAssertThrowsError(try Buoyancy.analyze(mesh: cube, config: zeroNormal)) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-IN003")
        }

        // Tilt axis parallel to the normal: nothing left in-plane.
        var badAxis = config(material: mat, waterlineZ: 50)
        badAxis.tiltAxis = Vec3(0, 0, 2)
        XCTAssertThrowsError(try Buoyancy.analyze(mesh: cube, config: badAxis)) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-IN003")
        }

        var zeroAxis = config(material: mat, waterlineZ: 50)
        zeroAxis.tiltAxis = .zero
        XCTAssertThrowsError(try Buoyancy.analyze(mesh: cube, config: zeroAxis))

        XCTAssertThrowsError(try Buoyancy.analyze(mesh: Mesh(), config: config(material: mat, waterlineZ: 50))) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-IN001")
        }

        var badDensity = config(material: mat, waterlineZ: 50)
        badDensity.fluidDensityKgM3 = 0
        XCTAssertThrowsError(try Buoyancy.analyze(mesh: cube, config: badDensity)) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-CF001")
        }

        var nanDensity = config(material: mat, waterlineZ: 50)
        nanDensity.fluidDensityKgM3 = .nan
        XCTAssertThrowsError(try Buoyancy.analyze(mesh: cube, config: nanDensity)) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-CF002")
        }
    }
}
