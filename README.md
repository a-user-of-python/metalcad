# MetalCAD

A touch-first CAD app for iPad — custom Swift library (**MetalCADKit**) + SwiftUI app.

- **Sketcher** with a real constraint solver (16 constraint types, live DOF counting)
- **Features:** pad, revolve, primitives, patterns, modeled threads (ISO / UNC / NPT presets, every parameter editable)
- **Distinct error codes** for every failure (`MCAD-SK204`, `MCAD-SV302`, …) — see [ERRORS.md](ERRORS.md)
- **Structured logging** with an in-app Diagnostics screen — see [LOGGING.md](LOGGING.md)
- Design: [DESIGN.md](DESIGN.md)

The library is platform-pure Swift and fully unit-tested:
`cd MetalCADKit && swift test` (173 cases).

v1's kernel is tessellation-based: additive modeling is exact at mesh level;
boolean cut / fillet / shell report their designed error codes until the
OpenCascade bridge lands.

Built with Muse.
