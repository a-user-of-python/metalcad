import Foundation

// Host benchmark for the 1M-triangle headroom pass — NOT part of the
// SwiftPM test target. Build & run:
//   swiftc -O Sources/MetalCADKit/*.swift bench/main.swift -o /tmp/mcbench && /tmp/mcbench

func timeMs(_ label: String, _ body: () -> Void) -> Double {
    let t0 = Date()
    body()
    let ms = Date().timeIntervalSince(t0) * 1000
    let padded = label.padding(toLength: 28, withPad: " ", startingAt: 0)
    print("\(padded) \(String(format: "%10.1f", ms)) ms")
    return ms
}

// ~1M triangles from the kit's own torus factory:
// 720 segments x 700 sides x 2 triangles = 1,008,000.
var mesh = Mesh()
timeMs("build torus (1.008M tris)") {
    mesh = try! Tessellation.torus(ringRadius: 50, tubeRadius: 20, segments: 720, sides: 700)
}
print("triangles: \(mesh.triangleCount), vertices: \(mesh.vertices.count)")

var sink = 0.0
timeMs("bounds x1000") {
    for _ in 0..<1000 { sink += mesh.bounds.size.x }
}
timeMs("volume x1000") {
    for _ in 0..<1000 { sink += mesh.volume }
}
timeMs("signedVolume x1000") {
    for _ in 0..<1000 { sink += mesh.signedVolume }
}
print("sink (prevents dead-code elim): \(sink)")

var soupCount = 0
timeMs("displaySoup x1") {
    let soup = mesh.displaySoup()
    soupCount = soup.positions.count
}
print("soup positions: \(soupCount)")

let stlURL = URL(fileURLWithPath: "/tmp/mcbench.stl")
timeMs("writeSTL x1") {
    _ = try! IOService.writeSTL(mesh, to: stlURL)
}
if let attrs = try? FileManager.default.attributesOfItem(atPath: stlURL.path),
   let bytes = attrs[.size] as? Int {
    print("STL bytes: \(bytes)")
}

var faceCount = 0
timeMs("groupedFaces x1") {
    faceCount = FaceExtractor.groupedFaces(of: mesh).faces.count
}
print("faces: \(faceCount)")
