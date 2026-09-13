#!/bin/bash
set -euo pipefail

# Builds a separate executable from a fixed copy. It never opens or changes
# an audio device and never injects a library into any other process.
probe_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$probe_dir/../../.." && pwd)"
if [[ $# -gt 0 ]]; then
    output_dir="$1"
    if [[ -e "$output_dir" ]]; then
        printf 'Output directory already exists: %s\n' "$output_dir" >&2
        exit 2
    fi
    mkdir -p "$output_dir"
else
    output_dir="$(mktemp -d /tmp/lowend-stage-chain-probe.XXXXXX)"
fi
output_dir="$(cd "$output_dir" && pwd)"
iterations="${2:-1000}"
reuse_snapshot="${3:-}"
trace_argument="${4:-}"
snapshot="$output_dir/snapshot"
build_dir="$output_dir/build"
mkdir -p "$snapshot/SystemAudioProcessor/Sources/SystemAudioProcessor" "$snapshot/Source" "$snapshot/probe" "$build_dir"

swift_names=(AudioSettings.swift TonalDSP.swift SpatialDSP.swift SpatialGeometry.swift
    PCMResampler.swift ResamplingOutputConditioningEngine.swift
    OutputConditioningParameters.swift DeltaSigmaDSDModulator.swift DoPacker.swift)
if [[ -n "$reuse_snapshot" ]]; then
    cp -R "$reuse_snapshot/SystemAudioProcessor/." "$snapshot/SystemAudioProcessor/"
    cp -R "$reuse_snapshot/Source/." "$snapshot/Source/"
else
    for name in "${swift_names[@]}"; do
        cp "$repo_root/SystemAudioProcessor/Sources/SystemAudioProcessor/$name" \
           "$snapshot/SystemAudioProcessor/Sources/SystemAudioProcessor/$name"
    done
    for name in AudioRingBufferC LowEndDSPCoreC LowEndSupport; do
        cp -R "$repo_root/SystemAudioProcessor/Sources/$name" "$snapshot/SystemAudioProcessor/Sources/$name"
    done
    cp -R "$repo_root/Source/Core" "$snapshot/Source/Core"
fi
cp "$probe_dir/Probe.swift" "$probe_dir/StageProbe.c" "$probe_dir/StageProbe.h" \
   "$probe_dir/CanaryClient.c" "$probe_dir/run.sh" "$probe_dir/report.py" "$probe_dir/README.md" "$snapshot/probe/"
# Provenance for the orchestration shape; this file is not linked into the probe.
if [[ -n "$reuse_snapshot" ]]; then
    cp "$reuse_snapshot/probe/production-orchestration.swift.txt" "$snapshot/probe/production-orchestration.swift.txt"
else
    cp "$repo_root/SystemAudioProcessor/Sources/SystemAudioProcessor/SystemAudioProcessor.swift" "$snapshot/probe/production-orchestration.swift.txt"
fi
(
    cd "$snapshot"
    find . -type f -print0 | sort -z | xargs -0 shasum -a 256
) > "$output_dir/source-sha256.txt"
{
    date -u '+UTC %Y-%m-%dT%H:%M:%SZ'
    sw_vers
    uname -m
    sysctl -n machdep.cpu.brand_string
    xcrun swiftc --version
    git -C "$repo_root" rev-parse HEAD
    printf 'iterations=%s\nOptimization=-O -whole-module-optimization\n' "$iterations"
} > "$output_dir/environment.txt"
cp "$probe_dir/README.md" "$output_dir/README.md"
{
    printf '\nExact invocation for this output:\n\n```bash\n'
    printf 'bash %q %q %q %q %q\n' "$probe_dir/run.sh" "$output_dir" "$iterations" "$reuse_snapshot" "$trace_argument"
    printf '```\n'
} >> "$output_dir/README.md"

audio_include="$snapshot/SystemAudioProcessor/Sources/AudioRingBufferC/include"
core_include="$snapshot/SystemAudioProcessor/Sources/LowEndDSPCoreC/include"
mkdir -p "$build_dir/Modules/AudioRingBufferC" "$build_dir/Modules/LowEndDSPCoreC" "$build_dir/Modules/StageProbe"
printf 'module AudioRingBufferC { header "%s/AudioRingBufferC.h" export * }\n' "$audio_include" > "$build_dir/Modules/AudioRingBufferC/module.modulemap"
printf 'module LowEndDSPCoreC { header "%s/LowEndDSPCoreC.h" export * }\n' "$core_include" > "$build_dir/Modules/LowEndDSPCoreC/module.modulemap"
printf 'module StageProbe { header "%s/probe/StageProbe.h" export * }\n' "$snapshot" > "$build_dir/Modules/StageProbe/module.modulemap"
{
    xcrun clang -O2 -std=c11 -dynamiclib "$snapshot/probe/StageProbe.c" \
        -install_name @rpath/libStageProbe.dylib -o "$build_dir/libStageProbe.dylib"
    xcrun clang -O2 -fno-builtin -dynamiclib "$snapshot/probe/CanaryClient.c" \
        -install_name @rpath/libStageCanary.dylib -o "$build_dir/libStageCanary.dylib"
    xcrun clang -O2 -std=c11 -I "$audio_include" -c \
        "$snapshot/SystemAudioProcessor/Sources/AudioRingBufferC/AudioRingBufferC.c" -o "$build_dir/AudioRingBufferC.o"
    xcrun clang++ -O2 -std=c++17 -I "$audio_include" -c \
        "$snapshot/SystemAudioProcessor/Sources/LowEndDSPCoreC/LowEndDSPCoreC.cpp" -o "$build_dir/LowEndDSPCoreC.o"
    xcrun swiftc -swift-version 6 -O -whole-module-optimization -parse-as-library \
        -module-name LowEndSupport -emit-library -emit-module \
        -emit-module-path "$build_dir/LowEndSupport.swiftmodule" \
        -Xlinker -install_name -Xlinker @rpath/libLowEndSupport.dylib \
        "$snapshot/SystemAudioProcessor/Sources/LowEndSupport/"*.swift \
        -o "$build_dir/libLowEndSupport.dylib"
    swift_inputs=()
    for name in "${swift_names[@]}"; do
        swift_inputs+=("$snapshot/SystemAudioProcessor/Sources/SystemAudioProcessor/$name")
    done
    xcrun swiftc -swift-version 6 -O -whole-module-optimization \
        -I "$build_dir" -I "$build_dir/Modules" -Xcc -I"$audio_include" \
        "${swift_inputs[@]}" "$snapshot/probe/Probe.swift" \
        "$build_dir/AudioRingBufferC.o" "$build_dir/LowEndDSPCoreC.o" \
        -L "$build_dir" -lStageProbe -lStageCanary -lLowEndSupport -lc++ \
        -Xlinker -rpath -Xlinker "$build_dir" -o "$build_dir/stage-chain-probe"
} > "$output_dir/build.log" 2>&1
"$build_dir/stage-chain-probe" "$iterations" "$trace_argument" > "$output_dir/results.csv" 2> "$output_dir/run-stderr.log"
python3 "$snapshot/probe/report.py" "$output_dir"
printf 'Stage chain probe completed: %s\n' "$output_dir"
