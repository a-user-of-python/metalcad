import Foundation

/// Outcome of a PCG solve. Non-convergence is *reported*, not thrown
/// (see `PCG` docs): `converged` says whether the tolerance was met,
/// and `x` holds the best iterate either way.
public struct PCGResult {
    public var x: [Double]
    public var iterations: Int
    /// Final residual norm ‖r‖₂ (absolute).
    public var residualNorm: Double
    /// Final ‖r‖₂ / ‖b‖₂ (0 when b is zero and r is zero).
    public var relativeResidual: Double
    public var converged: Bool

    public init(x: [Double], iterations: Int, residualNorm: Double,
                relativeResidual: Double, converged: Bool) {
        self.x = x
        self.iterations = iterations
        self.residualNorm = residualNorm
        self.relativeResidual = relativeResidual
        self.converged = converged
    }
}

/// A symmetric 3×3 matrix stored by its 6 unique entries — used as a
/// per-node block for the block-3 PCG preconditioner.
public struct Symmetric3x3: Equatable {
    public var m00: Double
    public var m01: Double
    public var m02: Double
    public var m11: Double
    public var m12: Double
    public var m22: Double

    public init(m00: Double, m01: Double, m02: Double,
                m11: Double, m12: Double, m22: Double) {
        self.m00 = m00; self.m01 = m01; self.m02 = m02
        self.m11 = m11; self.m12 = m12; self.m22 = m22
    }

    public static let identity = Symmetric3x3(m00: 1, m01: 0, m02: 0, m11: 1, m12: 0, m22: 1)

    /// The matrix inverse, or nil when (near-)singular.
    public func inverted() -> Symmetric3x3? {
        let det = m00 * (m11 * m22 - m12 * m12)
                - m01 * (m01 * m22 - m12 * m02)
                + m02 * (m01 * m12 - m11 * m02)
        guard det.isFinite, abs(det) > 1e-290 else { return nil }
        let s = 1 / det
        return Symmetric3x3(
            m00: (m11 * m22 - m12 * m12) * s,
            m01: (m02 * m12 - m01 * m22) * s,
            m02: (m01 * m12 - m02 * m11) * s,
            m11: (m00 * m22 - m02 * m02) * s,
            m12: (m02 * m01 - m00 * m12) * s,
            m22: (m00 * m11 - m01 * m01) * s)
    }

    /// M · v for a 3-vector stored at `offset` in a flat array.
    public func apply(_ v: [Double], at offset: Int, into out: inout [Double]) {
        let x = v[offset], y = v[offset + 1], z = v[offset + 2]
        out[offset]     = m00 * x + m01 * y + m02 * z
        out[offset + 1] = m01 * x + m11 * y + m12 * z
        out[offset + 2] = m02 * x + m12 * y + m22 * z
    }
}

/// Matrix-free preconditioned conjugate gradients for symmetric
/// positive-definite systems A·x = b. The operator is supplied as a
/// closure — no matrix is ever assembled — which is what lets the
/// stress/thermal solvers run element-by-element / stencil operators
/// at grid scale.
///
/// Contract:
/// - `apply` must be a *linear* operator (apply(0) = 0) of the given
///   size; its output must have the same count as its input.
/// - Convergence is relative: the solve stops when
///   ‖r‖₂ ≤ tolerance · ‖b‖₂ (with ‖b‖₂ = 0, it stops when ‖r‖₂ ≤
///   tolerance). The defaults (tolerance 1e-10, 10 000 iterations) suit
///   the package's grid systems; callers expose both as config.
/// - Exhausting `maxIterations` is **not** an error: the result comes
///   back with `converged == false` and the best `x`, and the calling
///   simulation decides whether that is fatal (throwing
///   `SimError.didNotConverge` is the intended pattern).
/// - `SimError.invalidSolverInput` *is* thrown for inconsistent
///   arguments (size mismatches, non-finite values, bad
///   preconditioner), and `SimError.operatorBreakdown` when the CG
///   recurrences collapse — the operator is not SPD on the Krylov
///   subspace (p·Ap ≤ 0, or ρ ≤ 0 from a non-SPD preconditioner).
///
/// Determinism: all reductions run in fixed index order, so identical
/// inputs give bit-identical iterates.
public enum PCG {

    /// Scalar PCG with an optional Jacobi (diagonal) preconditioner.
    /// - Parameters:
    ///   - size: number of unknowns (> 0).
    ///   - apply: the operator A as a closure over flat arrays.
    ///   - rhs: right-hand side b, `size` entries, all finite.
    ///   - preconditionerDiag: optional diagonal of A (the Jacobi
    ///     preconditioner applies 1/diag); every entry must be > 0.
    ///     nil = unpreconditioned CG.
    ///   - initialGuess: starting x (default: zeros).
    ///   - tolerance: relative residual target (see type docs).
    ///   - maxIterations: iteration cap.
    public static func solve(size: Int,
                             apply: ([Double]) -> [Double],
                             rhs: [Double],
                             preconditionerDiag: [Double]? = nil,
                             initialGuess: [Double]? = nil,
                             tolerance: Double = 1e-10,
                             maxIterations: Int = 10_000) throws -> PCGResult {
        var precondition: (([Double]) -> [Double])? = nil
        if let diag = preconditionerDiag {
            guard diag.count == size else {
                throw SimError.invalidSolverInput(detail: "preconditionerDiag has \(diag.count) entries, system size is \(size)")
            }
            for d in diag where !(d > 0) || !d.isFinite {
                throw SimError.invalidSolverInput(detail: "preconditioner diagonal entries must be positive and finite")
            }
            precondition = { r in
                var z = [Double](repeating: 0, count: size)
                for i in 0..<size { z[i] = r[i] / diag[i] }
                return z
            }
        }
        return try coreSolve(size: size, apply: apply, rhs: rhs,
                             precondition: precondition,
                             initialGuess: initialGuess,
                             tolerance: tolerance, maxIterations: maxIterations)
    }

    /// Block-3 PCG for systems with 3 DOF per node (e.g. FEA
    /// displacements): the unknown vector is `3 * nodeCount` long,
    /// laid out node-major (x, y, z per node). The preconditioner is
    /// one symmetric 3×3 block per node — typically the inverse of the
    /// node's diagonal stiffness block — applied exactly (blocks are
    /// inverted once up front; a singular block throws
    /// `SimError.invalidSolverInput`). nil blocks = unpreconditioned.
    public static func solveBlock3(nodeCount: Int,
                                   apply: ([Double]) -> [Double],
                                   rhs: [Double],
                                   preconditionerBlocks: [Symmetric3x3]? = nil,
                                   initialGuess: [Double]? = nil,
                                   tolerance: Double = 1e-10,
                                   maxIterations: Int = 10_000) throws -> PCGResult {
        guard nodeCount > 0 else {
            throw SimError.invalidSolverInput(detail: "nodeCount must be > 0")
        }
        let size = 3 * nodeCount
        var precondition: (([Double]) -> [Double])? = nil
        if let blocks = preconditionerBlocks {
            guard blocks.count == nodeCount else {
                throw SimError.invalidSolverInput(detail: "preconditionerBlocks has \(blocks.count) entries, nodeCount is \(nodeCount)")
            }
            var inverses: [Symmetric3x3] = []
            inverses.reserveCapacity(nodeCount)
            for (i, block) in blocks.enumerated() {
                guard let inv = block.inverted() else {
                    throw SimError.invalidSolverInput(detail: "preconditioner block \(i) is singular")
                }
                inverses.append(inv)
            }
            precondition = { r in
                var z = [Double](repeating: 0, count: size)
                for n in 0..<nodeCount {
                    inverses[n].apply(r, at: 3 * n, into: &z)
                }
                return z
            }
        }
        return try coreSolve(size: size, apply: apply, rhs: rhs,
                             precondition: precondition,
                             initialGuess: initialGuess,
                             tolerance: tolerance, maxIterations: maxIterations)
    }

    // MARK: Core

    private static func coreSolve(size: Int,
                                  apply: ([Double]) -> [Double],
                                  rhs: [Double],
                                  precondition: (([Double]) -> [Double])?,
                                  initialGuess: [Double]?,
                                  tolerance: Double,
                                  maxIterations: Int) throws -> PCGResult {
        guard size > 0 else {
            throw SimError.invalidSolverInput(detail: "system size must be > 0")
        }
        guard rhs.count == size else {
            throw SimError.invalidSolverInput(detail: "rhs has \(rhs.count) entries, system size is \(size)")
        }
        guard tolerance > 0, tolerance.isFinite else {
            throw SimError.invalidSolverInput(detail: "tolerance must be positive and finite")
        }
        guard maxIterations >= 0 else {
            throw SimError.invalidSolverInput(detail: "maxIterations must be ≥ 0")
        }
        for v in rhs where !v.isFinite {
            throw SimError.invalidSolverInput(detail: "rhs contains a non-finite value")
        }
        var x: [Double]
        if let guess = initialGuess {
            guard guess.count == size else {
                throw SimError.invalidSolverInput(detail: "initialGuess has \(guess.count) entries, system size is \(size)")
            }
            for v in guess where !v.isFinite {
                throw SimError.invalidSolverInput(detail: "initialGuess contains a non-finite value")
            }
            x = guess
        } else {
            x = [Double](repeating: 0, count: size)
        }

        func dot(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for i in 0..<size { s += a[i] * b[i] }
            return s
        }
        func norm(_ a: [Double]) -> Double { dot(a, a).squareRoot() }

        let bNorm = norm(rhs)
        let threshold = tolerance * (bNorm > 0 ? bNorm : 1)

        var r = rhs
        if x.contains(where: { $0 != 0 }) {
            let ax = apply(x)
            guard ax.count == size else {
                throw SimError.invalidSolverInput(detail: "operator returned \(ax.count) entries, expected \(size)")
            }
            for i in 0..<size { r[i] -= ax[i] }
        }
        var residual = norm(r)
        func result(_ iterations: Int, _ converged: Bool) -> PCGResult {
            PCGResult(x: x, iterations: iterations, residualNorm: residual,
                      relativeResidual: bNorm > 0 ? residual / bNorm : residual,
                      converged: converged)
        }
        if residual <= threshold { return result(0, true) }
        guard maxIterations > 0 else { return result(0, false) }

        var z = precondition?(r) ?? r
        var p = z
        var rho = dot(r, z)
        guard rho > 0, rho.isFinite else {
            throw SimError.operatorBreakdown(detail: "initial r·z = \(rho); preconditioner is not positive definite")
        }

        var iteration = 0
        while iteration < maxIterations {
            iteration += 1
            let q = apply(p)
            guard q.count == size else {
                throw SimError.invalidSolverInput(detail: "operator returned \(q.count) entries, expected \(size)")
            }
            let pq = dot(p, q)
            guard pq > 0, pq.isFinite else {
                throw SimError.operatorBreakdown(detail: "p·Ap = \(pq) at iteration \(iteration); operator is not positive definite")
            }
            let alpha = rho / pq
            for i in 0..<size {
                x[i] += alpha * p[i]
                r[i] -= alpha * q[i]
            }
            residual = norm(r)
            if residual <= threshold { return result(iteration, true) }
            if iteration == maxIterations { break }
            z = precondition?(r) ?? r
            let rhoNew = dot(r, z)
            guard rhoNew > 0, rhoNew.isFinite else {
                throw SimError.operatorBreakdown(detail: "r·z = \(rhoNew) at iteration \(iteration); preconditioner is not positive definite")
            }
            let beta = rhoNew / rho
            for i in 0..<size { p[i] = z[i] + beta * p[i] }
            rho = rhoNew
        }
        return result(iteration, false)
    }
}
