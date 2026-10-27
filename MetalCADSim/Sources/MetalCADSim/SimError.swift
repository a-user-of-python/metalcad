import Foundation

/// Every distinct failure in MetalCADSim. The `code` is stable forever:
/// never reused, never renumbered — same discipline as the kit's
/// `CADError`. Codes are prefixed `MSIM-` and grouped by domain:
///
/// - `CF` — configuration: a study/config value is nonsense.
/// - `GR` — grid: voxelization could not proceed within its budget.
/// - `SV` — solve: the iterative solver failed or was fed garbage.
/// - `IN` — input: the geometry/material handed to a study is unusable.
public enum SimError: Error, Equatable {
    // CF — configuration
    /// A config parameter is outside its valid range (zero/negative
    /// cell size, resolution, iteration cap, non-positive budget…).
    case invalidValue(parameter: String, detail: String)
    /// A config parameter is NaN or infinite where a finite value is
    /// required.
    case nonFiniteValue(parameter: String)

    // GR — grid
    /// The requested cell size / resolution would need more cells than
    /// the configured budget allows.
    case cellBudgetExceeded(cells: Int, budget: Int)
    /// The mesh bounds have no extent on any axis (a single point), so
    /// no grid can be laid over them.
    case degenerateBounds(detail: String)

    // SV — solve
    /// PCG exhausted its iteration cap above tolerance. Thrown by the
    /// simulation layer when a non-converged result is unacceptable;
    /// `PCG.solve` itself reports this via `PCGResult.converged`.
    case didNotConverge(residual: Double, iterations: Int)
    /// The operator/preconditioner broke the CG recurrences (p·Ap ≤ 0,
    /// ρ ≤ 0, non-finite intermediate): it is not symmetric positive
    /// definite on the Krylov subspace.
    case operatorBreakdown(detail: String)
    /// Solver arguments are inconsistent: wrong sizes, non-finite RHS,
    /// non-positive preconditioner entries, singular blocks.
    case invalidSolverInput(detail: String)

    // IN — input
    /// The mesh has no triangles.
    case emptyMesh
    /// No `SimMaterial` properties are known for this kit material name.
    case unknownMaterial(name: String)
    /// A direction vector is zero (or near enough) where a real
    /// direction is required — e.g. a wind/load direction.
    case zeroDirection(context: String)
    /// A user-selected face maps to nothing in the study: it does
    /// not resolve to a planar face of the mesh, or it resolves but
    /// touches no grid cells/nodes at this cell size (typically a
    /// face picked from a different part).
    case faceMatchedNoCells(context: String)

    public var code: String {
        switch self {
        case .invalidValue: return "MSIM-CF001"
        case .nonFiniteValue: return "MSIM-CF002"
        case .cellBudgetExceeded: return "MSIM-GR001"
        case .degenerateBounds: return "MSIM-GR002"
        case .didNotConverge: return "MSIM-SV001"
        case .operatorBreakdown: return "MSIM-SV002"
        case .invalidSolverInput: return "MSIM-SV003"
        case .emptyMesh: return "MSIM-IN001"
        case .unknownMaterial: return "MSIM-IN002"
        case .zeroDirection: return "MSIM-IN003"
        case .faceMatchedNoCells: return "MSIM-IN004"
        }
    }

    /// Plain-words message for the user. The code is shown separately.
    public var userMessage: String {
        switch self {
        case .invalidValue(let p, let d):
            return "The \(p) setting isn't usable (\(d))."
        case .nonFiniteValue(let p):
            return "The \(p) setting isn't a real number."
        case .cellBudgetExceeded(let cells, let budget):
            return "That detail level needs \(cells) grid cells, over the \(budget) budget. Use a larger cell size or raise the budget."
        case .degenerateBounds(let d):
            return "The shape has no size to simulate (\(d))."
        case .didNotConverge(let r, let n):
            return "The solver didn't settle after \(n) tries (leftover error \(String(format: "%.3g", r))). A coarser grid or looser tolerance may help."
        case .operatorBreakdown(let d):
            return "The solver hit a shape it can't solve (\(d))."
        case .invalidSolverInput(let d):
            return "The solver was handed inconsistent numbers (\(d))."
        case .emptyMesh:
            return "There's no shape to simulate yet."
        case .unknownMaterial(let n):
            return "No simulation data is known for the material \"\(n)\"."
        case .zeroDirection(let c):
            return "The \(c) direction is missing — pick a direction first."
        case .faceMatchedNoCells:
            return "The selected face doesn't touch this part."
        }
    }
}

/// All codes that exist — used by the test suite to prove distinctness.
public enum SimErrorCatalog {
    public static let allCodes: [String] = [
        "MSIM-CF001", "MSIM-CF002",
        "MSIM-GR001", "MSIM-GR002",
        "MSIM-SV001", "MSIM-SV002", "MSIM-SV003",
        "MSIM-IN001", "MSIM-IN002", "MSIM-IN003", "MSIM-IN004",
    ]
}
