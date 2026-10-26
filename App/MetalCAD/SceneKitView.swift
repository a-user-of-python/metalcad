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
    /// When true, the three base planes glow at the origin in their
    /// axis colors — YZ red (normal +X), XZ green (normal −Y), XY
    /// blue (normal +Z) — matching the New Sketch panel's plane
    /// cards while a plane is being chosen.
    var showBasePlanes: Bool = false
    /// Draw the model's sharp (crease) edges as thin dark lines —
    /// the shaded-with-edges look of normal CAD. Gated by the
    /// caller to meshes under ~80k triangles (see updateEdges).
    var showModelEdges: Bool = true
    /// The editor model, passed while an in-place sketch session may
    /// be live. When `sketchModel.activeSketchID != nil` the view
    /// switches to sketch input: one-finger/pencil strokes draw on
    /// the active sketch's plane (camera control is replaced by a
    /// two-finger orbit + pinch), pencil hover tracks the snapped
    /// point, and the grid / preview / selection overlays render.
    /// Nil (the default) keeps every pre-session behavior.
    var sketchModel: EditorModel? = nil
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

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var geometryKey: String = ""
        var overlayKey: String = ""
        var selectionKey: String = ""
        var measureKey: String = ""
        var basePlanesKey: String = ""
        var edgeNode: SCNNode?
        var edgeKey: String = ""
        var modelNode: SCNNode?
        var overlayNode: SCNNode?
        var selectionNode: SCNNode?
        var measureNode: SCNNode?
        var basePlanesNode: SCNNode?
        var cameraNode: SCNNode?
        var framed: Bool = false
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
        // In-place sketch session state (see `sketchModel`).
        weak var sketchModel: EditorModel?
        var sketchModeActive = false
        var strokeInFlight = false
        var orbitTarget: Vec3 = .zero
        var lastPinchScale: CGFloat = 1
        var sketchTrack: UILongPressGestureRecognizer?
        var orbitPan: UIPanGestureRecognizer?
        var orbitPinch: UIPinchGestureRecognizer?
        var pencilHover: UIHoverGestureRecognizer?
        var sketchSessionNode: SCNNode?
        var sketchGridNode: SCNNode?
        var sketchGridKey: String = ""
        // v1.13 session-dynamic layer: preview / hover marker /
        // working-copy nodes, owned and rebuilt IMPERATIVELY by
        // this coordinator from the gesture handlers — never via a
        // SwiftUI rebuild key (that round-trip was the v1.12
        // freeze: every hover/drag event rebuilt geometry).
        var sketchWorkingNode: SCNNode?
        var sketchPreviewNode: SCNNode?
        var sketchHoverNode: SCNNode?
        var sketchGuideNode: SCNNode?
        var sketchGuideKey: String = ""
        /// Accent color snapshot for the imperative layer
        /// (refreshed by updateUIView).
        var accentInput: UIColor = UIColor(red: 0.30, green: 0.85, blue: 0.80, alpha: 1)
        /// Nonce of the last camera-snap request consumed.
        var lastSnapNonce: Int = 0

        /// Project a view point onto a sketch plane — the same
        /// unproject + ray/plane intersection the sketch picking
        /// below uses — returning plane-space coordinates.
        func planePoint(at point: CGPoint, in view: SCNView, plane: Plane3) -> Vec2? {
            let near3 = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
            let far3 = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
            let origin = Vec3(Double(near3.x), Double(near3.y), Double(near3.z))
            let far = Vec3(Double(far3.x), Double(far3.y), Double(far3.z))
            let span = far - origin
            guard span.length > 1e-9 else { return nil }
            let dir = span.normalized
            let denom = dir.dot(plane.normal)
            guard abs(denom) > 1e-9 else { return nil }
            let t = (plane.origin - origin).dot(plane.normal) / denom
            guard t > 0 else { return nil }
            let hit = origin + dir * t
            let local = hit - plane.origin
            return Vec2(local.dot(plane.xAxis), local.dot(plane.yAxis))
        }

        /// Place the camera perfectly face-on to a plane (v1.13):
        /// on the plane's normal through its origin, screen-up =
        /// the plane's local V axis, at a distance framing about
        /// ±110 mm vertically. The orientation is written as an
        /// explicit basis matrix — `look(at:)` alone would hit
        /// gimbal degeneracy for the XZ plane (camera forward
        /// parallel to world +Y up). Instant: a snap that animates
        /// is a snap the user waits on.
        func snapCameraToPlane(origin: Vec3, normal: Vec3, vAxis: Vec3) {
            guard let cam = cameraNode else { return }
            let fovDeg = Double(cam.camera?.fieldOfView ?? 60)
            let dist = min(max(110.0 / max(tan(fovDeg * .pi / 360), 0.1), 60), 900)
            let z = normal.length > 1e-9 ? normal.normalized : Vec3(0, 0, 1)
            var x = vAxis.cross(z)
            if x.length < 1e-6 {
                x = Vec3(1, 0, 0).cross(z)
                if x.length < 1e-6 { x = Vec3(0, 1, 0).cross(z) }
            }
            x = x.normalized
            let y = z.cross(x).normalized
            let pos = origin + z * dist
            var m = SCNMatrix4()
            m.m11 = Float(x.x); m.m12 = Float(x.y); m.m13 = Float(x.z); m.m14 = 0
            m.m21 = Float(y.x); m.m22 = Float(y.y); m.m23 = Float(y.z); m.m24 = 0
            m.m31 = Float(z.x); m.m32 = Float(z.y); m.m33 = Float(z.z); m.m34 = 0
            m.m41 = Float(pos.x); m.m42 = Float(pos.y); m.m43 = Float(pos.z); m.m44 = 1
            cam.transform = m
            orbitTarget = origin
        }

        /// Hit-test a view point against the MODEL NODE ONLY
        /// (v1.13). v1.12 hit-tested the whole view with
        /// `searchMode .closest`, which returns only the single
        /// nearest hit — and the sketch-overlay halo tubes sit
        /// 0.05 mm proud of the model faces (directly over the very
        /// profile that was extruded), the edge lines 0.03 mm
        /// proud, the grid above its plane — so the nearest hit
        /// was routinely an overlay node, the `node === modelNode`
        /// filter discarded it, and the tap selected NOTHING (and
        /// face picking, same filter, failed the same way).
        /// Testing the model node's own subtree cannot see overlay
        /// nodes at all. The model node sits at the origin with no
        /// transform, so local coordinates are scene coordinates,
        /// and faceIndex addresses the geometry's triangles — the
        /// display-soup order, exactly as before.
        func modelHit(at point: CGPoint, in view: SCNView)
            -> (faceIndex: Int, point: Vec3)? {
            guard let node = modelNode else { return nil }
            let near3 = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
            let far3 = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
            let hits = node.hitTestWithSegment(
                from: near3, to: far3,
                options: [SCNHitTestSearchModeKey: NSNumber(value: SCNHitTestSearchMode.closest.rawValue),
                          SCNHitTestBoundingBoxOnlyKey: NSNumber(value: false)])
            guard let hit = hits.first else { return nil }
            let c = hit.localCoordinates
            return (hit.faceIndex, Vec3(Double(c.x), Double(c.y), Double(c.z)))
        }

        /// The session recognizers may recognize SIMULTANEOUSLY
        /// with each other (v1.13) — UIKit's default exclusivity
        /// was why the camera never moved while sketching: the
        /// zero-duration stroke tracker begins on the first touch
        /// and, under the default rules, the two-finger orbit pan
        /// and pinch could never begin afterwards. The stroke
        /// handler already cancels/rolls back cleanly when a
        /// second touch lands, and the orbit handlers cancel any
        /// in-flight stroke when they begin.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            let session: [UIGestureRecognizer?] = [sketchTrack, orbitPan, orbitPinch]
            return session.contains { $0 === gestureRecognizer }
                && session.contains { $0 === otherGestureRecognizer }
        }

        /// The session root node, created on demand (rendering
        /// order 7: over the sketch overlays at 6, under the
        /// selection highlight at 9).
        func ensureSessionRoot(in view: SCNView) -> SCNNode? {
            if let root = sketchSessionNode { return root }
            guard sketchModel?.activeSketchID != nil else { return nil }
            let root = SCNNode()
            root.name = "sketchSession"
            root.renderingOrder = 7
            view.scene?.rootNode.addChildNode(root)
            sketchSessionNode = root
            return root
        }

        /// Rebuild ONLY the session's dynamic layer — the working
        /// copy's lines, the selected entities' glow, the stroke
        /// preview, the hover marker — from the model's current
        /// transient state. Called imperatively by the gesture /
        /// hover handlers after every pointer event, and by
        /// updateSketchSession for discrete state changes. Plain
        /// line geometry (one build per node), so a pointer move
        /// costs a few small allocations — never a model or
        /// overlay rebuild.
        func refreshSessionDynamics(in view: SCNView) {
            guard let model = sketchModel, let working = model.activeSketch,
                  let root = ensureSessionRoot(in: view) else { return }
            let plane = working.plane
            let accent = accentInput
            let lift = plane.normal * 0.07
            let liftV = SCNVector3(Float(lift.x), Float(lift.y), Float(lift.z))

            sketchWorkingNode?.removeFromParentNode()
            let wNode = SCNNode()
            wNode.name = "sketchWorking"
            wNode.renderingOrder = 7
            wNode.position = liftV
            var plain: [(Vec3, Vec3)] = []
            let haloMat = SceneKitView.lineMaterial(accent, opacity: 0.30)
            let coreMat = SceneKitView.lineMaterial(accent, opacity: 1.0)
            for e in working.entities {
                let pts = e.polyline().map { plane.toWorld($0) }
                if model.selectedSketchEntityIDs.contains(e.id) {
                    for i in 0..<(pts.count - 1) {
                        if let halo = SceneKitView.tubeNode(from: pts[i], to: pts[i + 1],
                                                            radius: 0.9, material: haloMat) {
                            wNode.addChildNode(halo)
                        }
                        if let core = SceneKitView.tubeNode(from: pts[i], to: pts[i + 1],
                                                            radius: 0.35, material: coreMat) {
                            wNode.addChildNode(core)
                        }
                    }
                    for p in pts {
                        let sphere = SCNSphere(radius: 0.55)
                        sphere.materials = [coreMat]
                        let sNode = SCNNode(geometry: sphere)
                        sNode.position = SCNVector3(Float(p.x), Float(p.y), Float(p.z))
                        wNode.addChildNode(sNode)
                    }
                } else if pts.count == 1 {
                    let c = pts[0], r = 1.2
                    plain.append((c + plane.xAxis * -r, c + plane.xAxis * r))
                    plain.append((c + plane.yAxis * -r, c + plane.yAxis * r))
                } else {
                    for i in 0..<(pts.count - 1) {
                        plain.append((pts[i], pts[i + 1]))
                    }
                }
            }
            if let geo = SceneKitView.lineGeometry(
                segments: plain,
                material: SceneKitView.lineMaterial(SceneKitView.cyanColor, opacity: 0.9)) {
                wNode.addChildNode(SCNNode(geometry: geo))
            }
            root.addChildNode(wNode)
            sketchWorkingNode = wNode

            sketchPreviewNode?.removeFromParentNode()
            sketchPreviewNode = nil
            if !model.sketchPreview.isEmpty {
                let pNode = SCNNode()
                pNode.name = "sketchPreview"
                pNode.renderingOrder = 7
                pNode.position = liftV
                var dash: [(Vec3, Vec3)] = []
                var dots: [Vec3] = []
                for e in model.sketchPreview {
                    let pts = e.polyline()
                    if pts.count == 1 {
                        let c = pts[0], r = 1.6
                        dash.append((plane.toWorld(c + Vec2(-r, 0)),
                                     plane.toWorld(c + Vec2(r, 0))))
                        dash.append((plane.toWorld(c + Vec2(0, -r)),
                                     plane.toWorld(c + Vec2(0, r))))
                        dots.append(plane.toWorld(c))
                    }
                    for i in 0..<(pts.count - 1) {
                        dash += SceneKitView.dashedSegments(plane.toWorld(pts[i]),
                                                            plane.toWorld(pts[i + 1]),
                                                            on: 2.2, off: 1.6)
                        dots.append(plane.toWorld(pts[i]))
                    }
                    if let last = pts.last, pts.count > 1 { dots.append(plane.toWorld(last)) }
                }
                if let geo = SceneKitView.lineGeometry(
                    segments: dash,
                    material: SceneKitView.lineMaterial(accent, opacity: 0.95)) {
                    pNode.addChildNode(SCNNode(geometry: geo))
                }
                for d in dots {
                    let dot = SCNSphere(radius: 0.5)
                    dot.materials = [coreMat]
                    let dNode = SCNNode(geometry: dot)
                    dNode.position = SCNVector3(Float(d.x), Float(d.y), Float(d.z))
                    pNode.addChildNode(dNode)
                }
                root.addChildNode(pNode)
                sketchPreviewNode = pNode
            }

            sketchHoverNode?.removeFromParentNode()
            sketchHoverNode = nil
            if let hp = model.sketchHoverPoint {
                let hNode = SCNNode()
                hNode.name = "sketchHover"
                hNode.renderingOrder = 7
                hNode.position = liftV
                // Crosshair arms + ring + center dot at the
                // SNAPPED hover point (v1.13: hover must be
                // plainly visible, not just a faint ring).
                let arm = 3.2
                var segs: [(Vec3, Vec3)] = [
                    (plane.toWorld(hp + Vec2(-arm, 0)), plane.toWorld(hp + Vec2(arm, 0))),
                    (plane.toWorld(hp + Vec2(0, -arm)), plane.toWorld(hp + Vec2(0, arm))),
                ]
                let steps = 20, rad = 1.8
                for i in 0..<steps {
                    let a0 = 2 * Double.pi * Double(i) / Double(steps)
                    let a1 = 2 * Double.pi * Double(i + 1) / Double(steps)
                    segs.append((plane.toWorld(hp + Vec2(cos(a0) * rad, sin(a0) * rad)),
                                 plane.toWorld(hp + Vec2(cos(a1) * rad, sin(a1) * rad))))
                }
                if let geo = SceneKitView.lineGeometry(
                    segments: segs,
                    material: SceneKitView.lineMaterial(accent, opacity: 0.95)) {
                    hNode.addChildNode(SCNNode(geometry: geo))
                }
                let c = plane.toWorld(hp)
                let dot = SCNSphere(radius: 0.45)
                dot.materials = [coreMat]
                let dNode = SCNNode(geometry: dot)
                dNode.position = SCNVector3(Float(c.x), Float(c.y), Float(c.z))
                hNode.addChildNode(dNode)
                root.addChildNode(hNode)
                sketchHoverNode = hNode
            }
            view.setNeedsDisplay()
        }

        /// Sketch stroke tracking (a zero-duration long-press is the
        /// reliable "give me every touch phase" recognizer): finger /
        /// pencil down → drag → up maps straight onto the model's
        /// pointer API, projected onto the active sketch's plane.
        @objc func handleSketchTrack(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view as? SCNView, let model = sketchModel,
                  let plane = model.activeSketch?.plane else { return }
            if gesture.numberOfTouches > 1 {
                // A second finger landed — the orbit is taking over;
                // roll the stroke back instead of fighting it.
                if strokeInFlight {
                    strokeInFlight = false
                    model.cancelSketchStroke()
                    refreshSessionDynamics(in: view)
                }
                return
            }
            let loc = gesture.location(in: view)
            switch gesture.state {
            case .began:
                strokeInFlight = true
                if let p = planePoint(at: loc, in: view, plane: plane) {
                    model.sketchPointerDown(at: p)
                }
                refreshSessionDynamics(in: view)
            case .changed:
                if let p = planePoint(at: loc, in: view, plane: plane) {
                    model.sketchPointerDragged(to: p)
                }
                refreshSessionDynamics(in: view)
            case .ended:
                if let p = planePoint(at: loc, in: view, plane: plane) {
                    model.sketchPointerUp(at: p)
                }
                strokeInFlight = false
                model.endSketchHover()
                refreshSessionDynamics(in: view)
            case .cancelled, .failed:
                if strokeInFlight { model.cancelSketchStroke() }
                strokeInFlight = false
                refreshSessionDynamics(in: view)
            default:
                break
            }
        }

        /// Two-finger orbit while sketching (the built-in camera
        /// control is disabled so one finger can draw): pan rotates
        /// the camera around `orbitTarget` in world-Z azimuth /
        /// elevation, pinch dollies. Taking over cancels any stroke.
        @objc func handleOrbitPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SCNView, let cam = cameraNode
            else { return }
            if gesture.state == .began, strokeInFlight {
                strokeInFlight = false
                sketchModel?.cancelSketchStroke()
            }
            guard gesture.state == .changed else { return }
            let t = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            orbitCamera(cam, dAzimuth: -Double(t.x) * 0.008,
                        dElevation: -Double(t.y) * 0.008)
            view.setNeedsDisplay()
        }

        @objc func handleOrbitPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let cam = cameraNode else { return }
            if gesture.state == .began {
                lastPinchScale = 1
                if strokeInFlight {
                    strokeInFlight = false
                    sketchModel?.cancelSketchStroke()
                }
            }
            guard gesture.state == .changed, gesture.scale > 0 else { return }
            let step = Double(gesture.scale) / Double(lastPinchScale)
            lastPinchScale = gesture.scale
            guard step > 0 else { return }
            dollyCamera(cam, factor: step)
            (gesture.view as? SCNView)?.setNeedsDisplay()
        }

        private func orbitCamera(_ cam: SCNNode, dAzimuth: Double, dElevation: Double) {
            let pos = Vec3(Double(cam.position.x), Double(cam.position.y),
                           Double(cam.position.z))
            let off = pos - orbitTarget
            let r = off.length
            guard r > 1e-3 else { return }
            var az = atan2(off.y, off.x)
            var el = asin(max(-1, min(1, off.z / r)))
            az += dAzimuth
            el = max(-1.45, min(1.45, el + dElevation))
            let flat = r * cos(el)
            let newPos = orbitTarget + Vec3(flat * cos(az), flat * sin(az), r * sin(el))
            cam.position = SCNVector3(Float(newPos.x), Float(newPos.y), Float(newPos.z))
            cam.look(at: SCNVector3(Float(orbitTarget.x), Float(orbitTarget.y),
                                    Float(orbitTarget.z)))
        }

        private func dollyCamera(_ cam: SCNNode, factor: Double) {
            let pos = Vec3(Double(cam.position.x), Double(cam.position.y),
                           Double(cam.position.z))
            let off = pos - orbitTarget
            let r = off.length
            guard r > 1e-3 else { return }
            let newR = max(5, min(4000, r / factor))
            let newPos = orbitTarget + off * (newR / r)
            cam.position = SCNVector3(Float(newPos.x), Float(newPos.y), Float(newPos.z))
            cam.look(at: SCNVector3(Float(orbitTarget.x), Float(orbitTarget.y),
                                    Float(orbitTarget.z)))
        }

        /// Apple Pencil hover: the snapped point follows the pencil
        /// before it ever touches, so the user can aim the stroke.
        @objc func handlePencilHover(_ gesture: UIHoverGestureRecognizer) {
            guard let view = gesture.view as? SCNView, let model = sketchModel,
                  let plane = model.activeSketch?.plane else { return }
            switch gesture.state {
            case .began, .changed:
                if let p = planePoint(at: gesture.location(in: view),
                                      in: view, plane: plane) {
                    model.sketchHover(at: p)
                }
                refreshSessionDynamics(in: view)
            case .ended, .cancelled:
                model.endSketchHover()
                refreshSessionDynamics(in: view)
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            // In-place sketch session live: strokes own the touches.
            guard sketchModel?.activeSketchID == nil else { return }
            guard let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            if isPickingFace {
                // Only the model node counts — the hit test is
                // scoped to its subtree (see modelHit), so the
                // sketch overlays can never answer a face pick.
                guard let hit = modelHit(at: point, in: view) else { return }
                onFacePicked?(hit.faceIndex)
                return
            }
            // Normal mode: a tap ON the model resolves a picked
            // selection first (edge → face → shaft/hole, in the
            // model). Only a tap that misses the model entirely
            // falls through to sketch selection.
            if let hit = modelHit(at: point, in: view) {
                onModelHit?(hit.faceIndex, hit.point)
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
            guard sketchModel?.activeSketchID == nil else { return }
            guard !isPickingFace, let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            guard let hit = modelHit(at: point, in: view) else { return }
            onModelDoubleTap?(hit.faceIndex, hit.point)
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

    /// Identity fingerprint for a mesh, strong enough that two
    /// DIFFERENT meshes practically never share one: triangle
    /// count + volume + bounds + a sampled-vertex checksum. The
    /// old keys used count + volume alone — and a pure translation
    /// or rotation (Move Body) preserves BOTH exactly, so the
    /// geometry, edge overlay and selection highlight all stayed
    /// stale at the pre-move position (sweep finding, 2026-10-26).
    /// Shared by the geometry / edge / selection keys here and by
    /// EditorView's baseMeshKey.
    static func meshFingerprint(_ mesh: Mesh) -> String {
        let b = mesh.bounds
        var check = 0.0
        let vs = mesh.vertices
        if !vs.isEmpty {
            let stride = max(1, vs.count / 24)
            var i = 0
            while i < vs.count {
                let v = vs[i]
                check += v.x + v.y * 3.1 + v.z * 7.3
                i += stride
            }
            if let last = vs.last { check += last.x + last.y * 3.1 + last.z * 7.3 }
        }
        return String(format: "%d|%.4f|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%.3f",
                      mesh.triangleCount, mesh.volume,
                      b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z,
                      check)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        // Last chance to remember the viewpoint before teardown.
        guard coordinator.framed, !coordinator.currentDocumentID.isEmpty,
              let camNode = coordinator.cameraNode else { return }
        poseStore[coordinator.currentDocumentID] = CameraPose(
            position: camNode.position, orientation: camNode.orientation)
    }

    func makeUIView(context: Context) -> SCNView {
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

        // In-place sketch input. All four recognizers exist from the
        // start but stay DISABLED until a sketch session is live
        // (updateUIView's mode sync): the stroke tracker (zero-
        // duration long-press, one touch), a two-finger orbit pan
        // and a pinch — the built-in camera control is disabled
        // while sketching so one finger can draw without orbiting —
        // and the Pencil hover tracker.
        let track = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSketchTrack(_:)))
        track.minimumPressDuration = 0
        track.allowableMovement = CGFloat.greatestFiniteMagnitude
        track.numberOfTouchesRequired = 1
        track.isEnabled = false
        // Simultaneous recognition with the orbit recognizers is
        // what lets the camera move while sketching at all (see
        // the coordinator's delegate method).
        track.delegate = context.coordinator
        view.addGestureRecognizer(track)
        context.coordinator.sketchTrack = track

        let orbitPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleOrbitPan(_:)))
        orbitPan.minimumNumberOfTouches = 2
        orbitPan.maximumNumberOfTouches = 2
        orbitPan.isEnabled = false
        orbitPan.delegate = context.coordinator
        view.addGestureRecognizer(orbitPan)
        context.coordinator.orbitPan = orbitPan

        let orbitPinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleOrbitPinch(_:)))
        orbitPinch.isEnabled = false
        orbitPinch.delegate = context.coordinator
        view.addGestureRecognizer(orbitPinch)
        context.coordinator.orbitPinch = orbitPinch

        let hover = UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePencilHover(_:)))
        hover.isEnabled = false
        view.addGestureRecognizer(hover)
        context.coordinator.pencilHover = hover

        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onFacePicked = onFacePicked
        context.coordinator.onSketchPicked = onSketchPicked
        context.coordinator.onModelHit = onModelHit
        context.coordinator.onModelDoubleTap = onModelDoubleTap
        context.coordinator.isPickingFace = isPickingFace
        context.coordinator.sketchesInput = sketches
        context.coordinator.hiddenSketchIDsInput = hiddenSketchIDs
        context.coordinator.showSketchesInput = showSketches
        context.coordinator.sketchModel = sketchModel
        context.coordinator.accentInput = accentUIColor
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

        // Camera snap requests (v1.13): a session beginning, a
        // plane picked in the New Sketch panel, a face picked for
        // it, or the rail's Flat view button asks for the camera
        // flat on a plane. Consumed once per nonce, AFTER any pose
        // restore above and BEFORE the pose save below, so the
        // snapped pose is what persists.
        if let req = sketchModel?.cameraSnapRequest,
           context.coordinator.lastSnapNonce != req.nonce {
            context.coordinator.lastSnapNonce = req.nonce
            context.coordinator.snapCameraToPlane(origin: req.origin,
                                                  normal: req.normal,
                                                  vAxis: req.vAxis)
            context.coordinator.framed = true
        }

        // Sketch overlays + selection highlight + measure markers
        // refresh independently of the model geometry guard below.
        updateOverlays(view, context: context)
        updateSelection(view, context: context)
        updateMeasure(view, context: context)
        updateBasePlanes(view, context: context)
        updateEdges(view, context: context)
        syncSketchMode(view, context: context)
        updateSketchSession(view, context: context)

        // Identity for "geometry must be rebuilt": mesh shape +
        // material + preview state + accent (the preview tint reads
        // the accent, so a settings change re-tints a live preview).
        let mat = material ?? MaterialLibrary.defaultMaterial
        let key = "\(Self.meshFingerprint(mesh))|\(mat.id)|\(isPreview ? "preview" : "live")|\(accentKey)"
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
    }

    // MARK: Selection highlight

    /// Change fingerprint for the selection highlight: which thing is
    /// picked (with its identifying numbers) + the mesh it was picked
    /// from, so a rebuild swaps the highlight out.
    static func selectionKey(picked: PickedSelection?, mesh: Mesh) -> String {
        let meshPart = meshFingerprint(mesh)
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

    // MARK: Base-plane glow (New Sketch plane choice)

    /// Keep the base-plane glow quads in sync with `showBasePlanes`.
    /// Three translucent 70×70 mm quads through the origin, colored
    /// by the axis of their normal (RGB = XYZ): YZ red, XZ green,
    /// XY blue — the same colors as the New Sketch panel's plane
    /// cards. Rebuilt ONLY when the flag toggles (the key is just
    /// the flag). Named "basePlanes", renderingOrder 4 — below the
    /// sketch overlays (6) — and never hit-tested: every pick
    /// filters to the model node.
    private func updateBasePlanes(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        let key = showBasePlanes ? "planes-on" : "planes-off"
        guard coord.basePlanesKey != key else { return }
        coord.basePlanesKey = key
        coord.basePlanesNode?.removeFromParentNode()
        coord.basePlanesNode = nil
        guard showBasePlanes else { return }
        let root = SCNNode()
        root.name = "basePlanes"
        root.renderingOrder = 4
        // (plane normal, glow color) — normal axis picks the color.
        let planes: [(normal: Vec3, color: UIColor)] = [
            (Vec3(1, 0, 0), UIColor(red: 1.0, green: 0.28, blue: 0.28, alpha: 1)),  // YZ
            (Vec3(0, 1, 0), UIColor(red: 0.30, green: 0.95, blue: 0.38, alpha: 1)),  // XZ
            (Vec3(0, 0, 1), UIColor(red: 0.32, green: 0.56, blue: 1.0, alpha: 1)),  // XY
        ]
        for plane in planes {
            root.addChildNode(Self.makeBasePlaneNode(normal: plane.normal,
                                                     color: plane.color))
        }
        view.scene?.rootNode.addChildNode(root)
        coord.basePlanesNode = root
    }

    /// One glowing base plane: a translucent quad centered on the
    /// origin (fill reads at ~0.28 opacity) plus a brighter border
    /// outline (~0.8), neither writing to the depth buffer so the
    /// three planes blend where they cross instead of slicing each
    /// other. SCNPlane faces +Z; the node is rotated so +Z lands on
    /// the plane's normal.
    static func makeBasePlaneNode(normal: Vec3, color: UIColor) -> SCNNode {
        let node = SCNNode()
        node.renderingOrder = 4
        let fill = SCNMaterial()
        fill.lightingModel = .constant
        fill.diffuse.contents = color
        fill.transparency = 1 - 0.28
        fill.isDoubleSided = true
        fill.writesToDepthBuffer = false
        let quad = SCNPlane(width: 70, height: 70)
        quad.materials = [fill]
        node.addChildNode(SCNNode(geometry: quad))
        let h = 35.0
        let corners = [Vec3(-h, -h, 0), Vec3(h, -h, 0),
                       Vec3(h, h, 0), Vec3(-h, h, 0)]
        var segments: [(Vec3, Vec3)] = []
        for i in 0..<4 {
            segments.append((corners[i], corners[(i + 1) % 4]))
        }
        if let border = lineGeometry(segments: segments,
                                     material: lineMaterial(color, opacity: 0.8)) {
            node.addChildNode(SCNNode(geometry: border))
        }
        let zAxis = Vec3(0, 0, 1)
        let cross = zAxis.cross(normal)
        if cross.length > 1e-6 {
            let axis = cross.normalized
            let angle = acos(max(-1, min(1, zAxis.dot(normal))))
            node.rotation = SCNVector4(Float(axis.x), Float(axis.y),
                                       Float(axis.z), Float(angle))
        } else if normal.z < 0 {
            // Normal is straight −Z: flip the quad over.
            node.rotation = SCNVector4(1, 0, 0, Float(Double.pi))
        }
        return node
    }

    // MARK: Sharp-edge overlay (the CAD look)

    /// The crease angle (degrees between adjacent face normals)
    /// past which an edge counts as sharp and gets a drawn line.
    /// Matches the `displaySoup` default in the kit, so the lines
    /// land exactly where the smooth shading breaks.
    static let edgeCreaseDegrees: Double = 60

    /// Keep the sharp-edge line node in sync with the model +
    /// the "Show model edges" setting. Rebuilt only when its key
    /// moves (mesh identity + flag); skipped entirely at or above
    /// ~80k triangles, where per-edge lines stop being legible and
    /// the welded edge walk gets expensive. renderingOrder 5: above
    /// the model (0), below the sketch overlays (6), the session
    /// layer (7) and the selection highlight (9). Named
    /// "modelEdges" and never hit-tested (every pick filters to
    /// the model node).
    private func updateEdges(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        let key = "\(showModelEdges ? "edges-on" : "edges-off")|\(Self.meshFingerprint(mesh))"
        guard coord.edgeKey != key else { return }
        coord.edgeKey = key
        coord.edgeNode?.removeFromParentNode()
        coord.edgeNode = nil
        guard showModelEdges, mesh.triangleCount > 0,
              mesh.triangleCount < 80_000 else { return }
        let segments = Self.creaseEdgeSegments(mesh,
                                               creaseDegrees: Self.edgeCreaseDegrees)
        guard let geo = Self.lineGeometry(
            segments: segments,
            material: Self.lineMaterial(UIColor(white: 0.03, alpha: 1), opacity: 0.42))
        else { return }
        let node = SCNNode(geometry: geo)
        node.name = "modelEdges"
        node.renderingOrder = 5
        view.scene?.rootNode.addChildNode(node)
        coord.edgeNode = node
    }

    /// The sharp edges of the welded mesh: an edge shared by two
    /// faces whose normals differ by more than the crease angle,
    /// plus every boundary edge (only one adjacent face — the rim
    /// of an opening is always a drawn edge in CAD). Each segment is
    /// lifted 0.03 mm along the mean adjacent-face normal so the
    /// line sits proud of the surface instead of z-fighting it.
    static func creaseEdgeSegments(_ mesh: Mesh, creaseDegrees: Double) -> [(Vec3, Vec3)] {
        let m = mesh.welded()
        guard m.triangleCount > 0 else { return [] }
        let faceN = m.faceNormals()
        let cosLimit = cos(creaseDegrees * .pi / 180)
        func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
            (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
        }
        var edgeFaces: [UInt64: [Int]] = [:]
        for t in 0..<m.triangleCount {
            let i0 = m.indices[t * 3], i1 = m.indices[t * 3 + 1], i2 = m.indices[t * 3 + 2]
            edgeFaces[edgeKey(i0, i1), default: []].append(t)
            edgeFaces[edgeKey(i1, i2), default: []].append(t)
            edgeFaces[edgeKey(i2, i0), default: []].append(t)
        }
        var segments: [(Vec3, Vec3)] = []
        for k in edgeFaces.keys.sorted() {
            let faces = edgeFaces[k] ?? []
            let sharp: Bool
            if faces.count <= 1 {
                sharp = true
            } else {
                var s = false
                pairLoop: for i in faces.indices {
                    for j in faces.indices where j > i {
                        if faceN[faces[i]].dot(faceN[faces[j]]) < cosLimit {
                            s = true
                            break pairLoop
                        }
                    }
                }
                sharp = s
            }
            guard sharp else { continue }
            let lo = Int(k >> 32), hi = Int(k & 0xFFFF_FFFF)
            var n = Vec3.zero
            for f in faces { n = n + faceN[f] }
            let lift = n.length > 1e-9 ? n.normalized * 0.03 : Vec3.zero
            segments.append((m.vertices[lo] + lift, m.vertices[hi] + lift))
        }
        return segments
    }

    // MARK: In-place sketch session (grid / guide / dynamics)

    /// Enter/leave sketch input mode with the session: entering
    /// disables the built-in camera control (so one finger draws
    /// instead of orbiting) and arms the session recognizers;
    /// leaving restores the standard camera and disarms them. The
    /// orbit target is the active sketch plane's origin (v1.13).
    private func syncSketchMode(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        let active = sketchModel?.activeSketchID != nil
        // Keep the model's snap/pick tolerance honest while a
        // session is live: ≈14 screen points at the sketch plane,
        // from the live camera (distance + vertical FOV + height).
        if active, let model = sketchModel, let plane = model.activeSketch?.plane,
           let pov = view.pointOfView, let cam = pov.camera {
            let camPos = Vec3(Double(pov.position.x), Double(pov.position.y),
                              Double(pov.position.z))
            let dist = camPos.distance(to: plane.origin)
            let height = max(Double(view.bounds.height), 1)
            let fovRad = Double(cam.fieldOfView) * Double.pi / 180
            let tol = 14 * (2 * dist * tan(fovRad / 2) / height)
            if tol.isFinite, tol > 0.05,
               abs(tol - model.sketchSnapToleranceMM) > model.sketchSnapToleranceMM * 0.05 {
                model.sketchSnapToleranceMM = tol
            }
        }
        guard coord.sketchModeActive != active else { return }
        coord.sketchModeActive = active
        if active {
            view.allowsCameraControl = false
            // Orbit around the sketch plane's center (v1.13) —
            // the point the user is drawing about — not the part's
            // bounds center.
            coord.orbitTarget = sketchModel?.activeSketch?.plane.origin ?? .zero
            coord.sketchTrack?.isEnabled = true
            coord.orbitPan?.isEnabled = true
            coord.orbitPinch?.isEnabled = true
            coord.pencilHover?.isEnabled = true
        } else {
            view.allowsCameraControl = true
            coord.sketchTrack?.isEnabled = false
            coord.orbitPan?.isEnabled = false
            coord.orbitPinch?.isEnabled = false
            coord.pencilHover?.isEnabled = false
            coord.strokeInFlight = false
        }
    }

    /// Change fingerprint for the grid layer: only the sketch, its
    /// plane, and the snap step — the grid is static while drawing.
    /// (The v1.12 dynamic-layer key — selection + preview + hover
    /// at 0.01 mm precision — is gone: that layer is rebuilt
    /// imperatively by the coordinator now, never through here.)
    static func sketchGridKey(model: EditorModel, working: Sketch) -> String {
        let pl = working.plane
        return String(format: "%@|o:%.2f,%.2f,%.2f|n:%.3f,%.3f,%.3f|s:%.2f",
                      model.activeSketchID ?? "-", pl.origin.x, pl.origin.y,
                      pl.origin.z, pl.normal.x, pl.normal.y, pl.normal.z,
                      model.sketchSnapStep)
    }

    /// Keep the session's STATIC layers in sync: the root, the
    /// plane grid (rebuilt only when the sketch / plane / snap step
    /// changes) and the face-outline guide (only when the outline
    /// changes). Everything that moves per pointer event — working
    /// copy, preview, hover marker — lives in the coordinator's
    /// imperative layer (`refreshSessionDynamics`), refreshed here
    /// too so discrete state changes (selection, commits) land
    /// without waiting for the next pointer event.
    private func updateSketchSession(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        guard let model = sketchModel, model.activeSketchID != nil,
              let working = model.activeSketch else {
            if coord.sketchSessionNode != nil {
                coord.sketchSessionNode?.removeFromParentNode()
                coord.sketchSessionNode = nil
                coord.sketchGridNode = nil
                coord.sketchWorkingNode = nil
                coord.sketchPreviewNode = nil
                coord.sketchHoverNode = nil
                coord.sketchGuideNode = nil
                coord.sketchGridKey = ""
                coord.sketchGuideKey = ""
            }
            return
        }
        guard let root = coord.ensureSessionRoot(in: view) else { return }
        let gKey = Self.sketchGridKey(model: model, working: working)
        if coord.sketchGridKey != gKey {
            coord.sketchGridKey = gKey
            coord.sketchGridNode?.removeFromParentNode()
            let grid = Self.makeSketchGridNode(plane: working.plane,
                                               snapStep: model.sketchSnapStep)
            root.addChildNode(grid)
            coord.sketchGridNode = grid
        }
        // The face guide: when the active sketch was created on a
        // model face, its outline (stored by the model at creation)
        // draws as a closed amber loop in the session — the guide
        // the old 2D editor showed (v1.13 restores it in-place).
        let outline = model.activeSketchID.flatMap { model.faceOutlines[$0] } ?? []
        let oKey = outline.isEmpty ? "none"
            : "\(outline.count)|\(outline.first!.x),\(outline.first!.y)|\(outline.last!.x),\(outline.last!.y)"
        if coord.sketchGuideKey != oKey {
            coord.sketchGuideKey = oKey
            coord.sketchGuideNode?.removeFromParentNode()
            coord.sketchGuideNode = nil
            if outline.count > 1 {
                let guide = Self.makeSketchGuideNode(plane: working.plane,
                                                     outline: outline)
                root.addChildNode(guide)
                coord.sketchGuideNode = guide
            }
        }
        coord.refreshSessionDynamics(in: view)
    }

    /// The face-outline guide node: the picked face's boundary as
    /// one closed loop of line segments, in warm amber so it never
    /// reads as sketch geometry (cyan) or selection (accent).
    /// Lifted like the grid so it never z-fights the face itself.
    static func makeSketchGuideNode(plane: Plane3, outline: [Vec2]) -> SCNNode {
        let node = SCNNode()
        node.name = "sketchGuide"
        node.renderingOrder = 7
        let lift = plane.normal * 0.06
        node.position = SCNVector3(Float(lift.x), Float(lift.y), Float(lift.z))
        var segments: [(Vec3, Vec3)] = []
        for i in outline.indices {
            segments.append((plane.toWorld(outline[i]),
                             plane.toWorld(outline[(i + 1) % outline.count])))
        }
        if let geo = lineGeometry(
            segments: segments,
            material: lineMaterial(UIColor(red: 1.0, green: 0.72, blue: 0.30, alpha: 1),
                                   opacity: 0.85)) {
            node.addChildNode(SCNNode(geometry: geo))
        }
        return node
    }

    /// The active plane's grid: ±100 mm of lines in ONE
    /// SCNGeometry (v1.13) — a single vertex buffer with two line
    /// elements, minor at opacity 0.10 and major (every 5th) at
    /// 0.22, each element with its own material. The DRAWN minor
    /// spacing is the snap step floored at 2 mm (a 0.5 mm snap
    /// would otherwise weave thousands of lines; snapping itself
    /// still uses the real step). Tinted toward the plane's axis
    /// color for a true base plane. Lifted +0.06 mm along the
    /// normal so it never sits coplanar with a model face.
    static func makeSketchGridNode(plane: Plane3, snapStep: Double) -> SCNNode {
        let node = SCNNode()
        node.name = "sketchGrid"
        node.renderingOrder = 7
        let lift = plane.normal * 0.06
        node.position = SCNVector3(Float(lift.x), Float(lift.y), Float(lift.z))
        let tint = basePlaneTint(for: plane)
        let minorStep = max(2, snapStep)
        let half = 100.0
        let count = Int(half / minorStep)
        var positions: [Float] = []
        var minorIndices: [UInt32] = []
        var majorIndices: [UInt32] = []
        func addSegment(_ a: Vec3, _ b: Vec3, major: Bool) {
            let base = UInt32(positions.count / 3)
            positions.append(Float(a.x)); positions.append(Float(a.y)); positions.append(Float(a.z))
            positions.append(Float(b.x)); positions.append(Float(b.y)); positions.append(Float(b.z))
            if major { majorIndices += [base, base + 1] } else { minorIndices += [base, base + 1] }
        }
        for i in -count...count {
            let v = Double(i) * minorStep
            let major = i % 5 == 0
            addSegment(plane.toWorld(Vec2(v, -half)), plane.toWorld(Vec2(v, half)), major: major)
            addSegment(plane.toWorld(Vec2(-half, v)), plane.toWorld(Vec2(half, v)), major: major)
        }
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: posData, semantic: .vertex, vectorCount: positions.count / 3,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        func element(_ indices: [UInt32]) -> SCNGeometryElement {
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometryElement(data: data, primitiveType: .line,
                                      primitiveCount: indices.count / 2, bytesPerIndex: 4)
        }
        let geometry = SCNGeometry(sources: [vertexSource],
                                   elements: [element(minorIndices), element(majorIndices)])
        geometry.materials = [lineMaterial(tint, opacity: 0.10),
                              lineMaterial(tint, opacity: 0.22)]
        node.addChildNode(SCNNode(geometry: geometry))
        return node
    }

    /// White, blended 35% toward the axis color when the plane IS
    /// one of the three base planes (through the origin with an axis
    /// normal — XY blue, XZ green, YZ red, the v1.11 colors). Datum
    /// and face planes get plain white.
    static func basePlaneTint(for plane: Plane3) -> UIColor {
        let o = plane.origin
        guard abs(o.x) < 0.01, abs(o.y) < 0.01, abs(o.z) < 0.01 else { return .white }
        let n = plane.normal
        func tinted(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            UIColor(red: 1 + (r - 1) * 0.35, green: 1 + (g - 1) * 0.35,
                    blue: 1 + (b - 1) * 0.35, alpha: 1)
        }
        if abs(abs(n.z) - 1) < 0.01 { return tinted(0.35, 0.58, 1.0) }  // XY
        if abs(abs(n.y) - 1) < 0.01 { return tinted(0.30, 0.92, 0.40) }  // XZ
        if abs(abs(n.x) - 1) < 0.01 { return tinted(1.0, 0.30, 0.30) }   // YZ
        return .white
    }

    /// Split a segment into dash sub-segments (on/off lengths in mm).
    static func dashedSegments(_ a: Vec3, _ b: Vec3,
                               on: Double, off: Double) -> [(Vec3, Vec3)] {
        let len = a.distance(to: b)
        guard len > 1e-6 else { return [] }
        var out: [(Vec3, Vec3)] = []
        var t = 0.0
        while t < len {
            let t2 = min(t + on, len)
            out.append((a + (b - a) * (t / len), a + (b - a) * (t2 / len)))
            t = t2 + off
        }
        return out
    }

    // MARK: Sketch overlays

    /// Keep the sketch overlay nodes in sync with the overlay
    /// inputs. v1.13: these are the COMMITTED sketches only, and
    /// while a session is live the active sketch is EXCLUDED — the
    /// session layer draws its working copy. (v1.12 substituted
    /// the working copy in here, so every select-drag move changed
    /// this key and rebuilt every sketch overlay, tube glows
    /// included, per pointer event.)
    private func updateOverlays(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        let activeID = sketchModel?.activeSketchID
        let visible = activeID == nil ? sketches
            : sketches.filter { $0.id != activeID }
        let key = Self.overlayKey(sketches: visible, selectedID: selectedSketchID,
                                  hidden: hiddenSketchIDs, show: showSketches)
            + "|acc:\(accentKey)"
        guard coord.overlayKey != key else { return }
        coord.overlayKey = key
        coord.overlayNode?.removeFromParentNode()
        coord.overlayNode = nil
        guard showSketches else { return }
        let root = SCNNode()
        root.name = "sketchOverlays"
        for sketch in visible where !hiddenSketchIDs.contains(sketch.id) {
            root.addChildNode(Self.makeSketchNode(sketch,
                                                  selected: sketch.id == selectedSketchID,
                                                  accent: accentUIColor))
        }
        view.scene?.rootNode.addChildNode(root)
        coord.overlayNode = root
    }

    /// Change fingerprint for the overlays: visibility, selection,
    /// each sketch's plane origin, entity count, and a cheap shape
    /// sample (first polyline point per entity) so committed sketch
    /// edits refresh the overlay. (The ACTIVE sketch is excluded
    /// during a session — see updateOverlays.)
    static func overlayKey(sketches: [Sketch], selectedID: String?,
                           hidden: Set<String>, show: Bool) -> String {
        var parts = [show ? "show" : "hide", selectedID ?? "-"]
        for s in sketches {
            var fp = "\(s.id)#\(hidden.contains(s.id) ? 1 : 0)#\(s.entities.count)#"
            fp += String(format: "%.2f,%.2f,%.2f", s.plane.origin.x, s.plane.origin.y, s.plane.origin.z)
            for e in s.entities {
                let pts = e.polyline()
                if let f = pts.first, let l = pts.last {
                    // First AND last point: sampling the first alone
                    // missed edits that move only an entity's far
                    // end (a line's B endpoint, an arc's end).
                    fp += "|\(pts.count)@\(String(format: "%.2f,%.2f-%.2f,%.2f", f.x, f.y, l.x, l.y))"
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
