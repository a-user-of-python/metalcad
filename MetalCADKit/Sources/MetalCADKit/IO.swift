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
        var data = Data()
        data.append(Data(count: 80))  // header
        var count = UInt32(mesh.triangleCount).littleEndian
        data.append(Data(bytes: &count, count: 4))
        let normals = mesh.faceNormals()
        for t in 0..<mesh.triangleCount {
            let n = normals[t]
            appendFloat(n.x, &data); appendFloat(n.y, &data); appendFloat(n.z, &data)
            for k in 0..<3 {
                let v = mesh.vertices[Int(mesh.indices[t * 3 + k])]
                appendFloat(v.x, &data); appendFloat(v.y, &data); appendFloat(v.z, &data)
            }
            var attr = UInt16(0).littleEndian
            data.append(Data(bytes: &attr, count: 2))
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch { throw CADError.exportWriteFailed("\(error)") }
        logger.info(.io, "STL written", context: ["tris": "\(mesh.triangleCount)", "bytes": "\(data.count)"])
        return warnings
    }

    public static func readSTL(data: Data) throws -> Mesh {
        guard data.count >= 84 else { throw CADError.importFileUnreadable("STL too short") }
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian }
        let expected = 84 + Int(count) * 50
        guard data.count >= expected else {
            throw CADError.importFileUnreadable("STL truncated: declares \(count) triangles")
        }
        var mesh = Mesh()
        // Vertex dedupe by exact bit pattern for watertight reconstruction.
        var seen: [String: UInt32] = [:]
        func vertex(_ off: Int) -> UInt32 {
            let x = readFloat(data, off), y = readFloat(data, off + 4), z = readFloat(data, off + 8)
            let key = "\(x.bitPattern),\(y.bitPattern),\(z.bitPattern)"
            if let i = seen[key] { return i }
            mesh.vertices.append(Vec3(Double(x), Double(y), Double(z)))
            let i = UInt32(mesh.vertices.count - 1)
            seen[key] = i
            return i
        }
        for t in 0..<Int(count) {
            let base = 84 + t * 50 + 12
            mesh.indices.append(vertex(base))
            mesh.indices.append(vertex(base + 12))
            mesh.indices.append(vertex(base + 24))
        }
        return mesh
    }

    private static func appendFloat(_ v: Double, _ data: inout Data) {
        var bits = Float(v).bitPattern.littleEndian
        data.append(Data(bytes: &bits, count: 4))
    }
    private static func readFloat(_ data: Data, _ off: Int) -> Float {
        let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian }
        return Float(bitPattern: bits)
    }
}
