#!/usr/bin/env python3
"""Validate the provisioned Grafana dashboard without a DGX Spark.

The project's rule is: never query a metric nobody emits. On a box you can
reach that rule is enforced by looking at the board. Offline it has to be
enforced by derivation, which is what this does:

1. the JSON parses, and its `uid` is the one the monitoring role tells Grafana
   to land on (`monitoring_grafana_home_dashboard`), so a renamed uid breaks
   the check rather than the home page;
2. every PromQL expression in every panel **parses**, checked by the real
   parser, `promtool`, inside the same `prom/prometheus` image the box runs.
   A hand-rolled Python parser would only be a second opinion about syntax we
   do not own;
3. every metric name a query references is one the project's exporters
   actually emit. The expected set is derived from
   `roles/exporters/defaults/main.yml` (the enabled node_exporter collector
   list and the nvidia-smi query-field list), so disabling a collector makes
   the panels that depend on it fail here.

Metric names mentioned in panel *descriptions* are deliberately not examined.
The "Unified memory" panel explains at length that
`nvidia_smi_memory_used_bytes` does not exist on unified memory; that prose is
correct and must keep passing.

With `--prometheus-url` the tool switches to a second, stronger mode: it asks a
live Prometheus to evaluate every expression and fails on any that returns no
data. That is what the local harness uses, and it catches the class of typo
that a family-prefix allowlist cannot (`node_memory_MemAvailble_bytes` is still
a `node_memory_` name).

Requires PyYAML, the one dependency, and one every machine that can run this
repo already has, because ansible depends on it.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DASHBOARD_DIR = REPO_ROOT / "roles/monitoring/files/dashboards"
# The board the monitoring role sends every visitor to. Its uid is asserted against
# monitoring_grafana_home_dashboard; the others only have to be valid.
HOME_DASHBOARD = DASHBOARD_DIR / "spark-overview.json"
GROUP_VARS = REPO_ROOT / "group_vars/all.yml"
EXPORTER_DEFAULTS = REPO_ROOT / "roles/exporters/defaults/main.yml"
MONITORING_DEFAULTS = REPO_ROOT / "roles/monitoring/defaults/main.yml"
DATASOURCE_TEMPLATE = REPO_ROOT / "roles/monitoring/templates/datasource.yml.j2"

# Grafana interpolates these before the query reaches Prometheus, so they are
# not PromQL and promtool rejects them. Substituting concrete durations checks
# the expression around them, which is the part this repo owns. Any other `$`
# is an error rather than a guess.
GRAFANA_MACROS = {
    "$__rate_interval": "5m",
    "$__interval": "1m",
    "$__range": "1h",
    # Bare seconds, not a duration: it is used as a multiplier when integrating a
    # gauge into an energy figure, so it must stay numerically consistent with
    # $__range above or the substituted expression checks arithmetic nobody runs.
    "$__range_s": "3600",
}

# node_exporter collector -> what it emits. `names` where the collector has a
# fixed output, `prefixes` where it does not: the meminfo collector names a
# series after every key in /proc/meminfo, so an exhaustive list would be a
# claim about a kernel rather than about node_exporter. The prefix is the
# honest statement of what enabling the collector guarantees; the
# --prometheus-url mode is what catches a misspelling inside a real family.
NODE_COLLECTORS = {
    "cpu": {"prefixes": ["node_cpu_"]},
    "meminfo": {"prefixes": ["node_memory_"]},
    "loadavg": {"names": ["node_load1", "node_load5", "node_load15"]},
    "hwmon": {"prefixes": ["node_hwmon_"]},
    "thermal_zone": {"prefixes": ["node_thermal_zone_", "node_cooling_device_"]},
    "netdev": {"prefixes": ["node_network_"]},
    "uname": {"names": ["node_uname_info"]},
    "os": {"prefixes": ["node_os_"]},
    # The textfile collector serves whatever a .prom file in the textfile
    # directory contains, so it cannot constrain a name. It contributes only
    # its own health series; a dashboard querying a textfile metric has to
    # account for it some other way, and will fail here until it does.
    "textfile": {"prefixes": ["node_textfile_"]},
    "filesystem": {"prefixes": ["node_filesystem_"]},
    "stat": {
        "names": [
            "node_boot_time_seconds",
            "node_context_switches_total",
            "node_forks_total",
            "node_intr_total",
            "node_procs_blocked",
            "node_procs_running",
        ]
    },
}

# Emitted whatever the collector set is.
NODE_ALWAYS = [
    "node_exporter_build_info",
    "node_scrape_collector_duration_seconds",
    "node_scrape_collector_success",
]

# nvidia-smi query field -> the series utkuozdemir/nvidia_gpu_exporter emits
# for it. The exporter derives the name from the field and the unit in
# nvidia-smi's CSV header, which is not knowable offline, so the mapping is
# written down instead. The throttle-reason half of this table is the one
# documented in roles/exporters/README.md.
GPU_FIELD_METRICS = {
    "utilization.gpu": ["nvidia_smi_utilization_gpu_ratio"],
    "utilization.memory": ["nvidia_smi_utilization_memory_ratio"],
    "temperature.gpu": ["nvidia_smi_temperature_gpu"],
    "power.draw": ["nvidia_smi_power_draw_watts"],
    "power.limit": ["nvidia_smi_power_limit_watts"],
    "enforced.power.limit": ["nvidia_smi_enforced_power_limit_watts"],
    "clocks.current.graphics": ["nvidia_smi_clocks_current_graphics_clock_hz"],
    "clocks.current.sm": ["nvidia_smi_clocks_current_sm_clock_hz"],
    "clocks.current.memory": ["nvidia_smi_clocks_current_memory_clock_hz"],
    "clocks.current.video": ["nvidia_smi_clocks_current_video_clock_hz"],
    "clocks.max.sm": ["nvidia_smi_clocks_max_sm_clock_hz"],
    "clocks.max.graphics": ["nvidia_smi_clocks_max_graphics_clock_hz"],
    "pstate": ["nvidia_smi_pstate"],
    "persistence_mode": ["nvidia_smi_persistence_mode"],
    "compute_mode": ["nvidia_smi_compute_mode"],
    "fan.speed": ["nvidia_smi_fan_speed_ratio"],
    "clocks_event_reasons.supported": ["nvidia_smi_clocks_event_reasons_supported"],
    "clocks_event_reasons.active": ["nvidia_smi_clocks_event_reasons_active"],
    "clocks_event_reasons.gpu_idle": ["nvidia_smi_clocks_event_reasons_gpu_idle"],
    "clocks_event_reasons.applications_clocks_setting": [
        "nvidia_smi_clocks_event_reasons_applications_clocks_setting"
    ],
    "clocks_event_reasons.sw_power_cap": ["nvidia_smi_clocks_event_reasons_sw_power_cap"],
    "clocks_event_reasons.hw_slowdown": ["nvidia_smi_clocks_event_reasons_hw_slowdown"],
    "clocks_event_reasons.hw_thermal_slowdown": [
        "nvidia_smi_clocks_event_reasons_hw_thermal_slowdown"
    ],
    "clocks_event_reasons.hw_power_brake_slowdown": [
        "nvidia_smi_clocks_event_reasons_hw_power_brake_slowdown"
    ],
    "clocks_event_reasons.sw_thermal_slowdown": [
        "nvidia_smi_clocks_event_reasons_sw_thermal_slowdown"
    ],
    "clocks_event_reasons.sync_boost": ["nvidia_smi_clocks_event_reasons_sync_boost"],
    # The counter family is rescaled from microseconds and carries _seconds.
    "clocks_event_reasons_counters.sw_power_cap": [
        "nvidia_smi_clocks_event_reasons_counters_sw_power_cap_seconds"
    ],
    "clocks_event_reasons_counters.sw_thermal_slowdown": [
        "nvidia_smi_clocks_event_reasons_counters_sw_thermal_slowdown_seconds"
    ],
    "clocks_event_reasons_counters.hw_thermal_slowdown": [
        "nvidia_smi_clocks_event_reasons_counters_hw_thermal_slowdown_seconds"
    ],
    "clocks_event_reasons_counters.hw_power_brake_slowdown": [
        "nvidia_smi_clocks_event_reasons_counters_hw_power_brake_slowdown_seconds"
    ],
    "clocks_event_reasons_counters.sync_boost": [
        "nvidia_smi_clocks_event_reasons_counters_sync_boost_seconds"
    ],
}

# The exporter appends the GPU identity fields itself, whatever was queried.
GPU_ALWAYS = [
    "nvidia_smi_command_exit_code",
    "nvidia_smi_failed_scrapes_total",
    "nvidia_smi_gpu_info",
]

# Synthesised by the Prometheus server for every target, so they are available
# regardless of what any exporter emits.
# Synthesised by the Prometheus server rather than scraped from anything: ALERTS
# is materialised from the loaded alerting rules, so a panel may query it even
# though no exporter emits it.
PROMETHEUS_SYNTHETIC_METRICS = [
    "ALERTS",
    "ALERTS_FOR_STATE",
]

PROMETHEUS_SCRAPE_METRICS = [
    "scrape_body_size_bytes",
    "scrape_duration_seconds",
    "scrape_samples_post_metric_relabeling",
    "scrape_samples_scraped",
    "scrape_series_added",
    "scrape_timeout_seconds",
    "up",
]

PROMQL_FUNCTIONS = {
    "abs", "absent", "absent_over_time", "acos", "acosh", "asin", "asinh",
    "atan", "atanh", "avg_over_time", "ceil", "changes", "clamp", "clamp_max",
    "clamp_min", "cos", "cosh", "count_over_time", "day_of_month",
    "day_of_week", "day_of_year", "days_in_month", "deg", "delta", "deriv",
    "double_exponential_smoothing", "exp", "floor", "histogram_avg",
    "histogram_count", "histogram_fraction", "histogram_quantile",
    "histogram_stddev", "histogram_stdvar", "histogram_sum", "holt_winters",
    "hour", "idelta", "increase", "info", "irate", "label_join",
    "label_replace", "last_over_time", "ln", "log10", "log2", "mad_over_time",
    "max_over_time", "min_over_time", "minute", "month", "pi",
    "predict_linear", "present_over_time", "quantile_over_time", "rad", "rate",
    "resets", "round", "scalar", "sgn", "sin", "sinh", "sort", "sort_by_label",
    "sort_by_label_desc", "sort_desc", "sqrt", "stddev_over_time",
    "stdvar_over_time", "sum_over_time", "tan", "tanh", "time", "timestamp",
    "vector", "year",
}

PROMQL_AGGREGATORS = {
    "avg", "bottomk", "count", "count_values", "group", "limit_ratio", "limitk",
    "max", "min", "quantile", "stddev", "stdvar", "sum", "topk",
}

PROMQL_KEYWORDS = {
    "and", "atan2", "bool", "by", "end", "group_left", "group_right",
    "ignoring", "offset", "on", "or", "start", "unless", "without",
}

IDENTIFIER = re.compile(r"[a-zA-Z_:][a-zA-Z0-9_:]*")


class CheckFailed(Exception):
    """A check failed for a reason the operator has to fix."""


def load_yaml(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def expected_metrics(collectors: list[str], gpu_fields: list[str]) -> tuple[set[str], set[str]]:
    """Turn the enabled collector and query-field lists into what may be queried."""
    names = (set(NODE_ALWAYS) | set(GPU_ALWAYS) | set(PROMETHEUS_SCRAPE_METRICS)
             | set(PROMETHEUS_SYNTHETIC_METRICS))
    prefixes: set[str] = set()

    unmapped = [c for c in collectors if c not in NODE_COLLECTORS]
    if unmapped:
        raise CheckFailed(
            "node_exporter collectors enabled in roles/exporters/defaults/main.yml "
            f"that this check has no metric mapping for: {', '.join(sorted(unmapped))}. "
            "Add them to NODE_COLLECTORS."
        )
    for collector in collectors:
        entry = NODE_COLLECTORS[collector]
        names.update(entry.get("names", []))
        prefixes.update(entry.get("prefixes", []))

    unmapped = [f for f in gpu_fields if f not in GPU_FIELD_METRICS]
    if unmapped:
        raise CheckFailed(
            "nvidia-smi query fields in roles/exporters/defaults/main.yml that this "
            f"check has no metric mapping for: {', '.join(sorted(unmapped))}. "
            "Add them to GPU_FIELD_METRICS."
        )
    for field in gpu_fields:
        names.update(GPU_FIELD_METRICS[field])

    return names, prefixes


def walk_panels(node: object) -> list[dict]:
    """Every panel anywhere in the dashboard, including inside collapsed rows.

    A row exported while collapsed carries its children in row["panels"] instead
    of at the top level. Iterating dashboard["panels"] alone would stop checking
    them the moment somebody collapses a row in the UI and re-exports, which is
    a silent loss of coverage rather than a failure.
    """
    found: list[dict] = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "panels" and isinstance(value, list):
                found.extend(p for p in value if isinstance(p, dict))
            found.extend(walk_panels(value))
    elif isinstance(node, list):
        for value in node:
            found.extend(walk_panels(value))
    return found


def annotation_targets(dashboard: dict) -> list[tuple[str, str, str]]:
    """The annotation queries, which are checked differently from panels.

    An annotation that matches nothing is the correct state: `ALERTS` exists only
    while something is firing, and a box with no events is the box we want. So
    these are parsed by promtool and held to the metric allowlist like everything
    else, but exempt from the --prometheus-url emptiness check, which would
    otherwise demand that a healthy harness be alerting.
    """
    found = []
    for index, annotation in enumerate(dashboard.get("annotations", {}).get("list", [])):
        if isinstance(annotation.get("expr"), str):
            name = annotation.get("name", f"#{index}")
            found.append((f"annotation {name!r}", "expr", annotation["expr"]))
    return found


def walk_targets(node: object, panel: str = "dashboard") -> list[tuple[str, str, str]]:
    """Collect (panel, refId, expr) from anywhere in the dashboard JSON.

    Recursive rather than a fixed panels[].targets[] walk, so a query hidden in
    a collapsed row's nested panels cannot slip past unchecked.
    """
    found: list[tuple[str, str, str]] = []
    if isinstance(node, dict):
        if "title" in node and "type" in node:
            panel = f"{node.get('type')} #{node.get('id')} {node.get('title')!r}"
        if isinstance(node.get("expr"), str):
            found.append((panel, str(node.get("refId", "?")), node["expr"]))
        for value in node.values():
            found.extend(walk_targets(value, panel))
    elif isinstance(node, list):
        for value in node:
            found.extend(walk_targets(value, panel))
    return found


def substitute_macros(expr: str) -> str:
    # Longest first: `$__range_s` starts with `$__range`, and substituting the
    # shorter one first would leave the literal `1h_s` behind for promtool.
    for macro in sorted(GRAFANA_MACROS, key=len, reverse=True):
        expr = expr.replace(macro, GRAFANA_MACROS[macro])
    if "$" in expr:
        raise CheckFailed(
            f"expression uses a Grafana variable this check cannot interpolate: {expr!r}"
        )
    return expr


def strip_literals(expr: str) -> str:
    """Blank out string literals so their contents are never read as identifiers."""
    return re.sub(r"\"[^\"]*\"|'[^']*'|`[^`]*`", " ", expr)


def metric_names(expr: str) -> set[str]:
    """The metric names an expression selects.

    promtool has already accepted the expression as PromQL by the time this
    runs, so this only has to classify identifiers, not validate grammar. It
    fails closed: an identifier it cannot place becomes a metric name and is
    then checked against the allowlist, and an unknown call becomes an error.
    """
    if "__name__" in expr:
        raise CheckFailed(
            f"expression selects by __name__, which this check cannot resolve: {expr!r}"
        )
    text = strip_literals(expr)
    text = re.sub(r"\{[^{}]*\}", " ", text)  # label matchers
    text = re.sub(r"\[[^\[\]]*\]", " ", text)  # range and subquery windows
    # Label lists attached to aggregations and to vector matching: `by (cpu)`,
    # `on (instance)`, `group_left(job)`. Their contents are label names.
    text = re.sub(
        r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^()]*\)", " ", text
    )

    names: set[str] = set()
    for match in IDENTIFIER.finditer(text):
        token = match.group(0)
        rest = text[match.end():].lstrip()
        if rest.startswith("("):
            if token not in PROMQL_FUNCTIONS and token not in PROMQL_AGGREGATORS:
                raise CheckFailed(
                    f"{token!r} is called like a function but is not one this check "
                    f"knows, in: {expr!r}"
                )
            continue
        if token in PROMQL_KEYWORDS:
            continue
        names.add(token)
    return names


def promtool_parse(image: str, exprs: list[tuple[str, str, str]]) -> None:
    """Parse every expression with the real PromQL parser.

    The expressions are handed to `promtool check rules` as one generated rule
    file: one container start for the whole dashboard, and promtool names the
    rule it could not parse, which maps back to the panel.
    """
    labelled = []
    for index, (panel, ref, expr) in enumerate(exprs):
        labelled.append((f"dashboard:expr:{index}", panel, ref, substitute_macros(expr)))

    rules = {
        "groups": [
            {
                "name": "spark_overview_panels",
                "rules": [{"record": name, "expr": expr} for name, _, _, expr in labelled],
            }
        ]
    }

    # Piped in rather than bind-mounted. A mount would need the Docker daemon
    # to see this filesystem, which it does not when the check itself runs in a
    # container against a mounted socket, a normal CI shape, and one where the
    # mount silently resolves to an empty directory.
    result = subprocess.run(
        [
            "docker", "run", "--rm", "--interactive",
            "--entrypoint", "sh",
            image,
            "-c", "cat > /tmp/rules.yml && exec promtool check rules /tmp/rules.yml",
        ],
        input=yaml.safe_dump(rules, sort_keys=False),
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip().replace('/tmp/rules.yml', 'panel queries')
        for name, panel, ref, _ in labelled:
            detail = detail.replace(f'"{name}"', f"{panel} target {ref}")
        raise CheckFailed(f"promtool rejected a panel query:\n{detail}")
    print(f"  promtool ({image}) parsed {len(labelled)} expressions: "
          f"{result.stdout.strip().splitlines()[-1].strip()}")


def query_prometheus(url: str, expr: str) -> list:
    endpoint = url.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(endpoint, timeout=10) as response:  # noqa: S310
        payload = json.load(response)
    if payload.get("status") != "success":
        raise CheckFailed(f"Prometheus refused {expr!r}: {payload.get('error')}")
    return payload["data"]["result"]


def check_against_prometheus(url: str, exprs: list[tuple[str, str, str]]) -> list[str]:
    """Every panel query must return data from a Prometheus holding the synthetic feed."""
    problems = []
    for panel, ref, expr in exprs:
        resolved = substitute_macros(expr)
        try:
            result = query_prometheus(url, resolved)
        except (urllib.error.URLError, TimeoutError) as error:
            raise CheckFailed(f"cannot reach Prometheus at {url}: {error}") from error
        if result:
            print(f"  OK    {panel} target {ref}: {len(result)} series")
        else:
            problems.append(f"{panel} target {ref} returned no data: {resolved}")
            print(f"  EMPTY {panel} target {ref}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--prometheus-url",
        help="evaluate every panel query against this Prometheus and fail on empty "
             "results, instead of the offline parse and allowlist checks",
    )
    args = parser.parse_args()

    paths = sorted(DASHBOARD_DIR.glob("*.json"))
    if not paths:
        print(f"FAIL no dashboards in {DASHBOARD_DIR.relative_to(REPO_ROOT)}")
        return 1

    dashboards = {}
    for path in paths:
        try:
            dashboards[path] = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            print(f"FAIL {path.relative_to(REPO_ROOT)} is not valid JSON: {error}")
            return 1

    exprs = []
    annotations = []
    for path, dashboard in dashboards.items():
        annotations.extend(
            (f"{path.stem} {label}", ref, expr)
            for label, ref, expr in annotation_targets(dashboard)
        )
        # Walk everything except the annotations list, which is collected above and
        # judged by a different standard.
        panels_only = {k: v for k, v in dashboard.items() if k != "annotations"}
        found = walk_targets(panels_only)
        if not found:
            print(f"FAIL {path.relative_to(REPO_ROOT)} has no panel queries at all")
            return 1
        # Prefix the panel label so a failure names which board it is on.
        exprs.extend((f"{path.stem} {panel}", ref, expr) for panel, ref, expr in found)

    try:
        if args.prometheus_url:
            print(f"Evaluating {len(exprs)} panel queries against {args.prometheus_url}")
            if annotations:
                print(f"  ({len(annotations)} annotation queries exempt: matching nothing is "
                      f"the healthy state)")
            problems = check_against_prometheus(args.prometheus_url, exprs)
            if problems:
                print("\nFAIL panels with no data:")
                for problem in problems:
                    print(f"  - {problem}")
                return 1
            print(f"\nPASS all {len(exprs)} panel queries returned data")
            return 0

        return offline_checks(dashboards, exprs + annotations)
    except CheckFailed as error:
        print(f"FAIL {error}")
        return 1


def offline_checks(dashboards: dict, exprs: list[tuple[str, str, str]]) -> int:
    group_vars = load_yaml(GROUP_VARS)
    exporter_defaults = load_yaml(EXPORTER_DEFAULTS)
    monitoring_defaults = load_yaml(MONITORING_DEFAULTS)

    for path in dashboards:
        print(f"Checking {path.relative_to(REPO_ROOT)}")

    # The uid is not decoration: monitoring_grafana_home_dashboard sends every
    # anonymous visitor to /d/<uid>/..., so renaming it silently empties the
    # landing page.
    home = monitoring_defaults.get("monitoring_grafana_home_dashboard", "")
    match = re.match(r"^/d/([^/]+)/", home)
    if not match:
        raise CheckFailed(
            "monitoring_grafana_home_dashboard in roles/monitoring/defaults/main.yml "
            f"is not a /d/<uid>/<slug> path: {home!r}"
        )
    expected_uid = match.group(1)
    home = dashboards[HOME_DASHBOARD]
    if home.get("uid") != expected_uid:
        raise CheckFailed(
            f"{HOME_DASHBOARD.name} uid is {home.get('uid')!r} but Grafana is told to open "
            f"{monitoring_defaults.get('monitoring_grafana_home_dashboard')!r}, which needs uid "
            f"{expected_uid!r}"
        )
    print(f"  uid {expected_uid!r} matches monitoring_grafana_home_dashboard")

    # Uids have to be distinct across files: two dashboards claiming one uid means
    # whichever the provider reads last silently wins.
    uids = {path: d.get("uid") for path, d in dashboards.items()}
    if len(set(uids.values())) != len(uids):
        raise CheckFailed(f"two dashboards share a uid: {uids}")

    all_panels = []
    for path, dashboard in dashboards.items():
        panels = walk_panels(dashboard)
        ids = [p.get("id") for p in panels]
        duplicates = {i for i in ids if ids.count(i) > 1}
        if duplicates:
            raise CheckFailed(f"{path.name} panel ids are not unique: {sorted(duplicates)}")
        all_panels.extend(panels)

    # Panels reference the datasource by uid. The monitoring role provisions
    # exactly one, and its uid is fixed in the template.
    datasource_uid = re.search(
        r"^\s*uid:\s*(\S+)\s*$", DATASOURCE_TEMPLATE.read_text(encoding="utf-8"), re.MULTILINE
    )
    if not datasource_uid:
        raise CheckFailed(f"no datasource uid found in {DATASOURCE_TEMPLATE}")
    wrong = {
        json.dumps(p.get("datasource"))
        for p in all_panels
        if p.get("datasource") and p["datasource"].get("uid") != datasource_uid.group(1)
    }
    if wrong:
        raise CheckFailed(
            f"panels reference a datasource other than uid {datasource_uid.group(1)!r}: "
            f"{sorted(wrong)}"
        )
    print(f"  every panel uses the provisioned datasource uid {datasource_uid.group(1)!r}")

    image = group_vars.get("prometheus_image")
    if not image:
        raise CheckFailed("group_vars/all.yml does not set prometheus_image")
    promtool_parse(image, exprs)

    allowed_names, allowed_prefixes = expected_metrics(
        exporter_defaults.get("exporters_node_collectors", []),
        exporter_defaults.get("exporters_gpu_query_fields", []),
    )

    unaccounted: list[str] = []
    referenced: set[str] = set()
    for panel, ref, expr in exprs:
        for name in sorted(metric_names(substitute_macros(expr))):
            referenced.add(name)
            if name in allowed_names:
                continue
            if any(name.startswith(prefix) for prefix in allowed_prefixes):
                continue
            unaccounted.append(f"{panel} target {ref} queries {name!r}")

    if unaccounted:
        raise CheckFailed(
            "metrics no enabled exporter accounts for:\n  - "
            + "\n  - ".join(unaccounted)
            + "\n\nEither the panel is wrong, or the collector or nvidia-smi query "
            "field that emits it is missing from roles/exporters/defaults/main.yml."
        )

    print(f"  all {len(referenced)} referenced metrics are emitted by the enabled exporters")
    print(f"\nPASS {len(exprs)} panel queries across {len(dashboards)} dashboards")
    return 0


if __name__ == "__main__":
    sys.exit(main())
