import SwiftUI

/// Why the 3D view is currently picking a face. The editor sets this
/// before entering pick mode; the picked face is then routed to the
/// right consumer (a new sketch, the plane picker, a construct tool,
/// or a redefine).
enum FacePickPurpose: Equatable {
    case sketchOnFace            // v3 flow: create a sketch on the face at once
    case newSketchFace           // feed the New Sketch plane picker
    case offsetDatumFace         // feed Construct ▸ Offset Plane
    case midplaneA               // feed Construct ▸ Midplane (first face)
    case midplaneB               // feed Construct ▸ Midplane (second face)
    case redefineFace(String)    // set this sketch's plane to the face
}

/// A plane chosen in the plane picker (New Sketch / Redefine plane).
enum PlaneChoice: Equatable {
    case none
    case base(String)            // "XY" / "XZ" / "YZ"
    case datum(String)           // datum sketch id
    case face(PlanarFace)        // a face of the current body

    var resolvedPlane: Plane3? {
        switch self {
        case .none: return nil
        case .base(let name): return name == "XZ" ? .xz : (name == "YZ" ? .yz : .xy)
        case .datum: return nil  // resolved against the part by the caller
        case .face(let face): return face.plane
        }
    }
}

/// "facing +Z · at (0, 0, 10)" — a one-line plane description.
func mcPlaneText(_ plane: Plane3) -> String {
    let n = plane.normal
    let axis: String
    let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
    if ax >= ay && ax >= az { axis = n.x >= 0 ? "+X" : "−X" }
    else if ay >= ax && ay >= az { axis = n.y >= 0 ? "+Y" : "−Y" }
    else { axis = n.z >= 0 ? "+Z" : "−Z" }
    let o = plane.origin
    return "facing \(axis) · at (\(mcFmt(o.x)), \(mcFmt(o.y)), \(mcFmt(o.z)))"
}

/// "facing +Z · 2 400 mm²" — enough to tell one face from another.
func mcFaceLabel(_ face: PlanarFace) -> String {
    let n = face.plane.normal
    let axis: String
    let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
    if ax >= ay && ax >= az { axis = n.x >= 0 ? "+X" : "−X" }
    else if ay >= ax && ay >= az { axis = n.y >= 0 ? "+Y" : "−Y" }
    else { axis = n.z >= 0 ? "+Z" : "−Z" }
    return "facing \(axis) · \(String(format: "%.0f", face.area)) mm²"
}

/// Rotate a plane around one of its own axes (Plane at Angle tool).
func mcRotatedPlane(_ p: Plane3, aroundXAxis: Bool, degrees: Double) -> Plane3 {
    let th = degrees * Double.pi / 180
    let c = cos(th), s = sin(th)
    if aroundXAxis {
        // y axis rotates toward the normal; x axis stays.
        let y = p.yAxis * c + p.normal * s
        return Plane3(origin: p.origin, xAxis: p.xAxis, yAxis: y)
    } else {
        // x axis rotates away from the normal; y axis stays.
        let x = p.xAxis * c - p.normal * s
        return Plane3(origin: p.origin, xAxis: x, yAxis: p.yAxis)
    }
}

/// The Fusion-style context tools. Tapping a ribbon tool opens one of
/// these panels beside the preview; OK builds the feature with exactly
/// the numbers shown — nothing is hidden or prefixed.
enum ActiveTool: Identifiable, Equatable {
    case newSketch
    case redefinePlane(String)
    case offsetPlane
    case anglePlane
    case midplane
    case extrude
    case revolve
    case hole
    case loft
    case sweep
    case coil
    case pipe
    case rib
    case primitive(PrimitiveKind)
    case fillet
    case chamfer
    case shell
    case mirror
    case pattern
    case circularPattern
    case draft
    case scaleBody
    case moveBody
    case splitBody
    case measure
    // Selection-first panels (v4.3): opened from the picked-action
    // bar; each reads its target (face / edge / shaft) from
    // EditorModel.picked in its initializer.
    case pullFace
    case filletEdge
    case chamferEdge
    case threadShaft
    // Selection-first panels (v4.4): the picked-face bar's wider
    // Fusion-style menu — revolve the face's own outline, or finish
    // every edge bounding the face.
    case revolveFace
    case filletFaceEdges
    case chamferFaceEdges

    var id: String {
        switch self {
        case .newSketch: return "newSketch"
        case .redefinePlane(let id): return "redefinePlane-\(id)"
        case .offsetPlane: return "offsetPlane"
        case .anglePlane: return "anglePlane"
        case .midplane: return "midplane"
        case .extrude: return "extrude"
        case .revolve: return "revolve"
        case .hole: return "hole"
        case .loft: return "loft"
        case .sweep: return "sweep"
        case .coil: return "coil"
        case .pipe: return "pipe"
        case .rib: return "rib"
        case .primitive(let k): return "primitive-\(k.rawValue)"
        case .fillet: return "fillet"
        case .chamfer: return "chamfer"
        case .shell: return "shell"
        case .mirror: return "mirror"
        case .pattern: return "pattern"
        case .circularPattern: return "circularPattern"
        case .draft: return "draft"
        case .scaleBody: return "scaleBody"
        case .moveBody: return "moveBody"
        case .splitBody: return "splitBody"
        case .measure: return "measure"
        case .pullFace: return "pullFace"
        case .filletEdge: return "filletEdge"
        case .chamferEdge: return "chamferEdge"
        case .threadShaft: return "threadShaft"
        case .revolveFace: return "revolveFace"
        case .filletFaceEdges: return "filletFaceEdges"
        case .chamferFaceEdges: return "chamferFaceEdges"
        }
    }

    var title: String {
        switch self {
        case .newSketch: return "New Sketch"
        case .redefinePlane: return "Redefine Plane"
        case .offsetPlane: return "Offset Plane"
        case .anglePlane: return "Plane at Angle"
        case .midplane: return "Midplane"
        case .extrude: return "Extrude"
        case .revolve: return "Revolve"
        case .hole: return "Hole"
        case .loft: return "Loft"
        case .sweep: return "Sweep"
        case .coil: return "Coil"
        case .pipe: return "Pipe"
        case .rib: return "Rib"
        case .primitive(let k): return k.rawValue.capitalized
        case .fillet: return "Fillet"
        case .chamfer: return "Chamfer"
        case .shell: return "Shell"
        case .mirror: return "Mirror"
        case .pattern: return "Linear Pattern"
        case .circularPattern: return "Circular Pattern"
        case .draft: return "Draft"
        case .scaleBody: return "Scale"
        case .moveBody: return "Move Body"
        case .splitBody: return "Split Body"
        case .measure: return "Measure"
        case .pullFace: return "Pull Face"
        case .filletEdge: return "Fillet Edge"
        case .chamferEdge: return "Chamfer Edge"
        case .threadShaft: return "Thread Shaft"
        case .revolveFace: return "Revolve Face"
        case .filletFaceEdges: return "Fillet Face Edges"
        case .chamferFaceEdges: return "Chamfer Face Edges"
        }
    }
}

// MARK: - Shared panel pieces

func panelNum(_ s: String, fallback: Double) -> Double { Double(s) ?? fallback }

struct PanelNumberRow: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
                .mcFont(19, weight: .semibold)
            Spacer()
            TextField(label, text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .mcFont(20, weight: .semibold)
                .frame(width: 120)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }
}

struct PanelSketchPicker: View {
    let label: String
    let sketches: [Sketch]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("", selection: $selection) {
                ForEach(sketches) { sk in
                    Text(sk.name).tag(sk.id)
                }
            }
            .pickerStyle(.menu)
            .mcFont(20, weight: .semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

struct PanelNote: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text)
            .mcFont(17, weight: warning ? .semibold : .regular)
            .foregroundStyle(warning ? .orange : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Live draft feedback: while a panel is drafting, the pending
/// feature is rebuilt in the background and ghosted in the 3D view.
/// If that rebuild fails, the reason shows HERE, before the user
/// commits — no surprise error after OK.
struct PanelDraftError: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if model.draftFeatures != nil, let err = model.previewError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .mcFont(18)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Preview: \(err.userMessage)")
                        .mcFont(16, weight: .semibold)
                    Text(err.code)
                        .mcFont(13, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.14)))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PanelOKBar: View {
    var okTitle = "OK"
    var okEnabled = true
    let onOK: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button("Cancel") { onCancel() }
                .mcFont(20, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
            Button(okTitle) { onOK() }
                .mcFont(20, weight: .bold)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(okEnabled ? Color.orange : Color.gray))
                .disabled(!okEnabled)
        }
        .padding(.top, 8)
    }
}

// MARK: - Panel dispatch

struct ToolPanelView: View {
    let tool: ActiveTool
    @ObservedObject var model: EditorModel
    /// Sketch to pre-select (set when a sketch is finished with
    /// "Finish & Extrude").
    var extrudeSketchID: String? = nil
    /// Sketch tool panels should pre-select (the 3D selection, or the
    /// selection action bar's explicit choice).
    var panelSketchID: String? = nil
    /// Operation an Extrude panel should start with ("cut" when it
    /// was opened as Pocket from the selection action bar).
    var panelOperation: String? = nil
    let close: () -> Void
    let openSketch: (String) -> Void
    /// Enter face-pick mode for the given purpose; the picked face is
    /// routed back through EditorModel state and this panel reopens.
    let pickFace: (FacePickPurpose) -> Void
    /// Replace the open panel with another tool (construct flows hand
    /// off to New Sketch with the fresh datum pre-chosen).
    var switchTool: (ActiveTool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tool.title)
                    .mcFont(24, weight: .bold)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .mcFont(26)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider()
            panelBody
        }
        .padding(14)
    }

    @ViewBuilder
    private var panelBody: some View {
        switch tool {
        case .newSketch:
            NewSketchPanel(model: model, close: close, openSketch: openSketch, pickFace: pickFace)
        case .redefinePlane(let sketchID):
            RedefinePlanePanel(model: model, sketchID: sketchID, close: close, pickFace: pickFace)
        case .offsetPlane:
            OffsetPlanePanel(model: model, close: close, pickFace: pickFace, switchTool: switchTool)
        case .anglePlane:
            AnglePlanePanel(model: model, close: close, switchTool: switchTool)
        case .midplane:
            MidplanePanel(model: model, close: close, pickFace: pickFace, switchTool: switchTool)
        case .extrude:
            ExtrudePanel(model: model, initialSketchID: extrudeSketchID ?? panelSketchID,
                         initialOperation: panelOperation, close: close)
        case .revolve:
            RevolvePanel(model: model, initialSketchID: panelSketchID, close: close)
        case .hole:
            HolePanel(model: model, initialSketchID: panelSketchID,
                      generatedSketch: model.pendingHoleSketch, close: close)
        case .loft:
            LoftPanel(model: model, initialSketchID: panelSketchID, close: close)
        case .sweep:
            SweepPanel(model: model, initialSketchID: panelSketchID, close: close)
        case .coil:
            CoilPanel(model: model, close: close)
        case .pipe:
            PipePanel(model: model, initialSketchID: panelSketchID, close: close)
        case .rib:
            RibPanel(model: model, initialSketchID: panelSketchID, close: close)
        case .primitive(let kind):
            PrimitivePanel(model: model, kind: kind, close: close)
        case .fillet:
            FilletPanel(model: model, close: close)
        case .chamfer:
            ChamferPanel(model: model, close: close)
        case .shell:
            ShellPanel(model: model, close: close)
        case .mirror:
            MirrorPanel(model: model, close: close)
        case .pattern:
            PatternPanel(model: model, close: close)
        case .circularPattern:
            CircularPatternPanel(model: model, close: close)
        case .draft:
            DraftPanel(model: model, close: close)
        case .scaleBody:
            ScalePanel(model: model, close: close)
        case .moveBody:
            MoveBodyPanel(model: model, close: close)
        case .splitBody:
            SplitBodyPanel(model: model, close: close)
        case .measure:
            MeasurePanel(model: model)
        case .pullFace:
            PullFacePanel(model: model, close: close)
        case .filletEdge:
            EdgeFinishPanel(model: model, isFillet: true, source: .pickedEdge, close: close)
        case .chamferEdge:
            EdgeFinishPanel(model: model, isFillet: false, source: .pickedEdge, close: close)
        case .threadShaft:
            ThreadShaftPanel(model: model, close: close)
        case .revolveFace:
            RevolvePanel(model: model, initialSketchID: panelSketchID,
                         generatedSketch: model.pendingRevolveSketch, close: close)
        case .filletFaceEdges:
            EdgeFinishPanel(model: model, isFillet: true, source: .pickedFaceEdges, close: close)
        case .chamferFaceEdges:
            EdgeFinishPanel(model: model, isFillet: false, source: .pickedFaceEdges, close: close)
        }
    }
}

// MARK: - Plane choice (shared by New Sketch and Redefine Plane)

/// The v4 plane picker: a new sketch MUST be placed deliberately —
/// pick a base plane, a datum (construct) plane, or a face of the
/// model. Nothing is chosen until the user taps one; the summary at
/// the bottom always says what is currently selected.
struct PlaneChoiceView: View {
    @ObservedObject var model: EditorModel
    @Binding var choice: PlaneChoice
    /// Enter face-pick mode (the hosting panel supplies its purpose).
    let onPickFace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Base planes")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                planeCard("XY", sub: "facing +Z", selected: choice == .base("XY")) {
                    choice = .base("XY")
                }
                planeCard("XZ", sub: "facing −Y", selected: choice == .base("XZ")) {
                    choice = .base("XZ")
                }
                planeCard("YZ", sub: "facing +X", selected: choice == .base("YZ")) {
                    choice = .base("YZ")
                }
            }
            if !model.datumSketches.isEmpty {
                Text("Datum planes")
                    .mcFont(17, weight: .semibold)
                    .foregroundStyle(.secondary)
                ForEach(model.datumSketches) { datum in
                    Button {
                        choice = .datum(datum.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.on.square")
                                .mcFont(20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(datum.name)
                                    .mcFont(19, weight: .semibold)
                                    .foregroundStyle(.primary)
                                Text(mcPlaneText(datum.plane))
                                    .mcFont(16)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if choice == .datum(datum.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .mcFont(22)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(choice == .datum(datum.id) ? Color.orange.opacity(0.25) : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Or a face of the model")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Button {
                onPickFace()
            } label: {
                Label("Pick a face on the model…", systemImage: "square.on.square.dashed")
                    .mcFont(19, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
            .buttonStyle(.plain)
            HStack(alignment: .top, spacing: 8) {
                Text("Selected:")
                    .mcFont(18, weight: .bold)
                Text(choiceText)
                    .mcFont(18, weight: .semibold)
                    .foregroundStyle(choice == .none ? .orange : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        }
    }

    private func planeCard(_ name: String, sub: String, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: "square.dashed")
                    .mcFont(22)
                Text(name)
                    .mcFont(20, weight: .bold)
                Text(sub)
                    .mcFont(14)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(selected ? .black : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.orange : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var choiceText: String {
        switch choice {
        case .none:
            return "nothing yet — pick a plane or a face above"
        case .base(let name):
            return "\(name) base plane"
        case .datum(let id):
            return model.part?.sketch(id)?.name ?? "datum plane"
        case .face(let face):
            return "model face · \(mcFaceLabel(face))"
        }
    }
}

// MARK: - New Sketch panel (mandatory plane pick)

/// v4: creating a sketch ALWAYS starts here, and Create stays
/// disabled until a base plane, a datum plane, or a model face has
/// been picked — a sketch is never silently dropped on XY.
struct NewSketchPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    let openSketch: (String) -> Void
    let pickFace: (FacePickPurpose) -> Void

    @State private var nameText = ""

    private var choiceBinding: Binding<PlaneChoice> {
        Binding(get: { model.planeChoice }, set: { model.planeChoice = $0 })
    }

    private var resolvedPlane: Plane3? {
        switch model.planeChoice {
        case .none: return nil
        case .base, .face: return model.planeChoice.resolvedPlane
        case .datum(let id): return model.part?.sketch(id)?.plane
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlaneChoiceView(model: model, choice: choiceBinding,
                            onPickFace: { pickFace(.newSketchFace) })
            HStack {
                Text("Name")
                    .mcFont(19, weight: .semibold)
                Spacer()
                TextField("Sketch name", text: $nameText)
                    .mcFont(20, weight: .semibold)
                    .frame(width: 170)
                    .textFieldStyle(.roundedBorder)
            }
            PanelNote(text: "The sketch editor opens on the plane you picked, with the face's outline drawn as a guide when you picked a face.")
            PanelOKBar(okTitle: "Create Sketch", okEnabled: resolvedPlane != nil,
                       onOK: create, onCancel: close)
        }
    }

    private func create() {
        guard let plane = resolvedPlane else { return }
        let name = nameText.isEmpty
            ? "Sketch \((model.part?.sketches.count ?? 0) + 1)"
            : nameText
        let sketch = model.addSketch(plane: plane, name: name)
        if case .face(let face) = model.planeChoice {
            model.faceOutlines[sketch.id] = face.outline2D
        }
        model.planeChoice = .none
        close()
        openSketch(sketch.id)
    }
}

// MARK: - Redefine Plane panel

/// Move an existing sketch onto a different plane (same picker as
/// New Sketch). The sketch's 2D geometry is re-interpreted on the new
/// plane and the part rebuilds — stated plainly in the panel.
struct RedefinePlanePanel: View {
    @ObservedObject var model: EditorModel
    let sketchID: String
    let close: () -> Void
    let pickFace: (FacePickPurpose) -> Void

    private var choiceBinding: Binding<PlaneChoice> {
        Binding(get: { model.redefineChoice }, set: { model.redefineChoice = $0 })
    }

    private var sketch: Sketch? { model.part?.sketch(sketchID) }

    private var resolvedPlane: Plane3? {
        switch model.redefineChoice {
        case .none: return nil
        case .base, .face: return model.redefineChoice.resolvedPlane
        case .datum(let id): return model.part?.sketch(id)?.plane
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sk = sketch {
                PanelNote(text: "“\(sk.name)” currently lies on a plane \(mcPlaneText(sk.plane)).")
            }
            PlaneChoiceView(model: model, choice: choiceBinding,
                            onPickFace: { pickFace(.redefineFace(sketchID)) })
            PanelNote(text: "Redefining re-interprets the same 2D drawing on the new plane and rebuilds the part — features using this sketch follow it.", warning: true)
            PanelOKBar(okTitle: "Redefine", okEnabled: resolvedPlane != nil,
                       onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        guard let plane = resolvedPlane else { return }
        var outline: [Vec2]? = nil
        if case .face(let face) = model.redefineChoice { outline = face.outline2D }
        model.setSketchPlane(id: sketchID, plane: plane, outline: outline)
        model.redefineChoice = .none
        close()
    }
}

// MARK: - Construct panels (datum planes)

/// Source picker shared by the construct panels: a base plane or an
/// existing datum, chosen with a segmented control + menu.
struct DatumSourcePicker: View {
    @ObservedObject var model: EditorModel
    @Binding var sourceIsDatum: Bool
    @Binding var baseName: String
    @Binding var datumID: String

    var sourcePlane: Plane3? {
        if sourceIsDatum {
            return model.part?.sketch(datumID)?.plane
        }
        return baseName == "XZ" ? .xz : (baseName == "YZ" ? .yz : .xy)
    }

    var sourceName: String {
        if sourceIsDatum {
            return model.part?.sketch(datumID)?.name ?? "datum"
        }
        return baseName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.datumSketches.isEmpty {
                Picker("Source", selection: $sourceIsDatum) {
                    Text("Base plane").tag(false)
                    Text("Datum plane").tag(true)
                }
                .pickerStyle(.segmented)
                .mcFont(19, weight: .semibold)
            }
            if sourceIsDatum {
                PanelSketchPicker(label: "Datum plane", sketches: model.datumSketches,
                                  selection: $datumID)
            } else {
                Picker("Base plane", selection: $baseName) {
                    Text("XY").tag("XY")
                    Text("XZ").tag("XZ")
                    Text("YZ").tag("YZ")
                }
                .pickerStyle(.segmented)
                .mcFont(20, weight: .semibold)
            }
        }
    }
}

/// Offset Plane: a datum parallel to a base plane, a datum, or a
/// model face, slid along its normal by the given distance.
struct OffsetPlanePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    let pickFace: (FacePickPurpose) -> Void
    let switchTool: (ActiveTool) -> Void

    @State private var useFace = false
    @State private var sourceIsDatum = false
    @State private var baseName = "XY"
    @State private var datumID = ""
    @State private var distanceText = "10"
    @State private var nameText = ""
    @State private var createdDatumID: String?

    private var sourcePlane: Plane3? {
        if useFace { return model.constructFace?.plane }
        if sourceIsDatum { return model.part?.sketch(datumID)?.plane }
        return baseName == "XZ" ? .xz : (baseName == "YZ" ? .yz : .xy)
    }

    private var sourceName: String {
        if useFace { return "face" }
        if sourceIsDatum { return model.part?.sketch(datumID)?.name ?? "datum" }
        return baseName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Offset from", selection: $useFace) {
                Text("Plane").tag(false)
                Text("Model face").tag(true)
            }
            .pickerStyle(.segmented)
            .mcFont(19, weight: .semibold)
            if useFace {
                if let face = model.constructFace {
                    PanelNote(text: "Face picked: \(mcFaceLabel(face)) · \(mcPlaneText(face.plane))")
                } else {
                    PanelNote(text: "No face picked yet — pick one on the model.", warning: true)
                }
                Button {
                    pickFace(.offsetDatumFace)
                } label: {
                    Label("Pick a face on the model…", systemImage: "square.on.square.dashed")
                        .mcFont(19, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
                .buttonStyle(.plain)
            } else {
                DatumSourcePicker(model: model, sourceIsDatum: $sourceIsDatum,
                                  baseName: $baseName, datumID: $datumID)
            }
            PanelNumberRow(label: "Distance along normal (mm)", text: $distanceText)
            HStack {
                Text("Name")
                    .mcFont(19, weight: .semibold)
                Spacer()
                TextField("Datum name", text: $nameText)
                    .mcFont(20, weight: .semibold)
                    .frame(width: 170)
                    .textFieldStyle(.roundedBorder)
            }
            PanelNote(text: "Creates a datum plane (a ⌖ reference you can sketch on). A negative distance slides it the other way.")
            if let id = createdDatumID {
                Button("Sketch on this datum now") {
                    model.planeChoice = .datum(id)
                    switchTool(.newSketch)
                }
                .mcFont(19, weight: .bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.3)))
            }
            PanelOKBar(okTitle: "Create Datum", okEnabled: sourcePlane != nil,
                       onOK: create, onCancel: close)
        }
        .onAppear {
            if datumID.isEmpty { datumID = model.datumSketches.first?.id ?? "" }
        }
    }

    private func create() {
        guard let src = sourcePlane else { return }
        let d = panelNum(distanceText, fallback: 10)
        let plane = Plane3(origin: src.origin + src.normal * d,
                           xAxis: src.xAxis, yAxis: src.yAxis)
        let fallbackName = "Offset \(sourceName) \(d >= 0 ? "+" : "")\(mcFmt(d))"
        let datum = model.addDatum(plane: plane,
                                   name: nameText.isEmpty ? fallbackName : nameText)
        createdDatumID = datum.id
        nameText = ""
    }
}

/// Plane at Angle: a datum through the source plane's origin,
/// rotated around one of the source plane's own axes.
struct AnglePlanePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    let switchTool: (ActiveTool) -> Void

    @State private var sourceIsDatum = false
    @State private var baseName = "XY"
    @State private var datumID = ""
    @State private var aroundX = true
    @State private var angleText = "45"
    @State private var nameText = ""
    @State private var createdDatumID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatumSourcePicker(model: model, sourceIsDatum: $sourceIsDatum,
                              baseName: $baseName, datumID: $datumID)
            Text("Rotate around")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $aroundX) {
                Text("Plane's X axis").tag(true)
                Text("Plane's Y axis").tag(false)
            }
            .pickerStyle(.segmented)
            .mcFont(19, weight: .semibold)
            PanelNumberRow(label: "Angle (degrees)", text: $angleText)
            HStack {
                Text("Name")
                    .mcFont(19, weight: .semibold)
                Spacer()
                TextField("Datum name", text: $nameText)
                    .mcFont(20, weight: .semibold)
                    .frame(width: 170)
                    .textFieldStyle(.roundedBorder)
            }
            PanelNote(text: "The new datum passes through the source plane's origin, tilted by the angle around the chosen axis.")
            if let id = createdDatumID {
                Button("Sketch on this datum now") {
                    model.planeChoice = .datum(id)
                    switchTool(.newSketch)
                }
                .mcFont(19, weight: .bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.3)))
            }
            PanelOKBar(okTitle: "Create Datum", onOK: create, onCancel: close)
        }
        .onAppear {
            if datumID.isEmpty { datumID = model.datumSketches.first?.id ?? "" }
        }
    }

    private func create() {
        let src: Plane3?
        if sourceIsDatum { src = model.part?.sketch(datumID)?.plane }
        else { src = baseName == "XZ" ? .xz : (baseName == "YZ" ? .yz : .xy) }
        guard let source = src else { return }
        let angle = panelNum(angleText, fallback: 45)
        let plane = mcRotatedPlane(source, aroundXAxis: aroundX, degrees: angle)
        let srcName = sourceIsDatum ? (model.part?.sketch(datumID)?.name ?? "datum") : baseName
        let fallbackName = "Angle \(srcName) \(mcFmt(angle))°"
        let datum = model.addDatum(plane: plane,
                                   name: nameText.isEmpty ? fallbackName : nameText)
        createdDatumID = datum.id
        nameText = ""
    }
}

/// Midplane: a datum exactly halfway between two parallel faces of
/// the model.
struct MidplanePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    let pickFace: (FacePickPurpose) -> Void
    let switchTool: (ActiveTool) -> Void

    @State private var nameText = ""
    @State private var createdDatumID: String?

    private var parallel: Bool {
        guard let a = model.midplaneFaceA, let b = model.midplaneFaceB else { return false }
        return abs(a.plane.normal.dot(b.plane.normal)) > 0.999
    }

    private var ready: Bool { model.midplaneFaceA != nil && model.midplaneFaceB != nil && parallel }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            faceRow("First face", face: model.midplaneFaceA) { pickFace(.midplaneA) }
            faceRow("Second face", face: model.midplaneFaceB) { pickFace(.midplaneB) }
            if model.midplaneFaceA != nil && model.midplaneFaceB != nil && !parallel {
                PanelNote(text: "Those two faces are not parallel — a midplane needs two faces pointing the same way (like the top and bottom of a plate).", warning: true)
            }
            HStack {
                Text("Name")
                    .mcFont(19, weight: .semibold)
                Spacer()
                TextField("Datum name", text: $nameText)
                    .mcFont(20, weight: .semibold)
                    .frame(width: 170)
                    .textFieldStyle(.roundedBorder)
            }
            PanelNote(text: "The datum lands exactly halfway between the two faces, parallel to both.")
            if let id = createdDatumID {
                Button("Sketch on this datum now") {
                    model.planeChoice = .datum(id)
                    switchTool(.newSketch)
                }
                .mcFont(19, weight: .bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.3)))
            }
            PanelOKBar(okTitle: "Create Datum", okEnabled: ready, onOK: create, onCancel: close)
        }
    }

    private func faceRow(_ label: String, face: PlanarFace?,
                         action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            if let face {
                PanelNote(text: "\(mcFaceLabel(face)) · \(mcPlaneText(face.plane))")
            } else {
                PanelNote(text: "Not picked yet.", warning: true)
            }
            Button {
                action()
            } label: {
                Label("Pick on the model…", systemImage: "square.on.square.dashed")
                    .mcFont(19, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
            .buttonStyle(.plain)
        }
    }

    private func create() {
        guard let a = model.midplaneFaceA, let b = model.midplaneFaceB, parallel else { return }
        let mid = (a.centroid + b.centroid) * 0.5
        let plane = Plane3(origin: mid, xAxis: a.plane.xAxis, yAxis: a.plane.yAxis)
        let datum = model.addDatum(plane: plane,
                                   name: nameText.isEmpty ? "Midplane" : nameText)
        createdDatumID = datum.id
        nameText = ""
    }
}

// MARK: - Extrude panel (v4: extrude2 — operation + end condition)

struct ExtrudePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var sketchID: String
    @State private var distanceText = "10"
    @State private var typeChoice = "one"
    @State private var secondText = "10"
    @State private var taperText = "0"
    @State private var operation = "join"
    @State private var endChoice = "dimension"
    @State private var faceIndex = 0

    init(model: EditorModel, initialSketchID: String?, initialOperation: String? = nil,
         close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        let fallback = model.featureSketches.first?.id ?? ""
        _sketchID = State(initialValue: initialSketchID ?? fallback)
        if let initialOperation {
            _operation = State(initialValue: initialOperation)
        }
    }

    private var sketches: [Sketch] { model.featureSketches }

    /// The feature these fields describe — used for BOTH the live
    /// draft preview and the commit, so what you see is what you get.
    private var candidateKind: FeatureKind {
        let mode: ExtrudeMode
        switch typeChoice {
        case "symmetric": mode = .symmetric
        case "twoSided": mode = .twoSided(second: panelNum(secondText, fallback: 10))
        default: mode = .one
        }
        let op: BodyOperation
        switch operation {
        case "cut": op = .cut
        case "intersect": op = .intersect
        case "newBody": op = .newBody
        default: op = .join
        }
        let end: ExtrudeEnd
        switch endChoice {
        case "throughAll": end = .throughAll
        case "upToFace": end = .upToFace(faceIndex: faceIndex)
        default: end = .dimension
        }
        return .extrude2(sketchID: sketchID,
                         distance: panelNum(distanceText, fallback: 10),
                         taperDegrees: panelNum(taperText, fallback: 0),
                         mode: mode, operation: op, end: end)
    }

    private var draftSignature: String {
        "\(sketchID)|\(distanceText)|\(typeChoice)|\(secondText)|\(taperText)|\(operation)|\(endChoice)|\(faceIndex)"
    }

    private func refreshDraft() {
        if sketches.isEmpty { model.setDraft(nil) } else {
            model.draftAppend(Feature(name: "Extrude", kind: candidateKind))
        }
    }

    /// Slider ⇄ text field binding for scrubbing the distance live.
    private var distanceValue: Binding<Double> {
        Binding(get: { panelNum(distanceText, fallback: 10) },
                set: { distanceText = mcFmt($0) })
    }

    /// Faces of the body as built NOW, in the kernel's own order —
    /// the index chosen here is the index ExtrudeEnd.upToFace uses.
    private var faces: [PlanarFace] {
        guard let mesh = model.rebuild?.mesh, mesh.triangleCount > 0 else { return [] }
        return FaceExtractor.planarFaces(of: mesh)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.isEmpty {
                PanelNote(text: "There is no sketch to extrude yet. Create one first — Sketch ▸ New Sketch — then extrude it.", warning: true)
            } else {
                PanelSketchPicker(label: "Profile sketch", sketches: sketches, selection: $sketchID)
            }
            Text("Operation")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Operation", selection: $operation) {
                Text("Join (add)").tag("join")
                Text("Cut (remove)").tag("cut")
                Text("Intersect (keep overlap)").tag("intersect")
                Text("New Body").tag("newBody")
            }
            .pickerStyle(.menu)
            .mcFont(20, weight: .semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("End")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("End", selection: $endChoice) {
                Text("Dimension").tag("dimension")
                Text("Through All").tag("throughAll")
                Text("Up to Face").tag("upToFace")
            }
            .pickerStyle(.segmented)
            .mcFont(19, weight: .semibold)
            if endChoice == "dimension" {
                PanelNumberRow(label: "Distance (mm)", text: $distanceText)
                // Scrub the length and watch the ghost grow/shrink in
                // the 3D view before committing.
                Slider(value: distanceValue, in: 1...200, step: 0.5)
                    .accessibilityLabel("Extrude distance")
            }
            if endChoice == "throughAll" {
                PanelNote(text: "The prism runs past the whole body in the sketch direction — no distance needed.")
            }
            if endChoice == "upToFace" {
                if faces.isEmpty {
                    PanelNote(text: "Up to Face needs an existing body to stop at — there is none yet.", warning: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target face (of the part as built now)")
                            .mcFont(17, weight: .semibold)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $faceIndex) {
                            ForEach(Array(faces.enumerated()), id: \.offset) { i, face in
                                Text("Face \(i + 1) · \(mcFaceLabel(face))").tag(i)
                            }
                        }
                        .pickerStyle(.menu)
                        .mcFont(20, weight: .semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("Type")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Type", selection: $typeChoice) {
                Text("One side").tag("one")
                Text("Symmetric").tag("symmetric")
                Text("Two sides").tag("twoSided")
            }
            .pickerStyle(.segmented)
            if typeChoice == "twoSided" {
                PanelNumberRow(label: "Second distance (mm)", text: $secondText)
            }
            PanelNumberRow(label: "Taper angle (degrees)", text: $taperText)
            if operation == "newBody" {
                PanelNote(text: "New Body keeps this solid separate from the existing body — the part can hold several bodies.")
            }
            PanelDraftError(model: model)
            PanelOKBar(okEnabled: !sketches.isEmpty && (endChoice != "upToFace" || !faces.isEmpty),
                       onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Extrude", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

// MARK: - Revolve panel

struct RevolvePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    /// The generated face-outline sketch from the picked-face bar
    /// ("Revolve Face…"), if this panel was opened that way. Same
    /// pattern as HolePanel's: drafts inject it into the preview
    /// part; Apply commits it with the revolve feature.
    let generatedSketch: Sketch?

    @State private var sketchID: String
    @State private var axisEntityID: Int = 0
    @State private var angleText = "360"

    init(model: EditorModel, initialSketchID: String? = nil,
         generatedSketch: Sketch? = nil, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        self.generatedSketch = generatedSketch
        _sketchID = State(initialValue: generatedSketch?.id
                          ?? initialSketchID
                          ?? model.featureSketches.first?.id ?? "")
    }

    private var sketches: [Sketch] {
        var list = model.featureSketches
        if let gen = generatedSketch, !list.contains(where: { $0.id == gen.id }) {
            list.append(gen)
        }
        return list
    }

    /// True while the generated outline is the chosen profile:
    /// drafts must inject it into the preview part, and Apply
    /// commits it (once) before the revolve feature.
    private var usesGenerated: Bool {
        guard let gen = generatedSketch else { return false }
        return sketchID == gen.id
    }
    private var axisLines: [SketchEntity] {
        (sketches.first { $0.id == sketchID }?.entities ?? []).filter { e in
            if case .line = e { return true }
            return false
        }
    }

    private var candidateKind: FeatureKind {
        .revolve(sketchID: sketchID, axisEntityID: axisEntityID,
                 angleDegrees: panelNum(angleText, fallback: 360))
    }

    private var draftSignature: String { "\(sketchID)|\(axisEntityID)|\(angleText)" }

    private func refreshDraft() {
        if sketches.isEmpty || axisLines.isEmpty {
            model.setDraft(nil)
        } else if usesGenerated, let gen = generatedSketch {
            model.draftAppendWithSketches((model.part?.sketches ?? []) + [gen],
                                          Feature(name: "Revolve", kind: candidateKind))
        } else {
            model.draftAppend(Feature(name: "Revolve", kind: candidateKind))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.isEmpty {
                PanelNote(text: "There is no sketch yet. Create one with a profile and an axis line first.", warning: true)
            } else {
                PanelSketchPicker(label: "Profile sketch", sketches: sketches, selection: $sketchID)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Axis (a line in the sketch)")
                        .mcFont(17, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Picker("Axis", selection: $axisEntityID) {
                        ForEach(axisLines, id: \.id) { e in
                            Text("Line #\(e.id)").tag(e.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .mcFont(20, weight: .semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if axisLines.isEmpty {
                    PanelNote(text: "The chosen sketch has no line to revolve around yet.", warning: true)
                }
                if usesGenerated {
                    PanelNote(text: "The outline sketch “Face revolve (auto)” is created with the revolve. Pick one of its lines as the axis.")
                }
            }
            PanelNumberRow(label: "Angle (degrees)", text: $angleText)
            PanelDraftError(model: model)
            PanelOKBar(okEnabled: !sketches.isEmpty && !axisLines.isEmpty, onOK: apply, onCancel: close)
                .onAppear {
                    if axisEntityID == 0, let first = axisLines.first { axisEntityID = first.id }
                }
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        if usesGenerated, let gen = generatedSketch {
            model.addGeneratedSketch(gen)
        }
        model.appendFeature(name: "Revolve", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

// MARK: - Hole panel

struct HolePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    /// The generated one-point drill sketch from the picked-face bar
    /// ("Hole Here…"), if this panel was opened that way. Drafts with
    /// the sketch injected into the preview part; committed with the
    /// hole on Apply.
    let generatedSketch: Sketch?

    @State private var sketchID: String
    @State private var diameterText = "6"
    @State private var through = true
    @State private var depthText = "10"
    @State private var kindChoice = "simple"
    @State private var cbDiameterText = "10"
    @State private var cbDepthText = "3"
    @State private var csAngleText = "90"

    init(model: EditorModel, initialSketchID: String? = nil,
         generatedSketch: Sketch? = nil, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        self.generatedSketch = generatedSketch
        _sketchID = State(initialValue: generatedSketch?.id
                          ?? initialSketchID
                          ?? model.featureSketches.first?.id ?? "")
    }

    private var sketches: [Sketch] {
        var list = model.featureSketches
        if let gen = generatedSketch, !list.contains(where: { $0.id == gen.id }) {
            list.append(gen)
        }
        return list
    }

    /// True while the generated sketch is the chosen drill pattern:
    /// drafts must inject it into the preview part, and Apply commits
    /// it (once) before the hole feature.
    private var usesGenerated: Bool {
        guard let gen = generatedSketch else { return false }
        return sketchID == gen.id
    }

    private var candidateKind: FeatureKind {
        let hk: HoleKind
        switch kindChoice {
        case "counterbore":
            hk = .counterbore(diameter: panelNum(cbDiameterText, fallback: 10),
                              depth: panelNum(cbDepthText, fallback: 3))
        case "countersink":
            hk = .countersink(angleDegrees: panelNum(csAngleText, fallback: 90))
        default:
            hk = .simple
        }
        return .hole(sketchID: sketchID,
                     diameter: panelNum(diameterText, fallback: 6),
                     depth: through ? 0 : panelNum(depthText, fallback: 10),
                     kind: hk)
    }

    private var draftSignature: String {
        "\(sketchID)|\(diameterText)|\(through)|\(depthText)|\(kindChoice)|\(cbDiameterText)|\(cbDepthText)|\(csAngleText)"
    }

    private func refreshDraft() {
        if sketches.isEmpty {
            model.setDraft(nil)
        } else if usesGenerated, let gen = generatedSketch {
            model.draftAppendWithSketches((model.part?.sketches ?? []) + [gen],
                                          Feature(name: "Hole", kind: candidateKind))
        } else {
            model.draftAppend(Feature(name: "Hole", kind: candidateKind))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.isEmpty {
                PanelNote(text: "There is no sketch yet. Holes drill at the points and circle centers of a sketch.", warning: true)
            } else {
                PanelSketchPicker(label: "Drill-point sketch", sketches: sketches, selection: $sketchID)
            }
            if usesGenerated {
                PanelNote(text: "The drill-point sketch “Hole point (auto)” is created with the hole.")
            }
            PanelNumberRow(label: "Diameter (mm)", text: $diameterText)
            Toggle("Through (all the way)", isOn: $through)
                .mcFont(19, weight: .semibold)
            if !through {
                PanelNumberRow(label: "Depth (mm)", text: $depthText)
            }
            Text("Type")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Type", selection: $kindChoice) {
                Text("Simple").tag("simple")
                Text("Counterbore").tag("counterbore")
                Text("Countersink").tag("countersink")
            }
            .pickerStyle(.segmented)
            if kindChoice == "counterbore" {
                PanelNumberRow(label: "Bore diameter (mm)", text: $cbDiameterText)
                PanelNumberRow(label: "Bore depth (mm)", text: $cbDepthText)
            }
            if kindChoice == "countersink" {
                PanelNumberRow(label: "Sink angle (degrees)", text: $csAngleText)
            }
            PanelDraftError(model: model)
            PanelOKBar(okEnabled: !sketches.isEmpty, onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        if usesGenerated, let gen = generatedSketch {
            model.addGeneratedSketch(gen)
        }
        model.appendFeature(name: "Hole", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

// MARK: - Loft & Sweep panels

struct LoftPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var sketchA: String
    @State private var sketchB: String

    init(model: EditorModel, initialSketchID: String? = nil, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        let all = model.featureSketches
        _sketchA = State(initialValue: initialSketchID ?? all.first?.id ?? "")
        _sketchB = State(initialValue: (all.count > 1 ? all[1] : all.first)?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }

    private var candidateKind: FeatureKind { .loft(sketchA: sketchA, sketchB: sketchB) }

    private var draftSignature: String { "\(sketchA)|\(sketchB)" }

    private func refreshDraft() {
        if sketches.count >= 2 && sketchA != sketchB {
            model.draftAppend(Feature(name: "Loft", kind: candidateKind))
        } else {
            model.setDraft(nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.count < 2 {
                PanelNote(text: "Loft needs two profile sketches on different planes (for example XY offset, or a face sketch). The demo part's sketches all sit on related planes — draw a second profile to blend into.", warning: true)
            }
            PanelSketchPicker(label: "First profile", sketches: sketches, selection: $sketchA)
            PanelSketchPicker(label: "Second profile", sketches: sketches, selection: $sketchB)
            PanelNote(text: "Blends the first closed profile into the second. Both need the same number of corners.")
            PanelDraftError(model: model)
            PanelOKBar(okEnabled: sketches.count >= 2 && sketchA != sketchB, onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Loft", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct SweepPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var profileID: String
    @State private var pathID: String

    init(model: EditorModel, initialSketchID: String? = nil, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        let all = model.featureSketches
        _profileID = State(initialValue: initialSketchID ?? all.first?.id ?? "")
        _pathID = State(initialValue: (all.count > 1 ? all[1] : all.first)?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }

    private var candidateKind: FeatureKind {
        .sweep(profileSketchID: profileID, pathSketchID: pathID)
    }

    private var draftSignature: String { "\(profileID)|\(pathID)" }

    private func refreshDraft() {
        if sketches.count >= 2 && profileID != pathID {
            model.draftAppend(Feature(name: "Sweep", kind: candidateKind))
        } else {
            model.setDraft(nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.count < 2 {
                PanelNote(text: "Sweep needs two sketches: a closed profile and a path made of connected lines.", warning: true)
            }
            PanelSketchPicker(label: "Profile sketch", sketches: sketches, selection: $profileID)
            PanelSketchPicker(label: "Path sketch", sketches: sketches, selection: $pathID)
            PanelNote(text: "The profile is swept along the path's connected lines.")
            PanelDraftError(model: model)
            PanelOKBar(okEnabled: sketches.count >= 2 && profileID != pathID, onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Sweep", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

// MARK: - Primitive panel

struct PrimitivePanel: View {
    @ObservedObject var model: EditorModel
    let kind: PrimitiveKind
    let close: () -> Void

    @State private var values: [String: String]

    init(model: EditorModel, kind: PrimitiveKind, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.kind = kind
        self.close = close
        var d: [String: String] = [:]
        for (k, v) in Self.defaults(kind) { d[k] = mcFmt(v) }
        _values = State(initialValue: d)
    }

    static func defaults(_ kind: PrimitiveKind) -> [String: Double] {
        switch kind {
        case .box: return ["width": 30, "depth": 20, "height": 12]
        case .cylinder: return ["diameter": 20, "height": 25]
        case .sphere: return ["diameter": 24]
        case .cone: return ["diameter": 20, "height": 25]
        case .torus: return ["ringRadius": 15, "tubeRadius": 5]
        }
    }

    static func keys(_ kind: PrimitiveKind) -> [String] {
        switch kind {
        case .box: return ["width", "depth", "height"]
        case .cylinder: return ["diameter", "height"]
        case .sphere: return ["diameter"]
        case .cone: return ["diameter", "height"]
        case .torus: return ["ringRadius", "tubeRadius"]
        }
    }

    static func label(_ key: String) -> String {
        switch key {
        case "width": return "Width (mm)"
        case "depth": return "Depth (mm)"
        case "height": return "Height (mm)"
        case "diameter": return "Diameter (mm)"
        case "ringRadius": return "Ring radius (mm)"
        case "tubeRadius": return "Tube radius (mm)"
        default: return key
        }
    }

    private var candidateKind: FeatureKind {
        var params: [String: Double] = [:]
        for key in Self.keys(kind) {
            params[key] = panelNum(values[key] ?? "", fallback: Self.defaults(kind)[key] ?? 10)
        }
        return .primitive(kind: kind, params: params)
    }

    private var candidateName: String {
        switch kind {
        case .box: return "Box"
        case .cylinder: return "Cylinder"
        case .sphere: return "Sphere"
        case .cone: return "Cone"
        case .torus: return "Torus"
        }
    }

    private var draftSignature: String {
        Self.keys(kind).map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "|")
    }

    private func refreshDraft() {
        model.draftAppend(Feature(name: candidateName, kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.keys(kind), id: \.self) { key in
                PanelNumberRow(label: Self.label(key), text: binding(for: key))
            }
            PanelNote(text: "Built at the origin: boxes and cylinders rise from the XY plane, spheres and toruses are centered on it.")
            PanelDraftError(model: model)
            PanelOKBar(okTitle: "Create", onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func apply() {
        model.appendFeature(name: candidateName, kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

// MARK: - Fillet panel (with live edge count + FT408 guidance)

struct FilletPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var radiusText = "2"
    @State private var createdFeatureID: String?
    @State private var tooLargeMax: Double?
    @State private var sharpEdgeCount: Int?

    private var candidateKind: FeatureKind {
        .fillet(radius: panelNum(radiusText, fallback: 2))
    }

    /// Before OK the draft is an appended fillet; once the panel has
    /// created its feature (the FT408 stay-open flow), the draft
    /// replaces that feature in place instead.
    private func refreshDraft() {
        if let id = createdFeatureID,
           let idx = model.part?.features.firstIndex(where: { $0.id == id }) {
            model.draftReplacing(index: idx,
                                 with: Feature(id: id, name: "Fillet", kind: candidateKind))
        } else {
            model.draftAppend(Feature(name: "Fillet", kind: candidateKind))
        }
    }

    /// Slider ⇄ text field binding for scrubbing the radius live.
    private var radiusValue: Binding<Double> {
        Binding(get: { panelNum(radiusText, fallback: 2) },
                set: { radiusText = mcFmt($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Radius (mm)", text: $radiusText)
            Slider(value: radiusValue, in: 0.5...20, step: 0.5)
                .accessibilityLabel("Fillet radius")
            if let n = sharpEdgeCount {
                PanelNote(text: "The body built so far has \(n) sharp edge\(n == 1 ? "" : "s") — a fillet rounds all of them.")
            } else {
                PanelNote(text: "No solid yet — a fillet needs a body to round.")
            }
            if let maxF = tooLargeMax {
                PanelNote(text: "That radius is too big here — the largest that fits is ≈ \(mcFmt(maxF)) mm. (MCAD-FT408)", warning: true)
                Button("Use ≈ \(mcFmt(maxF)) mm and apply") {
                    radiusText = mcFmt(maxF)
                    apply()
                }
                .mcFont(19, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
            }
            PanelDraftError(model: model)
            PanelOKBar(okTitle: createdFeatureID == nil ? "OK" : "Apply", onOK: apply, onCancel: close)
        }
        .onAppear {
            if let mesh = model.rebuild?.mesh, mesh.triangleCount > 0 {
                sharpEdgeCount = SolidEdgeExtractor.edges(of: mesh).count
            }
            refreshDraft()
        }
        .onChange(of: radiusText) { _, _ in refreshDraft() }
    }

    private func apply() {
        let radius = panelNum(radiusText, fallback: 2)
        let id: String
        if let existing = createdFeatureID {
            model.updateFeature(id: existing, name: "Fillet", kind: .fillet(radius: radius))
            id = existing
        } else {
            let f = model.appendFeature(name: "Fillet", kind: .fillet(radius: radius))
            createdFeatureID = f.id
            id = f.id
        }
        // If the kernel says the radius cannot fit, stay open and show
        // the largest feasible radius straight from MCAD-FT408.
        if let st = model.status(for: id), !st.ok, st.errorCode == "MCAD-FT408",
           let err = model.rebuild?.firstError,
           case .filletRadiusTooLarge(_, let maxFeasible) = err {
            tooLargeMax = maxFeasible
            refreshDraft()
            return
        }
        model.setDraft(nil)
        close()
    }
}

// MARK: - Chamfer / Shell / Mirror / Pattern panels

struct ChamferPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var modeChoice = "equal"
    @State private var distanceText = "2"
    @State private var distanceBText = "1"
    @State private var angleText = "45"

    private var candidateKind: FeatureKind {
        let mode: ChamferMode
        switch modeChoice {
        case "two":
            mode = .twoDistances(panelNum(distanceText, fallback: 2),
                                 panelNum(distanceBText, fallback: 1))
        case "angle":
            mode = .distanceAngle(panelNum(distanceText, fallback: 2),
                                  panelNum(angleText, fallback: 45))
        default:
            mode = .equal(panelNum(distanceText, fallback: 2))
        }
        return .chamfer2(mode: mode)
    }

    private var draftSignature: String { "\(modeChoice)|\(distanceText)|\(distanceBText)|\(angleText)" }

    private func refreshDraft() {
        model.draftAppend(Feature(name: "Chamfer", kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mode")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Mode", selection: $modeChoice) {
                Text("Equal").tag("equal")
                Text("Two distances").tag("two")
                Text("Distance + Angle").tag("angle")
            }
            .pickerStyle(.segmented)
            .mcFont(18, weight: .semibold)
            if modeChoice == "equal" {
                PanelNumberRow(label: "Distance (mm)", text: $distanceText)
                PanelNote(text: "Cuts a flat 45° bevel across every sharp edge of the body built so far, this far back along both faces.")
            } else if modeChoice == "two" {
                PanelNumberRow(label: "Distance A (mm)", text: $distanceText)
                PanelNumberRow(label: "Distance B (mm)", text: $distanceBText)
                PanelNote(text: "An uneven bevel: this far back along the first face of each edge, and distance B along the second.")
            } else {
                PanelNumberRow(label: "Distance (mm)", text: $distanceText)
                PanelNumberRow(label: "Angle (degrees)", text: $angleText)
                PanelNote(text: "The bevel runs this far along the first face of each edge, tilted at the angle from that face.")
            }
            PanelDraftError(model: model)
            PanelOKBar(onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Chamfer", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct ShellPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var thicknessText = "2"

    private var candidateKind: FeatureKind {
        .shell(thickness: panelNum(thicknessText, fallback: 2))
    }

    private func refreshDraft() {
        model.draftAppend(Feature(name: "Shell", kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Wall thickness (mm)", text: $thicknessText)
            PanelNote(text: "Hollows the body built so far, leaving walls of this thickness — like turning a block into an open box.")
            PanelDraftError(model: model)
            PanelOKBar(onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: thicknessText) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Shell", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct MirrorPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var plane: MirrorPlane = .yz

    private var candidateKind: FeatureKind { .mirror(plane: plane) }

    private func refreshDraft() {
        model.draftAppend(Feature(name: "Mirror", kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mirror plane")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Plane", selection: $plane) {
                ForEach(MirrorPlane.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            PanelNote(text: "Duplicates the body built so far, mirrored across the chosen base plane, and joins the two halves.")
            PanelDraftError(model: model)
            PanelOKBar(onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: plane) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Mirror", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct PatternPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var count = 3
    @State private var spacingX = "15"
    @State private var spacingY = "0"
    @State private var spacingZ = "0"

    private var candidateKind: FeatureKind {
        .linearPattern(count: count,
                       spacing: Vec3(panelNum(spacingX, fallback: 15),
                                     panelNum(spacingY, fallback: 0),
                                     panelNum(spacingZ, fallback: 0)))
    }

    private var draftSignature: String { "\(count)|\(spacingX)|\(spacingY)|\(spacingZ)" }

    private func refreshDraft() {
        model.draftAppend(Feature(name: "Linear Pattern", kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("Copies: \(count)", value: $count, in: 1...24)
                .mcFont(20, weight: .semibold)
            PanelNumberRow(label: "Spacing X (mm)", text: $spacingX)
            PanelNumberRow(label: "Spacing Y (mm)", text: $spacingY)
            PanelNumberRow(label: "Spacing Z (mm)", text: $spacingZ)
            PanelNote(text: "Repeats the whole body built so far — copy 1 is the original, each next copy steps by the spacing.")
            PanelDraftError(model: model)
            PanelOKBar(onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Linear Pattern", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

// MARK: - v4 Create panels (Coil / Pipe / Rib)

struct CoilPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var radiusText = "15"
    @State private var pitchText = "8"
    @State private var turnsText = "5"
    @State private var wireText = "2"

    private var candidateKind: FeatureKind {
        .coil(radius: panelNum(radiusText, fallback: 15),
              pitch: panelNum(pitchText, fallback: 8),
              turns: panelNum(turnsText, fallback: 5),
              wireRadius: panelNum(wireText, fallback: 2))
    }

    private var draftSignature: String { "\(radiusText)|\(pitchText)|\(turnsText)|\(wireText)" }

    private func refreshDraft() {
        model.draftAppend(Feature(name: "Coil", kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Coil radius (mm)", text: $radiusText)
            PanelNumberRow(label: "Pitch (mm / turn)", text: $pitchText)
            PanelNumberRow(label: "Turns", text: $turnsText)
            PanelNumberRow(label: "Wire radius (mm)", text: $wireText)
            PanelNote(text: "A spring: wire wound in a helix. It starts at the origin and winds around the Z axis, rising by the pitch each turn.")
            PanelDraftError(model: model)
            PanelOKBar(okTitle: "Create", onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Coil", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct PipePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var pathID: String
    @State private var radiusText = "4"

    init(model: EditorModel, initialSketchID: String? = nil, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        _pathID = State(initialValue: initialSketchID ?? model.featureSketches.first?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }

    private var candidateKind: FeatureKind {
        .pipe(pathSketchID: pathID, radius: panelNum(radiusText, fallback: 4))
    }

    private var draftSignature: String { "\(pathID)|\(radiusText)" }

    private func refreshDraft() {
        if sketches.isEmpty { model.setDraft(nil) } else {
            model.draftAppend(Feature(name: "Pipe", kind: candidateKind))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.isEmpty {
                PanelNote(text: "There is no sketch yet. A pipe follows a path sketch — a chain of connected lines.", warning: true)
            } else {
                PanelSketchPicker(label: "Path sketch", sketches: sketches, selection: $pathID)
            }
            PanelNumberRow(label: "Pipe radius (mm)", text: $radiusText)
            PanelNote(text: "A round tube swept along the path — the profile is automatic, perpendicular to the path's start.")
            PanelDraftError(model: model)
            PanelOKBar(okEnabled: !sketches.isEmpty, onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Pipe", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct RibPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var sketchID: String
    @State private var thicknessText = "3"
    @State private var depthText = "12"

    init(model: EditorModel, initialSketchID: String? = nil, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        _sketchID = State(initialValue: initialSketchID ?? model.featureSketches.first?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }

    private var candidateKind: FeatureKind {
        .rib(sketchID: sketchID,
             thickness: panelNum(thicknessText, fallback: 3),
             depth: panelNum(depthText, fallback: 12))
    }

    private var draftSignature: String { "\(sketchID)|\(thicknessText)|\(depthText)" }

    private func refreshDraft() {
        if sketches.isEmpty { model.setDraft(nil) } else {
            model.draftAppend(Feature(name: "Rib", kind: candidateKind))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.isEmpty {
                PanelNote(text: "There is no sketch yet. A rib grows from an open profile line drawn where the wall should stand.", warning: true)
            } else {
                PanelSketchPicker(label: "Profile sketch", sketches: sketches, selection: $sketchID)
            }
            PanelNumberRow(label: "Thickness (mm)", text: $thicknessText)
            PanelNumberRow(label: "Depth into body (mm)", text: $depthText)
            PanelNote(text: "A thin reinforcing wall grown from the profile line, extending toward the body. It is trimmed approximately at curved surfaces — exact against flat ones.")
            PanelDraftError(model: model)
            PanelOKBar(okEnabled: !sketches.isEmpty, onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Rib", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

// MARK: - v4 Modify panels (Circular Pattern / Draft / Scale / Move / Split)

struct CircularPatternPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var count = 6
    @State private var axis = 2
    @State private var totalText = "360"

    private var candidateKind: FeatureKind {
        .circularPattern(count: count, axis: axis,
                         totalDegrees: panelNum(totalText, fallback: 360))
    }

    private var draftSignature: String { "\(count)|\(axis)|\(totalText)" }

    private func refreshDraft() {
        model.draftAppend(Feature(name: "Circular Pattern", kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("Copies: \(count)", value: $count, in: 2...36)
                .mcFont(20, weight: .semibold)
            Text("Around axis")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $axis) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .mcFont(20, weight: .semibold)
            PanelNumberRow(label: "Total angle (degrees)", text: $totalText)
            PanelNote(text: "Repeats the whole body built so far around the axis through the body's center — copy 1 is the original; 360° spreads the copies evenly all the way around.")
            PanelDraftError(model: model)
            PanelOKBar(onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Circular Pattern", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct DraftPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var angleText = "3"
    @State private var axis = 2

    private var candidateKind: FeatureKind {
        .draftBody(angleDegrees: panelNum(angleText, fallback: 3), pullAxis: axis)
    }

    private var draftSignature: String { "\(angleText)|\(axis)" }

    private func refreshDraft() {
        model.draftAppend(Feature(name: "Draft", kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Angle (degrees)", text: $angleText)
            Text("Pull axis")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $axis) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .mcFont(20, weight: .semibold)
            PanelNote(text: "Mold-release taper: a positive angle narrows the body toward the top of the pull axis, measured from its base. Between −30° and 30°.")
            PanelDraftError(model: model)
            PanelOKBar(onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Draft", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct ScalePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var fx = "1"
    @State private var fy = "1"
    @State private var fz = "1"
    @State private var uniform = true

    private var candidateKind: FeatureKind {
        .scaleBody(factors: Vec3(panelNum(fx, fallback: 1),
                                 panelNum(fy, fallback: 1),
                                 panelNum(fz, fallback: 1)))
    }

    private var draftSignature: String { "\(fx)|\(fy)|\(fz)" }

    private func refreshDraft() {
        model.draftAppend(Feature(name: "Scale", kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Uniform (same factor on all axes)", isOn: $uniform)
                .mcFont(19, weight: .semibold)
            PanelNumberRow(label: "Factor X", text: $fx)
                .onChange(of: fx) { _, newValue in
                    if uniform { fy = newValue; fz = newValue }
                }
            if !uniform {
                PanelNumberRow(label: "Factor Y", text: $fy)
                PanelNumberRow(label: "Factor Z", text: $fz)
            }
            PanelNote(text: "Scales the body built so far about its center — 2 doubles every size, 0.5 halves it.")
            PanelDraftError(model: model)
            PanelOKBar(onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Scale", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct MoveBodyPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var tx = "10"
    @State private var ty = "0"
    @State private var tz = "0"
    @State private var axis = 2
    @State private var degreesText = "0"

    private var candidateKind: FeatureKind {
        .moveBody(translation: Vec3(panelNum(tx, fallback: 0),
                                    panelNum(ty, fallback: 0),
                                    panelNum(tz, fallback: 0)),
                  rotationAxis: axis,
                  rotationDegrees: panelNum(degreesText, fallback: 0))
    }

    private var draftSignature: String { "\(tx)|\(ty)|\(tz)|\(axis)|\(degreesText)" }

    private func refreshDraft() {
        model.draftAppend(Feature(name: "Move Body", kind: candidateKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Move X (mm)", text: $tx)
            PanelNumberRow(label: "Move Y (mm)", text: $ty)
            PanelNumberRow(label: "Move Z (mm)", text: $tz)
            Text("Then rotate around")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $axis) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .mcFont(20, weight: .semibold)
            PanelNumberRow(label: "Rotation (degrees)", text: $degreesText)
            PanelNote(text: "Moves the whole body built so far, then rotates it around the chosen axis through its center. Rotation 0 just moves it.")
            PanelDraftError(model: model)
            PanelOKBar(onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        model.appendFeature(name: "Move Body", kind: candidateKind)
        model.setDraft(nil)
        close()
    }
}

struct SplitBodyPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var axis = 2
    @State private var offsetText = "0"

    private var bounds: BoundingBox? {
        guard let mesh = model.rebuild?.mesh, mesh.triangleCount > 0 else { return nil }
        return mesh.bounds
    }

    private func extent(_ b: BoundingBox) -> (lo: Double, hi: Double) {
        switch axis {
        case 0: return (b.min.x, b.max.x)
        case 1: return (b.min.y, b.max.y)
        default: return (b.min.z, b.max.z)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Split across axis")
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $axis) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .mcFont(20, weight: .semibold)
            if let b = bounds {
                let e = extent(b)
                if e.hi - e.lo > 0.02 {
                    Slider(value: offsetBinding(e), in: (e.lo + 0.01)...(e.hi - 0.01))
                    PanelNote(text: "Body spans \(mcFmt(e.lo)) … \(mcFmt(e.hi)) mm on this axis — the cut lands at the offset.")
                }
            } else {
                PanelNote(text: "No solid yet — a split needs a body to cut in two.", warning: true)
            }
            PanelNumberRow(label: "Offset (mm, world)", text: $offsetText)
            PanelNote(text: "Cuts the body built so far into two bodies at a plane perpendicular to the axis. Both halves stay in the part.")
            PanelOKBar(okEnabled: bounds != nil, onOK: apply, onCancel: close)
        }
    }

    private func offsetBinding(_ e: (lo: Double, hi: Double)) -> Binding<Double> {
        Binding(
            get: { min(max(panelNum(offsetText, fallback: (e.lo + e.hi) / 2), e.lo + 0.01), e.hi - 0.01) },
            set: { offsetText = mcFmt($0) }
        )
    }

    private func apply() {
        model.appendFeature(name: "Split Body",
                            kind: .splitBody(axis: axis,
                                             offset: panelNum(offsetText, fallback: 0)))
        close()
    }
}

// MARK: - Selection-first panels (opened from the picked-action bar)

/// Build the drill-point sketch for Face → "Hole Here…": one point on
/// the face's plane, exactly under the tapped spot (plane-local
/// coordinates). The Hole panel drafts with it and commits it with
/// the hole.
func mcHolePointSketch(face: PlanarFace, point: Vec3) -> Sketch {
    let plane = face.plane
    let rel = point - plane.origin
    var sketch = Sketch(name: "Hole point (auto)", plane: plane)
    sketch.addPoint(Vec2(rel.dot(plane.xAxis), rel.dot(plane.yAxis)))
    return sketch
}

/// Build the outline sketch for a face pull/press. Join: the face
/// outline on the face's own plane, extruded outward along the face
/// normal. Cut: the SAME outline on a flipped plane (axes swapped →
/// normal points INTO the body), so a one-sided extrude cuts inward.
/// Shared by the "Pull Face…" panel and the quick press/pull mode;
/// only the committed sketch NAME differs between them.
func mcFacePullSketch(id: String, face: PlanarFace, cut: Bool,
                      name: String = "Face pull (auto)") -> Sketch {
    let points = dropCollinear(face.outline2D)
    let plane: Plane3
    let outline: [Vec2]
    if cut {
        plane = Plane3(origin: face.plane.origin,
                       xAxis: face.plane.yAxis, yAxis: face.plane.xAxis)
        outline = points.map { Vec2($0.y, $0.x) }
    } else {
        plane = face.plane
        outline = points
    }
    var sketch = Sketch(id: id, name: name, plane: plane)
    guard outline.count >= 3 else { return sketch }
    for i in outline.indices {
        sketch.addLine(outline[i], outline[(i + 1) % outline.count])
    }
    return sketch
}

/// The extrude2 kind for a face pull/press on the sketch built by
/// `mcFacePullSketch`: one-sided, no taper, Dimension end — join
/// adds material outward along the face normal, cut presses inward
/// (via the flipped-plane sketch). THE single implementation: the
/// Pull Face panel and the quick press/pull mode both build their
/// draft and committed features through here, so the same inputs
/// always produce the same feature.
func mcFacePullKind(sketchID: String, distance: Double, cut: Bool) -> FeatureKind {
    .extrude2(sketchID: sketchID,
              distance: distance,
              taperDegrees: 0,
              mode: .one,
              operation: cut ? .cut : .join,
              end: .dimension)
}

/// Pull a picked face straight out (or cut it straight in) along its
/// normal. The feature is an extrude2 on a generated outline sketch
/// of the face; drafts inject the (not yet committed) sketch into the
/// preview part, and Apply commits the sketch + feature together.
struct PullFacePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    /// The face picked when the panel was opened (snapshot).
    private let face: PlanarFace?
    /// Stable id for the generated outline sketch (created once for
    /// the life of the panel — NOT regenerated per view update).
    @State private var scratchID: String = UUID().uuidString
    @State private var distanceText: String = "10"
    @State private var operation: String = "join"

    init(model: EditorModel, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        if case .face(_, let f, _) = model.picked { face = f } else { face = nil }
    }

    private var candidateSketch: Sketch? {
        guard let face else { return nil }
        return mcFacePullSketch(id: scratchID, face: face, cut: operation == "cut")
    }

    private var candidateKind: FeatureKind? {
        guard candidateSketch != nil else { return nil }
        return mcFacePullKind(sketchID: scratchID,
                              distance: panelNum(distanceText, fallback: 10),
                              cut: operation == "cut")
    }

    private var draftSignature: String { "\(distanceText)|\(operation)" }

    private func refreshDraft() {
        guard let kind = candidateKind, let sketch = candidateSketch else {
            model.setDraft(nil)
            return
        }
        model.draftAppendWithSketches((model.part?.sketches ?? []) + [sketch],
                                      Feature(name: "Face pull", kind: kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if face == nil {
                PanelNote(text: "No face is selected. Tap a flat face of the model, then choose Pull Face.", warning: true)
            } else {
                Text("Direction")
                    .mcFont(17, weight: .semibold)
                    .foregroundStyle(.secondary)
                Picker("Direction", selection: $operation) {
                    Text("Out (add)").tag("join")
                    Text("In (cut)").tag("cut")
                }
                .pickerStyle(.segmented)
                PanelNumberRow(label: "Distance (mm)", text: $distanceText)
                Slider(value: Binding(
                    get: { min(max(panelNum(distanceText, fallback: 10), 1), 200) },
                    set: { distanceText = mcFmt($0) }
                ), in: 1...200, step: 0.5)
                PanelNote(text: "The preview shows the result live. The face outline is saved as a sketch named “Face pull (auto)” when you tap OK.")
                PanelDraftError(model: model)
            }
            PanelOKBar(okEnabled: candidateKind != nil && panelNum(distanceText, fallback: 0) > 0,
                       onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        guard let kind = candidateKind, let sketch = candidateSketch else { return }
        model.addGeneratedSketch(sketch)
        model.appendFeature(name: "Face pull", kind: kind)
        model.setDraft(nil)
        close()
    }
}

// MARK: - Edge finish panels (one edge / a face's edges)

/// Which edges an EdgeFinishPanel acts on: just the single tapped
/// edge, or every sharp edge bounding the tapped face.
enum EdgeFinishSource {
    case pickedEdge
    case pickedFaceEdges
}

/// Closest point on triangle abc to point p (Ericson's
/// closest-point-on-triangle region tests).
func mcClosestPointOnTriangle(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Vec3 {
    let ab = b - a
    let ac = c - a
    let ap = p - a
    let d1 = ab.dot(ap)
    let d2 = ac.dot(ap)
    if d1 <= 0 && d2 <= 0 { return a }
    let bp = p - b
    let d3 = ab.dot(bp)
    let d4 = ac.dot(bp)
    if d3 >= 0 && d4 <= d3 { return b }
    let vc = d1 * d4 - d3 * d2
    if vc <= 0 && d1 >= 0 && d3 <= 0 {
        return a + ab * (d1 / (d1 - d3))
    }
    let cp = p - c
    let d5 = ab.dot(cp)
    let d6 = ac.dot(cp)
    if d6 >= 0 && d5 <= d6 { return c }
    let vb = d5 * d2 - d1 * d6
    if vb <= 0 && d2 >= 0 && d6 <= 0 {
        return a + ac * (d2 / (d2 - d6))
    }
    let va = d3 * d6 - d5 * d4
    if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
        let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return b + (c - b) * w
    }
    let denom = 1.0 / (va + vb + vc)
    return a + ab * (vb * denom) + ac * (vc * denom)
}

/// Distance from a point to the nearest point of a triangle.
func mcPointTriangleDistance(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
    p.distance(to: mcClosestPointOnTriangle(p, a, b, c))
}

/// Midpoints of the sharp edges that bound one face of the result
/// mesh. The face's triangles come from FaceExtractor.groupedFaces —
/// the same call the tap resolver used, so the stored face index
/// addresses the same list — and a SolidEdge belongs to the face
/// when its midpoint lies within 1.0 mm of any of those triangles
/// (a bounding edge's midpoint sits ON the face, so this also
/// catches edges whose triangles were re-split by CSG).
func mcFaceEdgeMidpoints(faceIndex: Int, mesh: Mesh) -> [Vec3] {
    let grouped = FaceExtractor.groupedFaces(of: mesh)
    guard grouped.triangles.indices.contains(faceIndex) else { return [] }
    let welded = grouped.mesh
    var tris: [(Vec3, Vec3, Vec3)] = []
    for t in grouped.triangles[faceIndex] {
        tris.append((welded.vertices[Int(welded.indices[t * 3])],
                     welded.vertices[Int(welded.indices[t * 3 + 1])],
                     welded.vertices[Int(welded.indices[t * 3 + 2])]))
    }
    guard !tris.isEmpty else { return [] }
    var mids: [Vec3] = []
    for edge in SolidEdgeExtractor.edges(of: mesh) {
        if tris.contains(where: { mcPointTriangleDistance(edge.mid, $0.0, $0.1, $0.2) <= 1.0 }) {
            mids.append(edge.mid)
        }
    }
    return mids
}

/// Fillet or chamfer a FIXED set of edges, chosen by midpoint —
/// one view for all four selection-first finishes: the single
/// tapped edge ("Fillet/Chamfer This Edge") and every edge
/// bounding the tapped face ("Fillet/Chamfer Face Edges"). The
/// ribbon Fillet/Chamfer panels stay all-edges; this one never
/// touches an edge outside its midpoint list.
struct EdgeFinishPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    let isFillet: Bool

    private let midpoints: [Vec3]
    private let note: String?
    private let emptyText: String
    private let featureName: String

    @State private var valueText: String = "2"

    init(model: EditorModel, isFillet: Bool, source: EdgeFinishSource,
         close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        self.isFillet = isFillet
        switch source {
        case .pickedEdge:
            featureName = isFillet ? "Fillet edge" : "Chamfer edge"
            emptyText = "No edge is selected. Tap an edge of the model, then choose \(isFillet ? "Fillet" : "Chamfer") This Edge."
            if case .edge(let mid, _, _, let len) = model.picked {
                midpoints = [mid]
                note = "Edge length \(mcFmt(len)) mm — only this edge is \(isFillet ? "filleted" : "chamfered")."
            } else {
                midpoints = []
                note = nil
            }
        case .pickedFaceEdges:
            featureName = isFillet ? "Fillet face edges" : "Chamfer face edges"
            emptyText = "No face edges were found. Tap a flat face of the model, then choose \(isFillet ? "Fillet" : "Chamfer") Face Edges."
            if case .face(let idx, _, _) = model.picked, let mesh = model.rebuild?.mesh {
                let mids = mcFaceEdgeMidpoints(faceIndex: idx, mesh: mesh)
                midpoints = mids
                note = mids.isEmpty ? nil
                    : "\(mids.count) edge\(mids.count == 1 ? "" : "s") around the selected face will be \(isFillet ? "filleted" : "chamfered") — no other edge is touched."
            } else {
                midpoints = []
                note = nil
            }
        }
    }

    private var candidateKind: FeatureKind? {
        guard !midpoints.isEmpty else { return nil }
        let v = panelNum(valueText, fallback: 2)
        return isFillet ? .filletEdges(radius: v, midpoints: midpoints)
                        : .chamferEdges(distance: v, midpoints: midpoints)
    }

    private func refreshDraft() {
        guard let kind = candidateKind else { model.setDraft(nil); return }
        model.draftAppend(Feature(name: featureName, kind: kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if midpoints.isEmpty {
                PanelNote(text: emptyText, warning: true)
            } else {
                if let note {
                    PanelNote(text: note)
                }
                PanelNumberRow(label: isFillet ? "Radius (mm)" : "Distance (mm)", text: $valueText)
                Slider(value: Binding(
                    get: { min(max(panelNum(valueText, fallback: 2), 0.5), 20) },
                    set: { valueText = mcFmt($0) }
                ), in: 0.5...20, step: 0.25)
                PanelDraftError(model: model)
            }
            PanelOKBar(okEnabled: candidateKind != nil && panelNum(valueText, fallback: 0) > 0,
                       onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: valueText) { _, _ in refreshDraft() }
    }

    private func apply() {
        guard let kind = candidateKind else { return }
        model.appendFeature(name: featureName, kind: kind)
        model.setDraft(nil)
        close()
    }
}

/// Cut threads onto exactly the picked shaft. The fields mirror the
/// feature editor's thread editor; the spec is prefilled from the
/// fitted cylinder: a preset within 2% of the shaft diameter wins
/// (keeping its pitch), otherwise major = the measured diameter and
/// the pitch comes from the nearest smaller preset.
struct ThreadShaftPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    private let fit: CylinderFit?

    @State private var spec: ThreadSpec
    @State private var presetName: String
    @State private var majorText: String
    @State private var pitchText: String
    @State private var threadLengthText: String
    @State private var profileAngleText: String
    @State private var taperText: String
    @State private var clearanceText: String

    private static let presetNames = ["M3", "M4", "M5", "M6", "M8", "M10", "M12", "M16", "M20",
                                      "1/4-20", "5/16-18", "3/8-16", "1/2-13",
                                      "NPT 1/4", "NPT 3/8", "NPT 1/2"]
    private static let standards: [ThreadStandard] = [.isoMetric, .unc, .npt, .custom]
    private static let kinds: [ThreadKind] = [.external, .internal]
    private static let hands: [ThreadHand] = [.right, .left]

    init(model: EditorModel, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        var fitted: CylinderFit? = nil
        if case .shaft(let f) = model.picked { fitted = f }
        fit = fitted
        var prefilled = ThreadSpec()
        var preset = ""
        if let f = fitted {
            let diameter = f.radius * 2
            prefilled = Self.prefillSpec(diameter: diameter, length: f.height)
            preset = prefilled.presetName(diameter: diameter)
        }
        _spec = State(initialValue: prefilled)
        _presetName = State(initialValue: preset)
        _majorText = State(initialValue: mcFmt(prefilled.majorDiameter))
        _pitchText = State(initialValue: mcFmt(prefilled.pitch))
        _threadLengthText = State(initialValue: mcFmt(prefilled.length))
        _profileAngleText = State(initialValue: mcFmt(prefilled.profileAngleDegrees))
        _taperText = State(initialValue: mcFmt(prefilled.taperDegrees))
        _clearanceText = State(initialValue: mcFmt(prefilled.clearance))
    }

    /// Prefill rule: the first preset (list order) whose major
    /// diameter is within 2% of the shaft's measured diameter wins,
    /// keeping its pitch; otherwise a custom external spec with
    /// major = measured diameter and the pitch of the nearest
    /// smaller preset. Length = the shaft's height either way.
    private static func prefillSpec(diameter: Double, length: Double) -> ThreadSpec {
        var bestSmaller: ThreadSpec?
        for name in presetNames {
            guard let p = try? ThreadSpec.preset(name) else { continue }
            if abs(p.majorDiameter - diameter) <= 0.02 * diameter {
                var match = p
                match.kind = .external
                match.length = length
                return match
            }
            if p.majorDiameter < diameter,
               bestSmaller == nil || p.majorDiameter > bestSmaller!.majorDiameter {
                bestSmaller = p
            }
        }
        var custom = ThreadSpec()
        custom.kind = .external
        custom.majorDiameter = diameter
        custom.pitch = bestSmaller?.pitch ?? 1.5
        if let smaller = bestSmaller { custom.standard = smaller.standard }
        custom.length = length
        return custom
    }

    private func applyPreset(_ name: String) {
        guard let p = try? ThreadSpec.preset(name) else { return }
        spec = p
        spec.kind = .external
        majorText = mcFmt(p.majorDiameter)
        pitchText = mcFmt(p.pitch)
        taperText = mcFmt(p.taperDegrees)
    }

    private var previewSpec: ThreadSpec {
        var s = spec
        s.majorDiameter = panelNum(majorText, fallback: s.majorDiameter)
        s.pitch = panelNum(pitchText, fallback: s.pitch)
        s.length = panelNum(threadLengthText, fallback: s.length)
        s.profileAngleDegrees = panelNum(profileAngleText, fallback: s.profileAngleDegrees)
        s.taperDegrees = panelNum(taperText, fallback: s.taperDegrees)
        s.clearance = panelNum(clearanceText, fallback: s.clearance)
        return s
    }

    private var candidateKind: FeatureKind? {
        guard let fit else { return nil }
        return .threadOnShaft(spec: previewSpec, origin: fit.origin, axis: fit.axis)
    }

    private var draftSignature: String {
        [presetName, majorText, pitchText, threadLengthText, profileAngleText,
         taperText, clearanceText, "\(spec.standard)", "\(spec.kind)", "\(spec.hand)",
         "\(spec.starts)", "\(spec.modeled)"].joined(separator: "|")
    }

    private func refreshDraft() {
        guard let kind = candidateKind else { model.setDraft(nil); return }
        model.draftAppend(Feature(name: "Thread", kind: kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let fit {
                PanelNote(text: "Picked shaft: Ø \(mcFmt(fit.radius * 2)) × \(mcFmt(fit.height)) mm long. The thread starts at the shaft's low end and runs along its axis.")
                Picker("Preset", selection: $presetName) {
                    Text("Custom").tag("")
                    ForEach(Self.presetNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .mcFont(19, weight: .semibold)
                .onChange(of: presetName) { _, name in
                    if !name.isEmpty { applyPreset(name) }
                }
                PanelNumberRow(label: "Major Ø (mm)", text: $majorText)
                PanelNumberRow(label: "Pitch (mm)", text: $pitchText)
                PanelNumberRow(label: "Length (mm)", text: $threadLengthText)
                Stepper(value: $spec.starts, in: 1...4) {
                    Text("Starts: \(spec.starts)").mcFont(19)
                }
                PanelNumberRow(label: "Profile angle (°)", text: $profileAngleText)
                PanelNumberRow(label: "Taper (°) — NPT ≈ 1.79", text: $taperText)
                PanelNumberRow(label: "Clearance (mm)", text: $clearanceText)
                Picker("Standard", selection: $spec.standard) {
                    ForEach(Self.standards, id: \.self) { s in Text("\(s)").tag(s) }
                }
                .pickerStyle(.menu)
                .mcFont(19)
                Picker("Kind", selection: $spec.kind) {
                    ForEach(Self.kinds, id: \.self) { k in Text("\(k)").tag(k) }
                }
                .pickerStyle(.menu)
                .mcFont(19)
                Picker("Hand", selection: $spec.hand) {
                    ForEach(Self.hands, id: \.self) { h in Text("\(h)").tag(h) }
                }
                .pickerStyle(.menu)
                .mcFont(19)
                Toggle("Modeled thread (real geometry)", isOn: $spec.modeled)
                    .mcFont(19)
                Text("Minor Ø \(mcFmt(previewSpec.minorDiameter)) · Pitch Ø \(mcFmt(previewSpec.pitchDiameter))")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
                PanelDraftError(model: model)
            } else {
                PanelNote(text: "No shaft is selected. Tap a round shaft on the model, then choose Thread This Shaft.", warning: true)
            }
            PanelOKBar(okEnabled: candidateKind != nil, onOK: apply, onCancel: close)
        }
        .onAppear { refreshDraft() }
        .onChange(of: draftSignature) { _, _ in refreshDraft() }
    }

    private func apply() {
        guard let kind = candidateKind else { return }
        model.appendFeature(name: "Thread", kind: kind)
        model.setDraft(nil)
        close()
    }
}

private extension ThreadSpec {
    /// The preset used to prefill this spec, if the diameter match
    /// that produced it still holds (major within 2% of the shaft).
    func presetName(diameter: Double) -> String {
        for name in ["M3", "M4", "M5", "M6", "M8", "M10", "M12", "M16", "M20",
                     "1/4-20", "5/16-18", "3/8-16", "1/2-13",
                     "NPT 1/4", "NPT 3/8", "NPT 1/2"] {
            guard let p = try? ThreadSpec.preset(name) else { continue }
            if abs(p.majorDiameter - diameter) <= 0.02 * diameter,
               abs(p.majorDiameter - majorDiameter) < 1e-9,
               abs(p.pitch - pitch) < 1e-9 {
                return name
            }
        }
        return ""
    }
}
