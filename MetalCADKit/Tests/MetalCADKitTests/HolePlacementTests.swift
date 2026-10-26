import XCTest
@testable import MetalCADKit

/// Hole placement/size: a sketch CIRCLE used as a hole site must drill
/// at the circle's own diameter — the circle is the hole profile, not
/// just a point marker for the panel's Diameter field. (Device bug,
/// 2026-10-26: user sketched a big circle on a face, applied Hole, and
/// got a small hole at the circle's center.) Point sites keep the
/// feature's diameter.
final class HolePlacementTests: XCTestCase {

    /// 40 x 40 plate padded 5 mm (z 0...5), as in the task spec.
    private func platePart5() -> Part {
        var part = Part(name: "plate")
        var base = Sketch(name: "base", plane: .xy)
        base.addRectangle(from: Vec2(-20, -20), to: Vec2(20, 20))
        part.sketches.append(base)
        part.features.append(Feature(name: "Plate",
                                     kind: .pad(sketchID: base.id, length: 5)))
        return part
    }

    private var topPlane5: Plane3 {
        Plane3(origin: Vec3(0, 0, 5), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))
    }

    /// Circle r17 on the top face, hole feature carrying a small panel
    /// diameter (6) — the circle's size must win, leaving a ring.
    func testCircleSiteDrillsAtCircleDiameter() {
        var part = platePart5()
        var face = Sketch(name: "face", plane: topPlane5)
        face.addCircle(Vec2(0, 0), 17)
        part.sketches.append(face)
        part.features.append(Feature(name: "Hole",
                                     kind: .hole(sketchID: face.id, diameter: 6,
                                                 depth: 0, kind: .simple)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Ring: 8000 - pi * 17^2 * 5 = 3461 (48-gon cutter: ~3474).
        XCTAssertEqual(r.mesh.volume, 3461, accuracy: 160,
                       "circle r17 must drill Ø34, got volume \(r.mesh.volume)")
        // Void along the axis, all the way through.
        for z in [0.5, 2.5, 4.5] {
            XCTAssertFalse(r.mesh.contains(Vec3(0, 0, z)),
                           "axis point z=\(z) should be void (through hole)")
        }
        // Void near the circle's edge too (r=16 < 17).
        XCTAssertFalse(r.mesh.contains(Vec3(16, 0, 2.5)))
        // The rim survives: r=19 > 17 is solid.
        XCTAssertTrue(r.mesh.contains(Vec3(19, 0, 2.5)), "rim should stay solid")
        XCTAssertTrue(r.mesh.contains(Vec3(0, 19, 2.5)), "rim should stay solid")
    }

    /// Circle r25 (Ø50) on a 40 mm plate: only the corners survive.
    func testOversizeCircleLeavesOnlyCorners() {
        var part = platePart5()
        var face = Sketch(name: "face", plane: topPlane5)
        face.addCircle(Vec2(0, 0), 25)
        part.sketches.append(face)
        part.features.append(Feature(name: "Hole",
                                     kind: .hole(sketchID: face.id, diameter: 6,
                                                 depth: 0, kind: .simple)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // Past the plate's edge midpoints the circle has cut through.
        for p in [Vec3(0, 19, 2.5), Vec3(0, -19, 2.5),
                  Vec3(19, 0, 2.5), Vec3(-19, 0, 2.5)] {
            XCTAssertFalse(r.mesh.contains(p), "\(p) should be void")
        }
        // Corners (dist ~26.9 > 25) stay solid.
        XCTAssertTrue(r.mesh.contains(Vec3(19, 19, 2.5)), "corner should stay solid")
        XCTAssertGreaterThan(r.mesh.volume, 0)
        XCTAssertLessThan(r.mesh.volume, 1200,
                          "only corner caps should remain, got \(r.mesh.volume)")
    }

    /// The app's Demo Part (DocumentsView.DemoFactory), plus what the
    /// user did on device: applied Hole — with the panel defaults
    /// (Ø6, through, simple) — to the demo's face sketch, "Face
    /// Sketch — Boss", whose single item is a circle r5 at (22, 0).
    /// The hole must come out at the circle's Ø10, not the panel's Ø6.
    func testDemoPartFaceSketchHoleUsesCircleSize() {
        var part = Part(name: "Demo Part")
        part.materialID = "stainless-304"
        var plate = Sketch(name: "Plate", plane: .xy)
        plate.addRectangle(from: Vec2(-30, -20), to: Vec2(30, 20))
        part.sketches.append(plate)
        part.features.append(Feature(name: "Base Plate",
                                     kind: .pad(sketchID: plate.id, length: 10)))
        let topPlane = Plane3(origin: Vec3(0, 0, 10),
                              xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))
        var pocketSketch = Sketch(name: "Pocket Outline", plane: topPlane)
        pocketSketch.addRectangle(from: Vec2(-15, -10), to: Vec2(15, 10))
        part.sketches.append(pocketSketch)
        part.features.append(Feature(name: "Pocket",
                                     kind: .pocket(sketchID: pocketSketch.id, depth: 4)))
        var holeSketch = Sketch(name: "Hole Points", plane: topPlane)
        holeSketch.addPoint(Vec2(-22, -12))
        holeSketch.addPoint(Vec2(-22, 12))
        part.sketches.append(holeSketch)
        part.features.append(Feature(name: "Holes",
                                     kind: .hole(sketchID: holeSketch.id, diameter: 6,
                                                 depth: 0, kind: .simple)))
        var bossSketch = Sketch(name: "Face Sketch — Boss", plane: topPlane)
        bossSketch.addCircle(Vec2(22, 0), 5)
        part.sketches.append(bossSketch)
        part.features.append(Feature(name: "Boss",
                                     kind: .pad(sketchID: bossSketch.id, length: 6)))
        // The user's step: Hole on the face (boss) sketch, panel Ø6.
        part.features.append(Feature(name: "Hole",
                                     kind: .hole(sketchID: bossSketch.id, diameter: 6,
                                                 depth: 0, kind: .simple)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        let m = r.mesh
        // 2 mm from the axis: void under either behaviour.
        XCTAssertFalse(m.contains(Vec3(24, 0, 5)))
        // 4 mm from the axis, inside the plate: SOLID when the hole is
        // drilled at the panel Ø6 (r3) — the bug; VOID once the hole
        // takes the circle's Ø10 (r5).
        XCTAssertFalse(m.contains(Vec3(26, 0, 5)),
                       "4 mm from the axis should be void — hole must be the circle's Ø10, not the panel Ø6")
        // 6.5 mm from the axis: outside the circle, stays solid.
        XCTAssertTrue(m.contains(Vec3(28.5, 0, 5)))
        // The boss itself is drilled through at its own diameter.
        XCTAssertFalse(m.contains(Vec3(22, 0, 13)))
    }
}
