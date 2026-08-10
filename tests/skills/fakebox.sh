#!/usr/bin/env bash
# Build a fake DGX Spark for one scenario, into $1.
#
# The skills under test read three things: `make report`, the spbm hwmon channels
# under /sys/class/hwmon, and nvidia-smi. All three are faked here from one table
# of microwatt values, so a scenario is a set of numbers rather than three
# hand-written fixtures that can disagree with each other.
#
# Every figure is one measured on the reference box, or the documented safety-mode
# value. See INSTALL_CLAUDE.md, "What the box can actually draw".
set -euo pipefail

SCENARIO="${1:?scenario}"
OUT="${2:?output directory}"

# label input cap max, in microwatts. Empty cap/max for the ten telemetry
# channels: only the four limit channels carry them, which is the whole point of
# the diagnosis.
case "${SCENARIO}" in
    pd-safety-mode)
        # A failed USB-C PD negotiation. The caps themselves collapse, and the GPU
        # sits near 500 MHz no matter what the workload asks for.
        CHANNELS="
sys_total 28000000 - -
soc_pkg 21000000 - -
cpu_gpu 12000000 - -
cpu_p 6000000 - -
cpu_e 500000 - -
vcore 3000000 - -
dc_input 27500000 - -
gpu 8000000 - -
prereg 6000000 - -
dla 10000 - -
pl1 19800000 20000000 250000000
pl2 19900000 20000000 250000000
syspl1 27000000 30000000 300000000
syspl2 27500000 30000000 300000000
"
        GPU_UTIL=99; GPU_TEMP=44; SM_CLOCK=495; GFX_CLOCK=495; SMI_POWER=7.90
        GPU_ZONE=44000
        ;;
    at-the-cap)
        # Saturated with a dense bf16 GEMM. pl1 pinned at its cap, which is the
        # box working as designed, and nvidia-smi reading the rail 30-44% low.
        CHANNELS="
sys_total 170800000 - -
soc_pkg 137900000 - -
cpu_gpu 116000000 - -
cpu_p 20600000 - -
cpu_e 4000000 - -
vcore 9000000 - -
dc_input 175000000 - -
gpu 91700000 - -
prereg 30000000 - -
dla 10000 - -
pl1 139700000 140000000 250000000
pl2 140100000 142000000 250000000
syspl1 153000000 231000000 300000000
syspl2 150000000 244000000 300000000
"
        GPU_UTIL=100; GPU_TEMP=82; SM_CLOCK=2418; GFX_CLOCK=2418; SMI_POWER=71.90
        GPU_ZONE=82000
        ;;
    below-cap)
        # A training job that is not compute-bound. Everything healthy, pl1 well
        # short of its cap: a symptom to explain, not headroom to reclaim.
        CHANNELS="
sys_total 139000000 - -
soc_pkg 112000000 - -
cpu_gpu 92000000 - -
cpu_p 14000000 - -
cpu_e 2000000 - -
vcore 7000000 - -
dc_input 142000000 - -
gpu 70000000 - -
prereg 24000000 - -
dla 10000 - -
pl1 117000000 140000000 250000000
pl2 118000000 142000000 250000000
syspl1 131000000 231000000 300000000
syspl2 128000000 244000000 300000000
"
        GPU_UTIL=92; GPU_TEMP=68; SM_CLOCK=2418; GFX_CLOCK=2418; SMI_POWER=48.30
        GPU_ZONE=68000
        ;;
    contended-benchmark)
        # Healthy box, mid load, and something else already on the GPU. The
        # benchmark skill's first trap: a contended measurement is valid for peak
        # power and worthless for throughput.
        CHANNELS="
sys_total 132000000 - -
soc_pkg 106000000 - -
cpu_gpu 88000000 - -
cpu_p 13000000 - -
cpu_e 2000000 - -
vcore 7000000 - -
dc_input 135000000 - -
gpu 67000000 - -
prereg 23000000 - -
dla 10000 - -
pl1 111000000 140000000 250000000
pl2 112000000 142000000 250000000
syspl1 125000000 231000000 300000000
syspl2 122000000 244000000 300000000
"
        GPU_UTIL=88; GPU_TEMP=66; SM_CLOCK=2418; GFX_CLOCK=2418; SMI_POWER=46.10
        GPU_ZONE=66000
        ;;
    *)
        echo "unknown scenario: ${SCENARIO}" >&2
        exit 2
        ;;
esac

HWMON="${OUT}/hwmon/hwmon6"
mkdir -p "${HWMON}" "${OUT}/bin"
echo spbm >"${HWMON}/name"

index=0
while read -r label input cap max; do
    [ -n "${label}" ] || continue
    index=$((index + 1))
    echo "${label}" >"${HWMON}/power${index}_label"
    echo "${input}" >"${HWMON}/power${index}_input"
    [ "${cap}" = "-" ] || echo "${cap}" >"${HWMON}/power${index}_cap"
    [ "${max}" = "-" ] || echo "${max}" >"${HWMON}/power${index}_max"
done <<<"${CHANNELS}"

# The eight thermal zones, in the driver's order. tj_max tracks the gpu zone; it
# is a temperature despite the name.
zone=0
while read -r label millidegrees; do
    [ -n "${label}" ] || continue
    zone=$((zone + 1))
    echo "${label}" >"${HWMON}/temp${zone}_label"
    echo "${millidegrees}" >"${HWMON}/temp${zone}_input"
done <<EOF
tj_max ${GPU_ZONE}
cpu_e_clu0 $((GPU_ZONE - 12000))
cpu_p_clu0 $((GPU_ZONE - 10000))
cpu_e_clu1 $((GPU_ZONE - 12000))
cpu_p_clu1 $((GPU_ZONE - 10000))
gpu ${GPU_ZONE}
soc $((GPU_ZONE - 8000))
dla 27290
EOF

# nvidia-smi, which on this hardware is the instrument that lies: it reads the
# rail low and reports Not Active through a throttle the EC is enforcing. A skill
# that trusts it fails the test, so the fake has to be convincingly wrong.
cat >"${OUT}/bin/nvidia-smi" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\${args}" in
    *--query-compute-apps*)
        echo "pid, process_name, used_memory [MiB]"
        echo "4711, python3, 41216 MiB"
        ;;
    # Ahead of the -q branch on purpose: "--query-gpu" contains "-q", and having
    # the verbose branch first sent every CSV query to the wrong output.
    *--query-gpu=*)
        fields="\${args#*--query-gpu=}"
        fields="\${fields%% *}"
        out=""
        IFS=, read -ra wanted <<<"\${fields}"
        for f in "\${wanted[@]}"; do
            case "\$f" in
                name) v="NVIDIA GB10" ;;
                utilization.gpu) v="${GPU_UTIL} %" ;;
                temperature.gpu) v="${GPU_TEMP}" ;;
                power.draw) v="${SMI_POWER} W" ;;
                power.limit|enforced.power.limit) v="[N/A]" ;;
                clocks.current.sm|clocks.sm) v="${SM_CLOCK} MHz" ;;
                clocks.current.graphics|clocks.gr) v="${GFX_CLOCK} MHz" ;;
                clocks.max.sm) v="3003 MHz" ;;
                memory.total|memory.used) v="[N/A]" ;;
                driver_version) v="580.95.05" ;;
                compute_cap) v="12.1" ;;
                *) v="[N/A]" ;;
            esac
            out="\${out:+\${out}, }\${v}"
        done
        case "\${args}" in *noheader*) ;; *) echo "\${fields}" ;; esac
        echo "\${out}"
        ;;
    *-d\ PERFORMANCE*|*-d\ TEMPERATURE*|*-q*)
        cat <<'REPORT'
==============NVSMI LOG==============

GPU 00000000:01:00.0
    Clocks Event Reasons
        Idle                              : Not Active
        Applications Clocks Setting       : Not Active
        SW Power Cap                      : Not Active
        HW Slowdown                       : Not Active
            HW Thermal Slowdown           : Not Active
            HW Power Brake Slowdown       : Not Active
        Sync Boost                        : Not Active
        SW Thermal Slowdown               : Not Active
    Temperature
        GPU Current Temp                  : ${GPU_TEMP} C
        GPU Shutdown Temp                 : N/A
        GPU Slowdown Temp                 : N/A
        GPU Max Operating Temp            : N/A
    Power Readings
        Power Draw                        : ${SMI_POWER} W
        Current Power Limit               : N/A
        Requested Power Limit             : N/A
        Default Power Limit               : N/A
        Min Power Limit                   : N/A
        Max Power Limit                   : N/A
    Clocks
        Graphics                          : ${GFX_CLOCK} MHz
        SM                                : ${SM_CLOCK} MHz
        Memory                            : 7500 MHz
    Max Clocks
        Graphics                          : 3003 MHz
        SM                                : 3003 MHz
    Default Applications Clocks
        Graphics                          : 2418 MHz
REPORT
        ;;
    *)
        echo "Fri Aug 10 12:00:00 2026"
        echo "NVIDIA GB10   Driver Version: 580.95.05"
        echo "GPU  Util ${GPU_UTIL}%   Temp ${GPU_TEMP}C   Pwr ${SMI_POWER}W / N/A   SM ${SM_CLOCK} MHz"
        ;;
esac
EOF
chmod +x "${OUT}/bin/nvidia-smi"

# `make report` is step 1 of the diagnosis skill, so the fake box has to answer
# it in the shape the real role prints: reading, then cap, then ceiling.
cat >"${OUT}/Makefile" <<'EOF'
.PHONY: report
report:
	@./report.sh
EOF

cat >"${OUT}/report.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "    MACHINE"
echo "      Product              NVIDIA DGX Spark"
echo "      OS                   Ubuntu 24.04"
echo "      Kernel               6.11.0-1008-nvidia (aarch64)"
echo
echo "    GPU"
nvidia-smi --query-gpu=name,driver_version,power.draw,power.limit --format=csv,noheader |
    sed 's/^/      /'
echo
echo "    WHOLE-SYSTEM POWER"
echo "      spbm module          loaded"
echo "      hwmon devices"
for input in /sys/class/hwmon/hwmon*/power*_input; do
    [ -e "${input}" ] || continue
    base="${input%_input}"
    label="$(cat "${base}_label" 2>/dev/null)" || label="${input}"
    cap="$(cat "${base}_cap" 2>/dev/null)" || cap=""
    max="$(cat "${base}_max" 2>/dev/null)" || max=""
    awk -v name="${label}" -v reading="$(cat "${input}")" -v cap="${cap}" -v max="${max}" \
        'BEGIN {
             printf "        %-12s %8.2f W", name, reading / 1000000
             if (cap != "") printf "   cap %5.0f W", cap / 1000000
             if (max != "") printf "   ceiling %5.0f W", max / 1000000
             printf "\n"
         }'
done
EOF
chmod +x "${OUT}/report.sh"

echo "fake box for '${SCENARIO}' in ${OUT}"
