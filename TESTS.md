# Testing FastCast2Parallel

## Run the automated suite

From the repository root, run:

```sh
npm test
# or
lune run tests/run.luau
```

The runner builds a Rojo place, runs it in Roblox Studio through `run-in-roblox`, prints the functional-test summary and the three-cast parallel benchmark results, and uploads the report to [paste.shellworks.dev](https://paste.shellworks.dev). See [`tests/README.md`](tests/README.md) for prerequisites and options.

## Functional test sections

The functional suite is organized into two sections. Both exercise the **Parallel implementation**; the shared API section is based on the Serial test coverage and adapted for Parallel's worker-based execution model.

### API coverage

- [ ] Initialize, create, and destroy casters.
- [ ] Stop simulation updates with an active cast, then call `FastCast.Init()` and confirm the cast resumes.
- [ ] Call `FastCast.DestroyVMs()`, verify firing requires reinitialization, then call `FastCast.Init()` and confirm an existing caster can fire again.
- [ ] Fire Raycast, Blockcast, and Spherecast casts; confirm each reaches a target and terminates.
- [ ] Verify enabled public event callbacks and multiple Signal listeners.
- [ ] Verify caster Signal listeners are tracked per caster and synchronized to every worker when connected, disconnected, or reconnected.
- [ ] Verify worker module callbacks are detected by checking whether each event field is a function.
- [ ] Check behavior defaults and independent nested configuration.
- [ ] Verify `InitialOffset` initializes the cosmetic transform and that runtime `Offset` changes propagate through `SyncChangesToCast`.
- [ ] Verify `MaxPiercesPerStep` emits pierced events before the terminal hit and respects the configured ray-attempt limit.
- [ ] Switch movement mode and manipulate active cast position, velocity, and acceleration.
- [ ] Verify `RaycastParams` filtering and `MaxDistance` termination without a hit.
- [ ] Verify cosmetic template cloning, `CloneTemplate = false`, and ignoring the cosmetic container.
- [ ] Exercise high-fidelity hit resolution and maximum-distance termination.
- [ ] Verify `MaxLifetime`, including zero lifetime, and pause/resume behavior.

### Parallel-specific coverage

- [ ] Confirm the shared runtime initializes and creates casters with distinct `CasterId` values.
- [ ] Confirm events are routed to the correct caster when multiple casters share the runtime.
- [ ] Confirm a caster can fire again after an earlier cast terminates, including multiple requests close together.
- [ ] Confirm worker `OnStep` runs before movement and can steer a cast.
- [ ] Confirm `FastCast:SyncChangesToCast(cast)` propagates updated `UserData` to worker `OnStep`.
- [ ] Confirm `FastCast:SyncChangesToCast(cast)` preserves worker-owned runtime and trajectory references, refreshes cached `MaxDistance`, and applies cast changes.
- [ ] Confirm `SetFastCastEventsModule` forwards module events to the configured module.
- [ ] Check Parallel-specific pause/resume and worker simulation behavior.

These lists describe the intended coverage, not a guarantee that every item has passed in the current environment. Run the suite in Studio to verify changes.

## Benchmarks

The automated benchmark exercises Raycast, Blockcast, and Spherecast using the parallel implementation. It records creation and cleanup throughput plus simulation frame-time percentiles. Worker count and sample duration are configurable in `tests/src/Benchmarks.luau`.

Compare benchmark runs using the same environment and settings. Performance results do not replace functional tests.

## Manual testing notes

- Run the suite in Roblox Studio; static checks alone do not verify worker/runtime behavior.
- Cosmetic projectile lifetime and cleanup are caller-owned. FastCast2Parallel does not automatically destroy projectiles or return them to a cache.
- When changing worker communication or synchronization, pay special attention to event routing, `FastCast:SyncChangesToCast(cast)`, and pause/resume behavior.
- API reference: [FastCast2Parallel API](https://weenachuangkud.github.io/FastCast2Parallel/docs/api-reference/).
