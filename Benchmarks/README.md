# Benchmarks

Benchmarks of Swift Build, run with the [Benchmark](https://github.com/ordo-one/benchmark) package's plugin:

```
swift package benchmark                       # every benchmark
swift package benchmark --target PlanningBenchmarks --filter 'Planning\..*'
swift package --allow-writing-to-package-directory benchmark baseline update main
swift package benchmark baseline compare main
```

| Target | What it measures |
|---|---|
| `PlanningBenchmarks` | Dependency resolution and build planning of generated workspaces of hundreds to thousands of targets, with and without cached settings |
| `SWBUtilBenchmarks`, `SWBCASBenchmarks`, `SWBCoreBenchmarks` | Utilities, the CAS, macros, settings and serialization |
| `SWBTaskConstructionBenchmarks` | Task construction |
| `SWBBuildSystemBenchmarks`, `SwiftBuildBenchmarks` | Real builds, the build service, and XCFramework creation |

Every benchmark reports the same metrics: wall clock and CPU time, instructions, throughput, malloc count and bytes, and peak resident memory.

## Accurate timing and allocation counts

The Benchmark package counts allocations through a malloc interposer that every allocation passes through, whether or not it's counting. That costs about 8% more instructions and 4–8% more time in planning, and 4–10% more resident memory. Measure time, instructions and memory without it, in a separate build directory, and use the default build only for allocation counts:

```
BENCHMARK_DISABLE_MALLOC_INTERPOSER=1 swift package --scratch-path .build-timing benchmark
swift package benchmark --skip-target SWBBuildSystemBenchmarks
```

`SWBBuildSystemBenchmarks` run builds in-process, which crash under the interposer when build threads exit, so they only run without it.

## Checking results

With `SWB_BENCHMARK_DUMP_DIRECTORY` set, `PlanningBenchmarks` writes the first graph, linkage graph or plan each benchmark produces, and a hash of its workspace, so that a change can be checked for differences against `main`. The same benchmark always generates the same workspace.
