import XCTest
@testable import MetalCADKit

/// v4: operations + end conditions + multi-body, coil/pipe/rib, body
/// transforms (draft/scale/move/split), circular pattern, chamfer
/// modes, project geometry, and v4 Codable stability.
final class V4Tests: XCTestCase {

    func rectSketch(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                    plane: Plane3 = .xy, name: String = "s") -> Sketch {
        var s = Sketch(name: name)
        s.plane = plane
        s.addRectangle(from: Vec2(x0, y0), to: Vec2(x1, y1))
        return s
    }

    func boxPart(_ size: Double = 20) -> Part {
        var part = Part(name: "box")
        let s = rectSketch(0, 0, size, size)
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: size)))
        return part
    }

    // MARK: operations + end conditions

    func testExtrude2JoinMatchesPad() {
        var part = Part(name: "p")
        let s = rectSketch(0, 0, 20, 20)
        part.sketches.append(s)
        part.features.append(Feature(name: "Ex", kind: .extrude2(
            sketchID: s.id, distance: 10, taperDegrees: 0, mode: .one,
            operation: .join, end: .dimension)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 4000, accuracy: 1e-6)
        XCTAssertEqual(r.bodies.count, 1)
    }

    func testExtrude2Cut() {
        var part = boxPart()
        let s = rectSketch(5, 5, 15, 15, name: "cut")
        part.sketches.append(s)
        part.features.append(Feature(name: "Cut", kind: .extrude2(
            sketchID: s.id, distance: 10, taperDegrees: 0, mode: .one,
            operation: .cut, end: .dimension)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 8000 - 1000, accuracy: 1.0)
    }

    func testExtrude2Intersect() {
        var part = boxPart()
        let s = rectSketch(5, 5, 25, 25, name: "keep")
        part.sketches.append(s)
        part.features.append(Feature(name: "Keep", kind: .extrude2(
            sketchID: s.id, distance: 10, taperDegrees: 0, mode: .one,
            operation: .intersect, end: .dimension)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Overlap of the two solids: x,y in 5..20, z in 0..10.
        XCTAssertEqual(r.mesh.volume, 15 * 15 * 10, accuracy: 1.0)
    }

    func testExtrude2NewBody() {
        var part = boxPart(10)
        let s = rectSketch(30, 0, 40, 10, name: "b2")
        part.sketches.append(s)
        part.features.append(Feature(name: "Body2", kind: .extrude2(
            sketchID: s.id, distance: 10, taperDegrees: 0, mode: .one,
            operation: .newBody, end: .dimension)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.bodies.count, 2)
        XCTAssertEqual(r.mesh.volume, 2000, accuracy: 1e-6)
    }

    func testExtrude2ThroughAllCut() {
        var part = boxPart()
        var s = rectSketch(5, 5, 15, 15, name: "thru")
        s.plane = Plane3(origin: Vec3(0, 0, 5), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))
        part.sketches.append(s)
        part.features.append(Feature(name: "Thru", kind: .extrude2(
            sketchID: s.id, distance: 1, taperDegrees: 0, mode: .one,
            operation: .cut, end: .throughAll)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // From z=5 up through the top: removes 10*10*15.
        XCTAssertEqual(r.mesh.volume, 8000 - 1500, accuracy: 1.0)
    }

    func testExtrude2UpToFace() {
        var part = boxPart()
        let body = DocumentEngine.rebuild(part: part).mesh
        let faces = FaceExtractor.planarFaces(of: body)
        let topIdx = faces.firstIndex { abs($0.plane.normal.z - 1) < 0.01 && $0.centroid.z > 19 }!
        let s = rectSketch(5, 5, 15, 15, name: "up")
        part.sketches.append(s)
        part.features.append(Feature(name: "UpTo", kind: .extrude2(
            sketchID: s.id, distance: 1, taperDegrees: 0, mode: .one,
            operation: .join, end: .upToFace(faceIndex: topIdx))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.bounds.max.z, 20, accuracy: 1e-6)
        XCTAssertEqual(r.mesh.volume, 8000, accuracy: 1.0)  // prism fills inside the box
    }

    func testExtrude2UpToFaceBehindFails() {
        var part = boxPart()
        let body = DocumentEngine.rebuild(part: part).mesh
        let faces = FaceExtractor.planarFaces(of: body)
        let bottomIdx = faces.firstIndex { abs($0.plane.normal.z + 1) < 0.01 && $0.centroid.z < 1 }!
        var s = rectSketch(5, 5, 15, 15, name: "bad")
        s.plane = Plane3(origin: Vec3(0, 0, 30), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))
        part.sketches.append(s)
        part.features.append(Feature(name: "Bad", kind: .extrude2(
            sketchID: s.id, distance: 1, taperDegrees: 0, mode: .one,
            operation: .join, end: .upToFace(faceIndex: bottomIdx))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT405")
    }

    // MARK: coil / pipe / rib

    func testCoil() throws {
        var part = Part(name: "spring")
        part.features.append(Feature(name: "Coil", kind: .coil(radius: 10, pitch: 6, turns: 3, wireRadius: 1.5)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertGreaterThan(r.mesh.volume, 500)   // ~pi*1.5^2 * helix length (~200) ≈ 1400
        XCTAssertLessThan(r.mesh.volume, 3000)
        XCTAssertEqual(r.mesh.bounds.size.z, 18 + 3, accuracy: 2.5)  // pitch*turns + wire dia
    }

    func testPipeStraight() throws {
        var part = Part(name: "pipe")
        var s = Sketch(name: "path")
        s.addLine(Vec2(0, 0), Vec2(30, 0))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pipe", kind: .pipe(pathSketchID: s.id, radius: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, Double.pi * 4 * 30, accuracy: 40)
        XCTAssertEqual(r.mesh.bounds.size.x, 30, accuracy: 0.6)
    }

    func testRibStandingFin() {
        var part = Part(name: "ribbed")
        let base = rectSketch(0, 0, 40, 40)
        part.sketches.append(base)
        part.features.append(Feature(name: "Plate", kind: .pad(sketchID: base.id, length: 4)))
        var rib = Sketch(name: "rib profile")
        rib.plane = Plane3(origin: Vec3(0, 20, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, 1))
        rib.addLine(Vec2(5, 0), Vec2(35, 0))  // floats 6 above the plate top
        part.sketches.append(rib)
        part.features.append(Feature(name: "Rib", kind: .rib(sketchID: rib.id, thickness: 2, depth: 8)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Plate 6400 + fin 30 wide * 6 tall * 2 thick = 360.
        XCTAssertEqual(r.mesh.volume, 6400 + 360, accuracy: 120)
        XCTAssertEqual(r.mesh.bounds.max.z, 10, accuracy: 0.6)
    }

    // MARK: body transforms

    func testDraftNarrowsTop() throws {
        var part = boxPart()
        part.features.append(Feature(name: "Draft", kind: .draftBody(angleDegrees: 5, pullAxis: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertLessThan(r.mesh.volume, 8000)
        XCTAssertGreaterThan(r.mesh.volume, 6000)
        XCTAssertFalse(r.mesh.contains(Vec3(0.2, 0.2, 19.5)))  // top corner pulled in
        XCTAssertTrue(r.mesh.contains(Vec3(10, 10, 19.5)))      // top center stays solid
        XCTAssertTrue(r.mesh.contains(Vec3(0.2, 0.2, 0.5)))     // base barely moves
    }

    func testScaleBody() {
        var part = boxPart(10)
        part.features.append(Feature(name: "Scale", kind: .scaleBody(factors: Vec3(2, 1, 1))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 2000, accuracy: 1e-6)
        XCTAssertEqual(r.mesh.bounds.size.x, 20, accuracy: 1e-6)
    }

    func testMoveBody() {
        var part = boxPart(10)
        part.features.append(Feature(name: "Move", kind: .moveBody(
            translation: Vec3(5, 0, 0), rotationAxis: 2, rotationDegrees: 0)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.bounds.min.x, 5, accuracy: 1e-6)
    }

    func testSplitBody() {
        var part = boxPart()
        part.features.append(Feature(name: "Split", kind: .splitBody(axis: 2, offset: 10)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.bodies.count, 2)
        XCTAssertEqual(r.bodies[0].volume, 4000, accuracy: 20)
        XCTAssertEqual(r.bodies[1].volume, 4000, accuracy: 20)
        XCTAssertEqual(r.mesh.volume, 8000, accuracy: 40)
    }

    func testCircularPattern() {
        var part = Part(name: "pat")
        let a = rectSketch(0, 0, 10, 10, name: "a")
        let b = rectSketch(30, 0, 40, 10, name: "b")
        part.sketches.append(contentsOf: [a, b])
        part.features.append(Feature(name: "A", kind: .pad(sketchID: a.id, length: 10)))
        part.features.append(Feature(name: "B", kind: .pad(sketchID: b.id, length: 10)))
        part.features.append(Feature(name: "Circ", kind: .circularPattern(count: 4, axis: 2, totalDegrees: 360)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // The two-box body rotated copies overlap pairwise: the union
        // covers 4 distinct box footprints of 1000 each.
        XCTAssertEqual(r.mesh.volume, 4000, accuracy: 200)
    }

    // MARK: chamfer modes

    func testChamferTwoDistances() throws {
        let box = try Tessellation.box(width: 20, depth: 20, height: 20)
        let two = try EdgeFinisher.chamfer2(body: box, distanceA: 1, distanceB: 3)
        let equal = try EdgeFinisher.chamfer(body: box, distance: 2)
        XCTAssertLessThan(equal.volume, two.volume)  // (1*3)/2 < (2*2)/2 per edge
        XCTAssertLessThan(two.volume, 8000)
    }

    func testChamferDistanceAngle45() throws {
        let box = try Tessellation.box(width: 20, depth: 20, height: 20)
        let mode = ChamferMode.distanceAngle(2, 45)
        let (dA, dB) = mode.distances
        XCTAssertEqual(dA, 2, accuracy: 1e-9)
        XCTAssertEqual(dB, 2, accuracy: 1e-9)
        var part = boxPart()
        part.features.append(Feature(name: "Ch", kind: .chamfer2(mode: mode)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        let equal = try EdgeFinisher.chamfer(body: box, distance: 2)
        XCTAssertEqual(r.mesh.volume, equal.volume, accuracy: 30)
    }

    func testChamfer2TooLargeNamesFit() throws {
        let box = try Tessellation.box(width: 10, depth: 10, height: 10)
        XCTAssertThrowsError(try EdgeFinisher.chamfer2(body: box, distanceA: 9, distanceB: 9)) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-FT409")
        }
    }

    // MARK: project geometry + codable

    func testProjectEdgesOntoXY() throws {
        let box = try Tessellation.box(width: 20, depth: 20, height: 20)
        let segs = ProjectGeometry.edgeSegments(body: box, onto: .xy)
        XCTAssertEqual(segs.count, 12)
        let lengths = segs.map { $0.0.distance(to: $0.1) }
        // 8 horizontal edges project at full length; the 4 verticals
        // collapse to points.
        XCTAssertEqual(lengths.filter { abs($0 - 20) < 1e-6 }.count, 8)
        XCTAssertEqual(lengths.filter { $0 < 1e-6 }.count, 4)
    }

    func testProjectFaceOutline() throws {
        let box = try Tessellation.box(width: 20, depth: 20, height: 20)
        let top = FaceExtractor.planarFaces(of: box).first { abs($0.plane.normal.z - 1) < 0.01 && $0.centroid.z > 19 }!
        let segs = ProjectGeometry.faceOutlineSegments(face: top, onto: .xy)
        XCTAssertGreaterThanOrEqual(segs.count, 4)
    }

    func testV4CodableRoundTrip() throws {
        var part = boxPart()
        part.features.append(Feature(name: "Ex", kind: .extrude2(
            sketchID: "x", distance: 5, taperDegrees: 2, mode: .symmetric,
            operation: .newBody, end: .upToFace(faceIndex: 3))))
        part.features.append(Feature(name: "Ch", kind: .chamfer2(mode: .distanceAngle(2, 30))))
        part.features.append(Feature(name: "Coil", kind: .coil(radius: 8, pitch: 4, turns: 2, wireRadius: 1)))
        part.features.append(Feature(name: "Split", kind: .splitBody(axis: 1, offset: 3)))
        let data = try JSONEncoder().encode(part)
        let back = try JSONDecoder().decode(Part.self, from: data)
        XCTAssertEqual(back, part)
    }
}
