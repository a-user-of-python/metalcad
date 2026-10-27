# MetalCADSim — design

A simulation library for MetalCAD, built as a SwiftPM package
(`MetalCADSim`) beside `MetalCADKit` in this repo.

## Compatibility contract (hard requirement)

- MetalCADSim **depends on MetalCADKit** (path dependency `../MetalCADKit`)
  and consumes its types directly: `Mesh`, `Vec3`, `Plane3`, `Tessellation`,
  `FaceExtractor` / `PlanarFace`, and the kit's material list.
- **No duplicated geometry types.** Anything a sim produces that is geometry
  (eroded shape, displaced shape) comes back as a kit `Mesh`, ready for the
  app's existing renderer, exporter, and document model.
- Face-based inputs (loads, fixtures, inlets, fixed temperatures) are the
  kit's `PlanarFace` values, so the app can pass the user's actual tapped-face
  selection straight in.
- Sim material properties (Young's modulus, Poisson, yield, conductivity,
  specific heat, erodibility) live in `SimMaterial`, keyed by the kit's
  material names so a part's chosen material carries over automatically.
- MetalCADKit is **not modified**. If a kit gap appears, the sim works
  around it locally and notes it here.

## Shared foundation

- **VoxelGrid** — the mesh voxelized once per study (scanline parity fill
  via BVH column rays). Configurable cell size / resolution, cell budget
  guard. Solid / void / outside classification, face-adjacency, surface-cell
  extraction. Every volumetric sim shares it.
- **BVH ray caster** — Möller–Trumbore over an AABB BVH built from the kit
  mesh; closest-hit and all-hits queries. Used by aerodynamics, erosion,
  and voxelization.
- **Matrix-free PCG solver** — preconditioned conjugate gradients over an
  operator closure (no global matrix assembly), Jacobi preconditioning;
  scalar and block-3 (vector) variants. Used by stress and thermal.
- **SimError** — distinct stable codes per failure, same discipline as the
  kit's `CADError`.
- **Determinism** — sorted iteration everywhere; identical inputs produce
  identical outputs.

## The simulations

1. **Aerodynamics** — the requested ray model: a configurable lattice of
   rays cast at the part from a configurable wind direction/speed. Newtonian
   impact theory per hit (pressure coefficient from incidence) gives drag
   coefficient, drag force, side forces, and center of pressure; per-ray
   data for a heat-map overlay; angle sweep (Cd vs yaw/pitch). *Honest
   limit: attached-flow impact model — bluff-body separation and viscous
   effects are approximated, so Cd is an estimate, not wind-tunnel data.*
2. **Structural (stress)** — linear-static voxel FEA: each solid voxel an
   8-node hexahedral element, matrix-free element-by-element PCG. Apply a
   force (N, direction) distributed over a `PlanarFace`; **fix** any faces
   so they cannot move; optional self-weight. Outputs: von Mises stress
   field, displacement field (with exaggeration factor), peak stress,
   safety factor against the material's yield.
3. **Thermal** — voxel heat conduction: steady state (PCG on the grid
   stencil) and transient (explicit stepping, stability-limited dt).
   Boundary conditions per face: fixed temperature, heat flux, convection
   (h + ambient); volumetric heat generation. Outputs: temperature field,
   extrema, total boundary heat flow.
4. **Water flow (through the part)** — void-space analysis on the voxel
   grid: choose inlet/outlet faces, flow rate/pressure, gravity direction.
   Simulates fill propagation through internal cavities; reports reachable
   vs **trapped** pockets (air locks / sealed voids), pooling under gravity,
   residual water after draining, and the bottleneck cross-section on the
   through-path.
5. **Water erosion** — streamlines cast through/around the part (same ray
   machinery, water density/speed); surface cells accumulate shear from
   incidence and local speed; erosion depth grows with simulated time and
   material erodibility; surface voxels peel iteratively, re-exposing
   fresh material. Outputs: the eroded shape as a kit `Mesh`, mass loss,
   max/average depth, per-cell depth map. *Visualization-grade model —
   shows where and how fast, not a lab prediction.*
6. **Buoyancy / hydrostatics** — waterline plane + fluid density: submerged
   volume, displaced mass, center of buoyancy vs the part's center of mass,
   float/sink verdict, small-angle righting tendency around a chosen axis.

## Configuration philosophy

Every sim is driven by a `Config` struct with **all** knobs exposed —
grid resolution, directions, speeds, densities, gravity, durations, time
steps, solver tolerances and iteration caps, exaggeration — sane defaults,
validated up front (`SimError` on nonsense), nothing hard-coded that a user
could reasonably want to change.

## Testing bar (before this is called done)

Known-answer tests against analytics, per sim: voxelized box/sphere volume;
cantilever beam tip deflection + root stress vs Euler–Bernoulli; tension
bar σ = F/A; 1D slab temperature profile; box drag ordering vs a flat plate;
trapped-pocket fixture shapes (sealed cavity, U-trap, open channel);
erosion monotonicity (more time ⇒ ≥ depth; no flow ⇒ zero); buoyancy of a
half-submerged cube. Plus edge cases: empty mesh, zero force, unfixable
load paths, budget guards. Full suite green or it doesn't ship.

## Non-goals (v1)

No app UI (integration is the follow-up step), no Navier–Stokes CFD, no
nonlinear/plastic FEA, no turbulence modelling. Models are chosen to be
fast, deterministic, explainable, and honest about their limits.
