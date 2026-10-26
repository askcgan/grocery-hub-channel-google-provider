# catalog-media: storage for catalog data and product images

Terraform for the Cloud Storage buckets, Pub/Sub topics and service accounts used by:

- **catalog-extractor**, which saves extraction runs: CSVs and cut-out images;
- **grocery-hub-media-processor**, which turns product images into resized WebP copies;
- **the storefront web and mobile apps**, which load those copies.

Project `groceryhub-channel`, region `asia-south1` (Mumbai) by default. Both are variables.

```
catalog-extractor (Cloud Run, private)
  └─ gs://groceryhub-channel-catalog-extractor     private: runs, products.csv, catalog-import.csv, images
       import CSV (media_url) → API
API ─ upload ─► gs://groceryhub-channel-media-originals    private: originals uploaded in the admin console
API ─ publish ─► catalog.media.ingest-requested ─ push (OIDC) ─► grocery-hub-media-processor
media processor ─► gs://groceryhub-channel-media           public read: catalog/<tenant>/<hh>/<sha256>/w200…w1200.webp
media processor ─ publish ─► catalog.media.processed ─ push (OIDC) ─► API /internal/pubsub/media-processed
storefront web + mobile ─► https://storage.googleapis.com/groceryhub-channel-media/catalog/…
```

## What it creates

| Resource | Name | Access |
|---|---|---|
| Bucket | `<project>-catalog-extractor` | Private: public access prevention enforced. `catalog-extractor-runner` has `objectUser`. Soft delete keeps deleted files 7 days. |
| Bucket | `<project>-media-originals` | Private. The API may only create objects (`objectCreator`); the processor may only read them (`objectViewer`). |
| Bucket | `<project>-media` | Public read: anyone can open an object by its name, but nobody can list the bucket (`legacyObjectReader` for `allUsers`). CORS allows GET and HEAD. The processor writes here (`objectUser`). |
| Service accounts | `catalog-extractor-runner`, `media-processor-runner`, `media-pubsub-pusher` | Runtime identities only. No keys are ever created for them. |
| Topics | `catalog.media.ingest-requested`, `catalog.media.processed`, `catalog.media.dead-letter` | The API publishes ingest requests; the processor publishes results. |
| Subscriptions | `media.dead-letter` (pull, 7 days); `media-processor.ingest` and `api.media-processed` (push, OIDC) | The push ones are created only once `processor_url` and `api_url` are set. |
| APIs | storage, iam, iamcredentials, pubsub, run | Never switched off on destroy. |

The two media buckets have `prevent_destroy`, so `terraform destroy` can't delete them by accident.

## Run it

You need `gcloud`, signed in with rights to create buckets, service accounts, Pub/Sub and IAM bindings in the project, plus `terraform` 1.6 or newer. **Cloud Shell has both.**

```bash
cd grocery-hub-channel-google-provider/catalog-media
./scripts/bootstrap.sh     # once: the APIs Terraform needs + versioned state bucket gs://groceryhub-channel-tfstate
./scripts/plan.sh          # shows what would change, saves the plan (changes nothing)
./scripts/apply.sh         # applies exactly that plan, after you type 'apply'
./scripts/verify.sh        # read-only checks; --probe also tests an anonymous image read
./scripts/app-env.sh       # the environment variables each app needs
```

To override the project or region: `PROJECT_ID=… REGION=… ./scripts/plan.sh`. Other settings are in `terraform.tfvars`, which `plan.sh` creates from `terraform.tfvars.example`.

**After the services are deployed:**
1. Set `api_service_account_email`, `processor_url` and `api_url` in `terraform.tfvars`.
2. Run `plan.sh` and `apply.sh` again.

That adds the API's grants (upload originals, publish ingest requests), the two push subscriptions, and `run.invoker` for the push account on both services.

## Connecting the apps

`./scripts/app-env.sh` prints the values from Terraform's outputs.

| App | Settings |
|---|---|
| catalog-extractor | `STORAGE_PROVIDER=gcs`, `GCS_BUCKET=<project>-catalog-extractor`, `GCP_PROJECT_ID=<project>`. Deploy with `--service-account=catalog-extractor-runner@…`. |
| media processor | `MEDIA_STORAGE=gcs`, `MEDIA_ORIGINALS_BUCKET`, `MEDIA_BUCKET`, `PUBSUB_PROJECT_ID`, `PUSH_SERVICE_ACCOUNT`. Deploy with `--service-account=media-processor-runner@…`. |
| API | `APP_MEDIA_INGEST_ENABLED=true`, `APP_MEDIA_PUBLIC_BASE_URL=https://storage.googleapis.com/<project>-media`, `APP_MEDIA_ORIGINALS_PROVIDER=gcs`, `APP_MEDIA_ORIGINALS_BUCKET`, `APP_MEDIA_PUSH_SERVICE_ACCOUNT`. |
| storefront web and mobile | Nothing to set. The API returns full image URLs on the media bucket (later the CDN domain), and the mobile app picks the right `w…` size from them. |

**Already pointed here:** the catalog extractor (`config/stage.env`, `cloudbuild.yaml`, `npm run deploy:stage`) and the media processor (`cloudbuild.yaml`) target `groceryhub-channel` / `asia-south1`. Their builds only check that this stack's resources exist; they no longer create them.

## How extracted images reach the storefront

The extractor's bucket stays private: it holds other sites' screenshots.

1. The extractor's import CSV carries a **signed link** to each image (`IMPORT_MEDIA_MODE=signed`, valid 7 days). The extractor's account signs as itself (`extractor_signs_image_links = true`).
2. On import, the API (with `APP_MEDIA_INGEST_ENABLED=true`) queues each link.
3. The processor downloads it once and stores its own WebP copies in the public media bucket.
4. Re-importing later doesn't duplicate images: the API compares signed Cloud Storage links without their signature.

## Notes

- **Cost.** At catalogue scale this is storage plus Pub/Sub throughput, a few rupees a month. Public image reads are billed as network egress. A CDN in front of the media bucket (load balancer plus Cloud CDN, in the media processor's DEPLOY.md §5) lowers that and adds a media domain, but the load balancer has a fixed monthly cost.
- **Org policy.** If `iam.allowedPolicyMemberDomains` forbids `allUsers`, the public grant fails. Set `media_public_read = false` and serve the bucket through the CDN.
- **No lifecycle rule on the extractor bucket.** OCR evidence (`out/<run>/cards/`, `snapshots/`) can't be matched by a lifecycle prefix or suffix without also matching the run's CSVs and images. Delete old runs by hand: `gcloud storage rm -r gs://<bucket>/out/<run>`.
- **State** is in `gs://<project>-tfstate` (versioned; old versions are kept 30 days). Commit `.terraform.lock.hcl`; never commit `terraform.tfstate` or `tfplan`.
