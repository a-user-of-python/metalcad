import SwiftUI

/// Whole-number-friendly formatting shared by the editor views.
func mcFmt(_ v: Double) -> String {
    if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
    return String(format: "%.2f", v)
}

/// Mass formatting: grams under a kilo, kilograms above.
func mcMass(_ grams: Double) -> String {
    if abs(grams) >= 1000 { return String(format: "%.2f kg", grams / 1000) }
    return String(format: "%.1f g", grams)
}

/// Programmatic navigation target for a sketch (e.g. a fresh face sketch).
struct SketchNav: Identifiable, Hashable {
    let id: String
}

/// What a normal-mode tap on the 3D model selected (v4.3,
/// selection-first): a flat face, one sharp edge, a cylindrical
/// shaft, or the wall of a cylindrical hole. Drives the highlight in
/// SceneKitView and the floating picked-action bar in EditorView.
/// Mutually exclusive with the sketch selection — picking one clears
/// the other.
enum PickedSelection {
    /// Index into FaceExtractor.groupedFaces(of:) of the result mesh.
    case face(index: Int, face: PlanarFace, point: Vec3)
    case edge(midpoint: Vec3, start: Vec3, end: Vec3, length: Double)
    case shaft(CylinderFit)
    case holeWall(CylinderFit)
}

extension Sketch {
    /// A datum (construction) plane: kit v4 has no datum type, so the
    /// app encodes one as an entity-free sketch whose name starts with
    /// "⌖ ". Datums are offered as sketch planes and construct-tool
    /// sources, never as feature profiles.
    var isDatumPlane: Bool { name.hasPrefix("⌖ ") && entities.isEmpty }
}

/// Editing session for one open document. Owns the document value, the
/// latest rebuild, and transient action errors. Every kit call goes
/// through here so a failure becomes a coded CADError banner — the UI
/// layer never throws and never crashes on a bad model.
final class EditorModel: ObservableObject {
    @Published var document: CADDocument
    @Published var rebuild: RebuildResult?
    @Published var actionError: CADError?
    @Published var saveMessage: String?
    @Published var stlURL: URL?
    /// File produced by the latest Save As format export — the Save
    /// As sheet presents it with the standard share/save sheet.
    @Published var shareURL: URL?
    @Published var stlWarnings: [CADError] = []
    @Published var partIndex: Int = 0
    /// Face outlines (in sketch-plane coordinates) for sketches created
    /// on a solid face, drawn as a guide in the sketch editor.
    @Published var faceOutlines: [String: [Vec2]] = [:]
    /// Set by the sketch editor's "Finish & Extrude": the editor opens
    /// the Extrude panel pre-filled with this sketch.
    @Published var pendingExtrudeSketchID: String?
    /// Sketch a tool panel should pre-select when it opens (set from
    /// the 3D selection / browser selection just before the panel
    /// appears). Panels consume it in their initializers.
    @Published var pendingPanelSketchID: String?
    /// Operation an Extrude panel opened from the selection action
    /// bar should start with (e.g. "cut" for Pocket). Same consume-on-
    /// open pattern as pendingPanelSketchID.
    @Published var pendingPanelOperation: String?
    /// The sketch currently selected in the 3D view (tap a sketch
    /// overlay, Fusion-style) — drives the overlay highlight, the
    /// browser-row highlight, and the selection action bar.
    @Published var selectedSketchID: String?
    /// Sketches whose 3D overlay is hidden (browser eye toggles).
    /// Session-only by design.
    @Published var hiddenSketchIDs: Set<String> = []
    /// Master switch for sketch overlays in the 3D view.
    @Published var showsSketches: Bool = true
    /// What a normal-mode tap on the model selected (face / edge /
    /// shaft / hole wall) — drives the 3D highlight and the floating
    /// picked-action bar. Mutually exclusive with `selectedSketchID`.
    @Published var picked: PickedSelection?
    /// Generated drill-point sketch waiting for the Hole panel (set by
    /// the picked-face bar's "Hole Here…"). The panel drafts with it
    /// and commits it alongside the hole feature; cleared when the
    /// panel closes.
    @Published var pendingHoleSketch: Sketch?
    /// Generated face-outline sketch waiting for the Revolve panel
    /// (set by the picked-face bar's "Revolve Face…"). The panel
    /// drafts with it injected and commits it alongside the revolve
    /// feature; cleared when the panel closes. Same pattern as
    /// pendingHoleSketch.
    @Published var pendingRevolveSketch: Sketch?
    /// Face the Measure panel should preselect as Face A when it next
    /// opens (set by the picked-face bar's "Measure").
    @Published var measureFace: PlanarFace?
    // MARK: Quick measure (always-on point-to-point, 3D view)
    /// While true, normal-mode model taps feed the quick measure
    /// (see `recordMeasureTap`) instead of the picked-selection
    /// resolution. Face-pick mode still wins — SceneKitView checks
    /// it before reporting a normal-mode hit.
    @Published var measureMode: Bool = false
    /// The 0–2 tapped points of the current quick measurement.
    @Published var measurePoints: [Vec3] = []
    /// Length of the sharp edge the latest measure tap landed on
    /// (within 2.5 mm, the selection flow's edge resolution), if any.
    @Published var measureEdgeLength: Double?
    // MARK: Live draft preview (uncommitted feature changes)
    /// The feature list the live preview shows, or nil when no panel
    /// is drafting. Panels keep this in sync with their fields (see
    /// draftAppend / draftReplacing) so the 3D view shows the result
    /// — as a tinted preview REPLACING the model — BEFORE the user
    /// commits with OK.
    @Published var draftFeatures: [Feature]?
    /// Mesh of the latest draft rebuild (nil when no draft).
    @Published var previewMesh: Mesh?
    /// First error of the latest draft rebuild, if it failed.
    @Published var previewError: CADError?
    /// Neutral note shown in the panels' draft slot when the live
    /// preview is intentionally skipped (very large part) — the
    /// draft itself still applies on OK.
    @Published var previewNote: String?
    private var draftWorkItem: DispatchWorkItem?
    /// Serial background queue for draft rebuilds. The kit rebuild is
    /// pure value math (and MCLog's ring buffer / file sink are
    /// NSLock-protected), so it is safe off the main thread; results
    /// hop back to the main queue to publish.
    private let draftQueue = DispatchQueue(label: "metalcad.draft-preview",
                                           qos: .userInitiated)
    /// Monotonic draft generation, bumped by EVERY setDraft call. A
    /// rebuild that finishes for an older generation is dropped, so
    /// while the user scrubs a slider the preview tracks the newest
    /// value and can never jump backwards to a stale intermediate.
    private var draftGeneration = 0
    private let draftGenerationLock = NSLock()

    private func bumpDraftGeneration() -> Int {
        draftGenerationLock.lock()
        defer { draftGenerationLock.unlock() }
        draftGeneration += 1
        return draftGeneration
    }

    private func currentDraftGeneration() -> Int {
        draftGenerationLock.lock()
        defer { draftGenerationLock.unlock() }
        return draftGeneration
    }
    /// The New Sketch panel's plane selection (kept here so it
    /// survives the panel closing while a face is picked).
    @Published var planeChoice: PlaneChoice = .none
    /// The Redefine Plane panel's selection, same reasoning.
    @Published var redefineChoice: PlaneChoice = .none
    /// Last face picked for Construct ▸ Offset Plane.
    @Published var constructFace: PlanarFace?
    /// Faces picked for Construct ▸ Midplane.
    @Published var midplaneFaceA: PlanarFace?
    @Published var midplaneFaceB: PlanarFace?
    let fileURL: URL

    init(document: CADDocument, url: URL) {
        self.document = document
        self.fileURL = url
        rebuildNow()
    }

    var part: Part? {
        guard !document.parts.isEmpty else { return nil }
        return document.parts[min(partIndex, document.parts.count - 1)]
    }

    func rebuildNow() {
        guard let p = part else { rebuild = nil; return }
        rebuild = DocumentEngine.rebuild(part: p)
    }

    // MARK: Draft previews

    /// Schedule a live preview rebuild of `features` (nil clears the
    /// preview). The rebuild runs ASYNCHRONOUSLY on a background
    /// queue after a ~50 ms debounce (device report, 2026-10-26: the
    /// preview must track a slider IN REAL TIME, not land whenever
    /// the user pauses) — 50 ms is just enough to batch the burst of
    /// changes a scrub or a keystroke produces. Each call bumps the
    /// draft generation; a result that finishes stale is dropped, so
    /// the on-screen preview always corresponds to the newest field
    /// values. Pass `sketches` when the candidate feature needs a
    /// generated sketch the committed part doesn't have yet — the
    /// preview part carries that list instead; the committed part is
    /// never touched.
    func setDraft(_ features: [Feature]?, sketches: [Sketch]? = nil) {
        draftFeatures = features
        // Bump FIRST, before anything else: this alone invalidates
        // every in-flight rebuild, including when the outcome below
        // is "clear" or "paused".
        let generation = bumpDraftGeneration()
        draftWorkItem?.cancel()
        draftWorkItem = nil
        guard let features else {
            previewMesh = nil
            previewError = nil
            previewNote = nil
            return
        }
        // Very large parts make every draft rebuild expensive (the
        // iPad ran hot, 2026-10-26): past ~150k triangles in the
        // current result, skip the preview entirely and say so — the
        // feature still applies, exactly, on OK. Decided here, before
        // scheduling; the generation bump above keeps an in-flight
        // stale result from landing after the pause.
        if (rebuild?.mesh.triangleCount ?? 0) > 150_000 {
            previewMesh = nil
            previewError = nil
            previewNote = "Preview paused — the part is large; the result applies on OK"
            return
        }
        previewNote = nil
        guard var snapshot = part else {
            previewMesh = nil
            previewError = nil
            return
        }
        snapshot.features = features
        if let sketches { snapshot.sketches = sketches }
        let item = DispatchWorkItem { [weak self] in
            self?.runDraft(snapshot: snapshot, generation: generation)
        }
        draftWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// Run one draft rebuild on the background queue and publish its
    /// result on the main queue — unless a newer draft superseded it
    /// in the meantime, at either end of the trip.
    private func runDraft(snapshot: Part, generation: Int) {
        draftQueue.async { [weak self] in
            // Superseded before we even started: don't burn the
            // rebuild at all (a fast scrub queues several of these).
            guard let self, self.currentDraftGeneration() == generation else { return }
            let result = DocumentEngine.rebuild(part: snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentDraftGeneration() == generation else { return }
                // Invariant: a FAILED draft shows the COMMITTED
                // model plus the error banner — never a stale or
                // partial preview mesh.
                if let err = result.firstError {
                    self.previewMesh = nil
                    self.previewError = err
                } else {
                    self.previewMesh = result.mesh
                    self.previewError = nil
                }
            }
        }
    }

    /// Draft = the committed features plus this candidate feature.
    func draftAppend(_ feature: Feature) {
        guard let current = part?.features else { setDraft(nil); return }
        setDraft(current + [feature])
    }

    /// Draft = the committed features plus this candidate feature,
    /// with the preview part's sketches replaced by `sketches` (the
    /// committed sketches plus a generated one). Used by the
    /// face-pull and hole-here flows, whose feature references a
    /// sketch that only exists once the user commits.
    func draftAppendWithSketches(_ sketches: [Sketch], _ feature: Feature) {
        guard let current = part?.features else { setDraft(nil); return }
        setDraft(current + [feature], sketches: sketches)
    }

    /// Draft = the committed features with the one at `index`
    /// replaced by this candidate (same feature id preserved).
    func draftReplacing(index: Int, with feature: Feature) {
        guard var current = part?.features, current.indices.contains(index) else {
            setDraft(nil)
            return
        }
        current[index] = feature
        setDraft(current)
    }

    private func mutate(_ change: (inout Part) -> Void) {
        guard !document.parts.isEmpty else { return }
        let i = min(partIndex, document.parts.count - 1)
        change(&document.parts[i])
        actionError = nil
        saveMessage = nil
        rebuildNow()
    }

    func status(for featureID: String) -> FeatureStatus? {
        rebuild?.statuses.first { $0.featureID == featureID }
    }

    func sketch(withID id: String) -> Sketch? { part?.sketch(id) }

    /// Sketches usable as feature profiles/paths — datum planes are
    /// NOT sketches to build from, so every feature picker uses this.
    var featureSketches: [Sketch] {
        part?.sketches.filter { !$0.isDatumPlane } ?? []
    }

    /// Datum (construct) planes of the current part.
    var datumSketches: [Sketch] {
        part?.sketches.filter { $0.isDatumPlane } ?? []
    }

    func feature(withID id: String) -> Feature? { part?.features.first { $0.id == id } }

    func replaceSketch(_ sketch: Sketch) {
        mutate { part in
            if let i = part.sketches.firstIndex(where: { $0.id == sketch.id }) {
                part.sketches[i] = sketch
            }
        }
    }

    /// Create a sketch on an explicit plane (New Sketch panel) and
    /// return it so the caller can navigate straight into it.
    @discardableResult
    func addSketch(plane: Plane3, name: String) -> Sketch {
        let sketch = Sketch(name: name, plane: plane)
        mutate { $0.sketches.append(sketch) }
        MCLog.shared.info(.sketch, "sketch created",
                          context: ["name": name])
        return sketch
    }

    /// Create a datum (construct) plane — an entity-free sketch whose
    /// name carries the ⌖ prefix that marks it as a datum.
    @discardableResult
    func addDatum(plane: Plane3, name: String) -> Sketch {
        let marked = name.hasPrefix("⌖ ") ? name : "⌖ " + name
        let datum = Sketch(name: marked, plane: plane)
        mutate { $0.sketches.append(datum) }
        MCLog.shared.info(.sketch, "datum plane created",
                          context: ["name": marked])
        return datum
    }

    /// Redefine a sketch's plane (Redefine Plane panel / face pick).
    func setSketchPlane(id: String, plane: Plane3, outline: [Vec2]?) {
        if let outline { faceOutlines[id] = outline }
        mutate { part in
            if let i = part.sketches.firstIndex(where: { $0.id == id }) {
                part.sketches[i].plane = plane
            }
        }
        MCLog.shared.info(.sketch, "sketch plane redefined", context: ["id": id])
    }

    func deleteSketch(_ id: String) {
        faceOutlines[id] = nil
        if selectedSketchID == id { selectedSketchID = nil }
        hiddenSketchIDs.remove(id)
        mutate { $0.sketches.removeAll { $0.id == id } }
    }

    // MARK: Renaming

    /// Rename a sketch. Names are display-only — every feature
    /// reference keys on the sketch's ID, so a rename can never
    /// break the feature tree. No rebuild is needed (names don't
    /// affect geometry); the document mutation alone refreshes the
    /// lists, and the change persists with the next Save like every
    /// other edit. Empty / whitespace-only names are ignored.
    func renameSketch(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !document.parts.isEmpty else { return }
        let i = min(partIndex, document.parts.count - 1)
        guard let idx = document.parts[i].sketches.firstIndex(where: { $0.id == id }),
              document.parts[i].sketches[idx].name != trimmed else { return }
        document.parts[i].sketches[idx].name = trimmed
        saveMessage = nil
        MCLog.shared.info(.sketch, "sketch renamed", context: ["id": id])
    }

    /// Rename a feature (same rules as `renameSketch` — display-only,
    /// no rebuild, persists on Save).
    func renameFeature(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !document.parts.isEmpty else { return }
        let i = min(partIndex, document.parts.count - 1)
        guard let idx = document.parts[i].features.firstIndex(where: { $0.id == id }),
              document.parts[i].features[idx].name != trimmed else { return }
        document.parts[i].features[idx].name = trimmed
        saveMessage = nil
        MCLog.shared.info(.feature, "feature renamed", context: ["id": id])
    }

    func setMaterial(_ materialID: String) {
        mutate { $0.materialID = materialID }
        MCLog.shared.info(.feature, "material changed", context: ["material": materialID])
    }

    // MARK: Feature creation / editing

    /// Append a feature and return it (so the caller can open its editor).
    @discardableResult
    func appendFeature(name: String, kind: FeatureKind) -> Feature {
        let feature = Feature(name: name, kind: kind)
        mutate { $0.features.append(feature) }
        MCLog.shared.info(.feature, "feature added", context: ["name": name])
        return feature
    }

    func updateFeature(id: String, name: String, kind: FeatureKind) {
        mutate { part in
            if let i = part.features.firstIndex(where: { $0.id == id }) {
                part.features[i].name = name
                part.features[i].kind = kind
            }
        }
    }

    func addPrimitive(_ kind: PrimitiveKind) -> Feature {
        let params: [String: Double]
        let label: String
        switch kind {
        case .box:      params = ["width": 30, "depth": 20, "height": 12]; label = "Box"
        case .cylinder: params = ["diameter": 20, "height": 25];           label = "Cylinder"
        case .sphere:   params = ["diameter": 24];                          label = "Sphere"
        case .cone:     params = ["diameter": 20, "height": 25];            label = "Cone"
        case .torus:    params = ["ringRadius": 15, "tubeRadius": 5];       label = "Torus"
        }
        return appendFeature(name: label, kind: .primitive(kind: kind, params: params))
    }

    /// First profile sketch of the part, or a coded error if there is
    /// none yet. Datum planes don't count — they hold no drawing.
    private func firstSketchOrError() -> Sketch? {
        if let sk = featureSketches.first { return sk }
        actionError = .padNoProfile
        MCLog.shared.log(error: .padNoProfile, category: .feature)
        return nil
    }

    func addPad() -> Feature? {
        guard let sk = firstSketchOrError() else { return nil }
        return appendFeature(name: "Pad", kind: .pad(sketchID: sk.id, length: 10))
    }

    func addPocket() -> Feature? {
        guard let sk = firstSketchOrError() else { return nil }
        return appendFeature(name: "Pocket", kind: .pocket(sketchID: sk.id, depth: 5))
    }

    func addRevolve() -> Feature? {
        guard let sk = firstSketchOrError() else { return nil }
        let axisID = sk.entities.first { entity in
            if case .line = entity { return true }
            return false
        }?.id ?? 0
        return appendFeature(name: "Revolve",
                             kind: .revolve(sketchID: sk.id, axisEntityID: axisID, angleDegrees: 360))
    }

    func addHole() -> Feature? {
        guard let sk = firstSketchOrError() else { return nil }
        return appendFeature(name: "Hole",
                             kind: .hole(sketchID: sk.id, diameter: 6, depth: 0, kind: .simple))
    }

    func addMirror() -> Feature {
        appendFeature(name: "Mirror", kind: .mirror(plane: .yz))
    }

    func addPattern() -> Feature {
        appendFeature(name: "Linear Pattern",
                      kind: .linearPattern(count: 3, spacing: Vec3(15, 0, 0)))
    }

    func addFillet() -> Feature {
        appendFeature(name: "Fillet", kind: .fillet(radius: 2))
    }

    func addThreadDefault() -> Feature? {
        do {
            let spec = try ThreadSpec.preset("M10")
            let checked = try spec.validated()
            for w in checked.warnings { MCLog.shared.log(error: w, category: .thread) }
            return appendFeature(name: "Thread M10", kind: .threadShaft(spec: checked.spec))
        } catch let e as CADError {
            actionError = e
            MCLog.shared.log(error: e, category: .thread)
            return nil
        } catch {
            actionError = .unknown("\(error)")
            return nil
        }
    }

    func deleteFeature(_ id: String) {
        mutate { $0.features.removeAll { $0.id == id } }
    }

    func setSuppressed(_ id: String, _ suppressed: Bool) {
        mutate { part in
            if let i = part.features.firstIndex(where: { $0.id == id }) {
                part.features[i].suppressed = suppressed
            }
        }
    }

    // MARK: Picking a face of the solid

    /// Resolve a SceneKit hit-test triangle (the display soup uses the
    /// welded mesh's triangle order) to the planar face that owns it.
    /// Returns nil with `actionError` set (MCAD-SK201 when no face
    /// matches) so every pick flow reports failures the same way.
    func resolvePickedFace(triangleIndex: Int) -> PlanarFace? {
        guard let mesh = rebuild?.mesh, mesh.triangleCount > 0 else {
            actionError = .kernelShapeInvalid("there is no solid to pick a face on yet")
            return nil
        }
        let welded = mesh.welded()
        guard triangleIndex >= 0, triangleIndex < welded.triangleCount else {
            actionError = .sketchPlaneLost(sketch: "picked face")
            MCLog.shared.log(error: .sketchPlaneLost(sketch: "picked face"), category: .sketch)
            return nil
        }
        let a = welded.vertices[Int(welded.indices[triangleIndex * 3])]
        let b = welded.vertices[Int(welded.indices[triangleIndex * 3 + 1])]
        let c = welded.vertices[Int(welded.indices[triangleIndex * 3 + 2])]
        let n = (b - a).cross(c - a).normalized
        let w = n.dot(a)
        let faces = FaceExtractor.planarFaces(of: welded)
        guard let face = faces.first(where: {
            $0.plane.normal.dot(n) > 0.999 && abs(n.dot($0.centroid) - w) < 1e-3
        }) else {
            actionError = .sketchPlaneLost(sketch: "picked face")
            MCLog.shared.log(error: .sketchPlaneLost(sketch: "picked face"), category: .sketch)
            return nil
        }
        return face
    }

    /// Append a fully-built generated sketch (face-pull outline,
    /// hole-point) as part of committing the feature that uses it.
    @discardableResult
    func addGeneratedSketch(_ sketch: Sketch) -> Sketch {
        mutate { $0.sketches.append(sketch) }
        MCLog.shared.info(.sketch, "generated sketch added",
                          context: ["name": sketch.name])
        return sketch
    }

    // MARK: Quick measure taps

    /// Record one quick-measure tap (measure mode): the first tap
    /// sets point A, the second sets B — the readout distance is the
    /// plain Euclidean A–B distance — and a third tap clears and
    /// starts a new A. Also notes the length when the tap lands on a
    /// sharp edge, using the same 2.5 mm edge resolution as the
    /// selection flow. Silent like picking: never raises the banner.
    func recordMeasureTap(triangleIndex: Int, point: Vec3) {
        if let mesh = rebuild?.mesh, mesh.triangleCount > 0 {
            var bestEdge: SolidEdge?
            var bestDist = 2.5
            for edge in SolidEdgeExtractor.edges(of: mesh) {
                let d = Self.distanceFromPointToSegment(point, edge.start, edge.end)
                if d < bestDist { bestDist = d; bestEdge = edge }
            }
            measureEdgeLength = bestEdge?.length
        } else {
            measureEdgeLength = nil
        }
        if measurePoints.count >= 2 {
            measurePoints = [point]
        } else {
            measurePoints.append(point)
        }
    }

    /// Drop the quick measurement (points + edge note). The measure
    /// MODE stays as it is — clearing is about the readout.
    func clearMeasure() {
        measurePoints = []
        measureEdgeLength = nil
    }

    // MARK: Selection-first picking (tap the model, then act on it)

    func clearPicked() { picked = nil }

    /// Resolve a normal-mode tap on the model into `picked`, in
    /// priority order: (a) a sharp edge within 2.5 mm of the hit
    /// point, (b) a fitted cylinder — external = shaft, internal =
    /// hole wall, (c) the grouped planar face owning the tapped
    /// triangle, (d) nothing → selection cleared. The cylinder fit
    /// runs BEFORE the face match on purpose: a tessellated cylinder
    /// side is many small planar quads, and matching the face first
    /// selected one flat facet (a visible rectangle) instead of the
    /// whole cylinder (device report, 2026-10-26). Silent by design:
    /// picking never raises the error banner.
    func resolveModelTap(triangleIndex: Int, point: Vec3) {
        guard let mesh = rebuild?.mesh, mesh.triangleCount > 0 else {
            clearPicked()
            return
        }
        selectedSketchID = nil
        // (a) EDGE — nearest sharp edge within 2.5 mm of the hit.
        // Edges under 1.2 mm are ignored: they are tessellation
        // noise (thread ridge facets measure ~0.65 mm), never a
        // design edge a tap could mean (device report, 2026-10-26).
        var bestEdge: SolidEdge?
        var bestDist = 2.5
        for edge in SolidEdgeExtractor.edges(of: mesh) where edge.length >= 1.2 {
            let d = Self.distanceFromPointToSegment(point, edge.start, edge.end)
            if d < bestDist { bestDist = d; bestEdge = edge }
        }
        if let edge = bestEdge {
            picked = .edge(midpoint: edge.mid, start: edge.start,
                           end: edge.end, length: edge.length)
            return
        }
        let welded = mesh.welded()
        guard triangleIndex >= 0, triangleIndex < welded.triangleCount else {
            clearPicked()
            return
        }
        // (b) SHAFT / HOLE WALL — fit a cylinder to the tapped patch
        // FIRST (see the doc comment: a cylinder side must not lose
        // to one of its own flat facets).
        if let fit = CylinderFitter.fit(mesh: welded, seedTriangle: triangleIndex) {
            picked = fit.isInternal ? .holeWall(fit) : .shaft(fit)
            return
        }
        // (c) FACE — same plane matcher as the face-pick flow, but
        // over groupedFaces so the stored index addresses the
        // per-face triangle lists (the highlight + label use them).
        let a = welded.vertices[Int(welded.indices[triangleIndex * 3])]
        let b = welded.vertices[Int(welded.indices[triangleIndex * 3 + 1])]
        let c = welded.vertices[Int(welded.indices[triangleIndex * 3 + 2])]
        let n = (b - a).cross(c - a).normalized
        let w = n.dot(a)
        let grouped = FaceExtractor.groupedFaces(of: mesh)
        if let idx = grouped.faces.firstIndex(where: {
            $0.plane.normal.dot(n) > 0.999 && abs(n.dot($0.centroid) - w) < 1e-3
        }) {
            picked = .face(index: idx, face: grouped.faces[idx], point: point)
            return
        }
        // (d) Nothing matched.
        clearPicked()
    }

    private static func distanceFromPointToSegment(_ p: Vec3, _ a: Vec3, _ b: Vec3) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        guard len2 > 1e-12 else { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(ab) / len2))
        return p.distance(to: a + ab * t)
    }

    /// Create a sketch on an already-resolved face and remember its
    /// outline as the editor guide. Returns the new sketch's id.
    @discardableResult
    func addSketchOnFace(_ face: PlanarFace) -> String {
        let sketch = Sketch(name: "Face sketch", plane: face.plane)
        faceOutlines[sketch.id] = face.outline2D
        mutate { $0.sketches.append(sketch) }
        MCLog.shared.info(.sketch, "face sketch created",
                          context: ["area": String(format: "%.1f", face.area),
                                    "tris": "\(face.triangleCount)"])
        return sketch.id
    }

    // MARK: File actions

    func save() {
        do {
            try IOService.saveJSON(document, to: fileURL)
            saveMessage = "Saved"
            actionError = nil
        } catch let e as CADError {
            actionError = e
        } catch {
            actionError = .unknown("\(error)")
        }
    }

    func exportSTL() {
        exportSTL(toShare: false)
    }

    /// Save As ▸ STL — the same binary STL as the Export STL button,
    /// but the file lands in `shareURL` for the sheet's share step.
    func exportSTLForShare() {
        exportSTL(toShare: true)
    }

    private func exportSTL(toShare: Bool) {
        guard let mesh = rebuild?.mesh, mesh.triangleCount > 0 else {
            actionError = .exportWriteFailed("there is no solid to export yet")
            MCLog.shared.log(error: .exportWriteFailed("empty mesh"), category: .io)
            return
        }
        let safeName = document.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).stl")
        do {
            // Export uses the raw welded mesh — triangles live here,
            // never in the smooth preview.
            stlWarnings = try IOService.writeSTL(mesh.welded(), to: url)
            if toShare { shareURL = url } else { stlURL = url }
        } catch let e as CADError {
            actionError = e
        } catch {
            actionError = .unknown("\(error)")
        }
    }

    /// Save As ▸ MetalCAD Document (.metaldoc): the current document
    /// serialized as its native Codable JSON — reopens in MetalCAD
    /// exactly as-is, sketches and feature history included.
    func exportMetalDoc() {
        let safeName = document.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).metaldoc")
        do {
            try IOService.saveJSON(document, to: url)
            shareURL = url
            actionError = nil
        } catch let e as CADError {
            actionError = e
        } catch {
            actionError = .unknown("\(error)")
        }
    }

    /// Save As ▸ OBJ: the welded result mesh as a Wavefront OBJ.
    func exportOBJ() {
        guard let mesh = rebuild?.mesh, mesh.triangleCount > 0 else {
            actionError = .exportWriteFailed("there is no solid to export yet")
            MCLog.shared.log(error: .exportWriteFailed("empty mesh"), category: .io)
            return
        }
        let safeName = document.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).obj")
        do {
            stlWarnings = try IOService.writeOBJ(mesh.welded(), to: url)
            shareURL = url
        } catch let e as CADError {
            actionError = e
        } catch {
            actionError = .unknown("\(error)")
        }
    }
}

/// The part editor v3 — a Fusion 360-style workspace:
/// a header strip (part, material, volume, mass, size — always
/// visible), a grouped ribbon toolbar (Sketch / Create / Modify /
/// Inspect), a browser on the left (sketches + the feature timeline in
/// build order), the smooth preview in the middle, and a context panel
/// on the right for the active tool.
/// What the browser/history Rename alert is editing: a sketch or a
/// feature, addressed by ID — the same way features reference
/// sketches — so a rename can never break the model.
private struct RenameTarget: Identifiable {
    enum Kind { case sketch, feature }
    let kind: Kind
    let targetID: String
    let currentName: String
    var id: String { "\(kind == .sketch ? "sketch" : "feature"):\(targetID)" }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    /// App navigation (Home ⇄ Editor) — the header's Home button
    /// closes the editor back to the files screen.
    @EnvironmentObject private var session: AppSession
    /// The user's accent color (Home ▸ Settings) — one stored hex
    /// drives this view's chrome and is handed to SceneKitView for
    /// the 3D highlights/tint.
    @AppStorage(MCAccent.key) private var accentHex: String = MCAccent.defaultHex
    private var accent: Color { MCAccent.color(hex: accentHex) }
    @State private var featureToEdit: Feature?
    @State private var showMaterialPicker = false
    @State private var showSaveAsSheet = false
    /// Rename alert state (browser / history rows): the target whose
    /// name is being edited, and the text field's working copy.
    @State private var renameTarget: RenameTarget?
    @State private var renameText: String = ""
    @State private var pickingFace = false
    @State private var pickPurpose: FacePickPurpose = .sketchOnFace
    @State private var sketchNav: SketchNav?
    @State private var activeTool: ActiveTool?
    @State private var extrudePresetSketchID: String?
    // Left browser panel width (v4.1): persisted, drag-resizable via
    // the handle on its trailing edge. 0 = fully collapsed; below 250
    // the panel renders as a slim icon rail (250 is the full row's
    // floor: icon + eye + menu + insets leave ~95 pt of text width —
    // any narrower and row names crushed letter-by-letter instead of
    // truncating, device report 2026-10-26). The header sidebar button
    // and a double-tap on the handle toggle hidden <-> last width.
    @AppStorage("browserPanelWidth") private var browserPanelWidth: Double = 300
    @AppStorage("browserPanelLastWidth") private var browserPanelLastWidth: Double = 300
    /// Distance quick press/pull starts at — the value last
    /// confirmed with Done, so a repeated pull (or the double-tap
    /// shortcut) repeats without re-typing.
    @AppStorage("quickPullDistance") private var quickPullDistance: Double = 10
    @State private var panelDragStart: Double?
    // Section view state. `sectionT` is the committed cut position;
    // the slider edits `sectionSlider` and commits on release so the
    // CSG section only runs once per drag, not per pixel.
    @State private var sectionOn = false
    @State private var sectionAxis = 2
    @State private var sectionT: Double = 0.5
    @State private var sectionSlider: Double = 0.5
    @State private var sectionedMesh: Mesh?
    // Quick press/pull mode (v4.3): entered from the picked-face
    // bar's Pull / Press buttons. The face is SNAPPED on entry (the
    // live selection may move on underneath; the card keeps acting
    // on this face). The slider drafts the very extrude2 the Pull
    // Face panel builds — via the shared mcFacePull helpers — so the
    // ghost tracks the distance before Done commits sketch+feature.
    @State private var quickFace: PlanarFace?
    @State private var quickCut = false
    @State private var quickDistance: Double = 10
    @State private var quickSketchID: String = UUID().uuidString
    private var quickActive: Bool { quickFace != nil }

    @ViewBuilder
    private var mainRow: some View {
                HStack(spacing: 0) {
                    if browserPanelWidth > 0 {
                        browserPanel
                            .frame(width: browserPanelWidth)
                    }
                    panelDragHandle
                    centerColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let tool = activeTool {
                        Divider()
                        ScrollView {
                            ToolPanelView(
                                tool: tool,
                                model: model,
                                extrudeSketchID: extrudePresetSketchID,
                                panelSketchID: model.pendingPanelSketchID ?? model.selectedSketchID,
                                panelOperation: model.pendingPanelOperation,
                                close: {
                                    activeTool = nil
                                    extrudePresetSketchID = nil
                                },
                                openSketch: { id in sketchNav = SketchNav(id: id) },
                                pickFace: { purpose in
                                    pickPurpose = purpose
                                    activeTool = nil
                                    startFacePicking()
                                },
                                switchTool: { newTool in
                                    activeTool = newTool
                                }
                            )
                        }
                        .frame(width: 380)
                        .background(Color.white.opacity(0.03))
                    }
                }
        .onChange(of: activeTool) { _, newTool in
            // A closed panel leaves no draft ghost and no stale
            // panel presets behind.
            if newTool == nil {
                model.pendingPanelSketchID = nil
                model.pendingPanelOperation = nil
                model.pendingHoleSketch = nil
                model.pendingRevolveSketch = nil
                model.setDraft(nil)
            }
        }
    }

    /// The editor shell (JOB A layering): navigation stack, title
    /// and toolbar ONLY. The two sheets and the remaining change
    /// handlers hang off SEPARATE computed properties below
    /// (withMaterialSheet, body) and off mainRow — a single giant
    /// modifier chain on one expression repeatedly timed out the
    /// Swift type checker (v4.2 Actions failures), so every layer
    /// here stays a small type-check unit of its own.
    private var coreView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerStrip
                Divider()
                ribbon
                Divider()
                mainRow
            }
            .navigationTitle(model.document.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $sketchNav) { nav in
                SketchEditorView(model: model, sketchID: nav.id)
            }
            // Save / Save As / Export used to live here as text
            // links — they moved into the header strip as separate
            // icon+text chips (top-UI redesign, 2026-10-26).
        }
        .onChange(of: model.pendingExtrudeSketchID) { _, newID in
            guard let newID else { return }
            model.pendingExtrudeSketchID = nil
            extrudePresetSketchID = newID
            activeTool = .extrude
        }
        .onChange(of: baseMeshKey) { _, _ in
            // The result mesh changed — any picked face/edge/shaft
            // referred to the old geometry, so drop the selection.
            // Quick-measure points referred to it too.
            model.clearPicked()
            model.clearMeasure()
            if sectionOn { refreshSection() }
        }
    }

    /// coreView + the material-picker sheet (its own layer, per
    /// coreView's note on type-check size).
    private var withMaterialSheet: some View {
        coreView
            .sheet(isPresented: $showMaterialPicker) {
                MaterialPickerSheet(
                    currentID: model.part?.materialID ?? MaterialLibrary.defaultMaterial.id,
                    onPick: { id in
                        model.setMaterial(id)
                        showMaterialPicker = false
                    },
                    onCancel: { showMaterialPicker = false }
                )
            }
    }

    var body: some View {
        withMaterialSheet
            .sheet(item: $featureToEdit) { feature in
                FeatureEditorSheet(
                    feature: feature,
                    sketches: model.featureSketches,
                    currentFaces: currentFaces,
                    filletMaxFeasible: filletMaxFeasible(for: feature),
                    onSave: { name, kind in
                        model.updateFeature(id: feature.id, name: name, kind: kind)
                        model.setDraft(nil)
                        featureToEdit = nil
                    },
                    onCancel: {
                        model.setDraft(nil)
                        featureToEdit = nil
                    },
                    onDraft: { kind in
                        if let idx = model.part?.features.firstIndex(where: { $0.id == feature.id }) {
                            model.draftReplacing(index: idx,
                                                 with: Feature(id: feature.id, name: feature.name, kind: kind))
                        }
                    },
                    onDraftEnd: { model.setDraft(nil) }
                )
            }
            .sheet(isPresented: $showSaveAsSheet) {
                saveAsSheet
            }
            .alert("Rename", isPresented: renamePresented) {
                TextField("Name", text: $renameText)
                    .mcFont(20)
                Button("Rename") {
                    if let target = renameTarget {
                        switch target.kind {
                        case .sketch: model.renameSketch(id: target.targetID, name: renameText)
                        case .feature: model.renameFeature(id: target.targetID, name: renameText)
                        }
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                Text("Rename “\(renameTarget?.currentName ?? "")”")
            }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private func beginRename(kind: RenameTarget.Kind, id: String, name: String) {
        renameText = name
        renameTarget = RenameTarget(kind: kind, targetID: id, currentName: name)
    }

    /// Save As sheet (header): in-place Save on top — saving in
    /// MetalCAD is manual, nothing autosaves, so the ability stays
    /// in the sheet — then the export formats. Tapping a format
    /// generates the file and the share row appears (the same
    /// generate-then-share pattern as Export STL ▸ Share STL).
    private var saveAsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        model.save()
                        showSaveAsSheet = false
                    } label: {
                        saveAsRow("Save", icon: "square.and.arrow.down",
                                  detail: "Save in place, in your Documents library — same file, same name.")
                    }
                    .buttonStyle(.plain)
                }
                Section("Export a copy") {
                    Button { model.exportMetalDoc() } label: {
                        saveAsRow("MetalCAD Document (.metaldoc)", icon: "doc.fill",
                                  detail: "The native file — reopens in MetalCAD exactly as-is, sketches and history included.")
                    }
                    .buttonStyle(.plain)
                    Button { model.exportSTLForShare() } label: {
                        saveAsRow("STL (.stl)", icon: "cube.fill",
                                  detail: "Binary mesh for 3D printing and slicers.")
                    }
                    .buttonStyle(.plain)
                    Button { model.exportOBJ() } label: {
                        saveAsRow("OBJ (.obj)", icon: "square.stack.3d.up.fill",
                                  detail: "Mesh for Blender and other 3D tools.")
                    }
                    .buttonStyle(.plain)
                }
                if let url = model.shareURL {
                    Section {
                        ShareLink(item: url) {
                            HStack(spacing: 10) {
                                Image(systemName: "square.and.arrow.up")
                                    .mcFont(22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Share / Save file")
                                        .mcFont(20, weight: .semibold)
                                    Text(url.lastPathComponent)
                                        .mcFont(16)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let err = model.actionError {
                    Section {
                        Text("\(err.userMessage) (\(err.code))")
                            .mcFont(17, weight: .semibold)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Save As")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showSaveAsSheet = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func saveAsRow(_ title: String, icon: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .mcFont(24)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .mcFont(20, weight: .semibold)
                Text(detail)
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: Mesh / section plumbing

    private var baseMesh: Mesh { model.rebuild?.mesh ?? Mesh() }

    /// Planar faces of the current body in the kernel's order — the
    /// index space ExtrudeEnd.upToFace refers to.
    private var currentFaces: [PlanarFace] {
        guard baseMesh.triangleCount > 0 else { return [] }
        return FaceExtractor.planarFaces(of: baseMesh)
    }

    private var baseMeshKey: String {
        "\(baseMesh.triangleCount)-\(baseMesh.volume)"
    }

    private var displayMesh: Mesh {
        sectionOn ? (sectionedMesh ?? baseMesh) : baseMesh
    }

    private var sectionNormal: Vec3 {
        sectionAxis == 0 ? Vec3(1, 0, 0) : (sectionAxis == 1 ? Vec3(0, 1, 0) : Vec3(0, 0, 1))
    }

    private var sectionExtent: Double {
        let s = baseMesh.bounds.size
        return sectionAxis == 0 ? s.x : (sectionAxis == 1 ? s.y : s.z)
    }

    private func refreshSection() {
        guard sectionOn, baseMesh.triangleCount > 0 else {
            sectionedMesh = nil
            return
        }
        let through = baseMesh.bounds.center + sectionNormal * ((sectionT - 0.5) * sectionExtent)
        do {
            sectionedMesh = try baseMesh.sectioned(normal: sectionNormal, through: through)
        } catch let e as CADError {
            model.actionError = e
            MCLog.shared.log(error: e, category: .kernel)
            sectionedMesh = nil
        } catch {
            sectionedMesh = nil
        }
    }

    private func toggleSection() {
        sectionOn.toggle()
        if sectionOn {
            activeTool = nil
            refreshSection()
        } else {
            sectionedMesh = nil
        }
    }

    // MARK: Header strip (always visible)

    /// Header file buttons (top-UI redesign): separate chip
    /// buttons at the far LEFT of the header — Home back to the
    /// files screen, Save As (format sheet), Export STL — each an
    /// SF Symbol + text, chip-styled like the ribbon buttons,
    /// never joined and never bare text links.
    private var headerFileButtons: some View {
        HStack(spacing: 10) {
            headerChip("Home", icon: "house.fill") { session.closeEditor() }
            headerChip("Save As", icon: "square.and.arrow.down") {
                model.shareURL = nil
                showSaveAsSheet = true
            }
            headerChip("Export STL", icon: "cube") { model.exportSTL() }
            if let url = model.stlURL {
                ShareLink(item: url) {
                    headerChipLabel("Share STL", icon: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            if let msg = model.saveMessage {
                Text(msg)
                    .mcFont(17, weight: .semibold)
                    .foregroundStyle(.green)
            }
        }
    }

    private func headerChip(_ title: String, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { headerChipLabel(title, icon: icon) }
            .buttonStyle(.plain)
    }

    private func headerChipLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .mcFont(19, weight: .semibold)
            Text(title)
                .mcFont(19, weight: .semibold)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.primary)
    }

    private var headerStrip: some View {
        HStack(spacing: 18) {
            headerFileButtons
            Button {
                toggleBrowserPanel()
            } label: {
                Image(systemName: "sidebar.left")
                    .mcFont(24)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.part?.name ?? "Part")
                    .mcFont(22, weight: .bold)
                Text("Material, size and weight — always up to date")
                    .mcFont(15)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showMaterialPicker = true
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(materialSwatch)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.part?.material.name ?? "—")
                            .mcFont(19, weight: .bold)
                            .foregroundStyle(.primary)
                        Text("\(String(format: "%.2f", model.part?.material.density ?? 0)) g/cm³")
                            .mcFont(15)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            headerStat("Volume", "\(String(format: "%.2f", baseMesh.volume / 1000)) cm³")
            headerStat("Mass", model.rebuild?.massGrams.map(mcMass) ?? "—")
            if let bodies = model.rebuild?.bodies, bodies.count > 1 {
                headerStat("Bodies", "\(bodies.count)")
            }
            headerStat("Size", sizeText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    private var materialSwatch: Color {
        let m = model.part?.material ?? MaterialLibrary.defaultMaterial
        return Color(red: m.red, green: m.green, blue: m.blue)
    }

    private var sizeText: String {
        guard baseMesh.triangleCount > 0 else { return "—" }
        let s = baseMesh.bounds.size
        return "\(mcFmt(s.x)) × \(mcFmt(s.y)) × \(mcFmt(s.z)) mm"
    }

    private func headerStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .mcFont(15, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .mcFont(19, weight: .bold)
        }
    }

    // MARK: Ribbon toolbar (Fusion-style groups)

    private var ribbon: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 2) {
                ribbonGroup("SKETCH") {
                    ribbonButton("New Sketch", icon: "square.and.pencil", active: activeTool == .newSketch) {
                        selectTool(.newSketch)
                    }
                    ribbonButton("On Face", icon: "square.on.square.dashed", active: pickingFace && pickPurpose == .sketchOnFace) {
                        pickPurpose = .sketchOnFace
                        activeTool = nil
                        startFacePicking()
                    }
                }
                ribbonGroup("CONSTRUCT") {
                    ribbonButton("Offset Plane", icon: "square.on.square", active: activeTool == .offsetPlane) {
                        selectTool(.offsetPlane)
                    }
                    ribbonButton("Angle Plane", icon: "triangle", active: activeTool == .anglePlane) {
                        selectTool(.anglePlane)
                    }
                    ribbonButton("Midplane", icon: "rectangle.split.3x1", active: activeTool == .midplane) {
                        selectTool(.midplane)
                    }
                }
                ribbonGroup("CREATE") {
                    ribbonButton("Extrude", icon: "rectangle.expand.vertical", active: activeTool == .extrude) {
                        selectTool(.extrude)
                    }
                    ribbonButton("Revolve", icon: "rotate.3d", active: activeTool == .revolve) {
                        selectTool(.revolve)
                    }
                    ribbonButton("Thread", icon: "lines.measurement.horizontal", active: false) {
                        activeTool = nil
                        if let f = model.addThreadDefault() { featureToEdit = f }
                    }
                    ribbonButton("Hole", icon: "circle.circle", active: activeTool == .hole) {
                        selectTool(.hole)
                    }
                    ribbonButton("Loft", icon: "square.2.layers.3d", active: activeTool == .loft) {
                        selectTool(.loft)
                    }
                    ribbonButton("Sweep", icon: "lasso", active: activeTool == .sweep) {
                        selectTool(.sweep)
                    }
                    ribbonButton("Coil", icon: "tornado", active: activeTool == .coil) {
                        selectTool(.coil)
                    }
                    ribbonButton("Pipe", icon: "waveform.path", active: activeTool == .pipe) {
                        selectTool(.pipe)
                    }
                    ribbonButton("Rib", icon: "square.split.2x1", active: activeTool == .rib) {
                        selectTool(.rib)
                    }
                    primitivesMenu
                }
                ribbonGroup("MODIFY") {
                    ribbonButton("Fillet", icon: "capsule", active: activeTool == .fillet) {
                        selectTool(.fillet)
                    }
                    ribbonButton("Chamfer", icon: "octagon", active: activeTool == .chamfer) {
                        selectTool(.chamfer)
                    }
                    ribbonButton("Shell", icon: "cube.transparent", active: activeTool == .shell) {
                        selectTool(.shell)
                    }
                    ribbonButton("Mirror", icon: "flip.horizontal", active: activeTool == .mirror) {
                        selectTool(.mirror)
                    }
                    ribbonButton("Pattern", icon: "square.grid.2x2", active: activeTool == .pattern) {
                        selectTool(.pattern)
                    }
                    ribbonButton("Circ. Pattern", icon: "arrow.triangle.2.circlepath", active: activeTool == .circularPattern) {
                        selectTool(.circularPattern)
                    }
                    ribbonButton("Draft", icon: "pyramid", active: activeTool == .draft) {
                        selectTool(.draft)
                    }
                    ribbonButton("Scale", icon: "arrow.up.and.down.and.arrow.left.and.right", active: activeTool == .scaleBody) {
                        selectTool(.scaleBody)
                    }
                    ribbonButton("Move", icon: "move.3d", active: activeTool == .moveBody) {
                        selectTool(.moveBody)
                    }
                    ribbonButton("Split", icon: "rectangle.split.2x1", active: activeTool == .splitBody) {
                        selectTool(.splitBody)
                    }
                }
                ribbonGroup("INSPECT") {
                    ribbonButton("Measure", icon: "ruler", active: activeTool == .measure) {
                        selectTool(.measure)
                    }
                    ribbonButton("Sketches", icon: model.showsSketches ? "eye" : "eye.slash",
                                 active: model.showsSketches) {
                        model.showsSketches.toggle()
                    }
                    ribbonButton("Section", icon: "square.lefthalf.filled", active: sectionOn) {
                        toggleSection()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.white.opacity(0.02))
    }

    private func selectTool(_ tool: ActiveTool) {
        if activeTool == tool {
            activeTool = nil
            extrudePresetSketchID = nil
        } else {
            activeTool = tool
        }
    }

    private func ribbonGroup<Content: View>(_ caption: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 4) { content() }
            Text(caption)
                .mcFont(14, weight: .bold)
                .foregroundStyle(.secondary)
                .tracking(1.5)
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 4)
        }
    }

    private func ribbonButton(_ label: String, icon: String, active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .mcFont(24)
                Text(label)
                    .mcFont(16, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(active ? .black : .primary)
            .frame(minWidth: 80, minHeight: 58)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(active ? accent : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private var primitivesMenu: some View {
        let isActive: Bool = {
            if case .primitive = activeTool ?? .measure { return true }
            return false
        }()
        return Menu {
            ForEach(PrimitiveKind.allCases, id: \.self) { kind in
                Button(primitiveLabel(kind)) { activeTool = .primitive(kind) }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "cube")
                    .mcFont(24)
                HStack(spacing: 3) {
                    Text("Primitive")
                        .mcFont(16, weight: .semibold)
                    Image(systemName: "chevron.down")
                        .mcFont(13, weight: .bold)
                }
                .lineLimit(1)
            }
            .foregroundStyle(isActive ? .black : .primary)
            .frame(minWidth: 80, minHeight: 58)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? accent : Color.white.opacity(0.06)))
        }
    }

    // MARK: Center column (preview + banners + section controls)

    private var centerColumn: some View {
        VStack(spacing: 10) {
            if pickingFace {
                pickBanner
            }
            if let err = model.actionError {
                errorBanner(err, dismissible: true)
            }
            if let err = model.rebuild?.firstError {
                errorBanner(err, dismissible: false)
            }
            // AnyView boundary (v4.9): centerColumn's opaque type used
            // to embed this whole subtree, and instantiating it on
            // first body update recursed the Swift runtime's type
            // demangler into a stack-overflow crash on editor open
            // (device .ips, 2026-10-26). Erasing the ZStack keeps
            // centerColumn's own type shallow; content is unchanged.
            AnyView(ZStack(alignment: .bottom) {
                SceneKitView(
                    // A live draft PREVIEW REPLACES the model while a
                    // panel drafts (isPreview tints it) — no overlay
                    // ghost: coincident surfaces z-fought into orange
                    // shards. The preview also takes precedence over
                    // the section-cut display mesh while active.
                    mesh: model.previewMesh ?? displayMesh,
                    material: model.part?.material,
                    isPreview: model.previewMesh != nil,
                    documentID: model.document.id,
                    accentUIColor: MCAccent.uiColor(hex: accentHex),
                    sketches: model.part?.sketches ?? [],
                    selectedSketchID: model.selectedSketchID,
                    hiddenSketchIDs: model.hiddenSketchIDs,
                    showSketches: model.showsSketches,
                    isPickingFace: pickingFace,
                    onFacePicked: { index in handleFacePicked(index) },
                    onSketchPicked: { id in
                        // In quick-measure mode a tap that misses the
                        // model is just a miss — it must not start
                        // selecting sketches underneath the user.
                        guard !model.measureMode else { return }
                        // Sketch and model selections are mutually
                        // exclusive — whichever was tapped last wins.
                        model.clearPicked()
                        model.selectedSketchID = id
                    },
                    picked: model.picked,
                    pickedMesh: model.rebuild?.mesh ?? Mesh(),
                    measurePoints: model.measurePoints,
                    onModelHit: { triangleIndex, point in
                        // In section view the displayed mesh is the
                        // cut mesh, whose triangle indices don't map
                        // to the result mesh — taps select nothing.
                        guard !sectionOn else { return }
                        // Quick measure armed: the tap records a
                        // measure point instead of resolving a picked
                        // selection. (Face-pick mode never reaches
                        // here — SceneKitView routes it first.)
                        if model.measureMode {
                            model.recordMeasureTap(triangleIndex: triangleIndex, point: point)
                        } else {
                            model.resolveModelTap(triangleIndex: triangleIndex, point: point)
                        }
                    },
                    onModelDoubleTap: { triangleIndex, point in
                        handleModelDoubleTap(triangleIndex: triangleIndex, point: point)
                    }
                )
                // NO .id() here: pinning the view's identity to the
                // mesh used to recreate the SCNView on every commit,
                // which reset the camera to its default framing.
                // Geometry rebuilds in place (SceneKitView's own
                // key), and the camera pose persists per document.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let selID = model.selectedSketchID, activeTool == nil, !pickingFace,
                   model.picked == nil,
                   let sel = model.sketch(withID: selID), !sel.isDatumPlane {
                    selectionActionBar(sel)
                }
                if let picked = model.picked, activeTool == nil, !pickingFace, !quickActive {
                    pickedActionBar(picked)
                }
                if quickActive {
                    quickPressPullCard
                }
                // Quick-measure chrome, pinned to the TOP of the
                // viewport so it never collides with the bottom
                // action bars or the quick press/pull card: the
                // readout (top-left) shows whenever a measurement
                // exists — even after measure mode is toggled off —
                // and the toggle (top-right) is always there.
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        if model.measureMode || !model.measurePoints.isEmpty
                            || model.measureEdgeLength != nil {
                            measureReadoutCard
                        }
                        Spacer()
                        measureToggleButton
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if sectionOn {
                AnyView(sectionControls)
            }
            AnyView(statsBar)
            if !model.stlWarnings.isEmpty {
                ForEach(Array(model.stlWarnings.enumerated()), id: \.offset) { _, w in
                    Text("\(w.userMessage) (\(w.code))")
                        .mcFont(17, weight: .semibold)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onChange(of: model.picked == nil) { _, isNil in
            // The selection under quick mode was cleared (tapped
            // empty space): quick mode has nothing left to act on,
            // so leave it, discarding the draft. (A Done COMMIT
            // keeps picked set until the rebuild clears it — by then
            // quick mode has already exited, so this stays a no-op.)
            if isNil, quickActive { cancelQuick() }
        }
        .onChange(of: activeTool != nil) { _, hasTool in
            // A tool panel takes over the draft machinery — quick
            // mode ends, discarding its draft (the panel drafts its
            // own on appear).
            if hasTool, quickActive { cancelQuick() }
        }
        .onChange(of: quickSignature) { _, _ in refreshQuickDraft() }
        .padding(10)
    }

    private var sectionControls: some View {
        HStack(spacing: 14) {
            Text("Section")
                .mcFont(19, weight: .bold)
            Picker("Axis", selection: $sectionAxis) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .onChange(of: sectionAxis) { _, _ in refreshSection() }
            Slider(value: $sectionSlider, in: 0...1) { editing in
                if !editing {
                    sectionT = sectionSlider
                    refreshSection()
                }
            }
            Text(sectionPositionText)
                .mcFont(18, weight: .semibold)
                .frame(width: 150, alignment: .trailing)
            Button("Done") { toggleSection() }
                .mcFont(19, weight: .semibold)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    private var sectionPositionText: String {
        let axisName = sectionAxis == 0 ? "X" : (sectionAxis == 1 ? "Y" : "Z")
        let offset = (sectionSlider - 0.5) * sectionExtent
        return "\(axisName) \(offset >= 0 ? "+" : "−")\(mcFmt(abs(offset))) mm"
    }

    private var pickBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
                .mcFont(26)
            Text(pickBannerText)
                .mcFont(20, weight: .semibold)
            Spacer()
            Button("Cancel") { pickingFace = false }
                .mcFont(20, weight: .semibold)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.25)))
    }

    private var pickBannerText: String {
        switch pickPurpose {
        case .sketchOnFace:
            return "Tap a flat face on the model to sketch on it."
        case .newSketchFace:
            return "Tap a flat face — the new sketch will lie on it."
        case .offsetDatumFace:
            return "Tap a flat face to offset a datum plane from."
        case .midplaneA:
            return "Tap the first of two parallel faces for the midplane."
        case .midplaneB:
            return "Tap the second parallel face for the midplane."
        case .redefineFace:
            return "Tap a flat face — the sketch will move onto it."
        }
    }

    private func startFacePicking() {
        if sectionOn { toggleSection() }
        pickingFace = true
    }

    private func handleFacePicked(_ triangleIndex: Int) {
        pickingFace = false
        guard let face = model.resolvePickedFace(triangleIndex: triangleIndex) else { return }
        switch pickPurpose {
        case .sketchOnFace:
            sketchNav = SketchNav(id: model.addSketchOnFace(face))
        case .newSketchFace:
            model.planeChoice = .face(face)
            activeTool = .newSketch
        case .offsetDatumFace:
            model.constructFace = face
            activeTool = .offsetPlane
        case .midplaneA:
            model.midplaneFaceA = face
            activeTool = .midplane
        case .midplaneB:
            model.midplaneFaceB = face
            activeTool = .midplane
        case .redefineFace(let sketchID):
            model.setSketchPlane(id: sketchID, plane: face.plane, outline: face.outline2D)
            model.redefineChoice = .face(face)
            activeTool = .redefinePlane(sketchID)
        }
    }

    private var statsBar: some View {
        HStack(spacing: 24) {
            Text("Triangles: \(displayMesh.triangleCount)")
            if sectionOn {
                Text("Section view")
                    .foregroundStyle(accent)
            }
            if let w = model.rebuild?.warnings, !w.isEmpty {
                Text("\(w.count) warning\(w.count == 1 ? "" : "s")")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .mcFont(19, weight: .semibold)
    }

    // MARK: Sketch selection action bar (Fusion-style)

    /// Floating bar over the 3D view when a sketch is selected by
    /// tapping its overlay: act on that sketch immediately, with the
    /// tool panels pre-set to it.
    private func selectionActionBar(_ sketch: Sketch) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sketch.name)
                    .mcFont(19, weight: .bold)
                    .lineLimit(1)
                Text("Selected sketch")
                    .mcFont(14)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 170, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    actionBarButton("Extrude", icon: "rectangle.expand.vertical") {
                        model.pendingPanelSketchID = sketch.id
                        model.pendingPanelOperation = "join"
                        activeTool = .extrude
                    }
                    actionBarButton("Pocket", icon: "arrow.down.square") {
                        model.pendingPanelSketchID = sketch.id
                        model.pendingPanelOperation = "cut"
                        activeTool = .extrude
                    }
                    actionBarButton("Revolve", icon: "rotate.3d") {
                        model.pendingPanelSketchID = sketch.id
                        activeTool = .revolve
                    }
                    actionBarButton("Hole", icon: "circle.circle") {
                        model.pendingPanelSketchID = sketch.id
                        activeTool = .hole
                    }
                    actionBarButton("Loft", icon: "square.stack.3d.up") {
                        model.pendingPanelSketchID = sketch.id
                        activeTool = .loft
                    }
                    actionBarButton("Sweep", icon: "arrow.triangle.2.circlepath") {
                        model.pendingPanelSketchID = sketch.id
                        activeTool = .sweep
                    }
                    actionBarButton("Edit Sketch", icon: "pencil") {
                        sketchNav = SketchNav(id: sketch.id)
                    }
                    actionBarButton("Hide", icon: "eye.slash") {
                        model.hiddenSketchIDs.insert(sketch.id)
                        model.selectedSketchID = nil
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.5), lineWidth: 1))
        .padding(10)
    }

    // MARK: Picked selection action bar (face / edge / shaft / hole)

    /// Floating bar over the 3D view when a face, edge, shaft or hole
    /// wall was selected by tapping the model: the actions that make
    /// sense for exactly that piece of geometry, Fusion-style.
    @ViewBuilder
    private func pickedActionBar(_ picked: PickedSelection) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pickedBarTitle(picked))
                    .mcFont(19, weight: .bold)
                    .lineLimit(1)
                Text(pickedBarSubtitle(picked))
                    .mcFont(14)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 210, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    switch picked {
                    case .face(_, let face, let point):
                        actionBarButton("Sketch Here", icon: "square.and.pencil") {
                            sketchNav = SketchNav(id: model.addSketchOnFace(face))
                        }
                        actionBarButton("Pull", icon: "arrow.up.circle.fill") {
                            startQuick(cut: false, face: face)
                        }
                        actionBarButton("Press", icon: "arrow.down.circle.fill") {
                            startQuick(cut: true, face: face)
                        }
                        actionBarButton("Pull Face…", icon: "arrow.up.square") {
                            activeTool = .pullFace
                        }
                        actionBarButton("Revolve Face…", icon: "rotate.3d.fill") {
                            model.pendingRevolveSketch = mcFacePullSketch(
                                id: UUID().uuidString, face: face, cut: false,
                                name: "Face revolve (auto)")
                            activeTool = .revolveFace
                        }
                        actionBarButton("Hole Here…", icon: "circle.circle") {
                            model.pendingHoleSketch = mcHolePointSketch(face: face, point: point)
                            activeTool = .hole
                        }
                        actionBarButton("Fillet Face Edges…", icon: "capsule") {
                            activeTool = .filletFaceEdges
                        }
                        actionBarButton("Chamfer Face Edges…", icon: "octagon") {
                            activeTool = .chamferFaceEdges
                        }
                        actionBarButton("Offset Plane", icon: "square.on.square") {
                            model.constructFace = face
                            activeTool = .offsetPlane
                        }
                        actionBarButton("Measure", icon: "ruler") {
                            model.measureFace = face
                            activeTool = .measure
                        }
                    case .edge:
                        actionBarButton("Fillet This Edge…", icon: "capsule") {
                            activeTool = .filletEdge
                        }
                        actionBarButton("Chamfer This Edge…", icon: "octagon") {
                            activeTool = .chamferEdge
                        }
                    case .shaft:
                        actionBarButton("Thread This Shaft…", icon: "lines.measurement.horizontal") {
                            activeTool = .threadShaft
                        }
                        actionBarButton("Measure", icon: "ruler") {
                            activeTool = .measure
                        }
                    case .holeWall:
                        actionBarButton("Clear", icon: "xmark") {
                            model.clearPicked()
                        }
                    }
                }
            }
            if case .holeWall = picked {
                EmptyView()
            } else {
                Button {
                    model.clearPicked()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .mcFont(22)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selection")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.5), lineWidth: 1))
        .padding(10)
    }

    private func pickedBarTitle(_ picked: PickedSelection) -> String {
        switch picked {
        case .face(_, let face, _):
            return "Face · \(String(format: "%.0f", face.area)) mm²"
        case .edge(_, _, _, let length):
            return "Edge · \(mcFmt(length)) mm"
        case .shaft(let fit):
            return "Shaft · Ø \(mcFmt(fit.radius * 2)) × \(mcFmt(fit.height))"
        case .holeWall(let fit):
            return "Hole · Ø \(mcFmt(fit.radius * 2)) × \(mcFmt(fit.height)) deep"
        }
    }

    private func pickedBarSubtitle(_ picked: PickedSelection) -> String {
        switch picked {
        case .face:
            return "Selected face"
        case .edge:
            return "Selected edge"
        case .shaft:
            return "Selected shaft"
        case .holeWall:
            return "Internal threading isn't supported yet"
        }
    }

    // MARK: Quick press/pull (tap a face → Pull / Press)

    /// Everything the draft depends on, as one string — the
    /// panels' draftSignature pattern. centerColumn watches it and
    /// re-drafts, so scrubbing the slider ghosts live.
    private var quickSignature: String { "\(quickCut)|\(quickDistance)" }

    /// Enter quick mode for `face`. Pull = join (material added
    /// outward along the face normal); Press = cut (inward). Starts
    /// at the remembered distance and drafts immediately, so the
    /// ghost is already up when the card appears.
    private func startQuick(cut: Bool, face: PlanarFace) {
        quickFace = face
        quickCut = cut
        quickDistance = min(max(quickPullDistance, 0.5), 100)
        quickSketchID = UUID().uuidString
        refreshQuickDraft()
    }

    /// Draft the quick feature through the SHARED face-pull
    /// builders (mcFacePullSketch + mcFacePullKind — the same code
    /// the Pull Face panel drafts and commits with), injecting the
    /// not-yet-committed sketch into the preview part.
    private func refreshQuickDraft() {
        guard let face = quickFace else { return }
        let sketch = mcFacePullSketch(id: quickSketchID, face: face,
                                      cut: quickCut, name: "Press/Pull (auto)")
        let kind = mcFacePullKind(sketchID: quickSketchID,
                                  distance: quickDistance, cut: quickCut)
        model.draftAppendWithSketches((model.part?.sketches ?? []) + [sketch],
                                      Feature(name: quickCut ? "Press" : "Pull", kind: kind))
    }

    /// Done: commit sketch + feature together (the panel's Apply
    /// does the same two calls), remember the distance for next
    /// time, and leave quick mode. The rebuild that follows clears
    /// the picked face via the baseMeshKey handler.
    private func commitQuick() {
        guard let face = quickFace else { return }
        let sketch = mcFacePullSketch(id: quickSketchID, face: face,
                                      cut: quickCut, name: "Press/Pull (auto)")
        let kind = mcFacePullKind(sketchID: quickSketchID,
                                  distance: quickDistance, cut: quickCut)
        model.addGeneratedSketch(sketch)
        model.appendFeature(name: quickCut ? "Press" : "Pull", kind: kind)
        quickPullDistance = quickDistance
        model.setDraft(nil)
        quickFace = nil
    }

    /// Cancel (or the selection/tool took over): drop the draft,
    /// commit nothing.
    private func cancelQuick() {
        model.setDraft(nil)
        quickFace = nil
    }

    /// Double-tap shortcut: SceneKitView reports a double-tap on the
    /// model separately from single-tap selection. Resolve it like a
    /// tap; ONLY a flat face acts — it is selected and immediately
    /// pulled (join) at the remembered distance. An edge, shaft or
    /// hole wall just keeps its ordinary selection (their own
    /// actions live in the picked bar); empty space never reaches
    /// here. Silent by design, like resolveModelTap.
    private func handleModelDoubleTap(triangleIndex: Int, point: Vec3) {
        guard !sectionOn, activeTool == nil, !pickingFace, !quickActive,
              !model.measureMode else { return }
        model.resolveModelTap(triangleIndex: triangleIndex, point: point)
        guard case .face(_, let face, _) = model.picked else { return }
        quickFace = face
        quickCut = false
        quickDistance = min(max(quickPullDistance, 0.5), 100)
        quickSketchID = UUID().uuidString
        commitQuick()
    }

    /// The quick-mode overlay card: big readout, one wide scrub
    /// slider, Done / Cancel. Floats over the 3D view in the same
    /// style as the action bars while the draft ghost tracks the
    /// slider.
    private var quickPressPullCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: quickCut ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .mcFont(30)
                    .foregroundStyle(accent)
                Text("\(quickCut ? "Press" : "Pull") · \(mcFmt(quickDistance)) mm")
                    .mcFont(30, weight: .bold)
                    .lineLimit(1)
                Spacer()
            }
            Slider(value: $quickDistance, in: 0.5...100, step: 0.5)
            if model.draftFeatures != nil, let err = model.previewError {
                PanelNote(text: "Preview: \(err.userMessage) (\(err.code))", warning: true)
            } else if model.draftFeatures != nil, let note = model.previewNote {
                PanelNote(text: note)
            }
            HStack(spacing: 14) {
                Button("Cancel") { cancelQuick() }
                    .mcFont(21, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
                Button("Done") { commitQuick() }
                    .mcFont(21, weight: .bold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 10).fill(accent))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.80)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.5), lineWidth: 1))
        .padding(10)
    }

    // MARK: Quick measure (always-on, tap two points)

    /// The quick-measure toggle pinned to the viewport's top-right
    /// corner: always visible, whatever else the viewport is doing.
    /// Filled orange while measure mode is armed.
    private var measureToggleButton: some View {
        Button {
            model.measureMode.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "ruler")
                    .mcFont(22, weight: .bold)
                Text("Measure")
                    .mcFont(18, weight: .bold)
            }
            .foregroundStyle(model.measureMode ? Color.black : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(model.measureMode ? accent : Color.black.opacity(0.75)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle quick measure")
    }

    /// The quick-measure readout, pinned top-left of the viewport.
    /// Visible while measuring (as a hint) and for as long as a
    /// measurement exists — it outlives the mode toggle and only
    /// goes away via its ✕ (or a rebuild, like the selection).
    /// "Distance" is the honest point-to-point distance; when a tap
    /// landed on a sharp edge, that edge's length rides along.
    private var measureReadoutCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if model.measurePoints.count == 2 {
                    Text("Distance \(mcFmt(model.measurePoints[0].distance(to: model.measurePoints[1]))) mm")
                        .mcFont(21, weight: .bold)
                        .lineLimit(1)
                } else if model.measurePoints.count == 1 {
                    Text("Tap a second point")
                        .mcFont(19, weight: .semibold)
                        .foregroundStyle(.secondary)
                } else if model.measureMode {
                    Text("Tap two points on the model")
                        .mcFont(19, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                if let edge = model.measureEdgeLength {
                    Text("Edge \(mcFmt(edge)) mm")
                        .mcFont(17, weight: .semibold)
                        .foregroundStyle(accent)
                }
            }
            if !model.measurePoints.isEmpty || model.measureEdgeLength != nil {
                Button {
                    model.clearMeasure()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .mcFont(22)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear measurement")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.5), lineWidth: 1))
    }

    private func actionBarButton(_ label: String, icon: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .mcFont(22)
                Text(label)
                    .mcFont(15, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .frame(minWidth: 74, minHeight: 52)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(_ err: CADError, dismissible: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .mcFont(26)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(err.userMessage)
                    .mcFont(20, weight: .semibold)
                Text(err.code)
                    .mcFont(14, design: .monospaced)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if dismissible {
                Button {
                    model.actionError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .mcFont(22)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.16)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Browser panel resize handle

    private func toggleBrowserPanel() {
        if browserPanelWidth == 0 {
            browserPanelWidth = browserPanelLastWidth >= 40 ? browserPanelLastWidth : 300
        } else {
            browserPanelLastWidth = browserPanelWidth
            browserPanelWidth = 0
        }
    }

    /// The grab strip on the panel's trailing edge: drag to resize
    /// (live, clamped 0–520, releasing under 40 snaps shut), double-tap
    /// to toggle hidden <-> last width. It stays on screen at width 0
    /// so a collapsed panel can be dragged back open.
    private var panelDragHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(browserPanelWidth == 0 ? 0.10 : 0.05))
            VStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 4, height: 4)
                }
            }
            if browserPanelWidth == 0 {
                Image(systemName: "chevron.right")
                    .mcFont(12, weight: .bold)
                    .foregroundStyle(.white.opacity(0.8))
                    .offset(y: 26)
            }
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if panelDragStart == nil { panelDragStart = browserPanelWidth }
                    let start = panelDragStart ?? 300
                    browserPanelWidth = min(520, max(0, start + Double(value.translation.width)))
                }
                .onEnded { _ in
                    if browserPanelWidth < 40 {
                        browserPanelWidth = 0
                    } else {
                        browserPanelLastWidth = browserPanelWidth
                    }
                    panelDragStart = nil
                }
        )
        .onTapGesture(count: 2) { toggleBrowserPanel() }
        .accessibilityLabel(browserPanelWidth == 0 ? "Show browser panel" : "Resize or hide browser panel")
    }

    // MARK: Browser (left): sketches + feature timeline

    /// Width dispatcher: below 250 pt the panel is a slim icon rail;
    /// at/above it, the full browser list at the chosen width.
    private var browserPanel: some View {
        Group {
            if browserPanelWidth < 250 {
                slimBrowserPanel
            } else {
                fullBrowserPanel
            }
        }
    }

    private func slimStatusColor(for feature: Feature) -> Color {
        guard let st = model.status(for: feature.id) else { return .gray }
        if !st.ok { return st.errorCode != nil ? .red : .orange }
        return st.message == "suppressed" ? .gray : .green
    }

    /// Slim rail (panel width < 250): icon + status dot only, no text.
    /// Rows stay fully tappable — sketches navigate, features open
    /// their editor — and every row keeps an accessibility label.
    private var slimBrowserPanel: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let part = model.part {
                    ForEach(part.sketches) { sketch in
                        NavigationLink {
                            SketchEditorView(model: model, sketchID: sketch.id)
                        } label: {
                            Image(systemName: sketch.isDatumPlane ? "square.on.square" : "square.and.pencil")
                                .mcFont(22)
                                .foregroundStyle(sketch.isDatumPlane ? Color.teal : accent)
                                .frame(width: 44, height: 44)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(model.selectedSketchID == sketch.id
                                          ? accent.opacity(0.35)
                                          : Color.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sketch.name)
                    }
                    if !part.sketches.isEmpty && !part.features.isEmpty {
                        Divider()
                            .padding(.horizontal, 10)
                    }
                    ForEach(part.features) { feature in
                        Button {
                            featureToEdit = feature
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: iconName(for: feature.kind))
                                    .mcFont(22)
                                    .foregroundStyle(accent)
                                    .frame(width: 44, height: 44)
                                    .background(RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(0.06)))
                                Circle()
                                    .fill(slimStatusColor(for: feature))
                                    .frame(width: 10, height: 10)
                                    .offset(x: 2, y: -2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(feature.name)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .background(Color.white.opacity(0.02))
    }

    private var fullBrowserPanel: some View {
        List {
            Section("Sketches & datum planes") {
                if let part = model.part {
                    if part.sketches.isEmpty {
                        Text("No sketches yet — use Sketch ▸ New Sketch in the toolbar and pick a plane.")
                            .mcFont(20)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(part.sketches) { sketch in
                        sketchRow(sketch)
                    }
                }
            }

            Section("History — tap a feature to edit it") {
                if let part = model.part, !part.features.isEmpty {
                    ForEach(part.features) { feature in
                        featureRow(feature)
                    }
                } else {
                    Text("No features yet. Pick a tool from the toolbar above — Extrude a sketch, or start with a Primitive.")
                        .mcFont(20)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }

    /// One browser row for a sketch or datum plane. Datums get the ⌖
    /// plane treatment (icon + plane description, no item counts);
    /// every row carries a menu with Redefine Plane and Delete.
    private func sketchRow(_ sketch: Sketch) -> some View {
        HStack(spacing: 10) {
            NavigationLink {
                SketchEditorView(model: model, sketchID: sketch.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: sketch.isDatumPlane ? "square.on.square" : "square.and.pencil")
                        .mcFont(22)
                        .foregroundStyle(sketch.isDatumPlane ? Color.teal : accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sketch.name)
                            .mcFont(20, weight: .semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if sketch.isDatumPlane {
                            Text("Datum plane · \(mcPlaneText(sketch.plane))")
                                .mcFont(17)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Text("\(sketch.entities.count) items · \(sketch.constraints.count) constraints")
                                .mcFont(17)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            Spacer()
            if !sketch.isDatumPlane {
                Button {
                    if model.hiddenSketchIDs.contains(sketch.id) {
                        model.hiddenSketchIDs.remove(sketch.id)
                    } else {
                        model.hiddenSketchIDs.insert(sketch.id)
                        if model.selectedSketchID == sketch.id { model.selectedSketchID = nil }
                    }
                } label: {
                    Image(systemName: model.hiddenSketchIDs.contains(sketch.id) ? "eye.slash" : "eye")
                        .mcFont(20)
                        .foregroundStyle(model.hiddenSketchIDs.contains(sketch.id) ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.hiddenSketchIDs.contains(sketch.id)
                                     ? "Show \(sketch.name) in 3D" : "Hide \(sketch.name) in 3D")
            }
            Menu {
                Button {
                    beginRename(kind: .sketch, id: sketch.id, name: sketch.name)
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button {
                    model.redefineChoice = .none
                    activeTool = .redefinePlane(sketch.id)
                } label: {
                    Label("Redefine plane…", systemImage: "square.on.square.dashed")
                }
                Button(role: .destructive) {
                    model.deleteSketch(sketch.id)
                } label: {
                    Label(sketch.isDatumPlane ? "Delete datum" : "Delete sketch",
                          systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .mcFont(24)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .listRowBackground(model.selectedSketchID == sketch.id ? accent.opacity(0.16) : Color.clear)
    }

    private func featureRow(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(for: feature)
            Image(systemName: iconName(for: feature.kind))
                .mcFont(22)
                .foregroundStyle(accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.name)
                    .mcFont(20, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(kindSummary(feature.kind))
                    .mcFont(17)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let st = model.status(for: feature.id) {
                    if !st.ok, let code = st.errorCode {
                        Text(code)
                            .mcFont(14, design: .monospaced)
                            .foregroundStyle(.red)
                    } else if st.message == "suppressed" {
                        Text("Suppressed")
                            .mcFont(17)
                            .foregroundStyle(.secondary)
                    } else if st.message == "paused" {
                        Text("Paused — an earlier feature failed")
                            .mcFont(17)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { featureToEdit = feature }
            Spacer()
            Button {
                featureToEdit = feature
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .mcFont(24)
            }
            .buttonStyle(.plain)
            Button(feature.suppressed ? "Show" : "Hide") {
                model.setSuppressed(feature.id, !feature.suppressed)
            }
            .mcFont(16, weight: .semibold)
            Button(role: .destructive) {
                model.deleteFeature(feature.id)
            } label: {
                Image(systemName: "trash")
                    .mcFont(20)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                beginRename(kind: .feature, id: feature.id, name: feature.name)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }
    }

    @ViewBuilder
    private func statusIcon(for feature: Feature) -> some View {
        Group {
            if let st = model.status(for: feature.id) {
                if st.ok {
                    if st.message == "suppressed" {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.gray)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else if st.errorCode != nil {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.gray)
            }
        }
        .mcFont(24)
    }

    /// When the feature being edited is a fillet failing with FT408,
    /// the kernel's largest feasible radius — passed to the sheet so it
    /// can offer it as a one-tap fix.
    private func filletMaxFeasible(for feature: Feature) -> Double? {
        guard case .fillet = feature.kind,
              model.status(for: feature.id)?.errorCode == "MCAD-FT408",
              let err = model.rebuild?.firstError,
              case .filletRadiusTooLarge(_, let maxFeasible) = err
        else { return nil }
        return maxFeasible
    }

    private func primitiveLabel(_ kind: PrimitiveKind) -> String {
        switch kind {
        case .box: return "Box…"
        case .cylinder: return "Cylinder…"
        case .sphere: return "Sphere…"
        case .cone: return "Cone…"
        case .torus: return "Torus…"
        }
    }

    func iconName(for kind: FeatureKind) -> String {
        switch kind {
        case .pad: return "square.stack.3d.up"
        case .pocket: return "arrow.down.square"
        case .revolve: return "rotate.3d"
        case .primitive(let k, _):
            switch k {
            case .box: return "cube.fill"
            case .cylinder: return "cylinder.fill"
            case .sphere: return "circle.fill"
            case .cone: return "triangle.fill"
            case .torus: return "lifepreserver"
            }
        case .threadShaft: return "lines.measurement.horizontal"
        case .linearPattern: return "square.grid.2x2"
        case .hole: return "circle.circle"
        case .mirror: return "flip.horizontal"
        case .fillet: return "capsule"
        case .chamfer: return "octagon"
        case .shell: return "cube.transparent"
        case .extrude: return "rectangle.expand.vertical"
        case .loft: return "square.2.layers.3d"
        case .sweep: return "lasso"
        case .extrude2: return "rectangle.expand.vertical"
        case .chamfer2: return "octagon"
        case .coil: return "tornado"
        case .pipe: return "waveform.path"
        case .rib: return "square.split.2x1"
        case .draftBody: return "pyramid"
        case .scaleBody: return "arrow.up.and.down.and.arrow.left.and.right"
        case .moveBody: return "move.3d"
        case .splitBody: return "rectangle.split.2x1"
        case .circularPattern: return "arrow.triangle.2.circlepath"
        case .filletEdges: return "capsule"
        case .chamferEdges: return "octagon"
        case .threadOnShaft: return "lines.measurement.horizontal"
        case .booleanCutPlaceholder: return "scissors"
        }
    }

    private func kindSummary(_ kind: FeatureKind) -> String {
        switch kind {
        case .pad(_, let len):
            return "Pad · \(mcFmt(len)) mm"
        case .pocket(_, let depth):
            return "Pocket · \(mcFmt(depth)) mm deep"
        case .revolve(_, _, let angle):
            return "Revolve · \(mcFmt(angle))°"
        case .primitive(let k, let p):
            switch k {
            case .box:
                return "Box · \(mcFmt(p["width"] ?? 0))×\(mcFmt(p["depth"] ?? 0))×\(mcFmt(p["height"] ?? 0))"
            case .cylinder:
                return "Cylinder · Ø\(mcFmt(p["diameter"] ?? 0)) × \(mcFmt(p["height"] ?? 0))"
            case .sphere:
                return "Sphere · Ø\(mcFmt(p["diameter"] ?? 0))"
            case .cone:
                return "Cone · Ø\(mcFmt(p["diameter"] ?? 0)) × \(mcFmt(p["height"] ?? 0))"
            case .torus:
                return "Torus · R\(mcFmt(p["ringRadius"] ?? 0)) × r\(mcFmt(p["tubeRadius"] ?? 0))"
            }
        case .threadShaft(let s):
            return "Thread · Ø\(mcFmt(s.majorDiameter)) × \(mcFmt(s.pitch)) pitch · \(s.starts) start\(s.starts == 1 ? "" : "s")"
        case .linearPattern(let count, let spacing):
            return "Pattern · ×\(count) step (\(mcFmt(spacing.x)), \(mcFmt(spacing.y)), \(mcFmt(spacing.z)))"
        case .hole(_, let diameter, let depth, let hk):
            let depthText = depth <= 0 ? "through" : "\(mcFmt(depth)) mm"
            switch hk {
            case .simple: return "Hole · Ø\(mcFmt(diameter)) · \(depthText)"
            case .counterbore(let cbD, let cbDepth):
                return "Hole · Ø\(mcFmt(diameter)) + bore Ø\(mcFmt(cbD))×\(mcFmt(cbDepth)) · \(depthText)"
            case .countersink(let angle):
                return "Hole · Ø\(mcFmt(diameter)) + sink \(mcFmt(angle))° · \(depthText)"
            }
        case .mirror(let plane):
            return "Mirror · \(plane.displayName)"
        case .fillet(let radius):
            return "Fillet · r \(mcFmt(radius))"
        case .chamfer(let distance):
            return "Chamfer · \(mcFmt(distance)) mm"
        case .shell(let thickness):
            return "Shell · wall \(mcFmt(thickness)) mm"
        case .extrude(_, let distance, let taper, let mode):
            var text = "Extrude · \(mcFmt(distance)) mm"
            switch mode {
            case .one: break
            case .symmetric: text += " · symmetric"
            case .twoSided(let second): text += " + \(mcFmt(second)) mm back"
            }
            if taper != 0 { text += " · taper \(mcFmt(taper))°" }
            return text
        case .loft:
            return "Loft · two profiles"
        case .sweep:
            return "Sweep · profile along path"
        case .extrude2(_, let distance, let taper, let mode, let op, let end):
            let opText: String
            switch op {
            case .join: opText = "join"
            case .cut: opText = "cut"
            case .intersect: opText = "intersect"
            case .newBody: opText = "new body"
            }
            var text = "Extrude · \(opText)"
            switch end {
            case .dimension: text += " · \(mcFmt(distance)) mm"
            case .throughAll: text += " · through all"
            case .upToFace(let i): text += " · up to face \(i + 1)"
            }
            switch mode {
            case .one: break
            case .symmetric: text += " · symmetric"
            case .twoSided(let second): text += " + \(mcFmt(second)) mm back"
            }
            if taper != 0 { text += " · taper \(mcFmt(taper))°" }
            return text
        case .chamfer2(let mode):
            switch mode {
            case .equal(let d):
                return "Chamfer · \(mcFmt(d)) mm both sides"
            case .twoDistances(let a, let b):
                return "Chamfer · \(mcFmt(a)) × \(mcFmt(b)) mm"
            case .distanceAngle(let d, let deg):
                return "Chamfer · \(mcFmt(d)) mm at \(mcFmt(deg))°"
            }
        case .coil(let radius, let pitch, let turns, let wire):
            return "Coil · R\(mcFmt(radius)) · pitch \(mcFmt(pitch)) · \(mcFmt(turns)) turns · wire r\(mcFmt(wire))"
        case .pipe(_, let radius):
            return "Pipe · r \(mcFmt(radius)) along path"
        case .rib(_, let thickness, let depth):
            return "Rib · \(mcFmt(thickness)) thick · \(mcFmt(depth)) deep"
        case .draftBody(let angle, let axis):
            return "Draft · \(mcFmt(angle))° · pull \(axis == 0 ? "X" : (axis == 1 ? "Y" : "Z"))"
        case .scaleBody(let f):
            if f.x == f.y && f.y == f.z { return "Scale · ×\(mcFmt(f.x))" }
            return "Scale · ×(\(mcFmt(f.x)), \(mcFmt(f.y)), \(mcFmt(f.z)))"
        case .moveBody(let t, let axis, let degrees):
            var text = "Move · (\(mcFmt(t.x)), \(mcFmt(t.y)), \(mcFmt(t.z)))"
            if degrees != 0 {
                text += " · rotate \(mcFmt(degrees))° around \(axis == 0 ? "X" : (axis == 1 ? "Y" : "Z"))"
            }
            return text
        case .splitBody(let axis, let offset):
            return "Split · \(axis == 0 ? "X" : (axis == 1 ? "Y" : "Z")) at \(mcFmt(offset)) mm"
        case .circularPattern(let count, let axis, let total):
            return "Circular pattern · ×\(count) around \(axis == 0 ? "X" : (axis == 1 ? "Y" : "Z")) over \(mcFmt(total))°"
        case .filletEdges(let radius, let midpoints):
            return "Fillet · r \(mcFmt(radius)) · \(midpoints.count) picked edge\(midpoints.count == 1 ? "" : "s")"
        case .chamferEdges(let distance, let midpoints):
            return "Chamfer · \(mcFmt(distance)) mm · \(midpoints.count) picked edge\(midpoints.count == 1 ? "" : "s")"
        case .threadOnShaft(let s, _, _):
            return "Thread on shaft · Ø\(mcFmt(s.majorDiameter)) × \(mcFmt(s.pitch)) pitch · \(mcFmt(s.length)) mm long"
        case .booleanCutPlaceholder:
            return "Boolean cut"
        }
    }
}
