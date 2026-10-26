import XCTest
import MetalCADKit
@testable import MetalCADSim

final class VoxelGridTests: XCTestCase {

    func testBoxGridExactAtUnitCells() throws {
        // Box 10×10×10 mm at h = 1: every column center lands strictly
        // inside the footprint, so exactly 1000 of 1000 cells are solid.
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let grid = try VoxelGrid(mesh: mesh, cellSize: 1)
        XCTAssertEqual(grid.nx, 10)
        XCTAssertEqual(grid.ny, 10)
        XCTAssertEqual(grid.nz, 10)
        XCTAssertEqual(grid.solidCellCount, 1000)
        XCTAssertEqual(grid.solidVolume, 1000, accuracy: 1e-9)
        XCTAssertEqual(grid.origin, Vec3(-5, -5, 0))
    }

    func testBoxVolumeWithinCellTolerance() throws {
        // Awkward cell size that doesn't divide the box evenly.
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let grid = try VoxelGrid(mesh: mesh, cellSize: 0.83)
        let relError = abs(grid.solidVolume - 1000) / 1000
        XCTAssertLessThan(relError, 0.05, "voxel volume \(grid.solidVolume) vs analytic 1000")
    }

    func testSphereVolumeWithinFivePercent() throws {
        let mesh = try Tessellation.sphere(radius: 10, segments: 96, rings: 64)
        let grid = try VoxelGrid(mesh: mesh, cellSize: 0.5)
        let analytic = 4.0 / 3.0 * Double.pi * 1000
        let relError = abs(grid.solidVolume - analytic) / analytic
        XCTAssertLessThan(relError, 0.05,
                          "voxel volume \(grid.solidVolume) vs analytic \(analytic)")
    }

    func testResolutionConvenience() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let grid = try VoxelGrid(mesh: mesh, resolution: 20)
        XCTAssertEqual(grid.cellSize, 0.5, accuracy: 1e-12)
        XCTAssertEqual(grid.nx, 20)
        XCTAssertEqual(grid.solidCellCount, 8000)
    }

    func testNestedBoxesGiveEnclosedVoid() throws {
        // Outer box 20³ with an 8³ box inside it as a separate shell:
        // the region between shells is solid, the inner box's interior
        // is an enclosed void (not .outside), and the grid boundary
        // around the mesh is .outside.
        var combined = try Tessellation.box(width: 20, depth: 20, height: 20)
        let inner = try Tessellation.box(width: 8, depth: 8, height: 8)
            .translated(by: Vec3(0, 0, 6))
        combined.append(inner)
        let grid = try VoxelGrid(mesh: combined, cellSize: 1)

        let center = grid.gridIndex(containing: Vec3(0, 0, 10))!
        XCTAssertEqual(grid.kind(x: center.x, y: center.y, z: center.z), .void,
                       "sealed inner cavity must classify as enclosed void")

        let shell = grid.gridIndex(containing: Vec3(-7, 0, 10))!
        XCTAssertEqual(grid.kind(x: shell.x, y: shell.y, z: shell.z), .solid,
                       "material between the shells must be solid")
        XCTAssertTrue(grid.isSolid(x: shell.x, y: shell.y, z: shell.z))

        // Corner of a sphere grid: in-bounds but far from the part.
        let sphere = try Tessellation.sphere(radius: 10, segments: 48, rings: 32)
        let sGrid = try VoxelGrid(mesh: sphere, cellSize: 1)
        XCTAssertEqual(sGrid.kind(x: 0, y: 0, z: 0), .outside)
        // Out-of-bounds reads as outside too.
        XCTAssertEqual(grid.kind(x: -1, y: 0, z: 0), .outside)
        XCTAssertFalse(grid.isSolid(x: 999, y: 0, z: 0))
    }

    func testSurfaceCellsAndCenters() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        let grid = try VoxelGrid(mesh: mesh, cellSize: 1)
        // All cells except the inner 8³ core touch non-solid space.
        XCTAssertEqual(grid.surfaceCells().count, 1000 - 512)
        XCTAssertTrue(grid.isSurfaceCell(x: 0, y: 0, z: 0))
        XCTAssertFalse(grid.isSurfaceCell(x: 5, y: 5, z: 5))
        XCTAssertFalse(grid.isSurfaceCell(x: 50, y: 5, z: 5))
        // Center of cell (0,0,0) is half a cell in from the origin.
        XCTAssertEqual(grid.cellCenter(x: 0, y: 0, z: 0), Vec3(-4.5, -4.5, 0.5))
        // World→grid round trip.
        let idx = grid.gridIndex(containing: Vec3(0, 0, 5))!
        XCTAssertEqual(idx.x, 5); XCTAssertEqual(idx.y, 5); XCTAssertEqual(idx.z, 5)
        XCTAssertNil(grid.gridIndex(containing: Vec3(100, 0, 0)))
        // 6-neighborhood shrinks at the boundary.
        XCTAssertEqual(grid.neighbors(x: 0, y: 0, z: 0).count, 3)
        XCTAssertEqual(grid.neighbors(x: 5, y: 5, z: 5).count, 6)
    }

    func testBudgetGuardThrows() throws {
        let mesh = try Tessellation.box(width: 10, depth: 10, height: 10)
        XCTAssertThrowsError(try VoxelGrid(mesh: mesh, cellSize: 0.1, maxCells: 1000)) { error in
            guard let simError = error as? SimError else {
                return XCTFail("expected SimError, got \(error)")
            }
            XCTAssertEqual(simError.code, "MSIM-GR001")
        }
    }

    func testEmptyMeshAndBadCellSizeThrow() {
        XCTAssertThrowsError(try VoxelGrid(mesh: Mesh(), cellSize: 1)) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-IN001")
        }
        XCTAssertThrowsError(try VoxelGrid(mesh: Mesh(), cellSize: 0)) { _ in }
        let mesh = Mesh(vertices: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
                        indices: [0, 1, 2])
        XCTAssertThrowsError(try VoxelGrid(mesh: mesh, cellSize: -1)) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-CF001")
        }
        XCTAssertThrowsError(try VoxelGrid(mesh: mesh, cellSize: .nan)) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-CF002")
        }
        XCTAssertThrowsError(try VoxelGrid(mesh: mesh, resolution: 0)) { error in
            XCTAssertEqual((error as? SimError)?.code, "MSIM-CF001")
        }
    }
}
