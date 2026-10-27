import Foundation
import MetalCADKit

/// Turns a `VoxelGrid` back into a kit `Mesh`: the surface of the
/// solid region, one quad (two triangles) per solid/non-solid cell
/// face in the 6-neighborhood.
///
/// Vertices are the grid corners, shared between adjacent quads (the
/// output is welded by construction — every corner appears exactly
/// once), and winding is counter-clockwise seen from outside, so the
/// mesh has outward normals and positive signed volume on a closed
/// grid.
///
/// An optional `displacement` closure maps each corner's world
/// position (mm) to a displacement (mm) added to it — used by the
/// structural sim to render its deformed shape, and written generally
/// so any grid-based sim (erosion, thermal expansion, …) can reuse it.
///
/// Everything is emitted in fixed row-major order (z, then y, then x;
/// directions in +x, −x, +y, −y, +z, −z order per cell), so the output
/// is deterministic.
public enum MeshExtraction {

    /// The surface mesh of `grid`'s solid cells.
    public static func surfaceMesh(of grid: VoxelGrid,
                                   displacement: ((Vec3) -> Vec3)? = nil) -> Mesh {
        let nx = grid.nx, ny = grid.ny, nz = grid.nz
        let h = grid.cellSize
        let cornersX = nx + 1, cornersY = ny + 1
        var builder = MeshBuilder()
        var vertexIndexByCorner: [Int: UInt32] = [:]

        func cornerVertex(_ cx: Int, _ cy: Int, _ cz: Int) -> UInt32 {
            let key = (cz * cornersY + cy) * cornersX + cx
            if let existing = vertexIndexByCorner[key] { return existing }
            let position = Vec3(grid.origin.x + Double(cx) * h,
                                grid.origin.y + Double(cy) * h,
                                grid.origin.z + Double(cz) * h)
            let displaced = displacement?(position) ?? .zero
            let index = builder.vertex(position + displaced)
            vertexIndexByCorner[key] = index
            return index
        }

        // Quad corner lists per direction, CCW seen from outside
        // (verified against the cross product of the first triangle).
        // Corner offsets are relative to the cell's (i, j, k).
        //
        //   +x: (1,0,0) (1,1,0) (1,1,1) (1,0,1)
        //   −x: (0,0,0) (0,0,1) (0,1,1) (0,1,0)
        //   +y: (0,1,0) (0,1,1) (1,1,1) (1,1,0)
        //   −y: (0,0,0) (1,0,0) (1,0,1) (0,0,1)
        //   +z: (0,0,1) (1,0,1) (1,1,1) (0,1,1)
        //   −z: (0,0,0) (0,1,0) (1,1,0) (1,0,0)
        let faces: [(di: Int, dj: Int, dk: Int, corners: [(Int, Int, Int)])] = [
            ( 1, 0, 0, [(1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)]),
            (-1, 0, 0, [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)]),
            (0,  1, 0, [(0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0)]),
            (0, -1, 0, [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]),
            (0, 0,  1, [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]),
            (0, 0, -1, [(0, 0, 0), (0, 1, 0), (1, 1, 0), (1, 0, 0)]),
        ]

        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx where grid.isSolid(x: i, y: j, z: k) {
                    for face in faces {
                        // Out-of-grid neighbors read as .outside
                        // (non-solid) via VoxelGrid.kind.
                        guard grid.kind(x: i + face.di, y: j + face.dj, z: k + face.dk) != .solid
                        else { continue }
                        let c = face.corners.map {
                            cornerVertex(i + $0.0, j + $0.1, k + $0.2)
                        }
                        builder.quad(c[0], c[1], c[2], c[3])
                    }
                }
            }
        }
        return builder.mesh
    }
}
