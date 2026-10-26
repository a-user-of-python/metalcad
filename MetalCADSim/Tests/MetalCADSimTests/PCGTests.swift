import XCTest
@testable import MetalCADSim

final class PCGTests: XCTestCase {

    /// 7-point Poisson stencil on an n×n×n grid (diag 6, −1 per
    /// in-grid neighbor; missing neighbors are Dirichlet boundary).
    private func poissonOperator(n: Int) -> (size: Int, apply: ([Double]) -> [Double]) {
        let size = n * n * n
        func idx(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * n + j) * n + i }
        let apply: ([Double]) -> [Double] = { x in
            var y = [Double](repeating: 0, count: size)
            for k in 0..<n {
                for j in 0..<n {
                    for i in 0..<n {
                        var v = 6 * x[idx(i, j, k)]
                        if i > 0 { v -= x[idx(i - 1, j, k)] }
                        if i < n - 1 { v -= x[idx(i + 1, j, k)] }
                        if j > 0 { v -= x[idx(i, j - 1, k)] }
                        if j < n - 1 { v -= x[idx(i, j + 1, k)] }
                        if k > 0 { v -= x[idx(i, j, k - 1)] }
                        if k < n - 1 { v -= x[idx(i, j, k + 1)] }
                        y[idx(i, j, k)] = v
                    }
                }
            }
            return y
        }
        return (size, apply)
    }

    private func manufacturedX(size: Int) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(size)
        for i in 0..<size {
            let a = sin(Double(i) * 1.3)
            let b = 0.5 * cos(Double(i) * 0.31)
            let c = 0.25 * Double(i % 7)
            out.append(a + b + c)
        }
        return out
    }

    private func maxError(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    func testPoissonManufacturedSolution() throws {
        let (size, apply) = poissonOperator(n: 4)
        let xTrue = manufacturedX(size: size)
        let rhs = apply(xTrue)
        let result = try PCG.solve(size: size, apply: apply, rhs: rhs,
                                   preconditionerDiag: [Double](repeating: 6, count: size),
                                   tolerance: 1e-12, maxIterations: 1000)
        XCTAssertTrue(result.converged, "residual \(result.residualNorm) after \(result.iterations) iterations")
        XCTAssertLessThan(maxError(result.x, xTrue), 1e-8)
        XCTAssertLessThan(result.relativeResidual, 1e-12)
    }

    func testUnpreconditionedAlsoConverges() throws {
        let (size, apply) = poissonOperator(n: 4)
        let xTrue = manufacturedX(size: size)
        let rhs = apply(xTrue)
        let result = try PCG.solve(size: size, apply: apply, rhs: rhs, tolerance: 1e-12)
        XCTAssertTrue(result.converged)
        XCTAssertLessThan(maxError(result.x, xTrue), 1e-8)
    }

    func testDiagonalSystemExactWithJacobi() throws {
        let size = 50
        let diag = (0..<size).map { Double($0 + 1) }
        let apply: ([Double]) -> [Double] = { x in zip(x, diag).map { $0 * $1 } }
        let xTrue = manufacturedX(size: size)
        let rhs = apply(xTrue)
        let result = try PCG.solve(size: size, apply: apply, rhs: rhs,
                                   preconditionerDiag: diag, tolerance: 1e-13)
        XCTAssertTrue(result.converged)
        XCTAssertEqual(result.iterations, 1, "Jacobi on a diagonal system converges in one step")
        XCTAssertLessThan(maxError(result.x, xTrue), 1e-10)
    }

    func testZeroRightHandSide() throws {
        let (size, apply) = poissonOperator(n: 3)
        let result = try PCG.solve(size: size, apply: apply, rhs: [Double](repeating: 0, count: size))
        XCTAssertTrue(result.converged)
        XCTAssertEqual(result.iterations, 0)
        XCTAssertTrue(result.x.allSatisfy { $0 == 0 })
    }

    func testNonConvergenceIsReportedNotThrown() throws {
        let (size, apply) = poissonOperator(n: 4)
        let rhs = apply(manufacturedX(size: size))
        let result = try PCG.solve(size: size, apply: apply, rhs: rhs,
                                   tolerance: 1e-14, maxIterations: 2)
        XCTAssertFalse(result.converged)
        XCTAssertEqual(result.iterations, 2)
        XCTAssertGreaterThan(result.residualNorm, 0)
    }

    func testBlock3ManufacturedSolution() throws {
        // 3×3×3 nodes; per-node SPD block B, weak symmetric coupling
        // to grid neighbors (strictly diagonally dominant ⇒ SPD).
        let n = 3
        let nodeCount = n * n * n
        let block = Symmetric3x3(m00: 4, m01: 0.5, m02: 0, m11: 4, m12: 0.5, m22: 4)
        func nidx(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * n + j) * n + i }
        let apply: ([Double]) -> [Double] = { x in
            var y = [Double](repeating: 0, count: 3 * nodeCount)
            for k in 0..<n {
                for j in 0..<n {
                    for i in 0..<n {
                        let node = nidx(i, j, k)
                        block.apply(x, at: 3 * node, into: &y)
                        for (di, dj, dk) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                            let (a, b, c) = (i + di, j + dj, k + dk)
                            guard a >= 0, b >= 0, c >= 0, a < n, b < n, c < n else { continue }
                            let other = 3 * nidx(a, b, c)
                            for comp in 0..<3 { y[3 * node + comp] -= 0.2 * x[other + comp] }
                        }
                    }
                }
            }
            return y
        }
        let size = 3 * nodeCount
        let xTrue = manufacturedX(size: size)
        let rhs = apply(xTrue)
        let result = try PCG.solveBlock3(nodeCount: nodeCount, apply: apply, rhs: rhs,
                                         preconditionerBlocks: [Symmetric3x3](repeating: block, count: nodeCount),
                                         tolerance: 1e-12, maxIterations: 1000)
        XCTAssertTrue(result.converged, "residual \(result.residualNorm)")
        XCTAssertLessThan(maxError(result.x, xTrue), 1e-8)
    }

    func testSymmetric3x3Inverse() {
        let m = Symmetric3x3(m00: 4, m01: 1, m02: 0.5, m11: 3, m12: -0.25, m22: 2)
        let inv = m.inverted()
        XCTAssertNotNil(inv)
        // M · M⁻¹ column-wise ≈ I.
        for col in 0..<3 {
            var basis = [Double](repeating: 0, count: 3)
            basis[col] = 1
            var step = [Double](repeating: 0, count: 3)
            inv!.apply(basis, at: 0, into: &step)
            var product = [Double](repeating: 0, count: 3)
            m.apply(step, at: 0, into: &product)
            XCTAssertEqual(product[col], 1, accuracy: 1e-12)
            for row in 0..<3 where row != col {
                XCTAssertEqual(product[row], 0, accuracy: 1e-12)
            }
        }
        XCTAssertNil(Symmetric3x3(m00: 0, m01: 0, m02: 0, m11: 0, m12: 0, m22: 0).inverted())
    }

    func testInvalidInputsThrow() {
        let identity: ([Double]) -> [Double] = { $0 }
        XCTAssertThrowsError(try PCG.solve(size: 4, apply: identity, rhs: [1, 2])) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-SV003")
        }
        XCTAssertThrowsError(try PCG.solve(size: 2, apply: identity, rhs: [1, .nan])) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-SV003")
        }
        XCTAssertThrowsError(try PCG.solve(size: 2, apply: identity, rhs: [1, 2],
                                           preconditionerDiag: [1, 0])) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-SV003")
        }
        XCTAssertThrowsError(try PCG.solve(size: 2, apply: identity, rhs: [1, 2],
                                           preconditionerDiag: [1])) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-SV003")
        }
        XCTAssertThrowsError(try PCG.solveBlock3(nodeCount: 1, apply: identity, rhs: [1, 2, 3],
                                                 preconditionerBlocks: [.init(m00: 0, m01: 0, m02: 0, m11: 0, m12: 0, m22: 0)])) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-SV003")
        }
    }

    func testNonSPDOperatorBreaksDown() {
        // Negative-definite operator: p·Ap < 0 on the first step.
        let negate: ([Double]) -> [Double] = { $0.map { -$0 } }
        XCTAssertThrowsError(try PCG.solve(size: 3, apply: negate, rhs: [1, 2, 3])) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-SV002")
        }
    }
}
