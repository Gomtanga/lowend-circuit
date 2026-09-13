# Offline production stage-chain probe

This is an offline measurement tool. It copies and compiles the actual `TonalDSPRouter → Spatializer → ResamplingOutputConditioningEngine` sources and C ring code into a separate scratch executable. No audio device is opened, no device setting is read or changed, and no library is injected into another application or system process. The interposition library is a normal linked dependency of this probe executable only.

Run from the repository root with a new output directory:

```bash
bash SystemAudioProcessor/Tests/StageChainProbe/run.sh /tmp/lowend-stage-chain-measurement 1000
```

The tested environment is an Apple M5, macOS 26.6.2, Apple Swift 6.3.3 and its macOS 26 SDK. The probe uses the newer typed allocator entrypoints from this SDK. This does not raise the application's deployment target, and this probe is not a minimum-macOS compatibility test. The report step needs Python 3's standard library.

The script copies all linked production sources before compiling, records SHA-256 hashes, and uses `-O -whole-module-optimization`. Only the simple `AppError.message` and `clamp` declarations are reproduced from `main.swift`; processing classes, settings, coefficients, geometry and C rings are unchanged copies. The production orchestration file is also copied as a reference but is not linked. The generated `README.md` includes the exact invocation. For a repeat using a previous fixed production snapshot:

```bash
bash SystemAudioProcessor/Tests/StageChainProbe/run.sh /tmp/lowend-stage-chain-repeat 1000 /tmp/lowend-stage-chain-measurement/snapshot
```

The matrix has 108 scenarios:

- 44.1, 48, 96, 192, 384 and 768 kHz; 64 and 256 input frames; Clean, Circuit and HighExciter with automatic exciter oversampling.
- Every combination runs with conditioning bypass, both steady Spatial-on and simultaneous tonal-model/Spatial retargeting. Model pairs are Clean↔Circuit, Circuit↔HighExciter, HighExciter↔Clean, alternating the target each block.
- At 44.1 and 48 kHz only, additional cases use live 2× short, live 2× long, and simultaneous model/Spatial/short↔long filter transitions.
- The first Spatial target is `(X=0.4, Z=-0.6, width=1.65, amount=35%)`; the other is `(3, 1.8, 3, 100%)`. Coefficients, packets and headroom gain are prepared outside the measured interval. Conditioning updates use the callback's `precomputedHeadroomGain` overload, not the manager/offline dB conversion convenience method.

Input, intermediates, output, timing storage and two rings are allocated before processing. A multitone stereo block repeats; this is CPU characterization, not a spectral-quality test. The measured block applies prepared changes when selected, processes each stereo sample through the production stages, conditions the block and pushes into two production C rings, as the capture path does for output and analysis. Ring draining, finite checks, checksums, sorting, formatting and logging occur after the measured interval. The rings do not have a simultaneous consumer in this test.

Each scenario has three measurement scopes. `cold_*` is the first processing block of that initialized chain on the measurement thread. After 256 warmup blocks, `cpu_*` and `elapsed_*` summarize the requested number of warm blocks. The chain is then reset on that thread and handed exclusively to a newly created pthread for one `fresh_thread_*` block. The creating thread joins the worker before touching the chain again. This catches per-thread first-use behavior that a manager-thread warmup alone would miss. It does not run on a CoreAudio thread.

Thread CPU uses `CLOCK_THREAD_CPUTIME_ID`; elapsed uses `mach_absolute_time`. Both include clock-read overhead. Elapsed can include descheduling, and the process has normal scheduling priority. A fraction of nominal `frames / inputRate` is only an offline comparison; it does not prove that a full capture/render callback stays below its budget.

The linked interposition dylib counts calls only while a measured interval is active and only on the selected measuring thread. It checks a static atomic flag before thread identity access, so the hooks do not recursively initialize TLS at process startup. The individually reported symbols are `malloc`, `calloc`, `realloc`, `free`, `malloc_zone_malloc`, `malloc_zone_calloc`, `malloc_zone_realloc`, `pthread_mutex_lock`, `pthread_mutex_trylock`, `os_unfair_lock_lock` and `os_unfair_lock_trylock`. `other_allocator_entrypoints` groups these 14 additional symbols:

```text
aligned_alloc, posix_memalign, malloc_zone_memalign,
malloc_type_malloc, malloc_type_calloc, malloc_type_realloc,
malloc_type_aligned_alloc, malloc_type_posix_memalign,
malloc_type_zone_malloc, malloc_type_zone_calloc,
malloc_type_zone_realloc, malloc_type_zone_memalign,
malloc_zone_malloc_with_options, malloc_type_zone_malloc_with_options
```

A separate canary dylib calls all listed allocation and lock families before measurement. A Swift allocation passed to an external C function must also be intercepted, which prevents the optimizer from removing the allocation. The executable refuses to measure if the canaries fail. On the tested OS, only hooking ordinary `malloc`/zone symbols missed the Swift allocation; the typed/aligned hooks detected it. Counts are imported symbol calls and can overlap within one allocation. Direct zone function-pointer calls, private locks, VM mappings and other allocation mechanisms are outside this coverage.

For diagnosis only, capture the first intercepted call's stack in each cold or fresh-thread interval:

```bash
bash SystemAudioProcessor/Tests/StageChainProbe/run.sh /tmp/lowend-stage-chain-trace 100 /tmp/lowend-stage-chain-measurement/snapshot --trace-first-allocation
```

Backtrace collection is disabled in normal measurements. Diagnostic-run timings are not performance evidence. Before `DelayLine` used fixed pointer storage, this diagnostic found `malloc_type_malloc → swift_slowAlloc → SwiftTLSContext::get → swift_beginAccess → Spatializer.process` on first use, including on a fresh pthread after initialization/warmup/reset on another thread. That result required a source fix; it was not dismissed as instrumentation overhead.

Outputs include `results.csv`, `summary.json`, `summary.md`, `environment.txt`, `source-sha256.txt`, `build.log`, `run-stderr.log`, the linked executable/libraries, and all fixed sources. The actual CoreAudio callback/gate/control queue drain, simultaneous output render, UI/analysis/GPU load, device switches, xrun behavior, Instruments stack coverage and audible transitions remain outside this test.
