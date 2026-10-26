# Deployment strategy: catalog extractor and media processor on Google Cloud

How infrastructure and application releases reach Google Cloud project `groceryhub-channel` (region `us-central1`, Iowa: chosen for cost, see "Region"), how changes are rolled out and rolled back, and what is planned next.

Status (26 Oct 2026): everything below is written and validated, **not yet applied or deployed**. Nothing exists in the project until someone runs the steps in "First rollout".

## What is in this folder

| Path | What it is | Use it? |
|---|---|---|
| `catalog-media/` | Terraform stack for the catalog extractor and media pipeline: buckets, service accounts, Pub/Sub, image repository, plus scripts | **Yes**: the infrastructure described here |
| `app-template/` | A sample app stack (Cloud Run + Cloud SQL MySQL + secret + bucket), rewritten from the Google Application Design Center export that used to sit at the top of this folder. Small database, scales to zero, about $10–15 a month; refuses to plan until `acknowledge_billable_resources = true` | Only if you need it: it isn't part of this platform |
| `app-template/original-export/*.tf.txt` | The export as Google generated it: Enterprise Plus `db-perf-optimized-N-8`, regional HA, always-on Cloud Run, about $1,400–1,600 a month | **Never.** Kept for reference, renamed `.txt` so Terraform can't load it |
| `tools/cost-guard.py` | Checks every saved plan for expensive resources; the scripts run it before anything is applied | Automatic |
| top level | No `.tf` files: `terraform apply` here finds nothing to apply | — |
| `GOOGLE_MAPS_PLATFORM.md` | Notes on the Maps Platform setup | Reference |
| `api-credentials`, `google-management-service` | A plain-text Google Maps key, and a list of enabled APIs | The key belongs in Secret Manager; both files are git-ignored |

## The strategy in one picture

```
            ┌─────────────────────── Layer 1: infrastructure (Terraform) ───────────────────────┐
 project    │ bootstrap.sh (once, by an owner) → plan.sh → apply.sh → verify.sh                 │
 owner ───► │ state: gs://groceryhub-channel-tfstate · runs as terraform-deployer (impersonated)│
            │ owns: buckets · service accounts · Pub/Sub · image repository · their IAM         │
            └───────────────────────────────────────────────────────────────────────────────────┘
                                     ▲ checks it exists, never changes it
            ┌──────────────────── Layer 2: applications (Cloud Build) ──────────────────────────┐
 developer  │ gcloud builds submit → project check → infrastructure check → build → push        │
       ───► │ → deploy new Cloud Run revision (100% traffic) → health check / verify            │
            └───────────────────────────────────────────────────────────────────────────────────┘
```

**Principle: one owner per resource.** Terraform creates and permissions everything that lasts (data, identities, topics, the image repository). Builds only ship code onto it.
- Builds can't drift the infrastructure, and the build accounts need no storage, Pub/Sub or IAM-admin rights.
- An infrastructure change is reviewed as a plan; an app release is a new Cloud Run revision.

## Strategy 1: infrastructure as code

| Aspect | How it's done |
|---|---|
| Tool | Terraform ≥ 1.6, Google provider pinned by `.terraform.lock.hcl` (7.46.2 at writing, Linux and macOS checksums) |
| Where it runs | Cloud Shell (has `gcloud` and `terraform`), or a laptop after `gcloud auth application-default login` |
| Identity | People sign in as themselves and **impersonate** `terraform-deployer`, which has only the roles the stack needs: no owner, editor or project-IAM-admin, no keys. The deployer is created by `bootstrap.sh`, not Terraform, so a Terraform run can never widen its own access |
| State | `gs://groceryhub-channel-tfstate`: private and versioned, old versions kept 30 days. Terraform's GCS backend locks the state during a run |
| Change flow | `plan.sh` saves the exact change list; `apply.sh` applies only that plan, after a typed `apply` |
| Cost guard | After every plan, and again right before every apply, `tools/cost-guard.py` reads the plan and **refuses** expensive shapes (rules in "Cost guard rails"). A blocked rule is allowed only by naming it for one run: `COST_GUARD_ALLOW=<rule> ./scripts/plan.sh`, after a cost review |
| Other stacks | `STACK_DIR=<path> ./catalog-media/scripts/plan.sh` runs any stack in this folder (`app-template`) through the same plan → cost guard → apply path |
| Guard rails | The media buckets have `prevent_destroy`; destroying the stack never disables APIs; `verify.sh` checks privacy, missing keys and the deployer's roles |
| Drift check | Run `plan.sh`: "No changes" means the project matches the code. Anything else was changed by hand: bring it back into code or let apply undo it |

**Planned next:** run `plan.sh` from a Cloud Build trigger on every pull request (the plan posted for review) and `apply.sh` on merge, as `terraform-deployer`, so no one applies from a laptop.

## Strategy 2: application releases

| Aspect | catalog-extractor | grocery-hub-media-processor |
|---|---|---|
| Command | `npm run deploy:stage` (= `gcloud builds submit --config cloudbuild.yaml --project groceryhub-channel .`) | `gcloud builds submit --config=cloudbuild.yaml --project=groceryhub-channel .` |
| Pipeline | project check → infrastructure check → build → push → deploy → authenticated `/healthz` | project check → infrastructure check → build → push → deploy → verify (Ready, anonymous request refused, subscriptions listed) |
| Image tags | `:<build id>` (what is deployed) and `:latest` (build cache) | same |
| Runs as | `catalog-extractor-runner` | `media-processor-runner` |
| Shape | private; 0–1 instance (job state is in memory); 2 vCPU, 2 GiB; CPU stays on while a run works; 1 h timeout | private; 0–5 instances; 1 vCPU, 1 GiB; concurrency 4; 120 s timeout |
| Who can call it | people with `roles/run.invoker`, through `gcloud run services proxy` | only the Pub/Sub push account, whose OIDC token it checks itself |

**Release strategy today: replace.**
- **How it goes out:** each deploy creates a new Cloud Run revision, and it takes 100% of traffic once it starts and passes Cloud Run's start-up check. Requests in flight finish on the old revision.
- **Why it's enough for now:** the extractor is an internal tool with one instance, and the processor works on queued messages that are retried. A failed image is retried 5 times, then kept 7 days in `media.dead-letter`. So a bad release delays work but doesn't lose it.
- **Instant rollback:** point traffic back at the previous revision. No rebuild is needed; it's in Cloud Run and in the image repository:
  ```bash
  gcloud run revisions list --service=<service> --region=us-central1
  gcloud run services update-traffic <service> --region=us-central1 --to-revisions=<previous revision>=100
  ```
- **Rollback window:** the image repository keeps the newest 5 versions of each image, whatever their age, and deletes other versions after 30 days. So the last 5 releases can always be restored.

**When a service gets real user traffic (the API, the storefronts), move to a canary:**
1. Deploy with `--no-traffic --tag=candidate`. The new revision gets its own test URL and no users.
2. Smoke-test that URL.
3. Shift a share of traffic: `gcloud run services update-traffic <service> --to-tags=candidate=10`.
4. Watch errors and latency in Cloud Monitoring.
5. Go to 100%, or back to 0.

This needs a `--no-traffic` deploy step and a manual or automated promotion step in `cloudbuild.yaml`. It isn't built yet.

## Strategy 3: configuration, secrets and feature switches

| What | Where it lives | How it changes |
|---|---|---|
| Per-environment settings | `config/<profile>.env` in each image (`APP_PROFILE=stage`) | Edit the file and redeploy; reviewed with the code |
| Values that differ per deploy | Cloud Run env vars from the deploy step (`GCS_BUCKET`, `GCP_PROJECT_ID`) | The build's substitutions. `--set-env-vars` **replaces** all variables, so add new ones to the build file, not by hand |
| Infrastructure names | Terraform outputs; `./scripts/app-env.sh <app>` prints them | Re-run after an apply; never typed by hand |
| Secrets (Google search key, Anthropic key, API passwords) | Secret Manager, mounted with `--set-secrets` | Never in env files, Terraform variables or this folder |

**Feature switches decide what a release turns on:**

| Switch | Where | Turn on when |
|---|---|---|
| `IMPORT_MEDIA_MODE=signed` | extractor (on in stage and prod) | Already on: import CSVs carry 7-day signed image links |
| `APP_MEDIA_INGEST_ENABLED=true` | API | Only after the processor is deployed and its push subscription exists, otherwise images stay "Processing…" |
| `processor_url`, `api_url` | catalog-media `terraform.tfvars` | After each service's first deploy; apply again to create its push subscription |
| `scan_images` | catalog-media | When images should be scanned for vulnerabilities on push (about $0.26 an image) |
| `media_public_read` | catalog-media | `false` when a CDN serves the media bucket, or an org policy forbids public access |

## Region

`us-central1` (Iowa) is the default because it is the cheapest region for this workload, checked 26 Oct 2026 against Google's [Cloud Run locations](https://docs.cloud.google.com/run/docs/locations) and [Free Tier](https://docs.cloud.google.com/free/docs/free-cloud-features) pages.

| | us-central1 (Iowa) | europe-west1 (Belgium) | asia-south1 (Mumbai) | europe-central2 (Warsaw) |
|---|---|---|---|---|
| Cloud Run pricing tier | Tier 1 | Tier 1 | Tier 1 | Tier 2 (dearer) |
| Cloud Storage always-free: 5 GB stored + 100 GB/month internet egress | yes (US regions only) | no | no | no |
| Low-CO2 | yes | yes | no | yes |

**The free egress is the deciding line.** Shoppers' image downloads were the biggest cost (about 12 GB a month now, ~$1.50 from Mumbai), and 100 GB a month of them is free from a US region. Warsaw costs more, not less.

**The price is distance:** an image request from India to Iowa takes about 200 ms longer than to Mumbai on first load. Images are cached by browsers for a year, and a CDN in front of the media bucket removes most of the gap when traffic grows. This bucket holds product images and catalogue data, not personal data, so residency doesn't constrain it. Where the API and its customer data run is a separate decision.

## Environments

| Environment | Where | State |
|---|---|---|
| local | laptops: `npm run ui`, local files, Pub/Sub emulator | none |
| stage | `groceryhub-channel`, `us-central1` | `gs://groceryhub-channel-tfstate`, prefix `catalog-media` |
| prod | **not decided**: recommended, a separate project with its own billing alerts | that project's own `<project>-tfstate` |

**Why a separate project for prod:**
- IAM, quotas, budgets and the state bucket are separate by default, so a stage mistake can't reach prod data.
- The same stack serves both: `PROJECT_ID=<prod project> ./scripts/bootstrap.sh`, then `plan.sh` and `apply.sh`.
- The build files' project guard and substitutions would take the prod project's values.

**Prod in the same project** would need a different state prefix and resource names per environment. The stack and scripts don't support that today.

## First rollout, in order

1. **Infrastructure:** in `catalog-media`, run `./scripts/bootstrap.sh` (a project owner, once), then `plan.sh`, `apply.sh` and `verify.sh`.
2. **Media processor:** deploy it, set `processor_url` in `terraform.tfvars`, then `plan.sh` and `apply.sh` (creates its push subscription).
3. **Catalog extractor:** `npm run deploy:stage`. Give people `roles/run.invoker` and use `gcloud run services proxy catalog-extractor --region=us-central1 --port=4321`.
4. **API:** when it runs in this project, set `api_url` and `api_service_account_email` and apply again. Add its media settings (`./scripts/app-env.sh api`) to its build file, then turn on `APP_MEDIA_INGEST_ENABLED`.
5. **End-to-end check:**
   - extract a screenshot;
   - download the import CSV (its image links show an expiry date);
   - import it in the admin console within 7 days;
   - the product images appear under `gs://groceryhub-channel-media/catalog/` and in the storefront.

## When something goes wrong

| Problem | First move | Then |
|---|---|---|
| A bad app release | Traffic back to the previous revision (Strategy 2) | Fix and redeploy; the bad revision stays for inspection |
| A bad Terraform apply | `plan.sh` from the last good commit, then `apply.sh` | If state itself is damaged, restore the previous version of the state object (bucket versioning, 30 days) |
| Build stops at "infrastructure check" | Apply `catalog-media` first | `verify.sh` names what's missing |
| `apply` says the image repository already exists | A build created it first: `terraform import google_artifact_registry_repository.images projects/groceryhub-channel/locations/us-central1/repositories/grocery-hub` | Plan again |
| Images stuck in "Processing…" | Check the processor's logs and `media.dead-letter` | Re-send dead letters once the cause is fixed (`grocery-hub-channel-api/docs/runbooks/MEDIA_PIPELINE.md`) |
| Import CSV download fails with a permission error | The extractor's account can't sign links: check `extractor_signs_image_links = true` and apply | `verify.sh` |
| A deleted run or category file | Restore it from soft delete (extractor bucket, 7 days) | |

## Cost guard rails

The whole stack scales to zero and costs about $1–3 a month at catalogue scale in `us-central1` (the free tier covers image egress and build minutes). Four layers keep a mistake from becoming a large bill:

1. **Nothing applies by accident.** The folder's top level has no Terraform; each stack has its own folder and scripts. `app-template` refuses to plan until its cost is acknowledged.
2. **Small by default.** Variables only accept small shapes (database tiers up to 2 vCPU, Cloud Run capped at 10 instances, disk growth capped), checked by `terraform validate` and by the offline tests in `app-template/tests`.
3. **The cost guard blocks expensive plans** before apply:

   | Rule | Blocks |
   |---|---|
   | `sql-tier`, `sql-enterprise-plus`, `sql-ha`, `sql-data-cache`, `sql-disk-unbounded` | Cloud SQL above 2 vCPU, Enterprise Plus, regional HA, data cache, unbounded disk growth |
   | `run-always-on`, `run-unbounded`, `run-big` | Cloud Run with minimum instances above 0, max instances above 10 or unset, more than 4 vCPU |
   | `vm-size`, `gpu` | VMs bigger than e2-small, GPUs |
   | `cluster`, `alloydb`, `spanner`, `bigtable`, `redis`, `dataproc`, `notebooks`, `vertex-endpoint` | Services with a fixed hourly cost |
   | `load-balancer`, `nat`, `vpc-connector` | Fixed-cost networking (~$15–32 a month each) |

4. **Budgets alert** when something gets through: all services ₹3,000, Cloud Run ₹1,000, storage ₹2,500, alerts at 50, 90 and 100%. Budgets only alert; they never stop spending.

The image cleanup policy keeps the repository from growing with every build. Line-by-line figures are in the shared write-up below.

## More detail

- `catalog-media/README.md`: the stack, every resource, settings for each app.
- `catalog-extractor/docs/deployment.md`: the extractor's settings, Cloud Run access, the signed-link image flow.
- `grocery-hub-media-processor/DEPLOY.md`: the processor's deploy, the CDN option, operations.
- Team write-up (security and cost): https://claude.ai/artifact/SGrpRoBn2BuH3LhNxvkHBM
