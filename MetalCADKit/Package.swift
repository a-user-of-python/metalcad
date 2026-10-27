// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetalCADKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MetalCADKit", targets: ["MetalCADKit"])],
    targets: [
        .target(name: "MetalCADKit"),
        .testTarget(name: "MetalCADKitTests", dependencies: ["MetalCADKit"]),
    ]
)
