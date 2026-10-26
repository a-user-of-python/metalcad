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
    /// True when `mesh` is an uncommitted DRAFT result. The preview
    /// REPLACES the committed model (Fusion-style): it is rendered as
    /// the one model mesh with a warm accent emissive tint, never as
    /// a translucent overlay — an overlay copy of the whole part sat
    /// exactly on the model's surfaces and z-fought into jagged
    /// shards (device report, 2026-10-26). While a preview is active
    /// it also takes precedence over the section view (the caller
    /// passes the preview instead of the sectioned mesh; the old
    /// ghost ignored section too).
    var isPreview: Bool = false
    /// The open document's id. The camera pose is persisted per
    /// document (see the pose store below) so leaving and returning
    /// — or anything recreating this view — restores his viewpoint
    /// instead of reframing.
    var documentID: String = ""
    /// The user's accent color (Home ▸ Settings), used for the
    /// selection highlight, the selected-sketch glow, the measure
    /// markers and the preview tint.
    var accentUIColor: UIColor = MCAccent.uiColor(hex: MCAccent.defaultHex)
    /// Sketches to draw as 3D overlays (tap one to select it).
    var sketches: [Sketch] = []
    /// The currently selected sketch (amber glow outline).
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
    /// Tapped points of the always-on quick measure (0–2), drawn as
    /// amber sphere markers plus a span line — the "measure" node,
    /// never hit-tested (every pick filters to the model node).
    var measurePoints: [Vec3] = []
    /// Called when a NORMAL-mode tap lands on the model: the welded
    /// triangle index and the hit point (model-node local coords —
    /// the node sits at the origin, so these are scene coords).
    var onModelHit: ((Int, Vec3) -> Void)? = nil
    /// Called when a double-tap lands on the model (normal mode
    /// only): the welded triangle index and hit point, same space as
    /// `onModelHit`. The single-tap recognizer is deliberately NOT
    /// made to wait for this one (no require(toFail:)) — tap-to-
    /// select keeps zero added latency; a double-tap simply ALSO
    /// raises this after the second tap's ordinary selection.
    var onModelDoubleTap: ((Int, Vec3) -> Void)? = nil

    final class Coordinator: NSObject {
        var geometryKey: String = ""
        var overlayKey: String = ""
        var selectionKey: String = ""
        var measureKey: String = ""
        var modelNode: SCNNode?
        var overlayNode: SCNNode?
        var selectionNode: SCNNode?
        var measureNode: SCNNode?
        var cameraNode: SCNNode?
        var framed: Bool = false
        /// CrashTrace: the first updateUIView has completed (and
        /// cleared the crash-pending flag) for this view.
        var tracedFirstUpdate: Bool = false
        /// The document the live camera currently belongs to; a
        /// change triggers a pose restore (or a first-time frame).
        var currentDocumentID: String = ""
        var onFacePicked: ((Int) -> Void)?
        var onSketchPicked: ((String?) -> Void)?
        var onModelHit: ((Int, Vec3) -> Void)?
        var onModelDoubleTap: ((Int, Vec3) -> Void)?
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
                // Only the model node counts — the sketch overlays
                // also carry geometry but must never answer a face pick.
                guard let hit = hits.first(where: { $0.node === modelNode }) else { return }
                onFacePicked?(hit.faceIndex)
                return
            }
            // Normal mode: a tap ON the model resolves a picked
            // selection first (edge → face → shaft/hole, in the
            // model). The filter to the model node keeps the sketch
            // overlays and the selection highlight itself from ever
            // answering the tap. Only a tap that misses the
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

        /// Double-tap on the model = the quick-pull shortcut. Face
        /// picking is a deliberate single-tap flow, so this stays out
        /// of its way: in pick mode a double-tap is just two picks,
        /// already handled by handleTap. Otherwise it hit-tests for
        /// itself and reports only model hits — empty
        /// space, overlays and the selection highlight
        /// never raise it.
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard !isPickingFace, let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            let options: [SCNHitTestOption: Any] = [
                .searchMode: NSNumber(value: SCNHitTestSearchMode.closest.rawValue),
                .boundingBoxOnly: NSNumber(value: false),
                .ignoreChildNodes: NSNumber(value: false),
            ]
            let hits = view.hitTest(point, options: options)
            guard let hit = hits.first(where: { $0.node === modelNode }) else { return }
            let c = hit.localCoordinates
            onModelDoubleTap?(hit.faceIndex,
                              Vec3(Double(c.x), Double(c.y), Double(c.z)))
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

    // MARK: Camera pose persistence

    /// A saved viewpoint: the camera node's position + orientation.
    private struct CameraPose {
        var position: SCNVector3
        var orientation: SCNQuaternion
    }

    /// Session-level pose store, keyed by document id. The camera
    /// used to reset to the default framing after every commit
    /// (device report, 2026-10-26): anything that recreated this
    /// view — the mesh-based `.id` the editor used, panel columns
    /// appearing, document switches — made a fresh Coordinator whose
    /// `framed` flag framed the part all over again. Now the pose is
    /// saved on every update and on dismantle, and restored whenever
    /// a view (re)appears for a document that has one; framing to
    /// bounds happens ONLY for a document's first-ever view.
    private static var poseStore: [String: CameraPose] = [:]

    /// Fingerprint of the accent color, folded into the node rebuild
    /// keys so highlights/tints recolor the moment the setting moves.
    private var accentKey: String {
        (accentUIColor.cgColor.components ?? [])
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        // Last chance to remember the viewpoint before teardown.
        guard coordinator.framed, !coordinator.currentDocumentID.isEmpty,
              let camNode = coordinator.cameraNode else { return }
        poseStore[coordinator.currentDocumentID] = CameraPose(
            position: camNode.position, orientation: camNode.orientation)
    }

    func makeUIView(context: Context) -> SCNView {
        CrashTrace.mark("scene: make begin")
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        // Power/thermal budget (device report, 2026-10-26: the iPad
        // ran hot): render ON DEMAND instead of continuously — the
        // built-in camera controller still invalidates the view
        // while orbiting — cap at 60 fps, and use 2x MSAA.
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 60

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
        // zFar is 6_000, not 20_000: depth-buffer precision is
        // zFar/zNear, and the huge far plane made the orange
        // selection z-fight with the grey model (same day's report).
        cam.zNear = 0.5
        cam.zFar = 6_000
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

        // Double tap: reports a model hit for the quick-pull shortcut.
        // Deliberately NOT paired with tap.require(toFail:) — that
        // would hold EVERY single tap hostage to the double-tap
        // window (~0.3 s of selection lag). Instead both recognizers
        // fire on a double tap: the second tap re-selects (harmless,
        // same target) and this one raises onModelDoubleTap.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        CrashTrace.mark("scene: make done")
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        CrashTrace.mark("scene: update begin")
        context.coordinator.onFacePicked = onFacePicked
        context.coordinator.onSketchPicked = onSketchPicked
        context.coordinator.onModelHit = onModelHit
        context.coordinator.onModelDoubleTap = onModelDoubleTap
        context.coordinator.isPickingFace = isPickingFace
        context.coordinator.sketchesInput = sketches
        context.coordinator.hiddenSketchIDsInput = hiddenSketchIDs
        context.coordinator.showSketchesInput = showSketches
        if isPickingFace {
            view.backgroundColor = UIColor(red: 0.13, green: 0.10, blue: 0.05, alpha: 1)
        } else {
            view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
        }

        // Camera pose: when the document changes under this view
        // (a fresh view for another document, or a recreation),
        // restore the saved pose for it if one exists — framing to
        // bounds is ONLY for a document's first-ever view.
        if context.coordinator.currentDocumentID != documentID {
            context.coordinator.currentDocumentID = documentID
            if !documentID.isEmpty, let pose = Self.poseStore[documentID],
               let camNode = context.coordinator.cameraNode {
                camNode.position = pose.position
                camNode.orientation = pose.orientation
                context.coordinator.framed = true
            } else {
                context.coordinator.framed = false
            }
        }

        // Sketch overlays + selection highlight + measure markers
        // refresh independently of the model geometry guard below.
        updateOverlays(view, context: context)
        updateSelection(view, context: context)
        updateMeasure(view, context: context)
        CrashTrace.mark("scene: after overlays")

        // Identity for "geometry must be rebuilt": mesh shape +
        // material + preview state + accent (the preview tint reads
        // the accent, so a settings change re-tints a live preview).
        let mat = material ?? MaterialLibrary.defaultMaterial
        let key = "\(mesh.triangleCount)|\(mesh.volume)|\(mat.id)|\(isPreview ? "preview" : "live")|\(accentKey)"
        if context.coordinator.geometryKey != key {
            context.coordinator.geometryKey = key

            context.coordinator.modelNode?.removeFromParentNode()
            let node = SCNNode(geometry: Self.makeGeometry(
                mesh, material: mat,
                previewAccent: isPreview ? accentUIColor : nil))
            view.scene?.rootNode.addChildNode(node)
            context.coordinator.modelNode = node

            // First-ever view of this document (no saved pose):
            // frame the part once.
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
        CrashTrace.mark("scene: after geometry")

        // Remember the camera exactly as it stands (restored,
        // framed, or orbited since) so the next recreation — or the
        // next visit to this document — restores it. Only deliberate
        // poses are saved: `framed` stays false until a restore or a
        // framing has placed the camera, so the makeUIView default
        // never lands in the store.
        if !documentID.isEmpty, context.coordinator.framed,
           let camNode = context.coordinator.cameraNode {
            Self.poseStore[documentID] = CameraPose(
                position: camNode.position, orientation: camNode.orientation)
        }

        // CrashTrace: surviving to the END of the first update
        // means the editor rendered — the creation attempt is
        // healthy and any pending crash trail is disarmed.
        if !context.coordinator.tracedFirstUpdate {
            context.coordinator.tracedFirstUpdate = true
            CrashTrace.mark("scene: first update done")
            CrashTrace.healthy()
        }
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
    /// an accent overlay for face/edge/shaft, blue for a hole wall.
    /// Highlight nodes are named "selection" and are excluded from
    /// picking because every hit test filters to the model node.
    private func updateSelection(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        let key = Self.selectionKey(picked: picked, mesh: pickedMesh) + "|acc:\(accentKey)"
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
                                                        normal: face.plane.normal,
                                                        color: accentUIColor) {
                root.addChildNode(SCNNode(geometry: geo))
            }
        case .edge(_, let start, let end, let length):
            Self.addEdgeHighlight(to: root, start: start, end: end,
                                  length: length, color: accentUIColor)
        case .shaft(let fit):
            if let sleeve = Self.sleeveMesh(fit: fit, radius: fit.radius + 0.15) {
                let node = SCNNode(geometry: Self.makeSleeveGeometry(
                    sleeve, color: accentUIColor, opacity: 0.30))
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

    // MARK: Quick-measure markers

    /// Change fingerprint for the measure markers: the points
    /// themselves, so moving a point (or clearing) rebuilds the node.
    static func measureKey(points: [Vec3]) -> String {
        points.map { String(format: "%.3f,%.3f,%.3f", $0.x, $0.y, $0.z) }
            .joined(separator: ";")
    }

    /// Keep the measure marker node in sync with `measurePoints`:
    /// an accent sphere at each tapped point and, once two points
    /// exist, a slim accent cylinder for the A–B span (a cylinder,
    /// not a 1 px line, so it reads at any zoom — same trick as the
    /// edge highlight). Named "measure", renderingOrder 9 like the
    /// selection highlight, and never hit-tested: every pick in the
    /// coordinator filters to the model node only.
    private func updateMeasure(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        let key = Self.measureKey(points: measurePoints) + "|acc:\(accentKey)"
        guard coord.measureKey != key else { return }
        coord.measureKey = key
        coord.measureNode?.removeFromParentNode()
        coord.measureNode = nil
        guard !measurePoints.isEmpty else { return }
        let root = SCNNode()
        root.name = "measure"
        root.renderingOrder = 9
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = accentUIColor
        mat.isDoubleSided = true
        for p in measurePoints {
            let sphere = SCNSphere(radius: 1.4)
            sphere.materials = [mat]
            let sNode = SCNNode(geometry: sphere)
            sNode.position = SCNVector3(Float(p.x), Float(p.y), Float(p.z))
            root.addChildNode(sNode)
        }
        if measurePoints.count == 2 {
            let a = measurePoints[0], b = measurePoints[1]
            let length = a.distance(to: b)
            if length > 1e-6 {
                let cylinder = SCNCylinder(radius: 0.5, height: CGFloat(length))
                cylinder.materials = [mat]
                let cylNode = SCNNode(geometry: cylinder)
                let mid = (a + b) * 0.5
                cylNode.position = SCNVector3(Float(mid.x), Float(mid.y), Float(mid.z))
                // SCNCylinder runs along +Y; rotate +Y onto A→B.
                let up = Vec3(0, 1, 0)
                let dir = (b - a).normalized
                let cross = up.cross(dir)
                if cross.length > 1e-6 {
                    let axis = cross.normalized
                    let angle = acos(max(-1, min(1, up.dot(dir))))
                    cylNode.rotation = SCNVector4(Float(axis.x), Float(axis.y),
                                                  Float(axis.z), Float(angle))
                } else if dir.y < 0 {
                    // Span runs straight down: flip the cylinder.
                    cylNode.rotation = SCNVector4(1, 0, 0, Float(Double.pi))
                }
                root.addChildNode(cylNode)
            }
        }
        view.scene?.rootNode.addChildNode(root)
        coord.measureNode = root
    }

    /// Flat triangle soup for one grouped face of the mesh, in the
    /// welded vertex space groupedFaces reports. Every vertex is
    /// pushed +0.05 mm along the face normal so the highlight sits
    /// PROUD of the model surface instead of coplanar with it
    /// (coplanar = the orange/grey clipping shimmer reported
    /// on-device, 2026-10-26).
    static func makeFaceHighlightGeometry(mesh: Mesh, faceIndex: Int,
                                          normal: Vec3, color: UIColor) -> SCNGeometry? {
        guard mesh.triangleCount > 0 else { return nil }
        let grouped = FaceExtractor.groupedFaces(of: mesh)
        guard faceIndex >= 0, faceIndex < grouped.triangles.count else { return nil }
        let welded = grouped.mesh
        let lift = normal * 0.05
        var positions: [Float] = []
        var normals: [Float] = []
        var indices: [UInt32] = []
        for t in grouped.triangles[faceIndex] {
            for k in 0..<3 {
                let v = welded.vertices[Int(welded.indices[t * 3 + k])] + lift
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
        mat.diffuse.contents = color
        mat.transparency = 0.65  // 0.35 opacity
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        geometry.materials = [mat]
        return geometry
    }

    /// A slim accent cylinder along the edge segment plus a sphere at
    /// each end — reads clearly at any zoom, unlike a 1px line.
    static func addEdgeHighlight(to root: SCNNode, start: Vec3, end: Vec3,
                                 length: Double, color: UIColor) {
        guard length > 1e-6 else { return }
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = color
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
            + "|acc:\(accentKey)"
        guard coord.overlayKey != key else { return }
        coord.overlayKey = key
        coord.overlayNode?.removeFromParentNode()
        coord.overlayNode = nil
        guard showSketches else { return }
        let root = SCNNode()
        root.name = "sketchOverlays"
        for sketch in sketches where !hiddenSketchIDs.contains(sketch.id) {
            root.addChildNode(Self.makeSketchNode(sketch,
                                                  selected: sketch.id == selectedSketchID,
                                                  accent: accentUIColor))
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
    /// the sketch plane (cyan; construction entities dim gray). The
    /// SELECTED sketch's outline itself glows in the accent color:
    /// every segment is drawn as a halo tube + a bright core tube, with spheres at
    /// the vertices — no bounding-box fill (device request,
    /// 2026-10-26). Datum planes draw only a dashed-look 40×40 mm
    /// outline. The whole node is lifted +0.05 mm along the plane
    /// normal so the overlay never sits coplanar with a model face
    /// it lies on (z-fighting).
    static func makeSketchNode(_ sketch: Sketch, selected: Bool, accent: UIColor) -> SCNNode {
        let node = SCNNode()
        node.name = "sketch-\(sketch.id)"
        node.renderingOrder = 6
        let plane = sketch.plane
        node.position = SCNVector3(Float(plane.normal.x * 0.05),
                                   Float(plane.normal.y * 0.05),
                                   Float(plane.normal.z * 0.05))

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
        var solidVertices: [Vec3] = []
        for entity in sketch.entities {
            let pts = entity.polyline()
            if !entity.isConstruction {
                solidVertices += pts.map { plane.toWorld($0) }
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
        if selected {
            // The outline ITSELF glows: a wide faint halo tube and a
            // thin bright core tube per segment, plus a sphere at
            // every polyline vertex. (SceneKit lines are 1 px and
            // can't glow; the tube pair reads as a glow at any zoom.)
            let haloMat = lineMaterial(accent, opacity: 0.30)
            let coreMat = lineMaterial(accent, opacity: 1.0)
            for (a, b) in solid {
                if let halo = tubeNode(from: a, to: b, radius: 0.9, material: haloMat) {
                    node.addChildNode(halo)
                }
                if let core = tubeNode(from: a, to: b, radius: 0.35, material: coreMat) {
                    node.addChildNode(core)
                }
            }
            for p in solidVertices {
                let sphere = SCNSphere(radius: 0.55)
                sphere.materials = [coreMat]
                let sNode = SCNNode(geometry: sphere)
                sNode.position = SCNVector3(Float(p.x), Float(p.y), Float(p.z))
                node.addChildNode(sNode)
            }
        } else if let geo = lineGeometry(segments: solid,
                                         material: lineMaterial(cyanColor, opacity: 0.9)) {
            node.addChildNode(SCNNode(geometry: geo))
        }
        if let geo = lineGeometry(segments: construction,
                                  material: lineMaterial(grayColor, opacity: 0.45)) {
            node.addChildNode(SCNNode(geometry: geo))
        }
        return node
    }

    /// A cylinder node spanning a→b (SCNCylinder runs along +Y;
    /// rotate +Y onto the segment direction). Nil for a degenerate
    /// (zero-length) segment.
    static func tubeNode(from a: Vec3, to b: Vec3, radius: Double,
                         material: SCNMaterial) -> SCNNode? {
        let length = a.distance(to: b)
        guard length > 1e-6 else { return nil }
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        let mid = (a + b) * 0.5
        node.position = SCNVector3(Float(mid.x), Float(mid.y), Float(mid.z))
        let up = Vec3(0, 1, 0)
        let dir = (b - a).normalized
        let cross = up.cross(dir)
        if cross.length > 1e-6 {
            let axis = cross.normalized
            let angle = acos(max(-1, min(1, up.dot(dir))))
            node.rotation = SCNVector4(Float(axis.x), Float(axis.y),
                                       Float(axis.z), Float(angle))
        } else if dir.y < 0 {
            // Segment runs straight down: flip the cylinder.
            node.rotation = SCNVector4(1, 0, 0, Float(Double.pi))
        }
        return node
    }

    static let cyanColor = UIColor(red: 0.20, green: 0.85, blue: 1.0, alpha: 1)
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
    /// When `previewAccent` is set the mesh is an uncommitted draft:
    /// the part's own material gets a warm accent emissive wash
    /// (~0.35) so it still shades like the real part but is
    /// unmistakably "preview, not committed".
    static func makeGeometry(_ mesh: Mesh, material: Material,
                             previewAccent: UIColor? = nil) -> SCNGeometry {
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
        if let previewAccent {
            scnMaterial.emission.contents = previewAccent
            scnMaterial.emission.intensity = 0.35
        }
        geometry.materials = [scnMaterial]
        return geometry
    }
}
