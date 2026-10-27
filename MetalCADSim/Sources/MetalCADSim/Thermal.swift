import Foundation
import MetalCADKit

// MARK: - Thermal conduction on the voxel grid
//
// METHOD
// ------
// Cell-centered finite volumes on the foundation `VoxelGrid`. Each
// solid voxel is one control volume holding a single temperature (its
// center value). Heat moves between adjacent solid cells by conduction
// through their shared face:
//
//     G = k · A / d,   A = h², d = h   ⇒   G = k · h        (per pair)
//
// Boundary conditions attach to surface cells through a half-cell:
//   - fixed temperature: G_b = k · A / (h/2) = 2 · k · h to the face
//     temperature;
//   - convection: G = h_conv · A straight to the ambient temperature
//     (the task's rule — no half-cell series resistance);
//   - heat flux: a prescribed total wattage spread evenly over the
//     face's cells as a source term (no conductance).
//
// Volumetric heat generation q''' (W/m³) adds q'''·V_cell watts to
// every solid cell. An optional global ambient convection applies
// h·A on every exposed cell face that no face BC covers (the patch a
// face BC covers on a cell — the exposed faces whose outward direction
// matches the BC face's normal — is suppressed, so a conditioned face
// is never double-counted).
//
// UNITS
// -----
// The grid is in millimetres (kit convention); all conductances are
// computed in SI: lengths are converted mm → m, so k [W/(m·K)] ×
// areas [m²] / lengths [m] give W/K, sources are watts, heat capacity
// per cell is ρ [kg/m³] · c [J/(kg·K)] · V [m³]. Temperatures are °C
// throughout (a difference in °C equals a difference in K).
//
// SOLVERS
// -------
// Steady state is the linear system A·T = b with the stencil above,
// solved matrix-free with the foundation scalar PCG (Jacobi
// preconditioner = the matrix diagonal, i.e. each row's conductance
// sum). Non-convergence throws `SimError.didNotConverge`
// (MSIM-SV001). A steady problem needs at least one temperature
// anchor (a fixed-temperature or convection boundary, face or
// global); pure flux/generation problems are singular and are
// rejected up front.
//
// Transient is explicit Euler,
//     T' = ( Σ G·(T_nb − T) + sources ) / (ρ·c·V_cell),
// stability-limited to dt ≤ ρcV / ΣG_max (the largest per-cell
// conductance sum). A larger requested step is auto-substepped
// (default) or rejected, per config.

// MARK: Boundary conditions

/// A boundary condition kind for one `PlanarFace`.
public enum ThermalBCKind: Equatable {
    /// The face is held at this temperature (°C).
    case fixedTemperature(celsius: Double)
    /// Total heat flow into the part across the whole face (W),
    /// distributed evenly over the face's selected cells.
    case heatFlux(watts: Double)
    /// Convection from the face to a fluid at `ambient` °C with film
    /// coefficient `coefficient` W/(m²·K).
    case convection(coefficient: Double, ambient: Double)
}

/// A boundary condition bound to one kit `PlanarFace`.
public struct ThermalFaceBC: Equatable {
    public var face: PlanarFace
    public var kind: ThermalBCKind
    public init(face: PlanarFace, kind: ThermalBCKind) {
        self.face = face
        self.kind = kind
    }
}

/// Global convection applied to every exposed surface that no face
/// BC covers. Off unless set on the config.
public struct ThermalAmbient: Equatable {
    /// Film coefficient h, W/(m²·K).
    public var coefficient: Double
    /// Ambient fluid temperature, °C.
    public var ambientC: Double
    public init(coefficient: Double, ambientC: Double) {
        self.coefficient = coefficient
        self.ambientC = ambientC
    }
}

/// Steady or transient run.
public enum ThermalMode: Equatable {
    case steady
    case transient
}

// MARK: Config

/// Everything a thermal study needs. All knobs are validated up
/// front; nonsense throws a `SimError` (CF domain) before any work.
public struct ThermalConfig {
    /// Simulation properties of the part's material.
    public var material: SimMaterial
    /// Grid cell size in mm. When nil, derived from `resolution`.
    public var cellSize: Double? = nil
    /// Cells along the mesh's longest axis when `cellSize` is nil.
    public var resolution: Int = 20
    /// Cell budget for voxelization.
    public var maxCells: Int = VoxelGrid.defaultMaxCells
    /// Per-face boundary conditions.
    public var faceBCs: [ThermalFaceBC] = []
    /// Optional global ambient convection (default nil = off).
    public var globalAmbient: ThermalAmbient? = nil
    /// Volumetric heat generation, W/m³ (negative = heat sink).
    public var heatGenerationWPerM3: Double = 0
    /// Steady-state or transient run.
    public var mode: ThermalMode = .steady

    // Transient knobs (ignored in steady mode).
    /// Total simulated time, s (must be > 0 in transient mode).
    public var duration: Double = 1
    /// Requested time step, s (must be > 0 in transient mode).
    public var timeStep: Double = 0.01
    /// When true (default), a step above the stability limit is
    /// split into stable substeps; when false it throws.
    public var autoSubstep: Bool = true
    /// Uniform starting temperature, °C (unless `initialFromSteady`).
    public var initialTemperatureC: Double = 20
    /// Start the transient from the steady-state solution of the
    /// same boundary conditions instead of a uniform temperature.
    public var initialFromSteady: Bool = false
    /// Number of evenly spaced snapshots to record (in addition to
    /// the final state, which is always in `temperaturePerCell`).
    /// 0 = none. The last snapshot is at t = duration.
    public var snapshotCount: Int = 0

    // Solver knobs (steady solve, and the optional initial steady).
    /// PCG relative-residual target.
    public var solverTolerance: Double = 1e-9
    /// PCG iteration cap; exceeding it throws MSIM-SV001.
    public var solverMaxIterations: Int = 10_000

    public init(material: SimMaterial) {
        self.material = material
    }
}

// MARK: Result

/// Outcome of a thermal run.
public struct ThermalResult {
    /// The grid the study ran on (cell ↔ world mapping, flat index
    /// space for the temperature arrays).
    public var grid: VoxelGrid
    /// Temperature per grid cell, in the grid's flat-index space
    /// ((z·ny + y)·nx + x). NaN for non-solid cells. °C.
    public var temperaturePerCell: [Double]
    /// Coldest / hottest solid-cell temperature, °C.
    public var minC: Double
    public var maxC: Double
    /// Volume-weighted mean over solid cells, °C (all cells have the
    /// same volume, so this is the plain mean over solid cells).
    public var averageC: Double
    /// Boundary heat flows at the end state: total watts flowing
    /// into the part across fixed-temperature / convection
    /// connections whose flow is inward, and total watts flowing out
    /// (positive number). Prescribed heat-flux BCs count toward
    /// `totalHeatFlowInW` when positive (out when negative).
    /// Volumetric generation is not a boundary flow and is excluded;
    /// at steady state in − out = generated watts.
    public var totalHeatFlowInW: Double
    public var totalHeatFlowOutW: Double
    /// Transient snapshots in time order (empty for steady runs).
    public var snapshots: [(time: Double, temperatures: [Double])]
    /// PCG iterations the (initial) steady solve took; 0 for a pure
    /// transient run from a uniform start.
    public var solverIterations: Int
    /// Inner time steps actually taken (transient; 0 for steady).
    public var timeStepsTaken: Int
    /// The stable inner time step used (transient; nil for steady).
    public var usedTimeStep: Double?
}

// MARK: Face → cell mapping

/// Selects the solid grid cells a `PlanarFace` boundary condition
/// applies to. The rule (documented per the study spec): a solid
/// cell is selected when
///   1. its center lies within `0.75 · h` of the face's plane
///      (|signed distance| along the plane normal), and
///   2. its center projected onto the plane falls inside the face's
///      `outline2D` polygon (the kit's `pointInPolygon`).
/// On an axis-aligned slab this selects exactly the surface layer of
/// cells under the face — the next layer's centers are 1.5·h from the
/// plane and fail rule 1 — which is what the known-answer tests pin.
public enum ThermalFaceMapping {
    public static func cells(of face: PlanarFace, in grid: VoxelGrid) -> [Int] {
        let h = grid.cellSize
        let limit = 0.75 * h
        let origin = face.plane.origin
        let normal = face.plane.normal
        let xAxis = face.plane.xAxis
        let yAxis = face.plane.yAxis
        var out: [Int] = []
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx where grid.isSolid(x: i, y: j, z: k) {
                    let c = grid.cellCenter(x: i, y: j, z: k)
                    let d = c - origin
                    let dist = d.dot(normal)
                    guard abs(dist) <= limit else { continue }
                    let q = Vec2(d.dot(xAxis), d.dot(yAxis))
                    guard face.outline2D.count < 3 || pointInPolygon(q, face.outline2D)
                    else { continue }
                    out.append(grid.flatIndex(x: i, y: j, z: k))
                }
            }
        }
        return out
    }
}

// MARK: Solver

public enum ThermalSimulation {

    /// Runs a thermal study. Throws `SimError` for invalid config
    /// (CF), voxelization budget problems (GR), a face BC that
    /// matches no cells (IN), an unanchored steady problem (CF), and
    /// steady-solver non-convergence (MSIM-SV001).
    public static func run(mesh: Mesh, config: ThermalConfig) throws -> ThermalResult {
        try validate(config)
        let grid: VoxelGrid
        if let h = config.cellSize {
            grid = try VoxelGrid(mesh: mesh, cellSize: h, maxCells: config.maxCells)
        } else {
            grid = try VoxelGrid(mesh: mesh, resolution: config.resolution,
                                 maxCells: config.maxCells)
        }
        guard grid.solidCellCount > 0 else {
            throw SimError.invalidValue(parameter: "mesh",
                                        detail: "voxelization produced no solid cells")
        }
        let system = try assemble(grid: grid, config: config)

        switch config.mode {
        case .steady:
            return try runSteady(grid: grid, config: config, system: system)
        case .transient:
            return try runTransient(grid: grid, config: config, system: system)
        }
    }

    // MARK: Validation

    private static func validate(_ config: ThermalConfig) throws {
        let m = config.material
        func finite(_ v: Double, _ p: String) throws {
            guard v.isFinite else { throw SimError.nonFiniteValue(parameter: p) }
        }
        guard m.thermalConductivity.isFinite else {
            throw SimError.nonFiniteValue(parameter: "material.thermalConductivity")
        }
        guard m.thermalConductivity > 0 else {
            throw SimError.invalidValue(parameter: "material.thermalConductivity",
                                        detail: "must be > 0 W/(m·K)")
        }
        guard m.specificHeat.isFinite, m.specificHeat > 0 else {
            throw SimError.invalidValue(parameter: "material.specificHeat",
                                        detail: "must be > 0 J/(kg·K)")
        }
        guard m.densityKgM3.isFinite, m.densityKgM3 > 0 else {
            throw SimError.invalidValue(parameter: "material.density",
                                        detail: "must be > 0")
        }
        if let h = config.cellSize {
            try finite(h, "cellSize")
            guard h > 0 else {
                throw SimError.invalidValue(parameter: "cellSize", detail: "must be > 0 mm")
            }
        }
        guard config.resolution > 0 else {
            throw SimError.invalidValue(parameter: "resolution", detail: "must be > 0")
        }
        try finite(config.heatGenerationWPerM3, "heatGenerationWPerM3")
        for (idx, bc) in config.faceBCs.enumerated() {
            switch bc.kind {
            case .fixedTemperature(let t):
                guard t.isFinite else {
                    throw SimError.nonFiniteValue(parameter: "faceBCs[\(idx)] temperature")
                }
            case .heatFlux(let w):
                guard w.isFinite else {
                    throw SimError.nonFiniteValue(parameter: "faceBCs[\(idx)] heatFlux")
                }
            case .convection(let hc, let amb):
                guard hc.isFinite, amb.isFinite else {
                    throw SimError.nonFiniteValue(parameter: "faceBCs[\(idx)] convection")
                }
                guard hc >= 0 else {
                    throw SimError.invalidValue(parameter: "faceBCs[\(idx)] convection coefficient",
                                                detail: "must be ≥ 0 W/(m²·K)")
                }
            }
        }
        if let amb = config.globalAmbient {
            guard amb.coefficient.isFinite, amb.ambientC.isFinite else {
                throw SimError.nonFiniteValue(parameter: "globalAmbient")
            }
            guard amb.coefficient >= 0 else {
                throw SimError.invalidValue(parameter: "globalAmbient coefficient",
                                            detail: "must be ≥ 0 W/(m²·K)")
            }
        }
        guard config.solverTolerance.isFinite, config.solverTolerance > 0 else {
            throw SimError.invalidValue(parameter: "solverTolerance", detail: "must be > 0")
        }
        guard config.solverMaxIterations > 0 else {
            throw SimError.invalidValue(parameter: "solverMaxIterations", detail: "must be > 0")
        }
        guard config.snapshotCount >= 0 else {
            throw SimError.invalidValue(parameter: "snapshotCount", detail: "must be ≥ 0")
        }
        guard config.initialTemperatureC.isFinite else {
            throw SimError.nonFiniteValue(parameter: "initialTemperatureC")
        }
        if config.mode == .transient {
            guard config.duration.isFinite else {
                throw SimError.nonFiniteValue(parameter: "duration")
            }
            guard config.duration > 0 else {
                throw SimError.invalidValue(parameter: "duration",
                                            detail: "must be > 0 s for a transient run")
            }
            guard config.timeStep.isFinite else {
                throw SimError.nonFiniteValue(parameter: "timeStep")
            }
            guard config.timeStep > 0 else {
                throw SimError.invalidValue(parameter: "timeStep", detail: "must be > 0 s")
            }
        }
    }

    // MARK: Assembly

    /// Everything the stencil needs, indexed by compact unknown
    /// number (solid cells only, in flat-index order).
    private struct Assembled {
        var unknownOfFlat: [Int]            // flat index → unknown, −1 if not solid
        var flatOfUnknown: [Int]
        var neighbors: [[Int]]              // per unknown: 6 neighbor unknowns, −1 = none
        var diag: [Double]                  // Σ conductances (interior + BC), W/K
        var neighborG: Double               // G between adjacent solid cells, W/K
        var bcRHS: [Double]                 // Σ G_bc · T_bc, W
        var sourceW: [Double]               // flux BCs + generation, W
        var connections: [(unknown: Int, g: Double, t: Double)]  // for end-state flows
        var fluxBCWatts: Double             // prescribed flux total (end-state flows)
        var anchored: Bool                  // any fixed-T / convection connection
        var maxConductanceSum: Double       // for the transient stability limit
        var cellHeatCapacity: Double        // ρ·c·V_cell, J/K
    }

    private static let dirOffsets = [(1, 0, 0), (-1, 0, 0), (0, 1, 0),
                                     (0, -1, 0), (0, 0, 1), (0, 0, -1)]
    private static let dirVectors = [Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0),
                                     Vec3(0, -1, 0), Vec3(0, 0, 1), Vec3(0, 0, -1)]

    private static func assemble(grid: VoxelGrid, config: ThermalConfig) throws -> Assembled {
        let mat = config.material
        let hM = grid.cellSize / 1000                 // cell size, m
        let areaM2 = hM * hM                          // face area, m²
        let volM3 = hM * hM * hM                      // cell volume, m³
        let k = mat.thermalConductivity
        let gNeighbor = k * hM                        // k·A/d with A = h², d = h
        let gFixed = 2 * k * hM                       // k·A/(h/2), half-cell

        var unknownOfFlat = [Int](repeating: -1, count: grid.cellCount)
        var flatOfUnknown: [Int] = []
        flatOfUnknown.reserveCapacity(grid.solidCellCount)
        for flat in 0..<grid.cellCount where grid.kind(at: flat) == .solid {
            unknownOfFlat[flat] = flatOfUnknown.count
            flatOfUnknown.append(flat)
        }
        let n = flatOfUnknown.count

        var neighbors = [[Int]](repeating: [Int](repeating: -1, count: 6), count: n)
        var diag = [Double](repeating: 0, count: n)
        var bcRHS = [Double](repeating: 0, count: n)
        var sourceW = [Double](repeating: 0, count: n)
        var connections: [(unknown: Int, g: Double, t: Double)] = []
        var anchored = false

        // Face BCs: map faces to cells (error when a face matches
        // nothing), apply conductances/sources, and record which
        // exposed cell faces they cover (for global-ambient
        // suppression): key = flat · 6 + direction.
        var coveredFaces = Set<Int>()
        var fluxBCWatts = 0.0
        for (idx, bc) in config.faceBCs.enumerated() {
            let flats = ThermalFaceMapping.cells(of: bc.face, in: grid)
            guard !flats.isEmpty else {
                throw SimError.faceMatchedNoCells(context: "faceBCs[\(idx)]")
            }
            let normal = bc.face.plane.normal
            for flat in flats {
                let u = unknownOfFlat[flat]
                for d in 0..<6 where dirVectors[d].dot(normal) > 0.5 {
                    coveredFaces.insert(flat * 6 + d)
                }
                switch bc.kind {
                case .fixedTemperature(let t):
                    diag[u] += gFixed
                    bcRHS[u] += gFixed * t
                    connections.append((u, gFixed, t))
                    anchored = true
                case .convection(let hc, let amb):
                    let g = hc * areaM2
                    if g > 0 {
                        diag[u] += g
                        bcRHS[u] += g * amb
                        connections.append((u, g, amb))
                        anchored = true
                    }
                case .heatFlux(let w):
                    sourceW[u] += w / Double(flats.count)
                    fluxBCWatts += w / Double(flats.count)
                }
            }
        }

        // Global ambient convection on uncovered exposed faces.
        if let amb = config.globalAmbient, amb.coefficient > 0 {
            let g = amb.coefficient * areaM2
            for u in 0..<n {
                let flat = flatOfUnknown[u]
                let i = flat % grid.nx
                let j = (flat / grid.nx) % grid.ny
                let l = flat / (grid.nx * grid.ny)
                for d in 0..<6 {
                    let (di, dj, dk) = dirOffsets[d]
                    guard grid.kind(x: i + di, y: j + dj, z: l + dk) != .solid else { continue }
                    guard !coveredFaces.contains(flat * 6 + d) else { continue }
                    diag[u] += g
                    bcRHS[u] += g * amb.ambientC
                    connections.append((u, g, amb.ambientC))
                    anchored = true
                }
            }
        }

        // Interior conduction + generation.
        let genW = config.heatGenerationWPerM3 * volM3
        var maxSum = 0.0
        for u in 0..<n {
            let flat = flatOfUnknown[u]
            let i = flat % grid.nx
            let j = (flat / grid.nx) % grid.ny
            let l = flat / (grid.nx * grid.ny)
            var sum = diag[u]
            for d in 0..<6 {
                let (di, dj, dk) = dirOffsets[d]
                let (a, b, c) = (i + di, j + dj, l + dk)
                guard grid.isInBounds(x: a, y: b, z: c) else { continue }
                let nf = grid.flatIndex(x: a, y: b, z: c)
                let nu = unknownOfFlat[nf]
                if nu >= 0 {
                    neighbors[u][d] = nu
                    sum += gNeighbor
                }
            }
            diag[u] = sum
            sourceW[u] += genW
            if sum > maxSum { maxSum = sum }
        }

        return Assembled(unknownOfFlat: unknownOfFlat, flatOfUnknown: flatOfUnknown,
                         neighbors: neighbors, diag: diag, neighborG: gNeighbor,
                         bcRHS: bcRHS, sourceW: sourceW, connections: connections,
                         fluxBCWatts: fluxBCWatts, anchored: anchored,
                         maxConductanceSum: maxSum,
                         cellHeatCapacity: mat.densityKgM3 * mat.specificHeat * volM3)
    }

    // MARK: Steady

    private static func solveSteady(config: ThermalConfig,
                                    system: Assembled) throws -> PCGResult {
        guard system.anchored else {
            throw SimError.invalidValue(
                parameter: "faceBCs",
                detail: "a steady run needs at least one fixed-temperature or convection boundary to anchor the temperatures")
        }
        let n = system.flatOfUnknown.count
        // Isolated cells (no conduction path and no BC) make the
        // Jacobi diagonal zero, which PCG rejects. Give them a unit
        // diagonal pinned to the initial temperature: they carry no
        // heat, so any value is a valid solution; the initial
        // temperature is the least surprising one.
        var diag = system.diag
        var rhs = [Double](repeating: 0, count: n)
        for u in 0..<n {
            rhs[u] = system.bcRHS[u] + system.sourceW[u]
            if diag[u] == 0 {
                diag[u] = 1
                rhs[u] = config.initialTemperatureC
            }
        }
        let neighbors = system.neighbors
        let g = system.neighborG
        let result = try PCG.solve(
            size: n,
            apply: { x in
                var y = [Double](repeating: 0, count: n)
                for u in 0..<n {
                    var acc = diag[u] * x[u]
                    for d in 0..<6 {
                        let v = neighbors[u][d]
                        if v >= 0 { acc -= g * x[v] }
                    }
                    y[u] = acc
                }
                return y
            },
            rhs: rhs,
            preconditionerDiag: diag,
            tolerance: config.solverTolerance,
            maxIterations: config.solverMaxIterations)
        guard result.converged else {
            throw SimError.didNotConverge(residual: result.residualNorm,
                                          iterations: result.iterations)
        }
        return result
    }

    private static func runSteady(grid: VoxelGrid, config: ThermalConfig,
                                  system: Assembled) throws -> ThermalResult {
        let solved = try solveSteady(config: config, system: system)
        let flat = expand(solved.x, system: system, grid: grid)
        return makeResult(grid: grid, system: system, flatTemps: flat,
                          snapshots: [], solverIterations: solved.iterations,
                          steps: 0, usedDt: nil)
    }

    // MARK: Transient

    private static func runTransient(grid: VoxelGrid, config: ThermalConfig,
                                     system: Assembled) throws -> ThermalResult {
        let n = system.flatOfUnknown.count
        var temps: [Double]
        var solverIterations = 0
        if config.initialFromSteady {
            let solved = try solveSteady(config: config, system: system)
            solverIterations = solved.iterations
            temps = solved.x
        } else {
            temps = [Double](repeating: config.initialTemperatureC, count: n)
        }

        // Stability limit and step plan.
        let cap = system.cellHeatCapacity
        let dtLimit = system.maxConductanceSum > 0 ? cap / system.maxConductanceSum
                                                   : Double.infinity
        let macroSteps = max(1, Int(ceil(config.duration / config.timeStep)))
        let macroDt = config.duration / Double(macroSteps)
        var subSteps = 1
        if macroDt > dtLimit {
            guard config.autoSubstep else {
                throw SimError.invalidValue(
                    parameter: "timeStep",
                    detail: "step \(macroDt) s exceeds the explicit stability limit \(dtLimit) s for this grid/material; enable autoSubstep or use a smaller step")
            }
            subSteps = Int(ceil(macroDt / dtLimit))
        }
        let dt = macroDt / Double(subSteps)

        // Snapshot schedule: after macro steps round(duration·i/count
        // / macroDt), i = 1...count.
        var snapshotAfterStep = Set<Int>()
        if config.snapshotCount > 0 {
            for i in 1...config.snapshotCount {
                let step = Int((Double(i) / Double(config.snapshotCount)
                                * Double(macroSteps)).rounded())
                snapshotAfterStep.insert(min(max(step, 1), macroSteps))
            }
        }
        var snapshots: [(time: Double, temperatures: [Double])] = []

        let neighbors = system.neighbors
        let diag = system.diag
        let g = system.neighborG
        var next = temps
        var stepsTaken = 0
        for step in 1...macroSteps {
            for _ in 0..<subSteps {
                for u in 0..<n {
                    var flux = system.bcRHS[u] + system.sourceW[u] - diag[u] * temps[u]
                    for d in 0..<6 {
                        let v = neighbors[u][d]
                        if v >= 0 { flux += g * temps[v] }
                    }
                    next[u] = temps[u] + dt * flux / cap
                }
                swap(&temps, &next)
                stepsTaken += 1
            }
            if snapshotAfterStep.contains(step) {
                snapshots.append((time: Double(step) * macroDt,
                                  temperatures: expand(temps, system: system, grid: grid)))
            }
        }

        let flat = expand(temps, system: system, grid: grid)
        return makeResult(grid: grid, system: system, flatTemps: flat,
                          snapshots: snapshots, solverIterations: solverIterations,
                          steps: stepsTaken, usedDt: dt)
    }

    // MARK: Result plumbing

    private static func expand(_ unknownTemps: [Double], system: Assembled,
                               grid: VoxelGrid) -> [Double] {
        var flat = [Double](repeating: Double.nan, count: grid.cellCount)
        for u in 0..<unknownTemps.count {
            flat[system.flatOfUnknown[u]] = unknownTemps[u]
        }
        return flat
    }

    private static func makeResult(grid: VoxelGrid, system: Assembled,
                                   flatTemps: [Double],
                                   snapshots: [(time: Double, temperatures: [Double])],
                                   solverIterations: Int, steps: Int,
                                   usedDt: Double?) -> ThermalResult {
        var minC = Double.infinity
        var maxC = -Double.infinity
        var sum = 0.0
        var count = 0
        for t in flatTemps where t.isFinite {
            if t < minC { minC = t }
            if t > maxC { maxC = t }
            sum += t
            count += 1
        }
        // End-state boundary flows over the recorded connections.
        var flowIn = max(system.fluxBCWatts, 0)
        var flowOut = max(-system.fluxBCWatts, 0)
        for c in system.connections {
            let tCell = flatTemps[system.flatOfUnknown[c.unknown]]
            let q = c.g * (c.t - tCell)
            if q > 0 { flowIn += q } else { flowOut -= q }
        }
        return ThermalResult(grid: grid,
                             temperaturePerCell: flatTemps,
                             minC: count > 0 ? minC : .nan,
                             maxC: count > 0 ? maxC : .nan,
                             averageC: count > 0 ? sum / Double(count) : .nan,
                             totalHeatFlowInW: flowIn,
                             totalHeatFlowOutW: flowOut,
                             snapshots: snapshots,
                             solverIterations: solverIterations,
                             timeStepsTaken: steps,
                             usedTimeStep: usedDt)
    }
}
