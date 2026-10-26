import Foundation
import MetalCADKit

/// Engineering properties of a material, for simulation. Keyed by the
/// kit's material names (`MaterialLibrary`) so a part's chosen material
/// carries into a study automatically; density is passed straight
/// through from the kit entry (never duplicated here).
///
/// Property values are typical published room-temperature values for the
/// named grade (datasheet / MatWeb-grade figures). They are
/// engineering estimates for a design tool, not certified allowables.
/// `erosionResistance` is a *relative* index in 0...1 (1 = most
/// resistant to water erosion/abrasion) used only for comparing
/// materials inside the erosion model — it has no physical unit.
public struct SimMaterial: Equatable {
    /// The kit material's name, e.g. "Aluminum 6061".
    public var name: String
    /// Density in g/cm³, passed through from the kit `Material`.
    public var densityGCm3: Double
    /// Young's modulus E, Pa.
    public var youngModulus: Double
    /// Poisson's ratio ν, dimensionless.
    public var poissonRatio: Double
    /// Yield strength, Pa (0.2% proof for metals; flexural/tensile yield
    /// for plastics as published).
    public var yieldStrength: Double
    /// Thermal conductivity k, W/(m·K).
    public var thermalConductivity: Double
    /// Specific heat capacity c_p, J/(kg·K).
    public var specificHeat: Double
    /// Relative erosion resistance, 0...1 (see type docs).
    public var erosionResistance: Double

    public init(name: String, densityGCm3: Double, youngModulus: Double,
                poissonRatio: Double, yieldStrength: Double,
                thermalConductivity: Double, specificHeat: Double,
                erosionResistance: Double) {
        self.name = name
        self.densityGCm3 = densityGCm3
        self.youngModulus = youngModulus
        self.poissonRatio = poissonRatio
        self.yieldStrength = yieldStrength
        self.thermalConductivity = thermalConductivity
        self.specificHeat = specificHeat
        self.erosionResistance = erosionResistance
    }

    /// Density in kg/m³ (SI, for solver-internal use).
    public var densityKgM3: Double { densityGCm3 * 1000 }

    /// The simulation properties for a kit material name, or nil when
    /// the name isn't a known kit material (or has no data yet).
    public static func forKitMaterial(_ name: String) -> SimMaterial? {
        all.first { $0.name == name }
    }

    /// Properties for a kit `Material` value.
    public static func forKitMaterial(_ material: Material) -> SimMaterial? {
        forKitMaterial(material.name)
    }

    /// Every kit material that has simulation data. Built by joining
    /// the property table onto `MaterialLibrary.all`, so the density
    /// always comes from the kit itself. A kit material with no entry
    /// in the property table is absent here — the test suite fails
    /// until data is added for it.
    public static let all: [SimMaterial] = MaterialLibrary.all.compactMap { kit in
        guard let p = propertiesByName[kit.name] else { return nil }
        return SimMaterial(name: kit.name, densityGCm3: kit.density,
                           youngModulus: p.youngModulus,
                           poissonRatio: p.poissonRatio,
                           yieldStrength: p.yieldStrength,
                           thermalConductivity: p.thermalConductivity,
                           specificHeat: p.specificHeat,
                           erosionResistance: p.erosionResistance)
    }

    private struct Properties {
        var youngModulus: Double
        var poissonRatio: Double
        var yieldStrength: Double
        var thermalConductivity: Double
        var specificHeat: Double
        var erosionResistance: Double
    }

    /// Typical published values by kit material name.
    private static let propertiesByName: [String: Properties] = [
        // 6061-T6: E 68.9 GPa, ν 0.33, yield 276 MPa, k 167, cp 896.
        "Aluminum 6061": Properties(youngModulus: 68.9e9, poissonRatio: 0.33,
                                    yieldStrength: 276e6, thermalConductivity: 167,
                                    specificHeat: 896, erosionResistance: 0.65),
        // A36-class mild steel: E 200 GPa, ν 0.30, yield 250 MPa,
        // k ~50, cp 490.
        "Steel (mild)": Properties(youngModulus: 200e9, poissonRatio: 0.30,
                                   yieldStrength: 250e6, thermalConductivity: 50,
                                   specificHeat: 490, erosionResistance: 0.75),
        // 304 annealed: E 193 GPa, ν 0.29, yield 215 MPa, k 16.2, cp 500.
        "Stainless 304": Properties(youngModulus: 193e9, poissonRatio: 0.29,
                                    yieldStrength: 215e6, thermalConductivity: 16.2,
                                    specificHeat: 500, erosionResistance: 0.90),
        // Cartridge/half-hard brass: E ~97 GPa, ν 0.34, yield ~275 MPa,
        // k ~115, cp 380.
        "Brass": Properties(youngModulus: 97e9, poissonRatio: 0.34,
                            yieldStrength: 275e6, thermalConductivity: 115,
                            specificHeat: 380, erosionResistance: 0.60),
        // C110 copper, half-hard: E 117 GPa, ν 0.34, yield ~195 MPa,
        // k 391, cp 385.
        "Copper": Properties(youngModulus: 117e9, poissonRatio: 0.34,
                             yieldStrength: 195e6, thermalConductivity: 391,
                             specificHeat: 385, erosionResistance: 0.55),
        // Ti-6Al-4V: E 113.8 GPa, ν 0.34, yield 880 MPa, k 6.7, cp 526.
        // (The kit's density 4.43 g/cm³ is the Ti-6Al-4V figure.)
        "Titanium": Properties(youngModulus: 113.8e9, poissonRatio: 0.34,
                               yieldStrength: 880e6, thermalConductivity: 6.7,
                               specificHeat: 526, erosionResistance: 0.95),
        // ABS: E ~2.2 GPa, ν 0.35, yield ~45 MPa, k 0.17, cp ~1300.
        "ABS plastic": Properties(youngModulus: 2.2e9, poissonRatio: 0.35,
                                  yieldStrength: 45e6, thermalConductivity: 0.17,
                                  specificHeat: 1300, erosionResistance: 0.25),
        // PLA: E ~3.5 GPa, ν 0.36, yield ~60 MPa, k 0.13, cp ~1800.
        "PLA plastic": Properties(youngModulus: 3.5e9, poissonRatio: 0.36,
                                  yieldStrength: 60e6, thermalConductivity: 0.13,
                                  specificHeat: 1800, erosionResistance: 0.30),
        // PETG: E ~2.1 GPa, ν 0.38, yield ~50 MPa, k 0.20, cp ~1200.
        "PETG plastic": Properties(youngModulus: 2.1e9, poissonRatio: 0.38,
                                   yieldStrength: 50e6, thermalConductivity: 0.20,
                                   specificHeat: 1200, erosionResistance: 0.30),
        // PA6 nylon (dry): E ~2.8 GPa, ν 0.40, yield ~80 MPa, k 0.25,
        // cp ~1700.
        "Nylon": Properties(youngModulus: 2.8e9, poissonRatio: 0.40,
                            yieldStrength: 80e6, thermalConductivity: 0.25,
                            specificHeat: 1700, erosionResistance: 0.50),
        // Red oak, along grain (wood is strongly anisotropic — these
        // are grain-direction figures): E ~11 GPa, ν ~0.35,
        // strength ~40 MPa, k 0.17, cp ~2400.
        "Oak wood": Properties(youngModulus: 11e9, poissonRatio: 0.35,
                               yieldStrength: 40e6, thermalConductivity: 0.17,
                               specificHeat: 2400, erosionResistance: 0.20),
        // POM/acetal (Delrin): E ~3.1 GPa, ν 0.35, yield ~70 MPa,
        // k 0.37, cp ~1500.
        "Delrin (acetal)": Properties(youngModulus: 3.1e9, poissonRatio: 0.35,
                                      yieldStrength: 70e6, thermalConductivity: 0.37,
                                      specificHeat: 1500, erosionResistance: 0.35),
    ]
}
