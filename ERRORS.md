# MetalCAD — Error Code Taxonomy

Every failure in MetalCAD carries a **distinct, stable error code**:
`MCAD-<domain><number>`, e.g. `MCAD-SV3007`. Codes are never reused, never
renumbered, and appear in: the user-facing alert (small, under the plain-words
message), the log (always), and support bundles. A user can quote a code and
we know exactly what failed, where, and what to tell them.

Format: `MCAD-` + domain prefix (2 letters) + 3 digits.

| Domain | Prefix | Area |
|---|---|---|
| General | GN | startup, memory, unknown |
| Document | DC | documents, feature tree, parameters |
| Sketch | SK | sketch entities and editing |
| Solver | SV | constraint solver |
| Features | FT | modeling operations |
| Threads | TH | thread system |
| Kernel | KN | geometry kernel bridge |
| Files | IO | import / export |
| Assembly | AS | assemblies and mates |
| Drawing | DR | drawings and annotation |
| Render | RD | tessellation and rendering |
| App/UI | UI | interface-level failures |

Severity: **W** warning (work continues), **E** error (operation stopped,
model intact), **F** fatal (app protects data and restarts the document).

---

## GN — General
- `MCAD-GN001` **UnknownError** (E) — an unclassified failure was caught and contained. Always logged with the underlying error.
- `MCAD-GN002` **OutOfMemory** (F) — the system reported memory pressure during a rebuild; the last good model is kept.
- `MCAD-GN003` **CancelledByUser** (W) — a long operation was cancelled; partial work discarded, model unchanged.
- `MCAD-GN004` **NotImplementedYet** (W) — a designed feature that lands in a later phase; the UI must never offer it silently.
- `MCAD-GN005` **InternalInvariantBroken** (F) — a "cannot happen" check failed; document is snapshotted for diagnostics before anything else happens.

## DC — Document
- `MCAD-DC101` **DocumentNotFound** (E) — the file isn't where the library thought it was.
- `MCAD-DC102` **DocumentCorruptJSON** (E) — the document JSON can't be parsed; the most recent snapshot is offered instead.
- `MCAD-DC103` **DocumentVersionTooNew** (E) — written by a newer MetalCAD; we refuse rather than mangle it.
- `MCAD-DC104` **DocumentVersionTooOld** (W) — migrated forward on load; a pre-migration copy is kept.
- `MCAD-DC105` **DuplicateName** (W) — two objects share a name; the new one is auto-suffixed (`plate_2`) and the rename is announced.
- `MCAD-DC106` **NameNotFound** (E) — a script/equation referenced an object that doesn't exist.
- `MCAD-DC107` **FeatureRebuildFailed** (E) — a feature in the tree failed; carries the child code of the real cause. The tree marks that feature and stops after it.
- `MCAD-DC108` **CircularDependency** (E) — features/parameters depend on each other in a loop; the loop members are listed.
- `MCAD-DC109` **ParameterOutOfRange** (W) — a value was clamped to its legal range (e.g. negative length → 0) and the clamp is announced.
- `MCAD-DC110` **SnapshotWriteFailed** (E) — autosave snapshot couldn't be written (storage full?); the in-memory document is safe and the user is told to export now.
- `MCAD-DC111` **EquationParseError** (E) — a formula couldn't be parsed; points at the character position.
- `MCAD-DC112` **EquationEvalError** (E) — a formula parsed but failed (divide by zero, unknown unit).

## SK — Sketch
- `MCAD-SK201` **SketchNotOnPlane** (E) — the sketch's plane reference vanished (its face was deleted).
- `MCAD-SK202` **EntityNotFound** (E)
- `MCAD-SK203` **DegenerateEntity** (W) — a zero-length line / zero-radius circle was created by an edit; it's flagged for the health check, never silently used.
- `MCAD-SK204` **ProfileOpen** (E) — Pad/Revolve asked for a closed profile but the loop is open; the gap endpoints are identified (coordinates in the log, a zoom target in the UI).
- `MCAD-SK205` **ProfileSelfIntersecting** (E) — the loop crosses itself; the crossing is located.
- `MCAD-SK206` **ProfileNestedTooDeep** (W) — more than 8 levels of nested islands; profile is flattened with a warning.
- `MCAD-SK207` **DuplicateEntity** (W) — an entity exactly overlaps another (found by health check).
- `MCAD-SK208` **SplineTooFewPoints** (E) — a spline needs ≥ 2 poles / ≥ 3 fit points.
- `MCAD-SK209` **ArcInvalidGeometry** (E) — three points are collinear; no arc exists.
- `MCAD-SK210` **TextProfileFailed** (E) — a font couldn't be outlined (later phase).
- `MCAD-SK211` **ProjectionSourceGone** (W) — projected reference geometry lost its source edge/face; kept as frozen construction geometry.
- `MCAD-SK212` **SketchEmpty** (W) — an operation was asked of an empty sketch.
- `MCAD-SK213` **ProfileGapHealed** (W) — profile/path chaining sewed an endpoint gap of at most the sketch sewing tolerance (0.5 mm): a hand-drawn joint that nearly touched. The sewn distance is carried in the warning; gaps beyond the tolerance remain `MCAD-SK204`.

## SV — Solver
- `MCAD-SV301` **SolverDidNotConverge** (E) — iterations exhausted; the sketch is left in its last valid state, never a half-solved one.
- `MCAD-SV302` **ConflictingConstraints** (E) — new constraint contradicts existing ones; the conflicting set is named.
- `MCAD-SV303` **RedundantConstraint** (W) — the constraint adds nothing (already implied); offered as a reference dimension instead.
- `MCAD-SV304` **OverConstrained** (E) — adding this would over-define the sketch; refused with the DOF count before/after.
- `MCAD-SV305` **SolverSingular** (E) — the system went singular mid-solve (classic: arcs flipped through infinity); last valid state restored.
- `MCAD-SV306` **DanglingConstraint** (E) — a constraint references a deleted entity; the constraint is quarantined and listed, not silently dropped.
- `MCAD-SV307` **SolveTimeout** (W) — solve exceeded its time budget on a huge sketch; partial solve applied only if residual < tolerance, else `SV301`.

## FT — Features / modeling
- `MCAD-FT401` **PadNoProfile** (E) — Pad was given a sketch with no closed profile.
- `MCAD-FT402` **PadLengthInvalid** (E) — zero or negative length after evaluation.
- `MCAD-FT403` **RevolveAxisMissing** (E) — no axis/construction line chosen.
- `MCAD-FT404` **RevolveProfileCrossesAxis** (E) — profile crosses the axis (would self-intersect).
- `MCAD-FT405` **BooleanFailed** (E) — kernel boolean refused; operands unchanged.
- `MCAD-FT406` **BooleanEmptyResult** (E) — cut removed everything / union of disjoint asked as one body.
- `MCAD-FT407` **FilletFailed** (E) — kernel couldn't fillet the edge set at this radius; UI suggests the largest radius that works (found by bisection) when possible.
- `MCAD-FT408` **FilletRadiusTooLarge** (W) — radius clamped to the largest feasible for the smallest adjacent face.
- `MCAD-FT409` **ChamferInvalid** (E) — distances/angle don't fit the edge's faces.
- `MCAD-FT410` **ShellFailed** (E) — wall thickness consumes the whole body or a face can't offset.
- `MCAD-FT411` **PatternCountInvalid** (E) — count < 1 or spacing 0.
- `MCAD-FT412` **TransformInvalid** (E) — zero axis for rotation, NaN in a typed value.
- `MCAD-FT413` **PrimitiveParamInvalid** (E) — e.g. torus tube radius ≥ ring radius.
- `MCAD-FT414` **SweepPathInvalid** (E) — path is open, self-intersecting, or the profile isn't near the path start (later phase).
- `MCAD-FT415` **LoftProfileMismatch** (W) — profiles have very different shapes; loft proceeds ruled (later phase).
- `MCAD-FT416` **HoleSpecInvalid** (E) — drill bigger than its face, counterbore shallower than depth, etc.
- `MCAD-FT417` **DirectEditHealFailed** (E) — deleting a face couldn't be healed over.

## TH — Threads
- `MCAD-TH501` **ThreadPitchInvalid** (E) — pitch ≤ 0 or > diameter.
- `MCAD-TH502` **ThreadDiameterInvalid** (E) — major ≤ minor, or thread on a non-cylindrical face.
- `MCAD-TH503` **ThreadProfileInvalid** (E) — profile angle outside 5°–175°, or flats exceed the pitch.
- `MCAD-TH504` **ThreadStartsInvalid** (E) — starts outside 1–4.
- `MCAD-TH505` **ThreadTooLongForShaft** (W) — thread length clamped to the cylinder's length.
- `MCAD-TH506` **ThreadSweepFailed** (E) — the helical sweep self-intersected (usually: pitch too fine for the profile depth).
- `MCAD-TH507` **ThreadTaperInvalid** (E) — taper makes the thread vanish before its end.
- `MCAD-TH508` **ThreadFitOutOfRange** (W) — clearance offset clamped so internal/external pair can't invert.
- `MCAD-TH509` **ThreadPresetUnknown** (W) — a named preset (e.g. "M10x1.5") isn't in the table; parameters left as-is.

## KN — Kernel bridge
- `MCAD-KN601` **KernelUnavailable** (E) — no kernel backend is linked (pure-Swift fallback is offered if present).
- `MCAD-KN602` **KernelOperationFailed** (E) — generic kernel refusal; original kernel exception text goes to the log, never to the user raw.
- `MCAD-KN603` **KernelShapeInvalid** (E) — the kernel returned a shape that fails validity checks; it's quarantined, the previous solid stays.
- `MCAD-KN604` **KernelTessellationFailed** (E) — a valid solid couldn't be meshed at the requested deflection; retried once coarser, then reported.
- `MCAD-KN605` **KernelTimeout** (E) — an operation exceeded its budget and was cancelled; model unchanged.

## IO — Import / Export
- `MCAD-IO701` **ImportFormatUnsupported** (E)
- `MCAD-IO702` **ImportFileUnreadable** (E) — permissions, truncation, or wrong file entirely.
- `MCAD-IO703` **ImportGeometryInvalid** (W) — imported with defects; repair offered (`FT` heal).
- `MCAD-IO704` **ExportNotWatertight** (W) — STL export proceeded but the mesh isn't watertight; the holes are counted and located in the log.
- `MCAD-IO705` **ExportWriteFailed** (E) — disk full / share sheet cancelled.
- `MCAD-IO706` **STEPWriteFailed** (E) — kernel refused the shape for STEP.
- `MCAD-IO707` **MeshTooLarge** (W) — export exceeds the chosen triangle budget; deflection coarsened automatically once.

## AS — Assembly (later phases, codes reserved now)
- `MCAD-AS801` **MateConflict** (E) — mates contradict; the set is named.
- `MCAD-AS802` **MateSourceGone** (W) — a mated face/edge was deleted; mate quarantined.
- `MCAD-AS803` **InterferenceFound** (W) — parts overlap; volume reported.
- `MCAD-AS804` **AssemblyCycle** (E) — sub-assembly contains itself.

## DR — Drawings (later phases, codes reserved now)
- `MCAD-DR901` **ViewProjectionFailed** (E)
- `MCAD-DR902` **DimensionOrphaned** (W) — the dimensioned geometry changed shape; dimension kept, flagged.
- `MCAD-DR903` **SheetOverflow** (W) — views don't fit the sheet at the chosen scale; smaller scale suggested.

## RD — Render
- `MCAD-RD951` **RenderDeviceLost** (E) — Metal device went away (backgrounding); view rebuilds on return.
- `MCAD-RD952` **ShaderCompileFailed** (F) — a built-in shader failed to compile; falls back to the flat shader and logs the compiler output.

## UI — App
- `MCAD-UI961` **ShareExportFailed** (W) — share sheet failed to hand off the file.
- `MCAD-UI962` **PickerCancelled** (W) — user cancelled a file picker (logged at info level in practice; exists so cancellations are distinguishable from failures in support bundles).
