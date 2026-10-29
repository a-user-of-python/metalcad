import Foundation
import SwiftUI

/// Stage 7: STEP import through the Files app — the NOVA /
/// CascadeDemo recipe, because Sean's signing certificates break
/// the in-app system document picker, so MetalCAD never shows
/// one. At launch the app creates its own STEP folder inside its
/// Documents (visible in Files as "On My iPad → MetalCAD → STEP",
/// next to Docs and Logs), seeds it with a README and a sample
/// plate, and the Documents screen's Import STEP sheet lists the
/// `.step` / `.stp` files found there.
///
/// Picking a file reads its bytes into a new document as an
/// `.importedSTEP` base feature — the bytes live inside the
/// document, so the document stays one self-contained file.
enum STEPFolder {
    static let folderName = "STEP"

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Create the folder and seed README + sample (each only if
    /// missing, so a user's edits and files are never touched).
    /// Called once at launch, after the engine registers. All
    /// best-effort: a seeding failure must never block launch —
    /// the folder itself is the guarantee, the sample a bonus.
    static func setup() {
        let fm = FileManager.default
        let dir = url
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let readme = dir.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
                Importing STEP files into MetalCAD

                Put .step or .stp files in this folder (Files ▸ On My iPad ▸ MetalCAD ▸ STEP).

                Then in MetalCAD: Documents ▸ Import STEP ▸ tap the file.
                The solid is imported as the new document's first feature, and you can
                build on it with pads, pockets, fillets and everything else.

                The file's contents are copied into the document, so you can delete
                the file from this folder afterwards if you like.

                sample-plate.step is a small plate MetalCAD wrote for you — import it
                to try the whole path end to end.
                """
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }

        let sample = dir.appendingPathComponent("sample-plate.step")
        if !fm.fileExists(atPath: sample.path) {
            do {
                let p = CascadeBridge.provider
                let box = try p.primitive(kind: .box, params: ["width": 40, "depth": 30, "height": 4])
                defer { p.release(box) }
                try p.exportSTEP(box, path: sample.path)
                MCLog.shared.info(.io, "seeded sample STEP", context: ["file": sample.lastPathComponent])
            } catch {
                MCLog.shared.warn(.io, "sample STEP seed failed (README still guarantees the folder)",
                                  code: (error as? CADError)?.code)
            }
        }
    }

    /// STEP files currently in the folder, newest first.
    static func stepFiles() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { ["step", "stp"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
    }
}

/// The Import STEP sheet: the `.step` / `.stp` files in the app's
/// STEP folder (see `STEPFolder` — no system document picker,
/// Sean's certificates break it). Tapping a file imports it as a
/// new document.
struct STEPImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (URL) -> Void

    var body: some View {
        NavigationStack {
            let files = STEPFolder.stepFiles()
            Group {
                if files.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "square.and.arrow.down")
                            .mcFont(54)
                            .foregroundStyle(.secondary)
                        Text("No STEP files yet")
                            .mcFont(26, weight: .bold)
                        Text("In the Files app, put .step or .stp files in:\nOn My iPad → MetalCAD → STEP\n\nA sample plate is already there to try.")
                            .mcFont(20)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(files, id: \.path) { url in
                            Button {
                                onPick(url)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "cube.transparent")
                                        .mcFont(26)
                                    Text(url.lastPathComponent)
                                        .mcFont(22, weight: .semibold)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(sizeText(url))
                                        .mcFont(18)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Import STEP")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .mcFont(19, weight: .semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func sizeText(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return "\(max(1, bytes / 1024)) KB"
    }
}
