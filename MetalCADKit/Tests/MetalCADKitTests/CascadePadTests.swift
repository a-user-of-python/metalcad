import XCTest
@testable import MetalCADKit

/// The `.cascadePad` feature kind (Cascade implant, 2026-10-28): the
/// kit itself stays pure Swift — these tests register a stub
/// evaluator and prove the rebuild wiring, the error when no kernel
/// is registered (MCAD-KN601), and document persistence. The real
/// OCCT evaluator is registered by the app (CascadeBridge) and its
/// geometry is proven on the cascade-ios host harness.
final class CascadePadTests: XCTestCase {

    override func tearDown() {
        DocumentEngine.cascadePadEvaluator = nil
        super.tearDown()
    }

    private func partWithCascadePad() -> (Part, Feature) {
        var part = Part(name: "Implant Test")
        var sketch = Sketch(name: "Plate", plane: .xy)
        sketch.addRectangle(from: Vec2(-10, -5), to: Vec2(10, 5))
        part.sketches.append(sketch)
        let feature = Feature(name: "Cascade Pad",
                              kind: .cascadePad(sketchID: sketch.id, length: 4))
        part.features.append(feature)
        return (part, feature)
    }

    func testRebuildUsesRegisteredEvaluator() throws {
        var seenLength: Double?
        DocumentEngine.cascadePadEvaluator = { _, length in
            seenLength = length
            let mesh = try Tessellation.box(width: 20, depth: 10, height: length)
            return (mesh, 20 * 10 * length)
        }
        let (part, feature) = partWithCascadePad()
        let result = DocumentEngine.rebuild(part: part)
        XCTAssertNil(result.firstError)
        XCTAssertEqual(seenLength, 4)
        XCTAssertEqual(result.mesh.triangleCount, 12)
        XCTAssertEqual(result.mesh.volume, 800, accuracy: 1e-6)
        let status = result.statuses.first { $0.featureID == feature.id }
        XCTAssertEqual(status?.ok, true)
        XCTAssertTrue(status?.message?.contains("800.00") ?? false,
                      "status carries the kernel volume readout: \(status?.message ?? "nil")")
    }

    func testRebuildWithoutEvaluatorFailsKN601() {
        DocumentEngine.cascadePadEvaluator = nil
        let (part, feature) = partWithCascadePad()
        let result = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(result.firstError?.code, "MCAD-KN601")
        let status = result.statuses.first { $0.featureID == feature.id }
        XCTAssertEqual(status?.ok, false)
        XCTAssertEqual(status?.errorCode, "MCAD-KN601")
    }

    func testCascadePadDocumentRoundTrip() throws {
        let (part, _) = partWithCascadePad()
        var doc = CADDocument(name: "Round Trip")
        doc.parts.append(part)
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(CADDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
        guard case .cascadePad(let sid, let len) = decoded.parts[0].features[0].kind else {
            return XCTFail("cascadePad kind did not survive the round trip")
        }
        XCTAssertEqual(sid, part.sketches[0].id)
        XCTAssertEqual(len, 4)
    }

    /// Documents written before the implant (no cascadePad anywhere)
    /// must still decode — the case was appended, never inserted.
    func testCascadePadInvalidLengthFailsFT402() {
        DocumentEngine.cascadePadEvaluator = { _, _ in (Mesh(), 0) }
        var part = Part(name: "Bad Length")
        var sketch = Sketch(name: "S", plane: .xy)
        sketch.addRectangle(from: Vec2(0, 0), to: Vec2(5, 5))
        part.sketches.append(sketch)
        part.features.append(Feature(name: "Bad", kind: .cascadePad(sketchID: sketch.id, length: 0)))
        let result = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(result.firstError?.code, "MCAD-FT402")
    }
}
