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

The functional suite is organized into shared API coverage and Parallel-specific coverage. Shared API tests are adapted to the Parallel execution model; they check the same public behavior as the Serial suite where the API contracts match. Parallel-only differences (such as asynchronous cast dispatch and worker synchronization) are tested separately.

### Shared API coverage

- [ ] Initialize, create, and destroy casters.
- [ ] Stop simulation updates with an active cast, then call `FastCast.Init()` and confirm the cast resumes.
- [ ] Fire Raycast, Blockcast, and Spherecast casts; confirm each reaches a target and terminates.
- [ ] Verify enabled public event callbacks, including `CastFire`, `OnStep`, `LengthChanged`, `Hit`, `Pierced`, and `CastTerminating`.
- [ ] Verify Signals support multiple listeners, `Once`, `Wait`, `Disconnect`, `DisconnectAll`, and `HasListeners`.
- [ ] Verify `CanPierce` and `Pierced` when a cast passes through an instance and reaches the next target.
- [ ] Verify `OnStep` can change the trajectory for subsequent movement.
- [ ] Check `FastCast.newBehavior()` defaults and independent nested configuration.
- [ ] Switch movement mode and manipulate cast position, velocity, and acceleration.
- [ ] Confirm trajectory setters preserve current position and runtime.
- [ ] Confirm `PreviousPosition` advances with the simulated cast.
- [ ] Confirm `RaycastParams` filtering and `MaxDistance` termination without a hit.
- [ ] Confirm `MaxLifetime` termination, including zero lifetime.
- [ ] Confirm paused casts freeze runtime and resume without catching up.
- [ ] Exercise `Default`, `Automatic`, and `Always` high-fidelity modes.
- [ ] Confirm cosmetic template cloning, `CloneTemplate = false`, `InitialOffset`, runtime `Offset`, and ignoring the cosmetic container.
- [ ] Confirm terminating a cast from `OnStep`, `LengthChanged`, or `Pierced` preserves the termination event.

### Parallel-specific coverage

- [ ] Confirm worker runtime initialization and distinct `CasterId` values.
- [ ] Confirm events are routed to the correct caster when multiple casters share the worker pool.
- [ ] Confirm a caster can fire again after a cast terminates, including multiple requests close together.
- [ ] Confirm worker `OnStep` runs before movement and can steer the current simulation step.
- [ ] Confirm caster Signal listener changes are synchronized to workers after connect, disconnect, and reconnect.
- [ ] Confirm `SetFastCastEventsModule` forwards module events.
- [ ] Confirm worker event batches preserve each cast's arguments when multiple casts dispatch together.
- [ ] Confirm destroying a caster preserves valid cast data for `CastTerminating` listeners.
- [ ] Confirm `FastCast:SyncChangesToCast(cast)` propagates updated `UserData`, `MaxPiercesPerStep`, and other mutable fields, refreshes cached `MaxDistance`, and preserves worker-owned runtime and trajectory references.
- [ ] Confirm `PauseCast` / `ResumeCast` affect the worker simulation.
- [ ] Confirm `DestroyVMs()` tears down workers and `Init()` recreates the runtime so existing casters can fire again.

The parallel API queues fire requests for worker dispatch, so it does not promise the synchronous cast return value tested by Serial `RaycastFire`. Cast data is observed through the `CastFire` Signal instead. Run the suite in Studio to verify runtime behavior; this checklist describes intended coverage, not a claim that tests have passed in the current environment.

## Benchmarks

The automated benchmark exercises Raycast, Blockcast, and Spherecast using the parallel implementation. It records creation and cleanup throughput plus simulation frame-time percentiles. Worker count and sample duration are configurable in `tests/src/Benchmarks.luau`.

Compare benchmark runs using the same environment and settings. Performance results do not replace functional tests.

## Manual testing notes

- Run the suite in Roblox Studio; static checks alone do not verify worker/runtime behavior.
- Cosmetic projectile lifetime and cleanup are caller-owned. FastCast2Parallel does not automatically destroy projectiles or return them to a cache.
- When changing worker communication or synchronization, pay special attention to event routing, `FastCast:SyncChangesToCast(cast)`, and pause/resume behavior.
- API reference: [FastCast2Parallel API](https://weenachuangkud.github.io/FastCast2Parallel/docs/api-reference/).
