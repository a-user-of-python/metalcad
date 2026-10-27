import SwiftUI

/// Session state for the app's two-screen flow: Home (the document
/// library) ⇄ Editor. There is no tab bar anymore (top-UI redesign,
/// 2026-10-26): Home is the root, opening a document presents the
/// editor, and the editor's Home button returns here. Diagnostics
/// moved into Home ▸ Settings.
final class AppSession: ObservableObject {
    @Published var editorModel: EditorModel?

    func open(document: CADDocument, url: URL) {
        editorModel = EditorModel(document: document, url: url)
    }

    /// Back to the files screen.
    func closeEditor() {
        editorModel = nil
    }
}

/// Top-level shell. Dark, high-contrast, large type throughout
/// (hard requirement).
struct ContentView: View {
    @StateObject private var session = AppSession()
    @AppStorage(MCAccent.key) private var accentHex: String = MCAccent.defaultHex

    var body: some View {
        Group {
            if let model = session.editorModel {
                EditorView(model: model)
                    .id(model.fileURL.path)
                    .environmentObject(session)
            } else {
                DocumentsView()
                    .environmentObject(session)
            }
        }
        .preferredColorScheme(.dark)
        // The user's accent color tints the whole app's chrome.
        .tint(MCAccent.color(hex: accentHex))
    }
}
