import SwiftUI

/// 2D sketch editor for one sketch in the open part. Works on a local
/// copy and commits every change back into the EditorModel (which
/// rebuilds the 3D model). Functional but deliberately simple: canvas,
/// a few add tools, tap-tap lines, H/V constraints, and Solve.
struct SketchEditorView: View {
    @ObservedObject var model: EditorModel
    let sketchID: String

    @State private var working: Sketch
    @State private var selectedID: Int?
    @State private var lineMode = false
    @State private var pending: Vec2?
    @State private var dof = 0
    @State private var solveNote: String?
    @State private var solveError: CADError?
    @State private var health: [CADError] = []

    private let bigFont = Font.system(size: 20, weight: .semibold)

    init(model: EditorModel, sketchID: String) {
        _model = ObservedObject(wrappedValue: model)
        self.sketchID = sketchID
        _working = State(initialValue: model.sketch(withID: sketchID) ?? Sketch(name: "Sketch"))
    }

    // MARK: Coordinate transform (sketch mm <-> view points)

    private struct ViewTransform {
        var scale: Double
        var cx: Double
        var cy: Double
        func toView(_ p: Vec2, in size: CGSize) -> CGPoint {
            CGPoint(x: (p.x - cx) * scale + Double(size.width) / 2,
                    y: Double(size.height) / 2 - (p.y - cy) * scale)
        }
        func toSketch(_ pt: CGPoint, in size: CGSize) -> Vec2 {
            Vec2((Double(pt.x) - Double(size.width) / 2) / scale + cx,
                 cy - (Double(pt.y) - Double(size.height) / 2) / scale)
        }
    }

    private func transform(for size: CGSize) -> ViewTransform {
        var pts: [Vec2] = []
        for e in working.entities { pts += e.polyline() }
        if let p = pending { pts.append(p) }
        guard let first = pts.first else {
            return ViewTransform(scale: 4, cx: 0, cy: 0)
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = 12.0
        minX -= pad; maxX += pad; minY -= pad; maxY += pad
        let w = max(maxX - minX, 24), h = max(maxY - minY, 24)
        let s = min(Double(size.width) / w, Double(size.height) / h)
        return ViewTransform(scale: s, cx: (minX + maxX) / 2, cy: (minY + maxY) / 2)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 10) {
            headerRow
            canvas
            if let e = solveError {
                messageRow(text: e.userMessage, code: e.code, color: .red)
            }
            if let n = solveNote {
                Text(n)
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let h = health.first {
                messageRow(text: h.userMessage, code: h.code, color: .orange)
            }
            toolRows
            entityList
        }
        .padding(10)
        .navigationTitle(working.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
    }

    private var headerRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(working.name)
                    .font(.system(size: 24, weight: .bold))
                Text("\(working.entities.count) items · \(working.constraints.count) constraints")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            dofBadge
        }
    }

    @ViewBuilder
    private var dofBadge: some View {
        if working.entities.isEmpty {
            badge("Empty sketch", .gray)
        } else if dof == 0 {
            badge("Fully constrained", .green)
        } else {
            badge("\(dof) free", .orange)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(color))
    }

    private func messageRow(text: String, code: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(code)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let t = transform(for: geo.size)
            ZStack {
                Color(white: 0.05)
                Canvas { ctx, size in
                    draw(ctx, size: size, t: t)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            handleTap(value.location, t: t, size: geo.size)
                        })
            }
        }
        .frame(minHeight: 380)
        .border(Color.white.opacity(0.25), width: 1)
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, t: ViewTransform) {
        let tl = t.toSketch(CGPoint(x: 0, y: 0), in: size)
        let br = t.toSketch(CGPoint(x: size.width, y: size.height), in: size)

        // Grid every 10 mm.
        var grid = Path()
        var gx = (tl.x / 10).rounded(.down) * 10
        while gx <= br.x {
            grid.move(to: t.toView(Vec2(gx, tl.y), in: size))
            grid.addLine(to: t.toView(Vec2(gx, br.y), in: size))
            gx += 10
        }
        var gy = (br.y / 10).rounded(.down) * 10
        while gy <= tl.y {
            grid.move(to: t.toView(Vec2(tl.x, gy), in: size))
            grid.addLine(to: t.toView(Vec2(br.x, gy), in: size))
            gy += 10
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)

        // Axes.
        var axes = Path()
        axes.move(to: t.toView(Vec2(tl.x, 0), in: size))
        axes.addLine(to: t.toView(Vec2(br.x, 0), in: size))
        axes.move(to: t.toView(Vec2(0, br.y), in: size))
        axes.addLine(to: t.toView(Vec2(0, tl.y), in: size))
        ctx.stroke(axes, with: .color(.white.opacity(0.3)), lineWidth: 1)

        // Entities.
        for e in working.entities {
            let selected = e.id == selectedID
            let color: Color = selected ? .orange : (e.isConstruction ? .gray : .cyan)
            if case .point(_, let at, _) = e {
                let c = t.toView(at, in: size)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                         with: .color(color))
                continue
            }
            let pts = e.polyline()
            guard pts.count > 1 else { continue }
            var path = Path()
            path.move(to: t.toView(pts[0], in: size))
            for p in pts.dropFirst() { path.addLine(to: t.toView(p, in: size)) }
            if case .circle = e { path.closeSubpath() }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: selected ? 4 : 2.5,
                                          dash: e.isConstruction ? [6, 4] : []))
        }

        // Pending line start marker.
        if let p = pending {
            let c = t.toView(p, in: size)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                     with: .color(.yellow))
        }
    }

    private func handleTap(_ loc: CGPoint, t: ViewTransform, size: CGSize) {
        let raw = t.toSketch(loc, in: size)
        let p = Vec2(raw.x.rounded(), raw.y.rounded())  // 1 mm snap
        if lineMode {
            if let start = pending {
                working.addLine(start, p)
                pending = nil
                changed()
            } else {
                pending = p
            }
        } else {
            selectNearest(to: raw, scale: t.scale)
        }
    }

    private func selectNearest(to p: Vec2, scale: Double) {
        var bestID: Int? = nil
        var bestDist = Double.greatestFiniteMagnitude
        for e in working.entities {
            for pt in e.polyline() {
                let d = pt.distance(to: p)
                if d < bestDist { bestDist = d; bestID = e.id }
            }
        }
        let threshold = 14 / max(scale, 0.001)
        selectedID = (bestID != nil && bestDist <= threshold) ? bestID : nil
    }

    // MARK: Tools

    private var selectedLineID: Int? {
        guard let id = selectedID, let e = working.entity(id) else { return nil }
        if case .line = e { return id }
        return nil
    }

    private var toolRows: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button("Rectangle 40×30") {
                    working.addRectangle(from: Vec2(-20, -15), to: Vec2(20, 15))
                    changed()
                }
                Button("Circle r15") {
                    working.addCircle(Vec2(0, 0), 15)
                    changed()
                }
                Button(lineMode ? (pending == nil ? "Line: tap start" : "Line: tap end") : "Add Line") {
                    lineMode.toggle()
                    if !lineMode { pending = nil }
                }
                .foregroundStyle(lineMode ? .yellow : .accentColor)
                Button("Solve") { solve() }
                Spacer()
            }
            .font(bigFont)
            if let lineID = selectedLineID {
                HStack(spacing: 10) {
                    Text("Line #\(lineID):")
                        .font(bigFont)
                    Button("Horizontal") {
                        working.constraints.append(.horizontal(entity: lineID))
                        changed()
                    }
                    Button("Vertical") {
                        working.constraints.append(.vertical(entity: lineID))
                        changed()
                    }
                    Spacer()
                }
                .font(bigFont)
            }
        }
    }

    private var entityList: some View {
        List {
            ForEach(working.entities, id: \.id) { e in
                HStack(spacing: 12) {
                    Text(describe(e))
                        .font(.system(size: 19, weight: e.id == selectedID ? .bold : .regular))
                        .foregroundStyle(e.id == selectedID ? .orange : .primary)
                    Spacer()
                    Button(role: .destructive) {
                        deleteEntity(e.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedID = e.id }
            }
        }
        .frame(height: 210)
    }

    // MARK: Actions

    private func changed() {
        model.replaceSketch(working)
        refresh()
    }

    private func refresh() {
        dof = SketchSolver.degreesOfFreedom(working)
        health = working.validate()
    }

    private func deleteEntity(_ id: Int) {
        working.removeEntity(id)
        // Constraints pointing at a deleted entity would dangle (SV306);
        // the editor removes them with the entity.
        working.constraints.removeAll { $0.referencedEntities.contains(id) }
        if selectedID == id { selectedID = nil }
        changed()
    }

    private func solve() {
        var copy = working
        do {
            let result = try SketchSolver.solve(&copy)
            working = copy
            solveError = nil
            var note = "Solved in \(result.iterations) iterations."
            if let w = result.warnings.first {
                note += " \(w.userMessage) (\(w.code))"
            }
            solveNote = note
            changed()
        } catch let e as CADError {
            solveError = e
            solveNote = nil
            MCLog.shared.log(error: e, category: .solver)
        } catch {
            solveError = .unknown("\(error)")
            solveNote = nil
        }
    }

    private func describe(_ e: SketchEntity) -> String {
        switch e {
        case .point(let id, _, _):
            return "Point #\(id)"
        case .line(let id, let a, let b, _):
            return "Line #\(id) · \(mcFmt(a.distance(to: b))) mm"
        case .circle(let id, _, let r, _):
            return "Circle #\(id) · r \(mcFmt(r))"
        case .arc(let id, _, let r, _, _, _):
            return "Arc #\(id) · r \(mcFmt(r))"
        }
    }
}
