// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetalCADSim",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MetalCADSim", targets: ["MetalCADSim"])],
    dependencies: [.package(path: "../MetalCADKit")],
    targets: [
        .target(name: "MetalCADSim", dependencies: ["MetalCADKit"]),
        .testTarget(name: "MetalCADSimTests", dependencies: ["MetalCADSim", "MetalCADKit"]),
    ]
)
