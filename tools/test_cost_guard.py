"""python3 -m unittest tools/test_cost_guard.py  (from grocery-hub-channel-google-provider)"""
import json, os, pathlib, subprocess, sys, tempfile, unittest

GUARD = pathlib.Path(__file__).with_name("cost-guard.py")


def change(addr, rtype, after, actions=("create",)):
    return {"address": addr, "type": rtype, "change": {"actions": list(actions), "after": after}}


def sql(tier, edition="ENTERPRISE", avail="ZONAL", cache=False, limit=20):
    return change("module.db.google_sql_database_instance.default", "google_sql_database_instance", {"settings": [{
        "tier": tier, "edition": edition, "availability_type": avail, "disk_autoresize": True,
        "disk_autoresize_limit": limit, "data_cache_config": [{"data_cache_enabled": cache}]}]})


def run_service(min_i, max_i, cpu="1"):
    return change("module.web.google_cloud_run_v2_service.main", "google_cloud_run_v2_service", {
        "scaling": [{"min_instance_count": 0}],
        "template": [{"scaling": [{"min_instance_count": min_i, "max_instance_count": max_i}],
                      "containers": [{"resources": [{"limits": {"cpu": cpu, "memory": "512Mi"}}]}]}]})


def guard(changes, allow=""):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump({"resource_changes": changes}, f)
    env = {**os.environ, "COST_GUARD_ALLOW": allow}
    p = subprocess.run([sys.executable, str(GUARD), f.name], capture_output=True, text=True, env=env)
    os.unlink(f.name)
    return p.returncode, p.stdout + p.stderr


class CostGuard(unittest.TestCase):
    def test_the_old_template_is_blocked(self):
        # what the Application Design Center export would have planned
        code, out = guard([sql("db-perf-optimized-N-8", "ENTERPRISE_PLUS", "REGIONAL", cache=True, limit=0), run_service(1, 10)])
        self.assertEqual(code, 1)
        for rule in ("sql-tier", "sql-enterprise-plus", "sql-ha", "sql-data-cache", "sql-disk-unbounded", "run-always-on"):
            self.assertIn(f"[{rule}]", out)

    def test_the_rewritten_template_passes(self):
        code, out = guard([sql("db-f1-micro"), run_service(0, 2)])
        self.assertEqual(code, 0, out)

    def test_catalog_media_passes(self):
        code, out = guard([change("google_storage_bucket.media", "google_storage_bucket", {"name": "x"}),
                           change("google_pubsub_topic.ingest", "google_pubsub_topic", {"name": "t"}),
                           change("google_artifact_registry_repository.images", "google_artifact_registry_repository", {})])
        self.assertEqual(code, 0, out)

    def test_expensive_types_and_vms(self):
        code, out = guard([change("google_container_cluster.c", "google_container_cluster", {}),
                           change("google_compute_instance.vm", "google_compute_instance", {"machine_type": "n2-standard-8"}),
                           change("google_compute_global_forwarding_rule.lb", "google_compute_global_forwarding_rule", {})])
        self.assertEqual(code, 1)
        for rule in ("cluster", "vm-size", "load-balancer"):
            self.assertIn(f"[{rule}]", out)
        self.assertEqual(guard([change("google_compute_instance.vm", "google_compute_instance", {"machine_type": "zones/x/machineTypes/e2-micro"})])[0], 0)

    def test_an_allowance_is_explicit_and_per_rule(self):
        lb = change("google_compute_global_forwarding_rule.lb", "google_compute_global_forwarding_rule", {})
        code, out = guard([lb], allow="load-balancer")
        self.assertEqual(code, 0)
        self.assertIn("ALLOWED by COST_GUARD_ALLOW", out)
        self.assertEqual(guard([lb, sql("db-perf-optimized-N-8")], allow="load-balancer")[0], 1)

    def test_deletes_cost_nothing_new(self):
        self.assertEqual(guard([sql("db-perf-optimized-N-8") | {"change": {"actions": ["delete"], "after": None}}])[0], 0)

    def test_unreadable_plan(self):
        p = subprocess.run([sys.executable, str(GUARD), "/nonexistent.json"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main()
