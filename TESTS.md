# Testing FastCast2Parallel

Run the automated suite from the repository root:

```sh
npm test
# or
lune run tests/run.luau
```

The runner builds a Rojo place, runs it in Roblox Studio through `run-in-roblox`,
prints a functional-test summary and a three-case parallel benchmark table, and
uploads the report to [paste.shellworks.dev](https://paste.shellworks.dev).
See [`tests/README.md`](tests/README.md) for prerequisites and options.

## Functional coverage

- Caster initialization and cleanup
- Raycast, Blockcast, and Spherecast hit/termination behavior
- Public event callbacks and multiple Signal listeners
- FastCastEventsModule forwarding
- Runtime cast manipulation and `SyncChangesToCast`
- Movement mode changes and high-fidelity behavior

## Benchmarks

The automated benchmark runs the parallel implementation with Raycast, Blockcast,
and Spherecast. It records creation and cleanup throughput plus simulation frame
time percentiles. Worker count and sample duration are configurable in
`tests/src/Benchmarks.luau`.

The same behaviors can be checked manually in Studio if automated execution is
not available. See the [API reference](https://weenachuangkud.github.io/FastCast2Parallel/docs/api-reference/).

