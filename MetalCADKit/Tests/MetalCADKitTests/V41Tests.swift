import XCTest
@testable import MetalCADKit

/// v4.1: low-triangle thread merging, per-edge fillet/chamfer,
/// cylinder fitting, and threading an existing shaft.
final class V41Tests: XCTestCase {

    func testThreadOnPlateStaysLean() throws {
        var part = Part(name: "p")
        var sk = Sketch(name: "base")
        sk.addRectangle(from: Vec2(0, 0), to: Vec2(40, 40))
        part.sketches.append(sk)
        part.features.append(Feature(name: "Plate", kind: .pad(sketchID: sk.id, length: 5)))
        let spec = try ThreadSpec.preset("M10")
        part.features.append(Feature(name: "Thread", kind: .threadShaft(spec: spec)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Was 169,020 triangles via raw CSG union of the ridge.
        XCTAssertLessThan(r.mesh.triangleCount, 15_000)
        // Volume: plate 8000 + core above the plate + exposed ridge.
        XCTAssertGreaterThan(r.mesh.volume, 8_400)
        XCTAssertLessThan(r.mesh.volume, 9_600)
        XCTAssertEqual(r.mesh.bounds.max.z, 20, accuracy: 0.6)
    }

    func testFilletOnlyPickedEdges() throws {
        let box = try Tessellation.box(width: 20, depth: 20, height: 20)
        // The 4 top edges of a 20-cube centered at x/y in -10...10, z 0...20.
        let tops = [Vec3(0, -10, 20), Vec3(0, 10, 20), Vec3(-10, 0, 20), Vec3(10, 0, 20)]
        let r = try EdgeFinisher.fillet(body: box, radius: 2, onlyMidpoints: tops)
        let all = try EdgeFinisher.fillet(body: box, radius: 2)
        XCTAssertLessThan(all.volume, r.volume)          // fewer edges cut
        XCTAssertLessThan(r.volume, 8000)
        // A bottom edge is still sharp (still extracted); top mids are gone.
        let edges = SolidEdgeExtractor.edges(of: r)
        XCTAssertTrue(edges.contains { $0.mid.distance(to: Vec3(0, -10, 0)) < 0.1 })
        XCTAssertFalse(edges.contains { $0.mid.distance(to: Vec3(0, -10, 20)) < 0.1 })
    }

    func testFilletPickedEdgeGoneThrows() throws {
        let box = try Tessellation.box(width: 20, depth: 20, height: 20)
        XCTAssertThrowsError(try EdgeFinisher.fillet(body: box, radius: 2, onlyMidpoints: [Vec3(99, 99, 99)])) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-FT407")
        }
    }

    func testChamferOnlyPickedEdges() throws {
        let box = try Tessellation.box(width: 20, depth: 20, height: 20)
        let one = [Vec3(0, -10, 20)]
        let r = try EdgeFinisher.chamfer(body: box, distance: 2, onlyMidpoints: one)
        let all = try EdgeFinisher.chamfer(body: box, distance: 2)
        XCTAssertLessThan(all.volume, r.volume)
        XCTAssertEqual(r.volume, 8000 - 40 + 0, accuracy: 30)  // one edge: (2*2/2)*20 = 40
    }

    func testCylinderFitOnShaft() throws {
        let cyl = try Tessellation.cylinder(radius: 5, height: 30, segments: 48)
        // Find a side triangle (normal mostly horizontal).
        let normals = cyl.faceNormals()
        let seed = normals.firstIndex { abs($0.z) < 0.3 }!
        let fit = CylinderFitter.fit(mesh: cyl, seedTriangle: seed)
        let f = try XCTUnwrap(fit)
        XCTAssertEqual(f.radius, 5, accuracy: 0.1)
        XCTAssertEqual(f.height, 30, accuracy: 0.5)
        XCTAssertEqual(abs(f.axis.z), 1, accuracy: 0.05)
        XCTAssertFalse(f.isInternal)
    }

    func testCylinderFitRejectsBox() throws {
        let box = try Tessellation.box(width: 20, depth: 20, height: 20)
        XCTAssertNil(CylinderFitter.fit(mesh: box, seedTriangle: 0))
    }

    func testCylinderFitInternal() throws {
        let block = try Tessellation.box(width: 30, depth: 30, height: 20)
        let hole = try Tessellation.cylinder(radius: 6, height: 24, segments: 48).translated(by: Vec3(0, 0, -2))
        let bored = try CSG.subtract(block, hole)
        let normals = bored.faceNormals()
        // Seed a triangle whose normal points at the axis (hole wall).
        let seed = normals.indices.first { i in
            let a = bored.vertices[Int(bored.indices[i * 3])]
            let b = bored.vertices[Int(bored.indices[i * 3 + 1])]
            let c = bored.vertices[Int(bored.indices[i * 3 + 2])]
            let cen = (a + b + c) * (1.0 / 3)
            return (cen.x * cen.x + cen.y * cen.y) < 40 && normals[i].dot(Vec3(cen.x, cen.y, 0)) < -0.5
        }!
        let fit = CylinderFitter.fit(mesh: bored, seedTriangle: seed)
        let f = try XCTUnwrap(fit)
        XCTAssertTrue(f.isInternal)
        XCTAssertEqual(f.radius, 6, accuracy: 0.15)
    }

    func testThreadOnExistingPillar() throws {
        var part = Part(name: "boss")
        var sk = Sketch(name: "base")
        sk.addRectangle(from: Vec2(-20, -20), to: Vec2(20, 20))
        part.sketches.append(sk)
        part.features.append(Feature(name: "Plate", kind: .pad(sketchID: sk.id, length: 5)))
        part.features.append(Feature(name: "Boss", kind: .primitive(kind: .cylinder,
                                     params: ["radius": 5, "height": 15])))
        let body = DocumentEngine.rebuild(part: part).mesh
        let normals = body.faceNormals()
        let seed = normals.indices.first { i in
            let a = body.vertices[Int(body.indices[i * 3])]
            let b = body.vertices[Int(body.indices[i * 3 + 1])]
            let c = body.vertices[Int(body.indices[i * 3 + 2])]
            let cz = (a.z + b.z + c.z) / 3
            return abs(normals[i].z) < 0.3 && cz > 8
        }!
        let fit = try XCTUnwrap(CylinderFitter.fit(mesh: body, seedTriangle: seed))
        var spec = try ThreadSpec.preset("M10")
        spec.length = fit.height
        part.features.append(Feature(name: "Thread it", kind: .threadOnShaft(
            spec: spec, origin: fit.origin, axis: fit.axis)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Bound is loose: the macOS CI build's CSG splits a little
        // differently (39.5k observed) — the point is "not the old
        // 169k raw-union explosion", not an exact count.
        XCTAssertLessThan(r.mesh.triangleCount, 60_000)
        // Pillar is threaded now: material exists at the crest radius
        // above the plate, and the volume dropped vs the plain pillar
        // (grooves) but not by much.
        let plain = DocumentEngine.rebuild(part: {
            var p = part; p.features.removeLast(); return p
        }()).mesh.volume
        XCTAssertLessThan(r.mesh.volume, plain)
        XCTAssertGreaterThan(r.mesh.volume, plain * 0.9)
    }

    func testV41CodableRoundTrip() throws {
        var part = Part(name: "x")
        part.features.append(Feature(name: "F", kind: .filletEdges(radius: 2, midpoints: [Vec3(1, 2, 3)])))
        part.features.append(Feature(name: "T", kind: .threadOnShaft(spec: ThreadSpec(), origin: Vec3(0, 0, 5), axis: Vec3(0, 0, 1))))
        let data = try JSONEncoder().encode(part)
        XCTAssertEqual(try JSONDecoder().decode(Part.self, from: data), part)
    }
}
