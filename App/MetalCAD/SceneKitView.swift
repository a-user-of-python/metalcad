import SwiftUI
import SceneKit
import UIKit

/// SceneKit preview of a kit Mesh. Vertices are expanded per triangle so
/// each face gets its own flat normal (flat shading). Camera control is
/// SceneKit's; the camera is framed once, on the first non-empty mesh.
struct SceneKitView: UIViewRepresentable {
    var mesh: Mesh

    final class Coordinator {
        var meshKey: String = ""
        var modelNode: SCNNode?
        var cameraNode: SCNNode?
        var framed: Bool = false
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

        let keyLight = SCNNode()
        let dir = SCNLight()
        dir.type = .directional
        dir.intensity = 900
        keyLight.light = dir
        keyLight.position = SCNVector3(60, 90, 110)
        keyLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyLight)

        let ambientNode = SCNNode()
        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 380
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

        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // Cheap identity for "the mesh changed": triangle count + volume.
        let key = "\(mesh.triangleCount)|\(mesh.volume)"
        guard context.coordinator.meshKey != key else { return }
        context.coordinator.meshKey = key

        context.coordinator.modelNode?.removeFromParentNode()
        let node = SCNNode(geometry: Self.makeGeometry(mesh))
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

    /// Expanded (non-shared) vertices + per-face normals + sequential index.
    static func makeGeometry(_ mesh: Mesh) -> SCNGeometry {
        let triCount = mesh.triangleCount
        guard triCount > 0 else { return SCNGeometry() }
        if let maxIndex = mesh.indices.max(), Int(maxIndex) >= mesh.vertices.count {
            MCLog.shared.warn(.render, "mesh index out of range; preview skipped",
                              code: "MCAD-KN603")
            return SCNGeometry()
        }
        var positions: [Float] = []
        var normals: [Float] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(triCount * 9)
        normals.reserveCapacity(triCount * 9)
        indices.reserveCapacity(triCount * 3)
        let faceNormals = mesh.faceNormals()
        for t in 0..<triCount {
            let n = faceNormals[t]
            for k in 0..<3 {
                let v = mesh.vertices[Int(mesh.indices[t * 3 + k])]
                positions.append(Float(v.x)); positions.append(Float(v.y)); positions.append(Float(v.z))
                normals.append(Float(n.x)); normals.append(Float(n.y)); normals.append(Float(n.z))
                indices.append(UInt32(t * 3 + k))
            }
        }
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let norData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let idxData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: posData, semantic: .vertex, vectorCount: triCount * 3,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let normalSource = SCNGeometrySource(
            data: norData, semantic: .normal, vectorCount: triCount * 3,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(
            data: idxData, primitiveType: .triangles,
            primitiveCount: triCount, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.36, green: 0.56, blue: 0.96, alpha: 1)
        material.lightingModel = .blinn
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}
