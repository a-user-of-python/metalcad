import XCTest
import MetalCADKit
@testable import MetalCADSim

/// Known-answer tests for the Newtonian ray model. A flat plate or
/// cube face presented square to the wind is the exact case: every
/// contributing panel has cosθ = 1, so Cd must come out at the
/// Newtonian 2.0 up to pure float dust; the sphere has the analytic
/// Newtonian Cd = 1.
final class AerodynamicsTests: XCTestCase {

    private func plate() throws -> Mesh {
        // 60 × 60 mm plate, 2 mm thick, z ∈ [0, 2], centered in x/y.
        try Tessellation.box(width: 60, depth: 60, height: 2)
    }

    private func config(wind: Vec3, spacing: Double = 2) -> AeroConfig {
        var c = AeroConfig()
        c.windDirection = wind
        c.windSpeed = 20
        c.airDensity = 1.225
        c.raySpacing = spacing
        return c
    }

    // MARK: (1) Flat plate, face-on

    func testFlatPlateFaceOn() throws {
        let mesh = try plate()
        let r = try Aerodynamics.analyze(mesh: mesh, config: config(wind: Vec3(0, 0, -1)))
        // Newtonian face-on Cd = 2.
        XCTAssertEqual(r.dragCoefficient, 2.0, accuracy: 0.2)
        // Force purely along the wind (pushing the plate downstream,
        // i.e. -z): no sideways component beyond float dust.
        XCTAssertEqual(r.totalForce.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.totalForce.y, 0, accuracy: 1e-9)
        XCTAssertLessThan(r.totalForce.z, 0)
        XCTAssertEqual(r.sideForce.length, 0, accuracy: 1e-9)
        // Analytic drag: 2 · q · A, q = ½·1.225·20² = 245 Pa, A = 3600 mm².
        XCTAssertEqual(r.dragForce, 2 * 245 * 3600e-6, accuracy: 1e-6)
        // Every lattice ray hits; frontal area = the plate's face.
        XCTAssertEqual(r.raysHit, r.raysCast)
        XCTAssertEqual(r.frontalArea, 3600, accuracy: 1e-6)
        // Center of pressure ≈ plate center = bounds center (0, 0, 1).
        XCTAssertEqual(r.centerOfPressure.x, 0, accuracy: 1.5)
        XCTAssertEqual(r.centerOfPressure.y, 0, accuracy: 1.5)
        XCTAssertEqual(r.centerOfPressure.z, 1, accuracy: 1.5)
        // One sample per hit ray, all at Cp = 2.
        XCTAssertEqual(r.samples.count, r.raysHit)
        XCTAssertTrue(r.samples.allSatisfy { abs($0.pressureCoefficient - 2) < 1e-9 })
    }

    // MARK: (2) Same plate, edge-on

    func testFlatPlateEdgeOn() throws {
        let mesh = try plate()
        let face = try Aerodynamics.analyze(mesh: mesh, config: config(wind: Vec3(0, 0, -1)))
        let edge = try Aerodynamics.analyze(mesh: mesh, config: config(wind: Vec3(1, 0, 0)))
        // Only the 2 mm edge is presented: silhouette 60 × 2 mm.
        XCTAssertEqual(edge.frontalArea, 120, accuracy: 18)
        XCTAssertLessThan(edge.raysHit * 10, face.raysHit)
        // Drag collapses to the edge's share (~1/30 of face-on).
        XCTAssertLessThan(edge.dragForce, face.dragForce * 0.05)
        XCTAssertGreaterThan(edge.dragForce, 0)
    }

    // MARK: (3) Cube face-on and sphere

    func testCubeFaceOn() throws {
        let cube = try Tessellation.box(width: 30, depth: 30, height: 30)
        let r = try Aerodynamics.analyze(mesh: cube, config: config(wind: Vec3(0, 0, -1), spacing: 3))
        XCTAssertEqual(r.dragCoefficient, 2.0, accuracy: 0.2)
        XCTAssertEqual(r.frontalArea, 900, accuracy: 1e-6)
    }

    func testSphere() throws {
        let sphere = try Tessellation.sphere(radius: 20, segments: 128, rings: 96)
        let r = try Aerodynamics.analyze(mesh: sphere, config: config(wind: Vec3(1, 0, 0), spacing: 1))
        // Analytic Newtonian sphere Cd = 1 (facets + lattice ≈ ±15%).
        XCTAssertEqual(r.dragCoefficient, 1.0, accuracy: 0.15)
        // Frontal area ≈ π r².
        XCTAssertEqual(r.frontalArea, Double.pi * 400, accuracy: Double.pi * 400 * 0.05)
        // Symmetry: side force ~ 0 and CoP near the center.
        XCTAssertLessThan(r.sideForce.length, abs(r.dragForce) * 0.02)
        XCTAssertLessThan(r.centerOfPressure.distance(to: .zero), 2)
    }

    // MARK: (4) Plate at 45°

    func testPlateAt45Degrees() throws {
        let mesh = try plate()
        let s = (0.5).squareRoot()
        let wind = Vec3(s, 0, -s)
        let r = try Aerodynamics.analyze(mesh: mesh, config: config(wind: wind))
        // Newtonian force acts along the plate normal: F ≈ -|F|·(0,0,1)
        // (the thin edge face adds only a few % along +x).
        let fHat = r.totalForce * (1 / r.totalForce.length)
        XCTAssertGreaterThan(fHat.dot(Vec3(0, 0, -1)), 0.95)
        // Drag is the wind-axis component: drag ≈ |F| · cos45°.
        XCTAssertEqual(r.dragForce, r.totalForce.length * s,
                       accuracy: r.totalForce.length * 0.15)
        // CoP stays on the plate.
        XCTAssertLessThan(abs(r.centerOfPressure.x), 31)
        XCTAssertLessThan(abs(r.centerOfPressure.y), 31)
        XCTAssertLessThan(abs(r.centerOfPressure.z - 1), 3)
    }

    // MARK: (5) Validation

    func testValidation() throws {
        let mesh = try plate()
        var c = config(wind: .zero)
        XCTAssertThrowsError(try Aerodynamics.analyze(mesh: mesh, config: c)) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-IN003")
        }
        c = config(wind: Vec3(1, 0, 0)); c.windSpeed = -5
        XCTAssertThrowsError(try Aerodynamics.analyze(mesh: mesh, config: c)) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-CF001")
        }
        c = config(wind: Vec3(1, 0, 0)); c.airDensity = .nan
        XCTAssertThrowsError(try Aerodynamics.analyze(mesh: mesh, config: c)) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-CF002")
        }
        c = config(wind: Vec3(1, 0, 0)); c.raySpacing = 0
        XCTAssertThrowsError(try Aerodynamics.analyze(mesh: mesh, config: c)) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-CF001")
        }
        XCTAssertThrowsError(try Aerodynamics.analyze(mesh: Mesh(), config: config(wind: Vec3(1, 0, 0)))) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-IN001")
        }
        // Sweep parameter validation.
        c = config(wind: Vec3(1, 0, 0))
        XCTAssertThrowsError(try Aerodynamics.sweep(mesh: mesh, config: c, yawRange: -45...45, yawStep: 0)) {
            XCTAssertEqual(($0 as? SimError)?.code, "MSIM-CF001")
        }
    }

    // MARK: (6) Sweep

    func testSweep() throws {
        let cube = try Tessellation.box(width: 30, depth: 30, height: 30)
        var c = AeroConfig()
        c.windDirection = Vec3(1, 0, 0)
        c.windSpeed = 20
        c.raySpacing = 5
        let entries = try Aerodynamics.sweep(mesh: cube, config: c,
                                             yawRange: -45...45, yawStep: 15)
        XCTAssertEqual(entries.count, 7)
        XCTAssertEqual(entries.first?.yawDegrees, -45)
        XCTAssertEqual(entries.last?.yawDegrees, 45)
        // Endpoints and center match direct runs at those directions.
        func direct(yaw: Double) throws -> AeroResult {
            let a = yaw * .pi / 180
            var cc = c
            cc.windDirection = Vec3(cos(a), sin(a), 0)
            return try Aerodynamics.analyze(mesh: cube, config: cc)
        }
        let mid = try direct(yaw: 0)
        XCTAssertEqual(entries[3].dragCoefficient, mid.dragCoefficient, accuracy: 1e-9)
        let lo = try direct(yaw: -45)
        XCTAssertEqual(entries[0].dragCoefficient, lo.dragCoefficient, accuracy: 1e-9)
        let hi = try direct(yaw: 45)
        XCTAssertEqual(entries[6].dragCoefficient, hi.dragCoefficient, accuracy: 1e-9)
        // Symmetric cube: yaw -45 and +45 give the same Cd, and Cd
        // varies gently between neighbours.
        XCTAssertEqual(entries[0].dragCoefficient, entries[6].dragCoefficient, accuracy: 1e-9)
        for i in 1..<entries.count {
            XCTAssertLessThan(abs(entries[i].dragCoefficient - entries[i - 1].dragCoefficient), 0.6)
        }
        // Pitch-only sweep: 1 yaw × 3 pitches; +30° tilts the wind up.
        let pitched = try Aerodynamics.sweep(mesh: cube, config: c,
                                             yawRange: 0...0, yawStep: 15,
                                             pitchRange: -30...30, pitchStep: 30)
        XCTAssertEqual(pitched.count, 3)
        var up = c
        let a30 = 30.0 * .pi / 180
        up.windDirection = Vec3(cos(a30), 0, sin(a30))
        let upDirect = try Aerodynamics.analyze(mesh: cube, config: up)
        XCTAssertEqual(pitched[2].pitchDegrees, 30)
        XCTAssertEqual(pitched[2].dragCoefficient, upDirect.dragCoefficient, accuracy: 1e-9)
    }

    // MARK: Lee-side rule smoke test

    func testLeeSideOnConvexPartChangesNothing() throws {
        // On a convex part every re-crossing faces downstream, so the
        // lee-side rule must reproduce the first-hit result exactly.
        let cube = try Tessellation.box(width: 30, depth: 30, height: 30)
        var c = config(wind: Vec3(0, 0, -1), spacing: 3)
        let front = try Aerodynamics.analyze(mesh: cube, config: c)
        c.includeLeeSide = true
        let lee = try Aerodynamics.analyze(mesh: cube, config: c)
        XCTAssertEqual(lee.dragForce, front.dragForce, accuracy: 1e-9)
        XCTAssertEqual(lee.samples.count, front.samples.count)
    }
}
