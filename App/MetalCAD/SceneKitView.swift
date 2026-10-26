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
    /// Translucent amber preview of an uncommitted (draft) feature
    /// result — rendered over the committed model, never hit-tested.
    var ghostMesh: Mesh? = nil
    /// Sketches to draw as 3D overlays (tap one to select it).
    var sketches: [Sketch] = []
    /// The currently selected sketch (amber overlay + fill).
    var selectedSketchID: String? = nil
    /// Sketches whose overlays are hidden (browser eye toggles).
    var hiddenSketchIDs: Set<String> = []
    /// Master switch for the sketch overlays.
    var showSketches: Bool = true
    /// When true, taps hit-test the model and report the triangle index.
    var isPickingFace: Bool = false
    /// Called with the welded-mesh triangle index of the tapped face.
    var onFacePicked: ((Int) -> Void)? = nil
    /// Called when a tap selects a sketch overlay (nil = empty space).
    var onSketchPicked: ((String?) -> Void)? = nil
    /// The current model selection (face / edge / shaft / hole wall),
    /// rendered as an amber (or blue, for hole walls) highlight. The
    /// highlight nodes are never hit-tested for picking.
    var picked: PickedSelection? = nil
    /// The result mesh `picked` was resolved against — face
    /// highlights index into its grouped faces.
    var pickedMesh: Mesh = Mesh()
    /// Called when a NORMAL-mode tap lands on the model: the welded
    /// triangle index and the hit point (model-node local coords —
    /// the node sits at the origin, so these are scene coords).
    var onModelHit: ((Int, Vec3) -> Void)? = nil

    final class Coordinator: NSObject {
        var geometryKey: String = ""
        var ghostKey: String = ""
        var overlayKey: String = ""
        var selectionKey: String = ""
        var modelNode: SCNNode?
        var ghostNode: SCNNode?
        var overlayNode: SCNNode?
        var selectionNode: SCNNode?
        var cameraNode: SCNNode?
        var framed: Bool = false
        var onFacePicked: ((Int) -> Void)?
        var onSketchPicked: ((String?) -> Void)?
        var onModelHit: ((Int, Vec3) -> Void)?
        var isPickingFace: Bool = false
        // Snapshot of the overlay inputs, for tap ray casting.
        var sketchesInput: [Sketch] = []
        var hiddenSketchIDsInput: Set<String> = []
        var showSketchesInput: Bool = true

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            let options: [SCNHitTestOption: Any] = [
                .searchMode: NSNumber(value: SCNHitTestSearchMode.closest.rawValue),
                .boundingBoxOnly: NSNumber(value: false),
                .ignoreChildNodes: NSNumber(value: false),
            ]
            if isPickingFace {
                let hits = view.hitTest(point, options: options)
                // Only the committed model node counts — the ghost and
                // the sketch overlays also carry geometry but must
                // never answer a face pick.
                guard let hit = hits.first(where: { $0.node === modelNode }) else { return }
                onFacePicked?(hit.faceIndex)
                return
            }
            // Normal mode: a tap ON the model resolves a picked
            // selection first (edge → face → shaft/hole, in the
            // model). The filter to the model node keeps the ghost,
            // the sketch overlays and the selection highlight itself
            // from ever answering the tap. Only a tap that misses the
            // model entirely falls through to sketch selection.
            let hits = view.hitTest(point, options: options)
            if let hit = hits.first(where: { $0.node === modelNode }) {
                let c = hit.localCoordinates
                onModelHit?(hit.faceIndex,
                            Vec3(Double(c.x), Double(c.y), Double(c.z)))
                return
            }
            pickSketch(at: point, in: view)
        }

        /// Ray-cast the tap against each visible sketch's plane and
        /// select the sketch whose nearest entity passes within
        /// 3.5 mm of the ray/plane intersection point. Tapping empty
        /// space clears the selection (reports nil).
        private func pickSketch(at point: CGPoint, in view: SCNView) {
            guard showSketchesInput else { onSketchPicked?(nil); return }
            let near3 = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
            let far3 = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
            let origin = Vec3(Double(near3.x), Double(near3.y), Double(near3.z))
            let far = Vec3(Double(far3.x), Double(far3.y), Double(far3.z))
            let span = far - origin
            guard span.length > 1e-9 else { onSketchPicked?(nil); return }
            let dir = span.normalized
            var best: (id: String, dist: Double)?
            for sketch in sketchesInput
            where !hiddenSketchIDsInput.contains(sketch.id) && !sketch.isDatumPlane {
                let plane = sketch.plane
                let denom = dir.dot(plane.normal)
                guard abs(denom) > 1e-9 else { continue }
                let t = (plane.origin - origin).dot(plane.normal) / denom
                guard t > 0 else { continue }
                let hit = origin + dir * t
                let local = hit - plane.origin
                let p = Vec2(local.dot(plane.xAxis), local.dot(plane.yAxis))
                var minDist = Double.greatestFiniteMagnitude
                for entity in sketch.entities where !entity.isConstruction {
                    let pts = entity.polyline()
                    if pts.count == 1 {
                        minDist = min(minDist, p.distance(to: pts[0]))
                    } else if pts.count > 1 {
                        for i in 0..<(pts.count - 1) {
                            minDist = min(minDist, Self.distanceToSegment(p, pts[i], pts[i + 1]))
                        }
                    }
                }
                guard minDist < 3.5 else { continue }
                if best == nil || minDist < best!.dist { best = (sketch.id, minDist) }
            }
            onSketchPicked?(best?.id)
        }

        static func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            let ab = b - a
            let len2 = ab.dot(ab)
            guard len2 > 1e-12 else { return p.distance(to: a) }
            let t = max(0, min(1, (p - a).dot(ab) / len2))
            return p.distance(to: a + ab * t)
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
        let cam = SCNCamera()
        // The scene is in MILLIMETRES. SceneKit's default clip range
        // (zNear 1, zFar 100) slices a 60 mm part framed from ~130 mm
        // away: orbiting moved surfaces across the far plane and the
        // model "clipped in and out of existence" (device report,
        // 2026-10-26). Use a range fitted to mm-scale parts instead.
        cam.zNear = 0.5
        cam.zFar = 20_000
        cam.automaticallyAdjustsZRange = false
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(70, 55, 95)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
        context.coordinator.cameraNode = cameraNode

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:)))
        // Single tap: picks a face in face-pick mode; otherwise it
        // selects the tapped sketch overlay. The recognizer only fires
        // on discrete taps, so orbit drags never disturb the camera.
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onFacePicked = onFacePicked
        context.coordinator.onSketchPicked = onSketchPicked
        context.coordinator.onModelHit = onModelHit
        context.coordinator.isPickingFace = isPickingFace
        context.coordinator.sketchesInput = sketches
        context.coordinator.hiddenSketchIDsInput = hiddenSketchIDs
        context.coordinator.showSketchesInput = showSketches
        if isPickingFace {
            view.backgroundColor = UIColor(red: 0.13, green: 0.10, blue: 0.05, alpha: 1)
        } else {
            view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
        }

        // Draft ghost + sketch overlays + selection highlight refresh
        // independently of the committed-model geometry guard below.
        updateGhost(view, context: context)
        updateOverlays(view, context: context)
        updateSelection(view, context: context)

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

    // MARK: Draft ghost

    /// Keep the translucent amber ghost node in sync with `ghostMesh`.
    private func updateGhost(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        let key: String
        if let g = ghostMesh, g.triangleCount > 0 {
            key = "\(g.triangleCount)|\(g.volume)"
        } else {
            key = ""
        }
        guard coord.ghostKey != key else { return }
        coord.ghostKey = key
        coord.ghostNode?.removeFromParentNode()
        coord.ghostNode = nil
        guard let g = ghostMesh, g.triangleCount > 0 else { return }
        let node = SCNNode(geometry: Self.makeGhostGeometry(g))
        node.name = "ghost"
        node.renderingOrder = 10
        view.scene?.rootNode.addChildNode(node)
        coord.ghostNode = node
    }

    /// Smooth geometry like the model's, but one translucent amber
    /// material that never writes depth (so the ghost reads as a
    /// preview layered over the committed solid).
    static func makeGhostGeometry(_ mesh: Mesh) -> SCNGeometry {
        let geometry = makeGeometry(mesh, material: MaterialLibrary.defaultMaterial)
        let ghost = SCNMaterial()
        ghost.lightingModel = .physicallyBased
        ghost.diffuse.contents = UIColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 1)
        ghost.transparency = 0.55  // ≈ 0.45 opacity
        ghost.isDoubleSided = true
        ghost.writesToDepthBuffer = false
        geometry.materials = [ghost]
        return geometry
    }

    // MARK: Selection highlight

    /// Change fingerprint for the selection highlight: which thing is
    /// picked (with its identifying numbers) + the mesh it was picked
    /// from, so a rebuild swaps the highlight out.
    static func selectionKey(picked: PickedSelection?, mesh: Mesh) -> String {
        let meshPart = "\(mesh.triangleCount)|\(mesh.volume)"
        guard let picked else { return "none|\(meshPart)" }
        switch picked {
        case .face(let index, _, _):
            return "face-\(index)|\(meshPart)"
        case .edge(_, let s, let e, _):
            return String(format: "edge-%.3f,%.3f,%.3f-%.3f,%.3f,%.3f|%@",
                          s.x, s.y, s.z, e.x, e.y, e.z, meshPart)
        case .shaft(let fit):
            return String(format: "shaft-%.3f,%.3f,%.3f,%.3f",
                          fit.origin.x + fit.origin.y + fit.origin.z,
                          fit.radius, fit.height) + "|\(meshPart)"
        case .holeWall(let fit):
            return String(format: "hole-%.3f,%.3f,%.3f,%.3f",
                          fit.origin.x + fit.origin.y + fit.origin.z,
                          fit.radius, fit.height) + "|\(meshPart)"
        }
    }

    /// Keep the selection highlight node in sync with `picked`:
    /// an amber overlay for face/edge/shaft, blue for a hole wall.
    /// Highlight nodes are named "selection" and are excluded from
    /// picking because every hit test filters to the model node.
    private func updateSelection(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        let key = Self.selectionKey(picked: picked, mesh: pickedMesh)
        guard coord.selectionKey != key else { return }
        coord.selectionKey = key
        coord.selectionNode?.removeFromParentNode()
        coord.selectionNode = nil
        guard let picked else { return }
        let root = SCNNode()
        root.name = "selection"
        root.renderingOrder = 9
        switch picked {
        case .face(let index, let face, _):
            if let geo = Self.makeFaceHighlightGeometry(mesh: pickedMesh,
                                                        faceIndex: index,
                                                        normal: face.plane.normal) {
                root.addChildNode(SCNNode(geometry: geo))
            }
        case .edge(_, let start, let end, let length):
            Self.addEdgeHighlight(to: root, start: start, end: end, length: length)
        case .shaft(let fit):
            if let sleeve = Self.sleeveMesh(fit: fit, radius: fit.radius + 0.15) {
                let node = SCNNode(geometry: Self.makeSleeveGeometry(
                    sleeve, color: amberColor, opacity: 0.30))
                node.renderingOrder = 9
                root.addChildNode(node)
            }
        case .holeWall(let fit):
            // The sleeve sits just INSIDE the hole radius: at the
            // radius itself (or beyond) it would be buried in the
            // surrounding material and depth-hidden from every angle.
            if let sleeve = Self.sleeveMesh(fit: fit, radius: max(0.05, fit.radius - 0.15)) {
                let node = SCNNode(geometry: Self.makeSleeveGeometry(
                    sleeve, color: UIColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1),
                    opacity: 0.35))
                node.renderingOrder = 9
                root.addChildNode(node)
            }
        }
        view.scene?.rootNode.addChildNode(root)
        coord.selectionNode = root
    }

    /// Flat triangle soup for one grouped face of the mesh, in the
    /// welded vertex space groupedFaces reports.
    static func makeFaceHighlightGeometry(mesh: Mesh, faceIndex: Int,
                                          normal: Vec3) -> SCNGeometry? {
        guard mesh.triangleCount > 0 else { return nil }
        let grouped = FaceExtractor.groupedFaces(of: mesh)
        guard faceIndex >= 0, faceIndex < grouped.triangles.count else { return nil }
        let welded = grouped.mesh
        var positions: [Float] = []
        var normals: [Float] = []
        var indices: [UInt32] = []
        for t in grouped.triangles[faceIndex] {
            for k in 0..<3 {
                let v = welded.vertices[Int(welded.indices[t * 3 + k])]
                positions.append(Float(v.x)); positions.append(Float(v.y)); positions.append(Float(v.z))
                normals.append(Float(normal.x)); normals.append(Float(normal.y)); normals.append(Float(normal.z))
                indices.append(UInt32(indices.count))
            }
        }
        guard !indices.isEmpty else { return nil }
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let norData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let idxData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: posData, semantic: .vertex, vectorCount: indices.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let normalSource = SCNGeometrySource(
            data: norData, semantic: .normal, vectorCount: indices.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(
            data: idxData, primitiveType: .triangles,
            primitiveCount: indices.count / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = amberColor
        mat.transparency = 0.65  // 0.35 opacity
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        geometry.materials = [mat]
        return geometry
    }

    /// A slim amber cylinder along the edge segment plus a sphere at
    /// each end — reads clearly at any zoom, unlike a 1px line.
    static func addEdgeHighlight(to root: SCNNode, start: Vec3, end: Vec3, length: Double) {
        guard length > 1e-6 else { return }
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = amberColor
        mat.isDoubleSided = true
        let radius = max(0.6, length * 0.01)
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cylinder.materials = [mat]
        let cylNode = SCNNode(geometry: cylinder)
        let mid = (start + end) * 0.5
        cylNode.position = SCNVector3(Float(mid.x), Float(mid.y), Float(mid.z))
        // SCNCylinder runs along +Y; rotate +Y onto the edge direction.
        let up = Vec3(0, 1, 0)
        let dir = (end - start).normalized
        let cross = up.cross(dir)
        if cross.length > 1e-6 {
            let axis = cross.normalized
            let angle = acos(max(-1, min(1, up.dot(dir))))
            cylNode.rotation = SCNVector4(Float(axis.x), Float(axis.y),
                                          Float(axis.z), Float(angle))
        }
        root.addChildNode(cylNode)
        for p in [start, end] {
            let sphere = SCNSphere(radius: CGFloat(radius * 1.7))
            sphere.materials = [mat]
            let sNode = SCNNode(geometry: sphere)
            sNode.position = SCNVector3(Float(p.x), Float(p.y), Float(p.z))
            root.addChildNode(sNode)
        }
    }

    /// A plain cylinder mesh fitted over a shaft / hole wall, placed
    /// with the kit's rigid placement (local +Z → the fitted axis).
    static func sleeveMesh(fit: CylinderFit, radius: Double) -> Mesh? {
        guard radius > 0, fit.height > 0,
              let cyl = try? Tessellation.cylinder(radius: radius, height: fit.height)
        else { return nil }
        return cyl.placed(axis: fit.axis, origin: fit.origin)
    }

    /// Smooth soup geometry like the model's, with one translucent
    /// material that never writes depth (preview-style layering).
    static func makeSleeveGeometry(_ mesh: Mesh, color: UIColor, opacity: CGFloat) -> SCNGeometry {
        let geometry = makeGeometry(mesh, material: MaterialLibrary.defaultMaterial)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = color
        mat.transparency = 1 - opacity
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        geometry.materials = [mat]
        return geometry
    }

    // MARK: Sketch overlays

    /// Keep the sketch overlay nodes in sync with the overlay inputs.
    private func updateOverlays(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        let key = Self.overlayKey(sketches: sketches, selectedID: selectedSketchID,
                                  hidden: hiddenSketchIDs, show: showSketches)
        guard coord.overlayKey != key else { return }
        coord.overlayKey = key
        coord.overlayNode?.removeFromParentNode()
        coord.overlayNode = nil
        guard showSketches else { return }
        let root = SCNNode()
        root.name = "sketchOverlays"
        for sketch in sketches where !hiddenSketchIDs.contains(sketch.id) {
            root.addChildNode(Self.makeSketchNode(sketch, selected: sketch.id == selectedSketchID))
        }
        view.scene?.rootNode.addChildNode(root)
        coord.overlayNode = root
    }

    /// Change fingerprint for the overlays: visibility, selection,
    /// each sketch's plane origin, entity count, and a cheap shape
    /// sample (first polyline point per entity) so in-place sketch
    /// edits refresh the overlay too.
    static func overlayKey(sketches: [Sketch], selectedID: String?,
                           hidden: Set<String>, show: Bool) -> String {
        var parts = [show ? "show" : "hide", selectedID ?? "-"]
        for s in sketches {
            var fp = "\(s.id)#\(hidden.contains(s.id) ? 1 : 0)#\(s.entities.count)#"
            fp += String(format: "%.2f,%.2f,%.2f", s.plane.origin.x, s.plane.origin.y, s.plane.origin.z)
            for e in s.entities {
                let pts = e.polyline()
                if let f = pts.first {
                    fp += "|\(pts.count)@\(String(format: "%.2f,%.2f", f.x, f.y))"
                } else {
                    fp += "|0"
                }
            }
            parts.append(fp)
        }
        return parts.joined(separator: ";")
    }

    /// One sketch's overlay node: entity polylines as line strips on
    /// the sketch plane (cyan, or amber when selected; construction
    /// entities dim gray). The selected sketch also gets a
    /// translucent fill over its extents. Datum planes draw only a
    /// dashed-look 40×40 mm outline.
    static func makeSketchNode(_ sketch: Sketch, selected: Bool) -> SCNNode {
        let node = SCNNode()
        node.name = "sketch-\(sketch.id)"
        node.renderingOrder = 6
        let plane = sketch.plane

        if sketch.isDatumPlane {
            // 40×40 mm square, four dashes per edge ("dashed look").
            var segments: [(Vec3, Vec3)] = []
            let corners = [Vec2(-20, -20), Vec2(20, -20), Vec2(20, 20), Vec2(-20, 20)]
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                for d in 0..<4 {
                    let t0 = Double(d) / 4 + 0.04, t1 = Double(d) / 4 + 0.19
                    segments.append((plane.toWorld(a + (b - a) * t0),
                                     plane.toWorld(a + (b - a) * t1)))
                }
            }
            if let geo = lineGeometry(segments: segments,
                                      material: lineMaterial(tealColor, opacity: 0.15)) {
                node.addChildNode(SCNNode(geometry: geo))
            }
            return node
        }

        var solid: [(Vec3, Vec3)] = []
        var construction: [(Vec3, Vec3)] = []
        var lo = Vec2(Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
        var hi = Vec2(-Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        var hasPoints = false
        for entity in sketch.entities {
            let pts = entity.polyline()
            for p in pts {
                lo = Vec2(min(lo.x, p.x), min(lo.y, p.y))
                hi = Vec2(max(hi.x, p.x), max(hi.y, p.y))
                hasPoints = true
            }
            if pts.count == 1 {
                // A point entity: draw a small cross so it is visible.
                let c = pts[0], r = 1.2
                let cross = [(c + Vec2(-r, 0), c + Vec2(r, 0)), (c + Vec2(0, -r), c + Vec2(0, r))]
                for (a, b) in cross {
                    if entity.isConstruction { construction.append((plane.toWorld(a), plane.toWorld(b))) }
                    else { solid.append((plane.toWorld(a), plane.toWorld(b))) }
                }
            }
            if pts.count > 1 {
                for i in 0..<(pts.count - 1) {
                    let seg = (plane.toWorld(pts[i]), plane.toWorld(pts[i + 1]))
                    if entity.isConstruction { construction.append(seg) } else { solid.append(seg) }
                }
            }
        }
        let mainColor = selected ? amberColor : cyanColor
        if let geo = lineGeometry(segments: solid,
                                  material: lineMaterial(mainColor, opacity: selected ? 1.0 : 0.9)) {
            node.addChildNode(SCNNode(geometry: geo))
        }
        if let geo = lineGeometry(segments: construction,
                                  material: lineMaterial(grayColor, opacity: 0.45)) {
            node.addChildNode(SCNNode(geometry: geo))
        }
        if selected, hasPoints {
            // Translucent fill over the sketch's extents (padded,
            // at least 12 mm across) so the selection is unmistakable.
            let w = max(hi.x - lo.x + 6, 12)
            let h = max(hi.y - lo.y + 6, 12)
            let center2 = Vec2((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
            let fill = SCNPlane(width: CGFloat(w), height: CGFloat(h))
            let fillMat = SCNMaterial()
            fillMat.lightingModel = .constant
            fillMat.diffuse.contents = amberColor
            fillMat.transparency = 0.90  // 0.10 opacity
            fillMat.isDoubleSided = true
            fillMat.writesToDepthBuffer = false
            fill.materials = [fillMat]
            let fillNode = SCNNode(geometry: fill)
            fillNode.renderingOrder = 5
            let x = plane.xAxis, y = plane.yAxis, n = plane.normal
            let o = plane.toWorld(center2)
            var m = SCNMatrix4()
            m.m11 = Float(x.x); m.m12 = Float(x.y); m.m13 = Float(x.z); m.m14 = 0
            m.m21 = Float(y.x); m.m22 = Float(y.y); m.m23 = Float(y.z); m.m24 = 0
            m.m31 = Float(n.x); m.m32 = Float(n.y); m.m33 = Float(n.z); m.m34 = 0
            m.m41 = Float(o.x); m.m42 = Float(o.y); m.m43 = Float(o.z); m.m44 = 1
            fillNode.transform = m
            node.addChildNode(fillNode)
        }
        return node
    }

    static let cyanColor = UIColor(red: 0.20, green: 0.85, blue: 1.0, alpha: 1)
    static let amberColor = UIColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 1)
    static let grayColor = UIColor(red: 0.65, green: 0.68, blue: 0.72, alpha: 1)
    static let tealColor = UIColor(red: 0.30, green: 0.85, blue: 0.80, alpha: 1)

    static func lineMaterial(_ color: UIColor, opacity: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.transparency = 1 - opacity
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }

    /// A line-strip geometry from world-space segments.
    static func lineGeometry(segments: [(Vec3, Vec3)], material: SCNMaterial) -> SCNGeometry? {
        guard !segments.isEmpty else { return nil }
        var positions: [Float] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(segments.count * 6)
        indices.reserveCapacity(segments.count * 2)
        for (a, b) in segments {
            let base = UInt32(positions.count / 3)
            positions.append(Float(a.x)); positions.append(Float(a.y)); positions.append(Float(a.z))
            positions.append(Float(b.x)); positions.append(Float(b.y)); positions.append(Float(b.z))
            indices.append(base); indices.append(base + 1)
        }
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let idxData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: posData, semantic: .vertex, vectorCount: segments.count * 2,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(
            data: idxData, primitiveType: .line,
            primitiveCount: segments.count, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        geometry.materials = [material]
        return geometry
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
