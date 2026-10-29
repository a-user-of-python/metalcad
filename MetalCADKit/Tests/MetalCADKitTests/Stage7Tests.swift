import XCTest
@testable import MetalCADKit

/// Stage 7 (the final migration stage): STEP export/import
/// through the engine, mass from exact engine volume, the finer
/// preview tessellation, and imported per-face colours (7b).
/// These tests prove the kit wiring against the stub provider
/// (which stands in for OCCT with the kit's own mesh kernel); the
/// real engine's numbers — multi-body compound round-trip, XDE
/// colour round-trip — are proven on the cascade-ios host harness
/// (§15) and on device.
final class Stage7Tests: XCTestCase {

    override func tearDown() {
        DocumentEngine.cascadeProvider = nil
        DocumentEngine.cascadePadEvaluator = nil
        super.tearDown()
    }

    private func plateSketch(z: Double = 0, w: Double = 20, d: Double = 10) -> Sketch {
        var sketch = Sketch(name: "Plate", plane: Plane3(origin: Vec3(0, 0, z), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        sketch.addRectangle(from: Vec2(-w / 2, -d / 2), to: Vec2(w / 2, d / 2))
        return sketch
    }

    private func tempURL(_ name: String = "stage7-test.step") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    // MARK: STEP export

    /// A pad part exports through the XDE path: one body, the
    /// part's material colour, the part name as the document
    /// label, and the engine's own volume in the result.
    func testExportSTEPViaXDE() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Bracket")
        part.materialID = "steel-mild"
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 4)))
        let url = tempURL()
        let result = try DocumentEngine.exportSTEP(part: part, to: url)
        XCTAssertTrue(result.carriesColor)
        XCTAssertEqual(result.bodyVolumes.count, 1)
        XCTAssertEqual(result.bodyVolumes[0], 800, accuracy: 1.0)
        XCTAssertEqual(stub.xdeExports.count, 1)
        XCTAssertEqual(stub.xdeExports[0].ids.count, 1)
        XCTAssertEqual(stub.xdeExports[0].name, "Bracket")
        let steel = MaterialLibrary.byID("steel-mild")!
        XCTAssertEqual(stub.xdeExports[0].colors.count, 1)
        XCTAssertEqual(stub.xdeExports[0].colors[0].red, steel.red)
        XCTAssertEqual(stub.xdeExports[0].colors[0].green, steel.green)
        XCTAssertEqual(stub.xdeExports[0].colors[0].blue, steel.blue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // Export releases its handles: nothing leaks but the
        // snapshot-free evaluation leaves the registry empty.
        XCTAssertTrue(stub.liveHandles.isEmpty, "export must release every handle: \(stub.liveHandles)")
    }

    /// A two-body part exports BOTH bodies into the one file.
    func testExportSTEPMultiBody() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Two Bodies")
        let a = plateSketch()
        part.sketches.append(a)
        part.features.append(Feature(name: "Base", kind: .pad(sketchID: a.id, length: 4)))
        let b = plateSketch(z: 10)
        part.sketches.append(b)
        part.features.append(Feature(name: "Second", kind: .extrude2(
            sketchID: b.id, distance: 2, taperDegrees: 0, mode: .one,
            operation: .newBody, end: .dimension)))
        let result = try DocumentEngine.exportSTEP(part: part, to: tempURL())
        XCTAssertEqual(result.bodyVolumes.count, 2)
        XCTAssertEqual(result.bodyVolumes[0], 800, accuracy: 1.0)
        XCTAssertEqual(result.bodyVolumes[1], 400, accuracy: 1.0)
        XCTAssertEqual(stub.xdeExports[0].ids.count, 2)
        XCTAssertEqual(stub.xdeExports[0].colors.count, 2)
    }

    /// No provider → KN601, never a silent mesh STEP.
    func testExportSTEPNoProviderFailsKN601() {
        DocumentEngine.cascadeProvider = nil
        var part = Part(name: "No Kernel")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 4)))
        XCTAssertThrowsError(try DocumentEngine.exportSTEP(part: part, to: tempURL())) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-KN601")
        }
    }

    /// An empty part has no solid to write → IO706 in plain words.
    func testExportSTEPEmptyPartFailsIO706() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        let part = Part(name: "Empty")
        XCTAssertThrowsError(try DocumentEngine.exportSTEP(part: part, to: tempURL())) { e in
            XCTAssertEqual((e as? CADError)?.code, "MCAD-IO706")
        }
    }

    /// A part whose rebuild fails exports nothing: the failing
    /// feature's own error surfaces, not a generic write error.
    func testExportSTEPFailingFeatureSurfacesItsError() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Broken")
        part.features.append(Feature(name: "Cut", kind: .booleanCutPlaceholder))
        XCTAssertThrowsError(try DocumentEngine.exportSTEP(part: part, to: tempURL())) { e in
            XCTAssertEqual((e as? CADError)?.code, CADError.booleanFailed("x").code)
        }
        XCTAssertTrue(stub.xdeExports.isEmpty && stub.bodiesExports.isEmpty)
    }

    /// When the XDE write is refused, the plain compound writer
    /// is the fallback — an honest STEP without colour, flagged
    /// as such in the result.
    func testExportSTEPXDEFallsBackToPlain() throws {
        let stub = StubCascadeProvider()
        stub.failXDE = true
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Fallback")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 4)))
        let result = try DocumentEngine.exportSTEP(part: part, to: tempURL())
        XCTAssertFalse(result.carriesColor)
        XCTAssertEqual(stub.bodiesExports.count, 1)
        XCTAssertEqual(result.bodyVolumes[0], 800, accuracy: 1.0)
    }

    // MARK: STEP import

    /// An imported STEP as the first feature becomes the body;
    /// its status names the file and the SOLID COUNT the façade
    /// reported (multi-solid files arrive as one compound body —
    /// the count is surfaced, never silently dropped).
    func testImportedSTEPBaseFeature() {
        let stub = StubCascadeProvider()
        stub.stubImportSolidCount = 3
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Imported")
        let f = Feature(name: "Import", kind: .importedSTEP(name: "housing.step", stepData: Data("fake step".utf8)))
        part.features.append(f)
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 1000, accuracy: 0.01)  // stub's 10 mm cube
        XCTAssertEqual(r.bodies.count, 1)
        let status = r.statuses.first { $0.featureID == f.id }
        XCTAssertEqual(status?.ok, true)
        XCTAssertTrue(status?.message?.contains("housing.step") ?? false,
                      "status names the file: \(status?.message ?? "nil")")
        XCTAssertTrue(status?.message?.contains("3 solids") ?? false,
                      "status surfaces the solid count: \(status?.message ?? "nil")")
    }

    /// A downstream engine feature composes onto the import
    /// exactly as onto a built body (pocket cuts it).
    func testImportedSTEPThenPocketCuts() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Imported + Pocket")
        part.features.append(Feature(name: "Import", kind: .importedSTEP(name: "cube.step", stepData: Data("x".utf8))))
        var pocketSketch = Sketch(name: "Pocket", plane: Plane3(origin: Vec3(0, 0, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        pocketSketch.addRectangle(from: Vec2(-2, -2), to: Vec2(2, 2))
        part.sketches.append(pocketSketch)
        part.features.append(Feature(name: "Pocket", kind: .cascadePocket(sketchID: pocketSketch.id, depth: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 1000 - 4 * 4 * 2, accuracy: 1.0)
        XCTAssertTrue(stub.calls.contains("subtract"), "pocket cut the import via the engine: \(stub.calls)")
    }

    /// A second import finishes the current body and starts a
    /// new one — two bodies, both in the output.
    func testImportedSTEPSecondImportStartsNewBody() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Two Imports")
        part.features.append(Feature(name: "A", kind: .importedSTEP(name: "a.step", stepData: Data("a".utf8))))
        part.features.append(Feature(name: "B", kind: .importedSTEP(name: "b.step", stepData: Data("b".utf8))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.bodies.count, 2)
        XCTAssertEqual(r.mesh.volume, 2000, accuracy: 0.01)
    }

    /// Engine-only: with no provider the import fails KN601.
    func testImportedSTEPNoProviderFailsKN601() {
        DocumentEngine.cascadeProvider = nil
        var part = Part(name: "No Kernel")
        part.features.append(Feature(name: "Import", kind: .importedSTEP(name: "a.step", stepData: Data("a".utf8))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-KN601")
    }

    /// Over the size cap → IO702 before the engine is even asked.
    func testImportedSTEPTooLargeFailsIO702() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Huge")
        let big = Data(count: DocumentEngine.maxImportedSTEPBytes + 1)
        part.features.append(Feature(name: "Import", kind: .importedSTEP(name: "huge.step", stepData: big)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-IO702")
        XCTAssertFalse(stub.calls.contains("importSTEP"))
    }

    /// A file the reader rejects → IO702 from the provider.
    func testImportedSTEPUnreadableFailsIO702() {
        let stub = StubCascadeProvider()
        stub.failImport = true
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Bad File")
        part.features.append(Feature(name: "Import", kind: .importedSTEP(name: "bad.step", stepData: Data("junk".utf8))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-IO702")
    }

    /// Format discipline: a document WITH an importedSTEP
    /// round-trips through the JSON unchanged (bytes intact), and
    /// a pre-Stage-7 document (no such feature) decodes and
    /// rebuilds exactly as before.
    func testImportedSTEPDocumentRoundTripAndLegacyDecode() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var doc = CADDocument(name: "Round Trip")
        var part = Part(name: "P")
        let payload = Data("STEP bytes here".utf8)
        part.features.append(Feature(name: "Import", kind: .importedSTEP(name: "a.step", stepData: payload)))
        doc.parts.append(part)
        let url = tempURL("roundtrip.json")
        try IOService.saveJSON(doc, to: url)
        let (back, _) = try IOService.loadJSON(from: url)
        XCTAssertEqual(back, doc)
        guard case .importedSTEP(let name, let data) = back.parts[0].features[0].kind else {
            return XCTFail("importedSTEP did not survive the round trip")
        }
        XCTAssertEqual(name, "a.step")
        XCTAssertEqual(data, payload)

        // A document written before Stage 7 (pad only) still
        // decodes — the appended enum case changed nothing old.
        var old = CADDocument(name: "Old")
        var oldPart = Part(name: "plate")
        var s = Sketch(name: "base")
        s.addRectangle(from: Vec2(-20, -20), to: Vec2(20, 20))
        oldPart.sketches.append(s)
        oldPart.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 10)))
        old.parts.append(oldPart)
        let oldURL = tempURL("old.json")
        try IOService.saveJSON(old, to: oldURL)
        let (oldBack, _) = try IOService.loadJSON(from: oldURL)
        let r = DocumentEngine.rebuild(part: oldBack.parts[0])
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 16000, accuracy: 1.0)
    }

    // MARK: Mass from the engine

    /// The headline Stage 7 mass proof: a steel cube's mass is
    /// the EXACT engine volume × 7.85 g/cm³. The imported body is
    /// a 10 mm cube = exactly 1 cm³ → exactly 7.85 g.
    func testMassSteelCubeExact() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Steel Cube")
        part.materialID = "steel-mild"  // 7.85 g/cm^3
        part.features.append(Feature(name: "Import", kind: .importedSTEP(name: "cube.step", stepData: Data("x".utf8))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.massGrams!, 7.85, accuracy: 1e-6)
    }

    /// Mass comes from `provider.volume`, not the display mesh:
    /// with the stub's volumes scaled 1.5×, the mass scales 1.5×
    /// while the mesh (and its volume) stays the same.
    func testMassUsesEngineVolumeNotMesh() {
        var part = Part(name: "Sphere")
        part.features.append(Feature(name: "Ball", kind: .primitive(kind: .sphere, params: ["diameter": 20])))
        let meshOnly = DocumentEngine.rebuild(part: part)  // no provider: legacy mass
        let stub = StubCascadeProvider()
        stub.volumeScale = 1.5
        DocumentEngine.cascadeProvider = stub
        let engine = DocumentEngine.rebuild(part: part)
        XCTAssertNil(engine.firstError)
        XCTAssertEqual(engine.mesh.volume, meshOnly.mesh.volume, accuracy: 0.01)
        XCTAssertEqual(engine.massGrams!, meshOnly.massGrams! * 1.5, accuracy: 0.01)
    }

    // MARK: Imported colours (7b)

    private func sixColors() -> [CensusFaceColor] {
        (0..<6).map { i in
            CensusFaceColor(red: Double(i) / 5, green: 1 - Double(i) / 5, blue: 0.25, hasColor: true)
        }
    }

    /// An imported body's colours reach the rebuild result mapped
    /// to its triangles, in census order.
    func testImportedColorsReachResult() {
        let stub = StubCascadeProvider()
        stub.stubImportColors = sixColors()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Painted")
        part.features.append(Feature(name: "Import", kind: .importedSTEP(name: "painted.step", stepData: Data("x".utf8))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.bodyFaceColors.count, 1)
        let entry = r.bodyFaceColors[0]
        XCTAssertEqual(entry.bodyIndex, 0)
        XCTAssertEqual(entry.faceColors, sixColors())
        XCTAssertEqual(entry.faceOfTriangle.count, r.bodies[0].triangleCount)
    }

    /// Colours belong to the imported handle: once a feature
    /// modifies the body (the handle is replaced), the colours
    /// are retired — the body renders in the part material.
    func testImportedColorsRetiredAfterModification() {
        let stub = StubCascadeProvider()
        stub.stubImportColors = sixColors()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Painted Then Padded")
        part.features.append(Feature(name: "Import", kind: .importedSTEP(name: "painted.step", stepData: Data("x".utf8))))
        let top = plateSketch(z: 10, w: 4, d: 4)
        part.sketches.append(top)
        part.features.append(Feature(name: "Boss", kind: .pad(sketchID: top.id, length: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(r.bodyFaceColors.isEmpty, "modified body must not keep the import's colours")
    }

    /// A completed imported body (finished by a second import)
    /// keeps its colours too — both bodies coloured.
    func testImportedColorsOnCompletedBody() {
        let stub = StubCascadeProvider()
        stub.stubImportColors = sixColors()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Two Painted")
        part.features.append(Feature(name: "A", kind: .importedSTEP(name: "a.step", stepData: Data("a".utf8))))
        part.features.append(Feature(name: "B", kind: .importedSTEP(name: "b.step", stepData: Data("b".utf8))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.bodyFaceColors.map { $0.bodyIndex }, [0, 1])
    }

    // MARK: Preview tessellation

    /// Sean's v1 fix item 6, pinned: the display tessellation is
    /// the fine 0.02 mm deflection (the preview smooth-shades
    /// over it in the renderer; triangles belong to exports).
    func testPreviewDeflectionIsFine() {
        XCTAssertEqual(DocumentEngine.previewDeflection, 0.02, accuracy: 1e-12)
    }
}
