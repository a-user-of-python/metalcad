import SwiftUI
import SceneKit
import UIKit

/// SceneKit preview of a kit Mesh, v2: SMOOTH shading via
/// `Mesh.displaySoup()` (crease-averaged normals — curved surfaces have
/// no visible triangles; triangles only appear in the exported STL),
/// physically-based material from the part's `Material`, and optional
/// face picking for "Sketch on face".
///
/// Picking note: the soup is expanded in exactly the same triangle order
/// as `mesh.welded()`, so a SceneKit hit-test `faceIndex` IS the welded
/// mesh's triangle index — no remapping needed.
struct SceneKitView: UIViewRepresentable {
    var mesh: Mesh
    /// Display material; nil falls back to the library default.
    var material: Material? = nil
    /// When true, taps hit-test the model and report the triangle index.
    var isPickingFace: Bool = false
    /// Called with the welded-mesh triangle index of the tapped face.
    var onFacePicked: ((Int) -> Void)? = nil

    final class Coordinator: NSObject {
        var geometryKey: String = ""
        var modelNode: SCNNode?
        var cameraNode: SCNNode?
        var framed: Bool = false
        var onFacePicked: ((Int) -> Void)?
        var isPickingFace: Bool = false

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard isPickingFace, let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            let options: [SCNHitTestOption: Any] = [
                .searchMode: NSNumber(value: SCNHitTestSearchMode.closest.rawValue),
                .boundingBoxOnly: NSNumber(value: false),
                .ignoreChildNodes: NSNumber(value: false),
            ]
            let hits = view.hitTest(point, options: options)
            guard let hit = hits.first(where: { $0.node.geometry != nil }) else { return }
            onFacePicked?(hit.faceIndex)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        view.scene = scene

        // Key light (physically-based materials still need real lights).
        let keyLight = SCNNode()
        let dir = SCNLight()
        dir.type = .directional
        dir.intensity = 1100
        keyLight.light = dir
        keyLight.position = SCNVector3(60, 90, 110)
        keyLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyLight)

        // Soft fill from the opposite side so curved metal reads smooth.
        let fillNode = SCNNode()
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 350
        fillNode.light = fill
        fillNode.position = SCNVector3(-80, -30, -60)
        fillNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillNode)

        let ambientNode = SCNNode()
        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 420
        amb.color = UIColor(white: 0.92, alpha: 1)
        ambientNode.light = amb
        scene.rootNode.addChildNode(ambientNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(70, 55, 95)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
        context.coordinator.cameraNode = cameraNode

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:)))
        // Single tap picks a face only in pick mode; the coordinator
        // ignores it otherwise, so camera control is never disturbed.
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onFacePicked = onFacePicked
        context.coordinator.isPickingFace = isPickingFace
        if isPickingFace {
            view.backgroundColor = UIColor(red: 0.13, green: 0.10, blue: 0.05, alpha: 1)
        } else {
            view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
        }

        // Identity for "geometry must be rebuilt": mesh shape + material.
        let mat = material ?? MaterialLibrary.defaultMaterial
        let key = "\(mesh.triangleCount)|\(mesh.volume)|\(mat.id)"
        guard context.coordinator.geometryKey != key else { return }
        context.coordinator.geometryKey = key

        context.coordinator.modelNode?.removeFromParentNode()
        let node = SCNNode(geometry: Self.makeGeometry(mesh, material: mat))
        view.scene?.rootNode.addChildNode(node)
        context.coordinator.modelNode = node

        if !context.coordinator.framed, mesh.triangleCount > 0,
           let cameraNode = context.coordinator.cameraNode {
            let b = mesh.bounds
            let c = b.center
            let r = max(b.size.length / 2, 12)
            cameraNode.position = SCNVector3(
                Float(c.x + r * 1.7), Float(c.y + r * 1.15), Float(c.z + r * 2.0))
            cameraNode.look(at: SCNVector3(Float(c.x), Float(c.y), Float(c.z)))
            context.coordinator.framed = true
        }
    }

    /// Smooth geometry: positions + crease-averaged normals straight from
    /// `displaySoup()`. One vertex per corner, sequential indices.
    static func makeGeometry(_ mesh: Mesh, material: Material) -> SCNGeometry {
        let triCount = mesh.triangleCount
        guard triCount > 0 else { return SCNGeometry() }
        let soup = mesh.displaySoup()
        let vertCount = soup.positions.count
        guard vertCount == triCount * 3 else {
            MCLog.shared.warn(.render, "display soup size mismatch; preview skipped",
                              code: "MCAD-KN603")
            return SCNGeometry()
        }
        var positions: [Float] = []
        var normals: [Float] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(vertCount * 3)
        normals.reserveCapacity(vertCount * 3)
        indices.reserveCapacity(vertCount)
        for i in 0..<vertCount {
            let p = soup.positions[i]
            let n = soup.normals[i]
            positions.append(Float(p.x)); positions.append(Float(p.y)); positions.append(Float(p.z))
            normals.append(Float(n.x)); normals.append(Float(n.y)); normals.append(Float(n.z))
            indices.append(UInt32(i))
        }
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let norData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let idxData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: posData, semantic: .vertex, vectorCount: vertCount,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let normalSource = SCNGeometrySource(
            data: norData, semantic: .normal, vectorCount: vertCount,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(
            data: idxData, primitiveType: .triangles,
            primitiveCount: triCount, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        let scnMaterial = SCNMaterial()
        scnMaterial.lightingModel = .physicallyBased
        scnMaterial.diffuse.contents = UIColor(
            red: CGFloat(material.red), green: CGFloat(material.green),
            blue: CGFloat(material.blue), alpha: 1)
        scnMaterial.metalness.contents = NSNumber(value: material.metalness)
        scnMaterial.roughness.contents = NSNumber(value: material.roughness)
        scnMaterial.isDoubleSided = true
        geometry.materials = [scnMaterial]
        return geometry
    }
}
