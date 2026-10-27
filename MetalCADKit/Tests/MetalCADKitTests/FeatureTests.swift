import XCTest
@testable import MetalCADKit

/// 50 checks: tessellation (primitives, extrude, revolve), the feature
/// tree rebuild, and the equation evaluator.
final class FeatureTests: XCTestCase {

    func testBoxVolume() throws {
        let m = try Tessellation.box(width: 10, depth: 10, height: 10)
        XCTAssertEqual(m.volume, 1000, accuracy: 1e-6)
        XCTAssertEqual(m.triangleCount, 12)
    }

    func testBoxWatertight() throws {
        let m = try Tessellation.box(width: 3, depth: 4, height: 5)
        XCTAssertTrue(m.isWatertight)
        XCTAssertEqual(m.openEdgeCount, 0)
    }

    func testBoxBounds() throws {
        let m = try Tessellation.box(width: 10, depth: 20, height: 30)
        XCTAssertEqual(m.bounds.size.x, 10, accuracy: 1e-9)
        XCTAssertEqual(m.bounds.size.y, 20, accuracy: 1e-9)
        XCTAssertEqual(m.bounds.size.z, 30, accuracy: 1e-9)
        XCTAssertEqual(m.bounds.min.z, 0)
    }

    func testBoxInvalidThrowsFT413() {
        XCTAssertThrowsError(try Tessellation.box(width: 0, depth: 1, height: 1)) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-FT413")
        }
    }

    func testCylinderVolume() throws {
        let m = try Tessellation.cylinder(radius: 5, height: 10, segments: 128)
        XCTAssertEqual(m.volume, Double.pi * 25 * 10, accuracy: 5)
        XCTAssertTrue(m.isWatertight)
    }

    func testSphereBoundsAndVolume() throws {
        let m = try Tessellation.sphere(radius: 10)
        XCTAssertEqual(m.bounds.size.x, 20, accuracy: 0.5)
        XCTAssertEqual(m.volume, 4.0 / 3.0 * Double.pi * 1000, accuracy: 150)
    }

    func testConeVolume() throws {
        let m = try Tessellation.cone(radius: 6, height: 9, segments: 128)
        XCTAssertEqual(m.volume, Double.pi * 36 * 9 / 3, accuracy: 5)
    }

    func testTorusVolume() throws {
        let m = try Tessellation.torus(ringRadius: 20, tubeRadius: 5, segments: 96, sides: 32)
        XCTAssertEqual(m.volume, 2 * Double.pi * Double.pi * 20 * 25, accuracy: 300)
    }

    func testTorusSelfIntersectingThrows() {
        XCTAssertThrowsError(try Tessellation.torus(ringRadius: 5, tubeRadius: 6)) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-FT413")
        }
    }

    func rectPart(padLength: Double = 5) -> Part {
        var part = Part(name: "plate")
        var s = Sketch(name: "base")
        s.addRectangle(from: Vec2(0, 0), to: Vec2(20, 10))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: padLength)))
        return part
    }

    func testPadVolume() {
        let r = DocumentEngine.rebuild(part: rectPart())
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 20 * 10 * 5, accuracy: 1e-6)
        XCTAssertTrue(r.mesh.welded().isWatertight)
    }

    func testPadZeroLengthFailsWithFT402() {
        let r = DocumentEngine.rebuild(part: rectPart(padLength: 0))
        XCTAssertEqual(r.firstError?.code, "MCAD-FT402")
        XCTAssertEqual(r.statuses.first?.errorCode, "MCAD-FT402")
        XCTAssertFalse(r.statuses.first!.ok)
    }

    func testPadWithHole() {
        var part = Part(name: "plate")
        var s = Sketch(name: "s")
        s.addRectangle(from: Vec2(0, 0), to: Vec2(40, 40))
        s.addCircle(Vec2(20, 20), 5)
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 10)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, (1600 - Double.pi * 25) * 10, accuracy: 60)
        XCTAssertTrue(r.mesh.welded().isWatertight)
    }

    func testPadOpenSketchFails() {
        var part = Part(name: "p")
        var s = Sketch(name: "s")
        s.addLine(Vec2(0, 0), Vec2(10, 0))
        s.addLine(Vec2(10, 0), Vec2(10, 10))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 5)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-SK204")
    }

    func testRevolveMakesCylinder() {
        var part = Part(name: "shaft")
        var s = Sketch(name: "s")
        // Rectangle from axis (x=0) out to r=5, height 20.
        let ids = s.addRectangle(from: Vec2(0, 0), to: Vec2(5, 20))
        part.sketches.append(s)
        part.features.append(Feature(name: "Rev", kind: .revolve(sketchID: s.id, axisEntityID: ids[3], angleDegrees: 360)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, Double.pi * 25 * 20, accuracy: 60)
    }

    func testRevolveCrossingAxisThrowsFT404() {
        var part = Part(name: "bad")
        var s = Sketch(name: "s")
        s.addRectangle(from: Vec2(-5, 0), to: Vec2(5, 10))
        // Construction axis straight through the middle of the profile.
        let axis = s.addLine(Vec2(0, -5), Vec2(0, 15), construction: true)
        part.sketches.append(s)
        part.features.append(Feature(name: "Rev", kind: .revolve(sketchID: s.id, axisEntityID: axis, angleDegrees: 360)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT404")
    }

    func testRevolvePartialHasCaps() {
        var part = Part(name: "wedge")
        var s = Sketch(name: "s")
        let ids = s.addRectangle(from: Vec2(2, 0), to: Vec2(6, 10))
        part.sketches.append(s)
        part.features.append(Feature(name: "Rev", kind: .revolve(sketchID: s.id, axisEntityID: ids[3], angleDegrees: 90)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Axis is the rectangle's left edge (x=2), so this is a quarter of a
        // solid cylinder of radius 4, height 10: (pi*16/4)*10.
        let expected = (Double.pi * 16 / 4) * 10
        XCTAssertEqual(r.mesh.volume, expected, accuracy: expected * 0.02)
    }

    func testRebuildStopsAfterFailure() {
        var part = rectPart(padLength: 0)
        part.features.append(Feature(name: "Ball", kind: .primitive(kind: .sphere, params: ["diameter": 10])))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.statuses.count, 2)
        XCTAssertFalse(r.statuses[0].ok)
        XCTAssertFalse(r.statuses[1].ok)
        XCTAssertEqual(r.statuses[1].message, "paused")
    }

    func testSuppressedFeatureSkipped() {
        var part = rectPart()
        part.features.append(Feature(name: "Bad", kind: .pad(sketchID: "missing", length: 5)))
        part.features[1].suppressed = true
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.statuses[1].message, "suppressed")
    }

    func testMissingSketchFailsByName() {
        var part = Part(name: "p")
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: "nope", length: 5)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-DC106")
    }

    func testPrimitiveFeatures() {
        var part = Part(name: "p")
        part.features.append(Feature(name: "Box", kind: .primitive(kind: .box, params: ["width": 10, "depth": 10, "height": 10])))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 1000, accuracy: 1e-6)
    }

    func testPocketMissingSketchFailsByName() {
        var part = Part(name: "p")
        part.features.append(Feature(name: "Pocket", kind: .pocket(sketchID: "x", depth: 3)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-DC106")
    }

    func testFilletWorks() {
        // v3: fillet is a real edge finish now (was FT407 in v1/v2).
        var part = rectPart()
        let before = DocumentEngine.rebuild(part: part).mesh.volume
        part.features.append(Feature(name: "Round", kind: .fillet(radius: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertLessThan(r.mesh.volume, before)
        XCTAssertGreaterThan(r.mesh.volume, before * 0.8)
    }

    func testPatternExpands() throws {
        let box = try Tessellation.box(width: 2, depth: 2, height: 2)
        let patterned = try DocumentEngine.applyPattern(mesh: box, count: 3, spacing: Vec3(5, 0, 0))
        XCTAssertEqual(patterned.triangleCount, 36)
        XCTAssertEqual(patterned.bounds.size.x, 12, accuracy: 1e-9)
        XCTAssertEqual(patterned.volume, 24, accuracy: 1e-6)
    }

    func testPatternInvalidCount() {
        let box = Mesh()
        XCTAssertThrowsError(try DocumentEngine.applyPattern(mesh: box, count: 0, spacing: Vec3(1, 0, 0))) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-FT411")
        }
    }

    func testMeshSignedVolumeOrientation() throws {
        let m = try Tessellation.box(width: 2, depth: 2, height: 2)
        XCTAssertGreaterThan(m.signedVolume, 0)
    }

    func testTranslatedMesh() throws {
        let m = try Tessellation.box(width: 2, depth: 2, height: 2)
        let t = m.translated(by: Vec3(10, 0, 0))
        XCTAssertEqual(t.bounds.min.x, 9, accuracy: 1e-9)
        XCTAssertEqual(t.volume, m.volume, accuracy: 1e-9)
    }

    // MARK: Equations

    func testEquationArithmetic() throws {
        XCTAssertEqual(try EquationEvaluator.evaluate("2+3*4", variables: [:]), 14)
        XCTAssertEqual(try EquationEvaluator.evaluate("(2+3)*4", variables: [:]), 20)
        XCTAssertEqual(try EquationEvaluator.evaluate("2^10", variables: [:]), 1024)
        XCTAssertEqual(try EquationEvaluator.evaluate("10/4", variables: [:]), 2.5)
        XCTAssertEqual(try EquationEvaluator.evaluate("-3+5", variables: [:]), 2)
    }

    func testEquationVariables() throws {
        XCTAssertEqual(try EquationEvaluator.evaluate("width/2", variables: ["width": 30]), 15)
        XCTAssertEqual(try EquationEvaluator.evaluate("pi*r^2", variables: ["r": 1]), Double.pi, accuracy: 1e-12)
    }

    func testEquationFunctions() throws {
        XCTAssertEqual(try EquationEvaluator.evaluate("sqrt(144)", variables: [:]), 12)
        XCTAssertEqual(try EquationEvaluator.evaluate("abs(-7)", variables: [:]), 7)
        XCTAssertEqual(try EquationEvaluator.evaluate("min(3, 9, 4)", variables: [:]), 3)
        XCTAssertEqual(try EquationEvaluator.evaluate("max(3, 9, 4)", variables: [:]), 9)
        XCTAssertEqual(try EquationEvaluator.evaluate("cos(0)", variables: [:]), 1)
    }

    func testEquationParseErrorDC111() {
        XCTAssertThrowsError(try EquationEvaluator.evaluate("2 + * 3", variables: [:])) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-DC111")
        }
        XCTAssertThrowsError(try EquationEvaluator.evaluate("(1+2", variables: [:])) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-DC111")
        }
    }

    func testEquationEvalErrorsDC112() {
        XCTAssertThrowsError(try EquationEvaluator.evaluate("1/0", variables: [:])) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-DC112")
        }
        XCTAssertThrowsError(try EquationEvaluator.evaluate("nope + 1", variables: [:])) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-DC112")
        }
        XCTAssertThrowsError(try EquationEvaluator.evaluate("sqrt(-1)", variables: [:])) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-DC112")
        }
    }
}
