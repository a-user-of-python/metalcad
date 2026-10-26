import SwiftUI

// MARK: - Material picker

struct MaterialPickerSheet: View {
    let currentID: String
    let onPick: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(MaterialLibrary.all) { mat in
                    Button {
                        onPick(mat.id)
                    } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: mat.red, green: mat.green, blue: mat.blue))
                                .frame(width: 44, height: 44)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.3)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mat.name)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("\(String(format: "%.2f", mat.density)) g/cm³ · metalness \(mcFmt(mat.metalness)) · roughness \(mcFmt(mat.roughness))")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if mat.id == currentID {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Material")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.system(size: 19, weight: .semibold))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Feature editor (every parameter editable, all 15 kinds)

/// Full editor for one feature: every parameter of its kind is a field.
/// Nothing is prefixed — Apply writes the numbers back and the part
/// rebuilds. Covers all 15 FeatureKind cases of kit v3.
struct FeatureEditorSheet: View {
    let feature: Feature
    let sketches: [Sketch]
    /// When this fillet currently fails with MCAD-FT408, the largest
    /// radius the kernel says fits — shown as a one-tap fix.
    var filletMaxFeasible: Double? = nil
    let onSave: (String, FeatureKind) -> Void
    let onCancel: () -> Void

    @State private var nameText: String
    // pad / pocket / revolve / hole / extrude shared
    @State private var sketchID: String
    @State private var lengthText: String = "10"
    @State private var depthText: String = "5"
    @State private var angleText: String = "360"
    @State private var axisEntityID: Int = 0
    // primitive
    @State private var paramValues: [String: String] = [:]
    // pattern
    @State private var countText: String = "3"
    @State private var spacingX: String = "15"
    @State private var spacingY: String = "0"
    @State private var spacingZ: String = "0"
    // hole
    @State private var holeDiameterText: String = "6"
    @State private var holeDepthText: String = "10"
    @State private var holeThrough: Bool = true
    @State private var holeKindChoice: String = "simple"
    @State private var cbDiameterText: String = "10"
    @State private var cbDepthText: String = "3"
    @State private var csAngleText: String = "90"
    // mirror
    @State private var mirrorPlane: MirrorPlane = .yz
    // fillet / chamfer / shell
    @State private var filletRadiusText: String = "2"
    @State private var chamferDistanceText: String = "2"
    @State private var shellThicknessText: String = "2"
    // extrude
    @State private var extrudeDistanceText: String = "10"
    @State private var extrudeTaperText: String = "0"
    @State private var extrudeModeChoice: String = "one"
    @State private var extrudeSecondText: String = "10"
    // loft / sweep
    @State private var loftAID: String = ""
    @State private var loftBID: String = ""
    @State private var sweepProfileID: String = ""
    @State private var sweepPathID: String = ""
    // thread
    @State private var spec = ThreadSpec()
    @State private var presetName: String = ""
    @State private var majorText: String = "10"
    @State private var pitchText: String = "1.5"
    @State private var threadLengthText: String = "20"
    @State private var profileAngleText: String = "60"
    @State private var taperText: String = "0"
    @State private var clearanceText: String = "0"

    private static let presetNames = ["M3", "M4", "M5", "M6", "M8", "M10", "M12", "M16", "M20",
                                      "1/4-20", "5/16-18", "3/8-16", "1/2-13",
                                      "NPT 1/4", "NPT 3/8", "NPT 1/2"]
    private static let standards: [ThreadStandard] = [.isoMetric, .unc, .npt, .custom]
    private static let kinds: [ThreadKind] = [.external, .internal]
    private static let hands: [ThreadHand] = [.right, .left]

    init(feature: Feature, sketches: [Sketch], filletMaxFeasible: Double? = nil,
         onSave: @escaping (String, FeatureKind) -> Void,
         onCancel: @escaping () -> Void) {
        self.feature = feature
        self.sketches = sketches
        self.filletMaxFeasible = filletMaxFeasible
        self.onSave = onSave
        self.onCancel = onCancel
        _nameText = State(initialValue: feature.name)
        var initialSketch = sketches.first?.id ?? ""
        switch feature.kind {
        case .pad(let sid, let len):
            initialSketch = sid
            _lengthText = State(initialValue: mcFmt(len))
        case .pocket(let sid, let depth):
            initialSketch = sid
            _depthText = State(initialValue: mcFmt(depth))
        case .revolve(let sid, let axis, let angle):
            initialSketch = sid
            _axisEntityID = State(initialValue: axis)
            _angleText = State(initialValue: mcFmt(angle))
        case .primitive(_, let params):
            var dict: [String: String] = [:]
            for (k, v) in params { dict[k] = mcFmt(v) }
            _paramValues = State(initialValue: dict)
        case .linearPattern(let count, let spacing):
            _countText = State(initialValue: "\(count)")
            _spacingX = State(initialValue: mcFmt(spacing.x))
            _spacingY = State(initialValue: mcFmt(spacing.y))
            _spacingZ = State(initialValue: mcFmt(spacing.z))
        case .hole(let sid, let diameter, let depth, let hk):
            initialSketch = sid
            _holeDiameterText = State(initialValue: mcFmt(diameter))
            _holeThrough = State(initialValue: depth <= 0)
            _holeDepthText = State(initialValue: mcFmt(depth > 0 ? depth : 10))
            switch hk {
            case .simple:
                _holeKindChoice = State(initialValue: "simple")
            case .counterbore(let d, let dep):
                _holeKindChoice = State(initialValue: "counterbore")
                _cbDiameterText = State(initialValue: mcFmt(d))
                _cbDepthText = State(initialValue: mcFmt(dep))
            case .countersink(let angle):
                _holeKindChoice = State(initialValue: "countersink")
                _csAngleText = State(initialValue: mcFmt(angle))
            }
        case .mirror(let plane):
            _mirrorPlane = State(initialValue: plane)
        case .fillet(let radius):
            _filletRadiusText = State(initialValue: mcFmt(radius))
        case .chamfer(let distance):
            _chamferDistanceText = State(initialValue: mcFmt(distance))
        case .shell(let thickness):
            _shellThicknessText = State(initialValue: mcFmt(thickness))
        case .extrude(let sid, let distance, let taper, let mode):
            initialSketch = sid
            _extrudeDistanceText = State(initialValue: mcFmt(distance))
            _extrudeTaperText = State(initialValue: mcFmt(taper))
            switch mode {
            case .one:
                _extrudeModeChoice = State(initialValue: "one")
            case .symmetric:
                _extrudeModeChoice = State(initialValue: "symmetric")
            case .twoSided(let second):
                _extrudeModeChoice = State(initialValue: "twoSided")
                _extrudeSecondText = State(initialValue: mcFmt(second))
            }
        case .loft(let a, let b):
            _loftAID = State(initialValue: a)
            _loftBID = State(initialValue: b)
        case .sweep(let profile, let path):
            _sweepProfileID = State(initialValue: profile)
            _sweepPathID = State(initialValue: path)
        case .threadShaft(let s):
            _spec = State(initialValue: s)
            _majorText = State(initialValue: mcFmt(s.majorDiameter))
            _pitchText = State(initialValue: mcFmt(s.pitch))
            _threadLengthText = State(initialValue: mcFmt(s.length))
            _profileAngleText = State(initialValue: mcFmt(s.profileAngleDegrees))
            _taperText = State(initialValue: mcFmt(s.taperDegrees))
            _clearanceText = State(initialValue: mcFmt(s.clearance))
        case .booleanCutPlaceholder:
            break
        }
        _sketchID = State(initialValue: initialSketch)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Feature name", text: $nameText)
                        .font(.system(size: 21, weight: .semibold))
                }
                kindFields
            }
            .navigationTitle("Edit Feature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.system(size: 19, weight: .semibold))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onSave(nameText, buildKind()) }
                        .font(.system(size: 19, weight: .bold))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var kindFields: some View {
        switch feature.kind {
        case .pad:
            Section("Pad") {
                sketchPicker
                numberRow("Length (mm)", $lengthText)
            }
        case .pocket:
            Section("Pocket") {
                sketchPicker
                numberRow("Depth (mm)", $depthText)
            }
        case .revolve:
            Section("Revolve") {
                sketchPicker
                axisPicker
                numberRow("Angle (degrees)", $angleText)
            }
        case .primitive(let kind, _):
            Section("Size — \(kind.rawValue)") {
                ForEach(primitiveKeys(kind), id: \.self) { key in
                    numberRow(primitiveLabel(key), binding(for: key))
                }
            }
        case .threadShaft:
            threadFields
        case .linearPattern:
            Section("Linear pattern") {
                Stepper("Copies: \(Int(countText) ?? 1)", value: countBinding, in: 1...24)
                    .font(.system(size: 20, weight: .semibold))
                numberRow("Spacing X (mm)", $spacingX)
                numberRow("Spacing Y (mm)", $spacingY)
                numberRow("Spacing Z (mm)", $spacingZ)
            }
        case .hole:
            Section("Hole") {
                sketchPicker
                numberRow("Diameter (mm)", $holeDiameterText)
                Toggle("Through (all the way)", isOn: $holeThrough)
                    .font(.system(size: 20, weight: .semibold))
                if !holeThrough {
                    numberRow("Depth (mm)", $holeDepthText)
                }
                Picker("Type", selection: $holeKindChoice) {
                    Text("Simple").tag("simple")
                    Text("Counterbore").tag("counterbore")
                    Text("Countersink").tag("countersink")
                }
                .font(.system(size: 20, weight: .semibold))
                if holeKindChoice == "counterbore" {
                    numberRow("Bore diameter (mm)", $cbDiameterText)
                    numberRow("Bore depth (mm)", $cbDepthText)
                }
                if holeKindChoice == "countersink" {
                    numberRow("Sink angle (degrees)", $csAngleText)
                }
                Text("Drill points are the points and circle centers in the chosen sketch.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        case .mirror:
            Section("Mirror") {
                Picker("Plane", selection: $mirrorPlane) {
                    ForEach(MirrorPlane.allCases, id: \.self) { plane in
                        Text(plane.displayName).tag(plane)
                    }
                }
                .font(.system(size: 20, weight: .semibold))
            }
        case .fillet:
            Section("Fillet") {
                numberRow("Radius (mm)", $filletRadiusText)
                if let maxF = filletMaxFeasible {
                    Text("The current radius is too big for this body — the largest that fits is ≈ \(mcFmt(maxF)) mm. (MCAD-FT408)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.orange)
                    Button("Use ≈ \(mcFmt(maxF)) mm") {
                        filletRadiusText = mcFmt(maxF)
                    }
                    .font(.system(size: 19, weight: .semibold))
                }
                Text("Rounds every sharp edge of the body built so far. If a radius cannot fit, the rebuild reports MCAD-FT408 with the largest radius that does.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        case .chamfer:
            Section("Chamfer") {
                numberRow("Distance (mm)", $chamferDistanceText)
                Text("Cuts a flat bevel across every sharp edge of the body built so far, this far back from each edge.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        case .shell:
            Section("Shell") {
                numberRow("Wall thickness (mm)", $shellThicknessText)
                Text("Hollows the body built so far, leaving walls of this thickness.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        case .extrude:
            Section("Extrude") {
                sketchPicker
                numberRow("Distance (mm)", $extrudeDistanceText)
                Picker("Type", selection: $extrudeModeChoice) {
                    Text("One side").tag("one")
                    Text("Symmetric").tag("symmetric")
                    Text("Two sides").tag("twoSided")
                }
                .font(.system(size: 20, weight: .semibold))
                if extrudeModeChoice == "twoSided" {
                    numberRow("Second distance (mm)", $extrudeSecondText)
                }
                numberRow("Taper angle (degrees)", $extrudeTaperText)
                Text("Extrude joins material. A one-sided extrude with no taper is the same shape as a Pad.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        case .loft:
            Section("Loft") {
                Picker("First profile sketch", selection: $loftAID) {
                    ForEach(sketches) { sk in
                        Text(sk.name).tag(sk.id)
                    }
                }
                .font(.system(size: 20, weight: .semibold))
                Picker("Second profile sketch", selection: $loftBID) {
                    ForEach(sketches) { sk in
                        Text(sk.name).tag(sk.id)
                    }
                }
                .font(.system(size: 20, weight: .semibold))
                Text("Blends one closed profile into the other. Both sketches need a closed profile with the same number of corners.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        case .sweep:
            Section("Sweep") {
                Picker("Profile sketch", selection: $sweepProfileID) {
                    ForEach(sketches) { sk in
                        Text(sk.name).tag(sk.id)
                    }
                }
                .font(.system(size: 20, weight: .semibold))
                Picker("Path sketch", selection: $sweepPathID) {
                    ForEach(sketches) { sk in
                        Text(sk.name).tag(sk.id)
                    }
                }
                .font(.system(size: 20, weight: .semibold))
                Text("Sweeps the closed profile along the path sketch's connected lines.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        case .booleanCutPlaceholder:
            Section("Boolean") {
                Text("Placeholder boolean — kept for older documents.")
                    .font(.system(size: 18))
            }
        }
    }

    private var sketchPicker: some View {
        Picker("Sketch", selection: $sketchID) {
            ForEach(sketches) { sk in
                Text(sk.name).tag(sk.id)
            }
        }
        .font(.system(size: 20, weight: .semibold))
    }

    private var axisPicker: some View {
        let lines = (sketches.first { $0.id == sketchID }?.entities ?? []).filter { e in
            if case .line = e { return true }
            return false
        }
        return Picker("Axis (a line in the sketch)", selection: $axisEntityID) {
            ForEach(lines, id: \.id) { e in
                Text("Line #\(e.id)").tag(e.id)
            }
        }
        .font(.system(size: 20, weight: .semibold))
    }

    private var threadFields: some View {
        Group {
            Section("Thread preset") {
                Picker("Preset", selection: $presetName) {
                    Text("Custom").tag("")
                    ForEach(Self.presetNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .font(.system(size: 20, weight: .semibold))
                .onChange(of: presetName) { _, newValue in
                    applyPreset(newValue)
                }
                Text("Picking a preset fills diameter, pitch and taper — every field below stays editable.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            Section("Thread size — all editable") {
                numberRow("Major diameter (mm)", $majorText)
                numberRow("Pitch (mm)", $pitchText)
                numberRow("Length (mm)", $threadLengthText)
                Stepper("Starts: \(spec.starts)", value: $spec.starts, in: 1...4)
                    .font(.system(size: 20, weight: .semibold))
                numberRow("Profile angle (degrees)", $profileAngleText)
                numberRow("Taper (degrees)", $taperText)
                numberRow("Clearance (mm)", $clearanceText)
            }
            Section("Thread options") {
                Picker("Standard", selection: $spec.standard) {
                    ForEach(Self.standards, id: \.self) { s in
                        Text(standardLabel(s)).tag(s)
                    }
                }
                .font(.system(size: 20, weight: .semibold))
                Picker("Kind", selection: $spec.kind) {
                    ForEach(Self.kinds, id: \.self) { k in
                        Text(k == .external ? "External (bolt)" : "Internal (nut)").tag(k)
                    }
                }
                .font(.system(size: 20, weight: .semibold))
                Picker("Hand", selection: $spec.hand) {
                    ForEach(Self.hands, id: \.self) { h in
                        Text(h == .right ? "Right-hand" : "Left-hand").tag(h)
                    }
                }
                .font(.system(size: 20, weight: .semibold))
                Toggle("Modeled thread (real ridges)", isOn: $spec.modeled)
                    .font(.system(size: 20, weight: .semibold))
                Text("Minor Ø \(mcFmt(previewSpec.minorDiameter)) · Pitch Ø \(mcFmt(previewSpec.pitchDiameter)) — from the numbers above.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func applyPreset(_ name: String) {
        guard !name.isEmpty, let preset = try? ThreadSpec.preset(name) else { return }
        majorText = mcFmt(preset.majorDiameter)
        pitchText = mcFmt(preset.pitch)
        taperText = mcFmt(preset.taperDegrees)
        spec.standard = preset.standard
    }

    /// ThreadSpec preview built from the current field values, so the
    /// derived diameters track typing (not just the saved spec).
    private var previewSpec: ThreadSpec {
        var s = spec
        s.majorDiameter = Double(majorText) ?? s.majorDiameter
        s.pitch = Double(pitchText) ?? s.pitch
        s.length = Double(threadLengthText) ?? s.length
        s.profileAngleDegrees = Double(profileAngleText) ?? s.profileAngleDegrees
        s.taperDegrees = Double(taperText) ?? s.taperDegrees
        s.clearance = Double(clearanceText) ?? s.clearance
        return s
    }

    private func standardLabel(_ s: ThreadStandard) -> String {
        switch s {
        case .isoMetric: return "ISO metric"
        case .unc: return "UNC"
        case .npt: return "NPT (tapered)"
        case .custom: return "Custom"
        }
    }

    // MARK: Field helpers

    private func numberRow(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 20, weight: .semibold))
            Spacer()
            TextField(label, text: binding)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 130)
        }
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { Int(countText) ?? 1 },
            set: { countText = "\($0)" }
        )
    }

    private func primitiveKeys(_ kind: PrimitiveKind) -> [String] {
        switch kind {
        case .box: return ["width", "depth", "height"]
        case .cylinder: return ["diameter", "height"]
        case .sphere: return ["diameter"]
        case .cone: return ["diameter", "height"]
        case .torus: return ["ringRadius", "tubeRadius"]
        }
    }

    private func primitiveLabel(_ key: String) -> String {
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

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { paramValues[key] ?? "" },
            set: { paramValues[key] = $0 }
        )
    }

    private func num(_ s: String, fallback: Double) -> Double { Double(s) ?? fallback }

    // MARK: Build the edited kind

    private func buildKind() -> FeatureKind {
        switch feature.kind {
        case .pad(_, let old):
            return .pad(sketchID: sketchID, length: num(lengthText, fallback: old))
        case .pocket(_, let old):
            return .pocket(sketchID: sketchID, depth: num(depthText, fallback: old))
        case .revolve(_, _, let old):
            return .revolve(sketchID: sketchID, axisEntityID: axisEntityID,
                            angleDegrees: num(angleText, fallback: old))
        case .primitive(let kind, let oldParams):
            var params = oldParams
            for key in primitiveKeys(kind) {
                if let text = paramValues[key], let v = Double(text) { params[key] = v }
            }
            return .primitive(kind: kind, params: params)
        case .threadShaft(let old):
            var s = spec
            s.majorDiameter = num(majorText, fallback: old.majorDiameter)
            s.pitch = num(pitchText, fallback: old.pitch)
            s.length = num(threadLengthText, fallback: old.length)
            s.profileAngleDegrees = num(profileAngleText, fallback: old.profileAngleDegrees)
            s.taperDegrees = num(taperText, fallback: old.taperDegrees)
            s.clearance = num(clearanceText, fallback: old.clearance)
            return .threadShaft(spec: s)
        case .linearPattern(_, let oldSpacing):
            let spacing = Vec3(num(spacingX, fallback: oldSpacing.x),
                               num(spacingY, fallback: oldSpacing.y),
                               num(spacingZ, fallback: oldSpacing.z))
            return .linearPattern(count: max(1, Int(countText) ?? 1), spacing: spacing)
        case .hole(_, let oldD, let oldDepth, _):
            let hk: HoleKind
            switch holeKindChoice {
            case "counterbore":
                hk = .counterbore(diameter: num(cbDiameterText, fallback: 10),
                                  depth: num(cbDepthText, fallback: 3))
            case "countersink":
                hk = .countersink(angleDegrees: num(csAngleText, fallback: 90))
            default:
                hk = .simple
            }
            return .hole(sketchID: sketchID,
                         diameter: num(holeDiameterText, fallback: oldD),
                         depth: holeThrough ? 0 : num(holeDepthText, fallback: oldDepth),
                         kind: hk)
        case .mirror:
            return .mirror(plane: mirrorPlane)
        case .fillet(let old):
            return .fillet(radius: num(filletRadiusText, fallback: old))
        case .chamfer(let old):
            return .chamfer(distance: num(chamferDistanceText, fallback: old))
        case .shell(let old):
            return .shell(thickness: num(shellThicknessText, fallback: old))
        case .extrude(let oldSketch, let oldDistance, let oldTaper, let oldMode):
            let mode: ExtrudeMode
            switch extrudeModeChoice {
            case "symmetric":
                mode = .symmetric
            case "twoSided":
                let oldSecond: Double
                if case .twoSided(let s) = oldMode { oldSecond = s } else { oldSecond = 10 }
                mode = .twoSided(second: num(extrudeSecondText, fallback: oldSecond))
            default:
                mode = .one
            }
            return .extrude(sketchID: sketchID.isEmpty ? oldSketch : sketchID,
                            distance: num(extrudeDistanceText, fallback: oldDistance),
                            taperDegrees: num(extrudeTaperText, fallback: oldTaper),
                            mode: mode)
        case .loft(let oldA, let oldB):
            return .loft(sketchA: loftAID.isEmpty ? oldA : loftAID,
                         sketchB: loftBID.isEmpty ? oldB : loftBID)
        case .sweep(let oldProfile, let oldPath):
            return .sweep(profileSketchID: sweepProfileID.isEmpty ? oldProfile : sweepProfileID,
                          pathSketchID: sweepPathID.isEmpty ? oldPath : sweepPathID)
        case .booleanCutPlaceholder:
            return .booleanCutPlaceholder
        }
    }
}
