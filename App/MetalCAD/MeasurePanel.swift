import SwiftUI

/// Total surface area of a triangle mesh, mm². (The kit exposes volume
/// and bounds but no area helper, so the app sums triangle areas.)
func meshSurfaceArea(_ mesh: Mesh) -> Double {
    var area = 0.0
    for t in 0..<mesh.triangleCount {
        let a = mesh.vertices[Int(mesh.indices[t * 3])]
        let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])]
        let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
        area += (b - a).cross(c - a).length / 2
    }
    return area
}

/// 3D Measure panel (Fusion's Inspect ▸ Measure): always-on part stats,
/// plus a two-face measurement — pick any two flat faces of the current
/// body to read each face's area and, when the faces are parallel, the
/// exact distance between their planes.
struct MeasurePanel: View {
    @ObservedObject var model: EditorModel

    @State private var faceAIndex = -1
    @State private var faceBIndex = -1

    private var mesh: Mesh { model.rebuild?.mesh ?? Mesh() }

    /// Planar faces of the current body, biggest first, capped so the
    /// pickers stay usable on tessellated parts.
    private var faces: [PlanarFace] {
        guard mesh.triangleCount > 0 else { return [] }
        return Array(FaceExtractor.planarFaces(of: mesh)
            .sorted { $0.area > $1.area }
            .prefix(30))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statsBlock
            Divider()
            faceMeasure
            PanelNote(text: "To change a size, edit the feature or the sketch dimension — in the sketch editor, the Measure tool and the length / radius fields drive the model.")
        }
        .onAppear { preselectPickedFace() }
    }

    /// If the picked-face bar sent a face ("Measure"), preselect it
    /// as Face A: match it against this panel's sorted face list by
    /// plane normal + centroid. Silent when it isn't in the top 30.
    private func preselectPickedFace() {
        guard let target = model.measureFace else { return }
        model.measureFace = nil
        let list = faces
        if let idx = list.firstIndex(where: {
            $0.plane.normal.dot(target.plane.normal) > 0.999
                && $0.centroid.distance(to: target.centroid) < 0.01
        }) {
            faceAIndex = idx
        }
    }

    private var statsBlock: some View {
        let b = mesh.bounds
        return VStack(alignment: .leading, spacing: 6) {
            Text("Part")
                .mcFont(19, weight: .bold)
            statRow("Volume", mesh.triangleCount > 0 ? "\(String(format: "%.2f", mesh.volume / 1000)) cm³" : "—")
            statRow("Surface area", mesh.triangleCount > 0 ? "\(String(format: "%.1f", meshSurfaceArea(mesh) / 100)) cm²" : "—")
            statRow("Mass", model.rebuild?.massGrams.map(mcMass) ?? "—")
            statRow("Size", mesh.triangleCount > 0
                    ? "\(mcFmt(b.size.x)) × \(mcFmt(b.size.y)) × \(mcFmt(b.size.z)) mm"
                    : "—")
            statRow("Triangles", "\(mesh.triangleCount)")
            statRow("Open edges", mesh.triangleCount > 0
                    ? (mesh.openEdgeCount == 0 ? "0 (watertight)" : "\(mesh.openEdgeCount)")
                    : "—")
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .mcFont(18, weight: .semibold)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .mcFont(19, weight: .semibold)
        }
    }

    private var faceMeasure: some View {
        let list = faces
        return VStack(alignment: .leading, spacing: 8) {
            Text("Face to face")
                .mcFont(19, weight: .bold)
            if list.isEmpty {
                PanelNote(text: "No solid yet — faces appear once the part has a body.")
            } else {
                facePicker("Face A", selection: $faceAIndex, faces: list)
                facePicker("Face B", selection: $faceBIndex, faces: list)
                if faceAIndex >= 0, faceAIndex < list.count {
                    statRow("Face A area", "\(String(format: "%.1f", list[faceAIndex].area)) mm²")
                }
                if faceBIndex >= 0, faceBIndex < list.count {
                    statRow("Face B area", "\(String(format: "%.1f", list[faceBIndex].area)) mm²")
                }
                if faceAIndex >= 0, faceBIndex >= 0,
                   faceAIndex < list.count, faceBIndex < list.count,
                   faceAIndex != faceBIndex {
                    facePairResult(list[faceAIndex], list[faceBIndex])
                }
            }
        }
    }

    private func facePicker(_ label: String, selection: Binding<Int>, faces list: [PlanarFace]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .mcFont(17, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                Text("None").tag(-1)
                ForEach(Array(list.enumerated()), id: \.offset) { i, face in
                    Text(faceLabel(i, face)).tag(i)
                }
            }
            .pickerStyle(.menu)
            .mcFont(19, weight: .semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Face 3 · facing +Z · 2 400 mm²" — enough to tell faces apart.
    private func faceLabel(_ index: Int, _ face: PlanarFace) -> String {
        let n = face.plane.normal
        let axis: String
        let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
        if ax >= ay && ax >= az { axis = n.x >= 0 ? "+X" : "−X" }
        else if ay >= ax && ay >= az { axis = n.y >= 0 ? "+Y" : "−Y" }
        else { axis = n.z >= 0 ? "+Z" : "−Z" }
        return "Face \(index + 1) · \(axis) · \(String(format: "%.0f", face.area)) mm²"
    }

    @ViewBuilder
    private func facePairResult(_ a: PlanarFace, _ b: PlanarFace) -> some View {
        let n1 = a.plane.normal
        let n2 = b.plane.normal
        let dot = abs(n1.dot(n2))
        if dot > 0.9999 {
            let d = abs((a.centroid - b.centroid).dot(n1))
            VStack(alignment: .leading, spacing: 2) {
                Text("Distance between faces")
                    .mcFont(17, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text("\(mcFmt(d)) mm")
                    .mcFont(30, weight: .bold)
                    .foregroundStyle(.orange)
            }
            .padding(.top, 2)
        } else {
            let angle = acos(min(1, dot)) * 180 / Double.pi
            PanelNote(text: "These faces are not parallel — angle between them ≈ \(mcFmt(angle))°. Pick two parallel faces (like the top and bottom of a plate) for a distance.", warning: true)
        }
    }
}
