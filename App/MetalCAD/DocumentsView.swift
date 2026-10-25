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

    /// Create a demo document (rectangle sketch + Pad + M10 thread shaft),
    /// save it, and return it ready to open.
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

/// Builds the starter document used by "New document".
enum DemoFactory {
    static func make(name: String) -> CADDocument {
        var doc = CADDocument(name: name)
        var part = Part(name: "Demo Part")

        var sketch = Sketch(name: "Plate", plane: .xy)
        sketch.addRectangle(from: Vec2(-20, -15), to: Vec2(20, 15))
        part.sketches.append(sketch)
        part.features.append(Feature(name: "Plate Pad",
                                     kind: .pad(sketchID: sketch.id, length: 10)))

        var spec = ThreadSpec()
        if let preset = try? ThreadSpec.preset("M10") { spec = preset }
        part.features.append(Feature(name: "M10 Thread Shaft",
                                     kind: .threadShaft(spec: spec)))

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
