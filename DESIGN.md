# MetalCAD — Design Document

Working title. A native, touch-first parametric CAD system for Apple-silicon
iPads, built as a reusable library plus an app — the same pattern as
MetalTerrain (library) and NativeMetalTerrain (app).

Status: DESIGN ONLY (2026-10-25). No code yet. Build starts on the owner's word.

---

## 1. What it is

- A parametric, feature-based solid modeler: you draw 2D sketches in a 3D
  world, turn them into exact solids (extrude, revolve, sweep, loft), edit
  them (bevel/fillet, chamfer, booleans), move things around freely, and cut
  real, highly customizable threads.
- Native on iPad: Swift + Metal UI and rendering, C++ geometry kernel.
  No Mac port, no web view, no server. Everything runs on-device.
- Designed for touch first and for bad vision: large type, high contrast,
  big touch targets are hard requirements, not a theme.

## 2. Why a custom build (and not a FreeCAD port)

FreeCAD's desktop GUI (Qt Widgets + Coin3D desktop-OpenGL viewer) cannot be
transplanted to iPadOS in any usable form. But its geometry kernel —
OpenCascade (OCCT) — officially supports iOS. So: same kernel, new native
library and touch interface around it.

## 3. Architecture

```
┌─────────────────────────────────────────────────────┐
│ App (SwiftUI + Metal)                                │
│  touch tools · sketch editor UI · feature tree UI    │
│  file pickers · settings · accessibility             │
├─────────────────────────────────────────────────────┤
│ MetalCAD library (Swift)                             │
│  Document · FeatureTree · Sketch model · Selection   │
│  Tessellation → Metal render scene · Export          │
├─────────────────────────────────────────────────────┤
│ Bridge (C++ / Objective-C++)                         │
│  thin, value-typed API over the kernel               │
├─────────────────────────────────────────────────────┤
│ OCCT kernel (C++, LGPL 2.1 with exception)           │
│  BRep modeling · fillets · booleans · STEP · threads │
└─────────────────────────────────────────────────────┘
```

- **Kernel: OpenCascade (OCCT).** Exact boundary-representation (B-rep)
  solids — true cylinders, true fillets, real measurements, STEP exchange.
  Officially builds for iOS (`ios_build.sh`, arm64). Statically linked.
- **Library owns the geometry and rendering** (like MetalTerrain owns all
  Metal): sketch model, feature evaluation, tessellation, render scene.
  The app never touches OCCT types directly.
- **App owns only UI and input** (dual-repo pattern, standing rule):
  library-level changes go to BOTH the library repo and the app repo
  (app vendors the library `Sources/`); app-only changes stay in the app.
- **Units:** millimeters everywhere internally; document can display
  mm / cm / inches (fractions optional in a later phase).
- **Coordinates:** right-handed, Z-up world. Base planes XY, XZ, YZ plus
  user workplanes and planar faces of solids. Sketches live on a plane;
  their local 2D coordinates map into the 3D world.
- **Documents:** a document is a feature tree. Every feature stores its
  parameters; the solid is rebuilt by replaying the tree. Editing any
  parameter or sketch rebuilds everything after it. Native file format:
  a folder/zip with `document.json` (tree + sketches + parameters) and
  `shapes.brep` (cached kernel shapes). The JSON alone can rebuild the
  model from scratch.

## 4. Object and feature model

- Every solid, sketch, and feature has a **name** (param3d-style) and is
  addressable: `bracket`, `bracket.hole`, `flange.thread`.
- Feature types (v1 → later): Sketch, Pad (extrude), Pocket (extrude-cut),
  Revolve, Groove (revolve-cut), Primitive (box/cylinder/sphere/cone/torus),
  Fillet, Chamfer, Boolean (union/cut/intersect), Transform (move/rotate/
  mirror/pattern), Shell, Thread (see §8).
- Features can be **suppressed** (skipped in rebuild), **reordered** where
  legal, and **rolled back** (rebuild stops at an earlier feature) so you
  can edit mid-history.
- A failed rebuild (e.g. a fillet the kernel refuses) marks that feature
  with the failure reason in plain words and keeps the last good solid —
  the app never loses the model to a failed operation.

---

## 5. THE SKETCH SYSTEM (full)

The sketcher is a first-class system, not a drawing toy: entities,
constraints, dimensions, and a real solver, with the common shapes and the
common tools CAD users expect.

### 5.1 Sketch placement

- New sketch on: a base plane (XY/XZ/YZ), any planar face of an existing
  solid, or a user-defined workplane (offset/angled from another plane).
- Sketch has its own local X/Y axes, origin, and orientation handle;
  it can be repositioned (attach to a different face/plane) later.
- Entering a sketch switches the camera to a straight-on 2D view of the
  sketch plane (with a one-tap "tilt" to peek at the 3D world), dims the
  rest of the model, and shows projected reference geometry.

### 5.2 Entities (things you can draw)

| Entity | Creation styles |
|---|---|
| Point | tap; also center points for circles/arcs |
| Line | two taps; chained polyline mode with per-segment constraints |
| Arc | center + start + end; three points; tangent arc continuing a line |
| Circle | center + radius point; three points |
| Ellipse | center + two axis points; focus style later |
| Elliptical arc | ellipse + start/end angles |
| Rectangle | two corners; center + corner; three points (rotated); center + size by numbers |
| Regular polygon | center + vertex, 3–64 sides, inscribed or circumscribed |
| Slot | two centers + radius (stadium/obround); arc slot later |
| Spline | B-spline through tapped points; control-point spline with draggable poles and weights |
| Polyline | connected segments (lines and tangent arcs in one chain) |
| Construction geometry | any entity toggled to construction (centerlines, reference circles) — shown dashed, used by constraints and revolutions, ignored by profiles |
| Text | (later phase) text as sketch profile for engraving/embossing |

### 5.3 Common shapes (one-tap quick create)

Rectangle, rounded rectangle, circle, regular polygon, slot, triangle,
and a **star/flange convenience set**: bolt-circle (N holes on a circle),
grid of holes, and a "plate with rounded corners + 4 holes" starter.
Quick shapes drop in as fully editable normal entities with constraints,
never as dead blobs.

### 5.4 Drawing and editing tools (the common CAD set)

- **Select** (tap, drag-box, lasso — box direction matters like real CAD:
  left-to-right = fully inside, right-to-left = touching).
- **Move / drag** entities and points directly; arrow-key style nudge
  buttons; numeric move (dx, dy).
- **Rotate** (around a chosen center, by angle or drag), **Scale**
  (uniform, about a base point), **Mirror** (about any line/axis).
- **Copy / Paste / Duplicate** within a sketch and between sketches,
  with offset placement.
- **Offset** — closed profiles and open chains, one or both sides,
  with corner style (sharp/round) and gap fill.
- **Trim** (tap segment to cut back to nearest intersections; power-trim
  by dragging across segments), **Extend** (to nearest entity or to a
  chosen boundary), **Split** (break an entity at a point), **Join /
  Heal** (merge coincident endpoints, close tiny gaps).
- **2D Fillet and Chamfer** on sketch corners (radius/distance by drag
  or by number).
- **Pattern in sketch:** linear (rows/columns, spacing, count) and
  circular (center, count, total angle) — pattern members stay linked to
  the source until "explode pattern" is chosen.
- **Project geometry:** project edges/faces of solids and other sketches
  into this sketch as reference (construction) geometry — the standard
  way real CAD keeps sketches attached to the model.
- **Convert:** entity ↔ construction; spline → arcs approximation preview
  for export-bound profiles.
- **Delete, Undo, Redo** at every level (per-gesture undo steps).

### 5.5 Constraints (the full common set)

Geometric constraints:
- Coincident (point-on-point, point-on-curve), Concentric, Tangent
  (line–arc, arc–arc, spline-tangent), Parallel, Perpendicular,
  Horizontal, Vertical, Equal (length/radius), Symmetric (about a line),
  Midpoint, On-curve, Collinear, Smooth (G1/G2 at spline joints),
  Fix/Lock (fully pinned entity), Point-on-axis / symmetry to axes.

Dimensional constraints (driving dimensions — edit the number, the
sketch re-solves):
- Distance (point–point, point–line, line–line), horizontal/vertical
  distance, Length, Angle (between lines, three-point), Radius,
  Diameter, Arc length (later), Equal via dimension, Reference
  (driven) dimensions that measure without driving.

### 5.6 The solver

- A real constraint solver in the library (Levenberg–Marquardt /
  dogleg over the constraint equations, the same family FreeCAD's
  planegcs uses — written fresh for this library).
- **Degrees-of-freedom tracking:** every sketch reports how many DOF
  remain. Entities are color-coded at all times:
  under-constrained (amber), fully constrained (green), conflicting or
  redundant constraints (red, named in plain words).
- Solver runs live while dragging: constrained geometry follows the
  finger without breaking relationships; on release it settles exactly.
- Adding a constraint that would conflict is refused with the reason
  ("these two lines are already parallel through the equal-length
  chain") — never a silent failure or a corrupted sketch.
- Auto-constrain while drawing: inferred horizontal/vertical, endpoint
  coincidence, tangency, and symmetry are offered as you draw (shown as
  glyphs) and kept only if still valid when you finish the stroke.
- Sketch health check on exit: open profiles, self-intersections,
  duplicate entities, zero-length segments — listed with a tap-to-zoom
  on each problem, and "fix" buttons for the mechanical ones
  (close gap, delete duplicate).

### 5.7 Snapping and precision input

- Snaps: grid (adjustable spacing), endpoints, midpoints, centers,
  quadrants, intersections, tangent points, perpendicular foot,
  on-curve, angle increments (15° default, adjustable), and
  "snap to dimension" (round to 0.1 / 0.5 / 1 mm while dragging).
- Every drag shows a live dimension readout next to the finger (never
  under it — readout is offset above the touch point).
- Any value can be typed instead: tap the readout (or the big number
  button) for a large numeric keypad with mm/inch toggle.
- Apple Pencil: precise point placement, hover preview where supported;
  finger drawing uses an offset cursor so you can see the point you're
  placing.

### 5.8 Profiles and validation

- Closed loops are detected continuously and shaded the moment they
  close; multiple disjoint profiles in one sketch are fine.
- Nested profiles = holes (islands) automatically, following the
  even–odd rule, shown with hatch shading.
- A sketch used by Pad/Revolve reports exactly which profiles it will
  consume before you confirm the operation.

### 5.9 Sketch → 3D

- Pad (extrude): length, symmetric, two-lengths, up-to-face, draft angle.
- Pocket: same, cutting.
- Revolve / Groove: any sketch axis or construction line, angle or full.
- A sketch may feed several features; editing it updates all of them.

---

## 6. 3D operations

- Primitives: box, cylinder, cone, sphere, torus — created by numbers or
  by dragging on a plane, then refined in the parameter panel.
- Sweep along a path (sketch path or edge chain), Loft between two or
  more sketch profiles (with ruled/smooth option).
- Booleans: union, cut, intersect — multi-select, keep-tool option.
- Fillet: tap edges (or "all edges of this face"), radius by drag wheel
  or number; variable radius later. Chamfer: equal distance, two
  distances, or distance+angle.
- Shell (hollow out, wall thickness, open faces), Draft (taper faces
  about a neutral plane) for mold-friendly parts.
- Patterns: linear, circular, mirror — of features or whole bodies,
  count/spacing by numbers, members stay parametric.
- Move things around: free drag on a plane, 3-axis move gizmo (large,
  finger-sized), rotate about any axis, align-to-face, and exact
  numeric transform — all recorded as parametric Transform features,
  so a move is editable, not destructive.

## 7. Selection and the 3D world

- Orbit (one finger), pan (two fingers), pinch zoom, with a "return to
  sketch view" button while sketching; orbit can lock to an axis.
- Tap selects faces/edges/vertices with a cycle-through menu when things
  overlap (big list, large rows — never a pixel-hunt).
- Section view (clip plane by drag), wireframe / shaded / shaded+edges,
  X-ray (translucent others) for picking internals.
- Measurement: distance, angle, radius, face area, volume, bounding box —
  big readout, copyable.

## 8. Threads — high customization (first-class feature)

- **Modeled (real) threads**, not textures: the thread profile is swept
  along a true helix on the shaft and fused/cut with the kernel — the
  part 3D-prints and fits.
- Presets: ISO metric coarse/fine (M3–M64), UNC/UNF, BSP, and tapered
  pipe (NPT-style) — presets are just starting points; every parameter
  stays editable:
  - nominal diameter, pitch (or TPI), thread length, major/minor
    diameters, profile angle (60°, 55°, custom), crest/root flat,
  - right-hand or left-hand, single or multi-start (1–4),
  - internal (nut/hole) or external (bolt/shaft),
  - taper angle for pipe threads, runout/chamfer at both ends
    (lead-in cone), thread relief groove option,
  - fit/clearance slider (loose → tight, for print tolerance) that
    offsets the profile by a chosen clearance.
- **Cosmetic thread mode** for big assemblies: stores the thread spec
  as parameters (shown in drawings/labels) without heavy geometry —
  one tap converts cosmetic ⇄ modeled.
- Honest limits, stated in-app: modeled threads are heavy geometry
  (a long M20 thread can be hundreds of thousands of triangles when
  tessellated) — generation runs in the background with progress, and
  the document keeps the parameters so the thread rebuilds on demand
  instead of storing dead weight.

## 9. Files and export

- Import: STEP (.step/.stp), IGES, BREP, STL — via the Files app.
- Export: **STEP** (exact solids, the CAD interchange format), **STL**
  (binary, watertight check before export, units noted), native
  MetalCAD document. Share sheet + Files app visibility like ChunkSend.
- Autosave with version history (keep last N document snapshots).

## 10. Rendering and performance targets

- Metal renderer in the library; OCCT tessellates solids with an
  adjustable deflection (quality slider: draft / standard / fine).
- Target: smooth orbit on iPad Air M3 with models of ~1M triangles;
  tessellation and rebuilds run off the main thread with cached results
  per feature (only changed features rebuild).
- Large-print-friendly defaults: the app UI never goes below 17 pt,
  tool buttons ≥ 56 pt, contrast-checked palette (dark UI, bright
  geometry colors colorblind-safe for selection/constraint states).

## 11. Phases (build order when green-lit)

- **Phase 0 — kernel spike:** OCCT built for iOS in CI, one Swift view
  rendering a kernel solid with touch orbit. Proves the foundation.
- **Phase 1 — library core:** document/feature tree, sketch entities
  (no solver yet — snap + dimensions), Pad/Revolve, booleans, fillet/
  chamfer, STL/STEP export. End-to-end: sketch → solid → printed part.
- **Phase 2 — full sketcher:** constraint system + solver (§5.5–5.6),
  trim/offset/patterns, project geometry, DOF coloring, health check.
- **Phase 3 — threads** (§8) + patterns, shell, draft, sweep, loft.
- **Phase 4 — app polish:** feature tree UI, section views, measurement
  suite, version history, Pencil refinement.

## 12. Risks and open questions

- OCCT iOS build is officially supported but heavy: CI build time and
  app size (~tens of MB of kernel) need the Phase 0 spike to confirm.
- The constraint solver is the single hardest component (Phase 2) —
  scoped and isolated in the library so the rest ships first.
- Fillets on complex edge sets can fail in any kernel; the design rule
  (§4) is: never corrupt the model, always explain the failure.
- Licensing: OCCT is LGPL 2.1 with an exception; personal sideloading
  is uncomplicated. Any future public distribution needs a license pass
  (static-linking obligations) before it happens — flagged, not hidden.
- Name, icon, and repo layout are the owner's call when the build starts.

## 13. Success test for the whole design

Model a real part end-to-end on the iPad with fingers only: a mounting
plate — sketch the outline with constraints, pad it, drill a bolt
circle, fillet the corners, add a threaded boss (M10 × 1.5, modeled),
export STEP and STL, and print the STL. If that flow feels good, the
design did its job.

---

## Errors & logging (first-class, added at build commission)

Every failure carries a **distinct, stable error code** (`MCAD-SK204`,
`MCAD-SV302`, …) — full taxonomy in **ERRORS.md** (12 domains, ~70 codes,
each with severity and recovery behavior; codes are never reused). Codes show
in the alert (small, under the plain-words message), always reach the log,
and identify the exact failure in a support bundle.

Logging is designed in **LOGGING.md**: structured entries (level, category,
code, context), ring buffer + rotating JSONL file sink, automatic coverage of
rebuilds / solver / kernel / IO, a Diagnostics screen (view log, copy last
error code, export bundle), and strict privacy rules (no document content,
no personal paths). `MCLog` lives in MetalCADKit, platform-pure, unit-tested.
