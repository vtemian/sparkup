#!/usr/bin/env python3
"""Serve synthetic node_exporter and nvidia_gpu_exporter metrics.

The dashboard is the part of this repo people most want to iterate on, and it
is the part that most needs a running box. This stands in for the box: two
HTTP endpoints in the Prometheus exposition format, shaped like the two host
exporters the `exporters` role installs, carrying values that plausibly
resemble a DGX Spark: 20 cores, 121 GiB of unified memory, one 3.7 TB NVMe,
a GPU rail that peaks near 83 W, and clocks between 200 MHz idle and 3003 MHz.

It is deliberately not a simulator. The numbers move on a slow cycle so panels
show a line rather than a flat bar; nothing here is a claim about how the real
hardware behaves under load.

The series names are the ones the panels query. If a name here drifts from a
name in the dashboard, `check_dashboard.py --prometheus-url` fails, which is
the point of running the two together.

Standard library only. Run it directly:

    python3 tests/fake_exporters.py --node-port 19100 --gpu-port 19835
"""

from __future__ import annotations

import argparse
import math
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GPU_UUID = "GPU-00000000-0000-0000-0000-000000000000"
GPU_NAME = "NVIDIA GB10"
CORES = 20
MEM_TOTAL = 121 * 1024**3
FS_ROOT_SIZE = 3_700_000_000_000
FS_ROOT_USED = 65_000_000_000
FS_BOOT_SIZE = 1_073_741_824
UPTIME_AT_START = 20 * 3600

# Where the box sat at the audit: 6.45 hours of power capping, no thermal
# slowdown at all.
POWER_CAP_SECONDS_AT_START = 23224.5

CPU_MODES = ("user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal")
HWMON_SENSORS = (
    ("acpitz", "temp1", 38.0, 12.0),
    ("nvme", "temp1", 41.0, 6.0),
    ("nvme", "temp2", 39.0, 5.0),
    ("mt7925_phy0", "temp1", 44.0, 3.0),
)

# The spbm driver's power channels, as node_exporter's hwmon collector renders
# them. Emitted unconditionally even though `spbm_enabled` defaults to false:
# the harness exists to prove the dashboard's Power row works on a box that
# opted in, and dropping these would stop that row being checked at all.
# `chip` is derived from the sysfs device path, not the driver name, and
# this is the value a real Spark produces, and unguessable, which is why every
# dashboard query joins node_hwmon_sensor_label rather than naming a chip.
#
# All 14 channels, in the driver's own order, so `power11` is `pl1` here exactly
# as it is on the box. A subset would let a panel pass this harness and find
# nothing on hardware.
#
# Watts are (idle, span), and value = idle + span * busy. `busy` tops out at
# 0.65, so every span is scaled against that rather than against 1.0, which is
# what makes the peak of the cycle land on the figures measured on the reference
# box: sys_total 171 W, soc_pkg 138 W, pl1 139.7 W against its 140 W cap,
# syspl1 153 W, the GPU rail 92 W, cpu_p 10.7 W idle rising to 20.6 W.
#
# The nesting has to hold at BOTH ends of the cycle, not just at the peak: the
# rails have to stay inside soc_pkg, soc_pkg inside sys_total and sys_total
# inside dc_input at idle too. The power flow panel computes board overhead and
# uncore as differences between channels, so an idle value that breaks the
# nesting draws a box bigger than the box containing it.
SPBM_CHIP = "lnxsybus:00_nvda8800:00"
SPBM_POWER = (
    ("power1", "sys_total", 28.0, 220.0),
    ("power2", "soc_pkg", 26.0, 172.3),
    ("power3", "cpu_gpu", 25.0, 141.5),
    ("power4", "cpu_p", 10.7, 15.2),
    ("power5", "cpu_e", 1.0, 4.6),
    ("power6", "vcore", 2.0, 10.8),
    ("power7", "dc_input", 42.0, 212.3),
    ("power8", "gpu", 5.0, 133.8),
    ("power9", "prereg", 40.0, 207.7),
    # Present in the driver's channel table, unpopulated on GB10: there is no
    # DLA behind it. A channel reading a flat zero is what the box shows, and
    # panels have to survive it rather than assume every channel carries watts.
    ("power10", "dla", 0.0, 0.0),
    # `pl1` is an average of module power, so it tracks soc_pkg and grazes its
    # cap at the peak. It has to: a limit channel that never reaches its cap
    # leaves every capping panel a flat "not capped" line and untestable.
    ("power11", "pl1", 26.0, 174.9),
    ("power12", "pl2", 26.0, 174.9),
    ("power13", "syspl1", 28.0, 192.3),
    ("power14", "syspl2", 28.0, 192.3),
)

# `powerN_cap` and `powerN_max` exist only for the four limit channels, which is
# why reading a `pl1` value without the cap beside it says nothing: 140 W is the
# stock module budget and 20 W is the PD safety mode, and the channel reads the
# same way in both. `_cap` is writable on the box and clamped to `_max`.
#
# pl1's 140 W cap and 250 W firmware ceiling and syspl1's 231 W cap are measured
# on the reference box. The pl2 and syspl2 figures are placeholders shaped like
# them; no reading was taken. The driver also exposes `powerN_min`, which nothing
# queries yet.
SPBM_LIMITS = (
    ("power11", 140.0, 250.0),
    ("power12", 140.0, 250.0),
    ("power13", 231.0, 281.0),
    ("power14", 231.0, 281.0),
)

# Cumulative counters, in joules. Only these four exist in the firmware, and there
# is no sys_total accumulator, which is why whole-box energy is a gauge integral.
SPBM_ENERGY = (
    ("energy1", "pkg", "power2"),
    ("energy2", "cpu_e", "power5"),
    ("energy3", "cpu_p", "power4"),
    ("energy4", "gpu", "power8"),
)

# The driver's eight thermal zones, in its own order. `tj_max` and `dla` are the
# two that read zero: GB10 answers N/A for every thermal-limit register, so there
# is no Tjmax to report, and there is no DLA. Reproduced rather than omitted,
# because the dashboard has to exclude them explicitly and would otherwise draw
# two flat lines at zero next to real sensors.
SPBM_TEMP = (
    ("temp1", "tj_max", 0.0, 0.0),
    ("temp2", "cpu_e_clu0", 41.0, 35.0),
    ("temp3", "cpu_p_clu0", 43.0, 42.0),
    ("temp4", "cpu_e_clu1", 41.0, 35.0),
    ("temp5", "cpu_p_clu1", 43.0, 42.0),
    ("temp6", "gpu", 45.0, 57.0),
    ("temp7", "soc", 42.0, 45.0),
    ("temp8", "dla", 0.0, 0.0),
)


class Box:
    """The synthetic box. Counters advance in real time so rate() has slope."""

    def __init__(self) -> None:
        self.started = time.time()
        self.last = self.started
        self.boot_time = self.started - UPTIME_AT_START
        self.cpu_seconds = {
            (cpu, mode): 0.0 for cpu in range(CORES) for mode in CPU_MODES
        }
        self.power_cap_seconds = POWER_CAP_SECONDS_AT_START
        self.energy_joules = {label: 0.0 for _, label, _ in SPBM_ENERGY}
        self.network_bytes = {"wlP9s9": [0.0, 0.0]}
        self.lock = threading.Lock()

    def busy(self, now: float) -> float:
        """Fraction of the machine that is working, on a four-minute cycle."""
        phase = (now - self.started) / 240.0 * 2 * math.pi
        return 0.35 + 0.30 * math.sin(phase)

    def gpu_utilisation(self, now: float) -> float:
        """GPU occupancy, on a slower cycle than the CPU and offset from it."""
        phase = (now - self.started) / 300.0 * 2 * math.pi
        return max(0.02, min(0.98, 0.55 + 0.42 * math.sin(phase - 0.9)))

    @staticmethod
    def power_watts(busy: float) -> list[tuple[str, float]]:
        """Watts per power channel at a given load, keyed by sensor."""
        return [(sensor, idle + span * busy) for sensor, _, idle, span in SPBM_POWER]

    def advance(self, now: float) -> float:
        """Move the counters forward to `now`. Returns the elapsed seconds."""
        with self.lock:
            elapsed = max(0.0, now - self.last)
            self.last = now
            busy = self.busy(now)
            for cpu in range(CORES):
                # The big cores carry more of the work than the little ones,
                # which is why the CPU-busy panel reads about half of what a
                # saturated big-core cluster feels like.
                weight = busy * (1.25 if cpu < CORES // 2 else 0.75)
                weight = max(0.0, min(1.0, weight))
                self.cpu_seconds[(cpu, "idle")] += elapsed * (1.0 - weight)
                self.cpu_seconds[(cpu, "user")] += elapsed * weight * 0.80
                self.cpu_seconds[(cpu, "system")] += elapsed * weight * 0.15
                self.cpu_seconds[(cpu, "iowait")] += elapsed * weight * 0.05
            if self.gpu_utilisation(now) > 0.75:
                self.power_cap_seconds += elapsed
            watts = dict(self.power_watts(busy))
            for _, label, source in SPBM_ENERGY:
                self.energy_joules[label] += elapsed * watts[source]
            rx, tx = self.network_bytes["wlP9s9"]
            self.network_bytes["wlP9s9"] = [
                rx + elapsed * 4_000_000 * busy,
                tx + elapsed * 900_000 * busy,
            ]
            return elapsed


def render(lines: list[str], name: str, kind: str, help_text: str) -> None:
    lines.append(f"# HELP {name} {help_text}")
    lines.append(f"# TYPE {name} {kind}")


def labels(pairs: dict[str, str]) -> str:
    return "{" + ",".join(f'{k}="{v}"' for k, v in pairs.items()) + "}"


def node_metrics(box: Box) -> str:
    now = time.time()
    box.advance(now)
    busy = box.busy(now)
    lines: list[str] = []

    render(lines, "node_cpu_seconds_total", "counter", "Seconds the CPUs spent in each mode.")
    with box.lock:
        for (cpu, mode), value in sorted(box.cpu_seconds.items()):
            lines.append(
                f"node_cpu_seconds_total{labels({'cpu': str(cpu), 'mode': mode})} {value:.4f}"
            )

    render(lines, "node_memory_MemTotal_bytes", "gauge", "Total unified memory.")
    lines.append(f"node_memory_MemTotal_bytes {MEM_TOTAL}")
    used = 8 * 1024**3 + int(60 * 1024**3 * max(0.0, busy))
    render(lines, "node_memory_MemAvailable_bytes", "gauge", "Memory available without swapping.")
    lines.append(f"node_memory_MemAvailable_bytes {MEM_TOTAL - used}")
    render(lines, "node_memory_MemFree_bytes", "gauge", "Memory not in use at all.")
    lines.append(f"node_memory_MemFree_bytes {int((MEM_TOTAL - used) * 0.7)}")

    for window, damping in (("1", 1.0), ("5", 0.85), ("15", 0.7)):
        render(lines, f"node_load{window}", "gauge", f"{window}-minute load average.")
        lines.append(f"node_load{window} {CORES * busy * damping:.2f}")

    render(lines, "node_boot_time_seconds", "gauge", "Unix time of the last boot.")
    lines.append(f"node_boot_time_seconds {box.boot_time:.0f}")

    render(lines, "node_hwmon_temp_celsius", "gauge", "Hardware monitor temperature sensor.")
    for chip, sensor, base, span in HWMON_SENSORS:
        temperature = base + span * busy
        lines.append(
            f"node_hwmon_temp_celsius{labels({'chip': chip, 'sensor': sensor})} "
            f"{temperature:.2f}"
        )
    for sensor, _, base, span in SPBM_TEMP:
        lines.append(
            f"node_hwmon_temp_celsius{labels({'chip': SPBM_CHIP, 'sensor': sensor})} "
            f"{base + span * busy:.2f}"
        )

    # The spbm channels. Without the label metric the dashboard's power queries
    # match nothing: they join on it rather than naming a chip.
    watts = dict(box.power_watts(busy))
    render(lines, "node_hwmon_power_watt", "gauge", "Hardware monitor power.")
    for sensor, _, _, _ in SPBM_POWER:
        lines.append(
            f"node_hwmon_power_watt{labels({'chip': SPBM_CHIP, 'sensor': sensor})} "
            f"{watts[sensor]:.3f}"
        )
    render(lines, "node_hwmon_power_cap_watt", "gauge", "Hardware monitor power cap.")
    for sensor, cap, _ in SPBM_LIMITS:
        lines.append(
            f"node_hwmon_power_cap_watt{labels({'chip': SPBM_CHIP, 'sensor': sensor})} {cap:.3f}"
        )
    render(lines, "node_hwmon_power_max_watt", "gauge", "Hardware monitor power max.")
    for sensor, _, ceiling in SPBM_LIMITS:
        lines.append(
            f"node_hwmon_power_max_watt{labels({'chip': SPBM_CHIP, 'sensor': sensor})} "
            f"{ceiling:.3f}"
        )
    render(
        lines,
        "node_hwmon_energy_joule_total",
        "counter",
        "Hardware monitor for joules used so far.",
    )
    for sensor, label, _ in SPBM_ENERGY:
        lines.append(
            f"node_hwmon_energy_joule_total{labels({'chip': SPBM_CHIP, 'sensor': sensor})} "
            f"{box.energy_joules[label]:.3f}"
        )
    render(lines, "node_hwmon_sensor_label", "gauge", "Label for given chip and sensor.")
    for sensor, label, _, _ in SPBM_POWER:
        lines.append(
            f"node_hwmon_sensor_label"
            f"{labels({'chip': SPBM_CHIP, 'label': label, 'sensor': sensor})} 1"
        )
    for sensor, label, _ in SPBM_ENERGY:
        lines.append(
            f"node_hwmon_sensor_label"
            f"{labels({'chip': SPBM_CHIP, 'label': label, 'sensor': sensor})} 1"
        )
    for sensor, label, _, _ in SPBM_TEMP:
        lines.append(
            f"node_hwmon_sensor_label"
            f"{labels({'chip': SPBM_CHIP, 'label': label, 'sensor': sensor})} 1"
        )

    root_avail = FS_ROOT_SIZE - FS_ROOT_USED - int(20_000_000_000 * busy)
    filesystems = (
        ("/dev/nvme0n1p2", "ext4", "/", FS_ROOT_SIZE, root_avail),
        ("/dev/nvme0n1p1", "vfat", "/boot/efi", FS_BOOT_SIZE, 800_000_000),
    )
    render(lines, "node_filesystem_size_bytes", "gauge", "Filesystem size.")
    for device, fstype, mountpoint, size, _ in filesystems:
        tags = {"device": device, "fstype": fstype, "mountpoint": mountpoint}
        lines.append(f"node_filesystem_size_bytes{labels(tags)} {size}")
    render(lines, "node_filesystem_avail_bytes", "gauge", "Filesystem space available.")
    for device, fstype, mountpoint, _, avail in filesystems:
        tags = {"device": device, "fstype": fstype, "mountpoint": mountpoint}
        lines.append(f"node_filesystem_avail_bytes{labels(tags)} {avail}")

    render(lines, "node_network_receive_bytes_total", "counter", "Bytes received.")
    render(lines, "node_network_transmit_bytes_total", "counter", "Bytes transmitted.")
    with box.lock:
        for device, (rx, tx) in box.network_bytes.items():
            lines.append(f"node_network_receive_bytes_total{labels({'device': device})} {rx:.0f}")
            lines.append(f"node_network_transmit_bytes_total{labels({'device': device})} {tx:.0f}")

    render(lines, "node_uname_info", "gauge", "Labelled system information.")
    uname = {
        "machine": "aarch64",
        "nodename": "spark",
        "release": "6.17.0-1029-nvidia",
        "sysname": "Linux",
    }
    lines.append(f"node_uname_info{labels(uname)} 1")

    return "\n".join(lines) + "\n"


def gpu_metrics(box: Box) -> str:
    now = time.time()
    box.advance(now)
    utilisation = box.gpu_utilisation(now)
    tags = labels({"uuid": GPU_UUID})
    lines: list[str] = []

    def gauge(name: str, value: float, help_text: str, fmt: str = "{:.4f}") -> None:
        render(lines, name, "gauge", help_text)
        lines.append(f"{name}{tags} " + fmt.format(value))

    render(lines, "nvidia_smi_gpu_info", "gauge", "Labelled GPU identity.")
    info = {"uuid": GPU_UUID, "name": GPU_NAME, "index": "0", "driver_model_current": "N/A"}
    lines.append(f"nvidia_smi_gpu_info{labels(info)} 1")

    gauge("nvidia_smi_utilization_gpu_ratio", utilisation, "GPU occupancy, 0 to 1.")
    gauge("nvidia_smi_utilization_memory_ratio", utilisation * 0.6, "Memory controller occupancy.")
    gauge("nvidia_smi_temperature_gpu", 41.0 + 32.0 * utilisation, "GPU die temperature.", "{:.1f}")
    # Deliberately derived from the firmware's own gpu channel and then made to
    # read low, rather than from `utilisation`: nvidia-smi measured 71.9 W where
    # the firmware read 103.4 W at the same instant, and a dashboard panel exists
    # to show that gap. Driving the two from different cycles would let them
    # cross, which would teach the opposite of what was measured. Power and
    # occupancy need not be in phase, so `utilisation` keeps its own cycle.
    firmware_gpu = dict(box.power_watts(box.busy(now)))["power8"]
    gauge("nvidia_smi_power_draw_watts", 0.695 * firmware_gpu, "GPU rail power.", "{:.2f}")

    idle_hz, max_hz = 200e6, 3003e6
    clock = idle_hz + (max_hz - idle_hz) * utilisation
    gauge("nvidia_smi_clocks_current_graphics_clock_hz", clock, "Graphics clock.", "{:.0f}")
    gauge("nvidia_smi_clocks_current_sm_clock_hz", clock, "SM clock.", "{:.0f}")
    gauge("nvidia_smi_clocks_current_memory_clock_hz", 7500e6, "Memory clock.", "{:.0f}")
    gauge("nvidia_smi_clocks_max_sm_clock_hz", max_hz, "Maximum SM clock.", "{:.0f}")
    gauge("nvidia_smi_clocks_max_graphics_clock_hz", max_hz, "Maximum graphics clock.", "{:.0f}")

    # Unified memory: nvidia-smi reports [N/A] for the memory fields on GB10
    # and the exporter drops unavailable fields, so no nvidia_smi_memory_*
    # series exist here either. That absence is the honest thing to reproduce.

    capping = 1.0 if utilisation > 0.75 else 0.0
    gauge("nvidia_smi_clocks_event_reasons_sw_power_cap", capping, "Power cap active.", "{:.0f}")
    gauge("nvidia_smi_clocks_event_reasons_hw_thermal_slowdown", 0.0, "HW thermal slowdown.", "{:.0f}")
    gauge("nvidia_smi_clocks_event_reasons_sw_thermal_slowdown", 0.0, "SW thermal slowdown.", "{:.0f}")
    gauge(
        "nvidia_smi_clocks_event_reasons_gpu_idle",
        1.0 if utilisation < 0.05 else 0.0,
        "GPU idle.",
        "{:.0f}",
    )
    with box.lock:
        capped = box.power_cap_seconds
    gauge(
        "nvidia_smi_clocks_event_reasons_counters_sw_power_cap_seconds",
        capped,
        "Cumulative seconds spent power capped.",
        "{:.3f}",
    )
    gauge(
        "nvidia_smi_clocks_event_reasons_counters_hw_thermal_slowdown_seconds",
        0.0,
        "Cumulative seconds spent thermally slowed.",
        "{:.3f}",
    )

    render(lines, "nvidia_smi_command_exit_code", "gauge", "Exit code of the last nvidia-smi call.")
    lines.append("nvidia_smi_command_exit_code 0")
    render(lines, "nvidia_smi_failed_scrapes_total", "counter", "nvidia-smi calls that failed.")
    lines.append("nvidia_smi_failed_scrapes_total 0")

    return "\n".join(lines) + "\n"


def handler_for(body):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - the base class names it
            # Ignore the query string. node_exporter takes `collect[]` and
            # `exclude[]` there, which the monitoring role uses to scrape the
            # textfile collector on its own slower interval, and comparing the
            # full path would 404 every such scrape.
            path = urllib.parse.urlparse(self.path).path
            if path not in ("/metrics", "/"):
                self.send_error(404)
                return
            payload = body().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_args) -> None:
            """Quiet: Prometheus scrapes every few seconds and says so twice."""

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--node-port", type=int, required=True)
    parser.add_argument("--gpu-port", type=int, required=True)
    # Bound on every interface on purpose: Prometheus runs in a container and
    # reaches these through the host gateway, exactly as it reaches the real
    # host exporters. A loopback-only bind would be unscrapeable.
    parser.add_argument("--bind", default="0.0.0.0")  # noqa: S104
    args = parser.parse_args()

    box = Box()
    servers = [
        ThreadingHTTPServer((args.bind, args.node_port), handler_for(lambda: node_metrics(box))),
        ThreadingHTTPServer((args.bind, args.gpu_port), handler_for(lambda: gpu_metrics(box))),
    ]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print(
        f"synthetic node_exporter on :{args.node_port}/metrics, "
        f"nvidia_gpu_exporter on :{args.gpu_port}/metrics",
        flush=True,
    )
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        for server in servers:
            server.shutdown()


if __name__ == "__main__":
    main()
