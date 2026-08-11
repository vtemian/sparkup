"""Sustained dense bf16 GEMM, for measuring GB10 throughput and peak power.

Usage: python gemm.py [N] [SECONDS]

N below ~8192 drifts toward memory-bound and under-reports both throughput and
power. Read power from the spbm hwmon channels while this runs; nvidia-smi reads
the GPU rail low on this hardware and cannot see EC capping at all.

Judge the TFLOP/s against theoretical at the clock this reports, not at the idle
clock: the power cap pulls a saturating job well below Default Applications
Clocks, so the idle figure implies a peak the box never reaches.
"""

import sys
import time

import torch

N = int(sys.argv[1]) if len(sys.argv) > 1 else 8192
SECONDS = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0

dev = torch.device("cuda")
a = torch.randn(N, N, device=dev, dtype=torch.bfloat16)
b = torch.randn(N, N, device=dev, dtype=torch.bfloat16)
c = torch.empty(N, N, device=dev, dtype=torch.bfloat16)

# Warm up before timing: cuBLAS picks a kernel on first call, and clocks take a
# moment to settle. Timing the first iteration measures neither.
for _ in range(10):
    torch.matmul(a, b, out=c)
torch.cuda.synchronize()

flop_per_iter = 2.0 * N**3
iters = 0
start = time.monotonic()
while time.monotonic() - start < SECONDS:
    # Queue a batch between syncs so the GPU never waits on the host. One
    # synchronize per matmul leaves gaps that read as lower power and lower
    # throughput, which is the mistake this script exists to avoid.
    for _ in range(20):
        torch.matmul(a, b, out=c)
    torch.cuda.synchronize()
    iters += 20
elapsed = time.monotonic() - start

clock = torch.cuda.clock_rate() if hasattr(torch.cuda, "clock_rate") else None
print(f"N={N} iters={iters} elapsed={elapsed:.1f}s")
print(f"achieved {iters * flop_per_iter / elapsed / 1e12:.1f} TFLOP/s bf16 dense")
if clock:
    print(f"SM clock {clock} MHz")
print("Contended? Check: nvidia-smi --query-compute-apps=pid,used_memory --format=csv")
