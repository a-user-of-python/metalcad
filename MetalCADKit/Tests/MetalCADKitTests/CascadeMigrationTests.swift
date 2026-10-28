import XCTest
@testable import MetalCADKit

/// Full-OCCT migration (2026-10-28): rebuild routing through a
/// registered `CascadeKernelProvider`. The stub below implements
/// the provider over the kit's own mesh kernel, so these tests
/// prove the WIRING (which path a feature takes, composition,
/// degradation in mixed chains, handle discipline) on any host.
/// The real provider's geometry is proven numerically on the
/// cascade-ios host harness (façade checks) and on device.
final class StubCascadeProvider: CascadeKernelProvider {
    private var registry: [Int: Mesh] = [:]
    private var nextID = 1
    private(set) var calls: [String] = []

    private func store(_ m: Mesh) -> Int {
        let id = nextID; nextID += 1
        registry[id] = m
        return id
    }
    private func mesh(_ id: Int) throws -> Mesh {
        guard let m = registry[id] else { throw CADError.kernelOperationFailed("stub: dead handle") }
        return m
    }

    func prismFromSketch(_ sketch: Sketch, offset: Double, along: Double) throws -> Int {
        calls.append("prismFromSketch")
        let (profiles, _) = try sketch.extractProfiles()
        var result = Mesh()
        for p in profiles {
            var m = try Tessellation.extrude(profile: p, plane: sketch.plane, length: along)
            m = m.translated(by: sketch.plane.normal * offset)
            result = result.triangleCount == 0 ? m : try CSG.union(result, m)
        }
        return store(result)
    }

    func prismFromProfile(_ points: [Vec2], plane: Plane3, offset: Double, along: Double) throws -> Int {
        calls.append("prismFromProfile")
        var m = try Tessellation.extrude(profile: Profile(outer: points, holes: []), plane: plane, length: along)
        m = m.translated(by: plane.normal * offset)
        return store(m)
    }

    func revolveFromSketch(_ sketch: Sketch, axisPoint: Vec2, axisDirection: Vec2, angleDegrees: Double) throws -> Int {
        calls.append("revolveFromSketch")
        let (profiles, _) = try sketch.extractProfiles()
        guard let p = profiles.first else { throw CADError.padNoProfile }
        return store(try Tessellation.revolve(profile: p, plane: sketch.plane,
                                              axisPoint: axisPoint, axisDirection: axisDirection,
                                              angleDegrees: angleDegrees))
    }

    func primitive(kind: PrimitiveKind, params p: [String: Double]) throws -> Int {
        calls.append("primitive")
        switch kind {
        case .box: return store(try Tessellation.box(width: p["width"] ?? 10, depth: p["depth"] ?? 10, height: p["height"] ?? 10))
        case .cylinder: return store(try Tessellation.cylinder(radius: (p["diameter"] ?? 10) / 2, height: p["height"] ?? 10))
        case .sphere: return store(try Tessellation.sphere(radius: (p["diameter"] ?? 10) / 2))
        case .cone: return store(try Tessellation.cone(radius: (p["diameter"] ?? 10) / 2, height: p["height"] ?? 10))
        case .torus: return store(try Tessellation.torus(ringRadius: p["ringRadius"] ?? 15, tubeRadius: p["tubeRadius"] ?? 5))
        }
    }

    func loft(profiles: [(plane: Plane3, points: [Vec2])], ruled: Bool) throws -> Int {
        calls.append("loft")
        guard profiles.count == 2 else { throw CADError.kernelOperationFailed("stub loft: 2 profiles") }
        let a = profiles[0].points.map { profiles[0].plane.toWorld($0) }
        let b = profiles[1].points.map { profiles[1].plane.toWorld($0) }
        return store(try LoftTessellator.loft(loopA: a, loopB: b))
    }

    func sweep(profilePlane: Plane3, profile: [Vec2], path: [Vec3]) throws -> Int {
        calls.append("sweep")
        let loop = profile.map { profilePlane.toWorld($0) }
        return store(try SweepTessellator.sweep(profileLoop: loop, profilePlane: profilePlane, path: path))
    }

    func unite(_ a: Int, _ b: Int) throws -> Int { calls.append("unite"); return store(try CSG.union(try mesh(a), try mesh(b))) }
    func subtract(_ a: Int, _ b: Int) throws -> Int { calls.append("subtract"); return store(try CSG.subtract(try mesh(a), try mesh(b))) }
    func intersect(_ a: Int, _ b: Int) throws -> Int { calls.append("intersect"); return store(try CSG.intersect(try mesh(a), try mesh(b))) }

    func fillet(_ s: Int, radius: Double, edgeIndices: [Int]?) throws -> Int {
        calls.append("fillet")
        let m = try mesh(s)
        if let idx = edgeIndices {
            let infos = try edgeInfos(s)
            let mids = idx.compactMap { $0 >= 0 && $0 < infos.count ? infos[$0].midPoint : nil }
            return store(try EdgeFinisher.fillet(body: m, radius: radius, onlyMidpoints: mids))
        }
        return store(try EdgeFinisher.fillet(body: m, radius: radius))
    }

    func chamfer(_ s: Int, distance: Double, edgeIndices: [Int]?) throws -> Int {
        calls.append("chamfer")
        let m = try mesh(s)
        if let idx = edgeIndices {
            let infos = try edgeInfos(s)
            let mids = idx.compactMap { $0 >= 0 && $0 < infos.count ? infos[$0].midPoint : nil }
            return store(try EdgeFinisher.chamfer(body: m, distance: distance, onlyMidpoints: mids))
        }
        return store(try EdgeFinisher.chamfer(body: m, distance: distance))
    }

    func shell(_ s: Int, thickness: Double) throws -> Int {
        calls.append("shell")
        return store(try EdgeFinisher.shell(body: try mesh(s), thickness: thickness))
    }

    func draft(_ s: Int, angleDegrees: Double, pullAxis: Int) throws -> Int {
        calls.append("draft")
        return store(try DocumentEngine.draftMesh(body: try mesh(s), angleDegrees: angleDegrees, pullAxis: pullAxis))
    }

    func transform(_ s: Int, matrix m: [Double]) throws -> Int {
        calls.append("transform")
        let src = try mesh(s)
        let out = src.vertices.map { v in
            Vec3(m[0] * v.x + m[1] * v.y + m[2] * v.z + m[3],
                 m[4] * v.x + m[5] * v.y + m[6] * v.z + m[7],
                 m[8] * v.x + m[9] * v.y + m[10] * v.z + m[11])
        }
        return store(Mesh(vertices: out, indices: src.indices))
    }

    func volume(_ s: Int) throws -> Double { try mesh(s).volume }
    func bounds(_ s: Int) throws -> (min: Vec3, max: Vec3) {
        let b = try mesh(s).bounds
        return (b.min, b.max)
    }
    func census(_ s: Int) throws -> (faces: Int, edges: Int, vertices: Int) {
        let m = try mesh(s)
        return (m.triangleCount, 0, m.vertices.count)
    }
    func faceInfo(_ s: Int, index: Int) throws -> (area: Double, center: Vec3, normal: Vec3, isPlanar: Bool) {
        throw CADError.kernelOperationFailed("stub: no face info")
    }
    func edgeInfos(_ s: Int) throws -> [CascadeEdgeInfo] {
        let m = try mesh(s)
        return SolidEdgeExtractor.edges(of: m).map {
            CascadeEdgeInfo(curveType: 0, length: $0.start.distance(to: $0.end),
                            start: $0.start, end: $0.end, center: .zero, radius: 0)
        }
    }
    func tessellate(_ s: Int, deflection: Double) throws -> Mesh { try mesh(s) }
    func exportSTEP(_ s: Int, path: String) throws { throw CADError.kernelOperationFailed("stub: no STEP") }
    func importSTEP(path: String) throws -> Int { throw CADError.kernelOperationFailed("stub: no STEP") }
    func release(_ s: Int) { registry[s] = nil }
}

final class CascadeMigrationTests: XCTestCase {

    override func tearDown() {
        DocumentEngine.cascadeProvider = nil
        DocumentEngine.cascadePadEvaluator = nil
        super.tearDown()
    }

    private func plateSketch(z: Double = 0) -> Sketch {
        var sketch = Sketch(name: "Plate", plane: Plane3(origin: Vec3(0, 0, z), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        sketch.addRectangle(from: Vec2(-10, -5), to: Vec2(10, 5))
        return sketch
    }

    /// Stage 1: cascade pocket cuts a cascade pad exactly, through
    /// the provider (prism + subtract), with the kernel volume in
    /// the feature status.
    func testCascadePocketCutsCascadePadThroughProvider() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Pocket Test")
        let plate = plateSketch()
        part.sketches.append(plate)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: plate.id, length: 4)))
        var pocketSketch = Sketch(name: "Pocket", plane: Plane3(origin: Vec3(0, 0, 4), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        pocketSketch.addRectangle(from: Vec2(-5, -2), to: Vec2(5, 2))
        part.sketches.append(pocketSketch)
        let pocket = Feature(name: "Pocket", kind: .cascadePocket(sketchID: pocketSketch.id, depth: 2))
        part.features.append(pocket)

        let result = DocumentEngine.rebuild(part: part)
        XCTAssertNil(result.firstError)
        XCTAssertEqual(result.mesh.volume, 800 - 10 * 4 * 2, accuracy: 1.0)
        XCTAssertTrue(stub.calls.contains("subtract"), "pocket composed via engine subtract: \(stub.calls)")
        let status = result.statuses.first { $0.featureID == pocket.id }
        XCTAssertEqual(status?.ok, true)
        XCTAssertTrue(status?.message?.contains("720") ?? false,
                      "status carries the kernel volume: \(status?.message ?? "nil")")
    }

    /// Stage 1: cascade pocket with no provider fails KN601, never
    /// silently.
    func testCascadePocketWithoutProviderFailsKN601() {
        DocumentEngine.cascadeProvider = nil
        var part = Part(name: "No Kernel")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pocket", kind: .cascadePocket(sketchID: s.id, depth: 1)))
        let result = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(result.firstError?.code, "MCAD-KN601")
    }

    /// Stage 1: a cascade pocket as the FIRST feature has nothing
    /// to cut — FT406, like the legacy pocket.
    func testCascadePocketOnEmptyBodyFailsFT406() {
        DocumentEngine.cascadeProvider = StubCascadeProvider()
        var part = Part(name: "Empty")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pocket", kind: .cascadePocket(sketchID: s.id, depth: 1)))
        let result = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(result.firstError?.code, "MCAD-FT406")
    }

    /// Stage 1: mixed chains degrade honestly — a legacy fillet
    /// after an engine pad materialises the body and still applies.
    func testLegacyFeatureAfterCascadePadMaterializes() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Mixed")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Fillet", kind: .fillet(radius: 1)))
        let result = DocumentEngine.rebuild(part: part)
        XCTAssertNil(result.firstError)
        XCTAssertTrue(result.statuses.allSatisfy { $0.ok })
        XCTAssertLessThan(result.mesh.volume, 800)
        XCTAssertGreaterThan(result.mesh.volume, 700)
    }

    /// Stage 1: cascade pocket documents round-trip (the kind was
    /// appended, never inserted).
    func testCascadePocketDocumentRoundTrip() throws {
        var part = Part(name: "RT")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pocket", kind: .cascadePocket(sketchID: s.id, depth: 2.5)))
        var doc = CADDocument(name: "RT")
        doc.parts.append(part)
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(CADDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
        guard case .cascadePocket(let sid, let depth) = decoded.parts[0].features[0].kind else {
            return XCTFail("cascadePocket kind did not survive the round trip")
        }
        XCTAssertEqual(sid, s.id)
        XCTAssertEqual(depth, 2.5)
    }
}
