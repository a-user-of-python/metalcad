import SwiftUI

/// One document file in Documents/Docs.
struct DocFile: Identifiable {
    let url: URL
    var id: String { url.path }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

/// Alert payload for document open/save failures (carries the MCAD code).
struct DocAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let code: String?
}

/// Lists, creates, opens and deletes the JSON documents in Documents/Docs.
final class DocumentLibrary: ObservableObject {
    @Published var files: [DocFile] = []
    let docsDir: URL

    init() {
        docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: docsDir, includingPropertiesForKeys: nil)) ?? []
        files = urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { DocFile(url: $0) }
    }

    /// Create the v2 demo document (base plate + pocket + through holes
    /// + boss on the top face, Stainless 304), save it, and return it
    /// ready to open.
    func createDemoDocument() -> (doc: CADDocument, url: URL)? {
        var n = files.count + 1
        var name = "Untitled \(n)"
        var url = docsDir.appendingPathComponent(name + ".json")
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            name = "Untitled \(n)"
            url = docsDir.appendingPathComponent(name + ".json")
        }
        let doc = DemoFactory.make(name: name)
        do {
            try IOService.saveJSON(doc, to: url)
            refresh()
            return (doc, url)
        } catch let e as CADError {
            MCLog.shared.log(error: e, category: .io)
            return nil
        } catch {
            MCLog.shared.log(error: .unknown("\(error)"), category: .io)
            return nil
        }
    }

    /// Create a BLANK document — one empty part, default material,
    /// no sketches, no features, no solid — save it, and return it
    /// ready to open. (User documents start blank; the demo part is
    /// `createDemoDocument`, kept separate and untouched.)
    func createBlankDocument() -> (doc: CADDocument, url: URL)? {
        var n = files.count + 1
        var name = "Untitled \(n)"
        var url = docsDir.appendingPathComponent(name + ".json")
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            name = "Untitled \(n)"
            url = docsDir.appendingPathComponent(name + ".json")
        }
        var doc = CADDocument(name: name)
        // Part's default materialID is the library default material.
        doc.parts.append(Part(name: "Part"))
        do {
            try IOService.saveJSON(doc, to: url)
            refresh()
            return (doc, url)
        } catch let e as CADError {
            MCLog.shared.log(error: e, category: .io)
            return nil
        } catch {
            MCLog.shared.log(error: .unknown("\(error)"), category: .io)
            return nil
        }
    }

    /// Create a document whose only part starts from an imported
    /// STEP file (Stage 7): the file's bytes become an
    /// `.importedSTEP` base feature and the document is named
    /// after the file. Over the document size cap → MCAD-IO702,
    /// like any unreadable import.
    func createImportedDocument(from stepURL: URL) -> Result<(doc: CADDocument, url: URL), CADError> {
        let data: Data
        do {
            data = try Data(contentsOf: stepURL)
        } catch {
            return .failure(.importFileUnreadable("couldn't read \(stepURL.lastPathComponent)"))
        }
        guard data.count <= DocumentEngine.maxImportedSTEPBytes else {
            return .failure(.importFileUnreadable(
                "that STEP file is \(data.count / (1024 * 1024)) MB — too large to keep inside a document (the limit is \(DocumentEngine.maxImportedSTEPBytes / (1024 * 1024)) MB)"))
        }
        let baseName = stepURL.deletingPathExtension().lastPathComponent
        var name = baseName
        var url = docsDir.appendingPathComponent(name + ".json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            name = "\(baseName) \(n)"
            url = docsDir.appendingPathComponent(name + ".json")
            n += 1
        }
        var doc = CADDocument(name: name)
        var part = Part(name: baseName)
        part.features.append(Feature(name: "Imported STEP — \(stepURL.lastPathComponent)",
                                     kind: .importedSTEP(name: stepURL.lastPathComponent, stepData: data)))
        doc.parts.append(part)
        do {
            try IOService.saveJSON(doc, to: url)
            refresh()
            return .success((doc, url))
        } catch let e as CADError {
            return .failure(e)
        } catch {
            return .failure(.unknown("\(error)"))
        }
    }

    func delete(_ file: DocFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
            MCLog.shared.info(.document, "document deleted", context: ["file": file.displayName])
        } catch {
            MCLog.shared.log(error: .unknown("\(error)"), category: .io)
        }
        refresh()
    }
}

/// Builds the starter document used by "New document". The v2 demo shows
/// the new features end to end: a base plate, a real pocket, through
/// holes, and a boss padded from a sketch on the plate's top face —
/// all in Stainless 304.
enum DemoFactory {
    static func make(name: String) -> CADDocument {
        var doc = CADDocument(name: name)
        var part = Part(name: "Demo Part")
        part.materialID = "stainless-304"

        // Base plate: 60 x 40 sketch, padded 10 mm.
        var plate = Sketch(name: "Plate", plane: .xy)
        plate.addRectangle(from: Vec2(-30, -20), to: Vec2(30, 20))
        part.sketches.append(plate)
        part.features.append(Feature(name: "Base Plate",
                                     kind: .pad(sketchID: plate.id, length: 10)))

        // The plate's top face (z = 10) — pocket, holes and the boss
        // sketch all live on it, exactly like Sketch on Face creates.
        let topPlane = Plane3(origin: Vec3(0, 0, 10),
                              xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))

        // Pocket: 30 x 20 recess, 4 mm deep.
        var pocketSketch = Sketch(name: "Pocket Outline", plane: topPlane)
        pocketSketch.addRectangle(from: Vec2(-15, -10), to: Vec2(15, 10))
        part.sketches.append(pocketSketch)
        part.features.append(Feature(name: "Pocket",
                                     kind: .pocket(sketchID: pocketSketch.id, depth: 4)))

        // Two through holes, drilled at the sketch points.
        var holeSketch = Sketch(name: "Hole Points", plane: topPlane)
        holeSketch.addPoint(Vec2(-22, -12))
        holeSketch.addPoint(Vec2(-22, 12))
        part.sketches.append(holeSketch)
        part.features.append(Feature(name: "Holes",
                                     kind: .hole(sketchID: holeSketch.id, diameter: 6,
                                                 depth: 0, kind: .simple)))

        // Boss: a circle sketched on the top face, padded up 6 mm.
        var bossSketch = Sketch(name: "Face Sketch — Boss", plane: topPlane)
        bossSketch.addCircle(Vec2(22, 0), 5)
        part.sketches.append(bossSketch)
        part.features.append(Feature(name: "Boss",
                                     kind: .pad(sketchID: bossSketch.id, length: 6)))

        // Cascade boss: a hexagon on the top face, padded 6 mm by
        // the Open CASCADE engine (the implant) — its feature row
        // shows OCCT's own volume readout.
        var hexSketch = Sketch(name: "Cascade Hex", plane: topPlane)
        let hexCenter = Vec2(-22, 0)
        let hexR = 4.0
        var hexPts: [Vec2] = []
        for i in 0..<6 {
            let a = Double(i) * Double.pi / 3
            hexPts.append(hexCenter + Vec2(hexR * cos(a), hexR * sin(a)))
        }
        for i in 0..<6 { hexSketch.addLine(hexPts[i], hexPts[(i + 1) % 6]) }
        part.sketches.append(hexSketch)
        part.features.append(Feature(name: "Cascade Boss",
                                     kind: .cascadePad(sketchID: hexSketch.id, length: 6)))

        doc.parts.append(part)
        return doc
    }
}

struct DocumentsView: View {
    @StateObject private var library = DocumentLibrary()
    @EnvironmentObject private var session: AppSession
    @State private var alertInfo: DocAlert?
    @State private var showSettings = false
    @State private var showImportSTEP = false
    @AppStorage(MCAccent.key) private var accentHex: String = MCAccent.defaultHex
    private var accent: Color { MCAccent.color(hex: accentHex) }

    var body: some View {
        NavigationStack {
            Group {
                if library.files.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.badge.plus")
                            .mcFont(54)
                            .foregroundStyle(.secondary)
                        Text("No documents yet")
                            .mcFont(26, weight: .bold)
                        Text("Tap New Document to start a blank document.")
                            .mcFont(20)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(library.files) { file in
                            HStack(spacing: 14) {
                                Image(systemName: "doc")
                                    .mcFont(26)
                                    .foregroundStyle(accent)
                                Text(file.displayName)
                                    .mcFont(22, weight: .semibold)
                                Spacer()
                                Button(role: .destructive) {
                                    library.delete(file)
                                } label: {
                                    Image(systemName: "trash")
                                        .mcFont(22)
                                }
                                .buttonStyle(.plain)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { open(file) }
                        }
                    }
                }
            }
            .navigationTitle("Documents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .mcFont(20, weight: .semibold)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showImportSTEP = true
                    } label: {
                        Label("Import STEP", systemImage: "square.and.arrow.down")
                            .mcFont(20, weight: .semibold)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let made = library.createBlankDocument() {
                            session.open(document: made.doc, url: made.url)
                        }
                    } label: {
                        Label("New Document", systemImage: "plus")
                            .mcFont(20, weight: .semibold)
                    }
                }
            }
            .onAppear { library.refresh() }
            .sheet(isPresented: $showSettings) {
                HomeSettingsView()
            }
            .sheet(isPresented: $showImportSTEP) {
                STEPImportSheet { stepURL in
                    switch library.createImportedDocument(from: stepURL) {
                    case .success(let made):
                        showImportSTEP = false
                        session.open(document: made.doc, url: made.url)
                    case .failure(let e):
                        MCLog.shared.log(error: e, category: .io)
                        showImportSTEP = false
                        alertInfo = DocAlert(title: "Couldn't import STEP",
                                             message: e.userMessage, code: e.code)
                    }
                }
            }
            .alert(item: $alertInfo) { info in
                Alert(
                    title: Text(info.title),
                    message: Text(info.code == nil ? info.message : "\(info.message)\n\(info.code!)"),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func open(_ file: DocFile) {
        do {
            let (doc, warnings) = try IOService.loadJSON(from: file.url)
            for w in warnings { MCLog.shared.log(error: w, category: .io) }
            session.open(document: doc, url: file.url)
        } catch let e as CADError {
            MCLog.shared.log(error: e, category: .io)
            alertInfo = DocAlert(title: "Couldn't open document",
                                 message: e.userMessage, code: e.code)
        } catch {
            let e = CADError.unknown("\(error)")
            MCLog.shared.log(error: e, category: .io)
            alertInfo = DocAlert(title: "Couldn't open document",
                                 message: e.userMessage, code: e.code)
        }
    }
}

/// Home ▸ Settings (gear on the Documents screen): the accent
/// color picker and the Diagnostics entry. The accent choice is
/// one @AppStorage hex shared by the whole app — editor chrome,
/// 3D highlights, preview tint — and applies the moment it changes.
struct HomeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MCAccent.key) private var accentHex: String = MCAccent.defaultHex
    @State private var showDiagnostics = false

    private var accentBinding: Binding<Color> {
        Binding(
            get: { MCAccent.color(hex: accentHex) },
            set: { accentHex = MCAccent.hexString(from: $0) }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 14) {
                        ForEach(MCAccent.swatches, id: \.name) { swatch in
                            Button {
                                accentHex = swatch.hex
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(MCAccent.color(hex: swatch.hex))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Circle().stroke(Color.white, lineWidth: 3)
                                                .opacity(accentHex.uppercased() == swatch.hex.uppercased() ? 1 : 0)
                                        )
                                    Text(swatch.name)
                                        .mcFont(14, weight: .semibold)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(swatch.name) accent")
                        }
                    }
                    .padding(.vertical, 6)
                    ColorPicker("Custom color", selection: accentBinding,
                                supportsOpacity: false)
                        .mcFont(20, weight: .semibold)
                } header: {
                    Text("Accent color")
                } footer: {
                    Text("Colors the buttons, selection highlights, sketch glow and previews across the app. Your parts' materials are not affected.")
                        .mcFont(15)
                }

                Section("Diagnostics") {
                    Button {
                        showDiagnostics = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "list.bullet.rectangle")
                                .mcFont(22)
                            Text("View diagnostics log")
                                .mcFont(20, weight: .semibold)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .mcFont(17, weight: .semibold)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    Text("Cascade Pad features are built by Open CASCADE Technology 8.0.1 (© Open Cascade SAS), licensed under LGPL 2.1 with the Open CASCADE exception. The full licence texts are included in the app bundle.")
                        .mcFont(15)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Geometry engine")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .mcFont(19, weight: .semibold)
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
            }
        }
        .preferredColorScheme(.dark)
    }
}
