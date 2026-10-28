<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="150" alt="MetalCAD icon">
</p>

<h1 align="center">MetalCAD</h1>

<p align="center">
  <b>A real parametric CAD app for iPad</b> — sketch with constraints, build features, tap faces and edges to modify them, and export for printing. Designed from the ground up for touch, large type, and high contrast.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/iPadOS-17%2B-blue" alt="iPadOS 17+">
  <img src="https://img.shields.io/badge/platform-iPad-lightgrey" alt="iPad">
  <img src="https://img.shields.io/badge/version-1.15-green" alt="Version 1.15">
</p>

---

## What it does

### Sketch
- Full 2D sketcher: lines, circles, arcs, points — with a real **constraint solver** (16 constraint types, degrees-of-freedom counting, drag editing with snapping)
- Sketches live on base planes, **datum planes**, or **any flat face of the model**
- Measure tool, dimension readouts, and constraint-driven parametric edits

### Model
- **Extrude** (join / cut / intersect / new body, taper, symmetric, two-sided, through-all, up-to-face), **Revolve**, **Loft**, **Sweep**, **Coil**, **Pipe**, **Rib**
- **Hole** wizard — simple, counterbore, countersink; holes sketched as circles drill at the circle's own size
- **Modeled threads** — thread a shaft you tap on the model, or a standalone threaded rod (metric / UNC / NPT presets, all parameters editable)
- **Fillet & chamfer** on whole features or on individual picked edges, with automatic max-feasible sizing
- Shell, draft, mirror, linear & circular patterns, split / move / scale body, primitives
- Real CSG booleans on a deterministic BSP kernel — watertight STL export
- **Cascade Pad** (new in 1.15) — a sketch pad built by the Open CASCADE engine instead of the mesh kernel: exact B-rep geometry, the engine's own volume in the feature list. First feature on the implanted engine; more follow (see below)

### Work the Fusion way
- **Tap the model**: pick a face, edge, shaft, or hole wall and get the actions that make sense for it — pull/press a face with a live slider, sketch on it, thread a shaft, fillet its edges
- **Live previews**: every panel drafts its result in real time as you scrub — the preview *is* the part, tinted, until you commit
- Selection-driven tools prefill from the **actual measured geometry** of what you tapped — never a preset guess
- Drag-resizable browser panel, rename anything, sketch & feature history with suppression and per-feature status

### Engineering
- 12 materials with density → live **volume, mass, and size** readouts
- Section views, quick two-point measure with persistent readout
- Save as native `.metaldoc`, export **STL** (binary, print-ready) or **OBJ**
- Accent color themes the whole app — buttons, highlights, sketch glow, measure markers

### Trust
- Every failure carries a **distinct, stable error code** (`MCAD-FT408`, `MCAD-SV302`, …) — see [ERRORS.md](ERRORS.md)
- **Structured logging** throughout, with an in-app Diagnostics screen — see [LOGGING.md](LOGGING.md)
- Full design document: [DESIGN.md](DESIGN.md)

## Install

MetalCAD ships as an unsigned IPA (GitHub Actions artifact, and attached to Releases):

1. Download `MetalCAD-unsigned.ipa` from the latest Release
2. Sign and install with **Signulous** (or your preferred sideloading service)
3. Requires an iPad running iPadOS 17 or later

## Building

- `MetalCADKit/` — the platform-pure Swift kernel (geometry, CSG, solver, features, IO). Fully unit-tested: `cd MetalCADKit && swift test`
- `App/` — the SwiftUI + SceneKit app. The Xcode project is generated: `cd App && python3 gen_project.py`
- CI (GitHub Actions, `macos-26`) runs the kit tests and packages the unsigned IPA on every push

## Cascade engine (implanted in 1.15)

MetalCAD now links **Open CASCADE Technology 8.0.1** as a static library (`CascadeKit`) and calls it from Swift through a thin C façade — Swift drives, Cascade computes. The engine's sources are *not* in this repo: their single source of truth is the [cascade-ios](https://github.com/a-user-of-python/cascade-ios) repo, and CI clones it at a pinned commit (see `.github/workflows/build-ipa.yml`) into `cascade-engine/` before generating the project. To build locally, clone that repo to `cascade-engine/` first.

OCCT is licensed under **LGPL 2.1 with the Open CASCADE exception** (© Open Cascade SAS); the licence texts ship inside the app bundle, and OCCT sources are used unmodified. Façade failures surface in MetalCAD's own error system (the `MCAD-KN6xx` kernel codes).

## Version 1.15

- **Cascade implant**: Open CASCADE 8.0.1 linked into the app as its second geometry engine, behind the kit's evaluator hook (errors MCAD-KN601–KN605)
- New feature: **Cascade Pad** (Create ▸ Cascade Pad) — sketch profiles extruded by OCCT into exact solids; the new-document demo gains a "Cascade Boss" so it can be seen immediately
- Installs over 1.14 and keeps existing documents; documents using Cascade Pad reopen and rebuild through the engine

## Version 1.10

- Fixed: header buttons crushed by layout — chips now size to their labels and never wrap
- Fixed: browser-panel drag stutter (the width is now committed once per drag, not saved per pixel)
- New: app icon
- Carries forward the v4.8/4.9 work: preview-replaces-model live drafting, sticky per-document camera, blank documents, rename, Save As (.metaldoc / STL / OBJ), accent color in Home ▸ Settings, and the editor-open crash fix

---

<sub>Built with Muse.</sub>
