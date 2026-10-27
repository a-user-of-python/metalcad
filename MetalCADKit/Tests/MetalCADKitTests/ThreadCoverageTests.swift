import XCTest
@testable import MetalCADKit

/// Defect A (device, 2026-10-26): threads applied to a tapped shaft
/// didn't cover it — the spec's length came from the fitted patch,
/// which stops at seams, fillet runouts and junctions and understates
/// the shaft. `.threadOnShaft` now measures the shaft's true column
/// extent from the body. These tests drive the exact app flow
/// (seed a side triangle -> CylinderFitter -> prefill -> feature)
/// and measure the RESULT: ridge angular coverage at stations
/// across the middle 80% of the pillar and the threaded span
/// against the pillar's true exposed length.
final class ThreadCoverageTests: XCTestCase {

    /// The app's shaft-panel prefill (preset near the diameter wins
    /// its pitch; major/length from the fit).
    static func appPrefill(diameter: Double, length: Double) -> ThreadSpec {
        for name in ["M3", "M4", "M5", "M6", "M8", "M10", "M12", "M16", "M20"] {
            guard let p = try? ThreadSpec.preset(name) else { continue }
            if abs(p.majorDiameter - diameter) <= 0.02 * diameter {
                var match = p
                match.kind = .external
                match.length = length
                return match
            }
        }
        var custom = ThreadSpec()
        custom.kind = .external
        custom.majorDiameter = diameter
        custom.length = length
        return custom
    }

    static func demoPart() -> Part {
        var part = Part(name: "Demo Part")
        part.materialID = "stainless-304"
        var plate = Sketch(name: "Plate", plane: .xy)
        plate.addRectangle(from: Vec2(-30, -20), to: Vec2(30, 20))
        part.sketches.append(plate)
        part.features.append(Feature(name: "Base Plate", kind: .pad(sketchID: plate.id, length: 10)))
        let topPlane = Plane3(origin: Vec3(0, 0, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))
        var pocketSketch = Sketch(name: "Pocket Outline", plane: topPlane)
        pocketSketch.addRectangle(from: Vec2(-15, -10), to: Vec2(15, 10))
        part.sketches.append(pocketSketch)
        part.features.append(Feature(name: "Pocket", kind: .pocket(sketchID: pocketSketch.id, depth: 4)))
        var holeSketch = Sketch(name: "Hole Points", plane: topPlane)
        holeSketch.addPoint(Vec2(-22, -12))
        holeSketch.addPoint(Vec2(-22, 12))
        part.sketches.append(holeSketch)
        part.features.append(Feature(name: "Holes", kind: .hole(sketchID: holeSketch.id, diameter: 6, depth: 0, kind: .simple)))
        var bossSketch = Sketch(name: "Face Sketch — Boss", plane: topPlane)
        bossSketch.addCircle(Vec2(22, 0), 5)
        part.sketches.append(bossSketch)
        part.features.append(Feature(name: "Boss", kind: .pad(sketchID: bossSketch.id, length: 6)))
        return part
    }

    static func seedOnCylinder(_ mesh: Mesh, axisPoint: Vec3, radius: Double,
                               sRange: ClosedRange<Double>, axis: Vec3) -> Int? {
        let m = mesh.welded()
        let normals = m.faceNormals()
        for t in 0..<m.triangleCount {
            let a = m.vertices[Int(m.indices[t * 3])]
            let b = m.vertices[Int(m.indices[t * 3 + 1])]
            let c = m.vertices[Int(m.indices[t * 3 + 2])]
            let cen = (a + b + c) * (1.0 / 3)
            let d = cen - axisPoint
            let s = d.dot(axis)
            let rad = (d - axis * s).length
            if abs(rad - radius) < 0.3, sRange.contains(s), abs(normals[t].dot(axis)) < 0.3 {
                return t
            }
        }
        return nil
    }

    /// Ridge vertices of a threaded result, in the TRUE pillar frame:
    /// (axial s from frameOrigin along frameAxis, angle, radius).
    static func ridgePoints(_ mesh: Mesh, frameOrigin: Vec3, frameAxis: Vec3,
                            spec: ThreadSpec) -> [(s: Double, ang: Double, r: Double)] {
        let ax = frameAxis.normalized
        let helper = abs(ax.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(ax).normalized
        let w = ax.cross(u)
        let rIn = spec.minorDiameter / 2
        let rOut = spec.majorDiameter / 2
        var out: [(s: Double, ang: Double, r: Double)] = []
        for v in mesh.vertices {
            let d = v - frameOrigin
            let s = d.dot(ax)
            let rad = d - ax * s
            let r = rad.length
            if r > rIn + 0.15 && r < rOut + 0.2 {
                var a = atan2(rad.dot(w), rad.dot(u))
                if a < 0 { a += 2 * Double.pi }
                out.append((s, a, r))
            }
        }
        return out
    }

    /// Assert >= 350 deg ridge coverage at stations across the
    /// middle 80% of [0, span] and a threaded span >= 95% of it.
    static func assertCoverage(_ mesh: Mesh, frameOrigin: Vec3, frameAxis: Vec3,
                               spec: ThreadSpec, span: Double,
                               file: StaticString = #filePath, line: UInt = #line) {
        let pts = ridgePoints(mesh, frameOrigin: frameOrigin, frameAxis: frameAxis, spec: spec)
        XCTAssertFalse(pts.isEmpty, "no ridge vertices found", file: file, line: line)
        let sMin = pts.map(\.s).min() ?? 0
        let sMax = pts.map(\.s).max() ?? 0
        XCTAssertGreaterThanOrEqual(sMax - sMin, span * 0.95,
                                    "threaded span \(sMax - sMin) < 95% of pillar \(span)", file: file, line: line)
        var s = span * 0.1
        while s <= span * 0.9 {
            var bins = Set<Int>()
            for p in pts where abs(p.s - s) <= spec.pitch / 2 {
                bins.insert(Int(p.ang / (10 * Double.pi / 180)) % 36)
            }
            XCTAssertGreaterThanOrEqual(bins.count * 10, 350,
                                        "coverage at s=\(s) is \(bins.count * 10) deg", file: file, line: line)
            s += spec.pitch / 2
        }
    }

    func testDemoBossThreadCovers() throws {
        var part = Self.demoPart()
        let body = DocumentEngine.rebuild(part: part).mesh
        let seed = try XCTUnwrap(Self.seedOnCylinder(body, axisPoint: Vec3(22, 0, 10), radius: 5,
                                                     sRange: 1...5, axis: Vec3(0, 0, 1)))
        let fit = try XCTUnwrap(CylinderFitter.fit(mesh: body, seedTriangle: seed))
        let spec = Self.appPrefill(diameter: fit.radius * 2, length: fit.height)
        part.features.append(Feature(name: "Thread", kind: .threadOnShaft(spec: spec, origin: fit.origin, axis: fit.axis)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // True frame: boss base (22,0,10), axis +Z, exposed span 6.
        Self.assertCoverage(r.mesh, frameOrigin: Vec3(22, 0, 10), frameAxis: Vec3(0, 0, 1),
                            spec: spec, span: 6)
    }

    func testDownPillarThreadCovers() throws {
        var part = Part(name: "down")
        let platePlane = Plane3(origin: Vec3(0, 0, 15), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))
        var plate = Sketch(name: "Plate", plane: platePlane)
        plate.addRectangle(from: Vec2(-20, -20), to: Vec2(20, 20))
        part.sketches.append(plate)
        part.features.append(Feature(name: "Plate", kind: .pad(sketchID: plate.id, length: 5)))
        let underPlane = Plane3(origin: Vec3(0, 0, 15), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, -1, 0))
        var boss = Sketch(name: "Boss", plane: underPlane)
        boss.addCircle(Vec2(0, 0), 5)
        part.sketches.append(boss)
        part.features.append(Feature(name: "Boss", kind: .pad(sketchID: boss.id, length: 12)))
        let body = DocumentEngine.rebuild(part: part).mesh
        let seed = try XCTUnwrap(Self.seedOnCylinder(body, axisPoint: Vec3(0, 0, 15), radius: 5,
                                                     sRange: 1...11, axis: Vec3(0, 0, -1)))
        let fit = try XCTUnwrap(CylinderFitter.fit(mesh: body, seedTriangle: seed))
        let spec = Self.appPrefill(diameter: fit.radius * 2, length: fit.height)
        part.features.append(Feature(name: "Thread", kind: .threadOnShaft(spec: spec, origin: fit.origin, axis: fit.axis)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        // True frame: pillar tip (0,0,3) -> plate (0,0,15); measure
        // from the plate junction down: origin (0,0,15), axis -Z.
        Self.assertCoverage(r.mesh, frameOrigin: Vec3(0, 0, 15), frameAxis: Vec3(0, 0, -1),
                            spec: spec, span: 12)
    }

    /// The fit-understates case: a collar ring around the pillar
    /// mid-height splits its side into two patches (the ring's flat
    /// annular faces turn 90 degrees from the side, so region
    /// growing can't cross). The fitter sees only the top patch
    /// (~5 of 12 mm); the thread must still cover the whole pillar
    /// because the engine measures the shaft column from the body.
    func testThreadExtendsPastInterruptedFit() throws {
        var part = Part(name: "collar")
        var plate = Sketch(name: "Plate", plane: .xy)
        plate.addRectangle(from: Vec2(-20, -20), to: Vec2(20, 20))
        part.sketches.append(plate)
        part.features.append(Feature(name: "Plate", kind: .pad(sketchID: plate.id, length: 5)))
        let topPlane = Plane3(origin: Vec3(0, 0, 5), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))
        var boss = Sketch(name: "Boss", plane: topPlane)
        boss.addCircle(Vec2(0, 0), 5)
        part.sketches.append(boss)
        part.features.append(Feature(name: "Boss", kind: .pad(sketchID: boss.id, length: 12)))
        // Collar ring around the pillar at z 9..12.
        let collarPlane = Plane3(origin: Vec3(0, 0, 9), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))
        var collar = Sketch(name: "Collar", plane: collarPlane)
        collar.addCircle(Vec2(0, 0), 7)
        part.sketches.append(collar)
        part.features.append(Feature(name: "Collar", kind: .pad(sketchID: collar.id, length: 3)))
        let body = DocumentEngine.rebuild(part: part).mesh
        // Seed the TOP patch of the pillar side (z 13..16 above plate top 5 -> s 8..11).
        let seed = try XCTUnwrap(Self.seedOnCylinder(body, axisPoint: Vec3(0, 0, 5), radius: 5,
                                                     sRange: 8...11, axis: Vec3(0, 0, 1)))
        let fit = try XCTUnwrap(CylinderFitter.fit(mesh: body, seedTriangle: seed))
        XCTAssertLessThan(fit.height, 8, "setup: the fit must understate the 12 mm pillar (got \(fit.height))")
        let spec = Self.appPrefill(diameter: fit.radius * 2, length: fit.height)
        part.features.append(Feature(name: "Thread", kind: .threadOnShaft(spec: spec, origin: fit.origin, axis: fit.axis)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        Self.assertCoverage(r.mesh, frameOrigin: Vec3(0, 0, 5), frameAxis: Vec3(0, 0, 1),
                            spec: spec, span: 12)
    }
}
