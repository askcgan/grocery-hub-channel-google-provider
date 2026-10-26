# Google Maps Platform for Grocery Hub

Which Google Maps Platform APIs Grocery Hub needs, how each one is used, how API keys should be split and
restricted, and how to keep usage and cost under control.

Project: `groceryhub-channel`. Last reviewed: 18 October 2026.

---

## 1. Where Grocery Hub uses location today

| Area | What it does | Code |
|---|---|---|
| Store location (console) | Embedded map in *Tenant Setup → Stores → Edit store* to set the store's latitude/longitude: click the map, drag the pin, search an address or landmark, or *Locate typed address* (searched inside the store's PIN code). Shows the address at the pin and can copy it into the form. | `grocery-hub-channel-ui/src/tenantSetup/components/StoreMapPicker.jsx` |
| Serviceability (API) | Picks the store that delivers to a shopper's address: a store whose service area lists the PIN code, otherwise the nearest store whose delivery radius covers the coordinates (straight-line distance). | `grocery-hub-channel-api/…/storefront/me/ServiceabilityService.java` |
| Shopper addresses (storefront) | Addresses are saved with latitude/longitude. | `grocery-hub-channel-storefront-ui`, `…/storefront/me/CustomerMeService.java` |
| Delivery routes (fulfillment) | Routes are created and edited by hand. | `…/fulfillment/service/DeliveryRouteService.java` |
| Shopper mobile app | React Native / Expo app; no maps yet. | `grocery-hub-channel-storefront-mobile` |

---

## 2. Which APIs to keep

The key currently allows 32 APIs. Grocery Hub needs **8**, and only **2** right now.

### Needed now or for planned features

| API | Used for | Called from | When |
|---|---|---|---|
| **Maps JavaScript API** | Store location map in Tenant Setup; later a delivery-area map and the shopper's address pin | Browser (console, storefront) | **Now** |
| **Geocoding API** | *Locate typed address* and *Pin is at…* in the store form; address → coordinates for shoppers | Browser now; server later | **Now** |
| **Places API (New)** | Address autocomplete at storefront checkout, giving clean addresses and coordinates instead of free text | Storefront web and app | Next |
| **Address Validation API** | Check a shopper's address and PIN code before saving, so a wrong PIN can't route an order to the wrong store | **Server only** | Next |
| **Routes API** | Road distance and travel time instead of straight-line km, for serviceability and delivery ETAs | Server | Next |
| **Maps SDK for Android** / **Maps SDK for iOS** | Maps inside the Expo shopper app (address pin, order tracking) | Mobile app | When the app shows maps |
| **Route Optimization API** | Best stop order for a rider's batch of deliveries, replacing hand-built routes in *Fulfillment → Route Management* | **Server only**, authenticated with a service account (OAuth), not an API key | Later |

### Useful later, not needed now

| API | Possible use |
|---|---|
| Maps Static API | Small map image of the delivery address in order emails, packer screen or invoices |
| Roads API | Snap riders' GPS points to roads for live tracking, once there is a rider app |
| Navigation SDK | Turn-by-turn directions inside an in-house rider app (riders can use Google Maps itself) |
| Isochrones API | Delivery area as a drive-time shape ("within 15 minutes") instead of a radius |
| Places Aggregate API | Count shops and homes around a candidate site when planning a new dark store |
| Maps Grounding Lite API | Real place data for the LangGraph assistants ("which store is nearest to me?") |
| Map Management API | Manage Map IDs and map styles from code (Terraform) instead of the Console |

### Remove: no Grocery Hub use

Aerial View · Air Quality · Pollen · Solar · Weather · Maps Elevation · Maps 3D SDK for Android · Maps 3D SDK for
iOS · Street View Static · Street View Publish · Map Tiles · Maps Platform Datasets · Maps Embed · Geolocation ·
Time Zone · Navigation Connect · Places UI Kit.

- **Geolocation:** the browser's and phone's own location services already give a shopper's position, free.
- **Time Zone:** India uses one time zone, and the store already stores `Asia/Kolkata`.
- **Maps Embed:** replaced by the Maps JavaScript map.
- **Places UI Kit:** ready-made place widgets; use Places API (New) directly.

Remove them from the key's API restrictions, and disable them in the project (*APIs & Services → Enabled APIs*) so
nothing can call them by accident.

---

## 3. One key per caller

A browser key is visible to anyone who opens the page; that is how the Maps JavaScript API works. What protects it
is **restricting where it works and what it can call**. Use a separate key for each kind of caller:

| Key | Application restriction | API restriction |
|---|---|---|
| **Console (browser)** | Websites: `http://localhost:5173/*` and each stage/prod console URL | Maps JavaScript API, Geocoding API |
| **Storefront web (browser)** | Websites: the storefront URLs | Maps JavaScript API, Places API (New), Geocoding API |
| **Mobile app** | Android: package name + SHA-1; iOS: bundle ID | Maps SDK for Android, Maps SDK for iOS, Places API (New) |
| **Server** | None (or the server's outbound IPs). Kept in Secret Manager, never sent to a browser. | Geocoding API, Address Validation API, Routes API |
| **Route Optimization** | Service account (OAuth), not an API key | Route Optimization API |

### Website restriction format

| Entry | Matches |
|---|---|
| `http://localhost:5173/*` | The console on this laptop ✔ |
| `https://console-stage.example.com/*` | One exact site ✔ |
| `https://*.example.com/*` | Every subdomain of `example.com` (not `example.com` itself) |
| `*.localhost:5173/*` | Only subdomains such as `app.localhost:5173`, **not** `localhost:5173` ✘ |

A wrong entry shows up in the browser console as `RefererNotAllowedMapError`, and the store map says *Google
refused the Maps key* along with the exact entry to add. Changes take up to 5 minutes.

### Current console key: what to change

The existing key ("Maps Platform API Key") is the console key. In *Cloud Console → APIs & Services → Credentials →
Maps Platform API Key*:

1. Website restrictions: replace `*.localhost:5173/*` with `http://localhost:5173/*`. Remove `*.localhost:5174/*`,
   which was only used for testing.
2. API restrictions: keep only **Maps JavaScript API** and **Geocoding API** (currently 32 APIs).
3. Save, and wait up to 5 minutes.

Create the storefront, mobile and server keys when those features are built.

---

## 4. Where the key lives

| Place | What |
|---|---|
| `grocery-hub-channel-ui/.env.local` | `VITE_GOOGLE_MAPS_API_KEY` (the console key) and `VITE_GOOGLE_MAPS_MAP_ID`. The file is git-ignored and readable only by its owner. Vite reads it at start-up, so restart the dev server after changing it. |
| `grocery-hub-channel-ui/.env.example` | The same variable names with empty values, for other developers. |
| `api-credentials` (this folder) | Plain-text copy of the key. Delete it once the key is restricted. Don't put this folder in git with the file in it. |
| Stage / prod | Store keys in Secret Manager and pass them to the build as environment variables. Better still, create them with Terraform (§6). |

**Map ID:** the map uses Google's development style `DEMO_MAP_ID`. Before go-live, create a Map ID under *Google
Maps Platform → Map management* and set `VITE_GOOGLE_MAPS_MAP_ID`.

---

## 5. Cost control

Maps Platform bills per request after a free monthly allowance for each API.

- **Daily quotas:** set a per-day request limit on every enabled API (*APIs & Services → the API → Quotas &
  system limits*), so a bug that loops on Geocoding, or a leaked key, can't run up a bill.
- **Budget alert:** add a budget with alerts on the project (*Billing → Budgets & alerts*).
- **Geocode once, store the result:** save coordinates with the store or address, as the store form does, rather
  than geocoding on every page view.
- **Autocomplete sessions:** with Places API (New), use session tokens so a run of keystrokes plus the final
  selection is billed as one session.

---

## 6. Managing it as code

Enable APIs and create restricted keys with Terraform, so the Console isn't the source of truth:

```hcl
resource "google_project_service" "maps" {
  for_each = toset([
    "maps-backend.googleapis.com",   # Maps JavaScript API
    "geocoding-backend.googleapis.com",
    "apikeys.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_apikeys_key" "console_maps" {
  project      = var.project_id
  name         = "console-maps"
  display_name = "Console — Maps JavaScript + Geocoding"

  restrictions {
    browser_key_restrictions {
      allowed_referrers = concat(["http://localhost:5173/*"], var.console_urls)
    }
    api_targets { service = "maps-backend.googleapis.com" }
    api_targets { service = "geocoding-backend.googleapis.com" }
  }
}

# The key string goes straight into Secret Manager, not into outputs or files.
resource "google_secret_manager_secret_version" "console_maps_key" {
  secret      = google_secret_manager_secret.console_maps_key.id
  secret_data = google_apikeys_key.console_maps.key_string
}
```

The generated key string is also stored in Terraform state, so the state bucket must be private (see the
infrastructure recommendation: remote GCS state, plan/apply through CI).

---

## 7. Next build steps

1. **Storefront address entry:** Places API (New) autocomplete in checkout, Address Validation on the server
   before saving, then coordinates feed serviceability.
2. **Road-distance serviceability and ETAs:** Routes API in `ServiceabilityService` instead of straight-line km.
3. **Maps in the shopper app:** Maps SDK for Android/iOS via the Expo map component, with a mobile-restricted key.
4. **Rider route planning:** Route Optimization API (service account) behind *Fulfillment → Route Management*.
