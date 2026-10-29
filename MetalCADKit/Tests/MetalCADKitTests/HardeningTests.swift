import XCTest
@testable import MetalCADKit

/// Hardening round (2026-10-29) — regression tests for Sean's
/// device failure: a hand-drawn closed profile on a sketch-on-face
/// errored MCAD-SK204 ("the outline isn't closed") on EVERY
/// sketch-consuming feature, because profile chaining demanded
/// bit-exact endpoint coincidence (1e-6 mm) from a touch editor
/// whose entities store independent endpoint copies and whose snap
/// is best-effort within ~14 screen points. The fix: two-tier
/// chaining — exact first, then sewing at `Sketch.sewTolerance`,
/// reported as MCAD-SK213; gaps beyond the tolerance stay SK204.
final class HardeningTests: XCTestCase {

    /// A 10x10 square drawn as four lines (the editor's line tool),
    /// with the last corner missing its mate by `miss` mm.
    private func handSquare(miss: Double) -> Sketch {
        var s = Sketch(name: "hand")
        let c = [Vec2(-5, -5), Vec2(5, -5), Vec2(5, 5), Vec2(-5, 5)]
        for i in 0..<4 {
            var end = c[(i + 1) % 4]
            if i == 3 { end = end + Vec2(miss, miss * 0.7) }
            s.addLine(c[i], end)
        }
        return s
    }

    func testExactSquareHasNoHealWarning() throws {
        let (_, warnings) = try handSquare(miss: 0).extractProfiles()
        XCTAssertFalse(warnings.contains { $0.code == "MCAD-SK213" })
    }

    func testSubVisibleMissesHeal() throws {
        // The sewn distance is the Euclidean corner gap:
        // miss * sqrt(1 + 0.7^2) = miss * 1.22 — all <= 0.49 mm here.
        for miss in [0.001, 0.02, 0.1, 0.25, 0.4] {
            let (profiles, warnings) = try handSquare(miss: miss).extractProfiles()
            XCTAssertEqual(profiles.count, 1, "miss \(miss)")
            XCTAssertEqual(profiles[0].area, 100, accuracy: 1.0, "miss \(miss)")
            let heal = warnings.first { $0.code == "MCAD-SK213" }
            XCTAssertNotNil(heal, "miss \(miss) should report SK213")
            if case .profileGapHealed(let gap) = heal! {
                XCTAssertEqual(gap, miss * 1.22, accuracy: miss * 0.35, "miss \(miss)")
            }
        }
    }

    func testGapBeyondToleranceStillSK204() {
        XCTAssertThrowsError(try handSquare(miss: 0.6).extractProfiles()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-SK204")
        }
        XCTAssertThrowsError(try handSquare(miss: 2.0).extractProfiles()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-SK204")
        }
    }

    /// Sean's exact scenario at the document level: a closed
    /// hand-drawn profile (0.02 mm corner miss) on the end plane of
    /// a cylinder, pocketed. Before the fix this rebuild failed
    /// with SK204; the profile now sews and the pocket cuts.
    func testSeanScenarioPocket() throws {
        var part = Part(name: "Tube")
        part.features.append(Feature(name: "Body", kind: .primitive(
            kind: .cylinder, params: ["diameter": 10, "height": 23])))
        var sk = Sketch(name: "Sketch on Face 1",
                        plane: Plane3(origin: Vec3(0, 0, 23), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        let c = [Vec2(-3, -3), Vec2(3, -3), Vec2(3, 3), Vec2(-3, 3)]
        for i in 0..<4 {
            var end = c[(i + 1) % 4]
            if i == 1 { end = end + Vec2(0.02, 0) }
            sk.addLine(c[i], end)
        }
        part.sketches.append(sk)
        part.features.append(Feature(name: "Pocket", kind: .pocket(sketchID: sk.id, depth: 5)))
        let result = DocumentEngine.rebuild(part: part)
        XCTAssertNil(result.firstError, "rebuild errored: \(result.firstError?.code ?? "")")
        // Cylinder 1809.56 mm3 minus a 6x6x5 pocket (180 mm3).
        XCTAssertEqual(result.mesh.volume, 1809.56 - 180, accuracy: 25)
        XCTAssertTrue(result.warnings.contains { $0.code == "MCAD-SK213" })
    }

    /// Same scenario through the Cascade Pocket kind: with no
    /// provider registered (kit context) it must fail KN601 —
    /// proving the kind never silently falls back to the legacy
    /// kernel — and its profile validation must NOT be what fails.
    func testSeanScenarioCascadePocketNeedsEngine() throws {
        var part = Part(name: "Tube")
        part.features.append(Feature(name: "Body", kind: .primitive(
            kind: .cylinder, params: ["diameter": 10, "height": 23])))
        var sk = Sketch(name: "Sketch on Face 1",
                        plane: Plane3(origin: Vec3(0, 0, 23), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        sk.addCircle(Vec2(0, 0), 3)
        part.sketches.append(sk)
        part.features.append(Feature(name: "Cascade Pocket", kind: .cascadePocket(sketchID: sk.id, depth: 5)))
        let result = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(result.firstError?.code, "MCAD-KN601")
    }

    /// A hand-drawn annulus (two line-drawn rings, one corner miss
    /// in the outer ring) still resolves to one profile with a hole.
    func testHandAnnulusHeals() throws {
        var s = Sketch(name: "annulus")
        func ring(_ r: Double, miss: Double) {
            let n = 8
            let pts: [Vec2] = (0..<n).map { i in
                let a = Double(i) * 2 * Double.pi / Double(n)
                return Vec2(r * cos(a), r * sin(a))
            }
            for i in 0..<n {
                // Only ONE segment carries the offset copy of the
                // shared corner — exactly how the editor stores it
                // (each line owns its endpoint values).
                let end = pts[(i + 1) % n] + (i == n - 1 ? Vec2(miss, 0) : .zero)
                s.addLine(pts[i], end)
            }
        }
        ring(5, miss: 0.05)
        ring(3, miss: 0)
        let (profiles, warnings) = try s.extractProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].holes.count, 1)
        XCTAssertTrue(warnings.contains { $0.code == "MCAD-SK213" })
    }

    /// Sweep/pipe/rib path chaining sews too: a path whose middle
    /// joint misses by 0.1 mm still chains end to end.
    func testPathPointsSew() throws {
        var s = Sketch(name: "path")
        s.addLine(Vec2(0, 0), Vec2(10, 0))
        s.addLine(Vec2(10.1, 0.05), Vec2(10, 10))
        s.addLine(Vec2(10, 10), Vec2(0, 10))
        let pts = try DocumentEngine.pathPoints(sketch: s)
        XCTAssertEqual(pts.count, 4)
        XCTAssertEqual(pts.first, Vec3(0, 0, 0))
        XCTAssertEqual(pts.last, Vec3(0, 10, 0))
    }

    /// A lone segment beside a closed profile is a reference
    /// line (revolve axis, centreline): dropped, never SK204.
    func testStandaloneAxisLineDropped() throws {
        var s = Sketch(name: "rev")
        s.addRectangle(from: Vec2(5, 0), to: Vec2(10, 8))
        s.addLine(Vec2(0, -2), Vec2(0, 10))   // separate axis line
        let (profiles, _) = try s.extractProfiles()
        XCTAssertEqual(profiles.count, 1)
    }

    /// A multi-segment outline that nearly closes (2 mm end
    /// gap) next to a valid profile still throws SK204 — it is
    /// a broken outline, not decoration.
    func testNearClosedChainThrowsBesideProfile() {
        var s = Sketch(name: "two")
        s.addRectangle(from: Vec2(-20, -5), to: Vec2(-10, 5))
        s.addLine(Vec2(10, -5), Vec2(20, -5))
        s.addLine(Vec2(20, -5), Vec2(20, 5))
        s.addLine(Vec2(20, 5), Vec2(12, 5))
        s.addLine(Vec2(10, 5), Vec2(10, -3))
        XCTAssertThrowsError(try s.extractProfiles()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-SK204")
        }
    }

    /// A wide-open polyline next to a valid profile is
    /// decoration: dropped silently.
    func testWideOpenPolylineDroppedBesideProfile() throws {
        var s = Sketch(name: "deco")
        s.addRectangle(from: Vec2(-20, -5), to: Vec2(-10, 5))
        s.addLine(Vec2(10, -5), Vec2(20, -5))
        s.addLine(Vec2(20, -5), Vec2(20, 5))
        let (profiles, _) = try s.extractProfiles()
        XCTAssertEqual(profiles.count, 1)
    }

    /// Legacy-kernel countersink actually removes its frustum
    /// (hardening 2026-10-29: the old cone tool lay entirely
    /// inside the drilled cylinder and removed nothing).
    /// Box 30x20x12, hole d6 through, 90-degree sink: the sink
    /// frustum (r6 -> r3 over 3 mm) removes 36*pi beyond the
    /// through hole (its inner r3 cylinder is the hole itself).
    func testLegacyCountersinkVolume() throws {
        var part = Part(name: "sink")
        part.features.append(Feature(name: "Box", kind: .primitive(
            kind: .box, params: ["width": 30, "depth": 20, "height": 12])))
        var sk = Sketch(name: "pts", plane: Plane3(origin: Vec3(0, 0, 12),
                                                  xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        sk.addPoint(Vec2(0, 0))
        part.sketches.append(sk)
        part.features.append(Feature(name: "Hole", kind: .hole(
            sketchID: sk.id, diameter: 6, depth: 0, kind: .countersink(angleDegrees: 90))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Frustum 63*pi minus the r3x3 cylinder shared with the
        // through hole (27*pi) = 36*pi beyond the hole's 108*pi.
        let expected = 7200 - 144 * Double.pi
        XCTAssertEqual(r.mesh.volume, expected, accuracy: expected * 0.01)
    }

    /// Editor-built shapes keep extracting exactly, with no heal
    /// warning: rectangle tool, ellipse loop, polygon loop, slot.
    func testEditorShapesStayExact() throws {
        var rect = Sketch(name: "rect")
        rect.addRectangle(from: Vec2(-5, -5), to: Vec2(5, 5))
        let (rp, rw) = try rect.extractProfiles()
        XCTAssertEqual(rp[0].area, 100, accuracy: 1e-9)
        XCTAssertTrue(rw.isEmpty)

        var ell = Sketch(name: "ellipse")
        var prev = Vec2(5, 0)
        for i in 1...48 {
            let a = Double(i) / Double(48) * 2 * Double.pi
            let p = Vec2(5 * cos(a), 3 * sin(a))
            ell.addLine(prev, p)
            prev = p
        }
        let (ep, ew) = try ell.extractProfiles()
        XCTAssertEqual(ep.count, 1)
        XCTAssertTrue(ew.isEmpty)

        var slot = Sketch(name: "slot")
        let a = Vec2(-4, 0), b = Vec2(4, 0), sr = 2.0
        let perp = (b - a).normalized.perpendicular
        let pa = atan2(perp.y, perp.x)
        slot.addLine(b + perp * sr, a + perp * sr)
        slot.addLine(a - perp * sr, b - perp * sr)
        slot.add(.arc(id: slot.allocateID(), center: b, radius: sr,
                      startAngle: pa - Double.pi, endAngle: pa, construction: false))
        slot.add(.arc(id: slot.allocateID(), center: a, radius: sr,
                      startAngle: pa, endAngle: pa + Double.pi, construction: false))
        let (sp, sw) = try slot.extractProfiles()
        XCTAssertEqual(sp.count, 1)
        XCTAssertTrue(sw.isEmpty)
    }
}
