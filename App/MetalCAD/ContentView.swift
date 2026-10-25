import SwiftUI

/// Shared app state: which document is open in the Editor tab, and which
/// tab is showing. Documents are opened from DocumentsView via `open`.
final class AppSession: ObservableObject {
    @Published var editorModel: EditorModel?
    @Published var tab: Int = 0

    func open(document: CADDocument, url: URL) {
        editorModel = EditorModel(document: document, url: url)
        tab = 1
    }
}

/// Top-level shell: Documents / Editor / Diagnostics.
/// Dark, high-contrast, large type throughout (hard requirement).
struct ContentView: View {
    @StateObject private var session = AppSession()

    var body: some View {
        TabView(selection: $session.tab) {
            DocumentsView()
                .environmentObject(session)
                .tabItem { Label("Documents", systemImage: "folder") }
                .tag(0)

            editorTab
                .tabItem { Label("Editor", systemImage: "cube") }
                .tag(1)

            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "list.bullet.rectangle") }
                .tag(2)
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
    }

    @ViewBuilder
    private var editorTab: some View {
        if let model = session.editorModel {
            EditorView(model: model)
                .id(model.fileURL.path)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "cube")
                    .font(.system(size: 54))
                    .foregroundStyle(.secondary)
                Text("No document open")
                    .font(.system(size: 26, weight: .bold))
                Text("Open one from the Documents tab.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
