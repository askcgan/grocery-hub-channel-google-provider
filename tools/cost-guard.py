#!/usr/bin/env python3
"""
Cost guard for every Terraform stack in grocery-hub-channel-google-provider.

Reads a saved plan as JSON (terraform show -json tfplan) and refuses it when it would create or change a resource
into a known expensive shape: big or highly-available Cloud SQL, always-on Cloud Run, clusters, VMs bigger than
e2-small, load balancers, NAT, and the like. The plan scripts run it after every plan and again before every apply,
so a template nobody reviewed can't quietly start billing hundreds of dollars a month.

    terraform show -json tfplan > tfplan.json && python3 tools/cost-guard.py tfplan.json

A blocked rule can be allowed on purpose, for one run, after a cost review:
    COST_GUARD_ALLOW=sql-tier,load-balancer ./scripts/plan.sh
Exit status: 0 = allowed, 1 = blocked, 2 = could not read the plan.
"""
import json
import os
import re
import sys

# Small Cloud SQL tiers: shared-core and 1–2 vCPU custom machines (about $9–100 a month single-zone).
SQL_TIERS = re.compile(r"^(db-f1-micro|db-g1-small|db-custom-[12]-[0-9]+)$")
SMALL_VMS = {"e2-micro", "e2-small", "f1-micro", "g1-small"}
RUN_MAX_INSTANCES = 10
RUN_MAX_CPU = 4.0

# Resource types that are expensive by nature (fixed hourly cost whatever the load). Rule id → (types, why).
EXPENSIVE_TYPES = {
    "cluster": ({"google_container_cluster", "google_container_node_pool"}, "GKE: a cluster fee plus node VMs, ~$75+/month"),
    "alloydb": ({"google_alloydb_cluster", "google_alloydb_instance"}, "AlloyDB: hundreds of dollars a month per instance"),
    "spanner": ({"google_spanner_instance"}, "Spanner: ~$65+/month even at the smallest size"),
    "bigtable": ({"google_bigtable_instance"}, "Bigtable: ~$470/month per node"),
    "redis": ({"google_redis_instance", "google_redis_cluster", "google_memcache_instance"}, "Memorystore: billed every hour, ~$35+/month"),
    "load-balancer": ({"google_compute_global_forwarding_rule", "google_compute_forwarding_rule"}, "load balancer forwarding rule: ~$18+/month fixed"),
    "nat": ({"google_compute_router_nat"}, "Cloud NAT gateway: ~$32+/month fixed"),
    "vpc-connector": ({"google_vpc_access_connector"}, "Serverless VPC connector: at least 2 always-on instances, ~$15+/month"),
    "dataproc": ({"google_dataproc_cluster"}, "Dataproc cluster VMs"),
    "notebooks": ({"google_workbench_instance", "google_notebooks_instance"}, "always-on notebook VM"),
    "vertex-endpoint": ({"google_vertex_ai_endpoint"}, "Vertex AI endpoint with deployed models"),
}


def first(value, default=None):
    """Terraform plan JSON nests single blocks as one-item lists."""
    if isinstance(value, list):
        return value[0] if value else default
    return value if value is not None else default


def cpu_value(text):
    if not text:
        return 0.0
    text = str(text)
    return float(text[:-1]) / 1000 if text.endswith("m") else float(text)


def check(rc):
    """Findings for one resource change: [(rule id, message)]."""
    t, after = rc["type"], rc["change"].get("after") or {}
    out = []
    for rule, (types, why) in EXPENSIVE_TYPES.items():
        if t in types:
            out.append((rule, why))

    if t == "google_sql_database_instance":
        s = first(after.get("settings"), {}) or {}
        tier, edition, avail = s.get("tier") or "", s.get("edition") or "ENTERPRISE", s.get("availability_type") or "ZONAL"
        if not SQL_TIERS.match(tier):
            out.append(("sql-tier", f"Cloud SQL tier {tier or '(unknown)'}: only db-f1-micro, db-g1-small or 1–2 vCPU custom tiers pass"))
        if edition == "ENTERPRISE_PLUS":
            out.append(("sql-enterprise-plus", "Cloud SQL Enterprise Plus edition: performance tiers start at hundreds of dollars a month"))
        if avail == "REGIONAL":
            out.append(("sql-ha", "Cloud SQL regional (high availability): doubles the instance cost"))
        if (first(s.get("data_cache_config"), {}) or {}).get("data_cache_enabled"):
            out.append(("sql-data-cache", "Cloud SQL data cache: billed per GB of cache"))
        if s.get("disk_autoresize") and not s.get("disk_autoresize_limit"):
            out.append(("sql-disk-unbounded", "Cloud SQL disk auto-resize with no limit: storage can grow without bound"))

    if t == "google_cloud_run_v2_service":
        tmpl = first(after.get("template"), {}) or {}
        scaling = first(tmpl.get("scaling"), {}) or {}
        svc_scaling = first(after.get("scaling"), {}) or {}
        if (scaling.get("min_instance_count") or 0) > 0 or (svc_scaling.get("min_instance_count") or 0) > 0:
            out.append(("run-always-on", "Cloud Run minimum instances above 0: billed around the clock"))
        mx = scaling.get("max_instance_count")
        if mx is None or mx > RUN_MAX_INSTANCES:
            out.append(("run-unbounded", f"Cloud Run max instances {mx if mx is not None else 'unset (Google default 100)'}: cap at {RUN_MAX_INSTANCES} or less"))
        containers = tmpl.get("containers") or []
        cpu = sum(cpu_value((first(c.get("resources"), {}) or {}).get("limits", {}).get("cpu")) for c in containers)
        if cpu > RUN_MAX_CPU:
            out.append(("run-big", f"Cloud Run {cpu:g} vCPU per instance (over {RUN_MAX_CPU:g})"))

    if t == "google_cloud_run_service":  # v1 API: min scale is an annotation
        meta = first((first(after.get("template"), {}) or {}).get("metadata"), {}) or {}
        if int((meta.get("annotations") or {}).get("autoscaling.knative.dev/minScale", "0") or 0) > 0:
            out.append(("run-always-on", "Cloud Run minScale above 0: billed around the clock"))

    if t == "google_compute_instance":
        machine = (after.get("machine_type") or "").split("/")[-1]
        if machine not in SMALL_VMS:
            out.append(("vm-size", f"VM {machine or '(unknown)'}: only e2-micro/e2-small pass"))
        if first(after.get("guest_accelerator")):
            out.append(("gpu", "GPU attached"))
    return out


def main(path):
    try:
        with (open(path) if path != "-" else sys.stdin) as f:
            plan = json.load(f)
    except (OSError, ValueError) as e:
        print(f"cost-guard: can't read the plan ({e})", file=sys.stderr)
        return 2
    allowed = {r.strip() for r in os.environ.get("COST_GUARD_ALLOW", "").split(",") if r.strip()}
    blocked, waived = [], []
    for rc in plan.get("resource_changes", []):
        if not set(rc["change"]["actions"]) & {"create", "update"}:
            continue  # deletes, reads and no-ops cost nothing new
        for rule, msg in check(rc):
            (waived if rule in allowed else blocked).append((rc["address"], rule, msg))

    for addr, rule, msg in waived:
        print(f"cost-guard: ALLOWED by COST_GUARD_ALLOW  [{rule}] {addr}: {msg}")
    if blocked:
        print("cost-guard: BLOCKED. This plan would create or change resources into an expensive shape:", file=sys.stderr)
        for addr, rule, msg in blocked:
            print(f"  [{rule}] {addr}: {msg}", file=sys.stderr)
        rules = ",".join(sorted({r for _, r, _ in blocked}))
        print(f"Change the configuration, or after a cost review allow it for one run: COST_GUARD_ALLOW={rules}", file=sys.stderr)
        return 1
    print(f"cost-guard: ok ({len(plan.get('resource_changes', []))} resource changes checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "-"))
