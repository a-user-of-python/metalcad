import Foundation

public enum PrimitiveKind: String, Codable, CaseIterable {
    case box, cylinder, sphere, cone, torus
}

public enum HoleKind: Codable, Equatable {
    case simple
    case counterbore(diameter: Double, depth: Double)
    case countersink(angleDegrees: Double)
}

public enum MirrorPlane: String, Codable, CaseIterable {
    case yz, xz, xy
    public var axis: Int { self == .yz ? 0 : (self == .xz ? 1 : 2) }
    public var displayName: String { rawValue.uppercased() + " plane" }
}

public enum ExtrudeMode: Codable, Equatable {
    case one
    case symmetric
    case twoSided(second: Double)
}

/// How an additive feature combines with the running body (v4).
public enum BodyOperation: String, Codable, Equatable {
    case join, cut, intersect, newBody
}

/// Where an extrude stops (v4).
public enum ExtrudeEnd: Codable, Equatable {
    case dimension
    case throughAll
    case upToFace(faceIndex: Int)
}

/// Chamfer sizing modes (v4).
public enum ChamferMode: Codable, Equatable {
    case equal(Double)
    case twoDistances(Double, Double)
    case distanceAngle(Double, Double)  // distance along face A, angle from face A
    public var distances: (Double, Double) {
        switch self {
        case .equal(let d): return (d, d)
        case .twoDistances(let a, let b): return (a, b)
        case .distanceAngle(let d, let deg):
            let t = tan(deg * Double.pi / 180)
            return (d, t > 1e-6 ? d / t : d * 1000)
        }
    }
}

public enum FeatureKind: Codable, Equatable {
    case pad(sketchID: String, length: Double)
    case pocket(sketchID: String, depth: Double)
    case revolve(sketchID: String, axisEntityID: Int, angleDegrees: Double)
    case primitive(kind: PrimitiveKind, params: [String: Double])
    case threadShaft(spec: ThreadSpec)
    case linearPattern(count: Int, spacing: Vec3)
    case hole(sketchID: String, diameter: Double, depth: Double, kind: HoleKind)
    case mirror(plane: MirrorPlane)
    case fillet(radius: Double)
    case chamfer(distance: Double)
    case shell(thickness: Double)
    case extrude(sketchID: String, distance: Double, taperDegrees: Double, mode: ExtrudeMode)
    case loft(sketchA: String, sketchB: String)
    case sweep(profileSketchID: String, pathSketchID: String)
    // v4 additions (appended — existing cases keep their encoding).
    case extrude2(sketchID: String, distance: Double, taperDegrees: Double, mode: ExtrudeMode, operation: BodyOperation, end: ExtrudeEnd)
    case chamfer2(mode: ChamferMode)
    case coil(radius: Double, pitch: Double, turns: Double, wireRadius: Double)
    case pipe(pathSketchID: String, radius: Double)
    case rib(sketchID: String, thickness: Double, depth: Double)
    case draftBody(angleDegrees: Double, pullAxis: Int)
    case scaleBody(factors: Vec3)
    case moveBody(translation: Vec3, rotationAxis: Int, rotationDegrees: Double)
    case splitBody(axis: Int, offset: Double)
    case circularPattern(count: Int, axis: Int, totalDegrees: Double)
    // v4.1 additions (appended — existing cases keep their encoding).
    case filletEdges(radius: Double, midpoints: [Vec3])
    case chamferEdges(distance: Double, midpoints: [Vec3])
    case threadOnShaft(spec: ThreadSpec, origin: Vec3, axis: Vec3)
    case booleanCutPlaceholder
}

public struct Feature: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: FeatureKind
    public var suppressed: Bool = false
    public init(id: String = UUID().uuidString, name: String, kind: FeatureKind) {
        self.id = id; self.name = name; self.kind = kind
    }
}

public struct Part: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var sketches: [Sketch] = []
    public var features: [Feature] = []
    public var materialID: String = MaterialLibrary.defaultMaterial.id
    public init(id: String = UUID().uuidString, name: String) {
        self.id = id; self.name = name
    }
    public func sketch(_ id: String) -> Sketch? { sketches.first { $0.id == id } }
    public var material: Material { MaterialLibrary.byID(materialID) ?? MaterialLibrary.defaultMaterial }
}

public struct CADDocument: Codable, Equatable, Identifiable {
    public static let currentFormatVersion = 1
    public var formatVersion: Int = CADDocument.currentFormatVersion
    public var id: String
    public var name: String
    public var parts: [Part] = []
    public var parameters: [String: Double] = [:]
    public init(id: String = UUID().uuidString, name: String) {
        self.id = id; self.name = name
    }
}

/// Per-feature outcome of a rebuild.
public struct FeatureStatus: Equatable {
    public var featureID: String
    public var ok: Bool
    public var errorCode: String?
    public var message: String?
}

public struct RebuildResult {
    public var mesh: Mesh
    /// All solid bodies (v4 multi-body); `mesh` is their concatenation.
    public var bodies: [Mesh] = []
    public var statuses: [FeatureStatus]
    public var warnings: [CADError]
    public var firstError: CADError?
    /// Mass in grams from the part's material density; nil if no material.
    public var massGrams: Double? = nil
}

public enum DocumentEngine {

    /// Evaluate a part's feature tree into one accumulated mesh (v1: additive
    /// mesh accumulation; exact boolean cut/fillet/shell return their codes).
    /// Stops after the first failing feature, per ERRORS.md DC107.
    public static func rebuild(part: Part, logger: MCLog = .shared) -> RebuildResult {
        let start = Date()
        var body = Mesh()
        var bodies: [Mesh] = []  // completed bodies (v4 multi-body)
        var statuses: [FeatureStatus] = []
        var warnings: [CADError] = []
        var firstError: CADError? = nil
        logger.debug(.feature, "rebuild start", context: ["part": part.name, "features": "\(part.features.count)"])

        for feature in part.features {
            if firstError != nil {
                statuses.append(FeatureStatus(featureID: feature.id, ok: false, errorCode: nil, message: "paused"))
                continue
            }
            if feature.suppressed {
                statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: "suppressed"))
                continue
            }
            do {
                if case .linearPattern(let count, let spacing) = feature.kind {
                    body = try DocumentEngine.applyPattern(mesh: body, count: count, spacing: spacing)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "pattern ok", context: ["feature": feature.name, "count": "\(count)"])
                    continue
                }
                if case .mirror(let plane) = feature.kind {
                    if body.triangleCount > 0 {
                        body = try CSG.union(body, body.mirrored(axis: plane.axis))
                    }
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "mirror ok", context: ["feature": feature.name, "plane": plane.rawValue])
                    continue
                }
                if case .fillet(let radius) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.filletFailed("no solid to fillet yet") }
                    body = try EdgeFinisher.fillet(body: body, radius: radius)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "fillet ok", context: ["feature": feature.name, "radius": "\(radius)"])
                    continue
                }
                if case .chamfer(let distance) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.chamferInvalid("no solid to chamfer yet") }
                    body = try EdgeFinisher.chamfer(body: body, distance: distance)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "chamfer ok", context: ["feature": feature.name, "distance": "\(distance)"])
                    continue
                }
                if case .shell(let thickness) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.shellFailed("no solid to shell yet") }
                    body = try EdgeFinisher.shell(body: body, thickness: thickness)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "shell ok", context: ["feature": feature.name, "wall": "\(thickness)"])
                    continue
                }
                if case .extrude2(let sketchID, let distance, let taper, let mode, let op, let end) = feature.kind {
                    let tool = try DocumentEngine.extrude2Mesh(part: part, sketchID: sketchID, distance: distance, taper: taper, mode: mode, end: end, body: body, warnings: &warnings)
                    switch op {
                    case .join:
                        body = body.triangleCount == 0 ? tool : try CSG.union(body, tool)
                    case .cut:
                        guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                        body = try CSG.subtract(body, tool)
                    case .intersect:
                        guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                        body = try CSG.intersect(body, tool)
                    case .newBody:
                        if body.triangleCount > 0 { bodies.append(body) }
                        body = tool
                    }
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "extrude2 ok", context: ["feature": feature.name, "op": op.rawValue])
                    continue
                }
                if case .rib(let sketchID, let thickness, let depth) = feature.kind {
                    body = try DocumentEngine.ribMesh(part: part, sketchID: sketchID, thickness: thickness, depth: depth, body: body)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "rib ok", context: ["feature": feature.name])
                    continue
                }
                if case .chamfer2(let mode) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.chamferInvalid("no solid to chamfer yet") }
                    let (dA, dB) = mode.distances
                    body = try EdgeFinisher.chamfer2(body: body, distanceA: dA, distanceB: dB)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "chamfer2 ok", context: ["feature": feature.name])
                    continue
                }
                if case .draftBody(let angle, let axis) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.transformInvalid("no solid to draft yet") }
                    body = try DocumentEngine.draftMesh(body: body, angleDegrees: angle, pullAxis: axis)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "draft ok", context: ["feature": feature.name])
                    continue
                }
                if case .scaleBody(let f) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.transformInvalid("no solid to scale yet") }
                    guard f.x > 0, f.y > 0, f.z > 0 else { throw CADError.transformInvalid("scale factors must be > 0") }
                    body = body.scaled(by: f, center: body.bounds.center)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "scale ok", context: ["feature": feature.name])
                    continue
                }
                if case .moveBody(let t, let axis, let deg) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.transformInvalid("no solid to move yet") }
                    if abs(deg) > 1e-9 { body = body.rotatedAround(axis: axis, degrees: deg, center: body.bounds.center) }
                    body = body.translated(by: t)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "move ok", context: ["feature": feature.name])
                    continue
                }
                if case .splitBody(let axis, let offset) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.booleanFailed("no solid to split yet") }
                    let (h1, h2) = try DocumentEngine.splitMesh(body: body, axis: axis, offset: offset)
                    bodies.append(h2)
                    body = h1
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "split ok", context: ["feature": feature.name])
                    continue
                }
                if case .circularPattern(let count, let axis, let total) = feature.kind {
                    guard count >= 2 else { throw CADError.patternCountInvalid(count) }
                    guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                    let center = body.bounds.center
                    let full = total >= 359.999
                    var acc = body
                    for i in 1..<count {
                        let a = full ? total * Double(i) / Double(count)
                                     : total * Double(i) / Double(count - 1)
                        acc = try CSG.union(acc, body.rotatedAround(axis: axis, degrees: a, center: center))
                    }
                    body = acc
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "circular pattern ok", context: ["feature": feature.name, "count": "\(count)"])
                    continue
                }
                if case .threadShaft(let spec) = feature.kind {
                    // Threads merge WITHOUT a raw CSG union of the ridge:
                    // BSP clipping dices body faces against the helix and
                    // explodes the triangle count (169k for one M10 shaft
                    // on a plate). Union only the plain core cylinder,
                    // then append the ridge trimmed where it dives below
                    // the body's surface along the shaft column.
                    let (vspec, tw) = try spec.validated()
                    warnings += tw
                    let core = try Tessellation.cylinder(radius: vspec.minorDiameter / 2,
                                                         height: vspec.length, baseZ: 0,
                                                         taperDegrees: vspec.taperDegrees)
                    var ridge = try ThreadTessellator.ridgeMesh(spec: vspec)
                    if body.triangleCount > 0 {
                        let rLim = vspec.majorDiameter / 2 + 0.5
                        var zTop = -Double.infinity
                        for v in body.vertices where v.x * v.x + v.y * v.y < rLim * rLim {
                            zTop = max(zTop, v.z)
                        }
                        if zTop.isFinite {
                            ridge = ridge.keepingTriangles(aboveZ: zTop - vspec.pitch * 0.5)
                        }
                        body = try CSG.union(body, core)
                        body.append(ridge)
                    } else {
                        body = core
                        body.append(ridge)
                    }
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "thread ok", context: ["feature": feature.name])
                    continue
                }
                if case .filletEdges(let radius, let midpoints) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.filletFailed("no solid to fillet yet") }
                    body = try EdgeFinisher.fillet(body: body, radius: radius, onlyMidpoints: midpoints)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "fillet edges ok", context: ["feature": feature.name, "edges": "\(midpoints.count)"])
                    continue
                }
                if case .chamferEdges(let distance, let midpoints) = feature.kind {
                    guard body.triangleCount > 0 else { throw CADError.chamferInvalid("no solid to chamfer yet") }
                    body = try EdgeFinisher.chamfer(body: body, distance: distance, onlyMidpoints: midpoints)
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "chamfer edges ok", context: ["feature": feature.name, "edges": "\(midpoints.count)"])
                    continue
                }
                if case .threadOnShaft(let spec, let origin, let axis) = feature.kind {
                    // Thread an EXISTING shaft (fitted by the app from a
                    // tapped pillar): cut the plain cylinder out, union
                    // the threaded core, append the ridge trimmed to
                    // the shaft's span — the same low-triangle merge as
                    // .threadShaft (never raw-union a ridge).
                    guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                    guard spec.kind == .external else {
                        throw CADError.threadProfileInvalid("threading a hole wall is not supported yet — pick an outside shaft")
                    }
                    let (vspec, tw) = try spec.validated()
                    warnings += tw
                    let ax = axis.normalized
                    let rOut = vspec.majorDiameter / 2
                    // Measure the shaft's TRUE extent along its axis
                    // from the body itself. The spec's length comes
                    // from the app's fitted patch, which stops at
                    // seams, fillet runouts and junctions and can
                    // understate the shaft — on device, threads ended
                    // short of the pillar's end (2026-10-26). Every
                    // triangle lying wholly inside the shaft column
                    // (radius major/2 + 0.5 around the axis line)
                    // votes with its axial span; the thread covers
                    // that whole span, or spec.length when longer.
                    // (The triangle-whole test keeps stray in-column
                    // vertices — a neighbouring hole's wall, a plate
                    // corner — from stretching the span.)
                    var lo = 0.0
                    var hi = vspec.length
                    for t in 0..<body.triangleCount {
                        var sMin = Double.infinity
                        var sMax = -Double.infinity
                        var inside = true
                        for k in 0..<3 {
                            let v = body.vertices[Int(body.indices[t * 3 + k])]
                            let d = v - origin
                            let s = d.dot(ax)
                            if (d - ax * s).length > rOut + 0.5 { inside = false; break }
                            sMin = min(sMin, s)
                            sMax = max(sMax, s)
                        }
                        if inside {
                            lo = min(lo, sMin)
                            hi = max(hi, sMax)
                        }
                    }
                    var effSpec = vspec
                    effSpec.length = hi - lo
                    if effSpec.taperDegrees > 0 {
                        // A longer span shrinks a tapered thread's far
                        // end further; keep it from closing past the
                        // minor diameter (validated() checked the
                        // requested length, not the measured one).
                        let maxLen = (effSpec.majorDiameter - effSpec.minorDiameter - 0.1)
                            / (2 * tan(effSpec.taperDegrees * .pi / 180))
                        effSpec.length = min(effSpec.length, max(maxLen, vspec.length))
                    }
                    let effOrigin = origin + ax * lo
                    // The cutter is a hair WIDER than the shaft
                    // (+0.05): a cutter exactly the shaft's radius is
                    // coincident with the wall it must remove, and BSP
                    // classification of coincident surfaces can leave
                    // smooth patches of the old wall interrupting the
                    // thread. The ridge crest defines the outside.
                    var cutter = try Tessellation.cylinder(radius: rOut + 0.05, height: effSpec.length + 2, baseZ: -1)
                    cutter = cutter.placed(axis: ax, origin: effOrigin)
                    var rest = try CSG.subtract(body, cutter)
                    let core = try Tessellation.cylinder(radius: effSpec.minorDiameter / 2,
                                                         height: effSpec.length, baseZ: 0,
                                                         taperDegrees: effSpec.taperDegrees)
                        .placed(axis: ax, origin: effOrigin)
                    rest = try CSG.union(rest, core)
                    var ridge = try ThreadTessellator.ridgeMesh(spec: effSpec)
                    ridge = ridge.placed(axis: ax, origin: effOrigin)
                    ridge = ridge.keepingTriangles(axis: effOrigin, axis: ax,
                                                   between: -effSpec.pitch * 0.5,
                                                   and: effSpec.length + effSpec.pitch * 0.5)
                    rest.append(ridge)
                    body = rest
                    statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                    logger.debug(.feature, "thread on shaft ok", context: ["feature": feature.name])
                    continue
                }
                let m = try evaluate(feature: feature, part: part, warnings: &warnings)
                switch feature.kind {
                case .pocket, .hole:
                    guard body.triangleCount > 0 else { throw CADError.booleanEmptyResult }
                    body = try CSG.subtract(body, m)
                default:
                    body = body.triangleCount == 0 ? m : try CSG.union(body, m)
                }
                statuses.append(FeatureStatus(featureID: feature.id, ok: true, errorCode: nil, message: nil))
                logger.debug(.feature, "feature ok", context: ["feature": feature.name, "tris": "\(m.triangleCount)"])
            } catch let e as CADError {
                let wrapped = CADError.featureRebuildFailed(feature: feature.name, underlyingCode: e.code)
                logger.log(error: e, category: .feature, context: ["feature": feature.name])
                logger.log(error: wrapped, category: .document, context: ["underlying": e.code])
                statuses.append(FeatureStatus(featureID: feature.id, ok: false, errorCode: e.code, message: e.userMessage))
                firstError = e
            } catch {
                let e = CADError.unknown("\(error)")
                logger.log(error: e, category: .feature, context: ["feature": feature.name])
                statuses.append(FeatureStatus(featureID: feature.id, ok: false, errorCode: e.code, message: e.userMessage))
                firstError = e
            }
        }
        var allBodies = bodies
        if body.triangleCount > 0 { allBodies.append(body) }
        var combined = Mesh()
        for b in allBodies { combined.append(b) }
        let mass = combined.volume / 1000.0 * part.material.density  // mm^3 -> cm^3 * g/cm^3
        logger.info(.perf, "rebuild done", context: [
            "ms": String(format: "%.1f", Date().timeIntervalSince(start) * 1000),
            "tris": "\(combined.triangleCount)",
            "bodies": "\(allBodies.count)",
            "ok": firstError == nil ? "1" : "0",
        ])
        return RebuildResult(mesh: combined, bodies: allBodies, statuses: statuses, warnings: warnings,
                             firstError: firstError, massGrams: mass)
    }

    /// Chain a sketch's line entities into an ordered world-space polyline
    /// (the sweep path).
    static func pathPoints(sketch: Sketch) throws -> [Vec3] {
        var segments: [(Vec2, Vec2)] = []
        for e in sketch.entities where !e.isConstruction {
            if case .line(_, let a, let b, _) = e { segments.append((a, b)) }
        }
        guard !segments.isEmpty else { throw CADError.sweepPathInvalid("the path sketch needs connected lines") }
        var chain: [Vec2] = [segments[0].0, segments[0].1]
        var pool = Array(segments.dropFirst())
        var grew = true
        while grew {
            grew = false
            for i in pool.indices {
                let (a, b) = pool[i]
                if a.distance(to: chain.last!) < 1e-6 { chain.append(b); pool.remove(at: i); grew = true; break }
                if b.distance(to: chain.last!) < 1e-6 { chain.append(a); pool.remove(at: i); grew = true; break }
                if a.distance(to: chain.first!) < 1e-6 { chain.insert(b, at: 0); pool.remove(at: i); grew = true; break }
                if b.distance(to: chain.first!) < 1e-6 { chain.insert(a, at: 0); pool.remove(at: i); grew = true; break }
            }
        }
        guard chain.count >= 2 else { throw CADError.sweepPathInvalid("path lines do not connect") }
        return chain.map { sketch.plane.toWorld($0) }
    }

    /// Map a +Z-built tool mesh (z: 0…height) onto a sketch plane so it
    /// starts `above` mm over the surface point and reaches into the part
    /// along −normal.
    static func orientCylinder(_ m: Mesh, plane: Plane3, center: Vec3, above: Double, depth: Double) -> Mesh {
        let n = plane.normal
        let verts = m.vertices.map { v in
            center + plane.xAxis * v.x + plane.yAxis * v.y + n * (above - v.z)
        }
        _ = depth
        // The z -> (above - z) map is a reflection: flip winding to restore
        // outward normals, or CSG will treat the tool as inside-out.
        var idx: [UInt32] = []
        for t in 0..<m.triangleCount {
            idx += [m.indices[t * 3], m.indices[t * 3 + 2], m.indices[t * 3 + 1]]
        }
        return Mesh(vertices: verts, indices: idx)
    }

    static func evaluate(feature: Feature, part: Part, warnings: inout [CADError]) throws -> Mesh {
        switch feature.kind {
        case .pad(let sketchID, let length):
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            let (profiles, w) = try sketch.extractProfiles()
            warnings += w
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            return try Tessellation.extrude(profile: profile, plane: sketch.plane, length: length)
        case .pocket(let sketchID, let depth):
            guard depth > 0 else { throw CADError.holeSpecInvalid("pocket depth must be > 0") }
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            let (profiles, w) = try sketch.extractProfiles()
            warnings += w
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            // Prism spanning from 1 mm above the sketch plane to `depth`
            // below it; rebuild subtracts it from the body.
            let prism = try Tessellation.extrude(profile: profile, plane: sketch.plane, length: depth + 1)
            return prism.translated(by: sketch.plane.normal * -depth)
        case .hole(let sketchID, let diameter, let depth, let kind):
            guard diameter > 0 else { throw CADError.holeSpecInvalid("diameter must be > 0") }
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            // Drill sites: sketch points drill at the feature's
            // diameter; sketch circles drill at their OWN diameter
            // (2 x radius) — a sketched circle is the hole's profile,
            // not just a center marker. (Device bug, 2026-10-26: a
            // big circle + Hole produced a small hole at its center,
            // drilled at the panel diameter.)
            var sites: [(center: Vec2, diameter: Double)] = []
            for e in sketch.entities where !e.isConstruction {
                switch e {
                case .point(_, let at, _):
                    sites.append((at, diameter))
                case .circle(_, let c, let r, _):
                    sites.append((c, r > 0 ? 2 * r : diameter))
                default: break
                }
            }
            guard !sites.isEmpty else { throw CADError.holeSpecInvalid("the hole sketch needs a point or circle center") }
            // Depth 0 = through: the cutter is a full column along the
            // axis (cutDepth each way from the sketch plane), so the
            // hole really passes through everything on that axis —
            // including material piled over the sketch plane (the demo
            // part's boss sits on the very face its sketch came from,
            // and a plane-anchored cutter left its top half uncut,
            // i.e. the "through" hole was blind from that side).
            // A blind hole (depth > 0) starts at the sketch plane and
            // reaches `depth` into the part, as before.
            let through = depth <= 0
            let cutDepth = through ? 10_000.0 : depth
            let toolHeight = through ? 2 * cutDepth : cutDepth + 1
            let toolAbove = through ? cutDepth : 1.0
            var tool = Mesh()
            for site in sites {
                let center3 = sketch.plane.toWorld(site.center)
                var cyl = try Tessellation.cylinder(radius: site.diameter / 2, height: toolHeight, segments: 48)
                // Cylinder is built along +Z from z=0; orient it along -normal
                // starting 1 mm above the plane.
                cyl = orientCylinder(cyl, plane: sketch.plane, center: center3, above: toolAbove, depth: toolHeight)
                tool.append(cyl)
                switch kind {
                case .simple: break
                case .counterbore(let cbD, let cbDepth):
                    guard cbD > diameter, cbDepth > 0, cbDepth < cutDepth else {
                        throw CADError.holeSpecInvalid("counterbore must be wider and shallower than the hole")
                    }
                    // The bore keeps the panel's size, measured from
                    // the sketch plane. Where a circle site is already
                    // wider than the bore, the bore cutter would be
                    // buried inside the hole and cut nothing — skip it
                    // for that site (and never error over it).
                    if site.diameter < cbD {
                        var cb = try Tessellation.cylinder(radius: cbD / 2, height: cbDepth + 1, segments: 48)
                        cb = orientCylinder(cb, plane: sketch.plane, center: center3, above: 1, depth: cbDepth + 1)
                        tool.append(cb)
                    }
                case .countersink(let angle):
                    guard angle > 0, angle < 180 else { throw CADError.holeSpecInvalid("countersink angle 0-180") }
                    let coneH = (diameter / 2) / tan(angle / 2 * .pi / 180)
                    var cone = try Tessellation.cone(radius: diameter / 2, height: coneH, segments: 48)
                    cone = orientCylinder(cone, plane: sketch.plane, center: center3, above: 1, depth: coneH + 1)
                    tool.append(cone)
                }
            }
            return tool
        case .revolve(let sketchID, let axisEntityID, let angle):
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            guard let axisEnt = sketch.entity(axisEntityID),
                  case .line(_, let a, let b, _) = axisEnt else { throw CADError.revolveAxisMissing }
            let (profiles, w) = try sketch.extractProfiles()
            warnings += w
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            return try Tessellation.revolve(profile: profile, plane: sketch.plane,
                                             axisPoint: a, axisDirection: b - a, angleDegrees: angle)
        case .primitive(let kind, let p):
            switch kind {
            case .box:
                return try Tessellation.box(width: p["width"] ?? 10, depth: p["depth"] ?? 10, height: p["height"] ?? 10)
            case .cylinder:
                return try Tessellation.cylinder(radius: (p["diameter"] ?? 10) / 2, height: p["height"] ?? 10)
            case .sphere:
                return try Tessellation.sphere(radius: (p["diameter"] ?? 10) / 2)
            case .cone:
                return try Tessellation.cone(radius: (p["diameter"] ?? 10) / 2, height: p["height"] ?? 10)
            case .torus:
                return try Tessellation.torus(ringRadius: p["ringRadius"] ?? 15, tubeRadius: p["tubeRadius"] ?? 5)
            }
        case .threadShaft:
            throw CADError.invariantBroken("thread shafts must be handled by rebuild, not evaluate")
        case .linearPattern:
            throw CADError.invariantBroken("pattern must be handled by rebuild, not evaluate")
        case .mirror:
            throw CADError.invariantBroken("mirror must be handled by rebuild, not evaluate")
        case .fillet, .chamfer, .shell, .chamfer2, .extrude2, .rib, .draftBody, .scaleBody, .moveBody, .splitBody, .circularPattern, .filletEdges, .chamferEdges, .threadOnShaft:
            throw CADError.invariantBroken("body-dependent feature must be handled by rebuild, not evaluate")
        case .coil(let radius, let pitch, let turns, let wireRadius):
            return try coilMesh(radius: radius, pitch: pitch, turns: turns, wireRadius: wireRadius)
        case .pipe(let pathSketchID, let radius):
            return try pipeMesh(part: part, pathSketchID: pathSketchID, radius: radius)
        case .extrude(let sketchID, let distance, let taper, let mode):
            guard distance > 0 else { throw CADError.padLengthInvalid(distance) }
            guard let sketch = part.sketch(sketchID) else { throw CADError.nameNotFound("sketch") }
            let (profiles, w) = try sketch.extractProfiles()
            warnings += w
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            switch mode {
            case .one:
                return try Tessellation.extrudeTapered(profile: profile, plane: sketch.plane, length: distance, taperDegrees: taper)
            case .symmetric:
                let shifted = Plane3(origin: sketch.plane.origin - sketch.plane.normal * (distance / 2),
                                     xAxis: sketch.plane.xAxis, yAxis: sketch.plane.yAxis)
                return try Tessellation.extrudeTapered(profile: profile, plane: shifted, length: distance, taperDegrees: taper)
            case .twoSided(let second):
                guard second > 0 else { throw CADError.padLengthInvalid(second) }
                var m = try Tessellation.extrudeTapered(profile: profile, plane: sketch.plane, length: distance, taperDegrees: taper)
                let backPlane = Plane3(origin: sketch.plane.origin - sketch.plane.normal * second,
                                       xAxis: sketch.plane.xAxis, yAxis: sketch.plane.yAxis)
                let back = try Tessellation.extrudeTapered(profile: profile, plane: backPlane, length: second, taperDegrees: taper)
                m.append(back)
                return m
            }
        case .loft(let idA, let idB):
            guard let skA = part.sketch(idA), let skB = part.sketch(idB) else { throw CADError.nameNotFound("sketch") }
            let loopA = try ProfileLoop.worldLoop(sketch: skA)
            let loopB = try ProfileLoop.worldLoop(sketch: skB)
            return try LoftTessellator.loft(loopA: loopA.points, loopB: loopB.points)
        case .sweep(let profileID, let pathID):
            guard let skP = part.sketch(profileID), let skPath = part.sketch(pathID) else { throw CADError.nameNotFound("sketch") }
            let loop = try ProfileLoop.worldLoop(sketch: skP)
            let path = try DocumentEngine.pathPoints(sketch: skPath)
            return try SweepTessellator.sweep(profileLoop: loop.points, profilePlane: skP.plane, path: path)
        case .booleanCutPlaceholder:
            throw CADError.booleanFailed("exact boolean arrives with the OCCT kernel bridge")
        }
    }

    /// Pattern needs the running body, so rebuild handles it specially:
    /// this helper is used by the app/tests to expand a mesh.
    public static func applyPattern(mesh: Mesh, count: Int, spacing: Vec3) throws -> Mesh {
        guard count >= 1, spacing.length > 0 else { throw CADError.patternCountInvalid(count) }
        var out = Mesh()
        for i in 0..<count { out.append(mesh.translated(by: spacing * Double(i))) }
        return out
    }
}

/// Formula evaluator for dimension equations: numbers, names, + - * / ^,
/// parentheses, sqrt/abs/min/max, pi. Throws DC111/DC112.
public enum EquationEvaluator {
    public static func evaluate(_ expr: String, variables: [String: Double]) throws -> Double {
        var parser = Parser(expr: expr, variables: variables)
        return try parser.parse()
    }

    struct Parser {
        let chars: [Character]
        var pos = 0
        let variables: [String: Double]
        init(expr: String, variables: [String: Double]) {
            self.chars = Array(expr)
            self.variables = variables
        }
        mutating func parse() throws -> Double {
            let v = try parseExpr()
            skipSpaces()
            guard pos >= chars.count else { throw CADError.equationParseError("trailing characters", position: pos) }
            guard v.isFinite else { throw CADError.equationEvalError("non-finite result") }
            return v
        }
        mutating func skipSpaces() { while pos < chars.count && chars[pos] == " " { pos += 1 } }
        mutating func parseExpr() throws -> Double {
            var v = try parseTerm()
            while true {
                skipSpaces()
                guard pos < chars.count else { return v }
                if chars[pos] == "+" { pos += 1; v += try parseTerm() }
                else if chars[pos] == "-" { pos += 1; v -= try parseTerm() }
                else { return v }
            }
        }
        mutating func parseTerm() throws -> Double {
            var v = try parseFactor()
            while true {
                skipSpaces()
                guard pos < chars.count else { return v }
                if chars[pos] == "*" { pos += 1; v *= try parseFactor() }
                else if chars[pos] == "/" {
                    pos += 1
                    let d = try parseFactor()
                    guard d != 0 else { throw CADError.equationEvalError("divide by zero") }
                    v /= d
                } else { return v }
            }
        }
        mutating func parseFactor() throws -> Double {
            var base = try parseAtom()
            skipSpaces()
            if pos < chars.count && chars[pos] == "^" {
                pos += 1
                let exp = try parseFactor()
                base = pow(base, exp)
            }
            return base
        }
        mutating func parseAtom() throws -> Double {
            skipSpaces()
            guard pos < chars.count else { throw CADError.equationParseError("unexpected end", position: pos) }
            let c = chars[pos]
            if c == "(" {
                pos += 1
                let v = try parseExpr()
                skipSpaces()
                guard pos < chars.count && chars[pos] == ")" else {
                    throw CADError.equationParseError("missing )", position: pos)
                }
                pos += 1
                return v
            }
            if c == "-" { pos += 1; return -(try parseAtom()) }
            if c.isNumber || c == "." {
                var s = ""
                while pos < chars.count && (chars[pos].isNumber || chars[pos] == ".") { s.append(chars[pos]); pos += 1 }
                guard let v = Double(s) else { throw CADError.equationParseError("bad number", position: pos) }
                return v
            }
            if c.isLetter || c == "_" {
                var s = ""
                while pos < chars.count && (chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_") { s.append(chars[pos]); pos += 1 }
                skipSpaces()
                if pos < chars.count && chars[pos] == "(" {
                    pos += 1
                    var args: [Double] = [try parseExpr()]
                    skipSpaces()
                    while pos < chars.count && chars[pos] == "," {
                        pos += 1; args.append(try parseExpr()); skipSpaces()
                    }
                    guard pos < chars.count && chars[pos] == ")" else {
                        throw CADError.equationParseError("missing )", position: pos)
                    }
                    pos += 1
                    switch s {
                    case "sqrt": guard args[0] >= 0 else { throw CADError.equationEvalError("sqrt of negative") }; return sqrt(args[0])
                    case "abs": return abs(args[0])
                    case "min": return args.min()!
                    case "max": return args.max()!
                    case "sin": return sin(args[0] * .pi / 180)
                    case "cos": return cos(args[0] * .pi / 180)
                    default: throw CADError.equationEvalError("unknown function \(s)")
                    }
                }
                if s == "pi" { return .pi }
                guard let v = variables[s] else { throw CADError.equationEvalError("unknown name \(s)") }
                return v
            }
            throw CADError.equationParseError("unexpected \(c)", position: pos)
        }
    }
}
