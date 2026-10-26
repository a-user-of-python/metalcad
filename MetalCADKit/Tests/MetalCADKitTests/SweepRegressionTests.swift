import XCTest
@testable import MetalCADKit

/// Regression tests for the 2026-10-26 engine sweep. Every test here
/// pins a defect the sweep's adversarial probes confirmed against the
/// pre-fix engine: crashes (traps/hangs), silent wrong geometry, and
/// silent no-ops reported as success.
final class SweepRegressionTests: XCTestCase {

    private func box(_ w: Double, _ d: Double, _ h: Double) throws -> Mesh {
        try Tessellation.box(width: w, depth: d, height: h)
    }

    // MARK: Tapered extrude crashed on collinear profile points
    // (offsetPolygon dropped the point, walls indexed by the old
    // count -> out-of-bounds trap).

    func testTaperedExtrudeWithCollinearOuterPoint() throws {
        let prof = Profile(outer: [Vec2(0, 0), Vec2(10, 0), Vec2(20, 0), Vec2(20, 10), Vec2(0, 10)], holes: [])
        let m = try Tessellation.extrudeTapered(profile: prof, plane: .xy, length: 10, taperDegrees: 5)
        XCTAssertGreaterThan(m.volume, 0)
        XCTAssertLessThan(m.volume, 2000)  // taper shrinks the top
    }

    func testTaperedExtrudeWithCollinearHolePoint() throws {
        let prof = Profile(outer: [Vec2(0, 0), Vec2(20, 0), Vec2(20, 20), Vec2(0, 20)],
                           holes: [[Vec2(5, 5), Vec2(10, 5), Vec2(15, 5), Vec2(15, 15), Vec2(5, 15)]])
        let m = try Tessellation.extrudeTapered(profile: prof, plane: .xy, length: 10, taperDegrees: 5)
        XCTAssertGreaterThan(m.volume, 0)
    }

    // MARK: Primitive tessellation parameter validation
    // (sphere(rings: 1) trapped on grid[-1]; segments < 3 silently
    // produced zero-volume garbage).

    func testPrimitiveSegmentValidation() {
        XCTAssertThrowsError(try Tessellation.sphere(radius: 5, rings: 1)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT413")
        }
        XCTAssertThrowsError(try Tessellation.sphere(radius: 5, segments: 2)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT413")
        }
        XCTAssertThrowsError(try Tessellation.cylinder(radius: 5, height: 5, segments: 2)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT413")
        }
        XCTAssertThrowsError(try Tessellation.cone(radius: 5, height: 5, segments: 1)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT413")
        }
        XCTAssertThrowsError(try Tessellation.torus(ringRadius: 15, tubeRadius: 5, segments: 0, sides: 0)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT413")
        }
    }

    // MARK: Arc polyline with absurd stored angles hung/OOMed
    // (sweep never normalized into one turn).

    func testArcWithHugeAnglesReturnsPromptly() {
        let e = SketchEntity.arc(id: 1, center: .zero, radius: 5, startAngle: 0, endAngle: 1e9, construction: false)
        let pts = e.polyline()
        XCTAssertLessThan(pts.count, 1000)
        XCTAssertGreaterThan(pts.count, 2)
    }

    // MARK: Loft with a degenerate (all-coincident) loop trapped
    // indexing the resample that never happened.

    func testLoftDegenerateLoopThrows() {
        let sq = [Vec3(0, 0, 10), Vec3(10, 0, 10), Vec3(10, 10, 10), Vec3(0, 10, 10)]
        XCTAssertThrowsError(try LoftTessellator.loft(loopA: [Vec3(1, 1, 1), Vec3(1, 1, 1), Vec3(1, 1, 1)], loopB: sq)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT415")
        }
    }

    // MARK: Equation parser recursion (deep nesting crashed with a
    // stack overflow).

    func testEquationDeepNestingThrowsNotCrashes() {
        let expr = String(repeating: "(", count: 5000) + "1" + String(repeating: ")", count: 5000)
        XCTAssertThrowsError(try EquationEvaluator.evaluate(expr, variables: [:])) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-DC111")
        }
        let minus = String(repeating: "-", count: 5000) + "1"
        XCTAssertThrowsError(try EquationEvaluator.evaluate(minus, variables: [:]))
        // Sane formulas still evaluate.
        XCTAssertEqual(try EquationEvaluator.evaluate("min(8, 2, 5) + sqrt(16)", variables: [:]), 6)
    }

    // MARK: Thread tessellation step cap (length 300 m at pitch 1.5
    // asked for ~40M vertices and ran until the process died).

    func testThreadLengthCap() {
        var spec = ThreadSpec()
        spec.majorDiameter = 10; spec.pitch = 1.5; spec.length = 300_000
        XCTAssertThrowsError(try ThreadTessellator.ridgeMesh(spec: spec)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-TH506")
        }
        var zero = ThreadSpec()
        zero.length = 0
        XCTAssertThrowsError(try ThreadTessellator.ridgeMesh(spec: zero))
    }

    // MARK: Fillet/chamfer silent no-ops (over-limit values and
    // edge-less bodies reported SUCCESS with the body untouched).

    func testFilletOversizeThrowsTooLarge() throws {
        let b = try box(20, 20, 10)
        XCTAssertThrowsError(try EdgeFinisher.fillet(body: b, radius: 100)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT408")
        }
        let cube = try box(4, 4, 4)
        XCTAssertThrowsError(try EdgeFinisher.fillet(body: cube, radius: 5)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT408")
        }
        XCTAssertThrowsError(try EdgeFinisher.chamfer(body: cube, distance: 5)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT409")
        }
    }

    func testFilletEdgelessBodyThrows() throws {
        let s = try Tessellation.sphere(radius: 10)
        XCTAssertThrowsError(try EdgeFinisher.fillet(body: s, radius: 1)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT407")
        }
    }

    func testFilletExactHalfThicknessStillWorks() throws {
        // Sean's plate case: r = exactly half the stock must succeed
        // (the feasibility ladder), not be caught by the new errors.
        let plate = try box(40, 40, 4)
        let m = try EdgeFinisher.fillet(body: plate, radius: 2)
        XCTAssertLessThan(m.volume, 6400)
        XCTAssertGreaterThan(m.volume, 5000)
    }

    // MARK: chamfer2 with a zero second distance subtracted the
    // ENTIRE body and returned an empty mesh as success.

    func testChamfer2ZeroSecondDistanceThrows() throws {
        let b = try box(20, 20, 10)
        XCTAssertThrowsError(try EdgeFinisher.chamfer2(body: b, distanceA: 2, distanceB: 0)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT409")
        }
        // A valid asymmetric pair still works.
        let m = try EdgeFinisher.chamfer2(body: b, distanceA: 2, distanceB: 1)
        XCTAssertLessThan(m.volume, 4000)
        XCTAssertGreaterThan(m.volume, 3000)
    }

    // MARK: Shell walls must be the requested thickness
    // (vertex-normal shells measured ~0.58x nominal at face centres).

    func testShellWallThicknessIsNominal() throws {
        let b = try box(10, 10, 10)
        let m = try EdgeFinisher.shell(body: b, thickness: 1)
        // 10^3 - 8^3 = 488 for true 1 mm walls.
        XCTAssertEqual(m.volume, 488, accuracy: 12)
    }

    // MARK: Multi-profile sketches: pad used to build only the first
    // profile, silently dropping the rest.

    func testPadBuildsAllProfiles() {
        var two = Sketch(name: "TWO")
        _ = two.addRectangle(from: Vec2(0, 0), to: Vec2(10, 10))
        _ = two.addRectangle(from: Vec2(20, 0), to: Vec2(30, 10))
        var part = Part(name: "P")
        part.sketches = [two]
        part.features = [Feature(name: "Pad", kind: .pad(sketchID: two.id, length: 10))]
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 2000, accuracy: 1)
    }

    func testDuplicateRectanglesPadOnce() {
        // A rectangle drawn over itself: containment parity used to
        // turn the twin into a "hole" and produce 2333 mm^3 of junk.
        var dup = Sketch(name: "DUP")
        _ = dup.addRectangle(from: Vec2(0, 0), to: Vec2(10, 10))
        _ = dup.addRectangle(from: Vec2(0, 0), to: Vec2(10, 10))
        var part = Part(name: "P")
        part.sketches = [dup]
        part.features = [Feature(name: "Pad", kind: .pad(sketchID: dup.id, length: 10))]
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 1000, accuracy: 1)
    }

    func testSweepRejectsDisconnectedPathLines() {
        // A path sketch whose lines don't all connect: sweeping the
        // connected subset and silently dropping the rest is wrong
        // geometry with a success checkmark.
        var path = Sketch(name: "PP2")
        _ = path.addLine(Vec2(0, 0), Vec2(30, 0))
        _ = path.addLine(Vec2(30, 0), Vec2(30, 30))
        _ = path.addLine(Vec2(100, 100), Vec2(140, 100))
        var prof = Sketch(name: "PR2")
        _ = prof.addRectangle(from: Vec2(-3, -3), to: Vec2(3, 3))
        var part = Part(name: "PS")
        part.sketches = [path, prof]
        part.features = [Feature(name: "Sweep", kind: .sweep(profileSketchID: prof.id, pathSketchID: path.id))]
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNotNil(r.firstError)
    }

    func testPatternCountCaps() {
        // Adversarial counts from a corrupt document must fail fast
        // with FT411, not run CSG unions / appends for hours.
        var sk = Sketch(name: "S")
        _ = sk.addRectangle(from: Vec2(-5, -5), to: Vec2(5, 5))
        var part = Part(name: "P")
        part.sketches = [sk]
        part.features = [
            Feature(name: "Pad", kind: .pad(sketchID: sk.id, length: 10)),
            Feature(name: "CP", kind: .circularPattern(count: 5000, axis: 2, totalDegrees: 360)),
        ]
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT411")
        XCTAssertThrowsError(try DocumentEngine.applyPattern(mesh: Mesh(), count: 100_000, spacing: Vec3(1, 0, 0))) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-FT411")
        }
    }

    // MARK: Pipe through a zero-length path segment came out a
    // zero-volume ghost (frame built from a zero tangent).

    func testPipeWithZeroLengthSegment() {
        var path = Sketch(name: "PATH")
        _ = path.addLine(Vec2(0, 0), Vec2(0, 0))
        _ = path.addLine(Vec2(0, 0), Vec2(50, 0))
        var part = Part(name: "PP")
        part.sketches = [path]
        part.features = [Feature(name: "Pipe", kind: .pipe(pathSketchID: path.id, radius: 3))]
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, Double.pi * 9 * 50, accuracy: 80)
    }

    // MARK: STL import accepted NaN vertices (which then trapped the
    // next weld/display pass on Int(floor(NaN))).

    func testReadSTLRejectsNonFiniteVertices() {
        var data = Data(count: 80)
        var count: UInt32 = 1
        var countLE = count.littleEndian
        withUnsafeBytes(of: &countLE) { data.append(contentsOf: $0) }
        func f32(_ v: Float) {
            var b = v.bitPattern.littleEndian
            withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
        }
        for _ in 0..<3 { f32(0) }
        f32(.nan); f32(0); f32(0)
        f32(10); f32(0); f32(0)
        f32(0); f32(10); f32(0)
        var attr: UInt16 = 0
        withUnsafeBytes(of: &attr) { data.append(contentsOf: $0) }
        XCTAssertThrowsError(try IOService.readSTL(data: data)) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-IO703")
        }
    }

    // MARK: Mesh hardening — weld tolerance 0 divided by zero and
    // trapped; a NaN vertex trapped displaySoup the same way.

    func testWeldedZeroToleranceDoesNotCrash() throws {
        let b = try box(10, 10, 10)
        let w = b.welded(tolerance: 0)
        XCTAssertEqual(w.vertices.count, 8)
        XCTAssertEqual(w.volume, 1000, accuracy: 1e-6)
    }

    func testNaNVertexDoesNotCrashDisplay() throws {
        var m = try box(10, 10, 10)
        m.vertices[0] = Vec3(.nan, 0, 0)
        let soup = m.displaySoup()
        XCTAssertEqual(soup.positions.count, m.triangleCount * 3)
        _ = m.welded()
        _ = m.stitched()
    }

    // MARK: displaySoup emitted a zero-length normal for degenerate
    // triangles (renderers need unit normals).

    func testDisplaySoupNormalsAreUnitLength() {
        var b = MeshBuilder()
        let a = b.vertex(Vec3(0, 0, 0)), c = b.vertex(Vec3(10, 0, 0)), d = b.vertex(Vec3(0, 10, 0))
        b.triangle(a, c, d)
        let e = b.vertex(Vec3(5, 0, 0))  // collinear: degenerate triangle
        b.triangle(a, e, c)
        let soup = b.mesh.displaySoup()
        for n in soup.normals {
            XCTAssertTrue(n.isFinite())
            XCTAssertEqual(n.length, 1, accuracy: 1e-9)
        }
    }

    // MARK: Booleans at 1e-4 mm scale dissolved in the BSP absolute
    // epsilon (47% volume error). Normalized internally now.

    func testTinyScaleBooleanAccuracy() throws {
        let a = try box(1e-4, 1e-4, 1e-4)
        let b = try box(1e-4, 1e-4, 1e-4).translated(by: Vec3(5e-5, 0, 0))
        let u = try CSG.union(a, b)
        XCTAssertEqual(u.volume, 1.5e-12, accuracy: 3e-14)
        let s = try CSG.subtract(a, b)
        XCTAssertEqual(s.volume, 0.5e-12, accuracy: 3e-14)
    }
}
