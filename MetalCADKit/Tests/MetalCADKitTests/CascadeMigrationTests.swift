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
        // Ring-transport stand-in for the engine's one-shot sweep:
        // the kit's SweepTessellator CSG-unions one prism per path
        // segment and blows its 60000-triangle cap on long paths
        // (a 3-turn coil) — the real engine has no such cap, so the
        // stub stitches the transported rings into a single mesh
        // instead. Volume is exact on straight runs and within a
        // few percent on gentle bends.
        let loop = profile.map { profilePlane.toWorld($0) }
        guard loop.count >= 3, path.count >= 2 else { throw CADError.sweepPathInvalid("stub sweep: bad input") }
        let centroid = loop.reduce(Vec3.zero) { $0 + $1 } * (1.0 / Double(loop.count))
        let rel = loop.map { $0 - centroid }
        func ring(at point: Vec3, tangent: Vec3) -> [Vec3] {
            let helper = abs(tangent.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
            let fx = helper.cross(tangent).normalized
            let fy = tangent.cross(fx).normalized
            return rel.map { d in point + fx * d.dot(profilePlane.xAxis) + fy * d.dot(profilePlane.yAxis) }
        }
        // One ring pair per segment (start + end in the segment's
        // own frame); consecutive segments share the corner point
        // but not the frame, and the wedge between the two corner
        // rings is stitched too — a single ring per path point
        // twists the strip at corners and halves the volume.
        var rings: [[Vec3]] = []
        for s in 0..<(path.count - 1) {
            let t = (path[s + 1] - path[s]).normalized
            rings.append(ring(at: path[s], tangent: t))
            rings.append(ring(at: path[s + 1], tangent: t))
        }
        var builder = MeshBuilder()
        let rv = rings.map { r in r.map { builder.vertex($0) } }
        for s in 0..<(rings.count - 1) {
            for i in 0..<loop.count {
                let j = (i + 1) % loop.count
                builder.quad(rv[s][i], rv[s][j], rv[s + 1][j], rv[s + 1][i])
            }
        }
        let c0 = builder.vertex(path[0]), c1 = builder.vertex(path[path.count - 1])
        for i in 0..<loop.count {
            let j = (i + 1) % loop.count
            builder.triangle(c0, rv[0][j], rv[0][i])
            builder.triangle(c1, rv[rings.count - 1][i], rv[rings.count - 1][j])
        }
        var mesh = builder.mesh
        if mesh.signedVolume < 0 {
            var idx: [UInt32] = []
            for t in 0..<mesh.triangleCount { idx += [mesh.indices[t * 3], mesh.indices[t * 3 + 2], mesh.indices[t * 3 + 1]] }
            mesh = Mesh(vertices: mesh.vertices, indices: idx)
        }
        return store(mesh)
    }

    func thread(spec: ThreadSpec) throws -> Int {
        calls.append("thread")
        let (vspec, _) = try spec.validated()
        if vspec.kind == .external {
            // The kit's own modeled-thread mesh (core + ridge).
            return store(try ThreadTessellator.threadedShaft(spec: vspec))
        }
        // Internal: the groove TOOL, approximated as the plain
        // annulus between the minor and major cylinders — the
        // right span and placement for wiring tests (the real
        // provider returns the exact helical void).
        let outer = try Tessellation.cylinder(radius: vspec.majorDiameter / 2, height: vspec.length)
        let inner = try Tessellation.cylinder(radius: vspec.minorDiameter / 2, height: vspec.length)
        return store(try CSG.subtract(outer, inner))
    }

    /// When true, `unite` returns a sliver instead of the real
    /// union — a Stage-4-style silent classifier failure — so
    /// tests can prove rebuild's verify-then-accept rejects it.
    var corruptUnites = false

    func unite(_ a: Int, _ b: Int) throws -> Int {
        calls.append("unite")
        if corruptUnites { return store(try Tessellation.box(width: 0.1, depth: 0.1, height: 0.1)) }
        return store(try CSG.union(try mesh(a), try mesh(b)))
    }
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

    func chamfer2(_ s: Int, distanceA: Double, distanceB: Double, edgeIndices: [Int]?) throws -> Int {
        calls.append("chamfer2")
        // The stub's mesh kernel has no census, so edgeIndices are
        // accepted for the record and the whole-body two-distance
        // chamfer runs (wiring fidelity, like the other stub ops).
        _ = edgeIndices
        return store(try EdgeFinisher.chamfer2(body: try mesh(s), distanceA: distanceA, distanceB: distanceB))
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
        // A reflection (negative determinant) reverses winding;
        // the real GTransform keeps faces outward, so flip the
        // triangles to match — CSG and the volume sign depend on
        // it (the same flip Mesh.mirrored performs).
        let det = m[0] * (m[5] * m[10] - m[6] * m[9])
                - m[1] * (m[4] * m[10] - m[6] * m[8])
                + m[2] * (m[4] * m[9] - m[5] * m[8])
        var idx = src.indices
        if det < 0 {
            idx = []
            for t in 0..<src.triangleCount {
                idx += [src.indices[t * 3], src.indices[t * 3 + 2], src.indices[t * 3 + 1]]
            }
        }
        return store(Mesh(vertices: out, indices: idx))
    }

    func contains(_ s: Int, point: Vec3) throws -> Bool {
        calls.append("contains")
        return try mesh(s).contains(point)
    }

    /// Stage 7: multiplies every reported volume — proves the
    /// mass readout follows the PROVIDER's volume, not the mesh.
    var volumeScale: Double = 1
    func volume(_ s: Int) throws -> Double { try mesh(s).volume * volumeScale }
    func bounds(_ s: Int) throws -> (min: Vec3, max: Vec3) {
        let b = try mesh(s).bounds
        return (b.min, b.max)
    }
    func census(_ s: Int) throws -> (faces: Int, edges: Int, vertices: Int) {
        let m = try mesh(s)
        return (m.triangleCount, 0, m.vertices.count)
    }
    /// Stage 6: per-handle grouped faces (lazily extracted from
    /// the stored mesh with the kit's own FaceExtractor) backing
    /// faceInfo / facePlane / tessellation face ranges — the
    /// stub's stand-in for the census. Indices are the grouped
    /// faces' deterministic order.
    private var groupedCache: [Int: (faces: [PlanarFace], triangles: [[Int]])] = [:]
    /// Face indices `faceInfo` reports as curved; `facePlane`
    /// refuses them (the curved-face refusal path).
    var curvedFaceIndices: Set<Int> = []

    private func grouped(_ s: Int) throws -> (faces: [PlanarFace], triangles: [[Int]]) {
        if let g = groupedCache[s] { return g }
        let g = FaceExtractor.groupedFaces(of: try mesh(s))
        groupedCache[s] = (g.faces, g.triangles)
        return groupedCache[s]!
    }

    func faceInfo(_ s: Int, index: Int) throws -> (area: Double, center: Vec3, normal: Vec3, isPlanar: Bool) {
        let g = try grouped(s)
        guard g.faces.indices.contains(index) else {
            throw CADError.kernelOperationFailed("stub: face index out of range")
        }
        let f = g.faces[index]
        return (f.area, f.centroid, f.plane.normal, !curvedFaceIndices.contains(index))
    }

    func facePlane(_ s: Int, index: Int) throws -> Plane3 {
        calls.append("facePlane")
        guard !curvedFaceIndices.contains(index) else {
            throw CADError.kernelOperationFailed("stub: face is not planar - a sketch plane needs a flat face")
        }
        let g = try grouped(s)
        guard g.faces.indices.contains(index) else {
            throw CADError.kernelOperationFailed("stub: face index out of range")
        }
        return g.faces[index].plane
    }

    func tessellateWithFaceRanges(_ s: Int, deflection: Double) throws -> (mesh: Mesh, faceOfTriangle: [Int]) {
        let m = try mesh(s)
        let g = try grouped(s)
        var map = [Int](repeating: 0, count: m.triangleCount)
        for (fi, tris) in g.triangles.enumerated() {
            for t in tris { map[t] = fi }
        }
        return (m, map)
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

    // MARK: Stage 7 — STEP import/export stand-ins
    /// What `importSTEP` hands back (a 10 mm cube by default), the
    /// solid count it reports, and the face colours it claims.
    var stubImportMesh: Mesh? = nil
    var stubImportSolidCount: Int = 1
    var stubImportColors: [CensusFaceColor] = []
    var failImport = false
    var failXDE = false
    var failBodiesExport = false
    private(set) var importedHandles: Set<Int> = []
    private(set) var xdeExports: [(ids: [Int], colors: [CensusFaceColor], name: String, path: String)] = []
    private(set) var bodiesExports: [(ids: [Int], path: String)] = []

    func importSTEP(path: String) throws -> (handle: Int, solidCount: Int) {
        calls.append("importSTEP")
        if failImport { throw CADError.importFileUnreadable("stub: unreadable") }
        let m = try stubImportMesh ?? Tessellation.box(width: 10, depth: 10, height: 10)
        let id = store(m)
        importedHandles.insert(id)
        return (id, stubImportSolidCount)
    }

    func exportSTEPBodies(_ ids: [Int], path: String) throws {
        calls.append("exportSTEPBodies")
        if failBodiesExport { throw CADError.stepWriteFailed("stub: bodies write refused") }
        bodiesExports.append((ids, path))
        try Data("stub step bodies".utf8).write(to: URL(fileURLWithPath: path))
    }

    func exportSTEPXDE(_ ids: [Int], colors: [CensusFaceColor], name: String, path: String) throws {
        calls.append("exportSTEPXDE")
        if failXDE { throw CADError.stepWriteFailed("stub: xde write refused") }
        xdeExports.append((ids, colors, name, path))
        try Data("stub step xde".utf8).write(to: URL(fileURLWithPath: path))
    }

    func faceColors(_ s: Int) throws -> [CensusFaceColor] {
        importedHandles.contains(s) ? stubImportColors : []
    }

    func release(_ s: Int) { registry[s] = nil; groupedCache[s] = nil }
    /// Test probe: handles the stub still holds (snapshot
    /// ownership shows up here — a retained final body stays
    /// registered until its snapshot goes away).
    var liveHandles: [Int] { Array(registry.keys) }
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

    // MARK: - Stage 3 (1.18): fillet / chamfer / shell / chamfer2 /
    // filletEdges / chamferEdges / draftBody / rib / splitBody

    private func engineBox(_ stub: StubCascadeProvider, size: Double = 20) -> Part {
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Box")
        var s = Sketch(name: "s")
        s.addRectangle(from: Vec2(0, 0), to: Vec2(size, size))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: size)))
        return part
    }

    /// Stage 3: .fillet on an engine body routes through the
    /// provider with a census edge list.
    func testFilletRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        var part = engineBox(stub)
        part.features.append(Feature(name: "Fillet", kind: .fillet(radius: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("fillet"), "fillet via engine: \(stub.calls)")
        XCTAssertLessThan(r.mesh.volume, 8000)
        XCTAssertGreaterThan(r.mesh.volume, 7000)
    }

    /// Stage 3: .chamfer routes through the provider.
    func testChamferRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        var part = engineBox(stub)
        part.features.append(Feature(name: "Chamfer", kind: .chamfer(distance: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("chamfer"), "chamfer via engine: \(stub.calls)")
        XCTAssertLessThan(r.mesh.volume, 8000)
    }

    /// Stage 3: .shell routes through the provider. (The stub
    /// reproduces the legacy mesh shell, so this asserts routing +
    /// stub/legacy parity; the exact engine value — 3904 for this
    /// part, where the legacy approximation gives ~2568 — is proven
    /// against mc_shell in the façade harness.)
    func testShellRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        var part = engineBox(stub)
        part.features.append(Feature(name: "Shell", kind: .shell(thickness: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("shell"), "shell via engine: \(stub.calls)")
        DocumentEngine.cascadeProvider = nil
        let legacy = DocumentEngine.rebuild(part: part)
        XCTAssertNil(legacy.firstError)
        XCTAssertEqual(r.mesh.volume, legacy.mesh.volume, accuracy: 0.01)
    }

    /// Stage 3: .chamfer2 (two distances) routes through the
    /// provider's chamfer2; equal distances take the symmetric path.
    func testChamfer2RoutesThroughProvider() {
        let stub = StubCascadeProvider()
        var part = engineBox(stub)
        part.features.append(Feature(name: "C2", kind: .chamfer2(mode: .twoDistances(2, 1))))
        var r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("chamfer2"), "chamfer2 via engine: \(stub.calls)")
        XCTAssertLessThan(r.mesh.volume, 8000)

        let stub2 = StubCascadeProvider()
        var part2 = engineBox(stub2)
        part2.features.append(Feature(name: "C2", kind: .chamfer2(mode: .equal(1.5))))
        r = DocumentEngine.rebuild(part: part2)
        XCTAssertNil(r.firstError)
        XCTAssertFalse(stub2.calls.contains("chamfer2"), "equal distances use symmetric chamfer")
        XCTAssertTrue(stub2.calls.contains("chamfer"))
    }

    /// Stage 3: .filletEdges matches the picked midpoint to a
    /// census edge; a stale midpoint fails with a coded error.
    func testFilletEdgesMatchesPickedMidpoint() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Plate")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "FE", kind: .filletEdges(radius: 1, midpoints: [Vec3(10, 5, 2)])))
        var r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("fillet"))
        XCTAssertLessThan(r.mesh.volume, 800)
        XCTAssertGreaterThan(r.mesh.volume, 780)

        var bad = Part(name: "Plate2")
        bad.sketches.append(s)
        bad.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 4)))
        bad.features.append(Feature(name: "FE", kind: .filletEdges(radius: 1, midpoints: [Vec3(999, 999, 999)])))
        r = DocumentEngine.rebuild(part: bad)
        XCTAssertNotNil(r.firstError, "stale picked edge must fail, not silently no-op")
    }

    /// Stage 3: .draftBody routes through the provider and narrows
    /// the top (volume drops, matching the legacy morph on a box).
    func testDraftBodyRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        var part = engineBox(stub)
        part.features.append(Feature(name: "Draft", kind: .draftBody(angleDegrees: 5, pullAxis: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("draft"), "draft via engine: \(stub.calls)")
        XCTAssertLessThan(r.mesh.volume, 8000)
        XCTAssertGreaterThan(r.mesh.volume, 6000)
    }

    /// Stage 3: .splitBody on an engine body yields two bodies
    /// whose volumes sum to the original.
    func testSplitBodyThroughProvider() {
        let stub = StubCascadeProvider()
        var part = engineBox(stub)
        part.features.append(Feature(name: "Split", kind: .splitBody(axis: 2, offset: 10)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.bodies.count, 2)
        XCTAssertEqual(r.bodies[0].volume, 4000, accuracy: 40)
        XCTAssertEqual(r.bodies[1].volume, 4000, accuracy: 40)
        XCTAssertEqual(r.mesh.volume, 8000, accuracy: 40)
    }

    /// Stage 3: .rib on an engine body builds the wall from engine
    /// solids and lands at the legacy volume (same part as the
    /// legacy rib test: plate 6400 + fin ~360).
    func testRibThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "ribbed")
        var base = Sketch(name: "base")
        base.addRectangle(from: Vec2(0, 0), to: Vec2(40, 40))
        part.sketches.append(base)
        part.features.append(Feature(name: "Plate", kind: .pad(sketchID: base.id, length: 4)))
        var rib = Sketch(name: "rib profile")
        rib.plane = Plane3(origin: Vec3(0, 20, 10), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, 1))
        rib.addLine(Vec2(5, 0), Vec2(35, 0))
        part.sketches.append(rib)
        part.features.append(Feature(name: "Rib", kind: .rib(sketchID: rib.id, thickness: 2, depth: 8)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("intersect"), "rib wall trimmed via engine: \(stub.calls)")
        XCTAssertEqual(r.mesh.volume, 6400 + 360, accuracy: 120)
        XCTAssertEqual(r.mesh.bounds.max.z, 10, accuracy: 0.6)
    }

    /// Stage 3 wrote this test as "a body-op after a legacy
    /// feature falls back": scaleBody was its materializing
    /// feature. Stage 5 migrated scaleBody, so the same chain now
    /// stays on the engine end to end — pad (prism), scale
    /// (transform), fillet (engine) — and the fillet IS asked of
    /// the provider. (After Stage 5 every body feature is
    /// solid-aware; the materialize-then-legacy fallback remains
    /// only for booleanCutPlaceholder, which throws by design.)
    func testBodyOpAfterScaleStaysOnEngine() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Mixed")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Scale", kind: .scaleBody(factors: Vec3(2, 1, 1))))
        part.features.append(Feature(name: "Fillet", kind: .fillet(radius: 1)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("fillet"), "fillet after an engine scale stays on the engine: \(stub.calls)")
        XCTAssertLessThan(r.mesh.volume, 1600)
        XCTAssertGreaterThan(r.mesh.volume, 1400)
    }

    // MARK: Stage 4 (loft, sweep, hole, coil, pipe, threads)

    private func topSketch(z: Double, _ build: (inout Sketch) -> Void) -> Sketch {
        var s = Sketch(name: "s", plane: Plane3(origin: Vec3(0, 0, z), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        build(&s)
        return s
    }

    /// Stage 4: .loft builds through the provider (ruled).
    func testLoftRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Loft")
        let a = topSketch(z: 0) { $0.addRectangle(from: Vec2(-10, -5), to: Vec2(10, 5)) }
        let b = topSketch(z: 10) { $0.addRectangle(from: Vec2(-5, -5), to: Vec2(5, 5)) }
        part.sketches += [a, b]
        part.features.append(Feature(name: "Loft", kind: .loft(sketchA: a.id, sketchB: b.id)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("loft"), "loft via engine: \(stub.calls)")
        // Frustum between 200 and 100 mm^2 over 10 mm: ~1491.
        XCTAssertEqual(r.mesh.volume, 1491, accuracy: 60)
    }

    /// Stage 4: .sweep re-centres the profile on the path and
    /// sweeps through the provider.
    func testSweepRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Sweep")
        let prof = topSketch(z: 0) { $0.addRectangle(from: Vec2(-2, -2), to: Vec2(2, 2)) }
        var path = Sketch(name: "path")
        path.addLine(Vec2(0, 0), Vec2(30, 0))
        path.addLine(Vec2(30, 0), Vec2(30, 20))
        part.sketches += [prof, path]
        part.features.append(Feature(name: "Sweep", kind: .sweep(profileSketchID: prof.id, pathSketchID: path.id)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("sweep"), "sweep via engine: \(stub.calls)")
        XCTAssertGreaterThan(r.mesh.volume, 500)  // 16 mm^2 x ~50 mm path
        DocumentEngine.cascadeProvider = nil
        let legacy = DocumentEngine.rebuild(part: part)
        XCTAssertNil(legacy.firstError)
        XCTAssertEqual(r.mesh.volume, legacy.mesh.volume, accuracy: legacy.mesh.volume * 0.25)
    }

    /// Stage 4: .pipe sweeps its circular profile through the
    /// provider (recorded as a sweep).
    func testPipeRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Pipe")
        var path = Sketch(name: "path")
        path.addLine(Vec2(0, 0), Vec2(30, 0))
        path.addLine(Vec2(30, 0), Vec2(30, 20))
        part.sketches.append(path)
        part.features.append(Feature(name: "Pipe", kind: .pipe(pathSketchID: path.id, radius: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("sweep"), "pipe via engine sweep: \(stub.calls)")
        XCTAssertGreaterThan(r.mesh.volume, 400)  // ~pi*4*50 = 628 less the bend
    }

    /// Stage 4: .coil sweeps the wire profile along the helix
    /// through the provider.
    func testCoilRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Coil")
        part.features.append(Feature(name: "Coil", kind: .coil(radius: 10, pitch: 5, turns: 3, wireRadius: 1)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("sweep"), "coil via engine sweep: \(stub.calls)")
        // Tube: pi * 1^2 * (3 * sqrt((2pi*10)^2 + 25)) ~= 594.
        XCTAssertEqual(r.mesh.volume, 594, accuracy: 90)
    }

    /// Stage 4: .hole cuts an engine tool; through and blind
    /// depths measure like the legacy drill.
    func testHoleRoutesThroughProvider() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "Holes")
        let plate = plateSketch()
        part.sketches.append(plate)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: plate.id, length: 4)))
        let drill = topSketch(z: 4) { $0.addPoint(Vec2(0, 0)) }
        part.sketches.append(drill)
        part.features.append(Feature(name: "Hole", kind: .hole(sketchID: drill.id, diameter: 5, depth: 0, kind: .simple)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("subtract"), "hole cut via engine: \(stub.calls)")
        XCTAssertEqual(r.mesh.volume, 800 - Double.pi * 6.25 * 4, accuracy: 4)
        // Blind: depth 2 removes half as much again from a fresh plate.
        var part2 = Part(name: "Blind")
        part2.sketches.append(plate)
        part2.features.append(Feature(name: "Pad", kind: .pad(sketchID: plate.id, length: 4)))
        part2.sketches.append(drill)
        part2.features.append(Feature(name: "Hole", kind: .hole(sketchID: drill.id, diameter: 5, depth: 2, kind: .simple)))
        let r2 = DocumentEngine.rebuild(part: part2)
        XCTAssertNil(r2.firstError)
        XCTAssertEqual(r2.mesh.volume, 800 - Double.pi * 6.25 * 2, accuracy: 4)
    }

    /// Stage 4: a sketched circle drills at its OWN diameter on
    /// the engine path too (the 2026-10-26 device bug's rule).
    func testHoleCircleSiteUsesOwnDiameter() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "CircleSite")
        let plate = plateSketch()
        part.sketches.append(plate)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: plate.id, length: 4)))
        let drill = topSketch(z: 4) { $0.addCircle(Vec2(0, 0), 3) }
        part.sketches.append(drill)
        part.features.append(Feature(name: "Hole", kind: .hole(sketchID: drill.id, diameter: 5, depth: 0, kind: .simple)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 800 - Double.pi * 9 * 4, accuracy: 5)
    }

    /// Stage 4: a hole with no body fails the same way on both
    /// paths (booleanEmptyResult, never a silent no-op).
    func testHoleOnEmptyBodyFailsLikeLegacy() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "NoBody")
        let drill = topSketch(z: 0) { $0.addPoint(Vec2(0, 0)) }
        part.sketches.append(drill)
        part.features.append(Feature(name: "Hole", kind: .hole(sketchID: drill.id, diameter: 5, depth: 0, kind: .simple)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNotNil(r.firstError)
        DocumentEngine.cascadeProvider = nil
        let legacy = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, legacy.firstError?.code)
    }

    /// Stage 4: a MODELED thread shaft routes through the
    /// provider's thread op and measures like the legacy build.
    func testThreadShaftModeledRoutesThroughProvider() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var spec = try ThreadSpec.preset("M10")
        spec.length = 12
        var part = Part(name: "Bolt")
        part.features.append(Feature(name: "Thread", kind: .threadShaft(spec: spec)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("thread"), "modeled thread via engine: \(stub.calls)")
        XCTAssertGreaterThan(r.mesh.volume, 700)
        XCTAssertLessThan(r.mesh.volume, 820)
        DocumentEngine.cascadeProvider = nil
        let legacy = DocumentEngine.rebuild(part: part)
        XCTAssertNil(legacy.firstError)
        XCTAssertEqual(r.mesh.volume, legacy.mesh.volume, accuracy: 1.0)
    }

    /// Stage 4: a COSMETIC thread shaft (the user's editor
    /// choice) never reaches the thread op: it builds the plain
    /// major-diameter shaft and its status says "Cosmetic".
    func testThreadShaftCosmeticIsPlainAndLabelled() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var spec = try ThreadSpec.preset("M10")
        spec.length = 12
        spec.modeled = false
        var part = Part(name: "CosmeticBolt")
        part.features.append(Feature(name: "Thread", kind: .threadShaft(spec: spec)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertFalse(stub.calls.contains("thread"), "cosmetic must not call the thread op: \(stub.calls)")
        XCTAssertEqual(r.mesh.volume, Double.pi * 25 * 12, accuracy: 6)
        XCTAssertTrue(r.statuses.first?.message?.contains("Cosmetic") == true,
                      "status labels the cosmetic thread: \(String(describing: r.statuses.first?.message))")
    }

    /// Stage 4: an internal thread shaft composes blank − bore −
    /// groove tool through the provider.
    func testThreadShaftInternalComposesTool() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var spec = try ThreadSpec.preset("M10")
        spec.length = 12
        spec.kind = .internal
        var part = Part(name: "Nut")
        part.features.append(Feature(name: "Thread", kind: .threadShaft(spec: spec)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("thread"), "internal thread via engine tool: \(stub.calls)")
        XCTAssertEqual(stub.calls.filter { $0 == "subtract" }.count, 2,
                       "blank-bore and bore-tool subtractions: \(stub.calls)")
    }

    /// Stage 4: thread-on-shaft (external) on an engine body:
    /// measured span, exact segment united through the provider.
    func testThreadOnShaftExternalThroughProvider() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var spec = try ThreadSpec.preset("M10")
        spec.length = 12
        var part = Part(name: "Shafted")
        part.features.append(Feature(name: "Shaft", kind: .primitive(kind: .cylinder, params: ["diameter": 10, "height": 20])))
        part.features.append(Feature(name: "Thread", kind: .threadOnShaft(spec: spec, origin: .zero, axis: Vec3(0, 0, 1))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("thread"), "thread on shaft via engine: \(stub.calls)")
        // The plain shaft is cut out and replaced by the threaded
        // segment over the measured 20 mm span: root core ~1046 +
        // ridge ~224.
        XCTAssertEqual(r.mesh.volume, 1270, accuracy: 140)
    }

    /// Stage 4: thread-on-shaft INTERNAL on an engine body — the
    /// hole-wall case the legacy path refuses — cuts the groove
    /// tool through the provider.
    func testThreadOnShaftInternalThroughProvider() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "NutBody")
        let plate = plateSketch()
        part.sketches.append(plate)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: plate.id, length: 12)))
        let drill = topSketch(z: 12) { $0.addPoint(Vec2(0, 0)) }
        part.sketches.append(drill)
        part.features.append(Feature(name: "Hole", kind: .hole(sketchID: drill.id, diameter: 8.15971, depth: 0, kind: .simple)))
        var spec = try ThreadSpec.preset("M10")
        spec.length = 12
        spec.kind = .internal
        part.features.append(Feature(name: "Thread", kind: .threadOnShaft(spec: spec, origin: .zero, axis: Vec3(0, 0, 1))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertTrue(stub.calls.contains("thread"), "internal on-shaft via engine tool: \(stub.calls)")
        // Plate is 2400; the bore removed ~628 and the groove
        // tool removes more of the annulus.
        XCTAssertGreaterThan(r.mesh.volume, 0)
        XCTAssertLessThan(r.mesh.volume, 2400 - 620)
        // The legacy path still refuses the same feature on a
        // mesh body (its documented limit).
        DocumentEngine.cascadeProvider = nil
        let legacy = DocumentEngine.rebuild(part: part)
        XCTAssertNotNil(legacy.firstError)
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

    // MARK: Stage 5 — patterns, mirror, move/scale

    private func rectSketch(_ name: String, _ from: Vec2, _ to: Vec2) -> Sketch {
        var sketch = Sketch(name: name, plane: Plane3(origin: .zero, xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        sketch.addRectangle(from: from, to: to)
        return sketch
    }

    /// Stage 5: a disjoint linear pattern fuses engine copies —
    /// transform + unite through the provider, volumes adding
    /// exactly (3 x the 800 mm^3 plate).
    func testLinearPatternEngineDisjoint() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "LP")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Pattern", kind: .linearPattern(count: 3, spacing: Vec3(30, 0, 0))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 2400, accuracy: 0.01)
        XCTAssertTrue(stub.calls.contains("transform"))
        XCTAssertTrue(stub.calls.contains("unite"))
        XCTAssertEqual(r.bodies.count, 1)
    }

    /// Stage 5: overlapping linear-pattern copies FUSE on the
    /// engine path (the union spans x -10...30 = 1600 mm^3).
    func testLinearPatternEngineOverlappingFuses() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "LPO")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Pattern", kind: .linearPattern(count: 3, spacing: Vec3(10, 0, 0))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 1600, accuracy: 0.01)
    }

    /// The legacy path APPENDS copies without combining them, so
    /// the same overlapping pattern measures 2400 there — the
    /// documented Stage 5 parity delta (legacy double-counts the
    /// overlap; the engine counts it once).
    func testLinearPatternLegacyAppendDelta() {
        var part = Part(name: "LPL")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Pattern", kind: .linearPattern(count: 3, spacing: Vec3(10, 0, 0))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 2400, accuracy: 0.01)
    }

    /// Stage 5: the pattern guard is the legacy one (count >= 1,
    /// non-zero spacing) on the engine path too.
    func testLinearPatternEngineRejectsZeroCount() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "LP0")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Pattern", kind: .linearPattern(count: 0, spacing: Vec3(10, 0, 0))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT411")
    }

    /// Stage 5: verify-then-accept REJECTS a silently corrupt
    /// fuse (the stub returns a sliver): the feature fails with
    /// KN603 and the rebuild output is still the pre-pattern body.
    func testPatternVerificationRejectsCorruptUnite() {
        let stub = StubCascadeProvider()
        stub.corruptUnites = true
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "LPC")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Pattern", kind: .linearPattern(count: 2, spacing: Vec3(30, 0, 0))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-KN603")
        XCTAssertEqual(r.statuses.last?.ok, false)
        XCTAssertEqual(r.mesh.volume, 800, accuracy: 0.01)
    }

    /// Stage 5: circular pattern about the bounds centre. The
    /// 6x2 block (48 mm^3) at 0/90/180/270 degrees: the 6x2 and
    /// 2x6 footprints cross in a 2x2 square, so the union is
    /// 48 + 48 - 16 = 80.
    func testCircularPatternEngine() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "CP")
        let s = rectSketch("Block", Vec2(8, -1), Vec2(14, 1))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Circular", kind: .circularPattern(count: 4, axis: 2, totalDegrees: 360)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 80, accuracy: 0.01)
        XCTAssertTrue(stub.calls.contains("transform"))
        XCTAssertTrue(stub.calls.contains("unite"))
    }

    /// Stage 5: circular pattern keeps the legacy count guard.
    func testCircularPatternEngineRejectsCountOne() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "CP1")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Circular", kind: .circularPattern(count: 1, axis: 2, totalDegrees: 360)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT411")
    }

    /// Stage 5: mirror across the YZ origin plane — a block at
    /// x 2...6 gains its disjoint twin (volume doubles, bounds
    /// span -6...6).
    func testMirrorEngineDisjoint() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "MI")
        let s = rectSketch("Block", Vec2(2, -2), Vec2(6, 2))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Mirror", kind: .mirror(plane: .yz)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 128, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.min.x, -6, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.x, 6, accuracy: 0.01)
    }

    /// Stage 5: a body crossing the mirror plane fuses with its
    /// overlapping twin (union spans x -6...6 = 192 mm^3).
    func testMirrorEngineCrossing() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "MIX")
        let s = rectSketch("Block", Vec2(-2, -2), Vec2(6, 2))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Mirror", kind: .mirror(plane: .yz)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 192, accuracy: 0.01)
    }

    /// Stage 5: a downstream cut composes with the mirrored pair
    /// (a pocket over the mirrored half removes exactly its top).
    func testMirrorThenPocketEngine() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "MIP")
        let s = rectSketch("Block", Vec2(2, -2), Vec2(6, 2))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Mirror", kind: .mirror(plane: .yz)))
        var pocketSketch = Sketch(name: "Pocket", plane: Plane3(origin: Vec3(0, 0, 4), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0)))
        pocketSketch.addRectangle(from: Vec2(-6, -2), to: Vec2(-2, 2))
        part.sketches.append(pocketSketch)
        part.features.append(Feature(name: "Pocket", kind: .cascadePocket(sketchID: pocketSketch.id, depth: 2)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 96, accuracy: 0.01)
    }

    /// Stage 5: move = rotate about the bounds centre, then
    /// translate (the legacy order), through the engine.
    func testMoveBodyEngineTranslation() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "MV")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Move", kind: .moveBody(translation: Vec3(5, 3, 0), rotationAxis: 2, rotationDegrees: 0)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 800, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.min.x, -5, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.min.y, -2, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.x, 15, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.y, 8, accuracy: 0.01)
    }

    /// Stage 5: a 90-degree move rotation about the bounds centre
    /// swaps the footprint extents, volume unchanged.
    func testMoveBodyEngineRotation() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "MVR")
        let s = rectSketch("Block", Vec2(8, -1), Vec2(14, 1))
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Move", kind: .moveBody(translation: .zero, rotationAxis: 2, rotationDegrees: 90)))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 48, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.min.x, 10, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.x, 12, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.min.y, -3, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.y, 3, accuracy: 0.01)
    }

    /// Stage 5: scale about the bounds centre — (2,1,0.5) keeps
    /// the volume (factor product 1) and maps the bounds exactly;
    /// (2,2,2) multiplies the volume by 8.
    func testScaleBodyEngine() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "SC")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Scale", kind: .scaleBody(factors: Vec3(2, 1, 0.5))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r.firstError)
        XCTAssertEqual(r.mesh.volume, 800, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.min.x, -20, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.x, 20, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.min.z, 1, accuracy: 0.01)
        XCTAssertEqual(r.mesh.bounds.max.z, 3, accuracy: 0.01)

        var part2 = Part(name: "SC2")
        let s2 = plateSketch()
        part2.sketches.append(s2)
        part2.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s2.id, length: 4)))
        part2.features.append(Feature(name: "Scale", kind: .scaleBody(factors: Vec3(2, 2, 2))))
        let r2 = DocumentEngine.rebuild(part: part2)
        XCTAssertNil(r2.firstError)
        XCTAssertEqual(r2.mesh.volume, 6400, accuracy: 0.01)
    }

    /// Stage 5: the scale factor guard is the legacy one on the
    /// engine path too.
    func testScaleBodyEngineRejectsZeroFactor() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = Part(name: "SC0")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 4)))
        part.features.append(Feature(name: "Scale", kind: .scaleBody(factors: Vec3(0, 1, 1))))
        let r = DocumentEngine.rebuild(part: part)
        XCTAssertEqual(r.firstError?.code, "MCAD-FT412")
    }

    // MARK: - Stage 6 (1.21): sketch-on-face

    /// A 20x10 plate padded 10 thick through the provider.
    private func platePart10() -> Part {
        var part = Part(name: "FacePlate")
        let s = plateSketch()
        part.sketches.append(s)
        part.features.append(Feature(name: "Pad", kind: .cascadePad(sketchID: s.id, length: 10)))
        return part
    }

    /// The census-style index of the stub face whose normal is +Z
    /// (the plate's top), resolved through the snapshot itself.
    private func topFaceIndex(_ snap: EngineBodySnapshot) throws -> Int {
        for i in 0..<64 {
            guard let info = try? snap.faceInfo(i) else { break }
            if info.isPlanar, info.normal.z > 0.999 { return i }
        }
        throw CADError.kernelOperationFailed("test: no +Z face")
    }

    /// Stage 6: a rebuild that ends on an engine solid carries a
    /// snapshot; every combined-mesh triangle of the body resolves
    /// to a census face, and the top face's plane is exact.
    func testRebuildEndsWithEngineSnapshot() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        let result = DocumentEngine.rebuild(part: platePart10())
        XCTAssertNil(result.firstError)
        let snap = try XCTUnwrap(result.engineBody, "engine-ended rebuild must carry a snapshot")
        XCTAssertEqual(snap.triangleOffset, 0)
        XCTAssertEqual(snap.faceOfTriangle.count, result.mesh.triangleCount)
        for t in 0..<result.mesh.triangleCount {
            XCTAssertNotNil(snap.faceIndex(combinedTriangle: t), "triangle \(t) must resolve to a face")
        }
        XCTAssertNil(snap.faceIndex(combinedTriangle: result.mesh.triangleCount))
        let top = try topFaceIndex(snap)
        let plane = try snap.facePlane(top)
        XCTAssertEqual(plane.normal.z, 1, accuracy: 1e-9)
        XCTAssertEqual(plane.origin.z, 10, accuracy: 1e-9)
        XCTAssertTrue(stub.calls.contains("facePlane"))
    }

    /// Stage 6: the snapshot OWNS the final handle — it stays live
    /// while the result lives and is released with it; every other
    /// handle rebuild made was already released inside rebuild.
    func testSnapshotOwnsFinalHandle() {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var result: RebuildResult? = DocumentEngine.rebuild(part: platePart10())
        XCTAssertNotNil(result?.engineBody)
        XCTAssertEqual(stub.liveHandles.count, 1,
                       "only the snapshot's handle may outlive rebuild: \(stub.liveHandles)")
        result = nil
        XCTAssertEqual(stub.liveHandles.count, 0,
                       "dropping the result must release the snapshot handle")
    }

    /// Stage 6: no provider → no snapshot (kit-only contexts are
    /// exactly as before).
    func testNoProviderNoSnapshot() {
        DocumentEngine.cascadeProvider = nil
        let result = DocumentEngine.rebuild(part: platePart10())
        XCTAssertNil(result.engineBody)
    }

    /// Stage 6, the headline flow: sketch on the plate's TOP face
    /// (plane taken from the snapshot), pocket 2 deep through the
    /// engine — the volume is the plate minus the pocket prism.
    func testFaceSketchPocketIntoEngineBody() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = platePart10()
        let first = DocumentEngine.rebuild(part: part)
        let snap = try XCTUnwrap(first.engineBody)
        let top = try topFaceIndex(snap)
        var faceSketch = Sketch(name: "Sketch on Face \(top)", plane: try snap.facePlane(top))
        faceSketch.sourceFaceIndex = top
        faceSketch.addRectangle(from: Vec2(-3, -2), to: Vec2(3, 2))
        part.sketches.append(faceSketch)
        part.features.append(Feature(name: "Pocket", kind: .cascadePocket(sketchID: faceSketch.id, depth: 2)))

        let result = DocumentEngine.rebuild(part: part)
        XCTAssertNil(result.firstError)
        XCTAssertTrue(result.statuses.allSatisfy { $0.ok })
        XCTAssertEqual(result.mesh.volume, 2000 - 6 * 4 * 2, accuracy: 2.0)
    }

    /// Stage 6: sketch on a SIDE face — the pad grows along the
    /// face normal (+X), not along +Z.
    func testFaceSketchPadOnSideFace() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = platePart10()
        let first = DocumentEngine.rebuild(part: part)
        let snap = try XCTUnwrap(first.engineBody)
        var side = -1
        for i in 0..<64 {
            guard let info = try? snap.faceInfo(i) else { break }
            if info.isPlanar, info.normal.x > 0.999 { side = i; break }
        }
        XCTAssertGreaterThanOrEqual(side, 0)
        var faceSketch = Sketch(name: "Sketch on Face \(side)", plane: try snap.facePlane(side))
        faceSketch.sourceFaceIndex = side
        // The +X face's plane coords: the rect is centred on the
        // face in 3D by construction of the stub's grouped plane
        // (origin at the face centroid).
        faceSketch.addRectangle(from: Vec2(-2, -2), to: Vec2(2, 2))
        part.sketches.append(faceSketch)
        part.features.append(Feature(name: "Boss", kind: .cascadePad(sketchID: faceSketch.id, length: 3)))

        let result = DocumentEngine.rebuild(part: part)
        XCTAssertNil(result.firstError)
        XCTAssertEqual(result.mesh.volume, 2000 + 4 * 4 * 3, accuracy: 2.0)
        XCTAssertEqual(result.mesh.bounds.max.x, 13, accuracy: 0.05)
    }

    /// Stage 6: a face the census calls curved is refused by
    /// facePlane with a coded error — never approximated.
    func testCurvedFacePlaneRefused() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        let first = DocumentEngine.rebuild(part: platePart10())
        let snap = try XCTUnwrap(first.engineBody)
        let top = try topFaceIndex(snap)
        stub.curvedFaceIndices = [top]
        let info = try snap.faceInfo(top)
        XCTAssertFalse(info.isPlanar)
        XCTAssertThrowsError(try snap.facePlane(top)) { error in
            XCTAssertEqual((error as? CADError)?.code, "MCAD-KN602")
        }
    }

    /// Stage 6: the face sketch is a self-contained document
    /// citizen — its plane (and the source-face metadata) survive
    /// a save/load round trip, and a document JSON written before
    /// Stage 6 (no sourceFaceIndex key) still decodes.
    func testFaceSketchDocumentRoundTrip() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = platePart10()
        let first = DocumentEngine.rebuild(part: part)
        let snap = try XCTUnwrap(first.engineBody)
        let top = try topFaceIndex(snap)
        var faceSketch = Sketch(name: "Sketch on Face \(top)", plane: try snap.facePlane(top))
        faceSketch.sourceFaceIndex = top
        faceSketch.addRectangle(from: Vec2(-3, -2), to: Vec2(3, 2))
        part.sketches.append(faceSketch)
        var doc = CADDocument(name: "Face Doc")
        doc.parts.append(part)
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(CADDocument.self, from: data)
        XCTAssertEqual(back, doc)
        XCTAssertEqual(back.parts[0].sketches.last?.sourceFaceIndex, top)

        // Pre-Stage-6 JSON: remove the key STRUCTURALLY (the
        // JSONSerialization round trip — string surgery on the
        // encoder's output proved platform-fragile: Darwin's
        // JSONEncoder text need not contain the exact substring),
        // decoding must yield nil.
        var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var parts = root["parts"] as! [[String: Any]]
        var sketches = parts[0]["sketches"] as! [[String: Any]]
        sketches[sketches.count - 1].removeValue(forKey: "sourceFaceIndex")
        parts[0]["sketches"] = sketches
        root["parts"] = parts
        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let legacy = try JSONDecoder().decode(CADDocument.self, from: legacyData)
        XCTAssertNil(legacy.parts[0].sketches.last?.sourceFaceIndex)
        XCTAssertEqual(legacy.parts[0].sketches.last?.plane, faceSketch.plane)
    }

    /// Stage 6: rebuild is deterministic for a face-sketch part —
    /// same mesh, same census mapping, same plane, twice.
    func testFaceSketchRebuildDeterminism() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        var part = platePart10()
        let first = DocumentEngine.rebuild(part: part)
        let snap = try XCTUnwrap(first.engineBody)
        let top = try topFaceIndex(snap)
        var faceSketch = Sketch(name: "Sketch on Face \(top)", plane: try snap.facePlane(top))
        faceSketch.sourceFaceIndex = top
        faceSketch.addRectangle(from: Vec2(-3, -2), to: Vec2(3, 2))
        part.sketches.append(faceSketch)
        part.features.append(Feature(name: "Pocket", kind: .cascadePocket(sketchID: faceSketch.id, depth: 2)))

        let r1 = DocumentEngine.rebuild(part: part)
        let r2 = DocumentEngine.rebuild(part: part)
        XCTAssertNil(r1.firstError)
        XCTAssertNil(r2.firstError)
        XCTAssertEqual(r1.mesh.volume, r2.mesh.volume, accuracy: 1e-9)
        XCTAssertEqual(r1.engineBody?.faceOfTriangle, r2.engineBody?.faceOfTriangle)
        let p1 = try XCTUnwrap(r1.engineBody).facePlane(top)
        let p2 = try XCTUnwrap(r2.engineBody).facePlane(top)
        XCTAssertEqual(p1, p2)
    }

    /// Stage 6: the face-sketch document does not depend on the
    /// engine staying attached — rebuilt with NO provider, the
    /// same part goes down the legacy paths and the pocket still
    /// lands (the sketch's stored plane is the whole contract).
    func testFaceSketchPartRebuildsOnLegacyKernel() throws {
        let stub = StubCascadeProvider()
        DocumentEngine.cascadeProvider = stub
        // The base is a plain .pad (a kind with a true legacy
        // path), so the no-provider rebuild below is legacy end
        // to end; the face sketch itself comes from the engine
        // snapshot of the engine rebuild.
        var part = Part(name: "FacePlateLegacy")
        let base = plateSketch()
        part.sketches.append(base)
        part.features.append(Feature(name: "Pad", kind: .pad(sketchID: base.id, length: 10)))
        let first = DocumentEngine.rebuild(part: part)
        let snap = try XCTUnwrap(first.engineBody)
        let top = try topFaceIndex(snap)
        var faceSketch = Sketch(name: "Sketch on Face \(top)", plane: try snap.facePlane(top))
        faceSketch.sourceFaceIndex = top
        faceSketch.addRectangle(from: Vec2(-3, -2), to: Vec2(3, 2))
        part.sketches.append(faceSketch)
        part.features.append(Feature(name: "Pocket", kind: .pocket(sketchID: faceSketch.id, depth: 2)))

        DocumentEngine.cascadeProvider = nil
        let legacy = DocumentEngine.rebuild(part: part)
        XCTAssertNil(legacy.firstError)
        XCTAssertNil(legacy.engineBody)
        XCTAssertEqual(legacy.mesh.volume, 2000 - 6 * 4 * 2, accuracy: 2.0)
    }
}
