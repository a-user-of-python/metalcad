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

        doc.parts.append(part)
        return doc
    }
}

struct DocumentsView: View {
    @StateObject private var library = DocumentLibrary()
    @EnvironmentObject private var session: AppSession
    @State private var alertInfo: DocAlert?

    var body: some View {
        NavigationStack {
            Group {
                if library.files.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 54))
                            .foregroundStyle(.secondary)
                        Text("No documents yet")
                            .font(.system(size: 26, weight: .bold))
                        Text("Tap New Document to start one with a demo part.")
                            .font(.system(size: 20))
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
                                    .font(.system(size: 26))
                                    .foregroundStyle(.orange)
                                Text(file.displayName)
                                    .font(.system(size: 22, weight: .semibold))
                                Spacer()
                                Button(role: .destructive) {
                                    library.delete(file)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 22))
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let made = library.createDemoDocument() {
                            session.open(document: made.doc, url: made.url)
                        }
                    } label: {
                        Label("New Document", systemImage: "plus")
                            .font(.system(size: 20, weight: .semibold))
                    }
                }
            }
            .onAppear { library.refresh() }
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
