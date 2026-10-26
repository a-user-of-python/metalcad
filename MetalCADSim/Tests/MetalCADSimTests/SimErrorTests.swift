import XCTest
@testable import MetalCADSim

final class SimErrorTests: XCTestCase {

    func testCatalogCodesAreDistinct() {
        let codes = SimErrorCatalog.allCodes
        XCTAssertEqual(Set(codes).count, codes.count, "catalog codes must be distinct")
        for code in codes {
            XCTAssertTrue(code.hasPrefix("MSIM-"), "code \(code) must carry the MSIM- prefix")
        }
    }

    func testEveryCaseMapsIntoTheCatalog() {
        let cases: [SimError] = [
            .invalidValue(parameter: "cellSize", detail: "x"),
            .nonFiniteValue(parameter: "cellSize"),
            .cellBudgetExceeded(cells: 10, budget: 5),
            .degenerateBounds(detail: "x"),
            .didNotConverge(residual: 1, iterations: 3),
            .operatorBreakdown(detail: "x"),
            .invalidSolverInput(detail: "x"),
            .emptyMesh,
            .unknownMaterial(name: "x"),
            .zeroDirection(context: "wind"),
            .faceMatchedNoCells(context: "loads"),
        ]
        XCTAssertEqual(cases.count, SimErrorCatalog.allCodes.count,
                       "catalog must list exactly the defined cases")
        for c in cases {
            XCTAssertTrue(SimErrorCatalog.allCodes.contains(c.code),
                          "\(c.code) missing from catalog")
            XCTAssertFalse(c.userMessage.isEmpty)
        }
        XCTAssertEqual(Set(cases.map { $0.code }).count, cases.count,
                       "case codes must be pairwise distinct")
    }
}
