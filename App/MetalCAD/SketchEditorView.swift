import SwiftUI

// MARK: - Snap engine

enum SnapKind {
    case endpoint, center, midpoint, grid
    var label: String {
        switch self {
        case .endpoint: return "END"
        case .center: return "CEN"
        case .midpoint: return "MID"
        case .grid: return "GRID"
        }
    }
    /// Lower wins when several candidates are in range.
    var priority: Int {
        switch self {
        case .endpoint: return 0
        case .center: return 1
        case .midpoint: return 2
        case .grid: return 3
        }
    }
}

struct SnapResult {
    var point: Vec2
    var kind: SnapKind?
}

/// What part of an entity a drag is moving.
enum DragRole {
    case point, lineA, lineB, center
}

struct DragTarget {
    var entityID: Int
    var role: DragRole
    var original: Vec2
}

/// An addressable point of a sketch entity (a line end, a center, a
/// standalone point) — the currency of the Measure tool and of driving
/// dimensions.
struct SketchPointRef: Equatable {
    var entityID: Int
    var kind: PointKind

    func resolve(in sketch: Sketch) -> Vec2? {
        sketch.entity(entityID)?.resolve(kind)
    }

    var shortLabel: String {
        switch kind {
        case .start: return "#\(entityID) start"
        case .end: return "#\(entityID) end"
        case .center: return "#\(entityID) center"
        case .whole: return "point #\(entityID)"
        }
    }
}

/// 2D sketch editor v3: everything from v2 (real snapping, drag-to-move,
/// numeric inspector, face-outline guide) plus Fusion-style parametrics:
///  - a Measure tool: tap two points, read the distance, TYPE a new one
///    and Apply — an existing Distance dimension is updated, otherwise
///    the second point moves and the sketch re-solves;
///  - driving dimensions: the line Length and circle Radius fields
///    update-or-create a solver constraint, so 14.3 really becomes 14
///    everywhere the sketch is used;
///  - a constraints list whose values are editable in place;
///  - "Finish & Extrude": a closed profile goes straight to the
///    Extrude panel, like Fusion's finish-sketch flow.
struct SketchEditorView: View {
    @ObservedObject var model: EditorModel
    let sketchID: String
    @Environment(\.dismiss) private var dismiss

    enum Tool: String, CaseIterable {
        case select = "Select"
        case line = "Line"
        case rectangle = "Rectangle"
        case circle = "Circle"
        case point = "Point"
        case measure = "Measure"
    }

    @State private var working: Sketch
    @State private var tool: Tool = .select
    @State private var snapEnabled = true
    @State private var selectedID: Int?
    @State private var pending: Vec2?
    @State private var liveSnap: SnapResult?
    @State private var dragging: DragTarget?
    @State private var dragChecked = false
    @State private var frozenTransform: ViewTransform?
    @State private var dof = 0
    @State private var solveNote: String?
    @State private var solveError: CADError?
    @State private var health: [CADError] = []

    // Numeric inspector fields (loaded when the selection changes).
    // (One variable per @State — SwiftUI wrappers reject multi-declarations.)
    @State private var fAX = ""
    @State private var fAY = ""
    @State private var fBX = ""
    @State private var fBY = ""
    @State private var fLength = ""
    @State private var fCX = ""
    @State private var fCY = ""
    @State private var fRadius = ""

    // Measure tool state.
    @State private var measureA: SketchPointRef?
    @State private var measureB: SketchPointRef?
    @State private var measureText = ""

    private let bigFont = Font.system(size: 20, weight: .semibold)

    init(model: EditorModel, sketchID: String) {
        _model = ObservedObject(wrappedValue: model)
        self.sketchID = sketchID
        _working = State(initialValue: model.sketch(withID: sketchID) ?? Sketch(name: "Sketch"))
    }

    private var guideOutline: [Vec2] { model.faceOutlines[sketchID] ?? [] }

    // MARK: Coordinate transform (sketch mm <-> view points)

    struct ViewTransform {
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
        if let frozen = frozenTransform { return frozen }
        var pts: [Vec2] = guideOutline
        for e in working.entities { pts += e.polyline() }
        if let p = pending { pts.append(p) }
        guard let first = pts.first else {
            return ViewTransform(scale: 6, cx: 0, cy: 0)
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = 10.0
        minX -= pad; maxX += pad; minY -= pad; maxY += pad
        let w = max(maxX - minX, 24), h = max(maxY - minY, 24)
        let s = min(Double(size.width) / w, Double(size.height) / h)
        return ViewTransform(scale: s, cx: (minX + maxX) / 2, cy: (minY + maxY) / 2)
    }

    // MARK: Snapping

    private func snap(_ raw: Vec2, scale: Double,
                      drag: DragTarget? = nil) -> SnapResult {
        guard snapEnabled else { return SnapResult(point: raw, kind: nil) }
        let threshold = 14 / max(scale, 0.001)
        var candidates: [(point: Vec2, kind: SnapKind)] = []
        for e in working.entities {
            switch e {
            case .point(_, let at, _):
                candidates.append((at, .endpoint))
            case .line(_, let a, let b, _):
                candidates.append((a, .endpoint))
                candidates.append((b, .endpoint))
                candidates.append(((a + b) * 0.5, .midpoint))
            case .circle(_, let c, _, _):
                candidates.append((c, .center))
            case .arc(let id, let c, _, _, _, _):
                candidates.append((c, .center))
                if let ent = working.entity(id) {
                    if let s = ent.resolve(.start) { candidates.append((s, .endpoint)) }
                    if let en = ent.resolve(.end) { candidates.append((en, .endpoint)) }
                }
            }
        }
        // Never snap a dragged point onto its own start position.
        if let drag {
            candidates.removeAll {
                $0.point.distance(to: drag.original) < 1e-9
            }
        }
        candidates.append((Vec2(raw.x.rounded(), raw.y.rounded()), .grid))
        var best: (point: Vec2, kind: SnapKind, dist: Double)?
        for c in candidates {
            let d = c.point.distance(to: raw)
            guard d <= threshold else { continue }
            if let b = best {
                if c.kind.priority < b.kind.priority ||
                    (c.kind.priority == b.kind.priority && d < b.dist) {
                    best = (c.point, c.kind, d)
                }
            } else {
                best = (c.point, c.kind, d)
            }
        }
        if let b = best { return SnapResult(point: b.point, kind: b.kind) }
        return SnapResult(point: raw, kind: nil)
    }

    private func draggablePoints() -> [(id: Int, role: DragRole, point: Vec2)] {
        var out: [(Int, DragRole, Vec2)] = []
        for e in working.entities {
            switch e {
            case .point(let id, let at, _):
                out.append((id, .point, at))
            case .line(let id, let a, let b, _):
                out.append((id, .lineA, a))
                out.append((id, .lineB, b))
            case .circle(let id, let c, _, _):
                out.append((id, .center, c))
            case .arc(let id, let c, _, _, _, _):
                out.append((id, .center, c))
            }
        }
        return out
    }

    private func moveDraggedPoint(_ target: DragTarget, to newPos: Vec2) {
        guard let idx = working.entities.firstIndex(where: { $0.id == target.entityID }) else { return }
        let e = working.entities[idx]
        switch (e, target.role) {
        case (.point(let id, _, let cons), .point):
            working.entities[idx] = .point(id: id, at: newPos, construction: cons)
        case (.line(let id, let a, let b, let cons), .lineA):
            working.entities[idx] = .line(id: id, a: newPos, b: b, construction: cons)
        case (.line(let id, let a, let b, let cons), .lineB):
            working.entities[idx] = .line(id: id, a: a, b: newPos, construction: cons)
        case (.line(let id, let a, let b, let cons), .point):
            // Whole-line drag fallback (unused roles map to nearest end).
            let da = a.distance(to: target.original), db = b.distance(to: target.original)
            if da <= db {
                working.entities[idx] = .line(id: id, a: newPos, b: b, construction: cons)
            } else {
                working.entities[idx] = .line(id: id, a: a, b: newPos, construction: cons)
            }
        case (.circle(let id, _, let r, let cons), .center):
            working.entities[idx] = .circle(id: id, center: newPos, radius: r, construction: cons)
        case (.arc(let id, _, let r, let a0, let a1, let cons), .center):
            working.entities[idx] = .arc(id: id, center: newPos, radius: r,
                                         startAngle: a0, endAngle: a1, construction: cons)
        default:
            break
        }
    }

    // MARK: Addressable points & direct point moves (Measure / dimensions)

    private func addressablePoints() -> [(ref: SketchPointRef, point: Vec2)] {
        var out: [(SketchPointRef, Vec2)] = []
        for e in working.entities {
            switch e {
            case .point(let id, let at, _):
                out.append((SketchPointRef(entityID: id, kind: .whole), at))
            case .line(let id, let a, let b, _):
                out.append((SketchPointRef(entityID: id, kind: .start), a))
                out.append((SketchPointRef(entityID: id, kind: .end), b))
            case .circle(let id, let c, _, _):
                out.append((SketchPointRef(entityID: id, kind: .center), c))
            case .arc(let id, _, _, _, _, _):
                if let s = e.resolve(.start) { out.append((SketchPointRef(entityID: id, kind: .start), s)) }
                if let en = e.resolve(.end) { out.append((SketchPointRef(entityID: id, kind: .end), en)) }
                if let c = e.resolve(.center) { out.append((SketchPointRef(entityID: id, kind: .center), c)) }
            }
        }
        return out
    }

    /// Move one addressable point directly. Arc endpoints are defined by
    /// angle, so they cannot be dragged this way (returns false).
    @discardableResult
    private func movePoint(_ ref: SketchPointRef, to newPos: Vec2) -> Bool {
        guard let idx = working.entities.firstIndex(where: { $0.id == ref.entityID }) else { return false }
        let e = working.entities[idx]
        switch (e, ref.kind) {
        case (.point(let id, _, let cons), .whole):
            working.entities[idx] = .point(id: id, at: newPos, construction: cons)
        case (.line(let id, _, let b, let cons), .start):
            working.entities[idx] = .line(id: id, a: newPos, b: b, construction: cons)
        case (.line(let id, let a, _, let cons), .end):
            working.entities[idx] = .line(id: id, a: a, b: newPos, construction: cons)
        case (.circle(let id, _, let r, let cons), .center):
            working.entities[idx] = .circle(id: id, center: newPos, radius: r, construction: cons)
        case (.arc(let id, _, let r, let a0, let a1, let cons), .center):
            working.entities[idx] = .arc(id: id, center: newPos, radius: r,
                                          startAngle: a0, endAngle: a1, construction: cons)
        default:
            return false
        }
        return true
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                headerRow
                finishRow
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
                toolBar
                if tool == .measure {
                    measureCard
                }
                if let id = selectedID, working.entity(id) != nil {
                    inspector(for: id)
                }
                if !working.constraints.isEmpty {
                    constraintsSection
                }
                entityList
            }
            .padding(10)
        }
        .navigationTitle(working.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .onChange(of: selectedID) { _, _ in loadInspector() }
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

    /// Fusion's finish-sketch flow: a closed profile can go straight
    /// into an Extrude panel; anything else stays here with the coded
    /// reason (MCAD-SK204 for an open profile, and so on).
    private var finishRow: some View {
        HStack(spacing: 12) {
            Button {
                finishAndExtrude()
            } label: {
                Label("Finish & Extrude", systemImage: "rectangle.expand.vertical")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.orange))
            }
            Button("Done") { dismiss() }
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.white.opacity(0.12)))
            Spacer()
            Text("Finish & Extrude needs a closed profile.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
    }

    private func finishAndExtrude() {
        do {
            let (profiles, _) = try working.extractProfiles()
            guard !profiles.isEmpty else { throw CADError.padNoProfile }
            model.pendingExtrudeSketchID = sketchID
            dismiss()
        } catch let e as CADError {
            solveError = e
            solveNote = nil
            MCLog.shared.log(error: e, category: .sketch)
        } catch {
            solveError = .unknown("\(error)")
            solveNote = nil
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
            ZStack(alignment: .topLeading) {
                Color(white: 0.05)
                Canvas { ctx, size in
                    draw(ctx, size: size, t: t)
                }
                if let live = liveSnap {
                    HStack(spacing: 8) {
                        if let kind = live.kind {
                            Text(kind.label)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.yellow))
                        }
                        Text("X \(mcFmt(live.point.x)) · Y \(mcFmt(live.point.y)) mm")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.yellow)
                    }
                    .padding(8)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            gestureChanged(value, t: t, size: geo.size)
                        }
                        .onEnded { value in
                            gestureEnded(value, t: t, size: geo.size)
                        })
            }
        }
        .frame(height: 430)
        .border(Color.white.opacity(0.25), width: 1)
    }

    private func gestureChanged(_ value: DragGesture.Value, t: ViewTransform, size: CGSize) {
        if frozenTransform == nil { frozenTransform = t }
        let ft = frozenTransform ?? t
        if !dragChecked {
            dragChecked = true
            // Drag-to-move wins over placement when a point is grabbed,
            // in Select mode or while no placement is pending. Measure
            // mode taps pick points instead of dragging them.
            if pending == nil && tool != .measure {
                let startRaw = ft.toSketch(value.startLocation, in: size)
                let threshold = 16 / max(ft.scale, 0.001)
                var bestTarget: DragTarget?
                var bestDist = Double.greatestFiniteMagnitude
                for cand in draggablePoints() {
                    let d = cand.point.distance(to: startRaw)
                    if d < bestDist { bestDist = d; bestTarget = DragTarget(entityID: cand.id, role: cand.role, original: cand.point) }
                }
                if let target = bestTarget, bestDist <= threshold {
                    dragging = target
                    selectedID = target.entityID
                }
            }
        }
        let raw = ft.toSketch(value.location, in: size)
        let snapped = snap(raw, scale: ft.scale, drag: dragging)
        liveSnap = snapped
        if let target = dragging {
            moveDraggedPoint(target, to: snapped.point)
        }
    }

    private func gestureEnded(_ value: DragGesture.Value, t: ViewTransform, size: CGSize) {
        let ft = frozenTransform ?? t
        let raw = ft.toSketch(value.location, in: size)
        let snapped = snap(raw, scale: ft.scale, drag: dragging)
        defer {
            dragging = nil
            dragChecked = false
            frozenTransform = nil
            liveSnap = nil
        }
        if dragging != nil {
            changed()
            return
        }
        let p = snapped.point
        switch tool {
        case .select:
            selectNearest(to: raw, scale: ft.scale)
        case .measure:
            pickMeasurePoint(at: raw, scale: ft.scale)
        case .line:
            if let start = pending {
                if start.distance(to: p) > 1e-9 {
                    working.addLine(start, p)
                    changed()
                }
                pending = nil
            } else {
                pending = p
            }
        case .rectangle:
            if let corner = pending {
                if abs(corner.x - p.x) > 1e-9 && abs(corner.y - p.y) > 1e-9 {
                    working.addRectangle(from: corner, to: p)
                    changed()
                }
                pending = nil
            } else {
                pending = p
            }
        case .circle:
            if let center = pending {
                let r = center.distance(to: p)
                if r > 0.1 {
                    working.addCircle(center, r)
                    changed()
                }
                pending = nil
            } else {
                pending = p
            }
        case .point:
            working.addPoint(p)
            changed()
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, t: ViewTransform) {
        let tl = t.toSketch(CGPoint(x: 0, y: 0), in: size)
        let br = t.toSketch(CGPoint(x: size.width, y: size.height), in: size)

        // 1 mm minor grid + 10 mm major grid (snapping is to 1 mm).
        var minor = Path()
        var gx = tl.x.rounded(.down)
        while gx <= br.x {
            minor.move(to: t.toView(Vec2(gx, tl.y), in: size))
            minor.addLine(to: t.toView(Vec2(gx, br.y), in: size))
            gx += 1
        }
        var gy = br.y.rounded(.down)
        while gy <= tl.y {
            minor.move(to: t.toView(Vec2(tl.x, gy), in: size))
            minor.addLine(to: t.toView(Vec2(br.x, gy), in: size))
            gy += 1
        }
        ctx.stroke(minor, with: .color(.white.opacity(0.03)), lineWidth: 1)
        var major = Path()
        gx = (tl.x / 10).rounded(.down) * 10
        while gx <= br.x {
            major.move(to: t.toView(Vec2(gx, tl.y), in: size))
            major.addLine(to: t.toView(Vec2(gx, br.y), in: size))
            gx += 10
        }
        gy = (br.y / 10).rounded(.down) * 10
        while gy <= tl.y {
            major.move(to: t.toView(Vec2(tl.x, gy), in: size))
            major.addLine(to: t.toView(Vec2(br.x, gy), in: size))
            gy += 10
        }
        ctx.stroke(major, with: .color(.white.opacity(0.09)), lineWidth: 1)

        // Face outline guide (the face this sketch lives on).
        if guideOutline.count > 1 {
            var guide = Path()
            guide.move(to: t.toView(guideOutline[0], in: size))
            for p in guideOutline.dropFirst() { guide.addLine(to: t.toView(p, in: size)) }
            guide.closeSubpath()
            ctx.fill(guide, with: .color(.white.opacity(0.05)))
            ctx.stroke(guide, with: .color(.white.opacity(0.4)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }

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

        // Draggable point handles.
        for cand in draggablePoints() {
            let c = t.toView(cand.point, in: size)
            let isDragged = dragging?.entityID == cand.id && dragging?.role == cand.role
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                     with: .color(isDragged ? .yellow : .white))
        }

        // Placement preview from the pending point to the live pointer.
        if let start = pending, let live = liveSnap {
            var preview = Path()
            switch tool {
            case .line:
                preview.move(to: t.toView(start, in: size))
                preview.addLine(to: t.toView(live.point, in: size))
            case .rectangle:
                let rect = CGRect(
                    x: min(t.toView(start, in: size).x, t.toView(live.point, in: size).x),
                    y: min(t.toView(start, in: size).y, t.toView(live.point, in: size).y),
                    width: abs(t.toView(live.point, in: size).x - t.toView(start, in: size).x),
                    height: abs(t.toView(live.point, in: size).y - t.toView(start, in: size).y))
                preview.addRect(rect)
            case .circle:
                let c = t.toView(start, in: size)
                let r = start.distance(to: live.point) * t.scale
                preview.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            default:
                break
            }
            ctx.stroke(preview, with: .color(.yellow.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            let c = t.toView(start, in: size)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                     with: .color(.yellow))
        } else if let p = pending {
            let c = t.toView(p, in: size)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                     with: .color(.yellow))
        }

        // Snap indicator: distinct shape per kind + label.
        if let live = liveSnap, let kind = live.kind {
            let c = t.toView(live.point, in: size)
            drawSnapIndicator(ctx, center: c, kind: kind)
            let label = Text(kind.label)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.yellow)
            ctx.draw(label, at: CGPoint(x: c.x + 16, y: c.y - 16))
        }

        // Measure picks: A (white) and B (orange), joined by a dashed
        // line so the measured span is visible.
        let pointA = measureA?.resolve(in: working)
        let pointB = measureB?.resolve(in: working)
        if let a = pointA, let b = pointB {
            var span = Path()
            span.move(to: t.toView(a, in: size))
            span.addLine(to: t.toView(b, in: size))
            ctx.stroke(span, with: .color(.orange),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        if let a = pointA {
            drawMeasureMarker(ctx, at: t.toView(a, in: size), letter: "A", color: .white)
        }
        if let b = pointB {
            drawMeasureMarker(ctx, at: t.toView(b, in: size), letter: "B", color: .orange)
        }
    }

    private func drawMeasureMarker(_ ctx: GraphicsContext, at c: CGPoint,
                                   letter: String, color: Color) {
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)),
                   with: .color(color), lineWidth: 3)
        let label = Text(letter)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(color)
        ctx.draw(label, at: CGPoint(x: c.x, y: c.y - 24))
    }

    private func drawSnapIndicator(_ ctx: GraphicsContext, center c: CGPoint, kind: SnapKind) {
        let s = 9.0
        switch kind {
        case .endpoint: // square
            ctx.stroke(Path(CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2)),
                       with: .color(.yellow), lineWidth: 2.5)
        case .center: // X
            var p = Path()
            p.move(to: CGPoint(x: c.x - s, y: c.y - s)); p.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
            p.move(to: CGPoint(x: c.x + s, y: c.y - s)); p.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
            ctx.stroke(p, with: .color(.yellow), lineWidth: 2.5)
        case .midpoint: // triangle
            var p = Path()
            p.move(to: CGPoint(x: c.x, y: c.y - s))
            p.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
            p.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
            p.closeSubpath()
            ctx.stroke(p, with: .color(.yellow), lineWidth: 2.5)
        case .grid: // crosshair
            var p = Path()
            p.move(to: CGPoint(x: c.x - s - 3, y: c.y)); p.addLine(to: CGPoint(x: c.x + s + 3, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - s - 3)); p.addLine(to: CGPoint(x: c.x, y: c.y + s + 3))
            ctx.stroke(p, with: .color(.yellow), lineWidth: 2)
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

    // MARK: Measure tool

    private func pickMeasurePoint(at p: Vec2, scale: Double) {
        let threshold = 16 / max(scale, 0.001)
        var best: (ref: SketchPointRef, point: Vec2, dist: Double)?
        for cand in addressablePoints() {
            let d = cand.point.distance(to: p)
            guard d <= threshold else { continue }
            if let b = best {
                if d < b.dist { best = (cand.ref, cand.point, d) }
            } else {
                best = (cand.ref, cand.point, d)
            }
        }
        guard let hit = best else { return }
        if measureA == nil || measureB != nil {
            // Start (or restart) the pair.
            measureA = hit.ref
            measureB = nil
            measureText = ""
        } else {
            measureB = hit.ref
            refreshMeasureText()
        }
    }

    private func refreshMeasureText() {
        if let a = measureA?.resolve(in: working), let b = measureB?.resolve(in: working) {
            measureText = mcFmt(a.distance(to: b))
        }
    }

    /// The headline interaction: type the distance a line should be
    /// (14.3 → 14) and the sketch obeys. If a Distance dimension joins
    /// the two points, its value is updated; otherwise point B is moved
    /// along the A→B direction (a direct edit); then the sketch solves
    /// and the part rebuilds.
    private func applyMeasure() {
        guard let a = measureA, let b = measureB,
              let value = Double(measureText), value > 0 else { return }
        if distanceConstraintIndex(a, b) != nil {
            applyDrivingDistance(a, b, value: value)
            return
        }
        var moved = false
        if let pa = a.resolve(in: working), let pb = b.resolve(in: working) {
            let d = pa.distance(to: pb)
            if d > 1e-9 {
                moved = movePoint(b, to: pa + (pb - pa) * (value / d))
            } else {
                moved = movePoint(b, to: pa + Vec2(value, 0))
            }
        }
        if !moved {
            // B cannot be moved directly (an arc end) — drive it with a
            // dimension + solver instead of pretending.
            applyDrivingDistance(a, b, value: value)
            return
        }
        changed()
        solve()
        refreshMeasureText()
    }

    private var measureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measure — tap two points (line ends, centers, points)")
                .font(.system(size: 20, weight: .bold))
            HStack(spacing: 18) {
                Text("A: \(measureA?.shortLabel ?? "—")")
                Text("B: \(measureB?.shortLabel ?? "—")")
            }
            .font(.system(size: 19, weight: .semibold))
            if measureA != nil && measureB != nil {
                HStack(spacing: 10) {
                    Text("Distance")
                        .font(bigFont)
                    TextField("Distance (mm)", text: $measureText)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 130)
                        .textFieldStyle(.roundedBorder)
                    Text("mm")
                        .font(bigFont)
                    Button("Apply") { applyMeasure() }
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.orange))
                    Button("Clear") {
                        measureA = nil
                        measureB = nil
                        measureText = ""
                    }
                    .font(bigFont)
                    Spacer()
                }
                Text("Type a new distance and Apply: an existing Distance dimension is updated, otherwise point B moves to the new distance and the sketch re-solves.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            } else {
                Text(measureA == nil ? "Tap the first point." : "Tap the second point.")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    // MARK: Driving dimensions (constraint value edits + solver)

    private func distanceConstraintIndex(_ a: SketchPointRef, _ b: SketchPointRef) -> Int? {
        working.constraints.firstIndex { c in
            if case .distancePoints(let ea, let ka, let eb, let kb, _) = c {
                return (ea == a.entityID && ka == a.kind && eb == b.entityID && kb == b.kind)
                    || (ea == b.entityID && ka == b.kind && eb == a.entityID && kb == a.kind)
            }
            return false
        }
    }

    private func constraintValue(_ c: SketchConstraint) -> Double? {
        switch c {
        case .distancePoints(_, _, _, _, let v): return v
        case .radius(_, let v): return v
        case .diameter(_, let v): return v
        case .angleBetween(_, _, let v): return v
        default: return nil
        }
    }

    private func constraint(_ c: SketchConstraint, withValue v: Double) -> SketchConstraint {
        switch c {
        case .distancePoints(let a, let ka, let b, let kb, _):
            return .distancePoints(entityA: a, kindA: ka, entityB: b, kindB: kb, value: v)
        case .radius(let e, _):
            return .radius(entity: e, value: v)
        case .diameter(let e, _):
            return .diameter(entity: e, value: v)
        case .angleBetween(let a, let b, _):
            return .angleBetween(entityA: a, entityB: b, degrees: v)
        default:
            return c
        }
    }

    /// Solve a modified copy of the sketch and adopt it on success.
    /// Returns false (leaving `working` untouched) when the solver
    /// cannot hold the new value, so callers can fall back honestly.
    private func trySolveCopy(_ copyIn: Sketch, note: String) -> Bool {
        var copy = copyIn
        do {
            let result = try SketchSolver.solve(&copy)
            working = copy
            solveError = nil
            var n = note
            if let w = result.warnings.first {
                n += " \(w.userMessage) (\(w.code))"
            }
            solveNote = n
            changed()
            loadInspector()
            refreshMeasureText()
            return true
        } catch {
            return false
        }
    }

    /// Update-or-create a Distance dimension between two points and
    /// solve. If the solver cannot hold it (conflicting constraints),
    /// fall back to the direct edit: move B along the A→B direction.
    private func applyDrivingDistance(_ a: SketchPointRef, _ b: SketchPointRef, value: Double) {
        var copy = working
        if let i = distanceConstraintIndex(a, b) {
            copy.constraints[i] = constraint(copy.constraints[i], withValue: value)
        } else {
            copy.constraints.append(.distancePoints(entityA: a.entityID, kindA: a.kind,
                                                    entityB: b.entityID, kindB: b.kind,
                                                    value: value))
        }
        if trySolveCopy(copy, note: "Dimension set to \(mcFmt(value)) mm — the sketch now drives from it.") {
            return
        }
        solveNote = nil
        if let pa = a.resolve(in: working), let pb = b.resolve(in: working) {
            let d = pa.distance(to: pb)
            if d > 1e-9 {
                _ = movePoint(b, to: pa + (pb - pa) * (value / d))
            } else {
                _ = movePoint(b, to: pa + Vec2(value, 0))
            }
        }
        changed()
        loadInspector()
        refreshMeasureText()
    }

    /// Update-or-create a Radius dimension (a Diameter dimension is
    /// updated in diameter units) and solve; falls back to setting the
    /// radius directly when the solver cannot hold it.
    private func applyDrivingRadius(entityID: Int, value: Double) {
        var copy = working
        var handled = false
        for i in copy.constraints.indices {
            switch copy.constraints[i] {
            case .radius(let e, _) where e == entityID:
                copy.constraints[i] = .radius(entity: e, value: value)
                handled = true
            case .diameter(let e, _) where e == entityID:
                copy.constraints[i] = .diameter(entity: e, value: value * 2)
                handled = true
            default:
                break
            }
        }
        if !handled {
            copy.constraints.append(.radius(entity: entityID, value: value))
        }
        if trySolveCopy(copy, note: "Radius driven to \(mcFmt(value)) mm.") { return }
        if let idx = working.entities.firstIndex(where: { $0.id == entityID }),
           case .circle(let id, let c, _, let cons) = working.entities[idx] {
            working.entities[idx] = .circle(id: id, center: c, radius: value, construction: cons)
        }
        changed()
        loadInspector()
    }

    // MARK: Constraints list (values editable in place)

    private var constraintsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Constraints — edit a value, Apply, and the sketch drives from it")
                .font(.system(size: 19, weight: .bold))
            ForEach(Array(working.constraints.enumerated()), id: \.offset) { i, c in
                ConstraintRow(
                    constraint: c,
                    onApplyValue: { v in updateConstraintValue(at: i, value: v) },
                    onDelete: { deleteConstraint(at: i) }
                )
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    private func updateConstraintValue(at index: Int, value: Double) {
        guard working.constraints.indices.contains(index) else { return }
        working.constraints[index] = constraint(working.constraints[index], withValue: value)
        changed()
        solve()
        refreshMeasureText()
    }

    private func deleteConstraint(at index: Int) {
        guard working.constraints.indices.contains(index) else { return }
        working.constraints.remove(at: index)
        changed()
    }

    // MARK: Tools + inspector

    private var toolBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Tool.allCases, id: \.self) { option in
                    Button(option.rawValue) {
                        tool = option
                        pending = nil
                    }
                    .font(bigFont)
                    .foregroundStyle(tool == option ? .black : .accentColor)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(tool == option ? Color.yellow : Color.clear))
                }
                Spacer()
            }
            HStack(spacing: 14) {
                Toggle("Snap", isOn: $snapEnabled)
                    .font(bigFont)
                    .fixedSize()
                if pending != nil {
                    Text("Tap the second point…")
                        .font(.system(size: 18))
                        .foregroundStyle(.yellow)
                    Button("Cancel") { pending = nil }
                        .font(bigFont)
                }
                Spacer()
                Button("Fit") { frozenTransform = nil }
                    .font(bigFont)
                Button("Solve") { solve() }
                    .font(bigFont)
            }
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

    private var selectedLineID: Int? {
        guard let id = selectedID, let e = working.entity(id) else { return nil }
        if case .line = e { return id }
        return nil
    }

    @ViewBuilder
    private func inspector(for id: Int) -> some View {
        if let e = working.entity(id) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Edit — \(describe(e))")
                    .font(.system(size: 21, weight: .bold))
                switch e {
                case .line:
                    HStack(spacing: 8) {
                        field("A X", $fAX); field("A Y", $fAY)
                        field("B X", $fBX); field("B Y", $fBY)
                    }
                    HStack(spacing: 8) {
                        field("Length mm", $fLength)
                        Button("Apply") { applyLineEdits(id: id) }
                            .font(bigFont)
                        Spacer()
                    }
                    Text("Length is a driving dimension: Apply sets (or updates) a Distance constraint between the line's ends and solves — change 14.3 to 14 and the sketch follows.")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                case .circle:
                    HStack(spacing: 8) {
                        field("Center X", $fCX); field("Center Y", $fCY); field("Radius", $fRadius)
                    }
                    HStack {
                        Button("Apply") { applyCircleEdits(id: id) }
                            .font(bigFont)
                        Spacer()
                    }
                    Text("Radius is a driving dimension too: Apply sets (or updates) a Radius constraint and solves.")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                case .point:
                    HStack(spacing: 8) {
                        field("X", $fCX); field("Y", $fCY)
                        Button("Apply") { applyPointEdits(id: id) }
                            .font(bigFont)
                        Spacer()
                    }
                case .arc:
                    HStack(spacing: 8) {
                        field("Center X", $fCX); field("Center Y", $fCY); field("Radius", $fRadius)
                    }
                    HStack {
                        Button("Apply") { applyArcEdits(id: id) }
                            .font(bigFont)
                        Spacer()
                    }
                }
                Text("Type exact numbers, then Apply. Dragging a white point also moves it (with snapping).")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        }
    }

    private func field(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(label, text: binding)
                .keyboardType(.numbersAndPunctuation)
                .font(.system(size: 20, weight: .semibold))
                .frame(minWidth: 70)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func loadInspector() {
        guard let id = selectedID, let e = working.entity(id) else { return }
        switch e {
        case .line(_, let a, let b, _):
            fAX = mcFmt(a.x); fAY = mcFmt(a.y); fBX = mcFmt(b.x); fBY = mcFmt(b.y)
            fLength = mcFmt(a.distance(to: b))
        case .circle(_, let c, let r, _):
            fCX = mcFmt(c.x); fCY = mcFmt(c.y); fRadius = mcFmt(r)
        case .point(_, let at, _):
            fCX = mcFmt(at.x); fCY = mcFmt(at.y)
        case .arc(_, let c, let r, _, _, _):
            fCX = mcFmt(c.x); fCY = mcFmt(c.y); fRadius = mcFmt(r)
        }
    }

    private func num(_ s: String, fallback: Double) -> Double { Double(s) ?? fallback }

    private func applyLineEdits(id: Int) {
        guard let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .line(_, let a0, let b0, let cons) = working.entities[idx] else { return }
        let a = Vec2(num(fAX, fallback: a0.x), num(fAY, fallback: a0.y))
        let b = Vec2(num(fBX, fallback: b0.x), num(fBY, fallback: b0.y))
        working.entities[idx] = .line(id: id, a: a, b: b, construction: cons)
        changed()
        // Length drives parametrically when it was actually changed.
        if let wanted = Double(fLength), wanted > 0 {
            let current = a.distance(to: b)
            if abs(wanted - current) > 1e-9 {
                applyDrivingDistance(SketchPointRef(entityID: id, kind: .start),
                                     SketchPointRef(entityID: id, kind: .end),
                                     value: wanted)
            }
        }
        loadInspector()
    }

    private func applyCircleEdits(id: Int) {
        guard let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .circle(_, let c0, let r0, let cons) = working.entities[idx] else { return }
        let c = Vec2(num(fCX, fallback: c0.x), num(fCY, fallback: c0.y))
        working.entities[idx] = .circle(id: id, center: c, radius: r0, construction: cons)
        changed()
        if let wanted = Double(fRadius), wanted > 0.05, abs(wanted - r0) > 1e-9 {
            applyDrivingRadius(entityID: id, value: wanted)
        }
        loadInspector()
    }

    private func applyPointEdits(id: Int) {
        guard let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .point(_, let at0, let cons) = working.entities[idx] else { return }
        let at = Vec2(num(fCX, fallback: at0.x), num(fCY, fallback: at0.y))
        working.entities[idx] = .point(id: id, at: at, construction: cons)
        changed()
        loadInspector()
    }

    private func applyArcEdits(id: Int) {
        guard let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .arc(_, let c0, let r0, let a0, let a1, let cons) = working.entities[idx] else { return }
        let c = Vec2(num(fCX, fallback: c0.x), num(fCY, fallback: c0.y))
        let r = max(0.1, num(fRadius, fallback: r0))
        working.entities[idx] = .arc(id: id, center: c, radius: r,
                                       startAngle: a0, endAngle: a1, construction: cons)
        changed()
        loadInspector()
    }

    private var entityList: some View {
        VStack(spacing: 0) {
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
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { selectedID = e.id }
                Divider()
            }
        }
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
        working.constraints.removeAll { $0.referencedEntities.contains(id) }
        if selectedID == id { selectedID = nil }
        if measureA?.entityID == id { measureA = nil }
        if measureB?.entityID == id { measureB = nil }
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
            loadInspector()
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
        case .point(let id, let at, _):
            return "Point #\(id) · (\(mcFmt(at.x)), \(mcFmt(at.y)))"
        case .line(let id, let a, let b, _):
            return "Line #\(id) · \(mcFmt(a.distance(to: b))) mm"
        case .circle(let id, _, let r, _):
            return "Circle #\(id) · r \(mcFmt(r))"
        case .arc(let id, _, let r, _, _, _):
            return "Arc #\(id) · r \(mcFmt(r))"
        }
    }
}

// MARK: - Constraint row (value editable in place)

struct ConstraintRow: View {
    let constraint: SketchConstraint
    let onApplyValue: (Double) -> Void
    let onDelete: () -> Void

    @State private var text: String

    init(constraint: SketchConstraint,
         onApplyValue: @escaping (Double) -> Void,
         onDelete: @escaping () -> Void) {
        self.constraint = constraint
        self.onApplyValue = onApplyValue
        self.onDelete = onDelete
        _text = State(initialValue: Self.value(of: constraint).map(mcFmt) ?? "")
    }

    private static func value(of c: SketchConstraint) -> Double? {
        switch c {
        case .distancePoints(_, _, _, _, let v): return v
        case .radius(_, let v): return v
        case .diameter(_, let v): return v
        case .angleBetween(_, _, let v): return v
        default: return nil
        }
    }

    private var hasValue: Bool { Self.value(of: constraint) != nil }

    private var detail: String {
        switch constraint {
        case .coincident(let a, _, let b, _): return "#\(a) ↔ #\(b)"
        case .horizontal(let e), .vertical(let e): return "line #\(e)"
        case .distancePoints(let a, _, let b, _, _): return "#\(a) ↔ #\(b)"
        case .radius(let e, _): return "circle #\(e)"
        case .diameter(let e, _): return "circle #\(e)"
        case .equalRadius(let a, let b), .equalLength(let a, let b),
             .parallel(let a, let b), .perpendicular(let a, let b):
            return "#\(a) ↔ #\(b)"
        case .pointOnLine(let p, _, let l): return "#\(p) on line #\(l)"
        case .pointOnCircle(let p, _, let c): return "#\(p) on circle #\(c)"
        case .fixedPoint(let e, _, let at): return "#\(e) at (\(mcFmt(at.x)), \(mcFmt(at.y)))"
        case .angleBetween(let a, let b, _): return "lines #\(a) ↔ #\(b)"
        case .tangentLineCircle(let l, let c): return "line #\(l) ↔ circle #\(c)"
        case .symmetric(let a, _, let b, _, let axis): return "#\(a) ↔ #\(b) over line #\(axis)"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(constraint.displayName)
                    .font(.system(size: 19, weight: .semibold))
                Text(detail)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasValue {
                TextField("Value", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
                Button("Apply") {
                    if let v = Double(text) { onApplyValue(v) }
                }
                .font(.system(size: 19, weight: .bold))
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 19))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .onChange(of: constraint) { _, newValue in
            text = Self.value(of: newValue).map(mcFmt) ?? ""
        }
    }
}
