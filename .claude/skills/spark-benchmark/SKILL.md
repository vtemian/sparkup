---
name: spark-benchmark
description: Use when measuring a DGX Spark's GPU throughput or peak power - "how fast is my Spark", "benchmark this box", "am I getting the TFLOPS I should", "how many watts can it pull", or before quoting any performance number for GB10. Encodes the traps that have produced wrong answers on this hardware.
---

# Benchmarking a DGX Spark

Three documented ways to get a wrong answer on this box. Check all three before running anything.

## Trap 1 — something else is already on the GPU

Always, first:

```sh
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

A live training job made a benchmark GEMM read **9.3 TFLOP/s instead of 23.75** — a 2.5× error that
sent an earlier investigation chasing the toolchain when the box was fine.

If anything is running, either stop and wait, or say explicitly that the result is contended.
Contended numbers are **valid for peak power** and **worthless for throughput**.

## Trap 2 — benchmarking against a number this hardware never had

Dense bf16 peak is 48 SMs × 1024 FLOP/clk × **the clock the job actually held**, which is not the
clock the GPU asks for. Compute the target from the measured clock or the target is fiction.

Two figures make a healthy box look broken:

- **~213 TFLOPS**, which circulates for this hardware and is not dense bf16. Do not quote it, and
  correct anyone who does.
- **The peak implied by 2418 MHz.** 2418 is `Default Applications Clocks` — what the GPU requests at
  idle. Under a saturating GEMM the power cap pulls the sustained clock down to roughly 2150 MHz, so
  a compute-bound job never holds 2418 and the peak derived from it is unreachable.

`nvidia-smi` also reports `Max Clocks` as 3003 MHz, the top of the clock table and not a sustained
frequency. Neither 3003 nor 2418 is a throughput target.

Judge the result against theoretical-at-the-measured-clock, never against the spec-sheet
peak; the fraction of achievable is the number worth quoting.

## Trap 3 — trusting nvidia-smi for power

It reads the GPU rail **low** — measured between 18 % and 44 % under across different runs, so treat
the direction as reliable and the magnitude as meaningless. It reports `power.limit` as `[N/A]`, and
holds every Clocks Event Reason at `Not Active` through a throttle the EC is enforcing — its
`SW Power Capping` counter did not advance through 75 s with the module pinned at its cap.

Take power from the `spbm` firmware channels. See the `spark-diagnosis` skill.

## Running it

`gemm.py` beside this file is a sustained dense bf16 GEMM: large square matmuls queued in batches so
the GPU never waits on the host, with a warmup before timing so cuBLAS heuristics and clocks settle.

```sh
scp .claude/skills/spark-benchmark/gemm.py <box>:/tmp/
ssh <box> '<path-to-venv>/bin/python /tmp/gemm.py 8192 60'
```

`<box>` is `spark.local` on its own LAN. From anywhere else it is the tailnet name, which `make
report` prints on its `Reachable from` line where the `tailscale` role is configured. A benchmark run
over the tailnet is fine: the GEMM runs entirely on the box and only the result crosses the link.

Arguments are matrix size and duration in seconds. 8192 keeps it compute-bound; smaller sizes drift
toward memory-bound and under-report both throughput and power.

To capture peak power, sample the channels in a second session while it runs — see step 3 of the
`spark-diagnosis` skill. Read `pl1` against its cap, not the `gpu` channel: `pl1` is the module budget
and is the limit that actually binds.

## Interpreting the result

- **`pl1` pinned at its cap** — the box is at its ceiling. This is the real peak, and expect
  `sys_total` around 171 W, nowhere near the 240 W PSU rating.
- **`pl1` short of its cap during a dense GEMM** — something is wrong with the benchmark, not the
  box. Check trap 1, then check the matrix size.
- **Throughput well under theoretical at the clock it held** — check the SM clock first. Near 500 MHz
  means the EC safety mode; go to `spark-diagnosis`. Around 2150 under load is normal, and roughly
  90 % of theoretical at that clock is what a good run looks like, so do not read the gap to an
  idle-clock target as a fault.

## Reporting it

State the matrix size, the duration, whether the box was contended, and the measured SM clock
alongside any TFLOP/s figure. A throughput number without those four is not reproducible, and this
hardware has already produced two published-then-retracted figures for want of them.
