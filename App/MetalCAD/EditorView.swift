import SwiftUI

/// Whole-number-friendly formatting shared by the editor views.
func mcFmt(_ v: Double) -> String {
    if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
    return String(format: "%.2f", v)
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

    // MARK: Feature creation

    func addPrimitive(_ kind: PrimitiveKind) {
        let params: [String: Double]
        let label: String
        switch kind {
        case .box:      params = ["width": 30, "depth": 20, "height": 12]; label = "Box"
        case .cylinder: params = ["diameter": 20, "height": 25];           label = "Cylinder"
        case .sphere:   params = ["diameter": 24];                          label = "Sphere"
        case .cone:     params = ["diameter": 20, "height": 25];            label = "Cone"
        case .torus:    params = ["ringRadius": 15, "tubeRadius": 5];      label = "Torus"
        }
        mutate { $0.features.append(Feature(name: label,
                                            kind: .primitive(kind: kind, params: params))) }
        MCLog.shared.info(.feature, "primitive added", context: ["kind": kind.rawValue])
    }

    func addPad(length: Double) {
        guard let sk = part?.sketches.first else {
            actionError = .padNoProfile
            MCLog.shared.log(error: .padNoProfile, category: .feature)
            return
        }
        guard length > 0 else {
            actionError = .padLengthInvalid(length)
            MCLog.shared.log(error: .padLengthInvalid(length), category: .feature)
            return
        }
        mutate { $0.features.append(Feature(name: "Pad",
                                            kind: .pad(sketchID: sk.id, length: length))) }
    }

    /// Pocket is added as-is; the v1 kernel refuses exact cuts, so the
    /// rebuild reports MCAD-FT405 on this feature. That's the honest
    /// designed behavior until the OCCT bridge lands.
    func addPocket(depth: Double) {
        let skID = part?.sketches.first?.id ?? ""
        mutate { $0.features.append(Feature(name: "Pocket",
                                            kind: .pocket(sketchID: skID, depth: depth))) }
    }

    /// Same honesty rule as Pocket: the rebuild reports MCAD-FT407.
    func addFillet(radius: Double) {
        mutate { $0.features.append(Feature(name: "Fillet",
                                            kind: .fillet(radius: radius))) }
    }

    func addThread(preset name: String, starts: Int) {
        do {
            var spec = try ThreadSpec.preset(name)
            spec.starts = starts
            let checked = try spec.validated()
            for w in checked.warnings { MCLog.shared.log(error: w, category: .thread) }
            mutate { $0.features.append(Feature(name: "Thread \(name)",
                                                kind: .threadShaft(spec: checked.spec))) }
            MCLog.shared.info(.thread, "thread feature added",
                              context: ["preset": name, "starts": "\(starts)"])
        } catch let e as CADError {
            actionError = e
            MCLog.shared.log(error: e, category: .thread)
        } catch {
            actionError = .unknown("\(error)")
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
            stlWarnings = try IOService.writeSTL(mesh.welded(), to: url)
            stlURL = url
        } catch let e as CADError {
            actionError = e
        } catch {
            actionError = .unknown("\(error)")
        }
    }
}

/// The part editor: feature list + add-controls on the left, live 3D
/// preview on the right. Rebuilds after every change.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var padLengthText = "10"
    @State private var pocketDepthText = "8"
    @State private var filletRadiusText = "2"
    @State private var threadStarts = 1

    private let rowFont = Font.system(size: 20)
    private let threadPresets = ["M3", "M4", "M5", "M6", "M8", "M10", "M12", "M16", "M20",
                                 "1/4-20", "NPT 1/2"]

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                controlPanel
                    .frame(width: 400)
                Divider()
                VStack(spacing: 10) {
                    if let err = model.actionError {
                        errorBanner(err, dismissible: true)
                    }
                    if let err = model.rebuild?.firstError {
                        errorBanner(err, dismissible: false)
                    }
                    SceneKitView(mesh: model.rebuild?.mesh ?? Mesh())
                        .id(meshKey)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .navigationTitle(model.document.name)
            .navigationBarTitleDisplayMode(.inline)
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
        }
    }

    private var meshKey: String {
        let m = model.rebuild?.mesh
        return "\(m?.triangleCount ?? 0)-\(m?.volume ?? 0)"
    }

    private var statsBar: some View {
        let m = model.rebuild?.mesh
        return HStack(spacing: 24) {
            Text("Triangles: \(m?.triangleCount ?? 0)")
            Text("Volume: \(mcFmt(m?.volume ?? 0)) mm³")
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

    // MARK: Left panel

    private var controlPanel: some View {
        List {
            Section("Add solid") {
                Menu {
                    ForEach(PrimitiveKind.allCases, id: \.self) { kind in
                        Button(primitiveLabel(kind)) { model.addPrimitive(kind) }
                    }
                } label: {
                    Text("Add Primitive…")
                        .font(rowFont)
                }
                HStack {
                    Text("Pad").font(rowFont)
                    Spacer()
                    TextField("mm", text: $padLengthText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .font(rowFont)
                    Text("mm").font(rowFont).foregroundStyle(.secondary)
                    Button("Add") { model.addPad(length: Double(padLengthText) ?? 10) }
                        .font(.system(size: 20, weight: .semibold))
                }
            }

            Section("Thread") {
                Stepper("Starts: \(threadStarts)", value: $threadStarts, in: 1...4)
                    .font(rowFont)
                Menu {
                    ForEach(threadPresets, id: \.self) { name in
                        Button(name) { model.addThread(preset: name, starts: threadStarts) }
                    }
                } label: {
                    Text("Add Thread…")
                        .font(rowFont)
                }
            }

            Section("Cut & round") {
                HStack {
                    Text("Fillet").font(rowFont)
                    Spacer()
                    TextField("mm", text: $filletRadiusText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .font(rowFont)
                    Text("mm").font(rowFont).foregroundStyle(.secondary)
                    Button("Add") { model.addFillet(radius: Double(filletRadiusText) ?? 2) }
                        .font(.system(size: 20, weight: .semibold))
                }
                HStack {
                    Text("Pocket").font(rowFont)
                    Spacer()
                    TextField("mm", text: $pocketDepthText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .font(rowFont)
                    Text("mm").font(rowFont).foregroundStyle(.secondary)
                    Button("Add") { model.addPocket(depth: Double(pocketDepthText) ?? 8) }
                        .font(.system(size: 20, weight: .semibold))
                }
                Text("Pocket and Fillet need the exact kernel (coming with the OCCT bridge) — adding one shows its MCAD code on the feature instead of faking the shape.")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }

            Section("Features") {
                if let part = model.part, !part.features.isEmpty {
                    ForEach(part.features) { feature in
                        featureRow(feature)
                    }
                } else {
                    Text("No features yet. Add a solid above.")
                        .font(rowFont)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sketches") {
                if let part = model.part {
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
                Button("New Sketch") { model.addSketch() }
                    .font(rowFont)
            }
        }
    }

    private func featureRow(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(for: feature)
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
            Spacer()
            Button(feature.suppressed ? "Unsuppress" : "Suppress") {
                model.setSuppressed(feature.id, !feature.suppressed)
            }
            .font(.system(size: 17, weight: .semibold))
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

    private func primitiveLabel(_ kind: PrimitiveKind) -> String {
        switch kind {
        case .box: return "Box 30×20×12"
        case .cylinder: return "Cylinder Ø20 × 25"
        case .sphere: return "Sphere Ø24"
        case .cone: return "Cone Ø20 × 25"
        case .torus: return "Torus R15 × r5"
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
        case .linearPattern(let count, _):
            return "Pattern · ×\(count)"
        case .fillet(let radius):
            return "Fillet · r \(mcFmt(radius))"
        case .booleanCutPlaceholder:
            return "Boolean cut"
        }
    }
}
