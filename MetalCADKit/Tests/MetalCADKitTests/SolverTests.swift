import XCTest
@testable import MetalCADKit

/// 50 checks: the constraint solver — DOF accounting, convergence,
/// conflict and dangling detection, and "failure never corrupts the sketch".
final class SolverTests: XCTestCase {

    func testSingleLineDOF() {
        var s = Sketch(name: "l")
        s.addLine(Vec2(0, 0), Vec2(10, 0))
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 4)
    }

    func testNoEntitiesDOFZero() {
        let s = Sketch(name: "e")
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 0)
    }

    func testHorizontalRemovesOneDOF() {
        var s = Sketch(name: "l")
        let id = s.addLine(Vec2(0, 1), Vec2(10, 3))
        s.constraints.append(.horizontal(entity: id))
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 3)
    }

    func testFixedPointRemovesTwoDOF() {
        var s = Sketch(name: "l")
        let id = s.addLine(Vec2(0, 0), Vec2(10, 0))
        s.constraints.append(.fixedPoint(entity: id, kind: .start, at: Vec2(0, 0)))
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 2)
    }

    func testSolveHorizontal() throws {
        var s = Sketch(name: "l")
        let id = s.addLine(Vec2(0, 1), Vec2(10, 3))
        s.constraints.append(.horizontal(entity: id))
        let result = try SketchSolver.solve(&s)
        let e = s.entity(id)!
        XCTAssertEqual(e.resolve(.start)!.y, e.resolve(.end)!.y, accuracy: 1e-7)
        XCTAssertEqual(result.degreesOfFreedom, 3)
        XCTAssertLessThan(result.residual, 1e-9)
    }

    func testSolveDistance() throws {
        var s = Sketch(name: "l")
        let id = s.addLine(Vec2(0, 0), Vec2(3, 0))
        s.constraints.append(.distancePoints(entityA: id, kindA: .start, entityB: id, kindB: .end, value: 10))
        try SketchSolver.solve(&s)
        let e = s.entity(id)!
        XCTAssertEqual(e.resolve(.start)!.distance(to: e.resolve(.end)!), 10, accuracy: 1e-6)
    }

    func testSolveFullyConstrainedRectangle() throws {
        var s = Sketch(name: "rect")
        let ids = s.addRectangle(from: Vec2(1, 1), to: Vec2(9, 5))
        // Corners coincident.
        for i in 0..<4 {
            let cur = ids[i], nxt = ids[(i + 1) % 4]
            s.constraints.append(.coincident(entityA: cur, kindA: .end, entityB: nxt, kindB: .start))
        }
        s.constraints.append(.horizontal(entity: ids[0]))
        s.constraints.append(.horizontal(entity: ids[2]))
        s.constraints.append(.vertical(entity: ids[1]))
        s.constraints.append(.vertical(entity: ids[3]))
        s.constraints.append(.fixedPoint(entity: ids[0], kind: .start, at: Vec2(0, 0)))
        s.constraints.append(.distancePoints(entityA: ids[0], kindA: .start, entityB: ids[0], kindB: .end, value: 20))
        s.constraints.append(.distancePoints(entityA: ids[1], kindA: .start, entityB: ids[1], kindB: .end, value: 10))
        let result = try SketchSolver.solve(&s)
        XCTAssertEqual(result.degreesOfFreedom, 0)
        let (profiles, _) = try s.extractProfiles()
        XCTAssertEqual(profiles[0].area, 200, accuracy: 1e-6)
    }

    func testConflictingConstraintsThrowSV302() {
        var s = Sketch(name: "fight")
        let id = s.addLine(Vec2(0, 0), Vec2(3, 0))
        s.constraints.append(.fixedPoint(entity: id, kind: .start, at: Vec2(0, 0)))
        s.constraints.append(.fixedPoint(entity: id, kind: .end, at: Vec2(3, 0)))
        s.constraints.append(.distancePoints(entityA: id, kindA: .start, entityB: id, kindB: .end, value: 10))
        XCTAssertThrowsError(try SketchSolver.solve(&s)) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-SV302")
        }
    }

    func testFailureLeavesSketchUntouched() {
        var s = Sketch(name: "fight")
        let id = s.addLine(Vec2(0, 0), Vec2(3, 0))
        s.constraints.append(.fixedPoint(entity: id, kind: .start, at: Vec2(0, 0)))
        s.constraints.append(.fixedPoint(entity: id, kind: .end, at: Vec2(3, 0)))
        s.constraints.append(.distancePoints(entityA: id, kindA: .start, entityB: id, kindB: .end, value: 99))
        let before = s
        _ = try? SketchSolver.solve(&s)
        XCTAssertEqual(s, before)
    }

    func testDanglingConstraintThrowsSV306() {
        var s = Sketch(name: "dangle")
        s.addLine(Vec2(0, 0), Vec2(1, 1))
        s.constraints.append(.horizontal(entity: 9999))
        XCTAssertThrowsError(try SketchSolver.solve(&s)) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-SV306")
        }
    }

    func testCoincidentPullsPointsTogether() throws {
        var s = Sketch(name: "c")
        let a = s.addLine(Vec2(0, 0), Vec2(5, 0))
        let b = s.addLine(Vec2(7, 2), Vec2(12, 2))
        s.constraints.append(.coincident(entityA: a, kindA: .end, entityB: b, kindB: .start))
        try SketchSolver.solve(&s)
        let pa = s.entity(a)!.resolve(.end)!
        let pb = s.entity(b)!.resolve(.start)!
        XCTAssertEqual(pa.distance(to: pb), 0, accuracy: 1e-6)
    }

    func testRadiusConstraint() throws {
        var s = Sketch(name: "c")
        let id = s.addCircle(Vec2(0, 0), 5)
        s.constraints.append(.radius(entity: id, value: 12))
        try SketchSolver.solve(&s)
        guard case .circle(_, _, let r, _) = s.entity(id)! else { return XCTFail() }
        XCTAssertEqual(r, 12, accuracy: 1e-6)
    }

    func testDiameterConstraint() throws {
        var s = Sketch(name: "c")
        let id = s.addCircle(Vec2(0, 0), 5)
        s.constraints.append(.diameter(entity: id, value: 30))
        try SketchSolver.solve(&s)
        guard case .circle(_, _, let r, _) = s.entity(id)! else { return XCTFail() }
        XCTAssertEqual(r, 15, accuracy: 1e-6)
    }

    func testParallelConstraint() throws {
        var s = Sketch(name: "p")
        let a = s.addLine(Vec2(0, 0), Vec2(10, 0))
        let b = s.addLine(Vec2(0, 5), Vec2(10, 8))
        s.constraints.append(.parallel(entityA: a, entityB: b))
        try SketchSolver.solve(&s)
        let d1 = s.entity(a)!.resolve(.end)! - s.entity(a)!.resolve(.start)!
        let d2 = s.entity(b)!.resolve(.end)! - s.entity(b)!.resolve(.start)!
        XCTAssertEqual(abs(d1.normalized.cross(d2.normalized)), 0, accuracy: 1e-6)
    }

    func testPerpendicularConstraint() throws {
        var s = Sketch(name: "p")
        let a = s.addLine(Vec2(0, 0), Vec2(10, 0))
        let b = s.addLine(Vec2(0, 0), Vec2(3, 3))
        s.constraints.append(.perpendicular(entityA: a, entityB: b))
        try SketchSolver.solve(&s)
        let d1 = s.entity(a)!.resolve(.end)! - s.entity(a)!.resolve(.start)!
        let d2 = s.entity(b)!.resolve(.end)! - s.entity(b)!.resolve(.start)!
        XCTAssertEqual(d1.normalized.dot(d2.normalized), 0, accuracy: 1e-6)
    }

    func testEqualLength() throws {
        var s = Sketch(name: "e")
        let a = s.addLine(Vec2(0, 0), Vec2(6, 0))
        let b = s.addLine(Vec2(0, 5), Vec2(2, 5))
        s.constraints.append(.equalLength(entityA: a, entityB: b))
        try SketchSolver.solve(&s)
        let la = s.entity(a)!.resolve(.start)!.distance(to: s.entity(a)!.resolve(.end)!)
        let lb = s.entity(b)!.resolve(.start)!.distance(to: s.entity(b)!.resolve(.end)!)
        XCTAssertEqual(la, lb, accuracy: 1e-6)
    }

    func testPointOnCircle() throws {
        var s = Sketch(name: "poc")
        let c = s.addCircle(Vec2(0, 0), 10)
        let p = s.addPoint(Vec2(3, 3))
        // Pin the circle; then the point itself must travel to the rim.
        s.constraints.append(.fixedPoint(entity: c, kind: .center, at: Vec2(0, 0)))
        s.constraints.append(.radius(entity: c, value: 10))
        s.constraints.append(.pointOnCircle(pointEntity: p, pointKind: .whole, circleEntity: c))
        try SketchSolver.solve(&s)
        let pt = s.entity(p)!.resolve(.whole)!
        XCTAssertEqual(pt.length, 10, accuracy: 1e-6)
    }

    func testPointOnLine() throws {
        var s = Sketch(name: "pol")
        let l = s.addLine(Vec2(0, 0), Vec2(10, 10))
        let p = s.addPoint(Vec2(5, 0))
        // Pin the line; the point must move onto it.
        s.constraints.append(.fixedPoint(entity: l, kind: .start, at: Vec2(0, 0)))
        s.constraints.append(.fixedPoint(entity: l, kind: .end, at: Vec2(10, 10)))
        s.constraints.append(.pointOnLine(pointEntity: p, pointKind: .whole, lineEntity: l))
        try SketchSolver.solve(&s)
        let pt = s.entity(p)!.resolve(.whole)!
        XCTAssertEqual(pt.x, pt.y, accuracy: 1e-6)
    }

    func testTangentLineCircle() throws {
        var s = Sketch(name: "tan")
        let l = s.addLine(Vec2(-10, 8), Vec2(10, 8))
        let c = s.addCircle(Vec2(0, 0), 5)
        s.constraints.append(.tangentLineCircle(lineEntity: l, circleEntity: c))
        try SketchSolver.solve(&s)
        let a = s.entity(l)!.resolve(.start)!, b = s.entity(l)!.resolve(.end)!
        guard case .circle(_, let cc, let r, _) = s.entity(c)! else { return XCTFail() }
        let dist = abs((b - a).cross(cc - a)) / (b - a).length
        XCTAssertEqual(dist, r, accuracy: 1e-5)
    }

    func testAngleConstraint() throws {
        var s = Sketch(name: "ang")
        let a = s.addLine(Vec2(0, 0), Vec2(10, 0))
        let b = s.addLine(Vec2(0, 0), Vec2(10, 1))
        s.constraints.append(.angleBetween(entityA: a, entityB: b, degrees: 45))
        try SketchSolver.solve(&s)
        let d1 = (s.entity(a)!.resolve(.end)! - s.entity(a)!.resolve(.start)!).normalized
        let d2 = (s.entity(b)!.resolve(.end)! - s.entity(b)!.resolve(.start)!).normalized
        XCTAssertEqual(d1.dot(d2), cos(45 * Double.pi / 180), accuracy: 1e-5)
    }

    func testSymmetricConstraint() throws {
        var s = Sketch(name: "sym")
        let axis = s.addLine(Vec2(0, -10), Vec2(0, 10), construction: true)
        let a = s.addPoint(Vec2(-4, 2))
        let b = s.addPoint(Vec2(1, 8))
        // Pin the axis and point A; B must mirror A across the axis.
        s.constraints.append(.fixedPoint(entity: axis, kind: .start, at: Vec2(0, -10)))
        s.constraints.append(.fixedPoint(entity: axis, kind: .end, at: Vec2(0, 10)))
        s.constraints.append(.fixedPoint(entity: a, kind: .whole, at: Vec2(-4, 2)))
        s.constraints.append(.symmetric(entityA: a, kindA: .whole, entityB: b, kindB: .whole, axisLine: axis))
        try SketchSolver.solve(&s)
        let pa = s.entity(a)!.resolve(.whole)!
        let pb = s.entity(b)!.resolve(.whole)!
        XCTAssertEqual(pa.x + pb.x, 0, accuracy: 1e-5)
        XCTAssertEqual(pa.y, pb.y, accuracy: 1e-5)
    }

    func testSolveIsIdempotent() throws {
        var s = Sketch(name: "l")
        let id = s.addLine(Vec2(0, 1), Vec2(10, 3))
        s.constraints.append(.horizontal(entity: id))
        try SketchSolver.solve(&s)
        let once = s
        try SketchSolver.solve(&s)
        XCTAssertEqual(s, once)
    }

    func testCircleDOF() {
        var s = Sketch(name: "c")
        s.addCircle(Vec2(0, 0), 5)
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 3)
    }

    func testRadiusConstraintDOF() {
        var s = Sketch(name: "c")
        let id = s.addCircle(Vec2(0, 0), 5)
        s.constraints.append(.radius(entity: id, value: 5))
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 2)
    }

    func testRedundantConstraintWarning() throws {
        var s = Sketch(name: "r")
        let id = s.addLine(Vec2(0, 0), Vec2(10, 0))
        s.constraints.append(.horizontal(entity: id))
        s.constraints.append(.horizontal(entity: id))
        let result = try SketchSolver.solve(&s)
        XCTAssertTrue(result.warnings.contains { $0.code == "MCAD-SV303" })
    }
}

// MARK: Top-up checks (DOF accounting & solver behavior)

extension SolverTests {
    func testVerticalConstraintSolve() throws {
        var s = Sketch(name: "v")
        let id = s.addLine(Vec2(1, 0), Vec2(3, 10))
        s.constraints.append(.vertical(entity: id))
        try SketchSolver.solve(&s)
        let e = s.entity(id)!
        XCTAssertEqual(e.resolve(.start)!.x, e.resolve(.end)!.x, accuracy: 1e-7)
    }

    func testArcDOF() {
        var s = Sketch(name: "a")
        s.entities.append(.arc(id: s.allocateID(), center: Vec2(0, 0), radius: 5, startAngle: 0, endAngle: 1, construction: false))
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 5)
    }

    func testPointDOF() {
        var s = Sketch(name: "p")
        s.addPoint(Vec2(1, 1))
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 2)
    }

    func testTwoLinesDOF() {
        var s = Sketch(name: "p")
        s.addLine(Vec2(0, 0), Vec2(1, 0))
        s.addLine(Vec2(0, 5), Vec2(1, 5))
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 8)
    }

    func testSolveNoConstraintsIsIdentity() throws {
        var s = Sketch(name: "i")
        s.addLine(Vec2(1, 2), Vec2(3, 4))
        let before = s
        let r = try SketchSolver.solve(&s)
        XCTAssertEqual(s, before)
        XCTAssertEqual(r.iterations, 0)
        XCTAssertEqual(r.degreesOfFreedom, 4)
    }

    func testEqualRadius() throws {
        var s = Sketch(name: "er")
        let a = s.addCircle(Vec2(0, 0), 5)
        let b = s.addCircle(Vec2(20, 0), 9)
        s.constraints.append(.equalRadius(entityA: a, entityB: b))
        try SketchSolver.solve(&s)
        guard case .circle(_, _, let ra, _) = s.entity(a)!, case .circle(_, _, let rb, _) = s.entity(b)! else { return XCTFail() }
        XCTAssertEqual(ra, rb, accuracy: 1e-6)
    }

    func testDistanceBetweenPoints() throws {
        var s = Sketch(name: "dp")
        let a = s.addPoint(Vec2(0, 0))
        let b = s.addPoint(Vec2(1, 0))
        s.constraints.append(.fixedPoint(entity: a, kind: .whole, at: Vec2(0, 0)))
        s.constraints.append(.distancePoints(entityA: a, kindA: .whole, entityB: b, kindB: .whole, value: 7))
        try SketchSolver.solve(&s)
        XCTAssertEqual(s.entity(b)!.resolve(.whole)!.length, 7, accuracy: 1e-6)
    }

    func testSolvePreservesConstructionFlag() throws {
        var s = Sketch(name: "cf")
        let id = s.addLine(Vec2(0, 1), Vec2(10, 3), construction: true)
        s.constraints.append(.horizontal(entity: id))
        try SketchSolver.solve(&s)
        XCTAssertTrue(s.entity(id)!.isConstruction)
    }

    func testCoincidentChain() throws {
        var s = Sketch(name: "chain")
        let a = s.addPoint(Vec2(0, 0))
        let b = s.addPoint(Vec2(5, 5))
        let c = s.addPoint(Vec2(9, 1))
        s.constraints.append(.coincident(entityA: a, kindA: .whole, entityB: b, kindB: .whole))
        s.constraints.append(.coincident(entityA: b, kindA: .whole, entityB: c, kindB: .whole))
        try SketchSolver.solve(&s)
        let pa = s.entity(a)!.resolve(.whole)!
        let pb = s.entity(b)!.resolve(.whole)!
        let pc = s.entity(c)!.resolve(.whole)!
        XCTAssertEqual(pa.distance(to: pb), 0, accuracy: 1e-6)
        XCTAssertEqual(pb.distance(to: pc), 0, accuracy: 1e-6)
    }

    func testHorizontalPlusVerticalPinsEndpoint() throws {
        var s = Sketch(name: "hv")
        let id = s.addLine(Vec2(0, 0), Vec2(4, 3))
        s.constraints.append(.horizontal(entity: id))
        s.constraints.append(.vertical(entity: id))
        let r = try SketchSolver.solve(&s)
        // Both force start == end: solvable, DOF 2 (the shared point is free).
        XCTAssertEqual(r.degreesOfFreedom, 2)
        let e = s.entity(id)!
        XCTAssertEqual(e.resolve(.start)!.distance(to: e.resolve(.end)!), 0, accuracy: 1e-6)
    }

    func testSolveEmptySketch() throws {
        var s = Sketch(name: "e")
        let r = try SketchSolver.solve(&s)
        XCTAssertEqual(r.degreesOfFreedom, 0)
        XCTAssertEqual(r.residual, 0)
    }

    func testDiameterDOF() {
        var s = Sketch(name: "d")
        let id = s.addCircle(Vec2(0, 0), 5)
        s.constraints.append(.diameter(entity: id, value: 10))
        XCTAssertEqual(SketchSolver.degreesOfFreedom(s), 2)
    }
}
