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
                                    .mcFont(22, weight: .semibold)
                                    .foregroundStyle(.primary)
                                Text("\(String(format: "%.2f", mat.density)) g/cm³ · metalness \(mcFmt(mat.metalness)) · roughness \(mcFmt(mat.roughness))")
                                    .mcFont(16)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if mat.id == currentID {
                                Image(systemName: "checkmark.circle.fill")
                                    .mcFont(24)
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
                        .mcFont(19, weight: .semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Feature editor (every parameter editable, all 25 kinds)

/// Full editor for one feature: every parameter of its kind is a field.
/// Nothing is prefixed — Apply writes the numbers back and the part
/// rebuilds. Covers all 25 FeatureKind cases of kit v4.
struct FeatureEditorSheet: View {
    let feature: Feature
    let sketches: [Sketch]
    /// Planar faces of the part as built now, in kernel order — the
    /// index space ExtrudeEnd.upToFace refers to (extrude2 editor).
    var currentFaces: [PlanarFace] = []
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
    // extrude2 (v4)
    @State private var ex2DistanceText: String = "10"
    @State private var ex2TaperText: String = "0"
    @State private var ex2ModeChoice: String = "one"
    @State private var ex2SecondText: String = "10"
    @State private var ex2Operation: String = "join"
    @State private var ex2EndChoice: String = "dimension"
    @State private var ex2FaceIndex: Int = 0
    // chamfer2 (v4)
    @State private var chamferModeChoice: String = "equal"
    @State private var chamferAText: String = "2"
    @State private var chamferBText: String = "1"
    @State private var chamferAngleText: String = "45"
    // coil (v4)
    @State private var coilRadiusText: String = "15"
    @State private var coilPitchText: String = "8"
    @State private var coilTurnsText: String = "5"
    @State private var coilWireText: String = "2"
    // pipe (v4) — path sketch uses the shared sketchID state
    @State private var pipeRadiusText: String = "4"
    // rib (v4) — profile sketch uses the shared sketchID state
    @State private var ribThicknessText: String = "3"
    @State private var ribDepthText: String = "12"
    // draft (v4)
    @State private var draftAngleText: String = "3"
    @State private var draftAxis: Int = 2
    // scale (v4)
    @State private var scaleXText: String = "1"
    @State private var scaleYText: String = "1"
    @State private var scaleZText: String = "1"
    // move body (v4)
    @State private var moveXText: String = "0"
    @State private var moveYText: String = "0"
    @State private var moveZText: String = "0"
    @State private var moveAxis: Int = 2
    @State private var moveDegreesText: String = "0"
    // split body (v4)
    @State private var splitAxis: Int = 2
    @State private var splitOffsetText: String = "0"
    // circular pattern (v4)
    @State private var circCountText: String = "6"
    @State private var circAxis: Int = 2
    @State private var circTotalText: String = "360"

    private static let presetNames = ["M3", "M4", "M5", "M6", "M8", "M10", "M12", "M16", "M20",
                                      "1/4-20", "5/16-18", "3/8-16", "1/2-13",
                                      "NPT 1/4", "NPT 3/8", "NPT 1/2"]
    private static let standards: [ThreadStandard] = [.isoMetric, .unc, .npt, .custom]
    private static let kinds: [ThreadKind] = [.external, .internal]
    private static let hands: [ThreadHand] = [.right, .left]

    init(feature: Feature, sketches: [Sketch], currentFaces: [PlanarFace] = [],
         filletMaxFeasible: Double? = nil,
         onSave: @escaping (String, FeatureKind) -> Void,
         onCancel: @escaping () -> Void) {
        self.feature = feature
        self.sketches = sketches
        self.currentFaces = currentFaces
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
        case .extrude2(let sid, let distance, let taper, let mode, let op, let end):
            initialSketch = sid
            _ex2DistanceText = State(initialValue: mcFmt(distance))
            _ex2TaperText = State(initialValue: mcFmt(taper))
            switch mode {
            case .one:
                _ex2ModeChoice = State(initialValue: "one")
            case .symmetric:
                _ex2ModeChoice = State(initialValue: "symmetric")
            case .twoSided(let second):
                _ex2ModeChoice = State(initialValue: "twoSided")
                _ex2SecondText = State(initialValue: mcFmt(second))
            }
            switch op {
            case .join: _ex2Operation = State(initialValue: "join")
            case .cut: _ex2Operation = State(initialValue: "cut")
            case .intersect: _ex2Operation = State(initialValue: "intersect")
            case .newBody: _ex2Operation = State(initialValue: "newBody")
            }
            switch end {
            case .dimension:
                _ex2EndChoice = State(initialValue: "dimension")
            case .throughAll:
                _ex2EndChoice = State(initialValue: "throughAll")
            case .upToFace(let faceIndex):
                _ex2EndChoice = State(initialValue: "upToFace")
                _ex2FaceIndex = State(initialValue: faceIndex)
            }
        case .chamfer2(let mode):
            switch mode {
            case .equal(let d):
                _chamferModeChoice = State(initialValue: "equal")
                _chamferAText = State(initialValue: mcFmt(d))
            case .twoDistances(let a, let b):
                _chamferModeChoice = State(initialValue: "two")
                _chamferAText = State(initialValue: mcFmt(a))
                _chamferBText = State(initialValue: mcFmt(b))
            case .distanceAngle(let d, let deg):
                _chamferModeChoice = State(initialValue: "angle")
                _chamferAText = State(initialValue: mcFmt(d))
                _chamferAngleText = State(initialValue: mcFmt(deg))
            }
        case .coil(let radius, let pitch, let turns, let wire):
            _coilRadiusText = State(initialValue: mcFmt(radius))
            _coilPitchText = State(initialValue: mcFmt(pitch))
            _coilTurnsText = State(initialValue: mcFmt(turns))
            _coilWireText = State(initialValue: mcFmt(wire))
        case .pipe(let pathID, let radius):
            initialSketch = pathID
            _pipeRadiusText = State(initialValue: mcFmt(radius))
        case .rib(let sid, let thickness, let depth):
            initialSketch = sid
            _ribThicknessText = State(initialValue: mcFmt(thickness))
            _ribDepthText = State(initialValue: mcFmt(depth))
        case .draftBody(let angle, let axis):
            _draftAngleText = State(initialValue: mcFmt(angle))
            _draftAxis = State(initialValue: axis)
        case .scaleBody(let f):
            _scaleXText = State(initialValue: mcFmt(f.x))
            _scaleYText = State(initialValue: mcFmt(f.y))
            _scaleZText = State(initialValue: mcFmt(f.z))
        case .moveBody(let t, let axis, let degrees):
            _moveXText = State(initialValue: mcFmt(t.x))
            _moveYText = State(initialValue: mcFmt(t.y))
            _moveZText = State(initialValue: mcFmt(t.z))
            _moveAxis = State(initialValue: axis)
            _moveDegreesText = State(initialValue: mcFmt(degrees))
        case .splitBody(let axis, let offset):
            _splitAxis = State(initialValue: axis)
            _splitOffsetText = State(initialValue: mcFmt(offset))
        case .circularPattern(let count, let axis, let total):
            _circCountText = State(initialValue: "\(count)")
            _circAxis = State(initialValue: axis)
            _circTotalText = State(initialValue: mcFmt(total))
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
                        .mcFont(21, weight: .semibold)
                }
                kindFields
            }
            .navigationTitle("Edit Feature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .mcFont(19, weight: .semibold)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onSave(nameText, buildKind()) }
                        .mcFont(19, weight: .bold)
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
                    .mcFont(20, weight: .semibold)
                numberRow("Spacing X (mm)", $spacingX)
                numberRow("Spacing Y (mm)", $spacingY)
                numberRow("Spacing Z (mm)", $spacingZ)
            }
        case .hole:
            Section("Hole") {
                sketchPicker
                numberRow("Diameter (mm)", $holeDiameterText)
                Toggle("Through (all the way)", isOn: $holeThrough)
                    .mcFont(20, weight: .semibold)
                if !holeThrough {
                    numberRow("Depth (mm)", $holeDepthText)
                }
                Picker("Type", selection: $holeKindChoice) {
                    Text("Simple").tag("simple")
                    Text("Counterbore").tag("counterbore")
                    Text("Countersink").tag("countersink")
                }
                .mcFont(20, weight: .semibold)
                if holeKindChoice == "counterbore" {
                    numberRow("Bore diameter (mm)", $cbDiameterText)
                    numberRow("Bore depth (mm)", $cbDepthText)
                }
                if holeKindChoice == "countersink" {
                    numberRow("Sink angle (degrees)", $csAngleText)
                }
                Text("Drill points are the points and circle centers in the chosen sketch.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .mirror:
            Section("Mirror") {
                Picker("Plane", selection: $mirrorPlane) {
                    ForEach(MirrorPlane.allCases, id: \.self) { plane in
                        Text(plane.displayName).tag(plane)
                    }
                }
                .mcFont(20, weight: .semibold)
            }
        case .fillet:
            Section("Fillet") {
                numberRow("Radius (mm)", $filletRadiusText)
                if let maxF = filletMaxFeasible {
                    Text("The current radius is too big for this body — the largest that fits is ≈ \(mcFmt(maxF)) mm. (MCAD-FT408)")
                        .mcFont(17, weight: .semibold)
                        .foregroundStyle(.orange)
                    Button("Use ≈ \(mcFmt(maxF)) mm") {
                        filletRadiusText = mcFmt(maxF)
                    }
                    .mcFont(19, weight: .semibold)
                }
                Text("Rounds every sharp edge of the body built so far. If a radius cannot fit, the rebuild reports MCAD-FT408 with the largest radius that does.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .chamfer:
            Section("Chamfer") {
                numberRow("Distance (mm)", $chamferDistanceText)
                Text("Cuts a flat bevel across every sharp edge of the body built so far, this far back from each edge.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .shell:
            Section("Shell") {
                numberRow("Wall thickness (mm)", $shellThicknessText)
                Text("Hollows the body built so far, leaving walls of this thickness.")
                    .mcFont(16)
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
                .mcFont(20, weight: .semibold)
                if extrudeModeChoice == "twoSided" {
                    numberRow("Second distance (mm)", $extrudeSecondText)
                }
                numberRow("Taper angle (degrees)", $extrudeTaperText)
                Text("Extrude joins material. A one-sided extrude with no taper is the same shape as a Pad.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .loft:
            Section("Loft") {
                Picker("First profile sketch", selection: $loftAID) {
                    ForEach(sketches) { sk in
                        Text(sk.name).tag(sk.id)
                    }
                }
                .mcFont(20, weight: .semibold)
                Picker("Second profile sketch", selection: $loftBID) {
                    ForEach(sketches) { sk in
                        Text(sk.name).tag(sk.id)
                    }
                }
                .mcFont(20, weight: .semibold)
                Text("Blends one closed profile into the other. Both sketches need a closed profile with the same number of corners.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .sweep:
            Section("Sweep") {
                Picker("Profile sketch", selection: $sweepProfileID) {
                    ForEach(sketches) { sk in
                        Text(sk.name).tag(sk.id)
                    }
                }
                .mcFont(20, weight: .semibold)
                Picker("Path sketch", selection: $sweepPathID) {
                    ForEach(sketches) { sk in
                        Text(sk.name).tag(sk.id)
                    }
                }
                .mcFont(20, weight: .semibold)
                Text("Sweeps the closed profile along the path sketch's connected lines.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .booleanCutPlaceholder:
            Section("Boolean") {
                Text("Placeholder boolean — kept for older documents.")
                    .mcFont(18)
            }
        case .extrude2:
            Section("Extrude") {
                sketchPicker
                Picker("Operation", selection: $ex2Operation) {
                    Text("Join (add)").tag("join")
                    Text("Cut (remove)").tag("cut")
                    Text("Intersect (keep overlap)").tag("intersect")
                    Text("New Body").tag("newBody")
                }
                .mcFont(20, weight: .semibold)
                Picker("End", selection: $ex2EndChoice) {
                    Text("Dimension").tag("dimension")
                    Text("Through All").tag("throughAll")
                    Text("Up to Face").tag("upToFace")
                }
                .mcFont(20, weight: .semibold)
                if ex2EndChoice == "dimension" {
                    numberRow("Distance (mm)", $ex2DistanceText)
                }
                if ex2EndChoice == "upToFace" {
                    if currentFaces.isEmpty {
                        Text("The part has no faces right now — Up to Face will fail until a body exists before this feature.")
                            .mcFont(16, weight: .semibold)
                            .foregroundStyle(.orange)
                    } else {
                        Picker("Target face (part as built now)", selection: $ex2FaceIndex) {
                            ForEach(Array(currentFaces.enumerated()), id: \.offset) { i, face in
                                Text("Face \(i + 1) · \(mcFaceLabel(face))").tag(i)
                            }
                        }
                        .mcFont(20, weight: .semibold)
                    }
                }
                Picker("Type", selection: $ex2ModeChoice) {
                    Text("One side").tag("one")
                    Text("Symmetric").tag("symmetric")
                    Text("Two sides").tag("twoSided")
                }
                .mcFont(20, weight: .semibold)
                if ex2ModeChoice == "twoSided" {
                    numberRow("Second distance (mm)", $ex2SecondText)
                }
                numberRow("Taper angle (degrees)", $ex2TaperText)
                Text("Join adds, Cut removes, Intersect keeps only the overlap, New Body keeps the solid separate.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .chamfer2:
            Section("Chamfer") {
                Picker("Mode", selection: $chamferModeChoice) {
                    Text("Equal").tag("equal")
                    Text("Two distances").tag("two")
                    Text("Distance + Angle").tag("angle")
                }
                .mcFont(20, weight: .semibold)
                numberRow(chamferModeChoice == "two" ? "Distance A (mm)" : "Distance (mm)", $chamferAText)
                if chamferModeChoice == "two" {
                    numberRow("Distance B (mm)", $chamferBText)
                }
                if chamferModeChoice == "angle" {
                    numberRow("Angle (degrees)", $chamferAngleText)
                }
                Text("Cuts a flat bevel across every sharp edge of the body built so far.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .coil:
            Section("Coil") {
                numberRow("Coil radius (mm)", $coilRadiusText)
                numberRow("Pitch (mm / turn)", $coilPitchText)
                numberRow("Turns", $coilTurnsText)
                numberRow("Wire radius (mm)", $coilWireText)
                Text("A spring wound around the Z axis from the origin.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .pipe:
            Section("Pipe") {
                Picker("Path sketch", selection: $sketchID) {
                    ForEach(sketches) { sk in
                        Text(sk.name).tag(sk.id)
                    }
                }
                .mcFont(20, weight: .semibold)
                numberRow("Pipe radius (mm)", $pipeRadiusText)
                Text("A round tube swept along the path sketch's connected lines.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .rib:
            Section("Rib") {
                sketchPicker
                numberRow("Thickness (mm)", $ribThicknessText)
                numberRow("Depth into body (mm)", $ribDepthText)
                Text("A thin wall grown from the profile line toward the body. Trimmed approximately at curved surfaces — exact against flat ones.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .draftBody:
            Section("Draft") {
                numberRow("Angle (degrees)", $draftAngleText)
                Picker("Pull axis", selection: $draftAxis) {
                    Text("X").tag(0)
                    Text("Y").tag(1)
                    Text("Z").tag(2)
                }
                .mcFont(20, weight: .semibold)
                Text("Mold-release taper: a positive angle narrows the body toward the top of the pull axis. Between −30° and 30°.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .scaleBody:
            Section("Scale") {
                numberRow("Factor X", $scaleXText)
                numberRow("Factor Y", $scaleYText)
                numberRow("Factor Z", $scaleZText)
                Text("Scales the body built so far about its center.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .moveBody:
            Section("Move Body") {
                numberRow("Move X (mm)", $moveXText)
                numberRow("Move Y (mm)", $moveYText)
                numberRow("Move Z (mm)", $moveZText)
                Picker("Rotate around", selection: $moveAxis) {
                    Text("X").tag(0)
                    Text("Y").tag(1)
                    Text("Z").tag(2)
                }
                .mcFont(20, weight: .semibold)
                numberRow("Rotation (degrees)", $moveDegreesText)
                Text("Moves the whole body, then rotates it around the axis through its center.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .splitBody:
            Section("Split Body") {
                Picker("Axis", selection: $splitAxis) {
                    Text("X").tag(0)
                    Text("Y").tag(1)
                    Text("Z").tag(2)
                }
                .mcFont(20, weight: .semibold)
                numberRow("Offset (mm, world)", $splitOffsetText)
                Text("Cuts the body into two bodies at a plane perpendicular to the axis at this offset.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        case .circularPattern:
            Section("Circular pattern") {
                Stepper("Copies: \(Int(circCountText) ?? 1)", value: circCountBinding, in: 2...36)
                    .mcFont(20, weight: .semibold)
                Picker("Around axis", selection: $circAxis) {
                    Text("X").tag(0)
                    Text("Y").tag(1)
                    Text("Z").tag(2)
                }
                .mcFont(20, weight: .semibold)
                numberRow("Total angle (degrees)", $circTotalText)
                Text("Repeats the whole body built so far around the axis through its center.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sketchPicker: some View {
        Picker("Sketch", selection: $sketchID) {
            ForEach(sketches) { sk in
                Text(sk.name).tag(sk.id)
            }
        }
        .mcFont(20, weight: .semibold)
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
        .mcFont(20, weight: .semibold)
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
                .mcFont(20, weight: .semibold)
                .onChange(of: presetName) { _, newValue in
                    applyPreset(newValue)
                }
                Text("Picking a preset fills diameter, pitch and taper — every field below stays editable.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
            Section("Thread size — all editable") {
                numberRow("Major diameter (mm)", $majorText)
                numberRow("Pitch (mm)", $pitchText)
                numberRow("Length (mm)", $threadLengthText)
                Stepper("Starts: \(spec.starts)", value: $spec.starts, in: 1...4)
                    .mcFont(20, weight: .semibold)
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
                .mcFont(20, weight: .semibold)
                Picker("Kind", selection: $spec.kind) {
                    ForEach(Self.kinds, id: \.self) { k in
                        Text(k == .external ? "External (bolt)" : "Internal (nut)").tag(k)
                    }
                }
                .mcFont(20, weight: .semibold)
                Picker("Hand", selection: $spec.hand) {
                    ForEach(Self.hands, id: \.self) { h in
                        Text(h == .right ? "Right-hand" : "Left-hand").tag(h)
                    }
                }
                .mcFont(20, weight: .semibold)
                Toggle("Modeled thread (real ridges)", isOn: $spec.modeled)
                    .mcFont(20, weight: .semibold)
                Text("Minor Ø \(mcFmt(previewSpec.minorDiameter)) · Pitch Ø \(mcFmt(previewSpec.pitchDiameter)) — from the numbers above.")
                    .mcFont(16)
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
                .mcFont(20, weight: .semibold)
            Spacer()
            TextField(label, text: binding)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .mcFont(20, weight: .semibold)
                .frame(width: 130)
        }
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { Int(countText) ?? 1 },
            set: { countText = "\($0)" }
        )
    }

    private var circCountBinding: Binding<Int> {
        Binding(
            get: { Int(circCountText) ?? 1 },
            set: { circCountText = "\($0)" }
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
        case .extrude2(let oldSketch, let oldDistance, let oldTaper, let oldMode, _, _):
            let mode: ExtrudeMode
            switch ex2ModeChoice {
            case "symmetric":
                mode = .symmetric
            case "twoSided":
                let oldSecond: Double
                if case .twoSided(let s) = oldMode { oldSecond = s } else { oldSecond = 10 }
                mode = .twoSided(second: num(ex2SecondText, fallback: oldSecond))
            default:
                mode = .one
            }
            let op: BodyOperation
            switch ex2Operation {
            case "cut": op = .cut
            case "intersect": op = .intersect
            case "newBody": op = .newBody
            default: op = .join
            }
            let end: ExtrudeEnd
            switch ex2EndChoice {
            case "throughAll": end = .throughAll
            case "upToFace": end = .upToFace(faceIndex: ex2FaceIndex)
            default: end = .dimension
            }
            return .extrude2(sketchID: sketchID.isEmpty ? oldSketch : sketchID,
                             distance: num(ex2DistanceText, fallback: oldDistance),
                             taperDegrees: num(ex2TaperText, fallback: oldTaper),
                             mode: mode, operation: op, end: end)
        case .chamfer2(let oldMode):
            let old = oldMode.distances
            switch chamferModeChoice {
            case "two":
                return .chamfer2(mode: .twoDistances(num(chamferAText, fallback: old.0),
                                                     num(chamferBText, fallback: old.1)))
            case "angle":
                let oldAngle: Double
                if case .distanceAngle(_, let deg) = oldMode { oldAngle = deg } else { oldAngle = 45 }
                return .chamfer2(mode: .distanceAngle(num(chamferAText, fallback: old.0),
                                                      num(chamferAngleText, fallback: oldAngle)))
            default:
                return .chamfer2(mode: .equal(num(chamferAText, fallback: old.0)))
            }
        case .coil(let oldR, let oldP, let oldT, let oldW):
            return .coil(radius: num(coilRadiusText, fallback: oldR),
                         pitch: num(coilPitchText, fallback: oldP),
                         turns: num(coilTurnsText, fallback: oldT),
                         wireRadius: num(coilWireText, fallback: oldW))
        case .pipe(let oldPath, let oldRadius):
            return .pipe(pathSketchID: sketchID.isEmpty ? oldPath : sketchID,
                         radius: num(pipeRadiusText, fallback: oldRadius))
        case .rib(let oldSketch, let oldThickness, let oldDepth):
            return .rib(sketchID: sketchID.isEmpty ? oldSketch : sketchID,
                        thickness: num(ribThicknessText, fallback: oldThickness),
                        depth: num(ribDepthText, fallback: oldDepth))
        case .draftBody(let oldAngle, _):
            return .draftBody(angleDegrees: num(draftAngleText, fallback: oldAngle),
                              pullAxis: draftAxis)
        case .scaleBody(let old):
            return .scaleBody(factors: Vec3(num(scaleXText, fallback: old.x),
                                            num(scaleYText, fallback: old.y),
                                            num(scaleZText, fallback: old.z)))
        case .moveBody(let oldT, _, let oldDegrees):
            return .moveBody(translation: Vec3(num(moveXText, fallback: oldT.x),
                                               num(moveYText, fallback: oldT.y),
                                               num(moveZText, fallback: oldT.z)),
                             rotationAxis: moveAxis,
                             rotationDegrees: num(moveDegreesText, fallback: oldDegrees))
        case .splitBody(_, let oldOffset):
            return .splitBody(axis: splitAxis,
                              offset: num(splitOffsetText, fallback: oldOffset))
        case .circularPattern(_, _, let oldTotal):
            return .circularPattern(count: max(2, Int(circCountText) ?? 2),
                                    axis: circAxis,
                                    totalDegrees: num(circTotalText, fallback: oldTotal))
        case .booleanCutPlaceholder:
            return .booleanCutPlaceholder
        }
    }
}
