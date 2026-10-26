import XCTest
@testable import MetalCADKit

/// v2 checks: CSG booleans, real pockets & holes, mirror, planar faces
/// (sketch-on-face), materials & mass, smooth display normals.
final class V2Tests: XCTestCase {

    func box(_ w: Double, _ d: Double, _ h: Double, at offset: Vec3 = .zero) throws -> Mesh {
        try Tessellation.box(width: w, depth: d, height: h).translated(by: offset)
    }

    // MARK: CSG

    func testUnionOverlappingBoxes() throws {
        let a = try box(10, 10, 10)                       // x -5..5
        let b = try box(10, 10, 10, at: Vec3(5, 0, 0))    // x 0..10
        let u = try CSG.union(a, b)
        XCTAssertEqual(u.volume, 1500, accuracy: 30)
        XCTAssertTrue(u.welded().isWatertight)
    }

    func testUnionDisjointBoxes() throws {
        let a = try box(10, 10, 10)
        let b = try box(10, 10, 10, at: Vec3(100, 0, 0))
        let u = try CSG.union(a, b)
        XCTAssertEqual(u.volume, 2000, accuracy: 20)
    }

    func testUnionEmptyOperand() throws {
        let a = try box(10, 10, 10)
        XCTAssertEqual(try CSG.union(a, Mesh()).volume, 1000, accuracy: 1)
        XCTAssertEqual(try CSG.union(Mesh(), a).volume, 1000, accuracy: 1)
    }

    func testSubtractHalf() throws {
        let a = try box(10, 10, 10)
        let b = try box(10, 10, 10, at: Vec3(5, 0, 0))
        let s = try CSG.subtract(a, b)
        XCTAssertEqual(s.volume, 500, accuracy: 15)
        XCTAssertTrue(s.welded().isWatertight)
    }

    func testSubtractDisjointIsNoOp() throws {
        let a = try box(10, 10, 10)
        let b = try box(10, 10, 10, at: Vec3(100, 0, 0))
        XCTAssertEqual(try CSG.subtract(a, b).volume, 1000, accuracy: 10)
    }

    func testSubtractEverything() throws {
        let a = try box(10, 10, 10)
        let big = try box(30, 30, 30)
        XCTAssertEqual(try CSG.subtract(a, big).volume, 0, accuracy: 1)
    }

    func testIntersectOverlap() throws {
        let a = try box(10, 10, 10)
        let b = try box(10, 10, 10, at: Vec3(5, 0, 0))
        let i = try CSG.intersect(a, b)
        XCTAssertEqual(i.volume, 500, accuracy: 15)
    }

    func testCSGCylinderThroughPlate() throws {
        let plate = try Tessellation.box(width: 40, depth: 40, height: 10)
        let drill = try Tessellation.cylinder(radius: 5, height: 30, segments: 48).translated(by: Vec3(0, 0, -10))
        let s = try CSG.subtract(plate, drill)
        XCTAssertEqual(s.volume, 16000 - Double.pi * 25 * 10, accuracy: 120)
    }

    func testCSGSphereUnion() throws {
        let a = try Tessellation.sphere(radius: 10)
        let b = try Tessellation.sphere(radius: 10).translated(by: Vec3(10, 0, 0))
        let u = try CSG.union(a, b)
        let single = 4.0 / 3.0 * Double.pi * 1000
        XCTAssertGreaterThan(u.volume, single)
        XCTAssertLessThan(u.volume, 2 * single)
    }

    // MARK: Features v2 (pocket / hole / mirror / pad-on-body)

    func platePart() -> Part {
        var part = Part(name: "plate")
        var s = Sketch(name: "base")
        s.addRectangle(from: Vec2(-20, -20), to: Vec2(20, 20))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 10)))
        return part
    }

    func testPocketCuts() {
        var part = platePart()
        var top = Sketch(name: "pocket", plane: Plane3(origin: Vec3(0, 0, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        top.addRectangle(from: Vec2(-10, -10), to: Vec2(10, 10))
        part.sketches.append(top)
        part.features.append(Feature(name: "Pocket", kind: .pocket(sketchID: top.id, depth: 4)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 16000 - 400 * 4, accuracy: 200)
    }

    func testPocketOnEmptyBodyFailsFT406() {
        var part = Part(name: "p")
        var s = Sketch(name: "s")
        s.addRectangle(from: Vec2(0, 0), to: Vec2(10, 10))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pocket", kind: .pocket(sketchID: s.id, depth: 3)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT406")
    }

    func testHoleThrough() {
        var part = platePart()
        var top = Sketch(name: "holes", plane: Plane3(origin: Vec3(0, 0, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        top.addPoint(Vec2(0, 0))
        part.sketches.append(top)
        part.features.append(Feature(name: "Hole", kind: .hole(sketchID: top.id, diameter: 10, depth: 0, kind: .simple)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 16000 - Double.pi * 25 * 10, accuracy: 150)
    }

    func testHoleCounterbore() {
        var part = platePart()
        var top = Sketch(name: "holes", plane: Plane3(origin: Vec3(0, 0, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        top.addPoint(Vec2(0, 0))
        part.sketches.append(top)
        part.features.append(Feature(name: "Hole", kind: .hole(sketchID: top.id, diameter: 6, depth: 0, kind: .counterbore(diameter: 12, depth: 3))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        let expected = 16000 - Double.pi * 9 * 10 - Double.pi * (36 - 9) * 3
        XCTAssertEqual(r.mesh.volume, expected, accuracy: 200)
    }

    func testHoleNoPointsFailsFT416() {
        var part = platePart()
        var top = Sketch(name: "holes")
        top.addRectangle(from: Vec2(0, 0), to: Vec2(5, 5))
        part.sketches.append(top)
        part.features.append(Feature(name: "Hole", kind: .hole(sketchID: top.id, diameter: 6, depth: 0, kind: .simple)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT416")
    }

    func testPadOnTopFace() {
        var part = platePart()
        var top = Sketch(name: "boss", plane: Plane3(origin: Vec3(0, 0, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        top.addCircle(Vec2(0, 0), 8)
        part.sketches.append(top)
        part.features.append(Feature(name: "Boss", kind: .pad(sketchID: top.id, length: 6)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 16000 + Double.pi * 64 * 6, accuracy: 250)
        XCTAssertEqual(r.mesh.bounds.max.z, 16, accuracy: 0.01)
    }

    func testMirrorDoubles() {
        var part = Part(name: "half")
        part.features.append(Feature(name: "Box", kind: .primitive(kind: .box, params: ["width": 10, "depth": 10, "height": 10])))
        part.features.append(Feature(name: "Mirror", kind: .mirror(plane: .yz)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Box is centered on x=0 already, so mirroring overlaps exactly:
        // volume stays 1000, bounds unchanged.
        XCTAssertEqual(r.mesh.volume, 1000, accuracy: 20)
    }

    func testMirrorOffsetPart() {
        var part = platePart()
        part.features.append(Feature(name: "MirrorZ", kind: .mirror(plane: .xy)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.bounds.min.z, -10, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.z, 10, accuracy: 0.01)
        XCTAssertEqual(r.mesh.volume, 32000, accuracy: 300)
    }

    // MARK: Faces

    func testBoxHasSixFaces() throws {
        let m = try Tessellation.box(width: 10, depth: 20, height: 30)
        let faces = FaceExtractor.planarFaces(of: m)
        XCTAssertEqual(faces.count, 6)
        let areas = faces.map { $0.area }.sorted()
        XCTAssertEqual(areas, [200, 200, 300, 300, 600, 600])
    }

    func testCylinderSideIsNotPlanarFace() throws {
        // A faceted cylinder: each side quad is its own plane, so the
        // extractor returns 32 side faces + top + bottom caps. The caps
        // are the sketchable faces (largest, axis-aligned).
        let m = try Tessellation.cylinder(radius: 10, height: 10, segments: 32)
        let faces = FaceExtractor.planarFaces(of: m)
        XCTAssertEqual(faces.count, 34)
        let caps = faces.filter { abs($0.plane.normal.z) > 0.999 }
        XCTAssertEqual(caps.count, 2)
        for cap in caps {
            XCTAssertEqual(cap.area, Double.pi * 100, accuracy: 5)
        }
        let sides = faces.filter { abs($0.plane.normal.z) < 0.001 }
        XCTAssertEqual(sides.count, 32)
    }

    func testTopFaceSketchRoundTrip() throws {
        let m = try Tessellation.box(width: 40, depth: 40, height: 10)
        let faces = FaceExtractor.planarFaces(of: m)
        let top = faces.first { $0.plane.normal.z > 0.99 }!
        XCTAssertEqual(top.area, 1600, accuracy: 1)
        XCTAssertEqual(top.outline2D.count, 4)
        // Sketch a circle on the face plane and pad it.
        var part = Part(name: "p")
        part.features.append(Feature(name: "Base", kind: .primitive(kind: .box, params: ["width": 40, "depth": 40, "height": 10])))
        var s = Sketch(name: "onTop", plane: top.plane)
        s.addCircle(Vec2(0, 0), 5)
        part.sketches.append(s)
        part.features.append(Feature(name: "Pin", kind: .pad(sketchID: s.id, length: 5)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertGreaterThan(r.mesh.volume, 16000)
    }

    // MARK: Materials & mass

    func testMaterialLibrary() {
        XCTAssertEqual(MaterialLibrary.all.count, 12)
        XCTAssertEqual(Set(MaterialLibrary.all.map { $0.id }).count, 12)
        XCTAssertEqual(MaterialLibrary.byID("brass")?.density, 8.50)
        XCTAssertNil(MaterialLibrary.byID("unobtanium"))
        for m in MaterialLibrary.all {
            XCTAssertGreaterThan(m.density, 0)
            XCTAssertFalse(m.name.isEmpty)
        }
    }

    func testMassFromMaterial() {
        var part = platePart()  // 40x40x10 mm = 16 cm^3
        part.materialID = "aluminum-6061"  // 2.70 g/cm^3
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.massGrams!, 16 * 2.70, accuracy: 0.5)
        part.materialID = "steel-mild"
        let r2 = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r2.massGrams!, 16 * 7.85, accuracy: 0.5)
    }

    func testDefaultMaterialIsAluminum() {
        XCTAssertEqual(Part(name: "x").material.name, "Aluminum 6061")
    }

    // MARK: Smooth display

    func testDisplaySoupCylinderIsSmooth() throws {
        let cyl = try Tessellation.cylinder(radius: 10, height: 10, segments: 32)
        let soup = cyl.displaySoup()
        XCTAssertEqual(soup.positions.count, soup.normals.count)
        XCTAssertEqual(soup.positions.count, cyl.triangleCount * 3)
        // Side vertices: normal should be radial (perpendicular to axis),
        // NOT the flat per-face normal of a low-poly look.
        // Rim corners come from both side faces (radial normals) and cap
        // fans (axial normals, correct for the flat cap). Group by rim
        // position: every rim position must have at least one radial
        // corner, i.e. the curved wall shades smooth.
        var byPosition: [String: [Vec3]] = [:]
        for (p, n) in zip(soup.positions, soup.normals) {
            let r = (p.x * p.x + p.y * p.y).squareRoot()
            if r > 9.9 {
                let key = "\(Int((p.x * 10).rounded())),\(Int((p.y * 10).rounded())),\(Int(p.z))"
                byPosition[key, default: []].append(n)
            }
        }
        XCTAssertGreaterThan(byPosition.count, 0)
        var radialPositions = 0
        for (key, normals) in byPosition {
            let p = soup.positions.first { pos in
                "\(Int((pos.x * 10).rounded())),\(Int((pos.y * 10).rounded())),\(Int(pos.z))" == key
            }!
            let r = (p.x * p.x + p.y * p.y).squareRoot()
            let radial = Vec3(p.x / r, p.y / r, 0)
            if normals.contains(where: { $0.dot(radial) > 0.99 }) { radialPositions += 1 }
        }
        XCTAssertGreaterThan(Double(radialPositions) / Double(byPosition.count), 0.9)
    }

    func testDisplaySoupBoxEdgesStaySharp() throws {
        let b = try Tessellation.box(width: 10, depth: 10, height: 10)
        let soup = b.displaySoup()
        // Every normal of a box must be axis-aligned (no puffy corners).
        for n in soup.normals {
            let comps = [abs(n.x), abs(n.y), abs(n.z)].sorted()
            XCTAssertEqual(comps[2], 1, accuracy: 1e-9)
            XCTAssertEqual(comps[1], 0, accuracy: 1e-9)
        }
    }

    func testDisplaySoupSphereNormals() throws {
        let s = try Tessellation.sphere(radius: 10, segments: 24, rings: 16)
        let soup = s.displaySoup()
        for (p, n) in zip(soup.positions, soup.normals) where p.length > 1 {
            XCTAssertGreaterThan(n.dot(p.normalized), 0.95)
        }
    }
}
