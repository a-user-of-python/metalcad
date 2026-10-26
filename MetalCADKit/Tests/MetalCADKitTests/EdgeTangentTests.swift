import XCTest
@testable import MetalCADKit

/// Defect B (device, 2026-10-26): "Fillet/Chamfer says too big when
/// it's not" — radius 2.0 on a 4 mm plate (exact tangency) failed
/// FT408 with "largest that fits is 1.9750776290893555" — and
/// "chamfer sticks out": chamfering the concave floor edges of an
/// open slot added wedges floating 1.2 mm past the part's sides
/// (the adder prism's end overshoot). finish() now retries a ladder
/// of hair-smaller values before erroring, FT408 prints 2 decimals,
/// and adder prisms stop at the edge's ends.
final class EdgeTangentTests: XCTestCase {

    func testTangentFilletSucceeds() throws {
        // Radius = exactly half the plate thickness: the fillets
        // from the top and bottom edges meet. Geometrically fine.
        let plate = try Tessellation.box(width: 40, depth: 40, height: 4)
        let r = try EdgeFinisher.fillet(body: plate, radius: 2.0)
        XCTAssertLessThan(r.volume, 6400)
        XCTAssertGreaterThan(r.volume, 5600)
    }

    func testTangentChamferSucceeds() throws {
        let plate = try Tessellation.box(width: 40, depth: 40, height: 4)
        let r = try EdgeFinisher.chamfer(body: plate, distance: 2.0)
        XCTAssertLessThan(r.volume, 6400)
        XCTAssertGreaterThan(r.volume, 5000)
    }

    func testGenuineOversizeStillErrorsWithRoundedMessage() throws {
        // Radius 3 on a 4 mm plate: fillets from both sides would
        // cross (max feasible is just under 2). Genuinely too big —
        // must still error, with the feasible value at 2 decimals.
        let plate = try Tessellation.box(width: 40, depth: 40, height: 4)
        XCTAssertThrowsError(try EdgeFinisher.fillet(body: plate, radius: 3)) { err in
            guard case .filletRadiusTooLarge(_, let maxF) = err as? CADError else {
                return XCTFail("expected FT408, got \(err)")
            }
            XCTAssertEqual(maxF, 1.98, accuracy: 0.05)
            let msg = (err as? CADError)?.userMessage ?? ""
            XCTAssertTrue(msg.contains("largest that fits is 1.9"), "message: \(msg)")
            XCTAssertFalse(msg.range(of: #"\.\d{3,}"#, options: .regularExpression) != nil,
                           "message still prints long decimals: \(msg)")
        }
    }

    func testChamferBoxStaysInBounds() throws {
        let box = try Tessellation.box(width: 20, depth: 20, height: 20)
        let r = try EdgeFinisher.chamfer(body: box, distance: 2)
        XCTAssertLessThan(r.volume, 8000)  // convex edges: material removed
        XCTAssertEqual(r.bounds.min.x, -10, accuracy: 1e-6)
        XCTAssertEqual(r.bounds.max.x, 10, accuracy: 1e-6)
        XCTAssertEqual(r.bounds.min.y, -10, accuracy: 1e-6)
        XCTAssertEqual(r.bounds.max.y, 10, accuracy: 1e-6)
        XCTAssertEqual(r.bounds.min.z, 0, accuracy: 1e-6)
        XCTAssertEqual(r.bounds.max.z, 20, accuracy: 1e-6)
    }

    /// The protrusion case: an open slot's concave floor edges END
    /// at the part's side faces. Before the fix the result's bounds
    /// grew to x = +/-21.2 on a +/-20 part (exactly the chamfer
    /// distance, floating in air).
    func testChamferOpenSlotFloorDoesNotProtrude() throws {
        let plate = try Tessellation.box(width: 40, depth: 20, height: 10)
        let channel = try Tessellation.box(width: 44, depth: 8, height: 6)
            .translated(by: Vec3(0, 0, 7))
        let slotted = try CSG.subtract(plate, channel)
        let mids = [Vec3(0, -4, 7), Vec3(0, 4, 7)]  // floor edges, z=7
        let r = try EdgeFinisher.chamfer(body: slotted, distance: 1.2, onlyMidpoints: mids)
        XCTAssertEqual(r.bounds.min.x, -20, accuracy: 1e-6)
        XCTAssertEqual(r.bounds.max.x, 20, accuracy: 1e-6)
        XCTAssertEqual(r.bounds.max.z, 10, accuracy: 1e-6)
        // Concave chamfer ADDS material in the corner — but only the
        // in-part wedge, not the floating overshoot tips.
        XCTAssertGreaterThan(r.volume, slotted.volume)
        XCTAssertLessThan(r.volume, slotted.volume + 59)
    }

    func testChamferDemoPocketRimStaysInBounds() throws {
        let body = DocumentEngine.rebuild(part: ThreadCoverageTests.demoPart()).mesh
        let edges = SolidEdgeExtractor.edges(of: body)
        let rim = edges.filter { abs($0.mid.z - 10) < 0.01 && abs($0.mid.x) <= 15.01 && abs($0.mid.y) <= 10.01 && $0.isConvex }
        XCTAssertEqual(rim.count, 4)
        let r = try EdgeFinisher.chamfer(body: body, distance: 1.5, onlyMidpoints: rim.map(\.mid))
        XCTAssertLessThan(r.volume, body.volume)  // convex: material removed
        let b = r.bounds, ob = body.bounds
        XCTAssertGreaterThanOrEqual(b.min.x, ob.min.x - 1e-6)
        XCTAssertLessThanOrEqual(b.max.x, ob.max.x + 1e-6)
        XCTAssertGreaterThanOrEqual(b.min.y, ob.min.y - 1e-6)
        XCTAssertLessThanOrEqual(b.max.y, ob.max.y + 1e-6)
        XCTAssertLessThanOrEqual(b.max.z, ob.max.z + 1e-6)
    }
}
