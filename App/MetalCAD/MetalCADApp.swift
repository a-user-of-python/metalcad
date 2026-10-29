import SwiftUI

/// App entry point. Attaches the MCLog file sink (Documents/Logs) before
/// anything else so even a launch failure leaves a log line behind.
@main
struct MetalCADApp: App {
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logDir = docs.appendingPathComponent("Logs", isDirectory: true)
        MCLog.shared.attachFileSink(directory: logDir)
        // Implant the Cascade (Open CASCADE) engine: registers the
        // evaluator the kit's .cascadePad features rebuild through.
        CascadeBridge.register()
        // Stage 7: the app's own STEP folder (Files ▸ On My iPad ▸
        // MetalCAD ▸ STEP) — created and seeded at launch; the
        // Documents screen's Import STEP sheet reads it. (No
        // system document picker: Sean's signing breaks it.)
        STEPFolder.setup()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        MCLog.shared.info(.lifecycle, "MetalCAD launched", context: ["version": version])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
