# MetalCADSim

A simulation library for **MetalCAD**: six studies — aerodynamics,
structural stress, heat conduction, internal water flow, water
erosion, and buoyancy — that run directly on the CAD app's own
parts. Pure Swift, no dependencies beyond Foundation and
MetalCADKit. See `DESIGN.md` for the full design rationale and the
honesty limits of every model.

## Compatibility contract

MetalCADSim is a **client** of MetalCADKit, never a fork of it:

- It depends on MetalCADKit by path (`../MetalCADKit`) and consumes
  its types directly: studies take a kit `Mesh`, face-based inputs
  are the kit's `PlanarFace` (the exact values `FaceExtractor`
  produces when the user taps a face), and the part's material is a
  kit `Material` from `MaterialLibrary`.
- Sim-only engineering properties (Young's modulus, yield,
  conductivity, erosion resistance, …) live in `SimMaterial`, keyed
  by kit material name and resolvable in one call:
  `SimMaterial.forKitMaterial(material)`. Densities are checked
  against the kit's.
- Anything a study produces that is geometry — a deformed shape, an
  eroded shape — comes back as a kit `Mesh`, ready for the app's
  renderer, exporter, and document model with zero conversion.
- **MetalCADKit is not modified.** Shared infrastructure lives here:
  `VoxelGrid` (scanline-parity voxelization with solid / enclosed
  void / outside classification), `RayCaster` (BVH ray casting over
  a kit mesh), `MeshExtraction` (voxel grid → kit `Mesh` surface),
  and a matrix-free PCG solver.
- Units are the kit's millimetres throughout; SI conversions
  (m³, kg, MPa, watts) happen at documented points on the results.

Everything is deterministic: fixed iteration order everywhere, so
identical inputs give bit-identical headline results (pinned by a
test).

## The simulations

### Aerodynamics — `Aerodynamics.analyze` / `.sweep`

Casts a configurable lattice of rays at the part from the wind
direction and applies Newtonian impact theory per first hit
(Cp = 2·cos²θ), yielding drag force, drag coefficient, side force,
center of pressure, and per-hit samples for a heat map; `sweep`
repeats over yaw/pitch angles. **Knobs:** wind direction/speed, air
density, ray spacing or counts, reference area/point,
`includeLeeSide` (free-molecular-style lee contributions),
ray budget. **Limits:** an inviscid impact model — no boundary
layer, separation, or stall; treat Cd as comparative, not
wind-tunnel truth.

### Structural — `Structural.solve`

Linear-static voxel FEA: one trilinear hexahedral element per solid
voxel, assembled matrix-free and solved with block PCG. Loads are
forces distributed over a tapped face's grid nodes; any faces can
be **fixed** so they cannot move; optional self-weight. Reports
per-cell von Mises stress, peak stress and its location, nodal
displacements, reaction total, and the safety factor against the
material's yield. **Knobs:** cell size/budget, loads, fixed faces,
gravity, solver tolerance/iterations, displacement exaggeration
for the deformed mesh. **Limits:** linear elasticity and small
displacements only; geometry is staircase at cell resolution, so
peak stresses at sharp features are resolution-limited.

### Thermal — `ThermalSimulation.run`

Voxel heat conduction (6-neighbor finite volume). Boundary
conditions bind to faces: fixed temperature, heat flux, or
convection; an optional global ambient convection covers every
exposed face a BC didn't claim. Steady state solves with PCG;
transient runs explicit steps with automatic stability substepping.
Reports the per-cell temperature field, extrema, mean, and boundary
heat-flow balance. **Knobs:** material, cell size, face BCs,
ambient, mode, initial temperature, duration/time step, solver
tolerance. **Limits:** conduction inside the part only (no
radiation model), isotropic conductivity, face-uniform BCs.

### Water flow — `WaterFlow.run`

Follows water **through** the part's void space (the non-solid
voxel cells): a priority-flood (minimax-sill) fill from the inlet
faces under a configurable pressure head, against a configurable
gravity. Reports how much of the void fills, whether an outlet is
reached, trapped pockets (sealed voids and air locks, with
volumes), what stays behind after draining, and the bottleneck
cross-section on the through-path. **Knobs:** inlet/outlet faces,
pressure head, gravity direction, cell size. **Limits:**
quasi-static — no flow dynamics, splashing, or momentum; air is
only "trapped or not", never compressed.

### Water erosion — `WaterErosion.run`

Peels the part's surface under flowing water, step by step. A
surface cell erodes when it has upstream line-of-sight to the flow;
its rate scales with v², an incidence factor (head-on fastest, with
a configurable glancing floor), the dynamic-pressure option, and
the material's erosion resistance. Accumulated depth reaching one
cell removes the cell and exposes the next layer. Returns the
eroded shape as a kit `Mesh`, the final solid mask, mass loss
(absolute and %), a per-cell depth map, and a time series.
**Knobs:** flow direction/speed, water density, erosion
coefficient, duration, step count, cell size, internal surfaces
on/off, glancing factor. **Limits:** visualization/calibration
grade — the *pattern* and material ranking are the product;
absolute rates hinge on the calibration coefficient. No sediment
transport or re-deposition; staircase surface normals.

### Buoyancy — `Buoyancy.analyze`

Mesh-exact hydrostatics: the part's volume below a configurable
waterplane is integrated by clipping, giving submerged volume and
fraction, displaced mass, float/sink verdict, center of buoyancy,
metacentric height (GM), and a righting-arm (GZ) sweep over
configurable tilt angles. **Knobs:** waterline point/normal, fluid
density (fresh/seawater presets), material, tilt axis and angles.
**Limits:** statics only — no waves, sloshing, or dynamic
stability; the part is treated as a uniform-density sealed solid.

## Errors

Every failure is a `SimError` with a **stable code**: `MSIM-` plus a
domain — `CF` configuration, `GR` grid, `SV` solve, `IN` input —
and a number. Codes are never reused or renumbered (same discipline
as the kit's `CADError`); `SimErrorCatalog.allCodes` lists them all
and the tests prove the mapping is exact and distinct.

| Code | Case | Means |
|---|---|---|
| MSIM-CF001 | `invalidValue` | a config value is outside its valid range |
| MSIM-CF002 | `nonFiniteValue` | a config value is NaN or infinite |
| MSIM-GR001 | `cellBudgetExceeded` | the grid would exceed the cell budget |
| MSIM-GR002 | `degenerateBounds` | the mesh has no extent to grid over |
| MSIM-SV001 | `didNotConverge` | PCG exhausted its iterations above tolerance |
| MSIM-SV002 | `operatorBreakdown` | the operator is not SPD on the Krylov subspace |
| MSIM-SV003 | `invalidSolverInput` | solver arguments are inconsistent |
| MSIM-IN001 | `emptyMesh` | the mesh has no triangles |
| MSIM-IN002 | `unknownMaterial` | no sim data for this kit material name |
| MSIM-IN003 | `zeroDirection` | a required direction vector is zero |
| MSIM-IN004 | `faceMatchedNoCells` | the selected face doesn't touch this part |

## Building & testing

```sh
swift build                 # debug
swift build -c release      # release
swift test                  # full suite
```

**80 tests, all passing** (≈ 40 s of test execution on a desktop
host; the structural solves dominate). The suite pins each model
against known answers — cantilever-beam deflection vs
Euler–Bernoulli, 1-D slab temperature profile, half-submerged cube
buoyancy, Newtonian plate drag, trapped-pocket fixture shapes —
plus a cross-sim integration test (one holed block, one material,
all six studies) and a determinism test (two runs, bit-exact
headline numbers).
