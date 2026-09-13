#!/usr/bin/env python3
"""Summarize the offline probe without treating timings as a device release gate."""
import csv
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1]).resolve()
lines = (directory / "results.csv").read_text().splitlines()
rows = list(csv.DictReader(line for line in lines if not line.startswith("#")))
names = ["malloc", "calloc", "realloc", "free", "zone_malloc", "zone_calloc", "zone_realloc",
         "pthread_mutex_lock", "pthread_mutex_trylock", "os_unfair_lock", "os_unfair_trylock",
         "other_allocator_entrypoints"]
counts = {scope or "warm": {name: sum(int(row[scope + name]) for row in rows) for name in names}
          for scope in ("", "cold_", "fresh_thread_")}
metrics = ["cpu_p50_us", "cpu_p95_us", "cpu_max_us", "elapsed_p50_us", "elapsed_p95_us", "elapsed_max_us",
           "cold_cpu_us", "cold_elapsed_us", "fresh_thread_cpu_us", "fresh_thread_elapsed_us"]

def worst(metric):
    row = max(rows, key=lambda r: float(r[metric]) / float(r["block_budget_us"]))
    return {"rate_hz": int(row["rate_hz"]), "block_frames": int(row["block_frames"]),
            "model": row["model"], "next_model": row["next_model"], "scenario": row["scenario"],
            "conditioning": row["conditioning"], "microseconds": float(row[metric]),
            "block_budget_microseconds": float(row["block_budget_us"]),
            "percent_of_nominal_block_duration": 100 * float(row[metric]) / float(row["block_budget_us"])}

valid_output = all(int(row["dropped_samples"]) == 0 and int(row["nonfinite_samples"]) == 0 for row in rows)
zero_observed_calls = all(value == 0 for scope in counts.values() for value in scope.values())
summary = {
    "scope": "offline production stage chain; does not execute or validate a CoreAudio callback",
    "scenario_count": len(rows), "measured_warm_blocks": sum(int(row["blocks"]) for row in rows),
    "cold_blocks": len(rows), "fresh_pthread_blocks": len(rows), "warmup_blocks_per_scenario": 256,
    "output_validation_passed": valid_output, "zero_observed_allocator_and_lock_calls": zero_observed_calls,
    "observed_symbol_calls": counts,
    "worst_by_nominal_block_fraction": {metric: worst(metric) for metric in metrics},
    "absolute_max_microseconds": {metric: max(float(row[metric]) for row in rows) for metric in metrics},
    "canary_and_scope_notes": [line[2:] for line in lines if line.startswith("# ")],
    "environment": (directory / "environment.txt").read_text(),
    "limitations": [
        "Normal-priority offline execution; actual capture/render callbacks and device rates are not exercised.",
        "No callback gate/control queue drain, simultaneous producer-consumer scheduling, output render, analysis/GPU or UI workload.",
        "Thread CPU excludes descheduled time; elapsed includes preemption. Both include clock-read overhead.",
        "Counts cover imported allocator and lock entrypoints only, not all VM allocation, direct function-pointer zone calls or private locks.",
        "Counters are symbol calls and may overlap within one allocation. Warm, first process block and fresh-thread blocks are separate.",
        "A fresh thread measures a single block after the same chain was initialized, warmed and reset on another thread.",
        "Timings characterize this source hash set, OS, compiler, hardware and run. They do not prove a hardware callback budget or no audible pops."
    ],
}
(directory / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
report = ["# Offline stage-chain probe", "", summary["scope"], "",
          f"Scenarios: {len(rows)}; warm blocks: {summary['measured_warm_blocks']}; cold blocks: {len(rows)}; fresh-pthread blocks: {len(rows)}.",
          f"Finite output and no ring loss: {valid_output}. Zero observed allocator/lock calls in all three scopes: {zero_observed_calls}.", "",
          "| Metric | Worst nominal block fraction | Rate / frames | Model / mode |", "|---|---:|---|---|"]
for metric in metrics:
    value = worst(metric)
    report.append(f"| {metric} | {value['percent_of_nominal_block_duration']:.2f}% ({value['microseconds']:.3f} µs) | "
                  f"{value['rate_hz']} / {value['block_frames']} | {value['model']} → {value['next_model']} / {value['conditioning']} |")
report += ["", "This table compares only the measured stage chain with a nominal input block duration. It is not a full callback acceptance result.", "",
           "Source copies and hashes are in snapshot/ and source-sha256.txt; commands and conditions are in README.md. "
           "Raw rows, canaries and full limitations are in results.csv and summary.json."]
(directory / "summary.md").write_text("\n".join(report) + "\n")
if len(rows) != 108 or not valid_output:
    raise SystemExit("Incomplete scenario matrix or invalid output; see saved summary.")
print(f"108 scenarios summarized. Zero observed calls in warm/cold/fresh scopes: {zero_observed_calls}.")
