import Foundation
import MetalCADKit

/// What a voxel cell contains.
public enum CellKind: UInt8, Equatable {
    /// Enclosed void: inside the grid but neither solid nor connected
    /// to the grid boundary (an internal cavity / trapped pocket).
    case void = 0
    /// Solid material.
    case solid = 1
    /// Open void: connected to the grid boundary (the world outside
    /// the part, plus any cavity that opens to it).
    case outside = 2
}

/// A kit `Mesh` voxelized onto a regular grid — the shared spatial
/// foundation for every volumetric simulation in this package.
///
/// All units are **millimetres**, matching the kit: cell size, origin,
/// and centers are in mm; volumes in mm³.
///
/// Voxelization is scanline parity fill: for each (x, y) column, one
/// ray is cast along +Z through the column center (using `RayCaster`,
/// whose merged hit distances make parity counting correct across
/// shared edges); a cell is solid when its center lies between an
/// odd/even pair of crossings. This assumes a closed (watertight)
/// mesh — for an open mesh the parity rule still yields a definite,
/// deterministic grid, but interior/exterior may be misjudged near
/// the openings.
///
/// Grid placement: the grid's origin is the mesh bounds' minimum
/// corner and it covers the bounds exactly (dims = ceil(extent /
/// cellSize), at least 1 per axis). Cell (x, y, z) covers
/// origin + [i·h, (i+1)·h) on each axis; its center is at
/// origin + (i + 0.5)·h.
///
/// Determinism: fixed ray set, sorted hits, row-major storage and
/// iteration — identical inputs give identical grids.
public struct VoxelGrid {
    /// Default maximum number of cells (8M ≈ a 200³ grid).
    public static let defaultMaxCells = 8_000_000

    /// Grid origin = the mesh bounds' minimum corner (mm).
    public let origin: Vec3
    /// Cell edge length h (mm).
    public let cellSize: Double
    /// Cell counts per axis.
    public let nx: Int
    public let ny: Int
    public let nz: Int
    /// The bounds of the source mesh (mm).
    public let meshBounds: BoundingBox

    private var cells: [CellKind]
    /// Number of solid cells.
    public let solidCellCount: Int

    public var cellCount: Int { nx * ny * nz }
    /// Volume of one cell (mm³).
    public var cellVolume: Double { cellSize * cellSize * cellSize }
    /// Total volume of solid cells (mm³).
    public var solidVolume: Double { Double(solidCellCount) * cellVolume }

    // MARK: Construction

    /// Voxelize `mesh` at the given cell size (mm).
    /// - Throws: `SimError.emptyMesh` for a triangle-less mesh,
    ///   `SimError.invalidValue` for a non-positive/non-finite cell
    ///   size or budget, `SimError.degenerateBounds` when the mesh has
    ///   no extent on any axis, `SimError.cellBudgetExceeded` when the
    ///   grid would exceed `maxCells`.
    public init(mesh: Mesh, cellSize: Double, maxCells: Int = VoxelGrid.defaultMaxCells) throws {
        guard mesh.triangleCount > 0 else { throw SimError.emptyMesh }
        guard cellSize.isFinite else { throw SimError.nonFiniteValue(parameter: "cellSize") }
        guard cellSize > 0 else {
            throw SimError.invalidValue(parameter: "cellSize", detail: "must be > 0 mm")
        }
        guard maxCells > 0 else {
            throw SimError.invalidValue(parameter: "maxCells", detail: "must be > 0")
        }
        let bounds = mesh.bounds
        guard !bounds.isEmpty else {
            throw SimError.degenerateBounds(detail: "mesh bounds are empty")
        }
        let size = bounds.size
        guard size.x > 0 || size.y > 0 || size.z > 0 else {
            throw SimError.degenerateBounds(detail: "mesh is a single point")
        }
        let nx = max(1, Int(ceil(size.x / cellSize)))
        let ny = max(1, Int(ceil(size.y / cellSize)))
        let nz = max(1, Int(ceil(size.z / cellSize)))
        let total = nx * ny * nz
        guard total <= maxCells else {
            throw SimError.cellBudgetExceeded(cells: total, budget: maxCells)
        }
        self.origin = bounds.min
        self.cellSize = cellSize
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.meshBounds = bounds

        // Scanline parity fill, one +Z ray per column.
        let caster = RayCaster(mesh: mesh)
        var storage = [CellKind](repeating: .void, count: total)
        let rayOriginZ = bounds.min.z - cellSize
        var solidCount = 0
        for j in 0..<ny {
            let cy = bounds.min.y + (Double(j) + 0.5) * cellSize
            for i in 0..<nx {
                let cx = bounds.min.x + (Double(i) + 0.5) * cellSize
                let hits = caster.allHits(origin: Vec3(cx, cy, rayOriginZ),
                                          direction: Vec3(0, 0, 1))
                guard !hits.isEmpty else { continue }
                let hitZ = hits.map { rayOriginZ + $0 }  // direction is unit +Z
                var crossed = 0  // hits below the current cell center
                for k in 0..<nz {
                    let cz = bounds.min.z + (Double(k) + 0.5) * cellSize
                    while crossed < hitZ.count && hitZ[crossed] < cz { crossed += 1 }
                    if crossed % 2 == 1 {
                        storage[(k * ny + j) * nx + i] = .solid
                        solidCount += 1
                    }
                }
            }
        }
        self.solidCellCount = solidCount
        self.cells = Self.finalizedCells(storage: storage, nx: nx, ny: ny, nz: nz)
    }

    /// Voxelize with `resolution` cells along the mesh's longest axis
    /// (cell size derived from the longest extent). Same throws as the
    /// cell-size initializer.
    public init(mesh: Mesh, resolution: Int, maxCells: Int = VoxelGrid.defaultMaxCells) throws {
        guard resolution > 0 else {
            throw SimError.invalidValue(parameter: "resolution", detail: "must be > 0")
        }
        guard mesh.triangleCount > 0 else { throw SimError.emptyMesh }
        let size = mesh.bounds.size
        let longest = max(size.x, size.y, size.z)
        guard longest > 0 else {
            throw SimError.degenerateBounds(detail: "mesh is a single point")
        }
        try self.init(mesh: mesh, cellSize: longest / Double(resolution), maxCells: maxCells)
    }

    /// Build a grid directly from a solid mask (row-major, x fastest
    /// — the same convention as `flatIndex(x:y:z:)`). Solid cells
    /// come from the mask; every other cell is classified by the same
    /// boundary flood fill the mesh initializers use:
    /// boundary-connected ⇒ `.outside`, enclosed ⇒ `.void`.
    /// `meshBounds` reports the grid extent (origin …
    /// origin + dims·cellSize), since there is no source mesh.
    /// - Throws: `SimError.nonFiniteValue` for a non-finite cell size
    ///   or origin, `SimError.invalidValue` for a non-positive cell
    ///   size, non-positive dims, or a mask whose count is not
    ///   exactly `nx * ny * nz`.
    public init(origin: Vec3, cellSize: Double, solidMask: [Bool],
                nx: Int, ny: Int, nz: Int) throws {
        guard cellSize.isFinite else { throw SimError.nonFiniteValue(parameter: "cellSize") }
        guard cellSize > 0 else {
            throw SimError.invalidValue(parameter: "cellSize", detail: "must be > 0 mm")
        }
        guard nx >= 1, ny >= 1, nz >= 1 else {
            throw SimError.invalidValue(parameter: "dims",
                                        detail: "grid dimensions must be ≥ 1 per axis")
        }
        let total = nx * ny * nz
        guard solidMask.count == total else {
            throw SimError.invalidValue(parameter: "solidMask",
                                        detail: "mask has \(solidMask.count) cells, grid needs \(total)")
        }
        self.origin = origin
        self.cellSize = cellSize
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.meshBounds = BoundingBox(
            min: origin,
            max: origin + Vec3(Double(nx) * cellSize,
                               Double(ny) * cellSize,
                               Double(nz) * cellSize))
        var storage = [CellKind](repeating: .void, count: total)
        var solidCount = 0
        for idx in 0..<total where solidMask[idx] {
            storage[idx] = .solid
            solidCount += 1
        }
        self.solidCellCount = solidCount
        self.cells = Self.finalizedCells(storage: storage, nx: nx, ny: ny, nz: nz)
    }

    /// Marks boundary-connected non-solid cells `.outside` in a
    /// storage that so far only distinguishes solid from void (flood
    /// fill over non-solid cells from every boundary cell). Shared by
    /// all initializers so every grid gets identical classification.
    private static func finalizedCells(storage input: [CellKind],
                                       nx: Int, ny: Int, nz: Int) -> [CellKind] {
        var storage = input
        let total = nx * ny * nz
        var queue: [Int] = []
        queue.reserveCapacity(total / 4)
        func seed(_ idx: Int) {
            if storage[idx] == .void {
                storage[idx] = .outside
                queue.append(idx)
            }
        }
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    let onBoundary = i == 0 || j == 0 || k == 0 || i == nx - 1 || j == ny - 1 || k == nz - 1
                    if onBoundary { seed((k * ny + j) * nx + i) }
                }
            }
        }
        var head = 0
        while head < queue.count {
            let idx = queue[head]; head += 1
            let i = idx % nx
            let j = (idx / nx) % ny
            let k = idx / (nx * ny)
            for (di, dj, dk) in Self.neighborOffsets {
                let (a, b, c) = (i + di, j + dj, k + dk)
                guard a >= 0, b >= 0, c >= 0, a < nx, b < ny, c < nz else { continue }
                seed((c * ny + b) * nx + a)
            }
        }
        return storage
    }

    private static let neighborOffsets = [(1, 0, 0), (-1, 0, 0), (0, 1, 0),
                                          (0, -1, 0), (0, 0, 1), (0, 0, -1)]

    // MARK: Indexing & queries

    /// Row-major flat index (x fastest, then y, then z).
    public func flatIndex(x: Int, y: Int, z: Int) -> Int { (z * ny + y) * nx + x }

    public func isInBounds(x: Int, y: Int, z: Int) -> Bool {
        x >= 0 && y >= 0 && z >= 0 && x < nx && y < ny && z < nz
    }

    /// The kind of a cell; out-of-bounds reads as `.outside`.
    public func kind(x: Int, y: Int, z: Int) -> CellKind {
        guard isInBounds(x: x, y: y, z: z) else { return .outside }
        return cells[flatIndex(x: x, y: y, z: z)]
    }

    public func kind(at flatIndex: Int) -> CellKind { cells[flatIndex] }

    public func isSolid(x: Int, y: Int, z: Int) -> Bool { kind(x: x, y: y, z: z) == .solid }

    /// World-space center (mm) of a cell.
    public func cellCenter(x: Int, y: Int, z: Int) -> Vec3 {
        Vec3(origin.x + (Double(x) + 0.5) * cellSize,
             origin.y + (Double(y) + 0.5) * cellSize,
             origin.z + (Double(z) + 0.5) * cellSize)
    }

    /// The cell containing a world point, or nil when the point lies
    /// outside the grid.
    public func gridIndex(containing point: Vec3) -> (x: Int, y: Int, z: Int)? {
        let i = Int(floor((point.x - origin.x) / cellSize))
        let j = Int(floor((point.y - origin.y) / cellSize))
        let k = Int(floor((point.z - origin.z) / cellSize))
        guard isInBounds(x: i, y: j, z: k) else { return nil }
        return (i, j, k)
    }

    /// The in-bounds face-adjacent (6-) neighbors of a cell, in a fixed
    /// order (+x, −x, +y, −y, +z, −z).
    public func neighbors(x: Int, y: Int, z: Int) -> [(x: Int, y: Int, z: Int)] {
        var out: [(x: Int, y: Int, z: Int)] = []
        for (di, dj, dk) in Self.neighborOffsets {
            let (a, b, c) = (x + di, y + dj, z + dk)
            if isInBounds(x: a, y: b, z: c) { out.append((a, b, c)) }
        }
        return out
    }

    /// A solid cell is a surface cell when at least one of its 6
    /// neighbors is not solid (the grid exterior counts as non-solid).
    public func isSurfaceCell(x: Int, y: Int, z: Int) -> Bool {
        guard isSolid(x: x, y: y, z: z) else { return false }
        for (di, dj, dk) in Self.neighborOffsets {
            if kind(x: x + di, y: y + dj, z: z + dk) != .solid { return true }
        }
        return false
    }

    /// All surface cells, sorted in row-major (x, then y, then z)
    /// order.
    public func surfaceCells() -> [(x: Int, y: Int, z: Int)] {
        var out: [(x: Int, y: Int, z: Int)] = []
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx where isSurfaceCell(x: i, y: j, z: k) {
                    out.append((i, j, k))
                }
            }
        }
        return out
    }
}
