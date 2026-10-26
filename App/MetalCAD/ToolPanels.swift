import SwiftUI

/// The Fusion-style context tools. Tapping a ribbon tool opens one of
/// these panels beside the preview; OK builds the feature with exactly
/// the numbers shown — nothing is hidden or prefixed.
enum ActiveTool: Identifiable, Equatable {
    case newSketch
    case extrude
    case revolve
    case hole
    case loft
    case sweep
    case primitive(PrimitiveKind)
    case fillet
    case chamfer
    case shell
    case mirror
    case pattern
    case measure

    var id: String {
        switch self {
        case .newSketch: return "newSketch"
        case .extrude: return "extrude"
        case .revolve: return "revolve"
        case .hole: return "hole"
        case .loft: return "loft"
        case .sweep: return "sweep"
        case .primitive(let k): return "primitive-\(k.rawValue)"
        case .fillet: return "fillet"
        case .chamfer: return "chamfer"
        case .shell: return "shell"
        case .mirror: return "mirror"
        case .pattern: return "pattern"
        case .measure: return "measure"
        }
    }

    var title: String {
        switch self {
        case .newSketch: return "New Sketch"
        case .extrude: return "Extrude"
        case .revolve: return "Revolve"
        case .hole: return "Hole"
        case .loft: return "Loft"
        case .sweep: return "Sweep"
        case .primitive(let k): return k.rawValue.capitalized
        case .fillet: return "Fillet"
        case .chamfer: return "Chamfer"
        case .shell: return "Shell"
        case .mirror: return "Mirror"
        case .pattern: return "Linear Pattern"
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
    let pickFace: () -> Void

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
        case .measure:
            MeasurePanel(model: model)
        }
    }
}

// MARK: - New Sketch panel (plane picker, Fusion-style)

struct NewSketchPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    let openSketch: (String) -> Void
    let pickFace: () -> Void

    @State private var planeChoice = "XY"
    @State private var offsetText = "0"
    @State private var nameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plane")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Plane", selection: $planeChoice) {
                Text("XY").tag("XY")
                Text("XZ").tag("XZ")
                Text("YZ").tag("YZ")
            }
            .pickerStyle(.segmented)
            .font(.system(size: 20, weight: .semibold))
            PanelNumberRow(label: "Offset from origin (mm)", text: $offsetText)
            HStack {
                Text("Name")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                TextField("Sketch name", text: $nameText)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 170)
                    .textFieldStyle(.roundedBorder)
            }
            PanelNote(text: "The offset slides the plane along its normal — sketch 10 mm above the XY plane with plane XY and offset 10.")
            Button {
                pickFace()
            } label: {
                Label("…or pick a face on the model", systemImage: "square.on.square.dashed")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
            PanelOKBar(okTitle: "Create Sketch", onOK: create, onCancel: close)
        }
    }

    private func create() {
        let base: Plane3
        switch planeChoice {
        case "XZ": base = .xz
        case "YZ": base = .yz
        default: base = .xy
        }
        let offset = panelNum(offsetText, fallback: 0)
        let plane = Plane3(origin: base.origin + base.normal * offset,
                           xAxis: base.xAxis, yAxis: base.yAxis)
        let name = nameText.isEmpty
            ? "Sketch \((model.part?.sketches.count ?? 0) + 1)"
            : nameText
        let sketch = model.addSketch(plane: plane, name: name)
        close()
        openSketch(sketch.id)
    }
}

// MARK: - Extrude panel

struct ExtrudePanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var sketchID: String
    @State private var distanceText = "10"
    @State private var typeChoice = "one"
    @State private var secondText = "10"
    @State private var taperText = "0"
    @State private var operation = "join"

    init(model: EditorModel, initialSketchID: String?, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.close = close
        let fallback = model.part?.sketches.first?.id ?? ""
        _sketchID = State(initialValue: initialSketchID ?? fallback)
    }

    private var sketches: [Sketch] { model.part?.sketches ?? [] }

    /// Cut is only honest as a one-sided, untapered pocket.
    private var cutIsLimited: Bool {
        operation == "cut" && (typeChoice != "one" || panelNum(taperText, fallback: 0) != 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sketches.isEmpty {
                PanelNote(text: "There is no sketch yet. Create one first — Sketch ▸ New Sketch — then extrude it.", warning: true)
            } else {
                PanelSketchPicker(label: "Profile sketch", sketches: sketches, selection: $sketchID)
            }
            PanelNumberRow(label: "Distance (mm)", text: $distanceText)
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
            Text("Operation")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Operation", selection: $operation) {
                Text("Join (add)").tag("join")
                Text("Cut (remove)").tag("cut")
            }
            .pickerStyle(.segmented)
            if operation == "cut" && !cutIsLimited {
                PanelNote(text: "Cut removes material along the sketch normal — saved as a Pocket.")
            }
            if cutIsLimited {
                PanelNote(text: "Cut only supports one side with no taper. With these settings, OK creates a Join extrude instead — the limit is stated, never faked.", warning: true)
            }
            PanelOKBar(okEnabled: !sketches.isEmpty, onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        let distance = panelNum(distanceText, fallback: 10)
        let taper = panelNum(taperText, fallback: 0)
        if operation == "cut" && !cutIsLimited {
            model.appendFeature(name: "Pocket", kind: .pocket(sketchID: sketchID, depth: distance))
        } else {
            let mode: ExtrudeMode
            switch typeChoice {
            case "symmetric": mode = .symmetric
            case "twoSided": mode = .twoSided(second: panelNum(secondText, fallback: 10))
            default: mode = .one
            }
            model.appendFeature(name: "Extrude",
                                kind: .extrude(sketchID: sketchID, distance: distance,
                                               taperDegrees: taper, mode: mode))
        }
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
        _sketchID = State(initialValue: model.part?.sketches.first?.id ?? "")
    }

    private var sketches: [Sketch] { model.part?.sketches ?? [] }
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
        _sketchID = State(initialValue: model.part?.sketches.first?.id ?? "")
    }

    private var sketches: [Sketch] { model.part?.sketches ?? [] }

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
        let all = model.part?.sketches ?? []
        _sketchA = State(initialValue: all.first?.id ?? "")
        _sketchB = State(initialValue: (all.count > 1 ? all[1] : all.first)?.id ?? "")
    }

    private var sketches: [Sketch] { model.part?.sketches ?? [] }

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
        let all = model.part?.sketches ?? []
        _profileID = State(initialValue: all.first?.id ?? "")
        _pathID = State(initialValue: (all.count > 1 ? all[1] : all.first)?.id ?? "")
    }

    private var sketches: [Sketch] { model.part?.sketches ?? [] }

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
    @State private var distanceText = "2"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelNumberRow(label: "Distance (mm)", text: $distanceText)
            PanelNote(text: "Cuts a flat bevel across every sharp edge of the body built so far, this far back from each edge.")
            PanelOKBar(onOK: apply, onCancel: close)
        }
    }

    private func apply() {
        model.appendFeature(name: "Chamfer",
                            kind: .chamfer(distance: panelNum(distanceText, fallback: 2)))
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
