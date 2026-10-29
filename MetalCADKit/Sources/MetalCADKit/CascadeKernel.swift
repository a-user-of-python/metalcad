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

    /// OCCT's own volume (mm^3) / bounding box / census counts.
    func volume(_ s: Int) throws -> Double
    func bounds(_ s: Int) throws -> (min: Vec3, max: Vec3)
    func census(_ s: Int) throws -> (faces: Int, edges: Int, vertices: Int)
    /// Per-face census info: area, centroid, outward normal
    /// (zero for non-planar), planarity.
    func faceInfo(_ s: Int, index: Int) throws -> (area: Double, center: Vec3, normal: Vec3, isPlanar: Bool)
    /// Per-edge census info for every edge, in census order.
    func edgeInfos(_ s: Int) throws -> [CascadeEdgeInfo]

    /// Triangulate for display (the kit's normal render path).
    func tessellate(_ s: Int, deflection: Double) throws -> Mesh

    /// STEP exchange through OCCT.
    func exportSTEP(_ s: Int, path: String) throws
    func importSTEP(path: String) throws -> Int

    /// Free a handle. Unknown handles are ignored.
    func release(_ s: Int)
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
