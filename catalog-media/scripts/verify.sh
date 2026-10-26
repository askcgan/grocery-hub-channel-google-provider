#!/usr/bin/env bash
# Read-only checks of what the stack should have created. Changes nothing.
#   --probe : also write a tiny test object to the media bucket, fetch it anonymously, and delete it
set -uo pipefail
source "$(dirname "$0")/common.sh"
need gcloud
fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
EXTRACTOR="${EXTRACTOR_BUCKET:-${PROJECT_ID}-catalog-extractor}"; ORIGINALS="${PROJECT_ID}-media-originals"; MEDIA="${PROJECT_ID}-media"

say "Buckets"
for b in "$EXTRACTOR" "$ORIGINALS" "$MEDIA"; do
  d="$(gcloud storage buckets describe "gs://$b" --format='value(location,uniform_bucket_level_access,public_access_prevention)' 2>/dev/null)" \
    && ok "gs://$b  $d" || bad "gs://$b missing"
done
pap() { gcloud storage buckets describe "gs://$1" --format='value(public_access_prevention)' 2>/dev/null; }
[ "$(pap "$EXTRACTOR")" = "enforced" ] && ok "extractor bucket is private" || bad "extractor bucket must have public access prevention enforced"
[ "$(pap "$ORIGINALS")" = "enforced" ] && ok "originals bucket is private" || bad "originals bucket must have public access prevention enforced"
gcloud storage buckets get-iam-policy "gs://$MEDIA" --format=json 2>/dev/null | grep -q '"allUsers"' \
  && ok "media bucket readable by anyone (allUsers)" || echo "  note media bucket not public (media_public_read=false or an org policy): images need a CDN in front"

say "Service accounts"
for a in catalog-extractor-runner media-processor-runner media-pubsub-pusher; do
  gcloud iam service-accounts describe "$a@${PROJECT_ID}.iam.gserviceaccount.com" --project="$PROJECT_ID" >/dev/null 2>&1 \
    && ok "$a" || bad "$a missing"
  keys="$(gcloud iam service-accounts keys list --iam-account="$a@${PROJECT_ID}.iam.gserviceaccount.com" --managed-by=user --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$keys" = "0" ] && ok "$a has no user-managed keys" || bad "$a has $keys user-managed key(s): delete them, Cloud Run needs none"
done
gcloud storage buckets get-iam-policy "gs://$EXTRACTOR" --format=json 2>/dev/null | grep -q "catalog-extractor-runner@" \
  && ok "extractor account can read/write its bucket" || bad "extractor account has no access to gs://$EXTRACTOR"

say "Deployer"
DEPLOYER="terraform-deployer@${PROJECT_ID}.iam.gserviceaccount.com"
if gcloud iam service-accounts describe "$DEPLOYER" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ok "terraform-deployer exists"
  keys="$(gcloud iam service-accounts keys list --iam-account="$DEPLOYER" --managed-by=user --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$keys" = "0" ] && ok "terraform-deployer has no user-managed keys (impersonation only)" || bad "terraform-deployer has $keys key(s): delete them"
  broad="$(gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' --filter="bindings.members:serviceAccount:${DEPLOYER} AND bindings.role:(roles/owner OR roles/editor OR roles/resourcemanager.projectIamAdmin)" --format='value(bindings.role)' 2>/dev/null)"
  [ -z "$broad" ] && ok "terraform-deployer has no owner, editor or project IAM admin role" || bad "terraform-deployer has $broad: remove it"
else
  bad "terraform-deployer missing: run ./scripts/bootstrap.sh"
fi

say "Container images"
gcloud artifacts repositories describe "${IMAGE_REPOSITORY:-grocery-hub}" --location="$REGION" --project="$PROJECT_ID" \
  --format='value(name)' >/dev/null 2>&1 && ok "repository ${IMAGE_REPOSITORY:-grocery-hub} in $REGION" || bad "repository ${IMAGE_REPOSITORY:-grocery-hub} missing in $REGION"
policies="$(gcloud artifacts repositories describe "${IMAGE_REPOSITORY:-grocery-hub}" --location="$REGION" --project="$PROJECT_ID" --format='value(cleanupPolicies)' 2>/dev/null)"
[ -n "$policies" ] && ok "cleanup policies set" || bad "no cleanup policy on the image repository"

say "Pub/Sub"
for t in catalog.media.ingest-requested catalog.media.processed catalog.media.dead-letter; do
  gcloud pubsub topics describe "$t" --project="$PROJECT_ID" >/dev/null 2>&1 && ok "topic $t" || bad "topic $t missing"
done
gcloud pubsub subscriptions list --project="$PROJECT_ID" --format='table[box](name.basename(),topic.basename(),pushConfig.pushEndpoint)' 2>/dev/null

if [ "${1:-}" = "--probe" ]; then
  say "Probe: anonymous read of the media bucket"
  key="probe/verify-$(date +%s).txt"
  echo ok | gcloud storage cp - "gs://$MEDIA/$key" >/dev/null
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://storage.googleapis.com/$MEDIA/$key")"
  [ "$code" = "200" ] && ok "https://storage.googleapis.com/$MEDIA/… loads without signing in" || bad "anonymous read returned HTTP $code"
  listing="$(curl -s -o /dev/null -w '%{http_code}' "https://storage.googleapis.com/$MEDIA")"
  [ "$listing" != "200" ] && ok "bucket listing is not public (HTTP $listing)" || bad "anyone can list the media bucket"
  gcloud storage rm "gs://$MEDIA/$key" >/dev/null
fi

say "$([ $fail = 0 ] && echo 'All checks passed' || echo 'Some checks FAILED')"
exit $fail
