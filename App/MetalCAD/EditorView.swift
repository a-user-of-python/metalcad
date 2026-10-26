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

/// What part of an entity a drag is moving (shared by the
/// in-place sketch engine's drag state).
enum DragRole {
    case point, lineA, lineB, center
}

/// An in-flight drag's target: which entity, which of its points,
/// and where that point started.
struct DragTarget {
    var entityID: Int
    var role: DragRole
    var original: Vec2
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

/// Tools of the in-place sketch session (drawing directly in the
/// 3D viewport on the active sketch's plane). Mirrors the creation
/// subset of the old 2D editor's tool enum (deleted in v1.12 with
/// the rest of that editor) — that enum also carried spline/
/// ellipse/polygon/slot/text/trim, which the in-place session
/// does not offer (see the wave-2 report's not-ported list).
enum InPlaceSketchTool: String, CaseIterable {
    case select, point, line, rectangle, circle, arc
    var displayName: String {
        switch self {
        case .select: return "Select"
        case .point: return "Point"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .circle: return "Circle"
        case .arc: return "Arc"
        }
    }
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
    /// True while the New Sketch panel is up choosing a plane: the
    /// 3D view glows the three base planes in their axis colors
    /// (YZ red, XZ green, XY blue — same colors as the panel's
    /// plane cards). Set by the panel on appear/disappear and
    /// force-cleared whenever the tool panel closes.
    @Published var choosingSketchPlane: Bool = false
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
        if activeSketchID == id { endSketchInPlace() }
        mutate { $0.sketches.removeAll { $0.id == id } }
    }

    // MARK: In-place sketching (drawing in the 3D viewport)

    /// The sketch being drawn on IN the 3D viewport, or nil when no
    /// in-place session is live. A String like every other sketch id
    /// in the app (`Sketch.id` is a UUID string; entity ids are the
    /// kit's Ints — the in-place API follows those existing types).
    @Published private(set) var activeSketchID: String?
    /// Live working copy of the active sketch. Pointer drags mutate
    /// ONLY this copy (no document rebuild per move); a commit —
    /// pointer-up after a create or a drag — writes it back through
    /// `replaceSketch`, the same commit path the 2D editor's
    /// `changed()` uses. SceneKitView renders this copy in place of
    /// the committed sketch so drags show live.
    @Published private(set) var activeSketch: Sketch?
    /// The in-place tool the next pointer stroke uses.
    @Published var inPlaceTool: InPlaceSketchTool = .select
    /// Entities selected inside the active sketch (kit entity ids).
    @Published var selectedSketchEntityIDs: Set<Int> = []
    /// Not-yet-committed entities of the stroke in flight (the
    /// rubber band), drawn dashed by the viewport. Ids are negative
    /// placeholders — preview entities never enter a real sketch.
    @Published var sketchPreview: [SketchEntity] = []
    /// Snapped pointer position on the active plane (pencil hover,
    /// and the live point while a stroke is down) — the viewport
    /// draws its marker ring here.
    @Published var sketchHoverPoint: Vec2?
    /// Live size readout of the stroke in flight ("128.4 mm",
    /// "120 × 80 mm", "Ø 48.0 mm", "R 30.0 mm"), nil between strokes.
    @Published var sketchDragReadout: String?
    /// Degrees of freedom of the active sketch, refreshed on begin
    /// and on every commit so constraint state stays visible live.
    @Published var activeSketchDOF: Int = 0
    /// Grid snap step in mm for in-place drawing — 1 mm, the same
    /// grid the 2D editor snaps to.
    @Published var sketchSnapStep: Double = 1.0
    /// Screen-derived snap/pick tolerance in mm at the sketch plane.
    /// SceneKitView refreshes it from the camera distance on every
    /// update while a session is live (≈14 screen points); the 2.5 mm
    /// default covers the frames before the first refresh.
    var sketchSnapToleranceMM: Double = 2.5

    /// True while an in-place sketch session is live.
    var isSketchingInPlace: Bool { activeSketchID != nil }

    // Stroke state (session-private; a stroke is down→drag→up).
    private var sketchDragStart: Vec2?
    private var sketchDragTarget: DragTarget?
    private var sketchDragEntity: Int?
    private var sketchDragBase: Sketch?
    private var sketchDragMoved = false
    private var sketchArcTangent: Vec2?

    private func resetSketchDrag() {
        sketchDragStart = nil
        sketchDragTarget = nil
        sketchDragEntity = nil
        sketchDragBase = nil
        sketchDragMoved = false
        sketchArcTangent = nil
    }

    /// Begin drawing on an existing sketch in the viewport. The
    /// sketch also becomes the 3D selection so the browser row and
    /// overlay agree with the session.
    func beginSketchInPlace(_ id: String) {
        guard let sk = sketch(withID: id), !sk.isDatumPlane else { return }
        activeSketchID = id
        activeSketch = sk
        selectedSketchID = id
        clearPicked()
        selectedSketchEntityIDs = []
        sketchPreview = []
        sketchHoverPoint = nil
        sketchDragReadout = nil
        resetSketchDrag()
        activeSketchDOF = SketchSolver.degreesOfFreedom(sk)
        MCLog.shared.info(.sketch, "in-place sketch session began",
                          context: ["id": id, "name": sk.name])
    }

    /// End the in-place session. Uncommitted stroke state is dropped
    /// (commits happen on pointer-up, so nothing else can be lost).
    func endSketchInPlace() {
        guard activeSketchID != nil else { return }
        activeSketchID = nil
        activeSketch = nil
        selectedSketchEntityIDs = []
        sketchPreview = []
        sketchHoverPoint = nil
        sketchDragReadout = nil
        resetSketchDrag()
        MCLog.shared.info(.sketch, "in-place sketch session ended")
    }

    /// Sean's open-straight-into-a-sketch rule: a brand-new document
    /// (no sketches, no features) gets a sketch on the XY base plane
    /// — created through the same `addSketch` path the New Sketch
    /// panel uses, with the same "Sketch N" naming — and the
    /// in-place session begins on it immediately. Called from the
    /// editor's onAppear; a no-op for any document that already has
    /// content (or a live session).
    func autoStartSketchIfEmpty() {
        guard activeSketchID == nil, let p = part,
              p.sketches.isEmpty, p.features.isEmpty else { return }
        let name = "Sketch \((part?.sketches.count ?? 0) + 1)"
        let sk = addSketch(plane: .xy, name: name)
        beginSketchInPlace(sk.id)
    }

    /// Write the working copy back to the document (the document-
    /// dirty path: mutate → rebuild). With `solveFirst`, a solver
    /// pass runs on a copy first and the solved geometry is what
    /// commits; a failed solve never loses the edit — the unsolved
    /// working copy commits instead (heavy sketches, >250 entities,
    /// skip the solver exactly like the 2D editor).
    private func commitActiveSketch(solveFirst: Bool = false) {
        guard var working = activeSketch else { return }
        if solveFirst, working.entities.count <= 250 {
            var copy = working
            if (try? SketchSolver.solve(&copy)) != nil { working = copy }
        }
        activeSketch = working
        replaceSketch(working)
        activeSketchDOF = SketchSolver.degreesOfFreedom(working)
    }

    /// Snap a raw plane point the way the 2D editor snaps: existing
    /// endpoints (priority 0), centers (1) and midpoints (2) inside
    /// the tolerance win over the grid (3), which rounds to
    /// `sketchSnapStep`. A dragged point never snaps onto its own
    /// start position (`excluding`).
    private func snappedSketchPoint(_ raw: Vec2, excluding: Vec2? = nil) -> Vec2 {
        guard let sk = activeSketch else { return raw }
        let threshold = max(sketchSnapToleranceMM, sketchSnapStep)
        var candidates: [(point: Vec2, priority: Int)] = []
        for e in sk.entities {
            switch e {
            case .point(_, let at, _):
                candidates.append((at, 0))
            case .line(_, let a, let b, _):
                candidates.append((a, 0))
                candidates.append((b, 0))
                candidates.append(((a + b) * 0.5, 2))
            case .circle(_, let c, _, _):
                candidates.append((c, 1))
            case .arc(let id, let c, _, _, _, _):
                candidates.append((c, 1))
                if let ent = sk.entity(id) {
                    if let s = ent.resolve(.start) { candidates.append((s, 0)) }
                    if let en = ent.resolve(.end) { candidates.append((en, 0)) }
                }
            }
        }
        if let excluding {
            candidates.removeAll { $0.point.distance(to: excluding) < 1e-9 }
        }
        let step = max(sketchSnapStep, 0.0001)
        candidates.append((Vec2((raw.x / step).rounded() * step,
                                (raw.y / step).rounded() * step), 3))
        var best: (point: Vec2, priority: Int, dist: Double)?
        for c in candidates {
            let d = c.point.distance(to: raw)
            guard d <= threshold else { continue }
            if let b = best {
                if c.priority < b.priority ||
                    (c.priority == b.priority && d < b.dist) {
                    best = (c.point, c.priority, d)
                }
            } else {
                best = (c.point, c.priority, d)
            }
        }
        return best?.point ?? raw
    }

    // MARK: In-place pointer API (plane-space points, snapped inside)

    /// Pointer pressed on the active sketch's plane.
    func sketchPointerDown(at raw: Vec2) {
        guard var working = activeSketch else { return }
        let p = snappedSketchPoint(raw)
        sketchHoverPoint = p
        switch inPlaceTool {
        case .point:
            working.addPoint(p)
            activeSketch = working
            commitActiveSketch()
        case .line, .rectangle, .circle, .arc:
            sketchDragStart = p
            sketchArcTangent = nil
            sketchPreview = []
            sketchDragReadout = nil
        case .select:
            beginSelectDrag(at: raw, snapped: p, working: working)
        }
    }

    /// Pointer moved with the stroke down.
    func sketchPointerDragged(to raw: Vec2) {
        guard activeSketch != nil else { return }
        let p = snappedSketchPoint(raw, excluding: sketchDragTarget?.original)
        sketchHoverPoint = p
        switch inPlaceTool {
        case .line:
            guard let s = sketchDragStart else { return }
            sketchPreview = [.line(id: -1, a: s, b: p, construction: false)]
            sketchDragReadout = String(format: "%.1f mm", s.distance(to: p))
        case .rectangle:
            guard let s = sketchDragStart else { return }
            let corners = [s, Vec2(p.x, s.y), p, Vec2(s.x, p.y)]
            sketchPreview = (0..<4).map { i in
                SketchEntity.line(id: -1 - i, a: corners[i],
                                  b: corners[(i + 1) % 4], construction: false)
            }
            sketchDragReadout = "\(mcFmt(abs(p.x - s.x))) × \(mcFmt(abs(p.y - s.y))) mm"
        case .circle:
            guard let s = sketchDragStart else { return }
            let r = s.distance(to: p)
            sketchPreview = [.circle(id: -1, center: s, radius: r, construction: false)]
            sketchDragReadout = String(format: "Ø %.1f mm", 2 * r)
        case .arc:
            guard let s = sketchDragStart else { return }
            // The arc's tangent at its start is the direction the
            // drag FIRST pulls in (captured once the pointer has
            // moved 2 mm from the start); the arc then runs from the
            // start through the current point with that tangent, so
            // pulling sideways bulges it out live.
            if sketchArcTangent == nil, s.distance(to: p) > 2 {
                sketchArcTangent = (p - s).normalized
            }
            if let t = sketchArcTangent,
               let arc = Self.tangentArc(start: s, tangent: t, through: p) {
                sketchPreview = [.arc(id: -1, center: arc.center, radius: arc.radius,
                                      startAngle: arc.startAngle, endAngle: arc.endAngle,
                                      construction: false)]
                sketchDragReadout = String(format: "R %.1f mm", arc.radius)
            } else {
                sketchPreview = []
                sketchDragReadout = nil
            }
        case .select:
            updateSelectDrag(to: p)
        case .point:
            break
        }
    }

    /// Pointer released: the stroke commits.
    func sketchPointerUp(at raw: Vec2) {
        guard var working = activeSketch else { return }
        let p = snappedSketchPoint(raw, excluding: sketchDragTarget?.original)
        switch inPlaceTool {
        case .line:
            if let s = sketchDragStart, s.distance(to: p) > 1e-9 {
                working.addLine(s, p)
                activeSketch = working
                commitActiveSketch()
            }
        case .rectangle:
            if let s = sketchDragStart,
               abs(s.x - p.x) > 1e-9, abs(s.y - p.y) > 1e-9 {
                working.addRectangle(from: s, to: p)
                activeSketch = working
                commitActiveSketch()
            }
        case .circle:
            if let s = sketchDragStart {
                let r = s.distance(to: p)
                if r > 0.1 {
                    working.addCircle(s, r)
                    activeSketch = working
                    commitActiveSketch()
                }
            }
        case .arc:
            if let s = sketchDragStart, let t = sketchArcTangent,
               let arc = Self.tangentArc(start: s, tangent: t, through: p) {
                let id = working.allocateID()
                working.add(.arc(id: id, center: arc.center, radius: arc.radius,
                                 startAngle: arc.startAngle, endAngle: arc.endAngle,
                                 construction: false))
                activeSketch = working
                commitActiveSketch()
            }
        case .select:
            if sketchDragMoved { commitActiveSketch(solveFirst: true) }
        case .point:
            break
        }
        sketchPreview = []
        sketchDragReadout = nil
        resetSketchDrag()
    }

    /// Abort the stroke in flight (a second finger landed and the
    /// orbit is taking over, or the system cancelled the touch): a
    /// select-drag rolls back to its drag-start geometry; create
    /// strokes have committed nothing yet, so only their preview and
    /// readout clear.
    func cancelSketchStroke() {
        if inPlaceTool == .select, let base = sketchDragBase {
            activeSketch = base
        }
        sketchPreview = []
        sketchDragReadout = nil
        resetSketchDrag()
    }

    /// Pencil hover (or any pointer move without a stroke): track
    /// the snapped point for the viewport's marker ring.
    func sketchHover(at raw: Vec2) {
        guard activeSketch != nil else { return }
        sketchHoverPoint = snappedSketchPoint(raw)
    }

    /// Hover ended: clear the marker.
    func endSketchHover() { sketchHoverPoint = nil }

    // MARK: In-place selection drag

    /// Select-mode press: a defining point near the touch (endpoint /
    /// center) starts a point drag; otherwise the nearest entity
    /// body within tolerance is selected and starts a whole-entity
    /// translate; empty space clears the selection.
    private func beginSelectDrag(at raw: Vec2, snapped: Vec2, working: Sketch) {
        let tol = max(sketchSnapToleranceMM, 1.5)
        var bestTarget: DragTarget?
        var bestDist = Double.greatestFiniteMagnitude
        for cand in Self.draggablePoints(of: working) {
            let d = cand.point.distance(to: raw)
            if d < bestDist {
                bestDist = d
                bestTarget = DragTarget(entityID: cand.id, role: cand.role,
                                        original: cand.point)
            }
        }
        if let target = bestTarget, bestDist <= tol {
            selectedSketchEntityIDs = [target.entityID]
            sketchDragTarget = target
            sketchDragBase = working
            sketchDragMoved = false
            return
        }
        var hitID: Int?
        var hitDist = Double.greatestFiniteMagnitude
        for e in working.entities {
            let d = Self.sketchEntityDistance(e, to: raw)
            if d < hitDist { hitDist = d; hitID = e.id }
        }
        if let hitID, hitDist <= max(tol, 3.5) {
            selectedSketchEntityIDs = [hitID]
            sketchDragEntity = hitID
            sketchDragBase = working
            sketchDragStart = snapped
            sketchDragMoved = false
        } else {
            selectedSketchEntityIDs = []
            sketchDragBase = nil
        }
    }

    /// Live half of a select drag: moves land on the working copy
    /// only (recomputed from the drag-start snapshot each move, so
    /// the motion is exactly the pointer delta); the solve + commit
    /// happen on pointer-up.
    private func updateSelectDrag(to p: Vec2) {
        guard let base = sketchDragBase else { return }
        var working = base
        if let target = sketchDragTarget {
            Self.moveDraggedPoint(&working, target: target, to: p)
            sketchDragMoved = true
            activeSketch = working
        } else if let eid = sketchDragEntity, let start = sketchDragStart {
            let delta = p - start
            if delta.length > 1e-12,
               let idx = working.entities.firstIndex(where: { $0.id == eid }) {
                working.entities[idx] = Self.translated(working.entities[idx], by: delta)
                sketchDragMoved = true
                activeSketch = working
            }
        }
    }

    /// The points a drag can grab — a port of the 2D editor's
    /// `draggablePoints` (endpoints for lines, centers for circles
    /// and arcs, the point itself for points).
    static func draggablePoints(of sketch: Sketch)
        -> [(id: Int, role: DragRole, point: Vec2)] {
        var out: [(Int, DragRole, Vec2)] = []
        for e in sketch.entities {
            switch e {
            case .point(let id, let at, _):
                out.append((id, .point, at))
            case .line(let id, let a, let b, _):
                out.append((id, .lineA, a))
                out.append((id, .lineB, b))
            case .circle(let id, let c, _, _):
                out.append((id, .center, c))
            case .arc(let id, let c, _, _, _, _):
                out.append((id, .center, c))
            }
        }
        return out
    }

    /// Move a grabbed defining point — a port of the 2D editor's
    /// `moveDraggedPoint`, including its whole-line fallback for the
    /// unused role mapping.
    static func moveDraggedPoint(_ sketch: inout Sketch, target: DragTarget, to newPos: Vec2) {
        guard let idx = sketch.entities.firstIndex(where: { $0.id == target.entityID })
        else { return }
        let e = sketch.entities[idx]
        switch (e, target.role) {
        case (.point(let id, _, let cons), .point):
            sketch.entities[idx] = .point(id: id, at: newPos, construction: cons)
        case (.line(let id, let a, let b, let cons), .lineA):
            sketch.entities[idx] = .line(id: id, a: newPos, b: b, construction: cons)
        case (.line(let id, let a, let b, let cons), .lineB):
            sketch.entities[idx] = .line(id: id, a: a, b: newPos, construction: cons)
        case (.line(let id, let a, let b, let cons), .point):
            let da = a.distance(to: target.original), db = b.distance(to: target.original)
            if da <= db {
                sketch.entities[idx] = .line(id: id, a: newPos, b: b, construction: cons)
            } else {
                sketch.entities[idx] = .line(id: id, a: a, b: newPos, construction: cons)
            }
        case (.circle(let id, _, let r, let cons), .center):
            sketch.entities[idx] = .circle(id: id, center: newPos, radius: r, construction: cons)
        case (.arc(let id, _, let r, let a0, let a1, let cons), .center):
            sketch.entities[idx] = .arc(id: id, center: newPos, radius: r,
                                         startAngle: a0, endAngle: a1, construction: cons)
        default:
            break
        }
    }

    /// Translate an entity by moving its defining points — a port of
    /// the 2D editor's `translatedEntity`.
    static func translated(_ e: SketchEntity, by d: Vec2) -> SketchEntity {
        switch e {
        case .point(let id, let at, let c):
            return .point(id: id, at: at + d, construction: c)
        case .line(let id, let a, let b, let c):
            return .line(id: id, a: a + d, b: b + d, construction: c)
        case .circle(let id, let ctr, let r, let c):
            return .circle(id: id, center: ctr + d, radius: r, construction: c)
        case .arc(let id, let ctr, let r, let a0, let a1, let c):
            return .arc(id: id, center: ctr + d, radius: r,
                        startAngle: a0, endAngle: a1, construction: c)
        }
    }

    /// Distance from a plane point to an entity (picking): exact for
    /// points, lines and circles; arcs measure against their
    /// flattened polyline, like the viewport's sketch picking.
    static func sketchEntityDistance(_ e: SketchEntity, to p: Vec2) -> Double {
        switch e {
        case .point(_, let at, _):
            return p.distance(to: at)
        case .line(_, let a, let b, _):
            return distanceToSegment(p, a, b)
        case .circle(_, let c, let r, _):
            return abs(p.distance(to: c) - r)
        case .arc:
            let pts = e.polyline()
            guard let first = pts.first else { return .greatestFiniteMagnitude }
            guard pts.count > 1 else { return p.distance(to: first) }
            var best = Double.greatestFiniteMagnitude
            for i in 0..<(pts.count - 1) {
                best = min(best, distanceToSegment(p, pts[i], pts[i + 1]))
            }
            return best
        }
    }

    static func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        guard len2 > 1e-12 else { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(ab) / len2))
        return p.distance(to: a + ab * t)
    }

    /// The drag-arc construction: the arc starts at `start`, leaves
    /// it along `tangent` (the direction the drag first pulled in),
    /// and passes through the current drag point `p`. The center
    /// sits on the tangent's perpendicular through the start, at the
    /// λ that puts `p` on the circle: λ = |p−s|² / (2·n̂·(p−s)).
    /// Nil when the drag runs (near-)parallel to the tangent — the
    /// "arc" would be a straight line with an astronomical radius.
    /// The kit arc sweeps CCW from startAngle to endAngle; when the
    /// CCW sweep would leave the start against the pull direction,
    /// the endpoints are stored swapped (the identical point set —
    /// `resolve(.start)` then reports the drag point, documented
    /// here rather than hidden).
    static func tangentArc(start s: Vec2, tangent t: Vec2, through p: Vec2)
        -> (center: Vec2, radius: Double, startAngle: Double, endAngle: Double)? {
        let d = p - s
        guard d.length > 1e-6 else { return nil }
        let n = t.perpendicular
        let denom = n.dot(d)
        guard abs(denom) > 0.02 * d.length else { return nil }
        let lambda = d.dot(d) / (2 * denom)
        let r = abs(lambda)
        guard r > 0.1, r < 100_000 else { return nil }
        let c = s + n * lambda
        let aS = atan2(s.y - c.y, s.x - c.x)
        let aE = atan2(p.y - c.y, p.x - c.x)
        // Direction the CCW sweep leaves the start point: the radius
        // direction rotated +90°. If that fights the pull, the arc
        // the user pulled is the complementary sweep — store the
        // endpoints swapped so the CCW arc IS the pulled one.
        let radial = (s - c) * (1 / r)
        let ccwLeave = Vec2(-radial.y, radial.x)
        if ccwLeave.dot(t) >= 0 {
            return (c, r, aS, aE)
        }
        return (c, r, aE, aS)
    }

    // MARK: In-place measurements & direct edits (fix a mistake in place)

    /// Readouts for the current in-place selection — one line per
    /// fact, ready for the layout wave to list verbatim: a point's
    /// coordinates, a line's length, a circle's radius + diameter,
    /// an arc's radius + sweep. Four selected lines whose endpoints
    /// land on two x and two y values (an axis-aligned rectangle)
    /// also report their width × height ahead of the per-line rows.
    var selectedSketchMeasurements: [String] {
        guard let sk = activeSketch else { return [] }
        let sel = sk.entities.filter { selectedSketchEntityIDs.contains($0.id) }
        guard !sel.isEmpty else { return [] }
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }
        var out: [String] = []
        if sel.count == 4 {
            var lines: [(a: Vec2, b: Vec2)] = []
            var isRect = true
            for e in sel {
                if case .line(_, let a, let b, _) = e { lines.append((a, b)) }
                else { isRect = false }
            }
            if isRect {
                var xs = Set<Double>()
                var ys = Set<Double>()
                for l in lines {
                    xs.insert((l.a.x * 1e6).rounded() / 1e6)
                    xs.insert((l.b.x * 1e6).rounded() / 1e6)
                    ys.insert((l.a.y * 1e6).rounded() / 1e6)
                    ys.insert((l.b.y * 1e6).rounded() / 1e6)
                }
                let axisAligned = lines.allSatisfy {
                    abs($0.a.x - $0.b.x) < 1e-6 || abs($0.a.y - $0.b.y) < 1e-6
                }
                let w = (xs.max() ?? 0) - (xs.min() ?? 0)
                let h = (ys.max() ?? 0) - (ys.min() ?? 0)
                if xs.count == 2, ys.count == 2, axisAligned, w > 0, h > 0 {
                    out.append("Rectangle \(mcFmt(w)) × \(mcFmt(h)) mm")
                }
            }
        }
        for e in sel {
            switch e {
            case .point(_, let at, _):
                out.append("Point (\(mcFmt(at.x)), \(mcFmt(at.y)))")
            case .line(_, let a, let b, _):
                out.append("Length \(f1(a.distance(to: b))) mm")
            case .circle(_, _, let r, _):
                out.append("Radius \(f1(r)) mm · Ø \(f1(2 * r)) mm")
            case .arc(_, _, let r, let a0, let a1, _):
                var sweep = a1 - a0
                while sweep < 0 { sweep += 2 * Double.pi }
                out.append("Radius \(f1(r)) mm · Sweep \(f1(sweep * 180 / Double.pi))°")
            }
        }
        return out
    }

    /// Fix the selected circle's radius in place. Exactly one circle
    /// must be selected. When the circle already carries a driving
    /// radius/diameter constraint, the constraint's value is updated
    /// and the solver places the geometry — the 2D inspector's
    /// parametric path; otherwise the geometry is set directly.
    /// Either way the edit commits through a solve, and a failed
    /// solve never loses the edit (see `commitActiveSketch`).
    @discardableResult
    func setSelectedCircleRadius(_ mm: Double) -> Bool {
        guard var working = activeSketch, mm > 0,
              selectedSketchEntityIDs.count == 1,
              let id = selectedSketchEntityIDs.first,
              let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .circle(let eid, let center, _, let cons) = working.entities[idx]
        else { return false }
        if let ci = working.constraints.firstIndex(where: { c in
            switch c {
            case .radius(let e, _), .diameter(let e, _): return e == eid
            default: return false
            }
        }) {
            switch working.constraints[ci] {
            case .radius(let e, _):
                working.constraints[ci] = .radius(entity: e, value: mm)
            case .diameter(let e, _):
                working.constraints[ci] = .diameter(entity: e, value: 2 * mm)
            default: break
            }
        } else {
            working.entities[idx] = .circle(id: eid, center: center,
                                             radius: mm, construction: cons)
        }
        activeSketch = working
        commitActiveSketch(solveFirst: true)
        return true
    }

    /// Fix the selected line's length in place: the line grows or
    /// shrinks FROM its first endpoint, along its own direction.
    /// Exactly one line must be selected. An existing driving
    /// distance constraint between the line's own endpoints is
    /// updated instead of moving geometry blind (same parametric
    /// rule as `setSelectedCircleRadius`).
    @discardableResult
    func setSelectedLineLength(_ mm: Double) -> Bool {
        guard var working = activeSketch, mm > 0,
              selectedSketchEntityIDs.count == 1,
              let id = selectedSketchEntityIDs.first,
              let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .line(let eid, let a, let b, let cons) = working.entities[idx]
        else { return false }
        if let ci = working.constraints.firstIndex(where: { c in
            guard case .distancePoints(let ea, let ka, let eb, let kb, _) = c
            else { return false }
            return ea == eid && eb == eid &&
                ((ka == .start && kb == .end) || (ka == .end && kb == .start))
        }) {
            if case .distancePoints(let ea, let ka, let eb, let kb, _) =
                working.constraints[ci] {
                working.constraints[ci] = .distancePoints(
                    entityA: ea, kindA: ka, entityB: eb, kindB: kb, value: mm)
            }
        } else {
            let dir = b - a
            guard dir.length > 1e-12 else { return false }
            working.entities[idx] = .line(id: eid, a: a,
                                          b: a + dir.normalized * mm,
                                          construction: cons)
        }
        activeSketch = working
        commitActiveSketch(solveFirst: true)
        return true
    }

    // MARK: In-place constraints & entity edits (the sketch rail)

    /// The one selected line's id when the in-place selection is
    /// exactly one line — the rail's Horizontal/Vertical target.
    var selectedSketchLineID: Int? {
        guard let sk = activeSketch, selectedSketchEntityIDs.count == 1,
              let id = selectedSketchEntityIDs.first,
              let e = sk.entity(id), case .line = e else { return nil }
        return id
    }

    /// Port of the 2D editor's line-inspector buttons: pin the
    /// selected line horizontal / vertical with a solver constraint,
    /// then re-solve. An already-present identical constraint is
    /// not duplicated (the 2D editor appended blindly; a duplicate
    /// only makes the solver report a conflict).
    @discardableResult
    func applyHorizontalConstraintToSelectedLine() -> Bool {
        guard let lineID = selectedSketchLineID,
              var working = activeSketch else { return false }
        if !working.constraints.contains(.horizontal(entity: lineID)) {
            working.constraints.append(.horizontal(entity: lineID))
        }
        activeSketch = working
        commitActiveSketch(solveFirst: true)
        return true
    }

    @discardableResult
    func applyVerticalConstraintToSelectedLine() -> Bool {
        guard let lineID = selectedSketchLineID,
              var working = activeSketch else { return false }
        if !working.constraints.contains(.vertical(entity: lineID)) {
            working.constraints.append(.vertical(entity: lineID))
        }
        activeSketch = working
        commitActiveSketch(solveFirst: true)
        return true
    }

    /// The 2D editor's `constraint(_:withValue:)` transform,
    /// ported: value-bearing constraints come back with the new
    /// driving value; every other kind passes through unchanged.
    static func sketchConstraint(_ c: SketchConstraint, withValue v: Double) -> SketchConstraint {
        switch c {
        case .distancePoints(let a, let ka, let b, let kb, _):
            return .distancePoints(entityA: a, kindA: ka, entityB: b, kindB: kb, value: v)
        case .radius(let e, _):
            return .radius(entity: e, value: v)
        case .diameter(let e, _):
            return .diameter(entity: e, value: v)
        case .angleBetween(let a, let b, _):
            return .angleBetween(entityA: a, entityB: b, degrees: v)
        default:
            return c
        }
    }

    /// Edit one of the active sketch's constraint values in place
    /// (the rail's constraint rows) and re-solve.
    func updateActiveSketchConstraint(at index: Int, value: Double) {
        guard var working = activeSketch,
              working.constraints.indices.contains(index) else { return }
        working.constraints[index] = Self.sketchConstraint(working.constraints[index],
                                                           withValue: value)
        activeSketch = working
        commitActiveSketch(solveFirst: true)
    }

    /// Remove one of the active sketch's constraints.
    func deleteActiveSketchConstraint(at index: Int) {
        guard var working = activeSketch,
              working.constraints.indices.contains(index) else { return }
        working.constraints.remove(at: index)
        activeSketch = working
        commitActiveSketch()
    }

    /// Delete the in-place selection's entities — the 2D editor's
    /// per-entity delete applied to the whole selection: the
    /// entities go, and every constraint that referenced any of
    /// them goes with them.
    func deleteSelectedSketchEntities() {
        guard var working = activeSketch,
              !selectedSketchEntityIDs.isEmpty else { return }
        let ids = selectedSketchEntityIDs
        for id in ids { working.removeEntity(id) }
        working.constraints.removeAll {
            !Set($0.referencedEntities).isDisjoint(with: ids)
        }
        selectedSketchEntityIDs = []
        activeSketch = working
        commitActiveSketch()
    }

    /// Fusion's finish-sketch flow, ported from the 2D editor: the
    /// active sketch must yield at least one closed profile
    /// (otherwise the coded reason lands in `actionError` and the
    /// session stays open); on success the session ends and the
    /// editor's pending-extrude hook opens the Extrude panel
    /// pre-filled with this sketch.
    @discardableResult
    func finishSketchAndExtrude() -> Bool {
        guard let sk = activeSketch, let id = activeSketchID else { return false }
        do {
            let (profiles, _) = try sk.extractProfiles()
            guard !profiles.isEmpty else { throw CADError.padNoProfile }
        } catch let e as CADError {
            actionError = e
            MCLog.shared.log(error: e, category: .sketch)
            return false
        } catch {
            actionError = .unknown("\(error)")
            return false
        }
        endSketchInPlace()
        pendingExtrudeSketchID = id
        return true
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

/// The part editor v3 — a Fusion-style workspace, reshaped in
/// v1.12: a header strip (part, material, volume, mass, size —
/// always visible), a browser on the far left (sketches + the
/// feature timeline in build order), an ALL-LEFT tool rail
/// (Sketch / Construct / Create / Modify / Inspect groups, and the
/// sketch tools while an in-place session is live), the 3D viewport
/// in the middle, and a context panel on the right for the active
/// tool.
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
    /// Live width while the resize handle is being dragged. Dragging
    /// used to write `browserPanelWidth` (@AppStorage) on EVERY drag
    /// event — a UserDefaults write plus full-tree invalidation per
    /// event, which made the drag visibly laggy (device report
    /// 2026-10-26). The drag now mutates only this @State; the
    /// persisted width is committed once, in onEnded.
    @State private var dragLiveWidth: Double?
    /// The width all layout reads: the live drag width while a drag
    /// is in flight, otherwise the persisted width.
    private var effectivePanelWidth: Double { dragLiveWidth ?? browserPanelWidth }
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
    /// "Show model edges" (Home ▸ Settings) — the sharp-edge line
    /// overlay in the 3D view. Same AppStorage key as the Settings
    /// toggle ("showModelEdges").
    @AppStorage("showModelEdges") private var showModelEdges: Bool = true
    /// Rail inspector working copies (one variable per @State):
    /// the selected circle's radius / the selected line's length,
    /// reloaded whenever the in-place selection changes.
    @State private var railRadiusText: String = ""
    @State private var railLengthText: String = ""

    @ViewBuilder
    private var mainRow: some View {
                HStack(spacing: 0) {
                    if effectivePanelWidth > 0 {
                        browserPanel
                            .frame(width: effectivePanelWidth)
                    }
                    panelDragHandle
                    toolRail
                    Divider()
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
                                openSketch: { id in
                                    // v1.12: a created sketch opens
                                    // as an in-place session in the
                                    // viewport, not a pushed editor.
                                    model.beginSketchInPlace(id)
                                },
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
                model.choosingSketchPlane = false
                model.setDraft(nil)
            }
        }
    }

    /// The editor shell (JOB A layering): navigation stack ONLY
    /// (the nav bar itself is hidden, v1.11). The two sheets and the
    /// remaining change handlers hang off SEPARATE computed
    /// properties below
    /// (withMaterialSheet, body) and off mainRow — a single giant
    /// modifier chain on one expression repeatedly timed out the
    /// Swift type checker (v4.2 Actions failures), so every layer
    /// here stays a small type-check unit of its own.
    private var coreView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerStrip
                Divider()
                mainRow
            }
            // No navigation bar over the editor (v1.11): the
            // document name moved into the header strip itself, and
            // the bar was a mostly-empty black band eating vertical
            // space. Nothing is pushed from the editor anymore
            // (v1.12) — sketching happens in place, in the viewport.
            .toolbar(.hidden, for: .navigationBar)
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
        .onAppear {
            // A brand-new document opens straight into an in-place
            // sketch on the XY plane (Sean's normal-CAD flow); any
            // document with content is left exactly as it was.
            model.autoStartSketchIfEmpty()
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
    /// files screen, Save As (format sheet) — each an SF Symbol +
    /// text, chip-styled like the rail buttons, never joined and
    /// never bare text links. (Export STL used to sit here too; it
    /// now lives only in the Save As sheet — v1.11.)
    private var headerFileButtons: some View {
        HStack(spacing: 10) {
            headerChip("Home", icon: "house.fill") { session.closeEditor() }
            headerChip("Save As", icon: "square.and.arrow.down") {
                model.shareURL = nil
                showSaveAsSheet = true
            }
            if let msg = model.saveMessage {
                Text(msg)
                    .mcFont(17, weight: .semibold)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
        }
        .layoutPriority(2)
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
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
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
                // The DOCUMENT name lives in the header strip now
                // (v1.11) — the navigation title bar above it is
                // hidden, so there is no second, mostly-empty black
                // band carrying just this name.
                Text(model.document.name)
                    .mcFont(22, weight: .bold)
                    .lineLimit(1)
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
            .layoutPriority(1)
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

    // MARK: Tool rail (left) — replaces the top ribbon (v1.12)

    /// The editor's tools live on the LEFT now: a ~96 pt vertical
    /// rail between the browser panel and the viewport. Two faces:
    /// the model tools (New Sketch prominent on top, then every
    /// tool the old top ribbon carried — same groups, same actions)
    /// and, while an in-place sketch session is live, the sketch
    /// face: draw tools, live status, constraints, the selection
    /// inspector, and Done.
    private var toolRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                if model.isSketchingInPlace {
                    sketchRailContent
                } else {
                    modelRailContent
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 96)
        .background(Color.white.opacity(0.02))
    }

    private func railButton(_ label: String, icon: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .mcFont(24)
                Text(label)
                    .mcFont(15, weight: .semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(active ? .black : .primary)
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(active ? accent : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func railCaption(_ text: String) -> some View {
        Text(text)
            .mcFont(12, weight: .bold)
            .foregroundStyle(.secondary)
            .tracking(1.5)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
    }

    /// Model face of the rail: New Sketch first (the primary flow,
    /// accent-filled), then the ribbon's groups 1:1 — SKETCH /
    /// CONSTRUCT / CREATE / MODIFY / INSPECT — every button setting
    /// the same activeTool / state the ribbon button set.
    @ViewBuilder
    private var modelRailContent: some View {
        Button {
            selectTool(.newSketch)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "square.and.pencil")
                    .mcFont(26)
                Text("New Sketch")
                    .mcFont(16, weight: .bold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 66)
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(activeTool == .newSketch ? accent : accent.opacity(0.75)))
        }
        .buttonStyle(.plain)
        railCaption("SKETCH")
        railButton("On Face", icon: "square.on.square.dashed", active: pickingFace && pickPurpose == .sketchOnFace) {
            pickPurpose = .sketchOnFace
            activeTool = nil
            startFacePicking()
        }
        railCaption("CONSTRUCT")
        railButton("Offset Plane", icon: "square.on.square", active: activeTool == .offsetPlane) {
            selectTool(.offsetPlane)
        }
        railButton("Angle Plane", icon: "triangle", active: activeTool == .anglePlane) {
            selectTool(.anglePlane)
        }
        railButton("Midplane", icon: "rectangle.split.3x1", active: activeTool == .midplane) {
            selectTool(.midplane)
        }
        railCaption("CREATE")
        railButton("Extrude", icon: "rectangle.expand.vertical", active: activeTool == .extrude) {
            selectTool(.extrude)
        }
        railButton("Revolve", icon: "rotate.3d", active: activeTool == .revolve) {
            selectTool(.revolve)
        }
        railButton("Thread", icon: "lines.measurement.horizontal", active: false) {
            activeTool = nil
            if let f = model.addThreadDefault() { featureToEdit = f }
        }
        railButton("Hole", icon: "circle.circle", active: activeTool == .hole) {
            selectTool(.hole)
        }
        railButton("Loft", icon: "square.2.layers.3d", active: activeTool == .loft) {
            selectTool(.loft)
        }
        railButton("Sweep", icon: "lasso", active: activeTool == .sweep) {
            selectTool(.sweep)
        }
        railButton("Coil", icon: "tornado", active: activeTool == .coil) {
            selectTool(.coil)
        }
        railButton("Pipe", icon: "waveform.path", active: activeTool == .pipe) {
            selectTool(.pipe)
        }
        railButton("Rib", icon: "square.split.2x1", active: activeTool == .rib) {
            selectTool(.rib)
        }
        railPrimitivesMenu
        railCaption("MODIFY")
        railButton("Fillet", icon: "capsule", active: activeTool == .fillet) {
            selectTool(.fillet)
        }
        railButton("Chamfer", icon: "octagon", active: activeTool == .chamfer) {
            selectTool(.chamfer)
        }
        railButton("Shell", icon: "cube.transparent", active: activeTool == .shell) {
            selectTool(.shell)
        }
        railButton("Mirror", icon: "flip.horizontal", active: activeTool == .mirror) {
            selectTool(.mirror)
        }
        railButton("Pattern", icon: "square.grid.2x2", active: activeTool == .pattern) {
            selectTool(.pattern)
        }
        railButton("Circ. Pattern", icon: "arrow.triangle.2.circlepath", active: activeTool == .circularPattern) {
            selectTool(.circularPattern)
        }
        railButton("Draft", icon: "pyramid", active: activeTool == .draft) {
            selectTool(.draft)
        }
        railButton("Scale", icon: "arrow.up.and.down.and.arrow.left.and.right", active: activeTool == .scaleBody) {
            selectTool(.scaleBody)
        }
        railButton("Move", icon: "move.3d", active: activeTool == .moveBody) {
            selectTool(.moveBody)
        }
        railButton("Split", icon: "rectangle.split.2x1", active: activeTool == .splitBody) {
            selectTool(.splitBody)
        }
        railCaption("INSPECT")
        railButton("Measure", icon: "ruler", active: activeTool == .measure) {
            selectTool(.measure)
        }
        railButton("Sketches", icon: model.showsSketches ? "eye" : "eye.slash",
                   active: model.showsSketches) {
            model.showsSketches.toggle()
        }
        railButton("Section", icon: "square.lefthalf.filled", active: sectionOn) {
            toggleSection()
        }
    }

    /// The ribbon's Primitive menu, restyled for the rail: one
    /// button, the same five kinds, the same activeTool routing.
    private var railPrimitivesMenu: some View {
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
                        .mcFont(15, weight: .semibold)
                    Image(systemName: "chevron.down")
                        .mcFont(11, weight: .bold)
                }
                .lineLimit(1)
            }
            .foregroundStyle(isActive ? .black : .primary)
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? accent : Color.white.opacity(0.06)))
        }
    }

    private func selectTool(_ tool: ActiveTool) {
        if activeTool == tool {
            activeTool = nil
            extrudePresetSketchID = nil
        } else {
            activeTool = tool
        }
    }

    // MARK: Tool rail — sketch face (in-place session live)

    private func sketchToolIcon(_ tool: InPlaceSketchTool) -> String {
        switch tool {
        case .select: return "cursorarrow"
        case .point: return "circle.circle"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arc: return "moon"
        }
    }

    /// Sketch face of the rail: the six draw tools, the live
    /// status card (drag readout while a stroke is down, otherwise
    /// DOF + snap), the constraint surface ported from the 2D
    /// editor (Horizontal/Vertical for a selected line + the
    /// value-editable constraint list), the selection inspector
    /// (measurements + exact radius/length fields + Delete), and
    /// the finish actions.
    @ViewBuilder
    private var sketchRailContent: some View {
        Text(model.activeSketch?.name ?? "Sketch")
            .mcFont(16, weight: .bold)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
        railCaption("DRAW")
        ForEach(InPlaceSketchTool.allCases, id: \.self) { tool in
            railButton(tool.displayName, icon: sketchToolIcon(tool),
                       active: model.inPlaceTool == tool) {
                model.inPlaceTool = tool
            }
        }
        sketchStatusCard
        sketchConstraintsSection
        sketchInspectorSection
        Divider()
            .padding(.vertical, 2)
        Button {
            _ = model.finishSketchAndExtrude()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "rectangle.expand.vertical")
                    .mcFont(22)
                Text("Finish & Extrude")
                    .mcFont(15, weight: .semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        Button {
            model.endSketchInPlace()
        } label: {
            Text("DONE")
                .mcFont(21, weight: .bold)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(RoundedRectangle(cornerRadius: 10).fill(accent))
        }
        .buttonStyle(.plain)
    }

    /// Live session status: while a stroke is down, its size
    /// readout (big, accent); otherwise the sketch's freedom —
    /// DOF count or "Fully constrained" — plus the snap step.
    private var sketchStatusCard: some View {
        VStack(spacing: 3) {
            if let readout = model.sketchDragReadout {
                Text(readout)
                    .mcFont(19, weight: .bold)
                    .foregroundStyle(accent)
                    .multilineTextAlignment(.center)
            } else if model.activeSketchDOF == 0,
                      !(model.activeSketch?.entities.isEmpty ?? true) {
                Text("Fully constrained")
                    .mcFont(15, weight: .bold)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            } else {
                Text("\(model.activeSketchDOF) DOF")
                    .mcFont(17, weight: .bold)
            }
            Text("Snap \(mcFmt(model.sketchSnapStep)) mm")
                .mcFont(13)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.06)))
    }

    /// The constraint surface, ported from the 2D editor: with
    /// exactly one line selected, Horizontal / Vertical buttons
    /// (the 2D line inspector's pair); below, the sketch's
    /// constraints as compact rows whose driving values are
    /// editable in place (the 2D ConstraintRow, restacked for the
    /// rail's width).
    @ViewBuilder
    private var sketchConstraintsSection: some View {
        let constraints = model.activeSketch?.constraints ?? []
        if model.selectedSketchLineID != nil || !constraints.isEmpty {
            railCaption("CONSTRAINTS")
            if model.selectedSketchLineID != nil {
                railButton("Horizontal", icon: "arrow.left.and.right", active: false) {
                    model.applyHorizontalConstraintToSelectedLine()
                }
                railButton("Vertical", icon: "arrow.up.and.down", active: false) {
                    model.applyVerticalConstraintToSelectedLine()
                }
            }
            ForEach(Array(constraints.enumerated()), id: \.offset) { i, c in
                RailConstraintRow(
                    constraint: c,
                    onApplyValue: { v in
                        model.updateActiveSketchConstraint(at: i, value: v)
                    },
                    onDelete: {
                        model.deleteActiveSketchConstraint(at: i)
                    }
                )
            }
        }
    }

    /// The radius of the one selected circle / the length of the
    /// one selected line — the exact guards the model's setters
    /// apply, mirrored so their fields show only when they apply.
    private var singleSelectedCircleRadius: Double? {
        guard let sk = model.activeSketch,
              model.selectedSketchEntityIDs.count == 1,
              let id = model.selectedSketchEntityIDs.first,
              let e = sk.entity(id),
              case .circle(_, _, let r, _) = e else { return nil }
        return r
    }

    private var singleSelectedLineLength: Double? {
        guard let sk = model.activeSketch,
              model.selectedSketchEntityIDs.count == 1,
              let id = model.selectedSketchEntityIDs.first,
              let e = sk.entity(id),
              case .line(_, let a, let b, _) = e else { return nil }
        return a.distance(to: b)
    }

    /// Selection inspector: the model's measurement readouts as
    /// large rows, exact-value fields for the selected circle's
    /// radius / the selected line's length (type it, tap ✓, the
    /// model fixes the geometry through its constraint-aware
    /// setters), and Delete for the selection. The fields reload
    /// whenever the selection or the measurements change.
    @ViewBuilder
    private var sketchInspectorSection: some View {
        if !model.selectedSketchMeasurements.isEmpty {
            railCaption("INSPECTOR")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.selectedSketchMeasurements, id: \.self) { line in
                    Text(line)
                        .mcFont(16, weight: .semibold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if singleSelectedCircleRadius != nil {
                railValueField(label: "Radius mm", text: $railRadiusText) { v in
                    _ = model.setSelectedCircleRadius(v)
                }
            }
            if singleSelectedLineLength != nil {
                railValueField(label: "Length mm", text: $railLengthText) { v in
                    _ = model.setSelectedLineLength(v)
                }
            }
            Button(role: .destructive) {
                model.deleteSelectedSketchEntities()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                        .mcFont(22)
                    Text("Delete")
                        .mcFont(15, weight: .semibold)
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color.red.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
    }

    /// One compact exact-value field (PanelNumberRow's style at
    /// rail width): label over a rounded text field + ✓ apply.
    private func railValueField(label: String, text: Binding<String>,
                                apply: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .mcFont(13, weight: .semibold)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(label, text: text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .mcFont(17, weight: .semibold)
                    .textFieldStyle(.roundedBorder)
                Button {
                    if let v = Double(text.wrappedValue) { apply(v) }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .mcFont(24)
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Apply \(label)")
            }
        }
        .onAppear { reloadRailInspectorFields() }
        .onChange(of: railInspectorFieldKey) { _, _ in reloadRailInspectorFields() }
    }

    /// What the inspector fields mirror: the selection + the
    /// current measurements. Any change reloads the field texts
    /// from the geometry, so a drag or a solve never leaves a
    /// stale number in a field.
    private var railInspectorFieldKey: String {
        model.selectedSketchEntityIDs.sorted().map(String.init).joined(separator: ",")
            + "|" + model.selectedSketchMeasurements.joined(separator: ";")
    }

    private func reloadRailInspectorFields() {
        if let r = singleSelectedCircleRadius { railRadiusText = mcFmt(r) }
        if let l = singleSelectedLineLength { railLengthText = mcFmt(l) }
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
                    showBasePlanes: model.choosingSketchPlane,
                    showModelEdges: showModelEdges,
                    sketchModel: model,
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
            model.beginSketchInPlace(model.addSketchOnFace(face))
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
                        model.beginSketchInPlace(sketch.id)
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
                            model.beginSketchInPlace(model.addSketchOnFace(face))
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
                // Same one-background rule as PanelOKBar: fill on
                // the label, .plain style — no pill inside a box.
                Button { cancelQuick() } label: {
                    Text("Cancel")
                        .mcFont(21, weight: .semibold)
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(accent.opacity(0.22)))
                }
                .buttonStyle(.plain)
                Button { commitQuick() } label: {
                    Text("Done")
                        .mcFont(21, weight: .bold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 10).fill(accent))
                }
                .buttonStyle(.plain)
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
                .fill(Color.white.opacity(effectivePanelWidth == 0 ? 0.10 : 0.05))
            VStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 4, height: 4)
                }
            }
            if effectivePanelWidth == 0 {
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
                    dragLiveWidth = min(520, max(0, start + Double(value.translation.width)))
                }
                .onEnded { _ in
                    // Commit once: under 40 snaps shut, otherwise the
                    // final width becomes the persisted + last width.
                    let finalWidth = dragLiveWidth ?? browserPanelWidth
                    if finalWidth < 40 {
                        browserPanelWidth = 0
                    } else {
                        browserPanelWidth = finalWidth
                        browserPanelLastWidth = finalWidth
                    }
                    dragLiveWidth = nil
                    panelDragStart = nil
                }
        )
        .onTapGesture(count: 2) { toggleBrowserPanel() }
        .accessibilityLabel(effectivePanelWidth == 0 ? "Show browser panel" : "Resize or hide browser panel")
    }

    // MARK: Browser (left): sketches + feature timeline

    /// Width dispatcher: below 250 pt the panel is a slim icon rail;
    /// at/above it, the full browser list at the chosen width.
    private var browserPanel: some View {
        Group {
            if effectivePanelWidth < 250 {
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
                        if sketch.isDatumPlane {
                            // Datums hold no drawing — no session to
                            // begin; the icon is display-only here.
                            Image(systemName: "square.on.square")
                                .mcFont(22)
                                .foregroundStyle(Color.teal)
                                .frame(width: 44, height: 44)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.06)))
                                .accessibilityLabel(sketch.name)
                        } else {
                            Button {
                                model.beginSketchInPlace(sketch.id)
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .mcFont(22)
                                    .foregroundStyle(accent)
                                    .frame(width: 44, height: 44)
                                    .background(RoundedRectangle(cornerRadius: 10)
                                        .fill(model.selectedSketchID == sketch.id
                                              ? accent.opacity(0.35)
                                              : Color.white.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(sketch.name)
                        }
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
                        Text("No sketches yet — use New Sketch in the rail on the left and pick a plane.")
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
                    Text("No features yet. Pick a tool from the rail on the left — Extrude a sketch, or start with a Primitive.")
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
            if sketch.isDatumPlane {
                sketchRowLabel(sketch)
            } else {
                // Tapping a sketch row starts drawing on it IN the
                // viewport (v1.12) — no pushed 2D editor anymore.
                Button {
                    model.beginSketchInPlace(sketch.id)
                } label: {
                    sketchRowLabel(sketch)
                }
                .buttonStyle(.plain)
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

    /// The icon + name + detail half of a sketch browser row,
    /// shared by the datum (display-only) and sketch (tap to draw
    /// in place) variants.
    private func sketchRowLabel(_ sketch: Sketch) -> some View {
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


/// One constraint row in the sketch rail — the 2D editor's
/// ConstraintRow ported to the rail's width: name + entity detail
/// stacked, the driving value editable in place (type it, tap ✓),
/// delete on the right. The detail strings and the value plumbing
/// are the 2D editor's, unchanged; only the layout differs (the
/// full-width row doesn't fit 96 pt).
private struct RailConstraintRow: View {
    let constraint: SketchConstraint
    let onApplyValue: (Double) -> Void
    let onDelete: () -> Void
    @State private var text: String
    @AppStorage(MCAccent.key) private var accentHex: String = MCAccent.defaultHex
    private var accent: Color { MCAccent.color(hex: accentHex) }

    init(constraint: SketchConstraint,
         onApplyValue: @escaping (Double) -> Void,
         onDelete: @escaping () -> Void) {
        self.constraint = constraint
        self.onApplyValue = onApplyValue
        self.onDelete = onDelete
        _text = State(initialValue: Self.value(of: constraint).map(mcFmt) ?? "")
    }

    private static func value(of c: SketchConstraint) -> Double? {
        switch c {
        case .distancePoints(_, _, _, _, let v): return v
        case .radius(_, let v): return v
        case .diameter(_, let v): return v
        case .angleBetween(_, _, let d): return d
        default: return nil
        }
    }

    private var detail: String {
        switch constraint {
        case .coincident(let a, let b): return "#\(a) = #\(b)"
        case .distancePoints(let a, _, let b, _, _): return "#\(a) – #\(b)"
        case .radius(let e, _): return "entity #\(e)"
        case .diameter(let e, _): return "entity #\(e)"
        case .horizontal(let e): return "entity #\(e)"
        case .vertical(let e): return "entity #\(e)"
        case .parallel(let a, let b): return "#\(a) ∥ #\(b)"
        case .perpendicular(let a, let b): return "#\(a) ⟂ #\(b)"
        case .tangent(let a, let b): return "#\(a) ~ #\(b)"
        case .concentric(let a, let b): return "#\(a) ◎ #\(b)"
        case .equal(let a, let b): return "#\(a) ≡ #\(b)"
        case .symmetric(let a, let b, let axis): return "#\(a) ↔ #\(b) / #\(axis)"
        case .pointOnEntity(let p, let e): return "#\(p) on #\(e)"
        case .midpoint(let p, let e): return "#\(p) mid #\(e)"
        case .collinear(let a, let b): return "#\(a) — #\(b)"
        case .angleBetween(let a, let b, _): return "#\(a) ∠ #\(b)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(constraint.displayName)
                        .mcFont(14, weight: .semibold)
                    Text(detail)
                        .mcFont(12)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .mcFont(15)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete constraint")
            }
            if Self.value(of: constraint) != nil {
                HStack(spacing: 4) {
                    TextField("Value", text: $text)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .mcFont(15, weight: .semibold)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        if let v = Double(text) { onApplyValue(v) }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .mcFont(20)
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apply value")
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.06)))
        .onChange(of: constraint) { _, newValue in
            if let v = Self.value(of: newValue) { text = mcFmt(v) }
        }
    }
}
