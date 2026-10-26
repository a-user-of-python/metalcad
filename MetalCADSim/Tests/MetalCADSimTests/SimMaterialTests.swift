import XCTest
import MetalCADKit
@testable import MetalCADSim

final class SimMaterialTests: XCTestCase {

    /// Every material in the kit library must have simulation data,
    /// and its density must be the kit's own value (passthrough).
    func testCoversEveryKitMaterial() {
        XCTAssertEqual(SimMaterial.all.count, MaterialLibrary.all.count,
                       "sim table must cover every kit material")
        for kit in MaterialLibrary.all {
            let sim = SimMaterial.forKitMaterial(kit.name)
            XCTAssertNotNil(sim, "missing SimMaterial for kit material \"\(kit.name)\"")
            guard let sim else { continue }
            XCTAssertEqual(sim.name, kit.name)
            XCTAssertEqual(sim.densityGCm3, kit.density,
                           "density must pass through from the kit for \(kit.name)")
            XCTAssertEqual(sim.densityKgM3, kit.density * 1000)
            // Physical sanity of the table itself.
            XCTAssertGreaterThan(sim.youngModulus, 0)
            XCTAssertGreaterThan(sim.poissonRatio, 0)
            XCTAssertLessThan(sim.poissonRatio, 0.5)
            XCTAssertGreaterThan(sim.yieldStrength, 0)
            XCTAssertGreaterThan(sim.thermalConductivity, 0)
            XCTAssertGreaterThan(sim.specificHeat, 0)
            XCTAssertGreaterThanOrEqual(sim.erosionResistance, 0)
            XCTAssertLessThanOrEqual(sim.erosionResistance, 1)
        }
    }

    func testLookupByMaterialValueAndUnknownName() {
        XCTAssertNotNil(SimMaterial.forKitMaterial(MaterialLibrary.defaultMaterial))
        XCTAssertNil(SimMaterial.forKitMaterial("Unobtainium"))
    }

    /// Spot-check the published values the design calls out.
    func testPublishedSpotValues() {
        let alu = SimMaterial.forKitMaterial("Aluminum 6061")!
        XCTAssertEqual(alu.youngModulus, 68.9e9, accuracy: 1e6)
        XCTAssertEqual(alu.poissonRatio, 0.33, accuracy: 1e-9)
        XCTAssertEqual(alu.yieldStrength, 276e6, accuracy: 1e6)
        XCTAssertEqual(alu.thermalConductivity, 167, accuracy: 0.5)

        let ti = SimMaterial.forKitMaterial("Titanium")!
        XCTAssertEqual(ti.youngModulus, 113.8e9, accuracy: 1e6)
        XCTAssertEqual(ti.poissonRatio, 0.34, accuracy: 1e-9)
        XCTAssertEqual(ti.yieldStrength, 880e6, accuracy: 1e6)
        XCTAssertEqual(ti.thermalConductivity, 6.7, accuracy: 0.05)

        let cu = SimMaterial.forKitMaterial("Copper")!
        XCTAssertEqual(cu.thermalConductivity, 391, accuracy: 1)
    }
}
