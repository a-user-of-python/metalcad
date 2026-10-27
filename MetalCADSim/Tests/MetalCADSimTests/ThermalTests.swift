import XCTest
import MetalCADKit
@testable import MetalCADSim

/// Known-answer tests for the thermal sim. Grids stay ≤ 20³ so the
/// suite stays fast.
final class ThermalTests: XCTestCase {

    private var aluminum: SimMaterial {
        SimMaterial.forKitMaterial("Aluminum 6061")!
    }

    /// The face of `mesh` whose outward normal matches `normal`.
    private func face(of mesh: Mesh, normal: Vec3) -> PlanarFace {
        let faces = FaceExtractor.planarFaces(of: mesh)
        let match = faces.first { $0.plane.normal.dot(normal) > 0.999 }
        return try! XCTUnwrap(match, "no face with normal \(normal)")
    }

    private func temp(_ r: ThermalResult, _ x: Int, _ y: Int, _ z: Int) -> Double {
        r.temperaturePerCell[r.grid.flatIndex(x: x, y: y, z: z)]
    }

    // MARK: (1) 1D slab, steady

    func testSteadySlabMatchesAnalytic() throws {
        let mesh = try Tessellation.box(width: 20, depth: 10, height: 10)
        var config = ThermalConfig(material: aluminum)
        config.cellSize = 1
        config.faceBCs = [
            ThermalFaceBC(face: face(of: mesh, normal: Vec3(-1, 0, 0)),
                          kind: .fixedTemperature(celsius: 100)),
            ThermalFaceBC(face: face(of: mesh, normal: Vec3(1, 0, 0)),
                          kind: .fixedTemperature(celsius: 0)),
        ]
        let r = try ThermalSimulation.run(mesh: mesh, config: config)
        XCTAssertEqual(r.grid.nx, 20)

        // Mid-plane: the two center layers straddle x = 0 and should
        // average to 50 °C (analytic profile T = 100·(10 − x)/20).
        let midA = temp(r, 9, 5, 5)
        let midB = temp(r, 10, 5, 5)
        XCTAssertEqual((midA + midB) / 2, 50, accuracy: 3,
                       "mid-plane temperatures \(midA), \(midB)")

        // Monotone decreasing along the center row.
        var prev = Double.infinity
        for x in 0..<20 {
            let t = temp(r, x, 5, 5)
            XCTAssertLessThan(t, prev, "profile not monotone at x=\(x)")
            prev = t
        }

        // Total heat in ≈ k·A·ΔT/L = 167 · 1e-4 · 100 / 0.02 = 83.5 W.
        let analyticQ = 167.0 * 1e-4 * 100.0 / 0.02
        XCTAssertEqual(r.totalHeatFlowInW, analyticQ,
                       accuracy: analyticQ * 0.07,
                       "heat in \(r.totalHeatFlowInW) W vs analytic \(analyticQ) W")
        // Steady balance: in ≈ out within 2%.
        XCTAssertEqual(r.totalHeatFlowInW, r.totalHeatFlowOutW,
                       accuracy: r.totalHeatFlowInW * 0.02,
                       "in \(r.totalHeatFlowInW) vs out \(r.totalHeatFlowOutW)")
    }

    // MARK: (2) Heat generation, both faces pinned

    func testGenerationSlabPeak() throws {
        let mesh = try Tessellation.box(width: 20, depth: 10, height: 10)
        let q = 2e7  // W/m³
        var config = ThermalConfig(material: aluminum)
        config.cellSize = 1
        config.heatGenerationWPerM3 = q
        config.faceBCs = [
            ThermalFaceBC(face: face(of: mesh, normal: Vec3(-1, 0, 0)),
                          kind: .fixedTemperature(celsius: 0)),
            ThermalFaceBC(face: face(of: mesh, normal: Vec3(1, 0, 0)),
                          kind: .fixedTemperature(celsius: 0)),
        ]
        let r = try ThermalSimulation.run(mesh: mesh, config: config)
        // Analytic peak: q·L²/(8k) = 2e7 · 0.02² / (8·167) ≈ 5.99 °C.
        let peak = q * 0.02 * 0.02 / (8 * 167.0)
        XCTAssertEqual(r.maxC, peak, accuracy: peak * 0.12,
                       "peak \(r.maxC) °C vs analytic \(peak) °C")
        XCTAssertGreaterThan(r.minC, -0.5)
    }

    // MARK: (3) Lumped-capacitance cooling

    func testLumpedCapacitanceCooling() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        var config = ThermalConfig(material: aluminum)
        config.cellSize = 2
        config.mode = .transient
        config.globalAmbient = ThermalAmbient(coefficient: 200, ambientC: 20)
        config.initialTemperatureC = 100
        // τ = ρcV/(hA) = 2700·896·1e-6 / (200·6e-4) = 20.16 s.
        let rho = 2700.0, c = 896.0, v = 1e-6, a = 6e-4, h = 200.0
        let tau = rho * c * v / (h * a)
        config.duration = 0.25 * tau
        config.timeStep = 0.1
        let r = try ThermalSimulation.run(mesh: mesh, config: config)

        let expected = 20 + 80 * exp(-0.25)
        let lumpedDrop = 100 - expected
        XCTAssertLessThan(r.averageC, 100, "block did not cool")
        XCTAssertEqual(r.averageC, expected, accuracy: lumpedDrop * 0.15,
                       "average \(r.averageC) °C vs lumped estimate \(expected) °C")
        // Biot ≈ 0.002: the block stays nearly uniform.
        XCTAssertLessThan(r.maxC - r.minC, 2.0,
                          "block not uniform: \(r.minC)...\(r.maxC)")
    }

    // MARK: (4) Transient converges to steady

    func testTransientConvergesToSteady() throws {
        let mesh = try Tessellation.box(width: 20, depth: 10, height: 10)
        func makeConfig() -> ThermalConfig {
            var c = ThermalConfig(material: aluminum)
            c.cellSize = 2
            c.faceBCs = [
                ThermalFaceBC(face: face(of: mesh, normal: Vec3(-1, 0, 0)),
                              kind: .fixedTemperature(celsius: 100)),
                ThermalFaceBC(face: face(of: mesh, normal: Vec3(1, 0, 0)),
                              kind: .fixedTemperature(celsius: 0)),
            ]
            return c
        }
        let steady = try ThermalSimulation.run(mesh: mesh, config: makeConfig())

        var tc = makeConfig()
        tc.mode = .transient
        tc.initialTemperatureC = 20
        tc.duration = 8          // ≈ 14 first-mode time constants
        tc.timeStep = 0.05
        let tran = try ThermalSimulation.run(mesh: mesh, config: tc)

        var worst = 0.0
        for i in 0..<steady.temperaturePerCell.count {
            let s = steady.temperaturePerCell[i]
            let t = tran.temperaturePerCell[i]
            if s.isFinite { worst = max(worst, abs(s - t)) }
        }
        XCTAssertLessThan(worst, 2.0,
                          "transient end state differs from steady by \(worst) °C")
    }

    // MARK: (5) Errors

    func testFaceFromAnotherMeshThrows() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let other = try Tessellation.box(width: 30, depth: 10, height: 30)
        let foreignTop = face(of: other, normal: Vec3(0, 0, 1))  // plane at z = 30
        var config = ThermalConfig(material: aluminum)
        config.cellSize = 2
        config.faceBCs = [ThermalFaceBC(face: foreignTop,
                                        kind: .fixedTemperature(celsius: 50))]
        XCTAssertThrowsError(try ThermalSimulation.run(mesh: mesh, config: config)) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-IN004")
        }
    }

    func testOversizedStepWithoutSubstepThrows() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        var config = ThermalConfig(material: aluminum)
        config.cellSize = 2
        config.mode = .transient
        config.duration = 1
        config.timeStep = 1.0     // stability limit ≈ 0.02 s here
        config.autoSubstep = false
        config.globalAmbient = ThermalAmbient(coefficient: 100, ambientC: 20)
        XCTAssertThrowsError(try ThermalSimulation.run(mesh: mesh, config: config)) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-CF001")
        }
    }

    func testZeroDurationTransientThrows() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        var config = ThermalConfig(material: aluminum)
        config.cellSize = 2
        config.mode = .transient
        config.duration = 0
        XCTAssertThrowsError(try ThermalSimulation.run(mesh: mesh, config: config)) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-CF001")
        }
    }

    func testUnanchoredSteadyThrows() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        var config = ThermalConfig(material: aluminum)
        config.cellSize = 2
        config.faceBCs = [
            ThermalFaceBC(face: face(of: mesh, normal: Vec3(-1, 0, 0)),
                          kind: .heatFlux(watts: 10)),
        ]
        XCTAssertThrowsError(try ThermalSimulation.run(mesh: mesh, config: config)) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-CF001")
        }
    }
}
