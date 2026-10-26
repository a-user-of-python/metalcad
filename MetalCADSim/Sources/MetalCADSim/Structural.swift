import Foundation
import MetalCADKit

/// A force applied to a planar face of the part: `force` newtons,
/// spread in `direction` (only its direction is used — it is
/// normalized internally) evenly over the grid nodes matched from the
/// face's triangles (see `Structural`).
public struct FaceLoad {
    public var face: PlanarFace
    /// Total force magnitude, N (≥ 0).
    public var force: Double
    /// Load direction; must be non-zero.
    public var direction: Vec3

    public init(face: PlanarFace, force: Double, direction: Vec3) {
        self.face = face
        self.force = force
        self.direction = direction
    }
}

/// Configuration for a structural (stress) study. Every knob is
/// exposed; defaults are sane for a first look at a part.
public struct StructuralConfig {
    /// The part's material (engineering properties from `SimMaterial`).
    public var material: SimMaterial
    /// Voxel cell size h, mm. Smaller = finer (and slower).
    public var cellSize: Double = 2.0
    /// Cell budget handed to `VoxelGrid` (guards runaway grids).
    public var maxCells: Int = VoxelGrid.defaultMaxCells
    /// Face loads; may be empty (e.g. a self-weight-only study).
    public var loads: [FaceLoad] = []
    /// Faces whose matched grid nodes are fixed (all 3 DOF = 0).
    /// **At least one is required** — an unfixed part has rigid-body
    /// modes and no static solution.
    public var fixedFaces: [PlanarFace] = []
    /// Add the part's own weight as a body force.
    public var includeSelfWeight: Bool = false
    /// Gravity acceleration vector, m/s² (direction *and* magnitude).
    public var gravity: Vec3 = Vec3(0, 0, -9.81)
    /// PCG relative-residual target.
    public var tolerance: Double = 1e-8
    /// PCG iteration cap; exhausting it throws `SimError.didNotConverge`
    /// (`MSIM-SV001`).
    public var maxIterations: Int = 10_000
    /// Default exaggeration used by `StructuralResult.displacedMesh()`
    /// when no explicit scale is passed.
    public var displacementScale: Double = 1.0

    public init(material: SimMaterial) {
        self.material = material
    }
}

/// Stress state of one element, MPa (N/mm²), Voigt order:
/// xx, yy, zz normal; xy, yz, zx engineering shear.
public struct StressState: Equatable {
    public var xx: Double
    public var yy: Double
    public var zz: Double
    public var xy: Double
    public var yz: Double
    public var zx: Double

    public init(xx: Double, yy: Double, zz: Double, xy: Double, yz: Double, zx: Double) {
        self.xx = xx; self.yy = yy; self.zz = zz
        self.xy = xy; self.yz = yz; self.zx = zx
    }

    public static let zero = StressState(xx: 0, yy: 0, zz: 0, xy: 0, yz: 0, zx: 0)

    /// von Mises equivalent stress, MPa.
    public var vonMises: Double {
        let s = (xx - yy) * (xx - yy) + (yy - zz) * (yy - zz) + (zz - xx) * (zz - xx)
              + 6 * (xy * xy + yz * yz + zx * zx)
        return (0.5 * s).squareRoot()
    }
}

/// The outcome of a structural study. Per-cell arrays are in the
/// grid's flat-index space (`VoxelGrid.flatIndex`); non-solid cells
/// read zero. Per-node arrays are in the result's dense node order,
/// with `nodePositions` alongside to interpret them.
public struct StructuralResult {
    /// The voxel grid the study ran on.
    public let grid: VoxelGrid
    /// von Mises stress per cell, MPa (0 for non-solid cells).
    public let vonMisesPerCell: [Double]
    /// Full stress state per cell, MPa (`.zero` for non-solid cells).
    public let stressPerCell: [StressState]
    /// Peak von Mises stress, MPa.
    public let maxVonMisesMPa: Double
    /// Flat grid index of the peak-stress cell (−1 when the grid has
    /// no solid cells — impossible from `solve`, which throws first).
    public let maxVonMisesCellIndex: Int
    /// World position (mm) of the peak-stress cell's center.
    public let maxVonMisesLocation: Vec3
    /// Nodal displacements, mm, dense node order.
    public let nodalDisplacements: [Vec3]
    /// World positions (mm) of the dense nodes, parallel to
    /// `nodalDisplacements`.
    public let nodePositions: [Vec3]
    /// Largest nodal displacement magnitude, mm.
    public let maxDisplacementMM: Double
    /// Dense node index of the largest displacement (−1 if no nodes).
    public let maxDisplacementNode: Int
    /// Sum of reaction forces at all fixed nodes, N. In equilibrium
    /// this balances the applied loads + self-weight.
    public let totalReaction: Vec3
    /// yieldStrength / maxVonMises. `Double.infinity` when the peak
    /// stress is zero (unloaded study): the part trivially cannot
    /// yield. (A value < 1 means the linear model predicts stress
    /// above yield — the part would deform permanently there; the
    /// linear result itself is not physically valid past yield.)
    public let safetyFactor: Double
    /// PCG iterations the solve took.
    public let iterations: Int
    /// Final relative residual of the solve.
    public let relativeResidual: Double
    /// The study's configured default displacement scale.
    public let displacementScale: Double

    // Dense node id per grid corner (−1 = corner touches no solid
    // cell), flat over (nx+1)×(ny+1)×(nz+1) corners, x fastest.
    private let cornerNodeIds: [Int]

    init(grid: VoxelGrid, vonMisesPerCell: [Double], stressPerCell: [StressState],
         maxVonMisesMPa: Double, maxVonMisesCellIndex: Int, maxVonMisesLocation: Vec3,
         nodalDisplacements: [Vec3], nodePositions: [Vec3],
         maxDisplacementMM: Double, maxDisplacementNode: Int,
         totalReaction: Vec3, safetyFactor: Double,
         iterations: Int, relativeResidual: Double, displacementScale: Double,
         cornerNodeIds: [Int]) {
        self.grid = grid
        self.vonMisesPerCell = vonMisesPerCell
        self.stressPerCell = stressPerCell
        self.maxVonMisesMPa = maxVonMisesMPa
        self.maxVonMisesCellIndex = maxVonMisesCellIndex
        self.maxVonMisesLocation = maxVonMisesLocation
        self.nodalDisplacements = nodalDisplacements
        self.nodePositions = nodePositions
        self.maxDisplacementMM = maxDisplacementMM
        self.maxDisplacementNode = maxDisplacementNode
        self.totalReaction = totalReaction
        self.safetyFactor = safetyFactor
        self.iterations = iterations
        self.relativeResidual = relativeResidual
        self.displacementScale = displacementScale
        self.cornerNodeIds = cornerNodeIds
    }

    /// The deformed shape as a kit `Mesh`: the grid's surface mesh
    /// with every corner moved by (nodal displacement × `scale`).
    /// Corners shared between surface quads share a node, so the
    /// displaced mesh stays welded. Defaults to the study's
    /// configured `displacementScale`.
    public func displacedMesh(scale: Double? = nil) -> Mesh {
        let s = scale ?? displacementScale
        let nx1 = grid.nx + 1, ny1 = grid.ny + 1
        return MeshExtraction.surfaceMesh(of: grid) { position in
            let cx = Int(((position.x - grid.origin.x) / grid.cellSize).rounded())
            let cy = Int(((position.y - grid.origin.y) / grid.cellSize).rounded())
            let cz = Int(((position.z - grid.origin.z) / grid.cellSize).rounded())
            guard cx >= 0, cy >= 0, cz >= 0, cx <= grid.nx, cy <= grid.ny, cz <= grid.nz
            else { return .zero }
            let id = cornerNodeIds[(cz * ny1 + cy) * nx1 + cx]
            guard id >= 0 else { return .zero }
            return nodalDisplacements[id] * s
        }
    }
}

/// Linear-static structural analysis on a voxel grid: every solid
/// voxel is one 8-node trilinear hexahedral (hex8) element; the
/// system K·u = f is solved matrix-free, element-by-element, with the
/// foundation block-3 PCG (Jacobi preconditioner from the assembled
/// nodal diagonal blocks).
///
/// **Units.** Geometry is mm (kit convention). `SimMaterial` gives E
/// and yield in Pa; internally E is converted to N/mm² (MPa,
/// E/1e6) so that with forces in N the stiffness is N/mm,
/// displacements come out in mm, and stresses in MPa. Self-weight
/// converts density (kg/m³) × cell volume (mm³ → m³) × gravity
/// (m/s²) to newtons.
///
/// **Element stiffness.** The cube element's 24×24 Ke is formed once
/// by exact 2×2×2 Gauss integration of BᵀDB (the standard full
/// integration for hex8); the matrix-free operator applies Ke via the
/// same quadrature (strain → stress → nodal forces per Gauss point),
/// which is identical arithmetic. Element stress is the centroid
/// stress: strain from B at the element center.
///
/// **Face → node mapping.** A `PlanarFace` is resolved to triangles
/// via `FaceExtractor.groupedFaces` on the study mesh (exact match
/// first, then nearest geometric match). The face's nodes are the
/// active grid corners lying **on the face's triangulated region**:
/// corners whose distance to some triangle of the face is within half
/// a cell (the triangles' own vertices are the distance-0 case, and
/// corners covered by the triangles' interiors — e.g. the inner nodes
/// of a box end face, which its two triangles tile completely — are
/// included). Loads distribute their total force **evenly** over the
/// matched nodes. Matching only the triangles' vertex positions was
/// considered and rejected: on a coarse source mesh that loads/fixes
/// just the face's outline corners, funneling the whole load path
/// through points — Saint-Venant violations at the face itself, and
/// the analytic bar/beam answers become unreachable.
public enum Structural {

    // Local node ordering (corner offsets dx, dy, dz ∈ {0,1}) and the
    // matching natural coordinates (ξ, η, ζ) ∈ {−1, +1}.
    private static let cornerOffsets: [(Int, Int, Int)] = [
        (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
        (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
    ]

    public static func solve(mesh: Mesh, config: StructuralConfig) throws -> StructuralResult {
        let material = config.material

        // MARK: Validate config
        guard config.cellSize.isFinite else {
            throw SimError.nonFiniteValue(parameter: "cellSize")
        }
        guard config.cellSize > 0 else {
            throw SimError.invalidValue(parameter: "cellSize", detail: "must be > 0 mm")
        }
        guard material.youngModulus.isFinite, material.youngModulus > 0 else {
            throw SimError.invalidValue(parameter: "youngModulus",
                                        detail: "material \"\(material.name)\" has no usable Young's modulus")
        }
        guard material.poissonRatio.isFinite,
              material.poissonRatio > -1, material.poissonRatio < 0.5 else {
            throw SimError.invalidValue(parameter: "poissonRatio",
                                        detail: "must be in (−1, 0.5) for an isotropic solid")
        }
        guard config.tolerance.isFinite, config.tolerance > 0 else {
            throw SimError.invalidValue(parameter: "tolerance", detail: "must be > 0")
        }
        guard config.maxIterations > 0 else {
            throw SimError.invalidValue(parameter: "maxIterations", detail: "must be > 0")
        }
        guard !config.fixedFaces.isEmpty else {
            throw SimError.invalidValue(parameter: "fixedFaces",
                                        detail: "fix at least one face — an unfixed part has no static solution")
        }
        for load in config.loads {
            guard load.force.isFinite else {
                throw SimError.nonFiniteValue(parameter: "load force")
            }
            guard load.force >= 0 else {
                throw SimError.invalidValue(parameter: "load force", detail: "must be ≥ 0 N")
            }
            guard load.direction.isFinite() else {
                throw SimError.nonFiniteValue(parameter: "load direction")
            }
            guard load.direction.length > 1e-12 else {
                throw SimError.zeroDirection(context: "load")
            }
        }
        if config.includeSelfWeight {
            guard config.gravity.isFinite() else {
                throw SimError.nonFiniteValue(parameter: "gravity")
            }
            guard config.gravity.length > 1e-12 else {
                throw SimError.zeroDirection(context: "gravity")
            }
            guard material.densityGCm3.isFinite, material.densityGCm3 > 0 else {
                throw SimError.invalidValue(parameter: "density",
                                            detail: "material \"\(material.name)\" has no usable density for self-weight")
            }
        }

        // MARK: Grid + nodes
        let grid = try VoxelGrid(mesh: mesh, cellSize: config.cellSize, maxCells: config.maxCells)
        guard grid.solidCellCount > 0 else {
            throw SimError.degenerateBounds(detail: "mesh voxelized to zero solid cells")
        }
        let h = grid.cellSize
        let nx = grid.nx, ny = grid.ny, nz = grid.nz
        let nx1 = nx + 1, ny1 = ny + 1, nz1 = nz + 1

        // Dense node ids over grid corners that touch a solid cell,
        // assigned in fixed (z, y, x) scan order.
        var cornerNodeIds = [Int](repeating: -1, count: nx1 * ny1 * nz1)
        func cornerFlat(_ cx: Int, _ cy: Int, _ cz: Int) -> Int { (cz * ny1 + cy) * nx1 + cx }
        var nodePositions: [Vec3] = []
        var elements: [[Int]] = []          // 8 dense node ids per solid cell
        var elementCells: [Int] = []        // flat cell index per element
        elements.reserveCapacity(grid.solidCellCount)
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx where grid.isSolid(x: i, y: j, z: k) {
                    var ids: [Int] = []
                    ids.reserveCapacity(8)
                    for (dx, dy, dz) in cornerOffsets {
                        let cf = cornerFlat(i + dx, j + dy, k + dz)
                        if cornerNodeIds[cf] < 0 {
                            cornerNodeIds[cf] = nodePositions.count
                            nodePositions.append(Vec3(grid.origin.x + Double(i + dx) * h,
                                                      grid.origin.y + Double(j + dy) * h,
                                                      grid.origin.z + Double(k + dz) * h))
                        }
                        ids.append(cornerNodeIds[cf])
                    }
                    elements.append(ids)
                    elementCells.append(grid.flatIndex(x: i, y: j, z: k))
                }
            }
        }
        let nodeCount = nodePositions.count
        let size = 3 * nodeCount

        // MARK: Element stiffness (unit handling: Pa → N/mm² = MPa)
        let eMPa = material.youngModulus / 1e6
        let nu = material.poissonRatio
        let lambda = eMPa * nu / ((1 + nu) * (1 - 2 * nu))
        let mu = eMPa / (2 * (1 + nu))
        // Isotropic D (6×6, Voigt, engineering shear).
        var dMat = [Double](repeating: 0, count: 36)
        for r in 0..<3 {
            for c in 0..<3 { dMat[r * 6 + c] = (r == c) ? lambda + 2 * mu : lambda }
        }
        dMat[3 * 6 + 3] = mu; dMat[4 * 6 + 4] = mu; dMat[5 * 6 + 5] = mu

        // B matrices (6×24) at the 8 Gauss points and at the center.
        let gp = 1.0 / 3.0.squareRoot()
        var gaussB: [[Double]] = []
        for gz in [-gp, gp] {
            for gy in [-gp, gp] {
                for gx in [-gp, gp] {
                    gaussB.append(strainMatrix(xi: gx, eta: gy, zeta: gz, h: h))
                }
            }
        }
        let centerB = strainMatrix(xi: 0, eta: 0, zeta: 0, h: h)
        let gaussWeight = h * h * h / 8   // detJ × w, w = 1 per point

        // Assembled Ke (24×24) — used for the Jacobi diagonal blocks.
        var ke = [Double](repeating: 0, count: 24 * 24)
        for b in gaussB {
            // ke += Bᵀ · D · B · w
            var db = [Double](repeating: 0, count: 6 * 24)
            for r in 0..<6 {
                for c in 0..<24 {
                    var s = 0.0
                    for m in 0..<6 { s += dMat[r * 6 + m] * b[m * 24 + c] }
                    db[r * 24 + c] = s
                }
            }
            for r in 0..<24 {
                for c in 0..<24 {
                    var s = 0.0
                    for m in 0..<6 { s += b[m * 24 + r] * db[m * 24 + c] }
                    ke[r * 24 + c] += s * gaussWeight
                }
            }
        }

        // Jacobi preconditioner blocks: per node, the sum of the 3×3
        // diagonal blocks of Ke over its elements.
        var diagBlocks = [Symmetric3x3](repeating: Symmetric3x3(m00: 0, m01: 0, m02: 0, m11: 0, m12: 0, m22: 0),
                                       count: nodeCount)
        for ids in elements {
            for a in 0..<8 {
                let n = ids[a]
                let b0 = 3 * a
                var blk = diagBlocks[n]
                blk.m00 += ke[b0 * 24 + b0];         blk.m01 += ke[b0 * 24 + b0 + 1]
                blk.m02 += ke[b0 * 24 + b0 + 2];     blk.m11 += ke[(b0 + 1) * 24 + b0 + 1]
                blk.m12 += ke[(b0 + 1) * 24 + b0 + 2]; blk.m22 += ke[(b0 + 2) * 24 + b0 + 2]
                diagBlocks[n] = blk
            }
        }

        // MARK: Face → node mapping
        let grouped = FaceExtractor.groupedFaces(of: mesh)
        func nodes(of face: PlanarFace, context: String) throws -> [Int] {
            // Resolve the face to its triangles in the grouped output
            // (shared rule — see FaceGeometry).
            guard let triangles = FaceGeometry.faceTriangles(of: face, in: grouped,
                                                             cellSize: h) else {
                throw SimError.faceMatchedNoCells(context: context)
            }
            // Active corners on the triangulated region: cheap plane
            // filter first (perpendicular distance to the face plane),
            // then exact point-to-triangle distance ≤ h/2.
            let planeNormal = face.plane.normal
            let planeOrigin = face.plane.origin
            var matched: [Int] = []
            for cz in 0...nz {
                for cy in 0...ny {
                    for cx in 0...nx {
                        let id = cornerNodeIds[cornerFlat(cx, cy, cz)]
                        guard id >= 0 else { continue }
                        let p = nodePositions[id]
                        guard abs((p - planeOrigin).dot(planeNormal)) <= 0.5 * h else { continue }
                        for tri in triangles {
                            if FaceGeometry.pointTriangleDistance(p, tri.0, tri.1, tri.2) <= 0.5 * h {
                                matched.append(id)
                                break
                            }
                        }
                    }
                }
            }
            guard !matched.isEmpty else {
                throw SimError.faceMatchedNoCells(context: context)
            }
            return matched.sorted()
        }

        var fixedNodes = Set<Int>()
        for face in config.fixedFaces {
            for n in try nodes(of: face, context: "fixedFaces") { fixedNodes.insert(n) }
        }
        var isFixed = [Bool](repeating: false, count: nodeCount)
        for n in fixedNodes { isFixed[n] = true }

        // MARK: Right-hand side (N)
        var rhs = [Double](repeating: 0, count: size)
        for load in config.loads {
            let nodes = try nodes(of: load.face, context: "loads")
            let per = load.force / Double(nodes.count)
            let d = load.direction.normalized
            for n in nodes {
                rhs[3 * n] += per * d.x
                rhs[3 * n + 1] += per * d.y
                rhs[3 * n + 2] += per * d.z
            }
        }
        if config.includeSelfWeight {
            // Body force per element: ρ(kg/m³) · V(m³) · g(m/s²) = N,
            // spread evenly (V/8 each — the consistent lumped load for
            // a uniform body force on a trilinear element).
            let elementForce = config.gravity * (material.densityKgM3 * grid.cellVolume * 1e-9)
            for ids in elements {
                for n in ids {
                    rhs[3 * n] += elementForce.x / 8
                    rhs[3 * n + 1] += elementForce.y / 8
                    rhs[3 * n + 2] += elementForce.z / 8
                }
            }
        }

        // MARK: Operators
        // Raw stiffness apply: y = K·u, element-by-element via the
        // Gauss quadrature (identical to Ke·u per element).
        func applyK(_ u: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: size)
            var ue = [Double](repeating: 0, count: 24)
            for ids in elements {
                for a in 0..<8 {
                    ue[3 * a] = u[3 * ids[a]]
                    ue[3 * a + 1] = u[3 * ids[a] + 1]
                    ue[3 * a + 2] = u[3 * ids[a] + 2]
                }
                var fe = [Double](repeating: 0, count: 24)
                for b in gaussB {
                    // ε = B·ue (6), σ = D·ε (6), fe += Bᵀ·σ·w
                    var eps = [Double](repeating: 0, count: 6)
                    for r in 0..<6 {
                        var s = 0.0
                        for c in 0..<24 { s += b[r * 24 + c] * ue[c] }
                        eps[r] = s
                    }
                    var sig = [Double](repeating: 0, count: 6)
                    for r in 0..<6 {
                        var s = 0.0
                        for c in 0..<6 { s += dMat[r * 6 + c] * eps[c] }
                        sig[r] = s
                    }
                    for c in 0..<24 {
                        var s = 0.0
                        for r in 0..<6 { s += b[r * 24 + c] * sig[r] }
                        fe[c] += s * gaussWeight
                    }
                }
                for a in 0..<8 {
                    y[3 * ids[a]] += fe[3 * a]
                    y[3 * ids[a] + 1] += fe[3 * a + 1]
                    y[3 * ids[a] + 2] += fe[3 * a + 2]
                }
            }
            return y
        }
        // Constrained operator for the solve: fixed DOFs are projected
        // out of the input (u_fixed := 0, so K's free rows see the
        // free part only) and their output rows act as identity. With
        // the RHS zeroed at fixed DOFs and a zero start, every PCG
        // iterate keeps u_fixed = 0, and the operator is K on the free
        // subspace — SPD once fixtures remove the rigid-body modes.
        func applyConstrained(_ u: [Double]) -> [Double] {
            var projected = u
            for n in 0..<nodeCount where isFixed[n] {
                projected[3 * n] = 0; projected[3 * n + 1] = 0; projected[3 * n + 2] = 0
            }
            var y = applyK(projected)
            for n in 0..<nodeCount where isFixed[n] {
                y[3 * n] = u[3 * n]; y[3 * n + 1] = u[3 * n + 1]; y[3 * n + 2] = u[3 * n + 2]
            }
            return y
        }
        var solveRhs = rhs
        for n in 0..<nodeCount where isFixed[n] {
            solveRhs[3 * n] = 0; solveRhs[3 * n + 1] = 0; solveRhs[3 * n + 2] = 0
        }

        // MARK: Solve
        let pcg = try PCG.solveBlock3(nodeCount: nodeCount, apply: applyConstrained,
                                      rhs: solveRhs, preconditionerBlocks: diagBlocks,
                                      tolerance: config.tolerance,
                                      maxIterations: config.maxIterations)
        guard pcg.converged else {
            throw SimError.didNotConverge(residual: pcg.residualNorm, iterations: pcg.iterations)
        }
        let u = pcg.x
        var nodalDisplacements: [Vec3] = []
        nodalDisplacements.reserveCapacity(nodeCount)
        var maxDisp = 0.0
        var maxDispNode = nodeCount > 0 ? 0 : -1
        for n in 0..<nodeCount {
            let d = Vec3(u[3 * n], u[3 * n + 1], u[3 * n + 2])
            nodalDisplacements.append(d)
            if d.length > maxDisp { maxDisp = d.length; maxDispNode = n }
        }

        // MARK: Reactions at fixed nodes: R = K·u − f (full f).
        let ku = applyK(u)
        var totalReaction = Vec3.zero
        for n in 0..<nodeCount where isFixed[n] {
            totalReaction = totalReaction + Vec3(ku[3 * n] - rhs[3 * n],
                                                 ku[3 * n + 1] - rhs[3 * n + 1],
                                                 ku[3 * n + 2] - rhs[3 * n + 2])
        }

        // MARK: Element stresses (centroid, MPa)
        var stressPerCell = [StressState](repeating: .zero, count: grid.cellCount)
        var vonMisesPerCell = [Double](repeating: 0, count: grid.cellCount)
        var maxVM = 0.0
        var maxVMCell = -1
        var ue = [Double](repeating: 0, count: 24)
        for (e, ids) in elements.enumerated() {
            for a in 0..<8 {
                ue[3 * a] = u[3 * ids[a]]
                ue[3 * a + 1] = u[3 * ids[a] + 1]
                ue[3 * a + 2] = u[3 * ids[a] + 2]
            }
            var eps = [Double](repeating: 0, count: 6)
            for r in 0..<6 {
                var s = 0.0
                for c in 0..<24 { s += centerB[r * 24 + c] * ue[c] }
                eps[r] = s
            }
            var sig = [Double](repeating: 0, count: 6)
            for r in 0..<6 {
                var s = 0.0
                for c in 0..<6 { s += dMat[r * 6 + c] * eps[c] }
                sig[r] = s
            }
            let state = StressState(xx: sig[0], yy: sig[1], zz: sig[2],
                                    xy: sig[3], yz: sig[4], zx: sig[5])
            let cell = elementCells[e]
            stressPerCell[cell] = state
            let vm = state.vonMises
            vonMisesPerCell[cell] = vm
            if vm > maxVM { maxVM = vm; maxVMCell = cell }
        }
        let maxVMLocation: Vec3
        if maxVMCell >= 0 {
            let cx = maxVMCell % nx
            let cy = (maxVMCell / nx) % ny
            let cz = maxVMCell / (nx * ny)
            maxVMLocation = grid.cellCenter(x: cx, y: cy, z: cz)
        } else {
            maxVMLocation = .zero
        }
        let yieldMPa = material.yieldStrength / 1e6
        let safetyFactor = maxVM > 0 ? yieldMPa / maxVM : Double.infinity

        return StructuralResult(
            grid: grid, vonMisesPerCell: vonMisesPerCell, stressPerCell: stressPerCell,
            maxVonMisesMPa: maxVM, maxVonMisesCellIndex: maxVMCell,
            maxVonMisesLocation: maxVMLocation,
            nodalDisplacements: nodalDisplacements, nodePositions: nodePositions,
            maxDisplacementMM: maxDisp, maxDisplacementNode: maxDispNode,
            totalReaction: totalReaction, safetyFactor: safetyFactor,
            iterations: pcg.iterations, relativeResidual: pcg.relativeResidual,
            displacementScale: config.displacementScale,
            cornerNodeIds: cornerNodeIds)
    }

    /// The 6×24 strain-displacement matrix B at natural coordinates
    /// (xi, eta, zeta) for a cube element of side h (mm): rows are
    /// [εx, εy, εz, γxy, γyz, γzx], columns the 24 nodal DOF.
    /// Physical derivatives carry the 2/h Jacobian factor.
    private static func strainMatrix(xi: Double, eta: Double, zeta: Double, h: Double) -> [Double] {
        var b = [Double](repeating: 0, count: 6 * 24)
        let s = 2.0 / h / 8.0   // (1/8 shape factor) × (2/h Jacobian)
        for a in 0..<8 {
            let (dx, dy, dz) = cornerOffsets[a]
            let sx = dx == 1 ? 1.0 : -1.0
            let sy = dy == 1 ? 1.0 : -1.0
            let sz = dz == 1 ? 1.0 : -1.0
            let dNdx = s * sx * (1 + sy * eta) * (1 + sz * zeta)
            let dNdy = s * sy * (1 + sx * xi) * (1 + sz * zeta)
            let dNdz = s * sz * (1 + sx * xi) * (1 + sy * eta)
            let c = 3 * a
            b[0 * 24 + c] = dNdx
            b[1 * 24 + c + 1] = dNdy
            b[2 * 24 + c + 2] = dNdz
            b[3 * 24 + c] = dNdy;     b[3 * 24 + c + 1] = dNdx
            b[4 * 24 + c + 1] = dNdz; b[4 * 24 + c + 2] = dNdy
            b[5 * 24 + c] = dNdz;     b[5 * 24 + c + 2] = dNdx
        }
        return b
    }
}
