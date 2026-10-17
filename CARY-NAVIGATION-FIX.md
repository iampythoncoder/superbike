# Cary crash map and bicycle navigation — October 17, 2026

## Changes

- Cycling now uses the bicycle-specific FOSSGIS / OSRM graph instead of relying on
  MapKit cycling requests that returned automobile routes. Walking stays in MapKit.
- Bicycle route responses must contain valid coordinates, nearby endpoint snaps,
  usable geometry/duration, and cycling, dismount or ferry modes. Car modes fail.
- A route preview fits its own polyline rather than the bounding box of all crash
  overlays. New routes also refresh the preview when their point counts match.
- Spoken turn cues are marked delivered only after the alert coordinator accepts
  them. A cue suppressed by an active danger warning can retry on the next GPS fix.
- Route errors remain visible during navigation, with a retry control when off route.
- Choosing a new search result can replace an active trip; search results are no
  longer all disabled just because navigation is already running.
- The default crash provider selects NCDOT in NC and NYPD in NYC. Separate provider
  caches preserve each region. Clusters use source-specific provenance and latitude.
- The map exposes source details and dates, attribution and map-correction links.

## Official data and routing sources

NCDOT links this layer from its Safety Data Maps → Pedestrian and Bicycle Crashes:

https://www.ncdot.gov/initiatives-policies/safety/traffic-safety/Pages/safety-data-maps.aspx

https://services.arcgis.com/NuWFvHYDMVmmxMeM/arcgis/rest/services/NCDOT_NonMotoristCrashes/FeatureServer/0

The NC query uses Bicyclist records over five years, a bounded geographic envelope,
and a final radial filter. Pedestrians, powered scooters, duplicate IDs, invalid
locations and future/out-of-window dates do not enter the bicycle heat overlay.
Red means >=3 recorded bicycle crashes in a 150m cluster cell or a cyclist fatality;
orange means other recorded clusters. No exposure-adjusted crash probability is implied.
The publisher's update date and newest nearby record are separate from fetch time.

Cary's police table was inspected but is not used: the current export omits
coordinates, so it cannot produce a reliable point map without guessing locations.

FOSSGIS routing policy and privacy: https://routing.openstreetmap.de/about.html

The `/routed-bike/route/v1/driving/` path is the provider's bicycle graph. The final
path token is OSRM's API profile parameter, not a request to the car-routing graph.
Responses are checked for bicycle-compatible step modes. Requests include a user
agent, reserve at least 1.05 seconds between starts, and respect the provider's
light-use limit. Origin and destination coordinates are transmitted to FOSSGIS.

## Validation

The additional `Validation/CaryNavigationChecks.swift` harness covers real bicycle
response decoding, car-response rejection, invalid snaps, route preview/start,
voice retry/deduplication, GPS progress/arrival, clearing navigation, NC query
filters and response validation. `--live` additionally checks official downtown
Cary crash records, MapKit search and a startable bicycle route with maneuvers.

Initial live run: 23 bicycle crashes / 21 historical zones within 3km of downtown
Cary (35.7877, -78.7811); route to Cary Regional Library returned 33 geometry points
and 7 maneuvers. Counts change as source data and date windows change.

Existing validation: 66 checks passed. New validation: 21 checks passed including
the live checks. Physical-device and simulator builds passed. These checks are
not a physical road test on the user's iPhone 15 Pro.

In Xcode, run the updated project on the phone, grant Precise Location, search
for Cary Regional Library or Downtown Cary Park, select a result, then tap Go.
The map's flame button controls the historical crash overlay. Keep the app open.

## Whole-Cary and current NC-02 expansion

The area/layers menu now offers All Cary, current NC-02 (Ross district), their
union, and the existing 3km nearby view. The local default is Cary + NC-02. These
are geographic scopes, not a radius around a downtown point. GPS tracking does
not replace a selected whole-area view. The app loads the full five-year bicycle
history within the selected bounds, paginates in 2,000-row pages, deduplicates
crash IDs, then filters against the actual municipal/district polygons. A 10,000
raw-row limit is explicitly labeled partial if reached; the live result did not
reach that limit. An empty area is not presented as evidence that roads are safe.

Census boundaries are bundled, so jurisdiction outlines do not depend on a live
Census request. Cary's disconnected annexations and holes are preserved. NC-02
is explicitly the current 119th Congress (2025–2027), not the 120th Congress
election map. Source URLs and query provenance are in
`Superbike/Resources/BOUNDARY-SOURCES.md` and Map → Sources & coverage.

Full-region snapshots are cached per area for offline use (up to seven days),
with the publication date and history window retained. Nearby rider alerts still
load separately, so viewing a different area does not disable local warnings.

Live October 17 check: 323 unique bicycle crashes and 288 zones in the union;
52 records in Cary and 301 in NC-02 (overlap counted in each jurisdiction). All
returned incidents passed the polygon filter; some are over 15km from downtown
Cary. `Validation/RegionalCoverageChecks.swift` passed 21 checks including holes,
overlaps, real complete-area retrieval, duplicate rejection and offline caching.
Pass the resources directory as its first argument and `--live` for source checks.

Final regression run: 108 checks passed (66 existing, 21 Cary/navigation including
live services, and 21 regional coverage including live data). Both iPhone-device
and simulator builds passed, including bundled boundary-resource checks.
