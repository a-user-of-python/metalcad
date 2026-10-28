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
    /// (offset, along) spans seen by prismFromSketch, in call order.
    private(set) var prismSpans: [(offset: Double, along: Double)] = []
    /// (angleDegrees, pullDirection) seen by draftGeneral.
    private(set) var draftGeneralCalls: [(angle: Double, pull: Vec3, neutral: Vec3)] = []

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
        prismSpans.append((offset, along))
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

    func revolveFromProfile(_ points: [Vec2], plane: Plane3, axisPoint: Vec2,
                            axisDirection: Vec2, angleDegrees: Double) throws -> Int {
        calls.append("revolveFromProfile")
        return store(try Tessellation.revolve(profile: Profile(outer: points, holes: []), plane: plane,
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

    func draftGeneral(_ s: Int, pullDirection: Vec3, angleDegrees: Double, neutralPoint: Vec3) throws -> Int {
        calls.append("draftGeneral")
        draftGeneralCalls.append((angleDegrees, pullDirection, neutralPoint))
        // Mesh-level approximation of the OCCT draft for wiring
        // tests: morph each vertex away from the neutral plane —
        // radial component (relative to the neutral point, pull
        // direction removed) scaled by -tan(angle) x height.
        let src = try mesh(s)
        let pull = pullDirection.normalized
        let t = tan(angleDegrees * Double.pi / 180)
        let out = src.vertices.map { v -> Vec3 in
            let rel = v - neutralPoint
            let h = rel.dot(pull)
            let radial = rel - pull * h
            guard radial.length > 1e-9 else { return v }
            return v - radial.normalized * (t * h)
        }
        return store(Mesh(vertices: out, indices: src.indices))
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

    // MARK: - Stage 2 (1.17): pad / pocket / revolve / primitive /
    // extrude / extrude2 re-pointed at the engine

    private func pocketSketch(z: Double = 4) -> Sketch {
        var sketch = Sketch(name: "Pocket", plane: Plane3(origin: Vec3(0, 0, z), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        sketch.addRectangle(from: Vec2(-5, -2), to: Vec2(5, 2))
        return sketch
    }

    /// Stage 2: .pad builds through the provider (prism + exact
    /// join) and measures the same as the legacy rebuild.
    func testPadRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Pad")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 4)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 800, accuracy: 1.0)
        XCTAssertTrue(stub.calls.contains("prismFromSketch"), "pad via engine prism: \(stub.calls)")
        XCTAssertEqual(stub.prismSpans.first?.offset, 0)
        XCTAssertEqual(stub.prismSpans.first?.along, 4)
        // Parity: the legacy rebuild of the same part.
        DocumentEngine.cascadeProvider = nil
        let legacy = DocumentEngine.rebuild(part: part)
        XCTAssertNil(legacy.firstError)
        XCTAssertEqual(legacy.mesh.volume, r.mesh.volume, accuracy: 0.01)
    }

    /// Stage 2: .pocket cuts through the provider with the legacy
    /// tool span (depth below the plane to 1 mm above it).
    func testPocketRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Pocket")
        let plate = plateSketch()
        let pocket = pocketSketch()
        part.sketches += [plate, pocket]
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: plate.id, length: 4)))
        part.features.append(Feature(name: "Pocket", kind: .pocket(sketchID: pocket.id, depth: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 800 - 80, accuracy: 1.0)
        XCTAssertTrue(stub.calls.contains("subtract"), "pocket composed via engine subtract: \(stub.calls)")
        XCTAssertEqual(stub.prismSpans.last?.offset, -2)
        XCTAssertEqual(stub.prismSpans.last?.along, 3)
    }

    /// Stage 2: .revolve builds through the provider and measures
    /// the same cylinder as the legacy path.
    func testRevolveRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Shaft")
        var s = Sketch(name: "s")
        let ids = s.addRectangle(from: Vec2(0, 0), to: Vec2(5, 20))
        part.sketches.append(s)
        part.features.append(Feature(name: "Rev", kind: .revolve(sketchID: s.id, axisEntityID: ids[3], angleDegrees: 360)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("revolveFromSketch"), "revolve via engine: \(stub.calls)")
        XCTAssertEqual(r.mesh.volume, Double.pi * 25 * 20, accuracy: 60)
    }

    /// Stage 2: revolve validation is unchanged on the engine
    /// path — a profile crossing the axis is still FT404.
    func testRevolveCrossingAxisStillFT404WithProvider() {
        DocumentEngine.cascadeProvider = StubCascadeProvider()
        var part = Part(name: "Bad")
        var s = Sketch(name: "s")
        s.addRectangle(from: Vec2(-5, 0), to: Vec2(5, 10))
        let axis = s.addLine(Vec2(0, -5), Vec2(0, 15), construction: true)
        part.sketches.append(s)
        part.features.append(Feature(name: "Rev", kind: .revolve(sketchID: s.id, axisEntityID: axis, angleDegrees: 360)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT404")
    }

    /// Stage 2: .primitive builds through the provider.
    func testPrimitiveRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Prim")
        part.features.append(Feature(name: "Box", kind: .primitive(kind: .box, params: ["width": 10, "depth": 6, "height": 3])))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 180, accuracy: 0.5)
        XCTAssertTrue(stub.calls.contains("primitive"), "primitive via engine: \(stub.calls)")
    }

    /// Stage 2: extrude spans mirror the legacy construction —
    /// symmetric centres on the plane; two-sided untapered is ONE
    /// prism across the whole span.
    func testExtrudeSpans() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Spans")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Sym", kind: .extrude(sketchID: s.id, distance: 6, taperDegrees: 0, mode: .symmetric)))
        var r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(stub.prismSpans.count, 1)
        XCTAssertEqual(stub.prismSpans[0].offset, -3)
        XCTAssertEqual(stub.prismSpans[0].along, 6)

        let stub2 = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub2
        var part2 = Part(name: "Spans2")
        part2.sketches.append(s)
        part2.features.append(Feature(name: "Two", kind: .extrude(sketchID: s.id, distance: 5, taperDegrees: 0, mode: .twoSided(second: 2))))
        r = DocumentEngine.rebuild(part: part2)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(stub2.prismSpans.count, 1)
        XCTAssertEqual(stub2.prismSpans[0].offset, -2)
        XCTAssertEqual(stub2.prismSpans[0].along, 7)
        XCTAssertEqual(r.mesh.volume, 20 * 10 * 7, accuracy: 1.0)
    }

    /// Stage 2: a tapered two-sided extrude drafts PER SEGMENT
    /// (two draftGeneral calls, one per legacy mesh segment).
    func testExtrudeTaperDraftsPerSegment() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Taper")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Ex", kind: .extrude(sketchID: s.id, distance: 5, taperDegrees: 4, mode: .twoSided(second: 2))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(stub.prismSpans.count, 2)
        XCTAssertEqual(stub.draftGeneralCalls.count, 2)
        XCTAssertTrue(stub.calls.contains("unite"), "tapered segments united: \(stub.calls)")
    }

    /// Stage 2: extrude2's operation composes exactly through the
    /// provider — cut subtracts, newBody starts a second body.
    func testExtrude2OperationsThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Ex2")
        let plate = plateSketch()
        let pocket = pocketSketch(z: 0)
        part.sketches += [plate, pocket]
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: plate.id, length: 4)))
        part.features.append(Feature(name: "Cut", kind: .extrude2(sketchID: pocket.id, distance: 2, taperDegrees: 0, mode: .one, operation: .cut, end: .dimension)))
        var r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 800 - 80, accuracy: 1.0)
        XCTAssertTrue(stub.calls.contains("subtract"))

        let stub2 = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub2
        var part2 = Part(name: "Ex2b")
        part2.sketches += [plate, pocket]
        part2.features.append(Feature(name: "Pad", kind: .pad(sketchID: plate.id, length: 4)))
        part2.features.append(Feature(name: "New", kind: .extrude2(sketchID: pocket.id, distance: 1, taperDegrees: 0, mode: .one, operation: .newBody, end: .dimension)))
        r = DocumentEngine.rebuild(part: part2)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.bodies.count, 2)
        XCTAssertEqual(r.mesh.volume, 800 + 40, accuracy: 1.0)
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
