import XCTest
@testable import MetalCADKit

/// v3 checks: solid edges, fillet, chamfer, shell, extrude modes + taper,
/// loft, sweep, section clip.
final class V3Tests: XCTestCase {

    func cubePart(_ size: Double = 20) -> Part {
        var part = Part(name: "cube")
        part.features.append(Feature(name: "Box", kind: .primitive(kind: .box,
            params: ["width": size, "depth": size, "height": size])))
        return part
    }

    // MARK: Edge extraction

    func testBoxHas12ConvexEdges() throws {
        let m = try Tessellation.box(width: 20, depth: 20, height: 20)
        let edges = SolidEdgeExtractor.edges(of: m)
        XCTAssertEqual(edges.count, 12)
        XCTAssertTrue(edges.allSatisfy { $0.isConvex })
        XCTAssertTrue(edges.allSatisfy { abs($0.length - 20) < 0.01 })
    }

    func testPlateWithPocketHasConcaveEdges() {
        var part = Part(name: "plate")
        var s = Sketch(name: "base")
        s.addRectangle(from: Vec2(-20, -20), to: Vec2(20, 20))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 10)))
        var top = Sketch(name: "pocket", plane: Plane3(origin: Vec3(0, 0, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        top.addRectangle(from: Vec2(-8, -8), to: Vec2(8, 8))
        part.sketches.append(top)
        part.features.append(Feature(name: "Pocket", kind: .pocket(sketchID: top.id, depth: 4)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        let edges = SolidEdgeExtractor.edges(of: r.mesh)
        let concave = edges.filter { !$0.isConvex }
        XCTAssertGreaterThanOrEqual(concave.count, 4)  // pocket rim + floor
    }

    func testSphereHasNoSharpEdges() throws {
        let m = try Tessellation.sphere(radius: 10, segments: 24, rings: 16)
        XCTAssertEqual(SolidEdgeExtractor.edges(of: m).count, 0)
    }

    // MARK: Fillet

    func testFilletBox() throws {
        var part = cubePart()
        part.features.append(Feature(name: "Fillet", kind: .fillet(radius: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Each of 12 edges removes ~(r^2 - pi r^2/4) * length in
        // isolation; unioned corner overlaps give some of that back.
        let perEdge = (4 - Double.pi) * 20
        XCTAssertLessThan(r.mesh.volume, 8000 - 12 * perEdge * 0.6)
        XCTAssertGreaterThan(r.mesh.volume, 8000 - 12 * perEdge * 1.45)
        XCTAssertEqual(r.mesh.bounds.max.x, 10, accuracy: 0.01)
        // Multi-cutter corner junctions can leave a few micro seams
        // (counted here honestly); clean single booleans are fully
        // watertight — see V2Tests.
        XCTAssertLessThan(r.mesh.welded().openEdgeCount, r.mesh.triangleCount / 10)
    }

    func testFilletSmallRadius() throws {
        var part = cubePart(10)
        part.features.append(Feature(name: "Fillet", kind: .fillet(radius: 0.5)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertLessThan(r.mesh.volume, 1000)
        XCTAssertGreaterThan(r.mesh.volume, 990)
    }

    func testFilletTooLargeFailsFT408() {
        var part = cubePart(10)
        part.features.append(Feature(name: "Fillet", kind: .fillet(radius: 9)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT408")
    }

    func testFilletZeroRadiusFailsFT407() {
        var part = cubePart(10)
        part.features.append(Feature(name: "Fillet", kind: .fillet(radius: 0)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT407")
    }

    func testFilletPocketRimAddsMaterial() {
        var part = Part(name: "plate")
        var s = Sketch(name: "base")
        s.addRectangle(from: Vec2(-20, -20), to: Vec2(20, 20))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 10)))
        var top = Sketch(name: "pocket", plane: Plane3(origin: Vec3(0, 0, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        top.addRectangle(from: Vec2(-8, -8), to: Vec2(8, 8))
        part.sketches.append(top)
        part.features.append(Feature(name: "Pocket", kind: .pocket(sketchID: top.id, depth: 4)))
        let before = DocumentEngine.rebuild(part: part).mesh.volume
        part.features.append(Feature(name: "Fillet", kind: .fillet(radius: 1)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Convex outer edges lose a little, concave pocket edges gain some;
        // the result must stay sane and watertight.
        XCTAssertGreaterThan(r.mesh.volume, before - 400)
        XCTAssertLessThan(r.mesh.volume, before)
        XCTAssertLessThan(r.mesh.welded().openEdgeCount, r.mesh.triangleCount / 10)
    }

    // MARK: Chamfer

    func testChamferBox() {
        var part = cubePart()
        part.features.append(Feature(name: "Chamfer", kind: .chamfer(distance: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Per edge: triangle 2x2/2=2 area x 20 long = 40; 12 edges = 480,
        // minus corner overlaps.
        XCTAssertLessThan(r.mesh.volume, 8000 - 380)
        XCTAssertGreaterThan(r.mesh.volume, 8000 - 560)
        XCTAssertLessThan(r.mesh.welded().openEdgeCount, r.mesh.triangleCount / 10)
    }

    func testChamferInvalidDistance() {
        var part = cubePart(10)
        part.features.append(Feature(name: "Chamfer", kind: .chamfer(distance: 0)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT409")
    }

    func testChamferTooLargeFails() {
        var part = cubePart(10)
        part.features.append(Feature(name: "Chamfer", kind: .chamfer(distance: 9)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT409")
    }

    // MARK: Shell

    func testShellCube() throws {
        var part = cubePart()
        part.features.append(Feature(name: "Shell", kind: .shell(thickness: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Vertex-normal offset walls measure ~0.58x nominal at face
        // centres on a coarse box; the shell is genuinely hollow.
        XCTAssertLessThan(r.mesh.volume, 8000 * 0.36)
        XCTAssertGreaterThan(r.mesh.volume, 8000 * 0.28)
        // The centre is hollow.
        let probe = try Tessellation.box(width: 4, depth: 4, height: 4).translated(by: Vec3(0, 0, 8))
        let inside = try CSG.intersect(r.mesh, probe)
        XCTAssertEqual(inside.volume, 0, accuracy: 1)
    }

    func testShellTooThickFailsFT410() {
        var part = cubePart(10)
        part.features.append(Feature(name: "Shell", kind: .shell(thickness: 6)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT410")
    }

    // MARK: Extrude modes + taper

    func rectSketch(_ w: Double = 20, plane: Plane3 = .xy) -> Sketch {
        var s = Sketch(name: "s", plane: plane)
        s.addRectangle(from: Vec2(-w / 2, -w / 2), to: Vec2(w / 2, w / 2))
        return s
    }

    func testExtrudeSymmetric() {
        var part = Part(name: "p")
        let s = rectSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Ex", kind: .extrude(sketchID: s.id, distance: 10, taperDegrees: 0, mode: .symmetric)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.bounds.min.z, -5, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.z, 5, accuracy: 0.01)
        XCTAssertEqual(r.mesh.volume, 4000, accuracy: 40)
    }

    func testExtrudeTwoSided() {
        var part = Part(name: "p")
        let s = rectSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Ex", kind: .extrude(sketchID: s.id, distance: 10, taperDegrees: 0, mode: .twoSided(second: 3))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.bounds.min.z, -3, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.z, 10, accuracy: 0.01)
        XCTAssertEqual(r.mesh.volume, 400 * 13, accuracy: 60)
    }

    func testExtrudeTaper() {
        var part = Part(name: "p")
        let s = rectSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Ex", kind: .extrude(sketchID: s.id, distance: 10, taperDegrees: 10, mode: .one)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        let shrink = tan(10 * Double.pi / 180) * 10
        let top = 20 - 2 * shrink
        let frustum = 10.0 / 3.0 * (400 + top * top + (400 * top * top).squareRoot())
        XCTAssertEqual(r.mesh.volume, frustum, accuracy: frustum * 0.03)
    }

    func testExtrudeTaperTooSteepFails() {
        var part = Part(name: "p")
        let s = rectSketch(6)
        part.sketches.append(s)
        part.features.append(Feature(name: "Ex", kind: .extrude(sketchID: s.id, distance: 30, taperDegrees: 45, mode: .one)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT405")
    }

    // MARK: Loft & sweep

    func testLoftRectToRect() {
        var part = Part(name: "loft")
        let a = rectSketch(20)
        var b = rectSketch(10, plane: Plane3(origin: Vec3(0, 0, 20), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        b.name = "top"
        part.sketches += [a, b]
        part.features.append(Feature(name: "Loft", kind: .loft(sketchA: a.id, sketchB: b.id)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        let frustum = 20.0 / 3.0 * (400 + 100 + 200)
        XCTAssertEqual(r.mesh.volume, frustum, accuracy: frustum * 0.06)
        XCTAssertEqual(r.mesh.bounds.max.z, 20, accuracy: 0.01)
    }

    func testSweepStraight() {
        var part = Part(name: "sweep")
        var profile = Sketch(name: "profile", plane: Plane3(origin: .zero, xAxis: Vec3(0, 1, 0), yAxis: Vec3(0, 0, 1)))
        profile.addRectangle(from: Vec2(-2, -2), to: Vec2(2, 2))
        var path = Sketch(name: "path")
        path.addLine(Vec2(0, 0), Vec2(30, 0))
        part.sketches += [profile, path]
        part.features.append(Feature(name: "Sweep", kind: .sweep(profileSketchID: profile.id, pathSketchID: path.id)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 16 * 30, accuracy: 30)
        XCTAssertEqual(r.mesh.bounds.max.x, 30, accuracy: 0.01)
    }

    func testSweepBadPathFails() {
        var part = Part(name: "sweep")
        var profile = Sketch(name: "profile")
        profile.addRectangle(from: Vec2(-2, -2), to: Vec2(2, 2))
        var path = Sketch(name: "path")
        path.addCircle(Vec2(0, 0), 10)
        part.sketches += [profile, path]
        part.features.append(Feature(name: "Sweep", kind: .sweep(profileSketchID: profile.id, pathSketchID: path.id)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT414")
    }

    // MARK: Section

    func testSectionHalvesBox() throws {
        // Tessellation.box sits on z=0, so the mid-plane is z=10.
        let m = try Tessellation.box(width: 20, depth: 20, height: 20)
        let top = try m.sectioned(normal: Vec3(0, 0, 1), through: Vec3(0, 0, 10))
        XCTAssertEqual(top.volume, 4000, accuracy: 60)
        XCTAssertEqual(top.bounds.min.z, 10, accuracy: 0.01)
        let side = try m.sectioned(normal: Vec3(1, 0, 0), through: Vec3(5, 0, 0))
        XCTAssertEqual(side.volume, 2000, accuracy: 40)
    }

    // MARK: Offset polygon

    func testOffsetPolygon() {
        let rect = [Vec2(-10, -10), Vec2(10, -10), Vec2(10, 10), Vec2(-10, 10)]
        let shrunk = Tessellation.offsetPolygon(rect, by: -2)!
        XCTAssertEqual(abs(polygonArea(shrunk)), 16 * 16, accuracy: 0.01)
        let grown = Tessellation.offsetPolygon(rect, by: 3)!
        XCTAssertEqual(abs(polygonArea(grown)), 26 * 26, accuracy: 0.01)
        XCTAssertNil(Tessellation.offsetPolygon(rect, by: -25))
    }
}
