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
                .font(.system(size: 19, weight: .semibold))
            Spacer()
            TextField(label, text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 20, weight: .semibold))
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $selection) {
                ForEach(sketches) { sk in
                    Text(sk.name).tag(sk.id)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 20, weight: .semibold))
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
            .font(.system(size: 17, weight: warning ? .semibold : .regular))
            .foregroundStyle(warning ? .orange : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
            Button(okTitle) { onOK() }
                .font(.system(size: 20, weight: .bold))
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
                    .font(.system(size: 24, weight: .bold))
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
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
            ExtrudePanel(model: model, initialSketchID: extrudeSketchID, close: close)
        case .revolve:
            RevolvePanel(model: model, close: close)
        case .hole:
            HolePanel(model: model, close: close)
        case .loft:
            LoftPanel(model: model, close: close)
        case .sweep:
            SweepPanel(model: model, close: close)
        case .coil:
            CoilPanel(model: model, close: close)
        case .pipe:
            PipePanel(model: model, close: close)
        case .rib:
            RibPanel(model: model, close: close)
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
                .font(.system(size: 17, weight: .semibold))
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.datumSketches) { datum in
                    Button {
                        choice = .datum(datum.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.on.square")
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(datum.name)
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(mcPlaneText(datum.plane))
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if choice == .datum(datum.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Button {
                onPickFace()
            } label: {
                Label("Pick a face on the model…", systemImage: "square.on.square.dashed")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
            .buttonStyle(.plain)
            HStack(alignment: .top, spacing: 8) {
                Text("Selected:")
                    .font(.system(size: 18, weight: .bold))
                Text(choiceText)
                    .font(.system(size: 18, weight: .semibold))
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
                    .font(.system(size: 22))
                Text(name)
                    .font(.system(size: 20, weight: .bold))
                Text(sub)
                    .font(.system(size: 14))
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
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                TextField("Sketch name", text: $nameText)
                    .font(.system(size: 20, weight: .semibold))
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
                .font(.system(size: 19, weight: .semibold))
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
                .font(.system(size: 20, weight: .semibold))
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
            .font(.system(size: 19, weight: .semibold))
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
                        .font(.system(size: 19, weight: .semibold))
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
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                TextField("Datum name", text: $nameText)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 170)
                    .textFieldStyle(.roundedBorder)
            }
            PanelNote(text: "Creates a datum plane (a ⌖ reference you can sketch on). A negative distance slides it the other way.")
            if let id = createdDatumID {
                Button("Sketch on this datum now") {
                    model.planeChoice = .datum(id)
                    switchTool(.newSketch)
                }
                .font(.system(size: 19, weight: .bold))
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $aroundX) {
                Text("Plane's X axis").tag(true)
                Text("Plane's Y axis").tag(false)
            }
            .pickerStyle(.segmented)
            .font(.system(size: 19, weight: .semibold))
            PanelNumberRow(label: "Angle (degrees)", text: $angleText)
            HStack {
                Text("Name")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                TextField("Datum name", text: $nameText)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 170)
                    .textFieldStyle(.roundedBorder)
            }
            PanelNote(text: "The new datum passes through the source plane's origin, tilted by the angle around the chosen axis.")
            if let id = createdDatumID {
                Button("Sketch on this datum now") {
                    model.planeChoice = .datum(id)
                    switchTool(.newSketch)
                }
                .font(.system(size: 19, weight: .bold))
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
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                TextField("Datum name", text: $nameText)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 170)
                    .textFieldStyle(.roundedBorder)
            }
            PanelNote(text: "The datum lands exactly halfway between the two faces, parallel to both.")
            if let id = createdDatumID {
                Button("Sketch on this datum now") {
                    model.planeChoice = .datum(id)
                    switchTool(.newSketch)
                }
                .font(.system(size: 19, weight: .bold))
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
                .font(.system(size: 17, weight: .semibold))
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
                    .font(.system(size: 19, weight: .semibold))
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

    init(model: EditorModel, initialSketchID: String?, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        let fallback = model.featureSketches.first?.id ?? ""
        _sketchID = State(initialValue: initialSketchID ?? fallback)
    }

    private var sketches: [Sketch] { model.featureSketches }

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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Operation", selection: $operation) {
                Text("Join (add)").tag("join")
                Text("Cut (remove)").tag("cut")
                Text("Intersect (keep overlap)").tag("intersect")
                Text("New Body").tag("newBody")
            }
            .pickerStyle(.menu)
            .font(.system(size: 20, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("End")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("End", selection: $endChoice) {
                Text("Dimension").tag("dimension")
                Text("Through All").tag("throughAll")
                Text("Up to Face").tag("upToFace")
            }
            .pickerStyle(.segmented)
            .font(.system(size: 19, weight: .semibold))
            if endChoice == "dimension" {
                PanelNumberRow(label: "Distance (mm)", text: $distanceText)
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
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $faceIndex) {
                            ForEach(Array(faces.enumerated()), id: \.offset) { i, face in
                                Text("Face \(i + 1) · \(mcFaceLabel(face))").tag(i)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 20, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("Type")
                .font(.system(size: 17, weight: .semibold))
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
            PanelOKBar(okEnabled: !sketches.isEmpty && (endChoice != "upToFace" || !faces.isEmpty),
                       onOK: apply, onCancel: close)
        }
    }

    private func apply() {
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
        model.appendFeature(name: "Extrude",
                            kind: .extrude2(sketchID: sketchID,
                                            distance: panelNum(distanceText, fallback: 10),
                                            taperDegrees: panelNum(taperText, fallback: 0),
                                            mode: mode, operation: op, end: end))
        close()
    }
}

// MARK: - Revolve panel

struct RevolvePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var sketchID: String
    @State private var axisEntityID: Int = 0
    @State private var angleText = "360"

    init(model: EditorModel, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        _sketchID = State(initialValue: model.featureSketches.first?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }
    private var axisLines: [SketchEntity] {
        (sketches.first { $0.id == sketchID }?.entities ?? []).filter { e in
            if case .line = e { return true }
            return false
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
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("Axis", selection: $axisEntityID) {
                        ForEach(axisLines, id: \.id) { e in
                            Text("Line #\(e.id)").tag(e.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if axisLines.isEmpty {
                    PanelNote(text: "The chosen sketch has no line to revolve around yet.", warning: true)
                }
            }
            PanelNumberRow(label: "Angle (degrees)", text: $angleText)
            PanelOKBar(okEnabled: !sketches.isEmpty && !axisLines.isEmpty, onOK: apply, onCancel: close)
                .onAppear {
                    if axisEntityID == 0, let first = axisLines.first { axisEntityID = first.id }
                }
        }
    }

    private func apply() {
        model.appendFeature(name: "Revolve",
                            kind: .revolve(sketchID: sketchID, axisEntityID: axisEntityID,
                                           angleDegrees: panelNum(angleText, fallback: 360)))
        close()
    }
}

// MARK: - Hole panel

struct HolePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var sketchID: String
    @State private var diameterText = "6"
    @State private var through = true
    @State private var depthText = "10"
    @State private var kindChoice = "simple"
    @State private var cbDiameterText = "10"
    @State private var cbDepthText = "3"
    @State private var csAngleText = "90"

    init(model: EditorModel, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        _sketchID = State(initialValue: model.featureSketches.first?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.isEmpty {
                PanelNote(text: "There is no sketch yet. Holes drill at the points and circle centers of a sketch.", warning: true)
            } else {
                PanelSketchPicker(label: "Drill-point sketch", sketches: sketches, selection: $sketchID)
            }
            PanelNumberRow(label: "Diameter (mm)", text: $diameterText)
            Toggle("Through (all the way)", isOn: $through)
                .font(.system(size: 19, weight: .semibold))
            if !through {
                PanelNumberRow(label: "Depth (mm)", text: $depthText)
            }
            Text("Type")
                .font(.system(size: 17, weight: .semibold))
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
            PanelOKBar(okEnabled: !sketches.isEmpty, onOK: apply, onCancel: close)
        }
    }

    private func apply() {
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
        model.appendFeature(name: "Hole",
                            kind: .hole(sketchID: sketchID,
                                        diameter: panelNum(diameterText, fallback: 6),
                                        depth: through ? 0 : panelNum(depthText, fallback: 10),
                                        kind: hk))
        close()
    }
}

// MARK: - Loft & Sweep panels

struct LoftPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var sketchA: String
    @State private var sketchB: String

    init(model: EditorModel, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        let all = model.featureSketches
        _sketchA = State(initialValue: all.first?.id ?? "")
        _sketchB = State(initialValue: (all.count > 1 ? all[1] : all.first)?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.count < 2 {
                PanelNote(text: "Loft needs two profile sketches on different planes (for example XY offset, or a face sketch). The demo part's sketches all sit on related planes — draw a second profile to blend into.", warning: true)
            }
            PanelSketchPicker(label: "First profile", sketches: sketches, selection: $sketchA)
            PanelSketchPicker(label: "Second profile", sketches: sketches, selection: $sketchB)
            PanelNote(text: "Blends the first closed profile into the second. Both need the same number of corners.")
            PanelOKBar(okEnabled: sketches.count >= 2 && sketchA != sketchB, onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Loft", kind: .loft(sketchA: sketchA, sketchB: sketchB))
        close()
    }
}

struct SweepPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var profileID: String
    @State private var pathID: String

    init(model: EditorModel, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        let all = model.featureSketches
        _profileID = State(initialValue: all.first?.id ?? "")
        _pathID = State(initialValue: (all.count > 1 ? all[1] : all.first)?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.count < 2 {
                PanelNote(text: "Sweep needs two sketches: a closed profile and a path made of connected lines.", warning: true)
            }
            PanelSketchPicker(label: "Profile sketch", sketches: sketches, selection: $profileID)
            PanelSketchPicker(label: "Path sketch", sketches: sketches, selection: $pathID)
            PanelNote(text: "The profile is swept along the path's connected lines.")
            PanelOKBar(okEnabled: sketches.count >= 2 && profileID != pathID, onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Sweep",
                            kind: .sweep(profileSketchID: profileID, pathSketchID: pathID))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.keys(kind), id: \.self) { key in
                PanelNumberRow(label: Self.label(key), text: binding(for: key))
            }
            PanelNote(text: "Built at the origin: boxes and cylinders rise from the XY plane, spheres and toruses are centered on it.")
            PanelOKBar(okTitle: "Create", onOK: apply, onCancel: close)
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func apply() {
        var params: [String: Double] = [:]
        for key in Self.keys(kind) {
            params[key] = panelNum(values[key] ?? "", fallback: Self.defaults(kind)[key] ?? 10)
        }
        let name: String
        switch kind {
        case .box: name = "Box"
        case .cylinder: name = "Cylinder"
        case .sphere: name = "Sphere"
        case .cone: name = "Cone"
        case .torus: name = "Torus"
        }
        model.appendFeature(name: name, kind: .primitive(kind: kind, params: params))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Radius (mm)", text: $radiusText)
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
                .font(.system(size: 19, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
            }
            PanelOKBar(okTitle: createdFeatureID == nil ? "OK" : "Apply", onOK: apply, onCancel: close)
        }
        .onAppear {
            if let mesh = model.rebuild?.mesh, mesh.triangleCount > 0 {
                sharpEdgeCount = SolidEdgeExtractor.edges(of: mesh).count
            }
        }
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
            return
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mode")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Mode", selection: $modeChoice) {
                Text("Equal").tag("equal")
                Text("Two distances").tag("two")
                Text("Distance + Angle").tag("angle")
            }
            .pickerStyle(.segmented)
            .font(.system(size: 18, weight: .semibold))
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
            PanelOKBar(onOK: apply, onCancel: close)
        }
    }

    private func apply() {
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
        model.appendFeature(name: "Chamfer", kind: .chamfer2(mode: mode))
        close()
    }
}

struct ShellPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var thicknessText = "2"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Wall thickness (mm)", text: $thicknessText)
            PanelNote(text: "Hollows the body built so far, leaving walls of this thickness — like turning a block into an open box.")
            PanelOKBar(onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Shell",
                            kind: .shell(thickness: panelNum(thicknessText, fallback: 2)))
        close()
    }
}

struct MirrorPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var plane: MirrorPlane = .yz

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mirror plane")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Plane", selection: $plane) {
                ForEach(MirrorPlane.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            PanelNote(text: "Duplicates the body built so far, mirrored across the chosen base plane, and joins the two halves.")
            PanelOKBar(onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Mirror", kind: .mirror(plane: plane))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("Copies: \(count)", value: $count, in: 1...24)
                .font(.system(size: 20, weight: .semibold))
            PanelNumberRow(label: "Spacing X (mm)", text: $spacingX)
            PanelNumberRow(label: "Spacing Y (mm)", text: $spacingY)
            PanelNumberRow(label: "Spacing Z (mm)", text: $spacingZ)
            PanelNote(text: "Repeats the whole body built so far — copy 1 is the original, each next copy steps by the spacing.")
            PanelOKBar(onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Linear Pattern",
                            kind: .linearPattern(count: count,
                                                 spacing: Vec3(panelNum(spacingX, fallback: 15),
                                                               panelNum(spacingY, fallback: 0),
                                                               panelNum(spacingZ, fallback: 0))))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Coil radius (mm)", text: $radiusText)
            PanelNumberRow(label: "Pitch (mm / turn)", text: $pitchText)
            PanelNumberRow(label: "Turns", text: $turnsText)
            PanelNumberRow(label: "Wire radius (mm)", text: $wireText)
            PanelNote(text: "A spring: wire wound in a helix. It starts at the origin and winds around the Z axis, rising by the pitch each turn.")
            PanelOKBar(okTitle: "Create", onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Coil",
                            kind: .coil(radius: panelNum(radiusText, fallback: 15),
                                        pitch: panelNum(pitchText, fallback: 8),
                                        turns: panelNum(turnsText, fallback: 5),
                                        wireRadius: panelNum(wireText, fallback: 2)))
        close()
    }
}

struct PipePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var pathID: String
    @State private var radiusText = "4"

    init(model: EditorModel, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        _pathID = State(initialValue: model.featureSketches.first?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.isEmpty {
                PanelNote(text: "There is no sketch yet. A pipe follows a path sketch — a chain of connected lines.", warning: true)
            } else {
                PanelSketchPicker(label: "Path sketch", sketches: sketches, selection: $pathID)
            }
            PanelNumberRow(label: "Pipe radius (mm)", text: $radiusText)
            PanelNote(text: "A round tube swept along the path — the profile is automatic, perpendicular to the path's start.")
            PanelOKBar(okEnabled: !sketches.isEmpty, onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Pipe",
                            kind: .pipe(pathSketchID: pathID,
                                        radius: panelNum(radiusText, fallback: 4)))
        close()
    }
}

struct RibPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var sketchID: String
    @State private var thicknessText = "3"
    @State private var depthText = "12"

    init(model: EditorModel, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        _sketchID = State(initialValue: model.featureSketches.first?.id ?? "")
    }

    private var sketches: [Sketch] { model.featureSketches }

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
            PanelOKBar(okEnabled: !sketches.isEmpty, onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Rib",
                            kind: .rib(sketchID: sketchID,
                                       thickness: panelNum(thicknessText, fallback: 3),
                                       depth: panelNum(depthText, fallback: 12)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("Copies: \(count)", value: $count, in: 2...36)
                .font(.system(size: 20, weight: .semibold))
            Text("Around axis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $axis) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .font(.system(size: 20, weight: .semibold))
            PanelNumberRow(label: "Total angle (degrees)", text: $totalText)
            PanelNote(text: "Repeats the whole body built so far around the axis through the body's center — copy 1 is the original; 360° spreads the copies evenly all the way around.")
            PanelOKBar(onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Circular Pattern",
                            kind: .circularPattern(count: count, axis: axis,
                                                   totalDegrees: panelNum(totalText, fallback: 360)))
        close()
    }
}

struct DraftPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var angleText = "3"
    @State private var axis = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Angle (degrees)", text: $angleText)
            Text("Pull axis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $axis) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .font(.system(size: 20, weight: .semibold))
            PanelNote(text: "Mold-release taper: a positive angle narrows the body toward the top of the pull axis, measured from its base. Between −30° and 30°.")
            PanelOKBar(onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Draft",
                            kind: .draftBody(angleDegrees: panelNum(angleText, fallback: 3),
                                             pullAxis: axis))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Uniform (same factor on all axes)", isOn: $uniform)
                .font(.system(size: 19, weight: .semibold))
            PanelNumberRow(label: "Factor X", text: $fx)
                .onChange(of: fx) { _, newValue in
                    if uniform { fy = newValue; fz = newValue }
                }
            if !uniform {
                PanelNumberRow(label: "Factor Y", text: $fy)
                PanelNumberRow(label: "Factor Z", text: $fz)
            }
            PanelNote(text: "Scales the body built so far about its center — 2 doubles every size, 0.5 halves it.")
            PanelOKBar(onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Scale",
                            kind: .scaleBody(factors: Vec3(panelNum(fx, fallback: 1),
                                                           panelNum(fy, fallback: 1),
                                                           panelNum(fz, fallback: 1))))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Move X (mm)", text: $tx)
            PanelNumberRow(label: "Move Y (mm)", text: $ty)
            PanelNumberRow(label: "Move Z (mm)", text: $tz)
            Text("Then rotate around")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $axis) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .font(.system(size: 20, weight: .semibold))
            PanelNumberRow(label: "Rotation (degrees)", text: $degreesText)
            PanelNote(text: "Moves the whole body built so far, then rotates it around the chosen axis through its center. Rotation 0 just moves it.")
            PanelOKBar(onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Move Body",
                            kind: .moveBody(translation: Vec3(panelNum(tx, fallback: 0),
                                                              panelNum(ty, fallback: 0),
                                                              panelNum(tz, fallback: 0)),
                                            rotationAxis: axis,
                                            rotationDegrees: panelNum(degreesText, fallback: 0)))
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Axis", selection: $axis) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .font(.system(size: 20, weight: .semibold))
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
