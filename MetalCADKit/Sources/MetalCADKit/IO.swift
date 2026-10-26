import Foundation

public enum IOService {

    // MARK: Document JSON

    public static func saveJSON(_ doc: CADDocument, to url: URL, logger: MCLog = .shared) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(doc)
            try data.write(to: url, options: .atomic)
            logger.info(.io, "document saved", context: ["bytes": "\(data.count)", "name": doc.name])
        } catch let e as CADError { throw e }
        catch { throw CADError.snapshotWriteFailed("\(error)") }
    }

    public static func loadJSON(from url: URL, logger: MCLog = .shared) throws -> (doc: CADDocument, warnings: [CADError]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CADError.documentNotFound(url.lastPathComponent)
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw CADError.importFileUnreadable("\(error)") }
        return try loadJSON(data: data, logger: logger)
    }

    public static func loadJSON(data: Data, logger: MCLog = .shared) throws -> (doc: CADDocument, warnings: [CADError]) {
        // Sniff the format version before full decode for a precise error.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = obj["formatVersion"] as? Int {
            if v > CADDocument.currentFormatVersion {
                throw CADError.documentVersionTooNew(found: v, supported: CADDocument.currentFormatVersion)
            }
        }
        do {
            let doc = try JSONDecoder().decode(CADDocument.self, from: data)
            var warnings: [CADError] = []
            if doc.formatVersion < CADDocument.currentFormatVersion {
                warnings.append(.documentVersionTooOld(found: doc.formatVersion))
            }
            logger.info(.io, "document loaded", context: ["name": doc.name, "parts": "\(doc.parts.count)"])
            return (doc, warnings)
        } catch let e as CADError { throw e }
        catch { throw CADError.documentCorruptJSON("\(error)") }
    }

    // MARK: Binary STL

    /// Write binary STL. Returns warnings (IO704 when not watertight).
    @discardableResult
    public static func writeSTL(_ mesh: Mesh, to url: URL, logger: MCLog = .shared) throws -> [CADError] {
        var warnings: [CADError] = []
        if !mesh.isWatertight {
            warnings.append(.exportNotWatertight(openEdges: mesh.openEdgeCount))
        }
        if mesh.hasNaN { throw CADError.kernelShapeInvalid("mesh contains NaN vertices") }
        // One pre-sized buffer, floats appended as raw bytes — no
        // per-float Data allocations (12+ per triangle at 1M tris).
        var data = Data()
        data.reserveCapacity(84 + mesh.triangleCount * 50)
        data.append(Data(count: 80))  // header
        var count = UInt32(mesh.triangleCount).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        let normals = mesh.faceNormals()
        for t in 0..<mesh.triangleCount {
            let n = normals[t]
            appendFloat(n.x, &data); appendFloat(n.y, &data); appendFloat(n.z, &data)
            for k in 0..<3 {
                let v = mesh.vertices[Int(mesh.indices[t * 3 + k])]
                appendFloat(v.x, &data); appendFloat(v.y, &data); appendFloat(v.z, &data)
            }
            var attr = UInt16(0).littleEndian
            withUnsafeBytes(of: &attr) { data.append(contentsOf: $0) }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch { throw CADError.exportWriteFailed("\(error)") }
        logger.info(.io, "STL written", context: ["tris": "\(mesh.triangleCount)", "bytes": "\(data.count)"])
        return warnings
    }

    /// Wavefront OBJ: one `v` line per vertex of the mesh as given
    /// (callers pass the welded mesh, so vertices are shared), then
    /// one 1-indexed `f` line per triangle. Plain and correct — no
    /// normals or texture coordinates; readers compute flat shading.
    public static func writeOBJ(_ mesh: Mesh, to url: URL, logger: MCLog = .shared) throws -> [CADError] {
        var warnings: [CADError] = []
        if !mesh.isWatertight {
            warnings.append(.exportNotWatertight(openEdges: mesh.openEdgeCount))
        }
        if mesh.hasNaN { throw CADError.kernelShapeInvalid("mesh contains NaN vertices") }
        func num(_ v: Double) -> String { String(format: "%.6f", v == 0 ? 0 : v) }
        var text = "# MetalCAD OBJ export\n"
        // Pre-size from line-count estimates (~28 chars per vertex line,
        // ~24 per face line) so the string doesn't grow by reallocation.
        text.reserveCapacity(22 + mesh.vertices.count * 28 + mesh.triangleCount * 24)
        for v in mesh.vertices {
            text += "v \(num(v.x)) \(num(v.y)) \(num(v.z))\n"
        }
        for t in 0..<mesh.triangleCount {
            let a = Int(mesh.indices[t * 3]) + 1
            let b = Int(mesh.indices[t * 3 + 1]) + 1
            let c = Int(mesh.indices[t * 3 + 2]) + 1
            text += "f \(a) \(b) \(c)\n"
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch { throw CADError.exportWriteFailed("\(error)") }
        logger.info(.io, "OBJ written", context: ["tris": "\(mesh.triangleCount)", "verts": "\(mesh.vertices.count)"])
        return warnings
    }

    public static func readSTL(data: Data) throws -> Mesh {
        guard data.count >= 84 else { throw CADError.importFileUnreadable("STL too short") }
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian }
        let expected = 84 + Int(count) * 50
        guard data.count >= expected else {
            throw CADError.importFileUnreadable("STL truncated: declares \(count) triangles")
        }
        // Vertex dedupe by exact bit pattern for watertight
        // reconstruction. The key is the three raw Float bit patterns
        // in a Hashable struct — the old string key formatted three
        // integers per corner (3M strings on a 1M-triangle file).
        var verts: [Vec3] = []
        var idx: [UInt32] = []
        idx.reserveCapacity(Int(count) * 3)
        var seen: [VertKey: UInt32] = [:]
        seen.reserveCapacity(Int(count) * 2)
        func vertex(_ off: Int) -> UInt32 {
            let x = readFloat(data, off), y = readFloat(data, off + 4), z = readFloat(data, off + 8)
            let key = VertKey(x: x.bitPattern, y: y.bitPattern, z: z.bitPattern)
            if let i = seen[key] { return i }
            verts.append(Vec3(Double(x), Double(y), Double(z)))
            let i = UInt32(verts.count - 1)
            seen[key] = i
            return i
        }
        for t in 0..<Int(count) {
            let base = 84 + t * 50 + 12
            idx.append(vertex(base))
            idx.append(vertex(base + 12))
            idx.append(vertex(base + 24))
        }
        // STL floats are untrusted bytes: a NaN/Inf coordinate used
        // to sail through into the mesh, where the next weld/display
        // pass trapped on Int(floor(NaN)) (2026-10-26 sweep). Reject
        // the file instead.
        if verts.contains(where: { !$0.isFinite() }) {
            throw CADError.importGeometryInvalid("STL contains non-finite vertex coordinates")
        }
        return Mesh(vertices: verts, indices: idx)
    }

    /// Exact Float bit-pattern triple used as the STL import dedupe key.
    private struct VertKey: Hashable {
        var x: UInt32, y: UInt32, z: UInt32
    }

    private static func appendFloat(_ v: Double, _ data: inout Data) {
        var bits = Float(v).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    private static func readFloat(_ data: Data, _ off: Int) -> Float {
        let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian }
        return Float(bitPattern: bits)
    }
}
