import XCTest
@testable import MetalCADKit

/// 50 checks: error codes are distinct, well-formed, and every code in the
/// catalog is produced by exactly the error that claims it.
final class ErrorsTests: XCTestCase {

    func testCatalogHasNoDuplicates() {
        XCTAssertEqual(Set(CADErrorCatalog.allCodes).count, CADErrorCatalog.allCodes.count)
    }

    func testCatalogSize() {
        XCTAssertGreaterThanOrEqual(CADErrorCatalog.allCodes.count, 70)
    }

    func testAllCodesWellFormed() {
        let pattern = #"^MCAD-(GN|DC|SK|SV|FT|TH|KN|IO|AS|DR|RD|UI)[0-9]{3}$"#
        let re = try! NSRegularExpression(pattern: pattern)
        for code in CADErrorCatalog.allCodes {
            let range = NSRange(code.startIndex..., in: code)
            XCTAssertNotNil(re.firstMatch(in: code, range: range), code)
        }
    }

    /// One representative error per code, in catalog order groups.
    func sampleErrors() -> [CADError] {
        [
            .unknown("x"), .outOfMemory, .cancelledByUser, .notImplementedYet("x"), .invariantBroken("x"),
            .documentNotFound("x"), .documentCorruptJSON("x"), .documentVersionTooNew(found: 9, supported: 1),
            .documentVersionTooOld(found: 0), .duplicateName("x"), .nameNotFound("x"),
            .featureRebuildFailed(feature: "f", underlyingCode: "MCAD-FT401"), .circularDependency(["a"]),
            .parameterOutOfRange(name: "p", value: -1, clamped: 0), .snapshotWriteFailed("x"),
            .equationParseError("x", position: 0), .equationEvalError("x"),
            .sketchPlaneLost(sketch: "s"), .entityNotFound(1), .degenerateEntity(1),
            .profileOpen(gapA: .zero, gapB: .zero), .profileSelfIntersecting(at: .zero),
            .profileNestedTooDeep(9), .duplicateEntity(1), .splineTooFewPoints(1),
            .arcInvalidGeometry, .projectionSourceGone(entity: 1), .sketchEmpty,
            .solverDidNotConverge(residual: 1, iterations: 100), .conflictingConstraints(["a"]),
            .redundantConstraint("a"), .overConstrained(dofBefore: 2, dofAfter: -1), .solverSingular,
            .danglingConstraint("a"), .solveTimeout,
            .padNoProfile, .padLengthInvalid(0), .revolveAxisMissing, .revolveProfileCrossesAxis,
            .booleanFailed("x"), .booleanEmptyResult, .filletFailed("x"),
            .filletRadiusTooLarge(requested: 5, maxFeasible: 2), .chamferInvalid("x"), .shellFailed("x"),
            .patternCountInvalid(0), .transformInvalid("x"), .primitiveParamInvalid("x"),
            .sweepPathInvalid("x"), .loftProfileMismatch, .holeSpecInvalid("x"), .directEditHealFailed,
            .threadPitchInvalid(0), .threadDiameterInvalid(major: 1, minor: 2),
            .threadProfileInvalid("x"), .threadStartsInvalid(9), .threadTooLong(requested: 10, clamped: 5),
            .threadSweepFailed("x"), .threadTaperInvalid(99), .threadFitOutOfRange(clamped: 0),
            .threadPresetUnknown("x"),
            .kernelUnavailable, .kernelOperationFailed("x"), .kernelShapeInvalid("x"),
            .kernelTessellationFailed("x"), .kernelTimeout,
            .importFormatUnsupported("xyz"), .importFileUnreadable("x"), .importGeometryInvalid("x"),
            .exportNotWatertight(openEdges: 3), .exportWriteFailed("x"), .stepWriteFailed("x"),
            .meshTooLarge(triangles: 10, budget: 5),
        ]
    }

    func testEverySampleCodeIsInCatalog() {
        for e in sampleErrors() {
            XCTAssertTrue(CADErrorCatalog.allCodes.contains(e.code), "\(e.code) missing from catalog")
        }
    }

    func testSampleCodesAreAllDistinct() {
        let codes = sampleErrors().map { $0.code }
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    func testSampleCoversWholeCatalog() {
        let codes = Set(sampleErrors().map { $0.code })
        XCTAssertEqual(codes, Set(CADErrorCatalog.allCodes))
    }

    func testEveryErrorHasUserMessage() {
        for e in sampleErrors() {
            XCTAssertFalse(e.userMessage.isEmpty, e.code)
            XCTAssertFalse(e.userMessage.contains("MCAD-"), "message shouldn't embed the code: \(e.code)")
        }
    }

    func testFatalSeverities() {
        XCTAssertEqual(CADError.outOfMemory.severity, .fatal)
        XCTAssertEqual(CADError.invariantBroken("x").severity, .fatal)
    }

    func testWarningSeverities() {
        let warnings: [CADError] = [
            .cancelledByUser, .duplicateName("x"), .degenerateEntity(1), .redundantConstraint("x"),
            .solveTimeout, .filletRadiusTooLarge(requested: 1, maxFeasible: 0.5),
            .threadTooLong(requested: 2, clamped: 1), .threadPresetUnknown("x"),
            .exportNotWatertight(openEdges: 1), .meshTooLarge(triangles: 2, budget: 1),
            .notImplementedYet("x"), .documentVersionTooOld(found: 0),
            .parameterOutOfRange(name: "p", value: 0, clamped: 0), .profileNestedTooDeep(9),
            .duplicateEntity(1), .projectionSourceGone(entity: 1), .threadFitOutOfRange(clamped: 0),
            .importGeometryInvalid("x"), .loftProfileMismatch,
        ]
        for e in warnings { XCTAssertEqual(e.severity, .warning, e.code) }
    }

    func testErrorSeverities() {
        let errors: [CADError] = [
            .documentNotFound("x"), .profileOpen(gapA: .zero, gapB: .zero), .solverSingular,
            .padNoProfile, .threadPitchInvalid(0), .kernelUnavailable, .importFormatUnsupported("x"),
        ]
        for e in errors { XCTAssertEqual(e.severity, .error, e.code) }
    }

    func testDomainPrefixesMatchGroups() {
        for e in sampleErrors() {
            let prefix = String(e.code.dropFirst(5).prefix(2))
            XCTAssertTrue(["GN", "DC", "SK", "SV", "FT", "TH", "KN", "IO"].contains(prefix), e.code)
        }
    }
}

// MARK: Top-up spot checks (exact code strings)

extension ErrorsTests {
    func testSpotCodes() {
        XCTAssertEqual(CADError.profileOpen(gapA: .zero, gapB: .zero).code, "MCAD-SK204")
        XCTAssertEqual(CADError.conflictingConstraints([]).code, "MCAD-SV302")
        XCTAssertEqual(CADError.threadPresetUnknown("x").code, "MCAD-TH509")
        XCTAssertEqual(CADError.documentVersionTooNew(found: 2, supported: 1).code, "MCAD-DC103")
        XCTAssertEqual(CADError.kernelTessellationFailed("x").code, "MCAD-KN604")
        XCTAssertEqual(CADError.exportNotWatertight(openEdges: 1).code, "MCAD-IO704")
        XCTAssertEqual(CADError.filletRadiusTooLarge(requested: 9, maxFeasible: 3).code, "MCAD-FT408")
        XCTAssertEqual(CADError.solveTimeout.code, "MCAD-SV307")
        XCTAssertEqual(CADError.arcInvalidGeometry.code, "MCAD-SK209")
        XCTAssertEqual(CADError.equationParseError("x", position: 0).code, "MCAD-DC111")
        XCTAssertEqual(CADError.revolveProfileCrossesAxis.code, "MCAD-FT404")
        XCTAssertEqual(CADError.threadSweepFailed("x").code, "MCAD-TH506")
    }
}
