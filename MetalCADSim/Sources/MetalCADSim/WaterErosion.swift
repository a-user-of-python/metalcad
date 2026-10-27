import Foundation
import MetalCADKit

// MARK: - Water erosion over the voxel grid
//
// MODEL (visualization-grade — read this before trusting a number)
// ----------------------------------------------------------------
// The part is voxelized (foundation `VoxelGrid`); erosion peels it
// one surface cell at a time. Everything is deterministic: fixed
// iteration order, no randomness, identical inputs ⇒ identical grid.
//
// SURFACE CELLS & NORMALS. A *surface cell* is a solid cell with at
// least one non-solid cell among its 6 face-neighbors. Its outward
// normal comes from the solid-mask gradient over the 6-neighborhood:
// per axis, n_axis = (solid on the − side ? 1 : 0) − (solid on the
// + side ? 1 : 0), normalised. This is a staircase normal — exact on
// axis-aligned faces, a 6-neighborhood average on slopes — and it is
// the only normal this model uses. An isolated cell (no solid
// neighbor at all) has a zero gradient; its normal falls back to
// facing the flow head-on.
//
// SHIELDING (exposure). From the void cell the surface faces (the
// non-solid 6-neighbor most aligned with the outward normal — the
// patch's "front porch" in the fluid), march upstream — along
// −flowDirection, in steps of one cell — through non-solid cells.
// If a solid cell is met before the march leaves the grid region
// inflated by one cell on every side, the cell is *shielded* and
// does not erode this step; otherwise it is *exposed*. (Marching
// from the surface cell's own centre instead would run through the
// cell's own row of material for any wall parallel to the flow —
// a channel wall would shield itself.) The march samples the ray
// at cell-size intervals (a voxel-traversal approximation: a cell
// touched only at a corner may be skipped).
// Enclosed cavities (the grid's `.void` cells) sit behind solid on
// every upstream path, so their walls never erode — water that cannot
// reach a surface cannot wear it.
//
// INTERNAL SURFACES. A surface cell is *internal* when it cannot see
// the sky: marching from the cell along its outward normal hits solid
// before leaving the inflated grid. (This geometric test is needed
// because the voxelizer classifies an open channel's void as
// `.outside` — boundary-connected — so `CellKind` alone cannot tell a
// channel wall from the outer hull. The price: a wall whose normal
// happens to point straight out of a wide, short mouth counts as
// external.) With `includeInternalSurfaces == false`, internal cells
// never erode; with `true` (default) they erode by the same rules —
// the water flowing through the part's passages.
//
// RATE. For an exposed surface cell, with unit flow direction `d`
// (the direction the water travels) and unit outward normal `n`:
//
//     incidence  = max(0, −(d · n))            (1 = head-on)
//     depthRate  = K · S · (g + (1 − g) · incidence) / R     [mm/s]
//
// where K = `erosionCoefficient`, R = `material.erosionResistance`
// (the SimMaterial 0…1 relative index), g = `glancingFactor`
// (default 0.25 — even a glancing surface is scrubbed by turbulence,
// so its rate floor is g × the head-on rate), and S is the speed
// factor: S = v² normally (v = `flowSpeed` in m/s). With
// `scaleByDynamicPressure == true`, S = ρ·v²/1000 instead — i.e. the
// dynamic pressure q = ½ρv² normalised by q_ref = 500 Pa (water at
// 1 m/s) — which only changes anything for non-water densities, since
// ρ = 1000 reproduces v² exactly.
//
// `erosionCoefficient` folds every unit conversion and the material's
// absolute wear constant into one calibration knob (reference value
// 1.0). Treat ABSOLUTE rates as calibration-grade: the relative
// pattern — where it erodes, what erodes first, how materials rank —
// is the product.
//
// ITERATION. `durationSeconds` is split into `stepCount` equal steps.
// Each step: exposures and rates are computed on the CURRENT mask;
// every exposed surface cell accumulates depth += rate · dt; then any
// surface cell whose accumulated depth ≥ cellSize is REMOVED (turned
// non-solid) and its cell mass is credited to the mass loss. A removed
// cell's surplus depth past one cell is discarded (documented
// simplification — no carry-over into the cell behind it). Cells
// exposed by a removal start accumulating next step.
//
// DEPTH MAP. `depthPerCell` is in the grid's flat-index space and
// holds, for every cell that was a surface cell at any step, the depth
// it accumulated while exposed — including removed cells, whose entry
// stays at their removal depth (≥ cellSize). It is NOT a per-original-
// surface total: once a layer peels, the cell behind it accumulates
// under its own index. Read mass loss / cellsRemoved for totals.

/// Configuration for a water-erosion study. See the model notes at
/// the top of this file for exactly what the knobs mean.
public struct ErosionConfig {
    /// Simulation properties of the part's material (its
    /// `erosionResistance` divides the wear rate; its density sets
    /// the mass loss).
    public var material: SimMaterial
    /// Direction the water travels (need not be unit — it is
    /// normalised). Zero-length is `SimError.zeroDirection`.
    public var flowDirection: Vec3 = Vec3(1, 0, 0)
    /// Flow speed, m/s. Must be ≥ 0 and finite. Zero is valid and
    /// yields zero erosion.
    public var flowSpeed: Double = 1
    /// Water density, kg/m³. Must be > 0 and finite. Only used when
    /// `scaleByDynamicPressure` is true.
    public var waterDensity: Double = 1000
    /// When true, the rate's speed factor is the dynamic-pressure
    /// ratio ρv²/1000 instead of v² (see model notes).
    public var scaleByDynamicPressure: Bool = false
    /// Calibration knob folding all absolute wear constants into one
    /// number; reference value 1.0. Must be ≥ 0 and finite.
    public var erosionCoefficient: Double = 1.0
    /// Total simulated erosion time, s. Must be > 0 and finite.
    public var durationSeconds: Double = 60
    /// Number of peel steps the duration is split into (1…100000).
    public var stepCount: Int = 20
    /// Grid cell size in mm. When nil, derived from `resolution`.
    public var cellSize: Double? = nil
    /// Cells along the mesh's longest axis when `cellSize` is nil.
    public var resolution: Int = 24
    /// Cell budget for voxelization.
    public var maxCells: Int = VoxelGrid.defaultMaxCells
    /// Erode surfaces lining internal passages and cavities too
    /// (default true). When false, only sky-visible (external)
    /// surface cells erode.
    public var includeInternalSurfaces: Bool = true
    /// Rate floor for glancing surfaces, as a fraction of the head-on
    /// rate (0…1, default 0.25). See model notes.
    public var glancingFactor: Double = 0.25

    public init(material: SimMaterial) {
        self.material = material
    }
}

/// One entry of the erosion time series (the series starts with a
/// t = 0 record of zeros).
public struct ErosionStepRecord: Equatable {
    /// Simulated time at the end of this step, s.
    public var timeSeconds: Double
    /// Cells removed from the start of the run through this step.
    public var cellsRemovedCumulative: Int
    /// Mass lost from the start of the run through this step, g.
    public var massLossGrams: Double

    public init(timeSeconds: Double, cellsRemovedCumulative: Int, massLossGrams: Double) {
        self.timeSeconds = timeSeconds
        self.cellsRemovedCumulative = cellsRemovedCumulative
        self.massLossGrams = massLossGrams
    }
}

public struct ErosionResult {
    /// The eroded shape as a kit `Mesh` (surface of the final solid
    /// mask, extracted by `MeshExtraction` from a mask-built
    /// `VoxelGrid`).
    public var erodedMesh: Mesh
    /// Final solid mask in the grid's flat-index space (row-major,
    /// x fastest — same convention as `VoxelGrid.flatIndex`), so a
    /// caller can re-extract or post-process the eroded grid.
    public var solidMask: [Bool]
    /// Grid geometry of `solidMask` / `depthPerCell`: origin (mm),
    /// cell size (mm), and cell counts per axis.
    public var gridOrigin: Vec3
    public var cellSize: Double
    public var nx: Int
    public var ny: Int
    public var nz: Int
    /// Solid volume before / after erosion, mm³ (voxel counts × cell
    /// volume).
    public var originalSolidVolumeMM3: Double
    public var erodedSolidVolumeMM3: Double
    /// Mass lost to erosion, g, and as a percentage of the original
    /// solid mass (material density × original solid volume).
    public var massLossGrams: Double
    public var massLossPercent: Double
    /// Number of cells peeled away over the whole run.
    public var cellsRemoved: Int
    /// Largest accumulated depth anywhere, mm, and the centre (mm) of
    /// the cell that reached it (nil when nothing eroded).
    public var maxErosionDepthMM: Double
    public var maxErosionDepthLocation: Vec3?
    /// Per-cell accumulated erosion depth, mm, in flat-index space.
    /// See "DEPTH MAP" in the model notes for the exact semantics.
    public var depthPerCell: [Double]
    /// Time series, starting with the t = 0 zero record.
    public var steps: [ErosionStepRecord]

    public init(erodedMesh: Mesh, solidMask: [Bool], gridOrigin: Vec3,
                cellSize: Double, nx: Int, ny: Int, nz: Int,
                originalSolidVolumeMM3: Double, erodedSolidVolumeMM3: Double,
                massLossGrams: Double, massLossPercent: Double,
                cellsRemoved: Int, maxErosionDepthMM: Double,
                maxErosionDepthLocation: Vec3?, depthPerCell: [Double],
                steps: [ErosionStepRecord]) {
        self.erodedMesh = erodedMesh
        self.solidMask = solidMask
        self.gridOrigin = gridOrigin
        self.cellSize = cellSize
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.originalSolidVolumeMM3 = originalSolidVolumeMM3
        self.erodedSolidVolumeMM3 = erodedSolidVolumeMM3
        self.massLossGrams = massLossGrams
        self.massLossPercent = massLossPercent
        self.cellsRemoved = cellsRemoved
        self.maxErosionDepthMM = maxErosionDepthMM
        self.maxErosionDepthLocation = maxErosionDepthLocation
        self.depthPerCell = depthPerCell
        self.steps = steps
    }

    /// Row-major flat index matching `solidMask` / `depthPerCell`.
    public func flatIndex(x: Int, y: Int, z: Int) -> Int { (z * ny + y) * nx + x }
}

// MARK: - Study

public enum WaterErosion {

    /// Run an erosion study over `mesh`.
    /// - Throws: `SimError.emptyMesh` (from voxelization),
    ///   `.zeroDirection` for a zero flow direction, `.nonFiniteValue`
    ///   / `.invalidValue` for bad config values,
    ///   `.cellBudgetExceeded` when the grid exceeds the budget.
    public static func run(mesh: Mesh, config: ErosionConfig) throws -> ErosionResult {
        let flowDir = try validated(config: config)

        let grid: VoxelGrid
        if let h = config.cellSize {
            grid = try VoxelGrid(mesh: mesh, cellSize: h, maxCells: config.maxCells)
        } else {
            grid = try VoxelGrid(mesh: mesh, resolution: config.resolution,
                                 maxCells: config.maxCells)
        }
        let nx = grid.nx, ny = grid.ny, nz = grid.nz, h = grid.cellSize
        let total = grid.cellCount

        // Working mask (the grid itself is immutable, so erosion
        // peels cells in this copy).
        var mask = [Bool](repeating: false, count: total)
        for idx in 0..<total { mask[idx] = grid.kind(at: idx) == .solid }
        func solidAt(_ x: Int, _ y: Int, _ z: Int) -> Bool {
            guard grid.isInBounds(x: x, y: y, z: z) else { return false }
            return mask[grid.flatIndex(x: x, y: y, z: z)]
        }

        // Rate scale (everything except the per-cell incidence
        // factor): K · S / R, mm/s.
        let speedFactor = config.scaleByDynamicPressure
            ? config.waterDensity * config.flowSpeed * config.flowSpeed / 1000.0
            : config.flowSpeed * config.flowSpeed
        let baseRate = config.erosionCoefficient * speedFactor / config.material.erosionResistance
        let g = config.glancingFactor

        // Mass bookkeeping: one cell = cellVolume mm³ = cellVolume·1e-3
        // cm³, times density g/cm³.
        let cellMassGrams = grid.cellVolume * 1e-3 * config.material.densityGCm3
        let originalMassGrams = Double(grid.solidCellCount) * cellMassGrams

        var depth = [Double](repeating: 0, count: total)
        var removedTotal = 0
        var massLoss = 0.0
        let dt = config.durationSeconds / Double(config.stepCount)
        var records: [ErosionStepRecord] = [
            ErosionStepRecord(timeSeconds: 0, cellsRemovedCumulative: 0, massLossGrams: 0)
        ]

        let offsets = [(1, 0, 0), (-1, 0, 0), (0, 1, 0),
                       (0, -1, 0), (0, 0, 1), (0, 0, -1)]

        if config.flowSpeed > 0 && baseRate > 0 && grid.solidCellCount > 0 {
            for step in 1...config.stepCount {
                var toRemove: [Int] = []
                for k in 0..<nz {
                    for j in 0..<ny {
                        for i in 0..<nx where solidAt(i, j, k) {
                            // Surface? (any non-solid 6-neighbor)
                            var isSurface = false
                            for o in offsets where !solidAt(i + o.0, j + o.1, k + o.2) {
                                isSurface = true
                                break
                            }
                            guard isSurface else { continue }
                            let idx = grid.flatIndex(x: i, y: j, z: k)

                            // Outward normal from the mask gradient.
                            let gx = (solidAt(i - 1, j, k) ? 1.0 : 0.0) - (solidAt(i + 1, j, k) ? 1.0 : 0.0)
                            let gy = (solidAt(i, j - 1, k) ? 1.0 : 0.0) - (solidAt(i, j + 1, k) ? 1.0 : 0.0)
                            let gz = (solidAt(i, j, k - 1) ? 1.0 : 0.0) - (solidAt(i, j, k + 1) ? 1.0 : 0.0)
                            var n = Vec3(gx, gy, gz)
                            if n.length < 1e-12 {
                                n = flowDir * -1   // isolated cell: faces the flow
                            } else {
                                n = n.normalized
                            }

                            // The void cell this surface faces:
                            // the non-solid 6-neighbor most aligned
                            // with the outward normal. Both marches
                            // start there, in the fluid.
                            var porch = (i, j, k)
                            var bestAlignment = -Double.infinity
                            for o in offsets where !solidAt(i + o.0, j + o.1, k + o.2) {
                                let alignment = Vec3(Double(o.0), Double(o.1), Double(o.2)).dot(n)
                                if alignment > bestAlignment {
                                    bestAlignment = alignment
                                    porch = (i + o.0, j + o.1, k + o.2)
                                }
                            }
                            let porchCenter = grid.cellCenter(x: porch.0, y: porch.1, z: porch.2)

                            // Internal surfaces are opt-out: internal
                            // = the sky march along the normal, from
                            // the porch, hits solid before exiting.
                            if !config.includeInternalSurfaces {
                                if marchHitsSolid(grid: grid, from: porchCenter,
                                                  direction: n, isSolid: solidAt) {
                                    continue   // cannot see the sky ⇒ internal
                                }
                            }

                            // Shielding: upstream march from the porch.
                            if marchHitsSolid(grid: grid, from: porchCenter,
                                              direction: flowDir * -1, isSolid: solidAt) {
                                continue   // shielded
                            }

                            let incidence = max(0, -(flowDir.dot(n)))
                            let rate = baseRate * (g + (1 - g) * incidence)
                            depth[idx] += rate * dt
                            if depth[idx] >= h { toRemove.append(idx) }
                        }
                    }
                }
                for idx in toRemove {
                    mask[idx] = false
                    removedTotal += 1
                    massLoss += cellMassGrams
                }
                records.append(ErosionStepRecord(timeSeconds: dt * Double(step),
                                                 cellsRemovedCumulative: removedTotal,
                                                 massLossGrams: massLoss))
            }
        } else {
            // Zero flow (or zero coefficient): a valid run that
            // erodes nothing, with a full-length zero time series.
            for step in 1...config.stepCount {
                records.append(ErosionStepRecord(timeSeconds: dt * Double(step),
                                                 cellsRemovedCumulative: 0,
                                                 massLossGrams: 0))
            }
        }

        // Deepest cell (flat order — first maximum wins, deterministic).
        var maxDepth = 0.0
        var maxIdx = -1
        for idx in 0..<total where depth[idx] > maxDepth {
            maxDepth = depth[idx]
            maxIdx = idx
        }
        let maxLocation: Vec3?
        if maxIdx >= 0 {
            let i = maxIdx % nx
            let j = (maxIdx / nx) % ny
            let k = maxIdx / (nx * ny)
            maxLocation = grid.cellCenter(x: i, y: j, z: k)
        } else {
            maxLocation = nil
        }

        let finalSolidCount = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
        let erodedGrid = try VoxelGrid(origin: grid.origin, cellSize: h,
                                       solidMask: mask, nx: nx, ny: ny, nz: nz)
        let erodedMesh = MeshExtraction.surfaceMesh(of: erodedGrid)

        return ErosionResult(
            erodedMesh: erodedMesh,
            solidMask: mask,
            gridOrigin: grid.origin,
            cellSize: h,
            nx: nx, ny: ny, nz: nz,
            originalSolidVolumeMM3: grid.solidVolume,
            erodedSolidVolumeMM3: Double(finalSolidCount) * grid.cellVolume,
            massLossGrams: massLoss,
            massLossPercent: originalMassGrams > 0 ? 100 * massLoss / originalMassGrams : 0,
            cellsRemoved: removedTotal,
            maxErosionDepthMM: maxDepth,
            maxErosionDepthLocation: maxLocation,
            depthPerCell: depth,
            steps: records)
    }

    // MARK: Validation

    /// Checks the config and returns the unit flow direction.
    private static func validated(config: ErosionConfig) throws -> Vec3 {
        guard config.flowDirection.isFinite() else {
            throw SimError.nonFiniteValue(parameter: "flowDirection")
        }
        guard config.flowDirection.length > 1e-12 else {
            throw SimError.zeroDirection(context: "flow")
        }
        guard config.flowSpeed.isFinite else {
            throw SimError.nonFiniteValue(parameter: "flowSpeed")
        }
        guard config.flowSpeed >= 0 else {
            throw SimError.invalidValue(parameter: "flowSpeed", detail: "speed must be ≥ 0 m/s")
        }
        guard config.waterDensity.isFinite else {
            throw SimError.nonFiniteValue(parameter: "waterDensity")
        }
        guard config.waterDensity > 0 else {
            throw SimError.invalidValue(parameter: "waterDensity", detail: "density must be > 0 kg/m³")
        }
        guard config.erosionCoefficient.isFinite else {
            throw SimError.nonFiniteValue(parameter: "erosionCoefficient")
        }
        guard config.erosionCoefficient >= 0 else {
            throw SimError.invalidValue(parameter: "erosionCoefficient", detail: "coefficient must be ≥ 0")
        }
        guard config.durationSeconds.isFinite else {
            throw SimError.nonFiniteValue(parameter: "durationSeconds")
        }
        guard config.durationSeconds > 0 else {
            throw SimError.invalidValue(parameter: "durationSeconds", detail: "duration must be > 0 s")
        }
        guard config.stepCount >= 1 && config.stepCount <= 100_000 else {
            throw SimError.invalidValue(parameter: "stepCount", detail: "step count must be 1…100000")
        }
        guard config.glancingFactor.isFinite else {
            throw SimError.nonFiniteValue(parameter: "glancingFactor")
        }
        guard config.glancingFactor >= 0 && config.glancingFactor <= 1 else {
            throw SimError.invalidValue(parameter: "glancingFactor", detail: "glancing factor must be 0…1")
        }
        if let h = config.cellSize {
            guard h.isFinite else { throw SimError.nonFiniteValue(parameter: "cellSize") }
            guard h > 0 else {
                throw SimError.invalidValue(parameter: "cellSize", detail: "must be > 0 mm")
            }
        }
        guard config.resolution >= 1 else {
            throw SimError.invalidValue(parameter: "resolution", detail: "must be ≥ 1")
        }
        guard config.maxCells >= 1 else {
            throw SimError.invalidValue(parameter: "maxCells", detail: "budget must be ≥ 1")
        }
        guard config.material.erosionResistance.isFinite else {
            throw SimError.nonFiniteValue(parameter: "material.erosionResistance")
        }
        guard config.material.erosionResistance > 0 else {
            throw SimError.invalidValue(parameter: "material.erosionResistance",
                                        detail: "resistance must be > 0 (it divides the wear rate)")
        }
        guard config.material.densityGCm3.isFinite else {
            throw SimError.nonFiniteValue(parameter: "material.densityGCm3")
        }
        guard config.material.densityGCm3 > 0 else {
            throw SimError.invalidValue(parameter: "material.densityGCm3", detail: "density must be > 0 g/cm³")
        }
        return config.flowDirection.normalized
    }

    // MARK: Marching

    /// March from `center` along the unit `direction` in steps of one
    /// cell. Returns true when a solid cell is met before the march
    /// leaves the grid region inflated by one cell on every side;
    /// false when the march exits (or, defensively, exhausts a step
    /// budget sized to cross the inflated grid diagonally).
    private static func marchHitsSolid(grid: VoxelGrid, from center: Vec3,
                                       direction: Vec3,
                                       isSolid: (Int, Int, Int) -> Bool) -> Bool {
        let h = grid.cellSize
        let maxSteps = grid.nx + grid.ny + grid.nz + 8
        for m in 1...maxSteps {
            let p = center + direction * (Double(m) * h)
            let fx = (p.x - grid.origin.x) / h
            let fy = (p.y - grid.origin.y) / h
            let fz = (p.z - grid.origin.z) / h
            if fx < -1 || fx > Double(grid.nx) ||
               fy < -1 || fy > Double(grid.ny) ||
               fz < -1 || fz > Double(grid.nz) {
                return false   // exited the inflated region
            }
            let i = Int(floor(fx)), j = Int(floor(fy)), k = Int(floor(fz))
            if grid.isInBounds(x: i, y: j, z: k) && isSolid(i, j, k) {
                return true
            }
        }
        return false
    }
}
