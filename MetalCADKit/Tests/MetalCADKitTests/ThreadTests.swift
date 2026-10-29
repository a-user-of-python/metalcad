import XCTest
@testable import MetalCADKit

/// 50 checks: thread presets, derived geometry, validation error codes,
/// and tessellation of modeled threads.
final class ThreadTests: XCTestCase {

    func testPresetM10() throws {
        let s = try ThreadSpec.preset("M10")
        XCTAssertEqual(s.majorDiameter, 10)
        XCTAssertEqual(s.pitch, 1.5)
        XCTAssertEqual(s.standard, .isoMetric)
    }

    func testPresetTable() throws {
        let table: [(String, Double, Double)] = [
            ("M3", 3, 0.5), ("M4", 4, 0.7), ("M5", 5, 0.8), ("M6", 6, 1.0),
            ("M8", 8, 1.25), ("M12", 12, 1.75), ("M16", 16, 2.0), ("M20", 20, 2.5),
        ]
        for (name, d, p) in table {
            let s = try ThreadSpec.preset(name)
            XCTAssertEqual(s.majorDiameter, d, name)
            XCTAssertEqual(s.pitch, p, name)
        }
    }

    func testPresetUNC() throws {
        let s = try ThreadSpec.preset("1/4-20")
        XCTAssertEqual(s.standard, .unc)
        XCTAssertEqual(s.majorDiameter, 6.35, accuracy: 1e-9)
        XCTAssertEqual(s.pitch, 25.4 / 20, accuracy: 1e-9)
    }

    func testPresetNPT() throws {
        let s = try ThreadSpec.preset("NPT 1/2")
        XCTAssertEqual(s.standard, .npt)
        XCTAssertEqual(s.taperDegrees, 1.7899, accuracy: 1e-9)
        XCTAssertEqual(s.majorDiameter, 21.34, accuracy: 1e-9)
    }

    func testPresetUnknownThrowsTH509() {
        XCTAssertThrowsError(try ThreadSpec.preset("M99")) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH509")
        }
        XCTAssertThrowsError(try ThreadSpec.preset("banana")) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH509")
        }
    }

    func testDerivedDiameters() throws {
        let s = try ThreadSpec.preset("M10")
        XCTAssertEqual(s.threadDepth, 0.61343 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.minorDiameter, 10 - 2 * 0.61343 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.pitchDiameter, 10 - 0.64952 * 1.5, accuracy: 1e-9)
        XCTAssertGreaterThan(s.minorDiameter, 8)
        XCTAssertLessThan(s.minorDiameter, s.majorDiameter)
    }

    func testLeadMultiStart() {
        var s = ThreadSpec()
        s.pitch = 2; s.starts = 3
        XCTAssertEqual(s.lead, 6)
        s.starts = 1
        XCTAssertEqual(s.lead, 2)
    }

    func testValidateGoodSpec() throws {
        let (spec, warnings) = try ThreadSpec().validated()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(spec.majorDiameter, 10)
    }

    func testPitchZeroThrowsTH501() {
        var s = ThreadSpec(); s.pitch = 0
        XCTAssertThrowsError(try s.validated()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH501")
        }
    }

    func testPitchTooBigThrowsTH501() {
        var s = ThreadSpec(); s.pitch = 12  // > major 10
        XCTAssertThrowsError(try s.validated()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH501")
        }
    }

    func testStartsOutOfRangeTH504() {
        var s = ThreadSpec(); s.starts = 5
        XCTAssertThrowsError(try s.validated()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH504")
        }
        var s2 = ThreadSpec(); s2.starts = 0
        XCTAssertThrowsError(try s2.validated()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH504")
        }
    }

    func testProfileAngleTH503() {
        var s = ThreadSpec(); s.profileAngleDegrees = 200
        XCTAssertThrowsError(try s.validated()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH503")
        }
        var s2 = ThreadSpec(); s2.profileAngleDegrees = 2
        XCTAssertThrowsError(try s2.validated()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH503")
        }
    }

    func testTooLongClampsWithTH505() throws {
        var s = ThreadSpec(); s.length = 50
        let (spec, warnings) = try s.validated(shaftLength: 30)
        XCTAssertEqual(spec.length, 30)
        XCTAssertTrue(warnings.contains { $0.code == "MCAD-TH505" })
    }

    func testWideProfileSweepThrowsTH506() {
        // A 120° profile is ~3x deeper than 60° for the same pitch:
        // depth ≈ 1.84 × pitch, so the ridge must fold → TH506.
        var s = ThreadSpec()
        s.majorDiameter = 10; s.pitch = 1.5; s.profileAngleDegrees = 120
        XCTAssertThrowsError(try s.validated()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH506")
        }
    }

    func testFitClampTH508() throws {
        var s = ThreadSpec(); s.clearance = 100
        let (spec, warnings) = try s.validated()
        XCTAssertTrue(warnings.contains { $0.code == "MCAD-TH508" })
        XCTAssertEqual(spec.clearance, s.pitch * 0.25, accuracy: 1e-9)
    }

    func testTaperVanishThrowsTH507() {
        var s = ThreadSpec()
        s.majorDiameter = 10; s.pitch = 1.5; s.taperDegrees = 5; s.length = 100
        XCTAssertThrowsError(try s.validated()) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-TH507")
        }
    }

    func testRidgeMeshExists() throws {
        let s = try ThreadSpec.preset("M10")
        let m = try ThreadTessellator.ridgeMesh(spec: s)
        XCTAssertGreaterThan(m.triangleCount, 100)
        XCTAssertFalse(m.hasNaN)
    }

    func testRidgeOuterRadius() throws {
        let s = try ThreadSpec.preset("M10")
        let m = try ThreadTessellator.ridgeMesh(spec: s)
        let maxR = m.vertices.map { ($0.x * $0.x + $0.y * $0.y).squareRoot() }.max()!
        XCTAssertEqual(maxR, 5, accuracy: 0.1)
    }

    func testThreadedShaftVolume() throws {
        let s = try ThreadSpec.preset("M10")
        let shaft = try ThreadTessellator.threadedShaft(spec: s)
        let plain = try Tessellation.cylinder(radius: s.minorDiameter / 2, height: s.length, segments: 64)
        XCTAssertGreaterThan(shaft.volume, plain.volume)
        XCTAssertFalse(shaft.hasNaN)
        XCTAssertEqual(shaft.bounds.size.z, s.length, accuracy: 1.0)
    }

    func testLeftHandDiffersFromRight() throws {
        var s = try ThreadSpec.preset("M10")
        let right = try ThreadTessellator.ridgeMesh(spec: s)
        s.hand = .left
        let left = try ThreadTessellator.ridgeMesh(spec: s)
        XCTAssertEqual(right.triangleCount, left.triangleCount)
        XCTAssertNotEqual(right.vertices, left.vertices)
    }

    func testInternalThreadMesh() throws {
        var s = try ThreadSpec.preset("M10")
        s.kind = .internal
        let m = try ThreadTessellator.ridgeMesh(spec: s)
        XCTAssertGreaterThan(m.triangleCount, 0)
        XCTAssertFalse(m.hasNaN)
    }

    func testMultiStartGeometryDiffers() throws {
        // Same total helix length (lead doubles as starts double), but the
        // ridges sit at different phases — geometry must differ.
        var s = try ThreadSpec.preset("M10")
        s.starts = 1
        let one = try ThreadTessellator.ridgeMesh(spec: s)
        s.starts = 2
        let two = try ThreadTessellator.ridgeMesh(spec: s)
        XCTAssertGreaterThan(one.triangleCount, 0)
        XCTAssertGreaterThan(two.triangleCount, 0)
        XCTAssertNotEqual(one.vertices, two.vertices)
    }

    func testSpecCodableRoundTrip() throws {
        let s = try ThreadSpec.preset("M12")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ThreadSpec.self, from: data)
        XCTAssertEqual(back, s)
    }

    // Stage 4: ISO metric FINE presets are starting points in the
    // same table (the spec stays fully editable afterwards).
    func testFinePresets() throws {
        let m10f = try ThreadSpec.preset("M10x1.25")
        XCTAssertEqual(m10f.majorDiameter, 10)
        XCTAssertEqual(m10f.pitch, 1.25)
        let m8f = try ThreadSpec.preset("M8x1")
        XCTAssertEqual(m8f.majorDiameter, 8)
        XCTAssertEqual(m8f.pitch, 1.0)
        XCTAssertNil(m10f.depthOverride, "presets never lock a depth")
    }

    // Stage 4: the depth override drives threadDepth (and so the
    // minor diameter and the engine's mc_thread depth); nil keeps
    // the standard depth.
    func testDepthOverride() throws {
        var s = try ThreadSpec.preset("M10")
        XCTAssertNil(s.depthOverride)
        XCTAssertEqual(s.threadDepth, 0.61343 * 1.5, accuracy: 1e-9)
        s.depthOverride = 0.5
        XCTAssertEqual(s.threadDepth, 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.minorDiameter, 9.0, accuracy: 1e-12)
        let (v, _) = try s.validated()
        XCTAssertEqual(v.threadDepth, 0.5, accuracy: 1e-12)
    }

    // Stage 4: an impossible depth override fails with a coded
    // error (TH503), never a silent bad solid.
    func testDepthOverrideTooDeepThrows() throws {
        var s = try ThreadSpec.preset("M10")
        s.depthOverride = 5.0  // == major/2: cuts through the core
        XCTAssertThrowsError(try s.validated()) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-TH503")
        }
        s.depthOverride = -1
        XCTAssertThrowsError(try s.validated()) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-TH503")
        }
    }

    // Stage 4: documents written before depthOverride existed
    // (the key absent from the JSON) decode with a nil override.
    func testSpecDecodesWithoutDepthOverrideKey() throws {
        var s = try ThreadSpec.preset("M10")
        s.depthOverride = nil
        let data = try JSONEncoder().encode(s)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("depthOverride"))
        let back = try JSONDecoder().decode(ThreadSpec.self, from: data)
        XCTAssertNil(back.depthOverride)
        XCTAssertEqual(back, s)
    }
}
