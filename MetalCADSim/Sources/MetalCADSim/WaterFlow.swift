import Foundation
import MetalCADKit

// MARK: - Water flow through a part (grid-native)
//
// METHOD
// ------
// The flow domain is every NON-solid cell of the foundation
// `VoxelGrid` — both `.outside` cells (void connected to the grid
// boundary) and `.void` cells (enclosed cavities). All motion is
// 6-connected on that graph and everything is expressed in terms of
// a scalar HEIGHT per cell:
//
//     height(cell) = −(cellCenter · ĝ),   ĝ = gravity.normalized
//
// so "higher" always means "against gravity", for any gravity
// direction. (Default gravity (0, 0, −1) makes height = z.)
//
// FACE → CELL MAPPING
// -------------------
// Inlet and outlet faces are kit `PlanarFace`s resolved to triangles
// exactly as in `Structural` (exact match in
// `FaceExtractor.groupedFaces`, else nearest geometric match; no
// match throws `MSIM-IN004` — a foreign face). A domain cell belongs
// to the face when EITHER
//   (a) its center lies within 0.75·h of the face's plane AND its
//       projection onto the plane falls inside the face's
//       `outline2D` polygon (the `Thermal` plane rule — this is
//       what seeds the cells inside an opening: a hole's channel
//       cells project inside the surrounding face's outline), OR
//   (b) its center is within 0.75·h of one of the face's triangles
//       (the Structural distance-to-triangles rule, adapted from
//       nodes-on-plane to centers-offset-by-half-a-cell).
// A face mapping to zero domain cells throws `MSIM-IN004`.
//
// FILL (priority flood / minimax sill)
// ------------------------------------
// For each domain cell define its SILL as the minimax path height
// from the inlet region:
//
//     sill(c) = min over paths P from any inlet cell to c of
//               max{ height(x) : x ∈ P }        (endpoints included)
//
// computed with a Dijkstra-style priority flood (path cost = running
// maximum). Supply level:
//
//     limit = inletHeight + pressureHeadMM,
//     inletHeight = max height over the inlet cells.
//
// A cell FILLS iff sill(c) ≤ limit. This is exactly "connected to
// the inlet through cells of ≤ its own height or through
// already-filled cells": pour water in at the inlet, it runs
// downhill freely and rises over sills no higher than the supply
// level. `fillLevelPerCell` reports sill(c) per cell (NaN when the
// cell can never fill / is solid).
//
// AIR TRAPPING (`trapsAir`, default true)
// ---------------------------------------
// Air escapes only by rising. A domain cell is VENTED when a
// non-descending path (each step's height ≥ the previous, within
// 1e-9) leads from it to a vent cell: a cell touching the grid
// boundary, an outlet cell, or a cell above the supply level
// (height > limit — open air over the water). Components of
// unvented domain cells that the untrapped flood would (partly)
// fill and that contain no inlet/outlet cell are AIR LOCKS: their
// cells are removed from the filled set and reported as pockets —
// water does not fill cells that would seal air in. With
// `trapsAir = false` this phase is skipped entirely.
//
// DRAIN (`runDrainPhase`, default true)
// --------------------------------------
// Drain targets are the outlet cells, plus — when
// `drainToGridBoundary` is set — every domain cell touching the
// grid boundary. A filled cell DRAINS when a path to a target
// exists along which height never increases (steps go downhill or
// level, within 1e-9); computed by reverse reachability from the
// targets through filled ∪ target cells. Everything else filled is
// RESIDUAL. With no targets at all, nothing drains. Note the
// outlet faces may legitimately include the fill inlet's own face
// (open the bottom and the part drains back out the way it filled).
//
// BOTTLENECK
// ----------
// Widest path (maximin) between the inlet cells and the outlet
// cells over the domain graph, where a path's width is the minimum
// over its cells of a LOCAL WIDTH:
//     width(cell) = number of domain cells of the cell's connected
//                   component lying in the plane perpendicular to
//                   gravity through the cell's center (cells are
//                   bucketed by floor((center·ĝ)/h)).
// Area = width × h². This is exact for a channel running along
// gravity (the perpendicular plane IS the flow cross-section) and
// an approximation otherwise — the reported location is the
// narrowest cell on the best path. No outlet cells ⇒ area 0 and
// the inlet centroid as location.
//
// POCKETS
// -------
// Reported deterministically (kind order sealed → airLock →
// unreachable, then lowest flat index):
//   - sealed: a connected component of `.void` cells containing no
//     inlet or outlet cell (fully enclosed cavity);
//   - airLock: an unvented component kept empty by the trapping
//     rule above (only when `trapsAir`);
//   - unreachable: a remaining component of unfilled domain cells
//     touching neither the grid boundary nor any inlet/outlet cell
//     (e.g. interior air the supply head could not reach).
//
// SNAPSHOTS
// ---------
// `heightSnapshots` records, for 10 evenly spaced heights between
// the lowest and highest FILLED cell heights (deciles), how many
// filled cells sit at or below that height. Empty when nothing
// filled.
//
// UNITS: mm throughout; volumes are converted mm³ → mL
// (1000 mm³ = 1 mL) in every `...VolumeML` field.

// MARK: - Config

/// Everything a water-flow study needs.
public struct WaterFlowConfig {
    /// Grid cell size in mm. When set it wins over `resolution`.
    public var cellSize: Double? = nil
    /// Cells along the mesh's longest axis when `cellSize` is nil.
    public var resolution: Int = 24
    /// Cell budget for voxelization.
    public var maxCells: Int = VoxelGrid.defaultMaxCells
    /// Faces water enters through. At least one is required, and
    /// each must map to ≥ 1 domain cell (`MSIM-IN004` otherwise).
    public var inletFaces: [PlanarFace] = []
    /// Faces water can leave through (reached-outlet test + drain
    /// targets). May be empty.
    public var outletFaces: [PlanarFace] = []
    /// Gravity direction (only its direction is used — it is
    /// normalized internally). Must be non-zero.
    public var gravity: Vec3 = Vec3(0, 0, -1)
    /// Extra supply pressure, expressed as mm of water column above
    /// the highest inlet cell. ≥ 0.
    public var pressureHeadMM: Double = 0
    /// When true (default), unvented air pockets block filling (see
    /// the header). When false, water fills everything its sill
    /// allows, compressing/ignoring trapped air.
    public var trapsAir: Bool = true
    /// When true (default), run the drain phase after filling.
    public var runDrainPhase: Bool = true
    /// When true, the grid boundary itself counts as a drain target
    /// (and as an outlet for `reachedOutlet`) even with no outlet
    /// faces. Default false.
    public var drainToGridBoundary: Bool = false

    public init() {}
}

// MARK: - Result

/// A body of air/void the water did not claim, with its reason.
public struct FlowPocket {
    public enum Kind: Equatable {
        /// Enclosed `.void` component with no inlet/outlet cell.
        case sealed
        /// Unvented component kept empty by the air-trapping rule.
        case airLock
        /// Interior unfilled component the supply never reached.
        case unreachable
    }
    public var kind: Kind
    /// Flat grid indices of the pocket's cells, ascending.
    public var cells: [Int]
    /// cells × cell volume, mL.
    public var volumeML: Double
    /// Mean of the cells' centers, mm.
    public var centroid: Vec3

    public init(kind: Kind, cells: [Int], volumeML: Double, centroid: Vec3) {
        self.kind = kind
        self.cells = cells
        self.volumeML = volumeML
        self.centroid = centroid
    }
}

/// Outcome of a water-flow study. Cell arrays are in the grid's
/// flat-index space (`VoxelGrid.flatIndex`).
public struct WaterFlowResult {
    /// The grid the study ran on.
    public var grid: VoxelGrid
    /// Filled cells after the fill (+ trapping) phase, before drain.
    public var filledCells: [Bool]
    public var filledCellCount: Int
    /// Filled volume, mL.
    public var filledVolumeML: Double
    /// filledCellCount / number of domain (non-solid) cells.
    public var fillFractionOfVoid: Double
    /// Sill height (mm) at which each cell fills; NaN for solid
    /// cells and for domain cells whose sill exceeds the supply
    /// limit (they did not fill on height grounds).
    public var fillLevelPerCell: [Double]
    /// Domain cells mapped from the inlet faces, ascending.
    public var inletCells: [Int]
    /// Domain cells mapped from the outlet faces, ascending.
    public var outletCells: [Int]
    /// True when at least one filled cell is an outlet cell (or,
    /// with `drainToGridBoundary`, a filled cell touches the grid
    /// boundary).
    public var reachedOutlet: Bool
    /// Trapped / unclaimed air, in deterministic order.
    public var pockets: [FlowPocket]
    /// Cells still holding water after the drain phase.
    public var residualCells: [Bool]
    public var residualCellCount: Int
    /// Residual volume, mL.
    public var residualVolumeML: Double
    /// Bottleneck cross-section area on the best inlet→outlet
    /// path, mm² (0 when there is no path / no outlets).
    public var bottleneckAreaMM2: Double
    /// Center of the narrowest cell on that path, mm (inlet
    /// centroid when there is no path).
    public var bottleneckLocation: Vec3
    /// Filled-cell counts per height decile (see header).
    public var heightSnapshots: [(heightMM: Double, filledCellCount: Int)]
}

// MARK: - Study

public enum WaterFlow {

    /// Runs a water-flow study (fill → trap → pockets → drain →
    /// bottleneck). Throws `SimError` for invalid config (CF),
    /// voxelization problems (GR/IN), and faces that are not faces
    /// of this mesh or map to no domain cells (IN).
    public static func run(mesh: Mesh, config: WaterFlowConfig) throws -> WaterFlowResult {
        let gHat = try validate(config)
        let grid: VoxelGrid
        if let h = config.cellSize {
            grid = try VoxelGrid(mesh: mesh, cellSize: h, maxCells: config.maxCells)
        } else {
            grid = try VoxelGrid(mesh: mesh, resolution: config.resolution,
                                 maxCells: config.maxCells)
        }
        let n = grid.cellCount
        let nx = grid.nx, ny = grid.ny

        // Domain mask + heights.
        var isDomain = [Bool](repeating: false, count: n)
        var heights = [Double](repeating: 0, count: n)
        var domainCount = 0
        for flat in 0..<n where grid.kind(at: flat) != .solid {
            isDomain[flat] = true
            domainCount += 1
            let i = flat % nx, j = (flat / nx) % ny, k = flat / (nx * ny)
            heights[flat] = -grid.cellCenter(x: i, y: j, z: k).dot(gHat)
        }

        // Face → domain-cell mapping.
        let grouped = FaceExtractor.groupedFaces(of: mesh)
        var inletSet = Set<Int>()
        for (idx, face) in config.inletFaces.enumerated() {
            let cells = try mapFace(face, context: "inletFaces[\(idx)]",
                                    grid: grid, grouped: grouped, isDomain: isDomain)
            inletSet.formUnion(cells)
        }
        var outletSet = Set<Int>()
        for (idx, face) in config.outletFaces.enumerated() {
            let cells = try mapFace(face, context: "outletFaces[\(idx)]",
                                    grid: grid, grouped: grouped, isDomain: isDomain)
            outletSet.formUnion(cells)
        }
        let inletCells = inletSet.sorted()
        let outletCells = outletSet.sorted()

        // Boundary domain cells (drain / vent helpers).
        var boundaryCells = Set<Int>()
        for flat in 0..<n where isDomain[flat] {
            let i = flat % nx, j = (flat / nx) % ny, k = flat / (nx * ny)
            if i == 0 || j == 0 || k == 0 || i == nx - 1 || j == ny - 1 || k == grid.nz - 1 {
                boundaryCells.insert(flat)
            }
        }

        // MARK: Fill — priority flood for minimax sill heights.
        let inletHeight = inletCells.map { heights[$0] }.max() ?? 0
        let limit = inletHeight + config.pressureHeadMM
        var sill = [Double](repeating: Double.infinity, count: n)
        var heap = PriorityQueue<(key: Double, cell: Int)> { a, b in
            a.key != b.key ? a.key < b.key : a.cell < b.cell
        }
        for c in inletCells {
            sill[c] = heights[c]
            heap.push((heights[c], c))
        }
        while let top = heap.pop() {
            let c = top.cell
            guard top.key == sill[c] else { continue }   // stale entry
            for nb in domainNeighbors(of: c, grid: grid, isDomain: isDomain) {
                let candidate = max(sill[c], heights[nb])
                if candidate < sill[nb] {
                    sill[nb] = candidate
                    heap.push((candidate, nb))
                }
            }
        }
        var filled = [Bool](repeating: false, count: n)
        for flat in 0..<n where isDomain[flat] {
            filled[flat] = sill[flat] <= limit + 1e-9
        }

        // MARK: Air trapping.
        var airLockCells = Set<Int>()
        if config.trapsAir {
            let vented = ventedCells(grid: grid, isDomain: isDomain, heights: heights,
                                     limit: limit, outletSet: outletSet,
                                     boundaryCells: boundaryCells)
            // Components of unvented domain cells.
            var seen = [Bool](repeating: false, count: n)
            for start in 0..<n where isDomain[start] && !vented[start] && !seen[start] {
                var component: [Int] = []
                var stack = [start]
                seen[start] = true
                while let c = stack.popLast() {
                    component.append(c)
                    for nb in domainNeighbors(of: c, grid: grid, isDomain: isDomain)
                    where !vented[nb] && !seen[nb] {
                        seen[nb] = true
                        stack.append(nb)
                    }
                }
                let touchesPort = component.contains { inletSet.contains($0) || outletSet.contains($0) }
                let wouldFill = component.contains { filled[$0] }
                if !touchesPort && wouldFill {
                    airLockCells.formUnion(component)
                }
            }
            for c in airLockCells { filled[c] = false }
        }

        // MARK: Reached outlet (post-fill, pre-drain).
        var reachedOutlet = outletCells.contains { filled[$0] }
        if !reachedOutlet && config.drainToGridBoundary {
            reachedOutlet = boundaryCells.contains { filled[$0] }
        }

        // MARK: Pockets.
        var pockets: [FlowPocket] = []
        var reported = [Bool](repeating: false, count: n)
        // Sealed: .void components with no inlet/outlet cell.
        for component in components(of: isDomain, grid: grid,
                                     where: { grid.kind(at: $0) == .void }) {
            let touchesPort = component.contains { inletSet.contains($0) || outletSet.contains($0) }
            guard !touchesPort else { continue }
            pockets.append(makePocket(kind: .sealed, cells: component, grid: grid))
            for c in component { reported[c] = true }
        }
        // Air locks (the components removed during trapping). Rebuild
        // them from airLockCells so multi-component sets stay split.
        if !airLockCells.isEmpty {
            for component in components(of: isDomain, grid: grid,
                                        where: { airLockCells.contains($0) }) {
                pockets.append(makePocket(kind: .airLock, cells: component, grid: grid))
                for c in component { reported[c] = true }
            }
        }
        // Unreachable: unfilled, unreported, interior components.
        for component in components(of: isDomain, grid: grid,
                                    where: { !filled[$0] && !reported[$0] }) {
            let touchesBoundary = component.contains { boundaryCells.contains($0) }
            let touchesPort = component.contains { inletSet.contains($0) || outletSet.contains($0) }
            guard !touchesBoundary, !touchesPort else { continue }
            pockets.append(makePocket(kind: .unreachable, cells: component, grid: grid))
            for c in component { reported[c] = true }
        }
        pockets.sort {
            let ra = kindRank($0.kind), rb = kindRank($1.kind)
            if ra != rb { return ra < rb }
            return ($0.cells.first ?? 0) < ($1.cells.first ?? 0)
        }

        // MARK: Drain.
        var residual = filled
        if config.runDrainPhase {
            var targets = outletSet
            if config.drainToGridBoundary { targets.formUnion(boundaryCells) }
            if !targets.isEmpty {
                // Reverse reachability: a cell drains when a
                // non-ascending path (steps never gain height) leads
                // from it to a target. BFS from targets through
                // filled ∪ target cells, expanding to neighbors
                // whose height is ≥ the current cell's (they can
                // flow down/level into it).
                var drains = [Bool](repeating: false, count: n)
                var queue: [Int] = []
                for t in targets where filled[t] || outletSet.contains(t) || targets.contains(t) {
                    if !drains[t] { drains[t] = true; queue.append(t) }
                }
                var head = 0
                while head < queue.count {
                    let c = queue[head]; head += 1
                    for nb in domainNeighbors(of: c, grid: grid, isDomain: isDomain) {
                        guard !drains[nb], filled[nb] else { continue }
                        if heights[nb] >= heights[c] - 1e-9 {
                            drains[nb] = true
                            queue.append(nb)
                        }
                    }
                }
                for flat in 0..<n where filled[flat] && drains[flat] { residual[flat] = false }
            }
        }

        // MARK: Bottleneck (widest path inlet → outlets).
        var drainTargets = outletSet
        if config.drainToGridBoundary { drainTargets.formUnion(boundaryCells) }
        let (bottleneckArea, bottleneckLocation) = bottleneck(
            grid: grid, isDomain: isDomain, heights: heights, gHat: gHat,
            inletCells: inletCells, targetCells: drainTargets)

        // MARK: Snapshots + totals.
        let filledCount = filled.filter { $0 }.count
        var snapshots: [(heightMM: Double, filledCellCount: Int)] = []
        if filledCount > 0 {
            var lo = Double.infinity, hi = -Double.infinity
            for flat in 0..<n where filled[flat] {
                lo = min(lo, heights[flat]); hi = max(hi, heights[flat])
            }
            for d in 1...10 {
                let level = lo + (hi - lo) * Double(d) / 10
                var count = 0
                for flat in 0..<n where filled[flat] && heights[flat] <= level + 1e-12 { count += 1 }
                snapshots.append((level, count))
            }
        }
        var fillLevel = [Double](repeating: Double.nan, count: n)
        for flat in 0..<n where isDomain[flat] && sill[flat] <= limit + 1e-9 {
            fillLevel[flat] = sill[flat]
        }
        let residualCount = residual.filter { $0 }.count
        let mL = grid.cellVolume / 1000

        return WaterFlowResult(
            grid: grid,
            filledCells: filled,
            filledCellCount: filledCount,
            filledVolumeML: Double(filledCount) * mL,
            fillFractionOfVoid: domainCount > 0 ? Double(filledCount) / Double(domainCount) : 0,
            fillLevelPerCell: fillLevel,
            inletCells: inletCells,
            outletCells: outletCells,
            reachedOutlet: reachedOutlet,
            pockets: pockets,
            residualCells: residual,
            residualCellCount: residualCount,
            residualVolumeML: Double(residualCount) * mL,
            bottleneckAreaMM2: bottleneckArea,
            bottleneckLocation: bottleneckLocation,
            heightSnapshots: snapshots)
    }

    // MARK: Validation

    /// Returns the unit gravity vector.
    private static func validate(_ config: WaterFlowConfig) throws -> Vec3 {
        guard !config.inletFaces.isEmpty else {
            throw SimError.invalidValue(parameter: "inletFaces",
                                        detail: "at least one inlet face is required")
        }
        guard config.gravity.isFinite() else {
            throw SimError.nonFiniteValue(parameter: "gravity")
        }
        guard config.gravity.length > 1e-12 else {
            throw SimError.zeroDirection(context: "gravity")
        }
        guard config.pressureHeadMM.isFinite else {
            throw SimError.nonFiniteValue(parameter: "pressureHeadMM")
        }
        guard config.pressureHeadMM >= 0 else {
            throw SimError.invalidValue(parameter: "pressureHeadMM", detail: "must be ≥ 0 mm")
        }
        if let h = config.cellSize {
            guard h.isFinite else { throw SimError.nonFiniteValue(parameter: "cellSize") }
            guard h > 0 else {
                throw SimError.invalidValue(parameter: "cellSize", detail: "must be > 0 mm")
            }
        }
        guard config.resolution > 0 else {
            throw SimError.invalidValue(parameter: "resolution", detail: "must be > 0")
        }
        return config.gravity.normalized
    }

    // MARK: Face mapping

    /// The domain cells belonging to `face` (rules (a)/(b) in the
    /// header). Throws `MSIM-IN004` when the face is not a face of
    /// the mesh or maps to zero domain cells.
    private static func mapFace(_ face: PlanarFace, context: String, grid: VoxelGrid,
                                grouped: (faces: [PlanarFace], triangles: [[Int]], mesh: Mesh),
                                isDomain: [Bool]) throws -> [Int] {
        let h = grid.cellSize
        // Resolve to grouped triangles (shared rule — see
        // FaceGeometry).
        guard let triangles = FaceGeometry.faceTriangles(of: face, in: grouped,
                                                         cellSize: h) else {
            throw SimError.faceMatchedNoCells(context: context)
        }
        let limit = 0.75 * h
        let origin = face.plane.origin
        let normal = face.plane.normal
        var out: [Int] = []
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    let flat = grid.flatIndex(x: i, y: j, z: k)
                    guard isDomain[flat] else { continue }
                    let c = grid.cellCenter(x: i, y: j, z: k)
                    let d = c - origin
                    var inside = false
                    if abs(d.dot(normal)) <= limit {
                        let q = Vec2(d.dot(face.plane.xAxis), d.dot(face.plane.yAxis))
                        inside = face.outline2D.count < 3 || pointInPolygon(q, face.outline2D)
                    }
                    if !inside {
                        for tri in triangles {
                            if FaceGeometry.pointTriangleDistance(c, tri.0, tri.1, tri.2) <= limit {
                                inside = true
                                break
                            }
                        }
                    }
                    if inside { out.append(flat) }
                }
            }
        }
        guard !out.isEmpty else {
            throw SimError.faceMatchedNoCells(context: context)
        }
        return out
    }

    // MARK: Graph helpers

    private static let offsets = [(1, 0, 0), (-1, 0, 0), (0, 1, 0),
                                  (0, -1, 0), (0, 0, 1), (0, 0, -1)]

    private static func domainNeighbors(of flat: Int, grid: VoxelGrid,
                                        isDomain: [Bool]) -> [Int] {
        let nx = grid.nx, ny = grid.ny
        let i = flat % nx, j = (flat / nx) % ny, k = flat / (nx * ny)
        var out: [Int] = []
        for (di, dj, dk) in offsets {
            let (a, b, c) = (i + di, j + dj, k + dk)
            guard grid.isInBounds(x: a, y: b, z: c) else { continue }
            let nf = grid.flatIndex(x: a, y: b, z: c)
            if isDomain[nf] { out.append(nf) }
        }
        return out
    }

    /// Connected components (6-conn) of the domain cells satisfying
    /// `include`, scanning in flat-index order; each component's
    /// cells are sorted ascending.
    private static func components(of isDomain: [Bool], grid: VoxelGrid,
                                   where include: (Int) -> Bool) -> [[Int]] {
        var seen = [Bool](repeating: false, count: grid.cellCount)
        var out: [[Int]] = []
        for start in 0..<grid.cellCount where isDomain[start] && include(start) && !seen[start] {
            var component: [Int] = []
            var stack = [start]
            seen[start] = true
            while let c = stack.popLast() {
                component.append(c)
                for nb in domainNeighbors(of: c, grid: grid, isDomain: isDomain)
                where include(nb) && !seen[nb] {
                    seen[nb] = true
                    stack.append(nb)
                }
            }
            out.append(component.sorted())
        }
        return out
    }

    /// Cells from which air can rise (non-descending path) to a vent
    /// cell: boundary / outlet / above-the-supply-level cells.
    private static func ventedCells(grid: VoxelGrid, isDomain: [Bool], heights: [Double],
                                    limit: Double, outletSet: Set<Int>,
                                    boundaryCells: Set<Int>) -> [Bool] {
        var vented = [Bool](repeating: false, count: grid.cellCount)
        var queue: [Int] = []
        for flat in 0..<grid.cellCount where isDomain[flat] {
            if boundaryCells.contains(flat) || outletSet.contains(flat) || heights[flat] > limit + 1e-9 {
                vented[flat] = true
                queue.append(flat)
            }
        }
        var head = 0
        while head < queue.count {
            let c = queue[head]; head += 1
            // Air at a neighbor n rises into c when height(n) ≤
            // height(c): expand to lower-or-level unvented neighbors.
            for nb in domainNeighbors(of: c, grid: grid, isDomain: isDomain) {
                if !vented[nb] && heights[nb] <= heights[c] + 1e-9 {
                    vented[nb] = true
                    queue.append(nb)
                }
            }
        }
        return vented
    }

    private static func kindRank(_ kind: FlowPocket.Kind) -> Int {
        switch kind {
        case .sealed: return 0
        case .airLock: return 1
        case .unreachable: return 2
        }
    }

    private static func makePocket(kind: FlowPocket.Kind, cells: [Int],
                                   grid: VoxelGrid) -> FlowPocket {
        var centroid = Vec3.zero
        for flat in cells {
            let i = flat % grid.nx, j = (flat / grid.nx) % grid.ny, k = flat / (grid.nx * grid.ny)
            centroid = centroid + grid.cellCenter(x: i, y: j, z: k)
        }
        if !cells.isEmpty { centroid = centroid * (1.0 / Double(cells.count)) }
        return FlowPocket(kind: kind, cells: cells.sorted(),
                          volumeML: Double(cells.count) * grid.cellVolume / 1000,
                          centroid: centroid)
    }

    // MARK: Bottleneck

    private static func bottleneck(grid: VoxelGrid, isDomain: [Bool], heights: [Double],
                                     gHat: Vec3, inletCells: [Int],
                                     targetCells: Set<Int>) -> (area: Double, location: Vec3) {
        let inletCentroid: Vec3 = {
            var c = Vec3.zero
            for flat in inletCells {
                let i = flat % grid.nx, j = (flat / grid.nx) % grid.ny, k = flat / (grid.nx * grid.ny)
                c = c + grid.cellCenter(x: i, y: j, z: k)
            }
            return inletCells.isEmpty ? .zero : c * (1.0 / Double(inletCells.count))
        }()
        guard !targetCells.isEmpty, !inletCells.isEmpty else { return (0, inletCentroid) }
        let h = grid.cellSize

        // Component labels (for slice bucketing) + local widths.
        let labels = components(of: isDomain, grid: grid, where: { _ in true })
        var componentOf = [Int](repeating: -1, count: grid.cellCount)
        for (ci, comp) in labels.enumerated() {
            for c in comp { componentOf[c] = ci }
        }
        var sliceCounts: [[Int]: Int] = [:]
        for flat in 0..<grid.cellCount where isDomain[flat] {
            let i = flat % grid.nx, j = (flat / grid.nx) % grid.ny, k = flat / (grid.nx * grid.ny)
            let proj = grid.cellCenter(x: i, y: j, z: k).dot(gHat)
            let layer = Int(floor(proj / h))
            sliceCounts[[componentOf[flat], layer], default: 0] += 1
        }
        func width(of flat: Int) -> Int {
            let i = flat % grid.nx, j = (flat / grid.nx) % grid.ny, k = flat / (grid.nx * grid.ny)
            let proj = grid.cellCenter(x: i, y: j, z: k).dot(gHat)
            let layer = Int(floor(proj / h))
            return sliceCounts[[componentOf[flat], layer]] ?? 1
        }

        // Maximin Dijkstra from the inlet cells to any target.
        var best = [Int](repeating: -1, count: grid.cellCount)   // widest bottleneck so far
        var parent = [Int](repeating: -1, count: grid.cellCount)
        var heap = PriorityQueue<(key: Int, cell: Int)> { a, b in
            a.key != b.key ? a.key > b.key : a.cell < b.cell    // max-heap via comparator flip
        }
        for c in inletCells {
            let w = width(of: c)
            if w > best[c] { best[c] = w; heap.push((w, c)) }
        }
        var target = -1
        while let top = heap.pop() {
            let c = top.cell
            guard top.key == best[c] else { continue }
            if targetCells.contains(c) { target = c; break }
            for nb in domainNeighbors(of: c, grid: grid, isDomain: isDomain) {
                let candidate = min(best[c], width(of: nb))
                if candidate > best[nb] {
                    best[nb] = candidate
                    parent[nb] = c
                    heap.push((candidate, nb))
                }
            }
        }
        guard target >= 0 else { return (0, inletCentroid) }
        // Walk the path; the bottleneck cell is its narrowest
        // (ties: lowest flat index).
        var path: [Int] = []
        var cursor = target
        while cursor >= 0 {
            path.append(cursor)
            cursor = parent[cursor]
        }
        var narrowest = path[0]
        for c in path {
            if width(of: c) < width(of: narrowest)
                || (width(of: c) == width(of: narrowest) && c < narrowest) {
                narrowest = c
            }
        }
        let i = narrowest % grid.nx, j = (narrowest / grid.nx) % grid.ny, k = narrowest / (grid.nx * grid.ny)
        return (Double(width(of: narrowest)) * h * h,
                grid.cellCenter(x: i, y: j, z: k))
    }

}

/// A tiny deterministic binary heap. `isOrderedBefore(a, b)` is
/// true when `a` should pop before `b`. (Duplicated in spirit from
/// the foundation's needs; PCG's solver does not expose one.)
private struct PriorityQueue<Element> {
    private var items: [Element] = []
    private let isOrderedBefore: (Element, Element) -> Bool

    init(isOrderedBefore: @escaping (Element, Element) -> Bool) {
        self.isOrderedBefore = isOrderedBefore
    }

    mutating func push(_ element: Element) {
        items.append(element)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard isOrderedBefore(items[child], items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items.removeLast() }
        let top = items[0]
        items[0] = items.removeLast()
        var parent = 0
        while true {
            var smallest = parent
            let left = 2 * parent + 1, right = left + 1
            if left < items.count && isOrderedBefore(items[left], items[smallest]) { smallest = left }
            if right < items.count && isOrderedBefore(items[right], items[smallest]) { smallest = right }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}
