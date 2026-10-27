import XCTest
@testable import MetalCADKit

/// 50 checks: sketch entities, builders, validation, profile extraction.
final class SketchTests: XCTestCase {

    func rectSketch() -> Sketch {
        var s = Sketch(name: "rect")
        s.addRectangle(from: Vec2(0, 0), to: Vec2(20, 10))
        return s
    }

    func testRectangleHasFourLines() {
        let s = rectSketch()
        XCTAssertEqual(s.entities.count, 4)
    }

    func testRectangleProfileArea() throws {
        let (profiles, _) = try rectSketch().extractProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].area, 200, accuracy: 1e-9)
        XCTAssertTrue(profiles[0].holes.isEmpty)
    }

    func testRectangleProfileIsCCW() throws {
        let (profiles, _) = try rectSketch().extractProfiles()
        XCTAssertGreaterThan(polygonArea(profiles[0].outer), 0)
    }

    func testClockwiseRectangleNormalizes() throws {
        var s = Sketch(name: "cw")
        let pts = [Vec2(0, 0), Vec2(0, 10), Vec2(20, 10), Vec2(20, 0)]
        for i in 0..<4 { s.addLine(pts[i], pts[(i + 1) % 4]) }
        let (profiles, _) = try s.extractProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].area, 200, accuracy: 1e-9)
    }

    func testCircleProfile() throws {
        var s = Sketch(name: "c")
        s.addCircle(Vec2(0, 0), 10)
        let (profiles, _) = try s.extractProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].area, Double.pi * 100, accuracy: 2.0)
    }

    func testOpenProfileThrowsSK204() {
        var s = Sketch(name: "open")
        s.addLine(Vec2(0, 0), Vec2(10, 0))
        s.addLine(Vec2(10, 0), Vec2(10, 10))
        s.addLine(Vec2(10, 10), Vec2(0, 10))
        // missing closing line — gap from (0,10) to (0,0)
        XCTAssertThrowsError(try s.extractProfiles()) { err in
            guard let e = err as? CADError, case .profileOpen(let a, let b) = e else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(e.code, "MCAD-SK204")
            XCTAssertEqual(Set([a, b]), Set([Vec2(0, 10), Vec2(0, 0)]))
        }
    }

    func testSelfIntersectingThrowsSK205() {
        var s = Sketch(name: "bowtie")
        let p = [Vec2(0, 0), Vec2(10, 10), Vec2(10, 0), Vec2(0, 10)]
        for i in 0..<4 { s.addLine(p[i], p[(i + 1) % 4]) }
        XCTAssertThrowsError(try s.extractProfiles()) { err in
            XCTAssertEqual((err as? CADError)?.code, "MCAD-SK205")
        }
    }

    func testRectWithRectHole() throws {
        var s = Sketch(name: "plate")
        s.addRectangle(from: Vec2(0, 0), to: Vec2(40, 40))
        s.addRectangle(from: Vec2(15, 15), to: Vec2(25, 25))
        let (profiles, _) = try s.extractProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].holes.count, 1)
        XCTAssertEqual(profiles[0].area, 1600 - 100, accuracy: 1e-9)
    }

    func testIslandInsideHoleIsSeparateProfile() throws {
        var s = Sketch(name: "nested")
        s.addRectangle(from: Vec2(0, 0), to: Vec2(60, 60))
        s.addRectangle(from: Vec2(10, 10), to: Vec2(50, 50))
        s.addRectangle(from: Vec2(25, 25), to: Vec2(35, 35))
        let (profiles, _) = try s.extractProfiles()
        XCTAssertEqual(profiles.count, 2)
        let areas = profiles.map { $0.area }.sorted()
        XCTAssertEqual(areas[0], 100, accuracy: 1e-9)
        XCTAssertEqual(areas[1], 3600 - 1600, accuracy: 1e-9)
    }

    func testEmptySketchThrows() {
        let s = Sketch(name: "empty")
        XCTAssertThrowsError(try s.extractProfiles()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-SK212")
        }
    }

    func testConstructionExcludedFromProfile() throws {
        var s = Sketch(name: "cons")
        s.addRectangle(from: Vec2(0, 0), to: Vec2(10, 10))
        s.addLine(Vec2(0, 0), Vec2(10, 10), construction: true)
        let (profiles, _) = try s.extractProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].area, 100, accuracy: 1e-9)
    }

    func testDegenerateLineFlagged() {
        var s = Sketch(name: "d")
        let id = s.addLine(Vec2(1, 1), Vec2(1, 1))
        let warnings = s.validate()
        XCTAssertTrue(warnings.contains { if case .degenerateEntity(let i) = $0 { return i == id }; return false })
        XCTAssertEqual(warnings.first?.code, "MCAD-SK203")
    }

    func testDegenerateCircleFlagged() {
        var s = Sketch(name: "d")
        s.addCircle(Vec2(0, 0), 0)
        XCTAssertTrue(s.validate().contains { $0.code == "MCAD-SK203" })
    }

    func testDuplicateLineFlagged() {
        var s = Sketch(name: "d")
        s.addLine(Vec2(0, 0), Vec2(5, 0))
        s.addLine(Vec2(5, 0), Vec2(0, 0))
        XCTAssertTrue(s.validate().contains { $0.code == "MCAD-SK207" })
    }

    func testHealthySketchHasNoWarnings() {
        XCTAssertTrue(rectSketch().validate().isEmpty)
    }

    func testEntityLookup() {
        var s = Sketch(name: "x")
        let id = s.addCircle(Vec2(3, 4), 7)
        XCTAssertNotNil(s.entity(id))
        XCTAssertNil(s.entity(9999))
        XCTAssertEqual(s.entity(id)?.resolve(.center), Vec2(3, 4))
    }

    func testIDsAreUnique() {
        var s = Sketch(name: "x")
        var ids = Set<Int>()
        for i in 0..<20 { ids.insert(s.addPoint(Vec2(Double(i), 0))) }
        XCTAssertEqual(ids.count, 20)
    }

    func testLineResolveEndpoints() {
        var s = Sketch(name: "x")
        let id = s.addLine(Vec2(1, 2), Vec2(3, 4))
        XCTAssertEqual(s.entity(id)?.resolve(.start), Vec2(1, 2))
        XCTAssertEqual(s.entity(id)?.resolve(.end), Vec2(3, 4))
    }

    func testArcResolveEndpoints() {
        let e = SketchEntity.arc(id: 1, center: Vec2(0, 0), radius: 10, startAngle: 0, endAngle: .pi / 2, construction: false)
        XCTAssertEqual(e.resolve(.start), Vec2(10, 0))
        let end = e.resolve(.end)!
        XCTAssertEqual(end.x, 0, accuracy: 1e-9)
        XCTAssertEqual(end.y, 10, accuracy: 1e-9)
    }

    func testArcPolylineEndpoints() {
        let e = SketchEntity.arc(id: 1, center: Vec2(0, 0), radius: 10, startAngle: 0, endAngle: .pi, construction: false)
        let pts = e.polyline()
        XCTAssertEqual(pts.first, Vec2(10, 0))
        XCTAssertEqual(pts.last!.x, -10, accuracy: 1e-9)
        XCTAssertGreaterThan(pts.count, 4)
    }

    func testPolygonAreaSigns() {
        let ccw = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)]
        XCTAssertEqual(polygonArea(ccw), 12)
        XCTAssertEqual(polygonArea(Array(ccw.reversed())), -12)
    }

    func testPointInPolygon() {
        let sq = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
        XCTAssertTrue(pointInPolygon(Vec2(5, 5), sq))
        XCTAssertFalse(pointInPolygon(Vec2(15, 5), sq))
        XCTAssertFalse(pointInPolygon(Vec2(-1, -1), sq))
    }

    func testSegmentsCross() {
        XCTAssertNotNil(segmentsCross(Vec2(0, 0), Vec2(10, 10), Vec2(0, 10), Vec2(10, 0)))
        XCTAssertNil(segmentsCross(Vec2(0, 0), Vec2(10, 0), Vec2(0, 5), Vec2(10, 5)))
        // Touching at an endpoint is not a *proper* crossing.
        XCTAssertNil(segmentsCross(Vec2(0, 0), Vec2(10, 0), Vec2(10, 0), Vec2(10, 10)))
    }

    func testSketchCodableRoundTrip() throws {
        var s = rectSketch()
        s.constraints.append(.horizontal(entity: s.entities[0].id))
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Sketch.self, from: data)
        XCTAssertEqual(back, s)
    }

    func testTriangleProfile() throws {
        var s = Sketch(name: "tri")
        s.addLine(Vec2(0, 0), Vec2(10, 0))
        s.addLine(Vec2(10, 0), Vec2(0, 10))
        s.addLine(Vec2(0, 10), Vec2(0, 0))
        let (profiles, _) = try s.extractProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].area, 50, accuracy: 1e-9)
    }
}
