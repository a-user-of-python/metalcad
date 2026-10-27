import XCTest
@testable import MetalCADKit

/// 50 checks: document JSON save/load with version guards, and binary STL
/// write/read round-trips.
final class IOTests: XCTestCase {

    func sampleDoc() -> CADDocument {
        var doc = CADDocument(name: "Bracket")
        var part = Part(name: "body")
        var s = Sketch(name: "base")
        s.addRectangle(from: Vec2(0, 0), to: Vec2(30, 20))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 8)))
        doc.parts.append(part)
        doc.parameters["width"] = 30
        return doc
    }

    func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    func testJSONRoundTrip() throws {
        let url = tempURL("doc.json")
        let doc = sampleDoc()
        try IOService.saveJSON(doc, to: url)
        let (back, warnings) = try IOService.loadJSON(from: url)
        XCTAssertEqual(back, doc)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testSavedFileExists() throws {
        let url = tempURL("doc.json")
        try IOService.saveJSON(sampleDoc(), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 50)
    }

    func testLoadMissingThrowsDC101() {
        XCTAssertThrowsError(try IOService.loadJSON(from: tempURL("nope.json"))) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-DC101")
        }
    }

    func testLoadCorruptThrowsDC102() {
        XCTAssertThrowsError(try IOService.loadJSON(data: Data("{ not json".utf8))) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-DC102")
        }
        XCTAssertThrowsError(try IOService.loadJSON(data: Data("{\"hello\": 1}".utf8))) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-DC102")
        }
    }

    func testLoadTooNewThrowsDC103() throws {
        var doc = sampleDoc()
        doc.formatVersion = 99
        let data = try JSONEncoder().encode(doc)
        XCTAssertThrowsError(try IOService.loadJSON(data: data)) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-DC103")
        }
    }

    func testFormatVersionIsOne() {
        XCTAssertEqual(CADDocument.currentFormatVersion, 1)
        XCTAssertEqual(sampleDoc().formatVersion, 1)
    }

    func testSTLSizes() throws {
        let box = try Tessellation.box(width: 10, depth: 10, height: 10)
        let url = tempURL("box.stl")
        let warnings = try IOService.writeSTL(box, to: url)
        XCTAssertTrue(warnings.isEmpty)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 84 + 12 * 50)
    }

    func testSTLRoundTripBox() throws {
        let box = try Tessellation.box(width: 10, depth: 20, height: 30)
        let url = tempURL("box.stl")
        try IOService.writeSTL(box, to: url)
        let back = try IOService.readSTL(data: Data(contentsOf: url))
        XCTAssertEqual(back.triangleCount, 12)
        XCTAssertEqual(back.volume, 6000, accuracy: 1)
        XCTAssertTrue(back.isWatertight)
        XCTAssertEqual(back.bounds.size.x, 10, accuracy: 0.01)
        XCTAssertEqual(back.bounds.size.z, 30, accuracy: 0.01)
    }

    func testSTLRoundTripCylinder() throws {
        let cyl = try Tessellation.cylinder(radius: 5, height: 12, segments: 32)
        let url = tempURL("cyl.stl")
        try IOService.writeSTL(cyl, to: url)
        let back = try IOService.readSTL(data: Data(contentsOf: url))
        XCTAssertEqual(back.triangleCount, cyl.triangleCount)
        XCTAssertEqual(back.volume, cyl.volume, accuracy: 2)
    }

    func testSTLWatertightWarningForOpenMesh() throws {
        var m = Mesh()
        m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)]
        m.indices = [0, 1, 2]
        let warnings = try IOService.writeSTL(m, to: tempURL("open.stl"))
        XCTAssertEqual(warnings.first?.code, "MCAD-IO704")
        if case .exportNotWatertight(let n) = warnings.first! {
            XCTAssertEqual(n, 3)
        } else { XCTFail("wrong warning") }
    }

    func testSTLTruncatedThrowsIO702() {
        XCTAssertThrowsError(try IOService.readSTL(data: Data(count: 40))) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-IO702")
        }
        var header = Data(count: 80)
        var count = UInt32(100).littleEndian
        header.append(Data(bytes: &count, count: 4))
        XCTAssertThrowsError(try IOService.readSTL(data: header)) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-IO702")
        }
    }

    func testSTLNaNRejected() throws {
        var m = Mesh()
        m.vertices = [Vec3(.nan, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)]
        m.indices = [0, 1, 2]
        XCTAssertThrowsError(try IOService.writeSTL(m, to: tempURL("nan.stl"))) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-KN603")
        }
    }

    func testDocWithThreadFeatureRoundTrips() throws {
        var doc = CADDocument(name: "Bolt")
        var part = Part(name: "bolt")
        let spec = try ThreadSpec.preset("M8")
        part.features.append(Feature(name: "Thread", kind: .threadShaft(spec: spec)))
        doc.parts.append(part)
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(CADDocument.self, from: data)
        XCTAssertEqual(back, doc)
        let r = DocumentEngine.rebuild(part: back.parts[0])
        XCTAssertNil(r.firstError)
        XCTAssertGreaterThan(r.mesh.triangleCount, 100)
    }

    func testEmptyMeshSTL() throws {
        let url = tempURL("empty.stl")
        let warnings = try IOService.writeSTL(Mesh(), to: url)
        XCTAssertEqual(warnings.first?.code, "MCAD-IO704")
        let back = try IOService.readSTL(data: Data(contentsOf: url))
        XCTAssertEqual(back.triangleCount, 0)
    }
}

// MARK: Top-up checks

extension IOTests {
    func testSTLVertexDedupe() throws {
        let box = try Tessellation.box(width: 10, depth: 10, height: 10)
        let url = tempURL("box.stl")
        try IOService.writeSTL(box, to: url)
        let back = try IOService.readSTL(data: Data(contentsOf: url))
        XCTAssertEqual(back.vertices.count, 8)  // a box has 8 corners
        XCTAssertEqual(back.indices.count, 36)
    }

    func testSTLSphereRoundTrip() throws {
        let sph = try Tessellation.sphere(radius: 7, segments: 24, rings: 16)
        let url = tempURL("sph.stl")
        try IOService.writeSTL(sph, to: url)
        let back = try IOService.readSTL(data: Data(contentsOf: url))
        XCTAssertEqual(back.triangleCount, sph.triangleCount)
        XCTAssertEqual(back.volume, sph.volume, accuracy: 5)
        XCTAssertEqual(back.bounds.size.z, 14, accuracy: 0.5)
    }

    func testWriteToBadPathThrowsIO705orSnapshot() {
        var m = Mesh()
        m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)]
        m.indices = [0, 1, 2]
        let bad = URL(fileURLWithPath: "/nonexistent-dir-xyz/file.stl")
        XCTAssertThrowsError(try IOService.writeSTL(m, to: bad)) {
            XCTAssertEqual(($0 as? CADError)?.code, "MCAD-IO705")
        }
    }

    func testParametersRoundTrip() throws {
        var doc = sampleDoc()
        doc.parameters = ["width": 30, "height": 12.5, "angle": 45]
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(CADDocument.self, from: data)
        XCTAssertEqual(back.parameters, doc.parameters)
        XCTAssertEqual(back.parameters["height"], 12.5)
    }

    func testEmptyDocRoundTrips() throws {
        let doc = CADDocument(name: "Empty")
        let url = tempURL("empty.json")
        try IOService.saveJSON(doc, to: url)
        let (back, warnings) = try IOService.loadJSON(from: url)
        XCTAssertEqual(back.name, "Empty")
        XCTAssertTrue(back.parts.isEmpty)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testSavedJSONIsHumanReadable() throws {
        let url = tempURL("doc.json")
        try IOService.saveJSON(sampleDoc(), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Bracket"))
        XCTAssertTrue(text.contains("formatVersion"))
    }

    func testMultiplePartsRoundTrip() throws {
        var doc = sampleDoc()
        var p2 = Part(name: "second")
        p2.features.append(Feature(name: "Ball", kind: .primitive(kind: .sphere, params: ["diameter": 12])))
        doc.parts.append(p2)
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(CADDocument.self, from: data)
        XCTAssertEqual(back.parts.count, 2)
        XCTAssertEqual(back.parts[1].name, "second")
        XCTAssertEqual(back, doc)
    }

    func testSTLHeaderIs84BytesPrefix() throws {
        let box = try Tessellation.box(width: 1, depth: 2, height: 3)
        let url = tempURL("h.stl")
        try IOService.writeSTL(box, to: url)
        let data = try Data(contentsOf: url)
        // 80-byte header + 4-byte count; count field must read 12.
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        XCTAssertEqual(count, 12)
    }
}
