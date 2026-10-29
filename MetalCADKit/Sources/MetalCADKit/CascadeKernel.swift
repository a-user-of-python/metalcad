import Foundation

/// The generalized Cascade (OCCT) kernel interface — the full-OCCT
/// migration (2026-10-28, Sean: "make everything use the OCOT
/// engine not just extrude").
///
/// The kit stays pure Swift. At launch the app registers a
/// `CascadeKernelProvider` (CascadeBridge, backed by the C façade
/// over OCCT); rebuild then routes every migrated feature through
/// it. Solids cross the boundary as opaque integer handles owned
/// by the provider's registry — the kit never sees a B-rep. A
/// feature whose kind has no engine path yet (or a rebuild with no
/// provider registered, e.g. kit unit tests) uses the legacy
/// tessellation path, exactly as before the migration.
///
/// Handle discipline: every method that returns a handle returns a
/// NEW one; inputs are never consumed. The kit releases handles it
/// is done with via `release`. All provider calls are made from
/// rebuild, which the bridge serialises internally.
public protocol CascadeKernelProvider: AnyObject {

    /// Solid from a sketch's closed profiles (outer + holes, all
    /// profiles united): the sketch face extruded along the sketch
    /// plane normal, starting `offset` mm along the normal and
    /// running `along` mm (both signed; span = [offset, offset+along]).
    func prismFromSketch(_ sketch: Sketch, offset: Double, along: Double) throws -> Int

    /// Solid from one closed 2D polygon profile on a plane, same
    /// span convention as `prismFromSketch`.
    func prismFromProfile(_ points: [Vec2], plane: Plane3, offset: Double, along: Double) throws -> Int

    /// Revolve a sketch's first profile around an axis given in
    /// sketch coordinates (a point + direction on the sketch plane).
    func revolveFromSketch(_ sketch: Sketch, axisPoint: Vec2, axisDirection: Vec2,
                           angleDegrees: Double) throws -> Int

    /// Revolve ONE closed 2D polygon (a profile loop — outer or a
    /// hole) on `plane` around an axis given in that plane's 2D
    /// coordinates. The kit composes holed profiles itself
    /// (outer minus holes), which `revolveFromSketch` cannot
    /// express (it takes the sketch's first profile only).
    func revolveFromProfile(_ points: [Vec2], plane: Plane3, axisPoint: Vec2,
                            axisDirection: Vec2, angleDegrees: Double) throws -> Int

    /// A native primitive, placed exactly where the kit's
    /// tessellation kernel placed it (box: XY-centred, z 0…height;
    /// cylinder/cone: base on z=0, axis +Z; sphere/torus: centred).
    func primitive(kind: PrimitiveKind, params: [String: Double]) throws -> Int

    /// Loft through ordered polygon profiles (each on its own
    /// plane). `ruled` selects straight interpolation.
    func loft(profiles: [(plane: Plane3, points: [Vec2])], ruled: Bool) throws -> Int

    /// Sweep a polygon profile (on `profilePlane`) along a 3D
    /// polyline path.
    func sweep(profilePlane: Plane3, profile: [Vec2], path: [Vec3]) throws -> Int

    /// A REAL helical thread segment for a MODELED spec, in
    /// canonical placement (axis +Z, base at the origin,
    /// z in [0, spec.length]) — façade `mc_thread`. External
    /// specs return the complete threaded segment (root core +
    /// fused helical ridge, exact end faces). INTERNAL specs
    /// return the groove TOOL solid instead — the void a mating
    /// ridge sweeps out, spanning the minor-to-major annulus —
    /// which the kit subtracts from a blank or a bored body.
    /// Cosmetic specs never reach this method: the kit builds
    /// plain geometry for them and labels them cosmetic.
    func thread(spec: ThreadSpec) throws -> Int

    /// Exact booleans (OCCT BRepAlgoAPI). Inputs unchanged.
    func unite(_ a: Int, _ b: Int) throws -> Int
    func subtract(_ a: Int, _ b: Int) throws -> Int
    func intersect(_ a: Int, _ b: Int) throws -> Int

    /// Constant-radius fillet. `edgeIndices` nil = all edges;
    /// otherwise census edge indices (see `edgeInfos`).
    func fillet(_ s: Int, radius: Double, edgeIndices: [Int]?) throws -> Int
    /// Symmetric chamfer, same edge convention as `fillet`.
    func chamfer(_ s: Int, distance: Double, edgeIndices: [Int]?) throws -> Int
    /// Two-distance (asymmetric) chamfer, same edge convention.
    /// `distanceA` is measured along "face A" of each edge, DEFINED
    /// as the adjacent face with the lower census index (a stored
    /// document carries no other face reference for an asymmetric
    /// chamfer, so the convention is fixed here and in the façade).
    func chamfer2(_ s: Int, distanceA: Double, distanceB: Double, edgeIndices: [Int]?) throws -> Int
    /// Closed hollow solid, walls growing inward by `thickness`.
    func shell(_ s: Int, thickness: Double) throws -> Int
    /// Draft every side face around the neutral plane at the
    /// body's minimum along `pullAxis` (0=X, 1=Y, 2=Z): positive
    /// angle narrows the body toward +axis.
    func draft(_ s: Int, angleDegrees: Double, pullAxis: Int) throws -> Int
    /// Draft around an explicit neutral plane (the plane through
    /// `neutralPoint` perpendicular to `pullDirection`): positive
    /// angle narrows the body on the +pullDirection side. This is
    /// the form tapered extrudes need (neutral plane = the sketch
    /// plane, pull = its normal).
    func draftGeneral(_ s: Int, pullDirection: Vec3, angleDegrees: Double,
                      neutralPoint: Vec3) throws -> Int
    /// General linear map + translation (12 doubles, row-major
    /// 3x4): rotation, translation, scale, mirror.
    func transform(_ s: Int, matrix: [Double]) throws -> Int

    /// Point-in-solid classification: true only for points
    /// strictly inside the solid (façade mc_contains — the
    /// Load + Perform form of the solid classifier). Stage 5's
    /// verify-then-accept pattern/mirror fusions witness their
    /// results with it.
    func contains(_ s: Int, point: Vec3) throws -> Bool

    /// OCCT's own volume (mm^3) / bounding box / census counts.
    func volume(_ s: Int) throws -> Double
    func bounds(_ s: Int) throws -> (min: Vec3, max: Vec3)
    func census(_ s: Int) throws -> (faces: Int, edges: Int, vertices: Int)
    /// Per-face census info: area, centroid, outward normal
    /// (zero for non-planar), planarity.
    func faceInfo(_ s: Int, index: Int) throws -> (area: Double, center: Vec3, normal: Vec3, isPlanar: Bool)
    /// The exact sketch plane of a PLANAR census face (façade
    /// `mc_face_plane`): origin on the face, axes the face
    /// surface's own, xAxis x yAxis = the outward normal. A
    /// non-planar face throws — never a tangent-plane substitute.
    func facePlane(_ s: Int, index: Int) throws -> Plane3
    /// Per-edge census info for every edge, in census order.
    func edgeInfos(_ s: Int) throws -> [CascadeEdgeInfo]

    /// Triangulate for display (the kit's normal render path).
    func tessellate(_ s: Int, deflection: Double) throws -> Mesh

    /// Triangulate WITH the census face index of every triangle
    /// (the façade tessellation's per-face ranges, expanded).
    /// `faceOfTriangle[i]` is the census face that owns triangle
    /// i of the returned mesh. Providers that cannot supply the
    /// ranges return an empty array (the default implementation)
    /// — rebuild then offers no face snapshot for that body.
    func tessellateWithFaceRanges(_ s: Int, deflection: Double) throws -> (mesh: Mesh, faceOfTriangle: [Int])

    /// STEP exchange through OCCT.
    func exportSTEP(_ s: Int, path: String) throws
    /// Import a STEP file; returns the new handle AND the number
    /// of solids (TopAbs_SOLID) inside it — a multi-solid file
    /// arrives as one compound handle, and the count is the only
    /// way to say so honestly in the feature's status.
    func importSTEP(path: String) throws -> (handle: Int, solidCount: Int)
    /// Write several bodies to ONE STEP file (façade
    /// `mc_export_step_bodies`: a compound of the bodies, plain
    /// writer, no colours). STEP write failures throw
    /// `CADError.stepWriteFailed` (MCAD-IO706), not KN602.
    func exportSTEPBodies(_ ids: [Int], path: String) throws
    /// Write bodies to a STEP file through the XDE layer (façade
    /// `mc_export_step_xde`): every solid carries the colour at
    /// the same index in `colors` (one colour per body = the part
    /// material colour) and the document is labelled `name`.
    /// STEP write failures throw MCAD-IO706 as above.
    func exportSTEPXDE(_ ids: [Int], colors: [CensusFaceColor], name: String, path: String) throws
    /// Per-face surface colours of a shape, in census face order
    /// (façade `mc_shape_face_colors`). Only handles that came
    /// from `importSTEP` can carry colours; every other shape
    /// returns one entry per census face with `hasColor == false`.
    func faceColors(_ s: Int) throws -> [CensusFaceColor]

    /// Free a handle. Unknown handles are ignored.
    func release(_ s: Int)
}

public extension CascadeKernelProvider {
    /// Default: ranges unavailable (see the protocol requirement).
    func tessellateWithFaceRanges(_ s: Int, deflection: Double) throws -> (mesh: Mesh, faceOfTriangle: [Int]) {
        (try tessellate(s, deflection: deflection), [])
    }
    /// Default: no colour source (see the protocol requirement).
    func faceColors(_ s: Int) throws -> [CensusFaceColor] { [] }
}

/// One census face's STEP surface colour (Stage 7): RGB in 0..1
/// plus whether the file actually gave the face a colour —
/// colourless faces keep the part material in the renderer.
public struct CensusFaceColor: Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var hasColor: Bool
    public init(red: Double, green: Double, blue: Double, hasColor: Bool) {
        self.red = red; self.green = green; self.blue = blue
        self.hasColor = hasColor
    }
}

/// A retained reference to the engine solid a rebuild ended on
/// (Stage 6, sketch-on-face). Rebuild normally releases every
/// handle before returning; when the final running body is an
/// engine solid AND its display tessellation carries census face
/// ranges, rebuild instead transfers the handle to one of these
/// snapshots in the result. The snapshot owns the handle — it is
/// released when the snapshot is deallocated (the app drops the
/// old rebuild result on the next rebuild) — and answers the two
/// questions sketch-on-face asks: which census face owns a
/// displayed triangle, and what that face's exact plane is.
///
/// Scope: the FINAL running body only. Bodies finished earlier
/// by a `.newBody` feature are tessellated and released as
/// before, and a body a legacy feature materialised to a mesh
/// has no snapshot — the app falls back to its mesh face picker
/// for those, unchanged.
public final class EngineBodySnapshot {
    /// The body's own display tessellation; its triangle order is
    /// `faceOfTriangle`'s order and its segment of the combined
    /// result mesh (starting at `triangleOffset`).
    public let mesh: Mesh
    /// Index of this body's first triangle within the combined
    /// rebuild mesh (and within the welded display mesh — welding
    /// preserves triangle order and count).
    public let triangleOffset: Int
    /// Census face index per body-local triangle.
    public let faceOfTriangle: [Int]

    private let provider: any CascadeKernelProvider
    private let handle: Int

    public init(provider: any CascadeKernelProvider, handle: Int, mesh: Mesh,
                triangleOffset: Int, faceOfTriangle: [Int]) {
        self.provider = provider
        self.handle = handle
        self.mesh = mesh
        self.triangleOffset = triangleOffset
        self.faceOfTriangle = faceOfTriangle
    }

    deinit { provider.release(handle) }

    /// The census face owning a triangle of the COMBINED result
    /// mesh, or nil when the triangle is outside this body.
    public func faceIndex(combinedTriangle triangle: Int) -> Int? {
        let local = triangle - triangleOffset
        guard local >= 0, local < faceOfTriangle.count else { return nil }
        return faceOfTriangle[local]
    }

    /// Body-local triangle indices belonging to census face
    /// `index` (for the sketch editor's face outline guide).
    public func triangles(ofFace index: Int) -> [Int] {
        faceOfTriangle.indices.filter { faceOfTriangle[$0] == index }
    }

    /// Census info for one face of the retained solid.
    public func faceInfo(_ index: Int) throws -> (area: Double, center: Vec3, normal: Vec3, isPlanar: Bool) {
        try provider.faceInfo(handle, index: index)
    }

    /// The exact sketch plane of a planar census face. Throws a
    /// coded CADError for a non-planar face.
    public func facePlane(_ index: Int) throws -> Plane3 {
        try provider.facePlane(handle, index: index)
    }
}

/// One edge of a solid in the census index space shared by
/// tessellation ranges and the fillet/chamfer edge lists.
public struct CascadeEdgeInfo: Equatable {
    /// 0 = line, 1 = circle, 2 = other curve.
    public var curveType: Int
    public var length: Double
    public var start: Vec3
    public var end: Vec3
    /// Circle centre (curveType 1 only; zero otherwise).
    public var center: Vec3
    /// Circle radius (curveType 1 only; 0 otherwise).
    public var radius: Double
    public init(curveType: Int, length: Double, start: Vec3, end: Vec3, center: Vec3, radius: Double) {
        self.curveType = curveType
        self.length = length
        self.start = start
        self.end = end
        self.center = center
        self.radius = radius
    }
    /// A point ON the edge near its middle: exact for lines; for
    /// arcs, the radial bisector point (start/end/centre geometry).
    public var midPoint: Vec3 {
        if curveType == 1, radius > 0 {
            let a = start - center, b = end - center
            var m = a + b
            if m.length < 1e-9 { m = a }  // near-full circle: start is fine
            return center + m.normalized * radius
        }
        return (start + end) * 0.5
    }
}
