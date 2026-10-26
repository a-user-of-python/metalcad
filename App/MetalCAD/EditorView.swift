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
    @Published var stlWarnings: [CADError] = []
    @Published var partIndex: Int = 0
    /// Face outlines (in sketch-plane coordinates) for sketches created
    /// on a solid face, drawn as a guide in the sketch editor.
    @Published var faceOutlines: [String: [Vec2]] = [:]
    /// Set by the sketch editor's "Finish & Extrude": the editor opens
    /// the Extrude panel pre-filled with this sketch.
    @Published var pendingExtrudeSketchID: String?
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

    func feature(withID id: String) -> Feature? { part?.features.first { $0.id == id } }

    func replaceSketch(_ sketch: Sketch) {
        mutate { part in
            if let i = part.sketches.firstIndex(where: { $0.id == sketch.id }) {
                part.sketches[i] = sketch
            }
        }
    }

    func addSketch() {
        mutate { part in
            part.sketches.append(Sketch(name: "Sketch \(part.sketches.count + 1)", plane: .xy))
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

    /// First sketch of the part, or a coded error if there is none yet.
    private func firstSketchOrError() -> Sketch? {
        if let sk = part?.sketches.first { return sk }
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

    // MARK: Sketch on a face

    /// Create a sketch on the planar face that owns welded-mesh triangle
    /// `triangleIndex` (the SceneKit hit-test face index — the display
    /// soup uses the same triangle order). Returns the new sketch's id,
    /// or nil with `actionError` set (MCAD-SK201 when no face matches).
    func sketchOnFace(triangleIndex: Int) -> String? {
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
            stlURL = url
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
struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var featureToEdit: Feature?
    @State private var showMaterialPicker = false
    @State private var pickingFace = false
    @State private var sketchNav: SketchNav?
    @State private var activeTool: ActiveTool?
    @State private var extrudePresetSketchID: String?
    @State private var showBrowser = true
    // Section view state. `sectionT` is the committed cut position;
    // the slider edits `sectionSlider` and commits on release so the
    // CSG section only runs once per drag, not per pixel.
    @State private var sectionOn = false
    @State private var sectionAxis = 2
    @State private var sectionT: Double = 0.5
    @State private var sectionSlider: Double = 0.5
    @State private var sectionedMesh: Mesh?

    private let rowFont = Font.system(size: 20)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerStrip
                Divider()
                ribbon
                Divider()
                HStack(spacing: 0) {
                    if showBrowser {
                        browserPanel
                            .frame(width: 350)
                        Divider()
                    }
                    centerColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let tool = activeTool {
                        Divider()
                        ScrollView {
                            ToolPanelView(
                                tool: tool,
                                model: model,
                                extrudeSketchID: extrudePresetSketchID,
                                close: {
                                    activeTool = nil
                                    extrudePresetSketchID = nil
                                },
                                openSketch: { id in sketchNav = SketchNav(id: id) },
                                pickFace: {
                                    activeTool = nil
                                    startFacePicking()
                                }
                            )
                        }
                        .frame(width: 380)
                        .background(Color.white.opacity(0.03))
                    }
                }
            }
            .navigationTitle(model.document.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $sketchNav) { nav in
                SketchEditorView(model: model, sketchID: nav.id)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let msg = model.saveMessage {
                        Text(msg)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    Button("Save") { model.save() }
                        .font(.system(size: 19, weight: .semibold))
                    Button("Export STL") { model.exportSTL() }
                        .font(.system(size: 19, weight: .semibold))
                    if let url = model.stlURL {
                        ShareLink(item: url) { Text("Share STL") }
                            .font(.system(size: 19, weight: .semibold))
                    }
                }
            }
            .sheet(item: $featureToEdit) { feature in
                FeatureEditorSheet(
                    feature: feature,
                    sketches: model.part?.sketches ?? [],
                    filletMaxFeasible: filletMaxFeasible(for: feature),
                    onSave: { name, kind in
                        model.updateFeature(id: feature.id, name: name, kind: kind)
                        featureToEdit = nil
                    },
                    onCancel: { featureToEdit = nil }
                )
            }
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
            .onChange(of: model.pendingExtrudeSketchID) { _, newID in
                guard let newID else { return }
                model.pendingExtrudeSketchID = nil
                extrudePresetSketchID = newID
                activeTool = .extrude
            }
            .onChange(of: baseMeshKey) { _, _ in
                if sectionOn { refreshSection() }
            }
        }
    }

    // MARK: Mesh / section plumbing

    private var baseMesh: Mesh { model.rebuild?.mesh ?? Mesh() }

    private var baseMeshKey: String {
        "\(baseMesh.triangleCount)-\(baseMesh.volume)"
    }

    private var displayMesh: Mesh {
        sectionOn ? (sectionedMesh ?? baseMesh) : baseMesh
    }

    private var meshKey: String {
        "\(displayMesh.triangleCount)-\(displayMesh.volume)-\(model.part?.materialID ?? "")-sec\(sectionOn)-\(sectionT)"
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

    private var headerStrip: some View {
        HStack(spacing: 18) {
            Button {
                showBrowser.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.part?.name ?? "Part")
                    .font(.system(size: 22, weight: .bold))
                Text("Material, size and weight — always up to date")
                    .font(.system(size: 15))
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
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("\(String(format: "%.2f", model.part?.material.density ?? 0)) g/cm³")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            headerStat("Volume", "\(String(format: "%.2f", baseMesh.volume / 1000)) cm³")
            headerStat("Mass", model.rebuild?.massGrams.map(mcMass) ?? "—")
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .bold))
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
                    ribbonButton("On Face", icon: "square.on.square.dashed", active: pickingFace) {
                        activeTool = nil
                        startFacePicking()
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
                }
                ribbonGroup("INSPECT") {
                    ribbonButton("Measure", icon: "ruler", active: activeTool == .measure) {
                        selectTool(.measure)
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
                .font(.system(size: 14, weight: .bold))
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
                    .font(.system(size: 24))
                Text(label)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? .black : .primary)
            .frame(minWidth: 80, minHeight: 58)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(active ? Color.orange : Color.white.opacity(0.06)))
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
                    .font(.system(size: 24))
                HStack(spacing: 3) {
                    Text("Primitive")
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                }
                .lineLimit(1)
            }
            .foregroundStyle(isActive ? .black : .primary)
            .frame(minWidth: 80, minHeight: 58)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.orange : Color.white.opacity(0.06)))
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
            SceneKitView(
                mesh: displayMesh,
                material: model.part?.material,
                isPickingFace: pickingFace,
                onFacePicked: { index in handleFacePicked(index) }
            )
            .id(meshKey)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if sectionOn {
                sectionControls
            }
            statsBar
            if !model.stlWarnings.isEmpty {
                ForEach(Array(model.stlWarnings.enumerated()), id: \.offset) { _, w in
                    Text("\(w.userMessage) (\(w.code))")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
    }

    private var sectionControls: some View {
        HStack(spacing: 14) {
            Text("Section")
                .font(.system(size: 19, weight: .bold))
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
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 150, alignment: .trailing)
            Button("Done") { toggleSection() }
                .font(.system(size: 19, weight: .semibold))
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
                .font(.system(size: 26))
            Text("Tap a flat face on the model to sketch on it.")
                .font(.system(size: 20, weight: .semibold))
            Spacer()
            Button("Cancel") { pickingFace = false }
                .font(.system(size: 20, weight: .semibold))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.25)))
    }

    private func startFacePicking() {
        if sectionOn { toggleSection() }
        pickingFace = true
    }

    private func handleFacePicked(_ triangleIndex: Int) {
        pickingFace = false
        if let sketchID = model.sketchOnFace(triangleIndex: triangleIndex) {
            sketchNav = SketchNav(id: sketchID)
        }
    }

    private var statsBar: some View {
        HStack(spacing: 24) {
            Text("Triangles: \(displayMesh.triangleCount)")
            if sectionOn {
                Text("Section view")
                    .foregroundStyle(.orange)
            }
            if let w = model.rebuild?.warnings, !w.isEmpty {
                Text("\(w.count) warning\(w.count == 1 ? "" : "s")")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.system(size: 19, weight: .semibold))
    }

    private func errorBanner(_ err: CADError, dismissible: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 26))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(err.userMessage)
                    .font(.system(size: 20, weight: .semibold))
                Text(err.code)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if dismissible {
                Button {
                    model.actionError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.16)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Browser (left): sketches + feature timeline

    private var browserPanel: some View {
        List {
            Section("Sketches") {
                if let part = model.part {
                    if part.sketches.isEmpty {
                        Text("No sketches yet — use Sketch ▸ New Sketch in the toolbar.")
                            .font(rowFont)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(part.sketches) { sketch in
                        NavigationLink {
                            SketchEditorView(model: model, sketchID: sketch.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sketch.name)
                                    .font(.system(size: 20, weight: .semibold))
                                Text("\(sketch.entities.count) items · \(sketch.constraints.count) constraints")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                        .font(rowFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }

    private func featureRow(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(for: feature)
            Image(systemName: iconName(for: feature.kind))
                .font(.system(size: 22))
                .foregroundStyle(.orange)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.name)
                    .font(.system(size: 20, weight: .semibold))
                Text(kindSummary(feature.kind))
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                if let st = model.status(for: feature.id) {
                    if !st.ok, let code = st.errorCode {
                        Text(code)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.red)
                    } else if st.message == "suppressed" {
                        Text("Suppressed")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                    } else if st.message == "paused" {
                        Text("Paused — an earlier feature failed")
                            .font(.system(size: 17))
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
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            Button(feature.suppressed ? "Show" : "Hide") {
                model.setSuppressed(feature.id, !feature.suppressed)
            }
            .font(.system(size: 16, weight: .semibold))
            Button(role: .destructive) {
                model.deleteFeature(feature.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
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
        .font(.system(size: 24))
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
        case .booleanCutPlaceholder:
            return "Boolean cut"
        }
    }
}
